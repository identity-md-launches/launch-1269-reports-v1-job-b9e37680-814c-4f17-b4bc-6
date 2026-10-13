// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {OracleAttestation, OracleAttestationConsumer} from "./oracle/OracleAttestation.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {IGameRegistry} from "./interfaces/IGameRegistry.sol";
import {IRewards} from "./interfaces/IGame.sol";
import {Params} from "./Params.sol";
import {GridOperator} from "./GridOperator.sol";
import {Civic} from "./Civic.sol";
import {Enhancement} from "./Enhancement.sol";
import {PackSale} from "./PackSale.sol";
import {Economy} from "./Economy.sol";
import {ChainClock} from "./lib/ChainClock.sol";
import {SwarmCode} from "./lib/SwarmCode.sol";
import {IMD} from "./lib/IMD.sol";
import "./lib/Errors.sol";

interface ISwarmIntake {
    struct Callback {
        address target;
        bytes4 selector;
    }
    function priceOf(bytes32 action, address asset) external view returns (uint256);
    function requestWithFailure(
        bytes32 action,
        bytes calldata body,
        Callback calldata callback,
        bytes4 onFailure,
        address asset,
        uint256 amount
    ) external payable returns (bytes32);
}

interface ISwarmFactory {
    function predictContract(uint64 launchNumber, uint256 index, bytes calldata initCode)
        external
        view
        returns (address);
}

interface ISwarmRegistry is IGameRegistry {
    function factory() external view returns (address);
}

/// @dev The launch hook's immutables, probed at bind time (V4Market exposes all three).
interface IBoundHook {
    function desk() external view returns (address);
    function token() external view returns (address);
    function gameConfigHash() external view returns (bytes32);
}

/// @notice BLACKOUT's only swarm authority. No owner, arbitrary calls, withdrawals or upgrades.
/// @dev Immutable recurring questions; each stream/UTC slot and attestation UUID is accepted once.
/// Callback only authenticates/stores. Anyone executes the committed answer outside the 200k stipend.
contract SwarmDesk is OracleAttestationConsumer, ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct OracleConfig {
        address intake;
        address delivery;
        address signer;
        address asset;
        bytes32 action;
        uint256 maxPrice;
        uint256 questionChain;
        uint64 fromBlock;
        uint64 toBlock;
        bytes32[2] questions;
        bytes32[2] bodies;
    }

    struct BindingConfig {
        address factory;
        uint64 registryLaunch;
        uint8 registryIndex;
        uint64 paramsLaunch;
        uint8 paramsIndex;
        bytes32 gameConfigHash;
        uint256 heartbeatBps;
        uint256 heartbeatCap;
    }

    struct Result {
        bytes32 answerHash;
        bytes32 requestId;
        uint64 issuedAt;
        uint64 validUntil;
        uint64 slot;
        bool pending;
        uint48 receivedBlock;
    }

    struct Pending {
        uint64 slot;
        uint64 deadline;
        uint8 streamPlusOne;
    }
    /// @dev Attested severity band; GridOperator itself admits 5000-10000, so the Desk never exceeds 7000.
    uint16 public constant SEVERITY_MIN = 5000;
    uint16 public constant SEVERITY_MAX = 7000;
    OracleConfig private config;
    BindingConfig private binding;
    IGameRegistry public registry;
    mapping(uint8 => Result) public lastAnswer;
    mapping(uint8 => uint256) public acceptedSlotPlusOne;
    mapping(uint8 => uint256) public askedSlotPlusOne;
    mapping(bytes32 => Pending) public pending;
    mapping(bytes32 => bool) public delivered;
    bytes32 public lastFailure;
    bytes32 public lastLetterHash;
    uint256 public lastEventEpoch;
    uint8 public districtHint;
    event Bound(address indexed registry);
    event BackupAsked(uint8 indexed stream, uint256 slot, bytes32 indexed requestId, uint256 price);
    event AnswerStored(uint8 indexed stream, bytes32 indexed requestId, uint256 slot, bytes answer);
    event AnswerIgnored(bytes32 indexed requestId, uint8 reason);
    event OracleFailure(bytes32 indexed requestId, uint8 status, bytes32 reason);
    event Executed(uint8 indexed stream, bytes32 indexed requestId, bytes32 letterHash);
    event ActionSkipped(uint8 indexed action, bytes reason);

    /// @dev Seven static ABI words (v3.14) fit the launcher's flat constructor encoder and the legacy (non
    /// via-IR) code generator the IMD verifier builds with. Every IMD protocol address (Intake, IntakeDelivery,
    /// attester, Robinhood IMD, ProjectFactory) is a compile-time constant (src/lib/IMD.sol): the IMD manifest
    /// gate refuses them as constructor words.
    /// policyWord = chainId[0:32] | fromBlock[32:80] | toBlock[80:128] | maxPrice[128:224] | heartbeatBps[224:240];
    /// bits 240-255 must be zero. No launch coordinate is taken: IMD launch numbers cannot be reserved, so
    /// they are supplied and proven at bind time (v3.8). The heartbeat cap is fixed at 1 ether.
    /// gameConfigHash = keccak256(abi.encode(starterRoot, freeRoot, snapshotBlock, endowment)); the token
    /// is deliberately excluded because the Desk bootstrap precedes the token launch.
    constructor(
        bytes32 action_,
        uint256 policyWord,
        bytes32 eventQuestion,
        bytes32 regulatorQuestion,
        bytes32 eventBody,
        bytes32 regulatorBody,
        bytes32 gameConfigHash_
    ) OracleAttestationConsumer(IMD.ATTESTER) {
        if (policyWord >> 240 != 0) revert InvalidValue();
        OracleConfig memory o;
        o.intake = IMD.INTAKE;
        o.delivery = IMD.INTAKE_DELIVERY;
        o.signer = IMD.ATTESTER;
        o.asset = IMD.IMD_TOKEN;
        o.action = action_;
        o.questionChain = uint32(policyWord);
        o.fromBlock = uint48(policyWord >> 32);
        o.toBlock = uint48(policyWord >> 80);
        o.maxPrice = uint96(policyWord >> 128);
        o.questions = [eventQuestion, regulatorQuestion];
        o.bodies = [eventBody, regulatorBody];
        BindingConfig memory b;
        b.factory = IMD.PROJECT_FACTORY;
        b.heartbeatBps = uint16(policyWord >> 224);
        b.heartbeatCap = 1 ether;
        b.gameConfigHash = gameConfigHash_;
        if (
            o.action == bytes32(0) || o.maxPrice == 0 || o.questionChain == 0 || o.toBlock < o.fromBlock
                || o.questions[0] == bytes32(0) || o.questions[1] == bytes32(0) || o.questions[0] == o.questions[1]
                || o.bodies[0] == bytes32(0) || o.bodies[1] == bytes32(0) || b.gameConfigHash == bytes32(0)
                || b.heartbeatBps < 200 || b.heartbeatBps > 5000
        ) revert InvalidValue();
        config = o;
        binding = b;
    }

    function oracleConfig() external view returns (OracleConfig memory) {
        return config;
    }

    function bindingConfig() external view returns (BindingConfig memory) {
        return binding;
    }

    /// @notice Permissionless one-time binding with bind-time proofs: the ProjectFactory admits each launch
    /// once and only from its deployer, so the recorded coordinates plus pinned creation code identify the
    /// only Registry/Params it can have created. The frozen roots/snapshot/endowment must match the
    /// commitment and Params must point back to this Desk. No launch number is known at construction.
    function bind(
        address candidate,
        bytes calldata registryCode,
        bytes calldata paramsCode,
        uint64 registryLaunch,
        uint8 registryIndex,
        uint64 paramsLaunch,
        uint8 paramsIndex
    ) external {
        if (address(registry) != address(0)) revert AlreadyDone();
        if (registryLaunch == 0 || paramsLaunch == 0 || registryIndex >= 8 || paramsIndex >= 8) revert InvalidValue();
        if (!SwarmCode.isRegistry(keccak256(registryCode)) || !SwarmCode.isParams(keccak256(paramsCode))) {
            revert InvalidProof();
        }
        ISwarmRegistry r = ISwarmRegistry(candidate);
        if (
            r.factory() != binding.factory
                || keccak256(abi.encode(r.starterRoot(), r.freeRoot(), r.snapshotBlock(), r.endowment()))
                    != binding.gameConfigHash
        ) revert InvalidProof();
        address p = _proveParams(paramsLaunch, paramsIndex, paramsCode);
        if (r.params() != p) revert InvalidProof();
        if (_predictRegistry(r, p, registryLaunch, registryIndex, registryCode) != candidate) revert InvalidProof();
        if (candidate.code.length == 0) revert InvalidProof();
        // v3.14 (audit a8730286 M): the registry's market must be a launch hook of this Desk for the registry's
        // token and this game configuration. A twin naming a foreign market or token is refused; an EOA market
        // reverts on the probe.
        IBoundHook h = IBoundHook(r.market());
        if (h.desk() != address(this) || h.token() != r.token() || h.gameConfigHash() != binding.gameConfigHash) {
            revert InvalidProof();
        }
        binding.registryLaunch = registryLaunch;
        binding.registryIndex = registryIndex;
        binding.paramsLaunch = paramsLaunch;
        binding.paramsIndex = paramsIndex;
        registry = r;
        emit Bound(candidate);
    }

    function _proveParams(uint64 launch, uint8 index, bytes calldata code) private view returns (address p) {
        bytes memory initCode =
            bytes.concat(code, abi.encode(address(this), binding.heartbeatBps, binding.heartbeatCap));
        p = ISwarmFactory(binding.factory).predictContract(launch, index, initCode);
        if (p.code.length == 0 || Params(p).swarmWallet() != address(this)) revert InvalidProof();
    }

    function _predictRegistry(ISwarmRegistry r, address p, uint64 launch, uint8 index, bytes calldata code)
        private
        view
        returns (address)
    {
        bytes memory args =
            abi.encode(r.token(), p, r.market(), r.starterRoot(), r.freeRoot(), r.snapshotBlock(), r.endowment());
        return ISwarmFactory(binding.factory).predictContract(launch, index, bytes.concat(code, args));
    }

    function slot(uint8 stream) public view returns (uint256) {
        if (stream > 1) revert InvalidValue();
        return block.timestamp / (stream == 0 ? 6 hours : 7 days);
    }

    function _period(uint8 stream) private pure returns (uint256) {
        return stream == 0 ? 6 hours : 7 days;
    }

    /// @notice Anyone can donate IMD. No withdrawal exists. One paid backup per stream/slot, after one hour.
    /// The keeper provides only bytes whose hash was frozen at deployment, never a question of their choice.
    function askBackup(uint8 stream, bytes calldata body) external nonReentrant returns (bytes32 id) {
        uint256 s = slot(stream);
        if (address(registry) == address(0)) revert NotConfigured();
        if (body.length > 16384 || keccak256(body) != config.bodies[stream]) revert InvalidProof();
        if (
            askedSlotPlusOne[stream] == s + 1 || acceptedSlotPlusOne[stream] == s + 1
                || block.timestamp < s * _period(stream) + 1 hours
        ) revert TooEarly();
        uint256 price = ISwarmIntake(config.intake).priceOf(config.action, config.asset);
        if (price == 0 || price > config.maxPrice) revert InvalidValue();
        askedSlotPlusOne[stream] = s + 1;
        IERC20(config.asset).forceApprove(config.intake, price);
        id = ISwarmIntake(config.intake)
            .requestWithFailure(
                config.action,
                body,
                ISwarmIntake.Callback(address(this), this.onOracleResult.selector),
                this.onOracleFailure.selector,
                config.asset,
                price
            );
        IERC20(config.asset).forceApprove(config.intake, 0);
        if (id == bytes32(0) || pending[id].streamPlusOne != 0) revert InvalidValue();
        uint256 deadline = block.timestamp + 1 hours;
        uint256 end = (s + 1) * _period(stream);
        if (deadline > end) deadline = end;
        pending[id] = Pending(uint64(s), uint64(deadline), stream + 1);
        emit BackupAsked(stream, s, id, price);
    }

    function onOracleResult(bytes32 intakeId, OracleAttestation.Attestation calldata a, bytes calldata signature)
        external
    {
        bool direct = msg.sender == config.intake;
        if (!direct && msg.sender != config.delivery) revert Unauthorized();
        _accept(direct, msg.sender, intakeId, a, signature);
    }

    /// @notice v3.8 heartbeat relay. Schedules bought on Ethereum with consumer {4663, this Desk} produce an
    /// attestation served over HTTP; anyone relays it here. Exactly the checks of a delivered result apply:
    /// attester signature in this Desk's domain, pinned question, context window, panel, slot/epoch
    /// freshness and once per oracle UUID. The relayer has no authority: the bytes are the attester's.
    function submit(OracleAttestation.Attestation calldata a, bytes calldata signature) external {
        _accept(false, address(0), a.requestId, a, signature);
    }

    function _accept(
        bool direct,
        address source,
        bytes32 intakeId,
        OracleAttestation.Attestation calldata a,
        bytes calldata signature
    ) private {
        if (address(registry) == address(0)) revert NotConfigured();
        uint8 stream;
        if (a.questionHash == config.questions[0]) stream = 0;
        else if (a.questionHash == config.questions[1]) stream = 1;
        else revert InvalidProof();
        Pending memory p = pending[intakeId];
        bytes32 deliveryKey = keccak256(abi.encode(source, intakeId));
        if (consumed[a.requestId] || delivered[deliveryKey]) {
            emit AnswerIgnored(a.requestId, 1);
            return;
        }
        if (intakeId == bytes32(0) || a.requestId == bytes32(0)) revert InvalidValue();
        if (direct && p.streamPlusOne != stream + 1) revert InvalidProof();
        if (
            a.chainId != config.questionChain || a.fromBlock != config.fromBlock || a.toBlock != config.toBlock
                || a.panelSize < 5 || a.quorum < 4 || a.agreed < a.quorum || a.agreed > a.panelSize
                || a.quorum > a.panelSize
        ) revert InvalidValue();
        // _verifyAttestation rejects expired; return early for stale results without accepting/acting on them.
        if (
            a.expiresAt < block.timestamp || uint256(a.issuedAt) + (stream == 0 ? 6 hours : 1 days) < block.timestamp
                || (direct && block.timestamp >= p.deadline)
        ) {
            emit AnswerIgnored(a.requestId, 2);
            return;
        }
        _verifyAttestation(a, signature);
        if (a.answerType != OracleAttestation.ANSWER_BYTES32_LIST) revert InvalidValue();
        // Exact ABI size bounds prevent storage/gas griefing before decoding.
        if (a.answer.length != (stream == 0 ? 288 : 608)) revert InvalidValue();
        bytes32[] memory values = abi.decode(a.answer, (bytes32[]));
        if (values.length != (stream == 0 ? 7 : 17)) revert InvalidValue();
        uint256 s = slot(stream);
        if (
            uint256(values[0]) != s || a.issuedAt / _period(stream) != s || (direct && p.slot != s)
                || acceptedSlotPlusOne[stream] == s + 1
        ) {
            emit AnswerIgnored(a.requestId, 2);
            return;
        }
        if (stream == 0 && uint256(values[1]) != IRewards(registry.module(1)).epoch()) {
            emit AnswerIgnored(a.requestId, 2);
            return;
        }
        _consume(a.requestId);
        delivered[deliveryKey] = true;
        acceptedSlotPlusOne[stream] = s + 1;
        if (direct) delete pending[intakeId];
        uint256 end = (s + 1) * _period(stream);
        uint256 until = uint256(a.issuedAt) + (stream == 0 ? 6 hours : 1 days);
        if (until > a.expiresAt) until = a.expiresAt;
        if (until > end) until = end;
        lastAnswer[stream] = Result(
            keccak256(a.answer), a.requestId, a.issuedAt, uint64(until), uint64(s), true, uint48(ChainClock.number())
        );
        emit AnswerStored(stream, a.requestId, s, a.answer);
    }

    function onOracleFailure(bytes32 id, uint8 status, bytes32 reason, uint16, uint16, bytes calldata) external {
        if (msg.sender == config.delivery) {
            emit OracleFailure(id, status, reason);
            return;
        }
        if (msg.sender != config.intake) revert Unauthorized();
        if (pending[id].streamPlusOne == 0 || (status != 1 && status != 2)) revert InvalidValue();
        delete pending[id];
        lastFailure = reason;
        emit OracleFailure(id, status, reason);
    }

    function clearExpired(bytes32 id) external {
        Pending memory p = pending[id];
        if (p.streamPlusOne == 0 || block.timestamp < p.deadline) revert TooEarly();
        delete pending[id];
        emit OracleFailure(id, 0, bytes32("timeout"));
    }

    function execute(uint8 stream, bytes calldata answer) external nonReentrant {
        if (stream > 1) revert InvalidValue();
        Result storage r = lastAnswer[stream];
        if (!r.pending || keccak256(answer) != r.answerHash) revert InvalidProof();
        r.pending = false;
        if (block.timestamp >= r.validUntil || r.slot != slot(stream)) {
            emit AnswerIgnored(r.requestId, 2);
            return;
        }
        bytes32[] memory v = abi.decode(answer, (bytes32[]));
        bytes32 letter = v[stream == 0 ? 6 : 16];
        lastLetterHash = letter;
        string memory notice = Strings.toHexString(uint256(letter), 32);
        if (stream == 0) _event(v, notice);
        else _regulate(v, notice);
        emit Executed(stream, r.requestId, letter);
    }

    function _clamp(uint256 n, uint256 lo, uint256 hi) private pure returns (uint256) {
        return n < lo ? lo : n > hi ? hi : n;
    }

    function _event(bytes32[] memory v, string memory notice) private {
        GridOperator grid = GridOperator(registry.module(7));
        uint256 base = uint256(v[1]);
        uint256 current = IRewards(registry.module(1)).epoch();
        if (current > base + 1 || current < base) return;
        uint256 maxKind = Civic(registry.module(12)).enabled(7) ? 9 : 7;
        uint8 kind = uint8(_clamp(uint256(v[2]), 0, maxKind));
        // v3.8: the swarm chooses kind and severity within a safe band instead of a fixed 9000.
        uint16 severity = uint16(_clamp(uint256(v[3]), SEVERITY_MIN, SEVERITY_MAX));
        districtHint = uint8(_clamp(uint256(v[4]), 0, 7)); // Advisory only; preserve weighted district/entropy rules.
        lastEventEpoch = base;
        for (uint256 e = base + 1; e <= base + 2; ++e) {
            if (e <= current || grid.planAt(e).submitted) continue;
            grid.submitPlan(e, GridOperator.Kind(kind), severity, v[5], notice);
        }
    }

    function _regulate(bytes32[] memory v, string memory notice) private {
        Params params = Params(registry.params());
        for (uint256 i; i < 8; ++i) {
            uint256 packed = uint256(v[i + 1]);
            uint256 key = packed >> 248;
            if (key == 0 || key > 45) continue; // v3.14: an unknown key is skipped, never clamped onto RepairHours
            uint256 target = packed & type(uint248).max;
            Params.Key k = Params.Key(key - 1);
            uint256 old = params.get(k);
            (uint256 lo, uint256 hi) = params.bounds(k);
            target = _clamp(_clamp(target, lo, hi), old - old / 10, old + old / 10);
            if (target == old || block.timestamp < params.lastChanged(k) + 1 days) continue;
            params.set(k, target, notice);
        }
        Civic civic = Civic(registry.module(12));
        if (v[9] != 0) {
            uint256 feature = _clamp(uint256(v[9]), 1, 8) - 1;
            if (civic.noticeAt(feature) == 0) civic.announce(feature, notice);
        }
        Enhancement enhancement = Enhancement(registry.module(11));
        if (v[10] != 0 && enhancement.announcedCap() == 0 && enhancement.cap() < 16) {
            enhancement.announceCap(enhancement.cap() == 8 ? 12 : 16, notice);
        }
        // Optional old swarm duties, independently tried so a busy dormant module cannot block notices.
        if (uint256(v[11]) >> 128 != 0) {
            try civic.grantDistrictBoost(
                _clamp(uint256(v[11]) >> 128, 1, 8) - 1,
                uint16(_clamp(uint256(v[11]) & type(uint128).max, 0, 1500)),
                notice
            ) {}
            catch (bytes memory reason) {
                emit ActionSkipped(0, reason);
            }
        }
        PackSale packs = PackSale(registry.module(4));
        if (uint256(v[12]) == 1) {
            packs.unpause();
        } else if (uint256(v[12]) > 1) {
            try packs.pause(_clamp(uint256(v[12]) - 1, 1, 72 hours)) {}
            catch (bytes memory reason) {
                emit ActionSkipped(1, reason);
            }
        }
        if (uint256(v[13]) >> 128 != 0 && uint128(uint256(v[13])) != 0) {
            try civic.startWar(
                uint8(_clamp(uint256(v[13]) >> 128, 1, 8) - 1),
                uint8(_clamp(uint256(v[13]) & type(uint128).max, 1, 8) - 1)
            ) {}
            catch (bytes memory reason) {
                emit ActionSkipped(2, reason);
            }
        }
        if (v[14] != 0) {
            uint256 daily = Economy(registry.module(10)).averageDaily();
            try civic.startCollapse(_clamp(uint256(v[14]), daily, daily * 100)) {}
            catch (bytes memory reason) {
                emit ActionSkipped(3, reason);
            }
        }
        if (uint256(v[15]) >> 16 != 0) {
            try civic.listLot(
                uint8(_clamp(uint256(v[15]) >> 16, 1, 12) - 1),
                uint8(_clamp((uint256(v[15]) >> 8) & 255, 1, 3)),
                uint8(_clamp(uint256(v[15]) & 255, 1, 3))
            ) {}
            catch (bytes memory reason) {
                emit ActionSkipped(4, reason);
            }
        }
    }
}
