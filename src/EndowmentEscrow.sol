// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IGameRegistry} from "./interfaces/IGameRegistry.sol";
import {SwarmCode} from "./lib/SwarmCode.sol";
import {ModuleCode} from "./lib/ModuleCode.sol";
import {IMD} from "./lib/IMD.sol";
import "./lib/Errors.sol";

interface IEscrowFactory {
    function predictContract(uint64 launchNumber, uint256 index, bytes calldata initCode)
        external
        view
        returns (address);
}

interface IEscrowRecords {
    function isRecorded(uint64 launchNumber) external view returns (bool);
}

interface IEscrowRegistry is IGameRegistry {
    function factory() external view returns (address);
}

interface IEscrowDesk {
    function registry() external view returns (address);
}

interface IEscrowParams {
    function swarmWallet() external view returns (address);
}

/// @notice v3.8 remainderTo target of the token launch. Ownerless, no withdrawal, one exit only:
/// forward the whole balance of the canonical game's token to its authenticated RewardPool, once.
/// @dev Deployed after the SwarmDesk bootstrap and before the token launch, so it needs no launch
/// number: the canonical game is the one the pinned Desk bound to, proven at forward time with the
/// ProjectFactory's CREATE2 prediction, its launch record and the pinned Registry/RewardPool code
/// (either toolchain pin, see ModuleCode).
contract EndowmentEscrow is ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice The IMD ProjectFactory and its launch registry, fixed in bytecode (v3.14, src/lib/IMD.sol).
    address public constant factory = IMD.PROJECT_FACTORY;
    address public constant records = IMD.PROJECT_RECORDS;
    address public immutable desk;
    bool public forwarded;
    event Forwarded(address indexed registry, address indexed pool, address indexed token, uint256 amount);

    /// @param desk_ the SwarmDesk of the same launch ($contract:SwarmDesk).
    constructor(address desk_) {
        if (desk_ == address(0) || desk_ == factory || desk_ == records) revert InvalidValue();
        desk = desk_;
    }

    /// @notice Permissionless. Proves `registry` is the canonical factory-deployed GameRegistry the pinned
    /// Desk bound to, that its RewardPool was deployed by the factory from the pinned creation code, then
    /// sends the entire token balance there. Nothing else can ever move the balance.
    function forward(
        address registry,
        uint64 registryLaunch,
        uint256 registryIndex,
        bytes calldata registryCode,
        uint64 poolLaunch,
        uint256 poolIndex,
        bytes calldata poolCode
    ) external nonReentrant returns (uint256 amount) {
        if (forwarded) revert AlreadyDone();
        if (registryLaunch == 0 || registryIndex >= 8 || poolLaunch == 0 || poolIndex >= 8) revert InvalidValue();
        if (!SwarmCode.isRegistry(keccak256(registryCode)) || !ModuleCode.matches(0, keccak256(poolCode))) {
            revert InvalidProof();
        }
        if (IEscrowDesk(desk).registry() != registry) revert InvalidProof();
        IEscrowRegistry r = IEscrowRegistry(registry);
        if (r.factory() != factory || IEscrowParams(r.params()).swarmWallet() != desk) revert InvalidProof();
        if (!IEscrowRecords(records).isRecorded(registryLaunch) || !IEscrowRecords(records).isRecorded(poolLaunch)) {
            revert InvalidProof();
        }
        _proveRegistry(r, registryLaunch, registryIndex, registryCode);
        address pool = _provePool(registry, poolLaunch, poolIndex, poolCode);
        IERC20 token = IERC20(r.token());
        amount = token.balanceOf(address(this));
        if (amount == 0) revert InsufficientBalance();
        forwarded = true;
        token.safeTransfer(pool, amount);
        emit Forwarded(registry, pool, address(token), amount);
    }

    function _proveRegistry(IEscrowRegistry r, uint64 launch, uint256 index, bytes calldata code) private view {
        bytes memory args = abi.encode(
            r.token(), r.params(), r.market(), r.starterRoot(), r.freeRoot(), r.snapshotBlock(), r.endowment()
        );
        if (IEscrowFactory(factory).predictContract(launch, index, bytes.concat(code, args)) != address(r)) {
            revert InvalidProof();
        }
    }

    function _provePool(address registry, uint64 launch, uint256 index, bytes calldata code)
        private
        view
        returns (address pool)
    {
        pool = IEscrowRegistry(registry).module(0);
        bytes memory initCode = bytes.concat(code, abi.encode(registry));
        if (pool.code.length == 0 || IEscrowFactory(factory).predictContract(launch, index, initCode) != pool) {
            revert InvalidProof();
        }
    }
}
