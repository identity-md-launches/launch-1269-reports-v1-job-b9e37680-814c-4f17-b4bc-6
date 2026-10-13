// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {Test, console2} from "forge-std/Test.sol";
import {SwarmDesk} from "../../src/SwarmDesk.sol";
import {SwarmArgs} from "../../script/SwarmArgs.sol";
import {SwarmCode} from "../../src/lib/SwarmCode.sol";
import {ModuleCode} from "../../src/lib/ModuleCode.sol";
import {EndowmentEscrow} from "../../src/EndowmentEscrow.sol";
import {GameRegistry} from "../../src/GameRegistry.sol";
import {Params} from "../../src/Params.sol";
import {RewardPool} from "../../src/RewardPool.sol";
import {FarmRewards} from "../../src/FarmRewards.sol";
import {PackSale} from "../../src/PackSale.sol";
import {FeeRouter} from "../../src/FeeRouter.sol";
import {GridOperator} from "../../src/GridOperator.sol";
import {V4Market} from "../../src/V4Market.sol";
import {IMD} from "../../src/lib/IMD.sol";
import {MockAttester} from "../mocks/MockAttester.sol";
import {IArbSys} from "../../src/lib/ChainClock.sol";
import {OracleAttestation} from "../../src/oracle/OracleAttestation.sol";
import {IV4PoolManager, PoolKey, SwapParams} from "../../src/interfaces/IV4.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../../src/lib/Errors.sol";

/// @dev ABI of the live IMD factories on Robinhood Chain (4663), recovered from their runtime selectors and the
/// calldata of recorded launches 1271 (evm_contracts) and 1316 (univ4_hook). Sources are unverified.
struct PlatformAttestation {
    bytes32 kind;
    uint64 launchNumber;
    uint64 reserved;
    bytes32 commit;
    bytes32 hashA;
    bytes32 hashB;
    bytes32 hashC;
    string repo;
}

struct ContractsLaunch {
    uint64 launchNumber;
    bytes[] initCodes;
    bytes32[] names;
    address[] expected;
    PlatformAttestation attestation;
    uint256[] opcodes;
}

struct HookLaunch {
    uint64 launchNumber;
    bytes32 kind;
    bytes tokenInitCode;
    bytes hookInitCode;
    bytes32 hookSalt;
    uint160 hookFlags;
    uint256 totalSupply;
    uint16 poolBps;
    address remainderTo;
    bytes32 distributorRoot;
    uint64 claimDelay;
    uint64 claimWindow;
    address pairCurrency;
    uint24 fee;
    int24 tickSpacing;
    uint160 sqrtPriceX96;
    int24 tickLower;
    int24 tickUpper;
    uint128 liquidity;
    PlatformAttestation attestation;
    uint256[] opcodes;
    address requester;
}

interface IProjectFactory {
    function launchContracts(ContractsLaunch calldata l) external;
    function predictContract(uint64 launchNumber, uint256 index, bytes calldata initCode)
        external
        view
        returns (address);
    function deployer() external view returns (address);
}

interface IProjectRecords {
    function isRecorded(uint64 launchNumber) external view returns (bool);
}

interface ILaunchFactory {
    function launch(HookLaunch calldata l) external payable;
    function predictToken(uint64 launchNumber, bytes calldata initCode) external view returns (address);
    function predictHook(bytes calldata initCode, bytes32 salt) external view returns (address);
    function claimFees(uint64 launchNumber) external;
    function poolManager() external view returns (address);
    function deployer() external view returns (address);
}

/// @title BLACKOUT v3.11 fork rehearsal of launch-v39.md steps M1–M13 on a Robinhood Chain (4663) fork.
/// @notice Skips unless the test runs against a 4663 fork (`tools/rehearse_v311.sh` starts an anvil fork and
/// points forge at it). Nothing is broadcast: every call is executed in the local fork only. The platform
/// deployer is impersonated where the platform would deploy or initialize. Test roots, a test attester key and
/// throw-away launch numbers are used; production roots never appear here.
contract RehearsalV311Test is Test {
    IProjectFactory internal constant PF = IProjectFactory(0x9C9D2FCB75c2C132C0AC0C42DF3819A42347265e);
    IProjectRecords internal constant PFR = IProjectRecords(0xF52bbE066B7Ad2d28C2195D066Ea08DCbcA88406);
    ILaunchFactory internal constant LF = ILaunchFactory(0xA25B02A1e93903b790E6aaf7dA1b8B8d50294645);
    address internal constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address internal constant INTAKE = 0xa43e6F75ee006411F79Ac1C84120606C2330DE82;
    address internal constant DELIVERY = 0xCE0E6a670AA75E161d02aca3C7F00B94cA428CCb;
    address internal constant IMD_ASSET = 0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127;
    address internal constant TEAM = 0x6d51cBE774aeAe4dd40bCA2560E9bc2695A0d007;
    address internal constant ARBSYS = address(100);
    uint256 internal constant ENDOWMENT = 200_000_000 ether;
    uint160 internal constant HOOK_FLAGS = 0x10cc;
    uint256 internal constant TEST_ATTESTER_KEY = 0xB1AC0007;
    /// @dev Throw-away launch numbers, asserted unrecorded on the fork before use.
    uint64 internal constant N_DESK = 777001;
    uint64 internal constant N_ESCROW = 777002;
    uint64 internal constant N_TOKEN = 777003;
    uint64 internal constant N_A = 777004;
    uint64 internal constant N_B = 777005;

    struct State {
        address deployer;
        bytes32 starterRoot;
        bytes32 freeRoot;
        uint256 snapshotBlock;
        bytes32 gameConfigHash;
        SwarmDesk desk;
        EndowmentEscrow escrow;
        address token;
        V4Market hook;
        Params params;
        GameRegistry registry;
        address[8] jobA;
        address[8] jobB;
        uint256 l2Block;
        uint256 gasDesk;
        uint256 gasEscrow;
        uint256 gasToken;
        uint256 gasJobA;
        uint256 gasJobB;
    }

    State internal s;
    bool internal forked;
    uint256 internal nonce;

    function setUp() public {
        if (block.chainid != 4663) return;
        forked = true;
        s.deployer = PF.deployer();
        assertEq(LF.deployer(), s.deployer, "both factories share the launch wallet");
        assertEq(LF.poolManager(), POOL_MANAGER, "PoolManager of the LaunchFactory");
        s.starterRoot = keccak256("v3.11 rehearsal starter root (throw-away)");
        s.freeRoot = keccak256("v3.11 rehearsal free-pack root (throw-away)");
        s.snapshotBlock = 23_400_000;
        s.gameConfigHash = keccak256(abi.encode(s.starterRoot, s.freeRoot, s.snapshotBlock, ENDOWMENT));
        _mockClock(1_000_000);
        vm.deal(s.deployer, 100 ether);
        vm.deal(address(this), 1000 ether);
        console2.log("== BLACKOUT v3.11 fork rehearsal, chain", block.chainid, "fork block", block.number);
        console2.log("deployer (impersonated)", s.deployer);
        console2.log("gameConfigHash (test roots)", vm.toString(s.gameConfigHash));
        for (uint64 n = N_DESK; n <= N_B; ++n) {
            assertFalse(PFR.isRecorded(n), "throw-away launch number already recorded");
        }
        _m1Desk();
        _m2Escrow();
        _m3Token();
        _m4JobA();
        _m5Bind();
        _m6Register();
        _m7JobB();
        _m8BindRouter();
        _m9Forward();
        _m10Fund();
    }

    // ───────────────────────────── platform helpers ─────────────────────────────

    function _attestation(bytes32 kind, uint64 n) internal pure returns (PlatformAttestation memory a) {
        a.kind = kind;
        a.launchNumber = n;
        a.commit = keccak256("v3.11 rehearsal commit");
        a.hashA = keccak256(abi.encode("a", n));
        a.hashB = keccak256(abi.encode("b", n));
        a.hashC = keccak256(abi.encode("c", n));
        a.repo = "https://github.com/identity-md-launches/launch-1269-reports-v1-job-b9e37680-814c-4f17-b4bc-6";
    }

    /// @dev Deploys `initCodes` through the real ProjectFactory as the platform would, returns gas used.
    function _launchContracts(uint64 n, bytes[] memory initCodes, string[] memory names)
        internal
        returns (address[] memory deployed, uint256 gasUsed)
    {
        ContractsLaunch memory l;
        l.launchNumber = n;
        l.initCodes = initCodes;
        l.names = new bytes32[](initCodes.length);
        l.expected = new address[](initCodes.length);
        for (uint256 i; i < initCodes.length; ++i) {
            l.names[i] = bytes32(bytes(names[i]));
            l.expected[i] = PF.predictContract(n, i, initCodes[i]);
        }
        l.attestation = _attestation(bytes32("evm_contracts"), n);
        l.opcodes = new uint256[](0);
        vm.prank(s.deployer);
        uint256 g = gasleft();
        PF.launchContracts(l);
        gasUsed = g - gasleft();
        assertTrue(PFR.isRecorded(n), "launch recorded");
        deployed = l.expected;
        for (uint256 i; i < deployed.length; ++i) {
            assertGt(deployed[i].code.length, 0, "deployed at predicted address");
            console2.log(string.concat("  [", vm.toString(i), "] ", names[i]), deployed[i]);
            console2.log("      creationCodeHash", vm.toString(keccak256(initCodes[i])));
        }
        console2.log("  launchContracts gas", gasUsed, "wei at basefee", gasUsed * block.basefee);
    }

    function _oracle() internal view returns (SwarmDesk.OracleConfig memory o) {
        o.intake = INTAKE;
        o.delivery = DELIVERY;
        o.signer = IMD.ATTESTER; // fixed in bytecode; the fork test vouches for its key through an ERC-1271 stand-in
        o.asset = IMD_ASSET;
        o.action = bytes32("oracle.request@oracle-1");
        o.maxPrice = 0.5 ether;
        o.questionChain = 1;
        o.fromBlock = 26122900;
        o.toBlock = 26122901;
        // Pinned question/body hashes of docs/oracle-v37/oracle-config.json.
        o.questions = [
            bytes32(0x2fc5a57f2c5f7bc083ea8ac5016234f1a0b1c68a514e5d921956cc57948534ef),
            bytes32(0xc13efed8438aab53ea052a4507def2dc4ce9856765520dfa28c66daa59cfc11d)
        ];
        o.bodies = [
            bytes32(0x00e69e4445c7ca7256338293f9f9cea439fd2beb1959d1d43ebec7b14493e2f6),
            bytes32(0xc0ae7511b06744cf7ccadc6b60ff9ff96cb7234cf32988850df33324861cc8df)
        ];
    }

    // ───────────────────────────── M1–M10 ─────────────────────────────

    function _m1Desk() internal {
        console2.log("M1 SwarmDesk bootstrap via ProjectFactory, launch", N_DESK);
        // Fork only: the real attester key is not available, so an ERC-1271 stand-in at the constant attester
        // address vouches for the throw-away test key (never done on a live chain).
        vm.etch(IMD.ATTESTER, address(new MockAttester(vm.addr(TEST_ATTESTER_KEY))).code);
        SwarmDesk.BindingConfig memory b =
            SwarmDesk.BindingConfig(address(PF), 0, 0, 0, 0, s.gameConfigHash, 200, 1 ether);
        bytes memory args = SwarmArgs.encode(_oracle(), b);
        assertEq(args.length, 7 * 32, "seven static constructor words (v3.14)");
        bytes[] memory codes = new bytes[](1);
        codes[0] = bytes.concat(type(SwarmDesk).creationCode, args);
        string[] memory names = new string[](1);
        names[0] = "SwarmDesk";
        (address[] memory d, uint256 g) = _launchContracts(N_DESK, codes, names);
        s.gasDesk = g;
        s.desk = SwarmDesk(d[0]);
        assertEq(address(s.desk.registry()), address(0), "unbound");
        assertEq(s.desk.bindingConfig().gameConfigHash, s.gameConfigHash);
        assertEq(s.desk.oracleConfig().signer, IMD.ATTESTER, "the attester is fixed in bytecode (v3.14)");
        console2.log("  check Desk.registry() == 0: ok; attester (fork only)", vm.addr(TEST_ATTESTER_KEY));
    }

    function _m2Escrow() internal {
        console2.log("M2 EndowmentEscrow via ProjectFactory, launch", N_ESCROW);
        bytes[] memory codes = new bytes[](1);
        codes[0] = bytes.concat(type(EndowmentEscrow).creationCode, abi.encode(address(s.desk)));
        string[] memory names = new string[](1);
        names[0] = "EndowmentEscrow";
        (address[] memory d, uint256 g) = _launchContracts(N_ESCROW, codes, names);
        s.gasEscrow = g;
        s.escrow = EndowmentEscrow(d[0]);
        assertEq(s.escrow.factory(), address(PF));
        assertEq(s.escrow.records(), address(PFR));
        assertEq(s.escrow.desk(), address(s.desk));
        assertFalse(s.escrow.forwarded());
    }

    function _hookInitCode(address token) internal view returns (bytes memory) {
        return bytes.concat(
            type(V4Market).creationCode,
            abi.encode(POOL_MANAGER, token, uint24(12500), int24(60), address(LF), address(s.desk), s.gameConfigHash)
        );
    }

    function _mineHookSalt(bytes memory initCode) internal view returns (bytes32 salt, address hook) {
        bytes32 h = keccak256(initCode);
        for (uint256 i;; ++i) {
            salt = bytes32((uint256(N_TOKEN) << 192) | i);
            hook = vm.computeCreate2Address(salt, h, address(LF));
            if (uint160(hook) & 0x3fff == HOOK_FLAGS) break;
        }
    }

    function _m3Token() internal {
        console2.log("M3 token launch via LaunchFactory (univ4_hook), launch", N_TOKEN);
        bytes memory tokenCode = _platformTokenInitCode();
        s.token = LF.predictToken(N_TOKEN, tokenCode);
        bytes memory hookCode = _hookInitCode(s.token);
        (bytes32 salt, address predictedHook) = _mineHookSalt(hookCode);
        assertEq(LF.predictHook(hookCode, salt), predictedHook, "LaunchFactory.predictHook agrees with CREATE2");
        HookLaunch memory l;
        l.launchNumber = N_TOKEN;
        l.kind = bytes32("univ4_hook");
        l.tokenInitCode = tokenCode;
        l.hookInitCode = hookCode;
        l.hookSalt = salt;
        l.hookFlags = HOOK_FLAGS;
        l.totalSupply = 1_000_000_000 ether;
        l.poolBps = 7000;
        l.remainderTo = address(s.escrow);
        l.distributorRoot = keccak256("v3.11 rehearsal swarm distributor root");
        l.claimDelay = 3600;
        l.claimWindow = 365 days;
        // Pair currency: ETH (address(0)). Every recorded 4663 hook launch so far (1015, 1300, 1316) was paired
        // with IMD; the policy's ETH pairing opens at 10 ETH FDV, i.e. 1e8 tokens per ETH: sqrtPriceX96 = 1e4 * 2^96,
        // tick 184206. Single-sided token liquidity sits below the price (token is currency1), tick spacing 60.
        l.pairCurrency = address(0);
        l.fee = 12500;
        l.tickSpacing = 60;
        l.sqrtPriceX96 = uint160(10_000 << 96);
        l.tickLower = -887220;
        l.tickUpper = 184200;
        l.liquidity = 7.0e22; // ~699.76M of the 700M pool tokens at this range
        l.attestation = _attestation(bytes32("univ4_hook"), N_TOKEN);
        l.opcodes = new uint256[](0);
        l.requester = TEAM;
        vm.prank(s.deployer);
        uint256 g = gasleft();
        LF.launch(l);
        s.gasToken = g - gasleft();
        s.hook = V4Market(payable(predictedHook));
        console2.log("  token", s.token);
        console2.log("  hook", predictedHook, "salt", vm.toString(salt));
        console2.log("  launch gas", s.gasToken, "wei at basefee", s.gasToken * block.basefee);
        assertGt(s.token.code.length, 0, "token deployed");
        assertGt(predictedHook.code.length, 0, "hook deployed at mined address");
        // Reality check: the LaunchFactory sends remainderTo the 20% plus whatever the liquidity position did not
        // consume of the 70%, so the escrow holds at least the endowment (the runbook's M3/M9 checks say >=).
        uint256 escrowBalance = IERC20(s.token).balanceOf(address(s.escrow));
        assertGe(escrowBalance, ENDOWMENT, "remainderTo received at least 20%");
        console2.log("  escrow balance", escrowBalance, "surplus over endowment", escrowBalance - ENDOWMENT);
        assertEq(s.hook.launcher(), address(LF));
        assertEq(s.hook.poolFee(), 12500);
        assertEq(s.hook.desk(), address(s.desk));
        assertEq(s.hook.gameConfigHash(), s.gameConfigHash);
        assertEq(s.hook.initializedAt(), block.timestamp, "afterInitialize ran with sender == LaunchFactory");
        assertEq(address(s.hook.fees()), address(0), "router unbound until M8");
        console2.log("  check escrow balance >= 200,000,000e18: ok; initializedAt", s.hook.initializedAt());
    }

    function _m4JobA() internal {
        console2.log("M4 job A via ProjectFactory, launch", N_A);
        bytes[] memory codes = new bytes[](8);
        string[] memory names = new string[](8);
        codes[0] = bytes.concat(type(Params).creationCode, abi.encode(address(s.desk), uint256(200), uint256(1 ether)));
        names[0] = "Params";
        address params = PF.predictContract(N_A, 0, codes[0]);
        codes[1] = bytes.concat(
            type(GameRegistry).creationCode,
            abi.encode(s.token, params, address(s.hook), s.starterRoot, s.freeRoot, s.snapshotBlock, ENDOWMENT)
        );
        names[1] = "GameRegistry";
        address registry = PF.predictContract(N_A, 1, codes[1]);
        string[6] memory modules = ["RewardPool", "FarmRewards", "FarmCore", "FarmItems", "PackSale", "StarterClaim"];
        for (uint256 i; i < 6; ++i) {
            codes[i + 2] = bytes.concat(_moduleCode(modules[i]), abi.encode(registry));
            names[i + 2] = modules[i];
        }
        (address[] memory d, uint256 g) = _launchContracts(N_A, codes, names);
        s.gasJobA = g;
        s.params = Params(d[0]);
        s.registry = GameRegistry(d[1]);
        for (uint256 i; i < 8; ++i) {
            s.jobA[i] = d[i];
        }
        assertEq(s.registry.params(), address(s.params));
        assertEq(s.registry.token(), s.token);
        assertEq(s.registry.market(), address(s.hook));
        assertEq(s.params.swarmWallet(), address(s.desk));
        _checkPins(codes);
    }

    /// @dev Attested creation-code hashes against the pins the Desk, hook, Registry and escrow enforce.
    function _checkPins(bytes[] memory codes) internal view {
        bytes32 p = keccak256(type(Params).creationCode);
        bytes32 r = keccak256(type(GameRegistry).creationCode);
        assertTrue(SwarmCode.isParams(p), "Params creation code pinned");
        assertTrue(SwarmCode.isRegistry(r), "GameRegistry creation code pinned");
        bool launchToolchain = r == SwarmCode.REGISTRY_LAUNCH;
        console2.log(launchToolchain ? "  toolchain: IMD launch (viaIR false)" : "  toolchain: repository (via-IR)");
        for (uint256 i; i < 6; ++i) {
            bytes32 h = keccak256(_stripArgs(codes[i + 2]));
            assertTrue(ModuleCode.matches(i, h), "module creation code pinned");
            assertEq(h, launchToolchain ? ModuleCode.launchHash(i) : ModuleCode.repoHash(i), "pin of this toolchain");
        }
    }

    function _stripArgs(bytes memory initCode) internal pure returns (bytes memory code) {
        code = new bytes(initCode.length - 32);
        for (uint256 i; i < code.length; ++i) {
            code[i] = initCode[i];
        }
    }

    function _moduleCode(string memory name) internal view returns (bytes memory) {
        return vm.getCode(string.concat(name, ".sol:", name));
    }

    function _m5Bind() internal {
        console2.log("M5 Desk.bind (permissionless)");
        // Failure: a contract that is not the recorded registry at these coordinates is refused.
        vm.expectRevert();
        s.desk.bind(address(s.escrow), type(GameRegistry).creationCode, type(Params).creationCode, N_A, 1, N_A, 0);
        // Failure: the right registry at the wrong coordinates is refused.
        vm.expectRevert(InvalidProof.selector);
        s.desk.bind(address(s.registry), type(GameRegistry).creationCode, type(Params).creationCode, N_A, 2, N_A, 0);
        s.desk.bind(address(s.registry), type(GameRegistry).creationCode, type(Params).creationCode, N_A, 1, N_A, 0);
        assertEq(address(s.desk.registry()), address(s.registry), "Desk.registry() == job A registry");
        vm.expectRevert(AlreadyDone.selector);
        s.desk.bind(address(s.registry), type(GameRegistry).creationCode, type(Params).creationCode, N_A, 1, N_A, 0);
        console2.log("  check Desk.registry() == REGISTRY: ok", address(s.registry));
    }

    function _m6Register() internal {
        console2.log("M6 register roles 0-5 with launch", N_A);
        string[6] memory modules = ["RewardPool", "FarmRewards", "FarmCore", "FarmItems", "PackSale", "StarterClaim"];
        for (uint256 i; i < 6; ++i) {
            address m = s.registry.register(i, N_A, i + 2, _moduleCode(modules[i]));
            assertEq(m, s.jobA[i + 2], "registered job A module");
            assertEq(s.registry.module(i), s.jobA[i + 2]);
        }
        // Failure: a second registration of a taken role is refused.
        vm.expectRevert(AlreadyDone.selector);
        s.registry.register(0, N_A, 2, _moduleCode("RewardPool"));
        console2.log("  check module(0..5) == job A addresses: ok");
    }

    function _m7JobB() internal {
        console2.log("M7 job B via ProjectFactory, launch", N_B);
        string[8] memory modules =
            ["FeeRouter", "GridOperator", "Season", "FarmEngine", "Economy", "Enhancement", "Civic", "Billboards"];
        bytes[] memory codes = new bytes[](8);
        string[] memory names = new string[](8);
        for (uint256 i; i < 8; ++i) {
            codes[i] = bytes.concat(_moduleCode(modules[i]), abi.encode(address(s.registry)));
            names[i] = modules[i];
        }
        (address[] memory d, uint256 g) = _launchContracts(N_B, codes, names);
        s.gasJobB = g;
        for (uint256 i; i < 8; ++i) {
            s.jobB[i] = d[i];
            bytes32 h = keccak256(_moduleCode(modules[i]));
            assertTrue(ModuleCode.matches(i + 6, h), "job B creation code pinned");
            assertEq(s.registry.register(i + 6, N_B, i, _moduleCode(modules[i])), d[i]);
            assertEq(s.registry.module(i + 6), d[i]);
        }
        assertEq(s.registry.registered(), 14, "all fourteen roles registered");
        console2.log("  check module(6..13) == job B addresses: ok");
    }

    function _m8BindRouter() internal {
        console2.log("M8 V4Market.bindFeeRouter (permissionless)");
        vm.expectRevert(NotConfigured.selector);
        s.hook.flushFees();
        // Failure: a module that is not the FeeRouter is refused.
        vm.expectRevert(InvalidValue.selector);
        s.hook.bindFeeRouter(s.jobB[1], N_A, 1);
        s.hook.bindFeeRouter(s.jobB[0], N_A, 1);
        assertEq(address(s.hook.fees()), s.jobB[0], "hook.fees() == FeeRouter");
        assertEq(address(s.hook.params()), address(s.params), "hook.params() == Params");
        vm.expectRevert(InsufficientBalance.selector);
        s.hook.flushFees(); // configured, nothing held yet
        console2.log("  check fees()/params(): ok", s.jobB[0]);
    }

    function _m9Forward() internal {
        console2.log("M9 EndowmentEscrow.forward (permissionless)");
        bytes memory poolCode = _moduleCode("RewardPool");
        // Failure: wrong pool coordinates are refused.
        vm.expectRevert(InvalidProof.selector);
        s.escrow.forward(address(s.registry), N_A, 1, type(GameRegistry).creationCode, N_A, 3, poolCode);
        uint256 amount =
            s.escrow.forward(address(s.registry), N_A, 1, type(GameRegistry).creationCode, N_A, 2, poolCode);
        assertGe(amount, ENDOWMENT, "full balance forwarded");
        assertTrue(s.escrow.forwarded());
        assertEq(IERC20(s.token).balanceOf(address(s.escrow)), 0);
        assertEq(IERC20(s.token).balanceOf(s.jobA[2]), amount, "RewardPool holds the whole forwarded balance");
        vm.expectRevert(AlreadyDone.selector);
        s.escrow.forward(address(s.registry), N_A, 1, type(GameRegistry).creationCode, N_A, 2, poolCode);
        console2.log("  check forwarded, pool balance 200,000,000e18: ok", s.jobA[2]);
    }

    function _m10Fund() internal {
        console2.log("M10 RewardPool.fundEndowment (permissionless)");
        RewardPool pool = RewardPool(s.jobA[2]);
        pool.fundEndowment();
        assertTrue(pool.endowed());
        assertEq(pool.lockedEndowment(), ENDOWMENT, "all locked at funding");
        assertEq(pool.dripPeriod(), s.params.get(Params.Key.DripPeriod));
        vm.expectRevert(AlreadyDone.selector);
        pool.fundEndowment();
        console2.log("  check endowed, drip period", pool.dripPeriod());
    }

    // ───────────────────────────── swaps ─────────────────────────────

    receive() external payable {}

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == POOL_MANAGER);
        (bool buy, uint256 amount) = abi.decode(data, (bool, uint256));
        int256 delta = IV4PoolManager(POOL_MANAGER)
            .swap(
                s.hook.key(),
                SwapParams(buy, -int256(amount), buy ? 4295128740 : 1461446703485210103287273052203988822378723970341),
                ""
            );
        int128 a = int128(delta >> 128);
        int128 b = int128(delta);
        if (a < 0) IV4PoolManager(POOL_MANAGER).settle{value: uint256(-int256(a))}();
        else if (a > 0) IV4PoolManager(POOL_MANAGER).take(address(0), address(this), uint256(uint128(a)));
        if (b < 0) {
            IV4PoolManager(POOL_MANAGER).sync(s.token);
            IERC20(s.token).transfer(POOL_MANAGER, uint256(-int256(b)));
            IV4PoolManager(POOL_MANAGER).settle();
        } else if (b > 0) {
            IV4PoolManager(POOL_MANAGER).take(s.token, address(this), uint256(uint128(b)));
        }
        return abi.encode(delta);
    }

    function _swap(bool buy, uint256 amount) internal returns (int256 delta) {
        delta = abi.decode(IV4PoolManager(POOL_MANAGER).unlock(abi.encode(buy, amount)), (int256));
    }

    function _buyAt(uint256 minutesAfter, uint256 expectedBps) internal {
        vm.warp(s.hook.initializedAt() + minutesAfter * 60);
        uint256 held = s.hook.heldLaunchTax();
        uint256 base = s.hook.heldBase();
        _swap(true, 1 ether);
        if (expectedBps > 100) {
            assertEq(s.hook.heldLaunchTax() - held, expectedBps * 1 ether / 10000, "stepped launch tax");
            assertEq(s.hook.heldBase(), base, "no base stream during the launch window");
        } else {
            assertEq(s.hook.heldLaunchTax(), held, "launch window over");
            assertEq(s.hook.heldBase() - base, 0.01 ether, "exactly 1% to rewards");
        }
        console2.log("  buy 1 ETH at +min", minutesAfter, "tax bps", s.hook.currentBuyTaxBps());
    }

    function _mockClock(uint256 n) internal {
        s.l2Block = n;
        vm.mockCall(ARBSYS, abi.encodeCall(IArbSys.arbBlockNumber, ()), abi.encode(n));
    }

    function _revealHash(uint256 target) internal {
        vm.mockCall(ARBSYS, abi.encodeCall(IArbSys.arbBlockHash, (target)), abi.encode(keccak256(abi.encode(target))));
    }

    // ───────────────────────────── tests ─────────────────────────────

    function testRehearsalLaunchTaxThenOnePercentAndSurcharge() public {
        if (!forked) return vm.skip(true);
        console2.log("Swaps through the real PoolManager", POOL_MANAGER);
        _buyAt(5, 9000);
        _buyAt(15, 5000);
        _buyAt(25, 2500);
        _buyAt(31, 100);
        assertEq(s.hook.heldLaunchTax(), 1.65 ether, "90% + 50% + 25% of three 1 ETH buys");
        uint256 tokens = IERC20(s.token).balanceOf(address(this));
        assertGt(tokens, 0);
        uint256 baseBefore = s.hook.heldBase();
        // An hour later the buy volume has left the hourly window, so a sell is net sell pressure.
        vm.warp(block.timestamp + 61 minutes);
        _swap(false, tokens / 2);
        uint256 baseDelta = s.hook.heldBase() - baseBefore;
        assertGt(baseDelta, 0, "1% base on the sell output");
        assertGt(s.hook.heldSellTax(), 0, "progressive sell surcharge");
        assertLe(s.hook.storedFeeWad(), 1500 ether, "surcharge cap 15%");
        console2.log("  sell: base", baseDelta, "surcharge", s.hook.heldSellTax());
        FeeRouter router = FeeRouter(payable(s.jobB[0]));
        uint256 direct = s.hook.heldBase() + s.hook.heldLaunchTax();
        uint256 total = direct + s.hook.heldSellTax();
        s.hook.flushFees();
        assertGe(router.rewardETH(), direct, "launch tax and the 1% stream are reward ETH in full");
        assertEq(address(router).balance, total, "surcharge routed by the FeeRouter split");
        console2.log("  flushFees -> FeeRouter.rewardETH", router.rewardETH());
    }

    function testRehearsalPacksOpenOneHourAfterLaunch() public {
        if (!forked) return vm.skip(true);
        PackSale packs = PackSale(s.jobA[6]);
        // Reality: a pack sale records into the live epoch, so the keeper's first advanceEpoch (allowed from the
        // pool initialization on) must land before packs open at +1h.
        FarmRewards(s.jobA[3]).advanceEpoch();
        vm.warp(s.hook.initializedAt() + 31 minutes);
        _swap(true, 1 ether);
        IERC20(s.token).approve(address(packs), type(uint256).max);
        assertFalse(packs.isOpen());
        vm.expectRevert(TooEarly.selector);
        packs.openPack(1);
        vm.warp(s.hook.initializedAt() + 1 hours);
        assertTrue(packs.isOpen());
        assertTrue(packs.ready(), "profile, endowment and router all ready");
        uint256 price = packs.price();
        assertLe(price, IERC20(s.token).balanceOf(address(this)), "one buy covers the first pack");
        uint256 id = packs.openPack(1);
        console2.log("  first pack at +1h, id", id, "price", price);
        // Entropy: the commit targets ArbSys block + 2; reveal and resolve.
        _mockClock(s.l2Block + 3);
        _revealHash(s.l2Block - 1);
        packs.captureEntropy(id);
        console2.log("  pack entropy captured at L2 block", s.l2Block);
    }

    function testRehearsalAttestedAnswerChangesPlanWithinBand() public {
        if (!forked) return vm.skip(true);
        FarmRewards rewards = FarmRewards(s.jobA[3]);
        GridOperator grid = GridOperator(s.jobB[1]);
        rewards.advanceEpoch();
        uint256 epoch = rewards.epoch();
        assertEq(epoch, 1);
        vm.warp((block.timestamp / 6 hours) * 6 hours + 1 hours);
        bytes32[] memory v = new bytes32[](7);
        v[0] = bytes32(s.desk.slot(0));
        v[1] = bytes32(epoch);
        v[2] = bytes32(uint256(1));
        v[3] = bytes32(uint256(9999)); // above the band: clamped to 7000
        v[4] = bytes32(uint256(3));
        v[5] = keccak256("oracle salt");
        v[6] = keccak256("letter");
        OracleAttestation.Attestation memory a = _attest(0, abi.encode(v));
        // Failure: a signature from another key is refused.
        (uint8 fv, bytes32 fr, bytes32 fs) = vm.sign(0xBAD, s.desk.attestationDigest(a));
        vm.expectRevert();
        s.desk.submit(a, abi.encodePacked(fr, fs, fv));
        (uint8 sv, bytes32 sr, bytes32 ss) = vm.sign(TEST_ATTESTER_KEY, s.desk.attestationDigest(a));
        address relayer = makeAddr("anyone");
        vm.prank(relayer);
        s.desk.submit(a, abi.encodePacked(sr, ss, sv));
        (,,,,, bool pendingResult,) = s.desk.lastAnswer(0);
        assertTrue(pendingResult, "answer stored");
        s.desk.execute(0, abi.encode(v));
        GridOperator.Plan memory p = grid.planAt(epoch + 1);
        assertTrue(p.submitted);
        assertGe(p.severity, 5000);
        assertLe(p.severity, 7000);
        assertEq(p.severity, 7000, "clamped to the Desk band");
        assertTrue(grid.planAt(epoch + 2).submitted);
        console2.log("  SwarmDesk.submit relayed by", relayer, "plan severity", p.severity);
        // Replay of the same UUID is ignored, not executed twice.
        vm.recordLogs();
        s.desk.submit(a, abi.encodePacked(sr, ss, sv));
        assertEq(vm.getRecordedLogs().length, 1, "AnswerIgnored only");
    }

    function _attest(uint8 stream, bytes memory answer) internal returns (OracleAttestation.Attestation memory a) {
        SwarmDesk.OracleConfig memory o = s.desk.oracleConfig();
        a.requestId = keccak256(abi.encode("uuid", ++nonce));
        a.chainId = o.questionChain;
        a.questionHash = o.questions[stream];
        a.answerType = 5;
        a.answer = answer;
        a.fromBlock = o.fromBlock;
        a.toBlock = o.toBlock;
        a.blockHash = keccak256("anchor");
        a.panelJobId = keccak256("panel");
        a.panelSize = 5;
        a.quorum = 4;
        a.agreed = 5;
        a.issuedAt = uint64(block.timestamp);
        a.expiresAt = uint64(block.timestamp + 6 hours);
    }

    function testRehearsalKeeperPassAdvancesEpochsRevealsEntropyAndClaimFeesPaysTeam() public {
        if (!forked) return vm.skip(true);
        FarmRewards rewards = FarmRewards(s.jobA[3]);
        GridOperator grid = GridOperator(s.jobB[1]);
        address keeper = makeAddr("keeper");
        vm.prank(keeper);
        rewards.advanceEpoch();
        assertEq(rewards.epoch(), 1);
        vm.expectRevert(TooEarly.selector);
        rewards.advanceEpoch();
        vm.warp(rewards.epochEnd());
        _mockClock(s.l2Block + 10);
        _revealHash(s.l2Block - 9); // shift() targeted l2Block + 1
        vm.prank(keeper);
        rewards.advanceEpoch();
        assertEq(rewards.epoch(), 2, "epoch advanced");
        (,,, bytes32 seed, bool resolved) = rewards.eventAt(1);
        assertTrue(resolved, "entropy revealed and event resolved");
        assertTrue(seed != bytes32(0));
        console2.log("  keeper pass: epoch 2, event 1 resolved, seed", vm.toString(seed));
        assertEq(grid.planAt(1).submitted, false, "no plan: fallback table");

        // M13: the platform LP fee is claimed to the paying wallet.
        vm.warp(s.hook.initializedAt() + 31 minutes);
        _swap(true, 2 ether);
        uint256 teamBefore = TEAM.balance;
        LF.claimFees(N_TOKEN);
        uint256 paid = TEAM.balance - teamBefore;
        assertGt(paid, 0, "paying wallet received the platform 1%");
        // 1.25% LP fee on ~1.98 ETH net input, 80% of it to the requester: about 0.0198 ETH.
        assertApproxEqRel(paid, 0.0198 ether, 0.05e18, "about 1% of swap volume");
        console2.log("  LaunchFactory.claimFees paid the paying wallet wei", paid);
    }

    function testRehearsalGasPerLaunchUnderPlatformCeiling() public {
        if (!forked) return vm.skip(true);
        uint256 ceiling = 0.01 ether;
        uint256 basefee = block.basefee;
        console2.log("gas: Desk", s.gasDesk, "Escrow", s.gasEscrow);
        console2.log("gas: token+hook", s.gasToken, "jobA", s.gasJobA);
        console2.log("gas: jobB", s.gasJobB, "basefee wei", basefee);
        uint256[5] memory g = [s.gasDesk, s.gasEscrow, s.gasToken, s.gasJobA, s.gasJobB];
        for (uint256 i; i < 5; ++i) {
            uint256 cost = (g[i] + 21_000) * basefee;
            console2.log("  launch", i, "cost wei at fork basefee", cost);
            assertLt(cost, ceiling, "under the 0.01 ETH per-launch ceiling at the fork basefee");
        }
        // Headroom: the largest launch still fits at this multiple of the fork basefee.
        uint256 largest = s.gasJobA > s.gasJobB ? s.gasJobA : s.gasJobB;
        console2.log("  largest launch fits up to basefee wei", ceiling / (largest + 21_000));
    }

    /// @dev Exact token initcode the LaunchFactory deployed for launch 1316 (plain ERC-20, mints 1e27 to the
    /// caller). The platform supplies this code; BLACKOUT only consumes the token.
    function _platformTokenInitCode() internal pure returns (bytes memory) {
        return hex"608060405234801561000f575f80fd5b50610026336b033b2e3c9fd0803ce800000061002b565b6101b3565b6001600160a01b0382166100595760405163ec442f0560e01b81525f60048201526024015b60405180910390fd5b6100645f8383610068565b5050565b6001600160a01b038316610092578060025f828254610087919061018e565b909155506101029050565b6001600160a01b0383165f90815260208190526040902054818110156100e45760405163391434e360e21b81526001600160a01b03851660048201526024810182905260448101839052606401610050565b6001600160a01b0384165f9081526020819052604090209082900390555b6001600160a01b03821661011e5760028054829003905561013c565b6001600160a01b0382165f9081526020819052604090208054820190555b816001600160a01b0316836001600160a01b03167fddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef8360405161018191815260200190565b60405180910390a3505050565b808201808211156101ad57634e487b7160e01b5f52601160045260245ffd5b92915050565b610627806101c05f395ff3fe608060405234801561000f575f80fd5b506004361061009b575f3560e01c806370a082311161006357806370a0823114610132578063902d55a51461015a57806395d89b411461016d578063a9059cbb14610192578063dd62ed3e146101a5575f80fd5b806306fdde031461009f578063095ea7b3146100db57806318160ddd146100fe57806323b872dd14610110578063313ce56714610123575b5f80fd5b60408051808201909152600e81526d494d44204d6f6e6579204261636b60901b60208201525b6040516100d291906104f8565b60405180910390f35b6100ee6100e9366004610548565b6101dd565b60405190151581526020016100d2565b6002545b6040519081526020016100d2565b6100ee61011e366004610570565b6101f5565b604051601281526020016100d2565b6101026101403660046105aa565b6001600160a01b03165f9081526020819052604090205490565b6101026b033b2e3c9fd0803ce800000081565b6040805180820190915260098152684d4f4e45594241434b60b81b60208201526100c5565b6100ee6101a0366004610548565b610216565b6101026101b33660046105ca565b6001600160a01b039182165f90815260016020908152604080832093909416825291909152205490565b5f6101eb3384846001610222565b5060015b92915050565b5f6102018433846102fa565b61020c848484610370565b5060019392505050565b5f6101eb338484610370565b6001600160a01b0384166102505760405163e602df0560e01b81525f60048201526024015b60405180910390fd5b6001600160a01b03831661027957604051634a1406b160e11b81525f6004820152602401610247565b6001600160a01b038085165f90815260016020908152604080832093871683529290522082905580156102f457826001600160a01b0316846001600160a01b03167f8c5be1e5ebec7d5bd14f71427d1e84f3dd0314c0f7b2291e5b200ac8c7c3b925846040516102eb91815260200190565b60405180910390a35b50505050565b6001600160a01b038084165f908152600160209081526040808320938616835292905220545f198110156102f4578181101561036257604051637dc7a0d960e11b81526001600160a01b03841660048201526024810182905260448101839052606401610247565b6102f484848484035f610222565b6001600160a01b03831661039957604051634b637e8f60e11b81525f6004820152602401610247565b6001600160a01b0382166103c25760405163ec442f0560e01b81525f6004820152602401610247565b6103cd8383836103d2565b505050565b6001600160a01b0383166103fc578060025f8282546103f191906105fb565b9091555061046c9050565b6001600160a01b0383165f908152602081905260409020548181101561044e5760405163391434e360e21b81526001600160a01b03851660048201526024810182905260448101839052606401610247565b6001600160a01b0384165f9081526020819052604090209082900390555b6001600160a01b038216610488576002805482900390556104a6565b6001600160a01b0382165f9081526020819052604090208054820190555b816001600160a01b0316836001600160a01b03167fddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef836040516104eb91815260200190565b60405180910390a3505050565b602081525f82518060208401528060208501604085015e5f604082850101526040601f19601f83011684010191505092915050565b80356001600160a01b0381168114610543575f80fd5b919050565b5f8060408385031215610559575f80fd5b6105628361052d565b946020939093013593505050565b5f805f60608486031215610582575f80fd5b61058b8461052d565b92506105996020850161052d565b929592945050506040919091013590565b5f602082840312156105ba575f80fd5b6105c38261052d565b9392505050565b5f80604083850312156105db575f80fd5b6105e48361052d565b91506105f26020840161052d565b90509250929050565b808201808211156101ef57634e487b7160e01b5f52601160045260245ffdfea164736f6c634300081a000a";
    }
}
