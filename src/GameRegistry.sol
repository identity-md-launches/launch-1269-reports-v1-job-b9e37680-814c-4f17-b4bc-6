// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {ILaunchHook} from "./interfaces/ILaunchHook.sol";
import {IGameRegistry} from "./interfaces/IGameRegistry.sol";
import {ModuleCode} from "./lib/ModuleCode.sol";
import {IMD} from "./lib/IMD.sol";
import "./lib/Errors.sol";

interface IApplicationFactory {
    function predictContract(uint64 launchNumber, uint256 index, bytes calldata initCode)
        external
        view
        returns (address);
}

/// @notice No owner and no replacements. Enrollment proves canonical factory deployment of exact initcode.
/// @dev v3.9: each role accepts the creation code of either pinned toolchain (the IMD verifier's build and
/// the repository's build of the same source); see ModuleCode.
contract GameRegistry is IGameRegistry {
    address public immutable token;
    address public immutable params;
    address public immutable market;

    bytes32 public immutable starterRoot;
    bytes32 public immutable freeRoot;
    uint256 public immutable snapshotBlock;
    uint256 public immutable endowment;
    /// @notice The IMD ProjectFactory, fixed in bytecode (v3.14, src/lib/IMD.sol): never a constructor word.
    IApplicationFactory public constant factory = IApplicationFactory(IMD.PROJECT_FACTORY);
    mapping(uint256 => address) private modules;
    uint256 public registered;
    event Registered(uint256 indexed role, address indexed module, uint64 launchNumber, uint256 index);

    constructor(
        address token_,
        address params_,
        address market_,
        bytes32 root_,
        bytes32 freeRoot_,
        uint256 snapshot_,
        uint256 endowment_
    ) {
        if (
            token_ == address(0) || params_ == address(0) || market_ == address(0) || freeRoot_ == bytes32(0)
                || root_ == bytes32(0) || snapshot_ == 0 || endowment_ > 250_000_000 ether
        ) revert InvalidValue();
        token = token_;
        params = params_;
        market = market_;
        starterRoot = root_;
        freeRoot = freeRoot_;
        snapshotBlock = snapshot_;
        endowment = endowment_;
    }

    function launchTime() external view returns (uint256) {
        uint256 t = ILaunchHook(market).initializedAt();
        if (t == 0) revert NotConfigured();
        return t;
    }

    function module(uint256 role) external view returns (address result) {
        result = modules[role];
        if (result == address(0)) revert NotConfigured();
    }

    function registeredModule(uint256 role) external view returns (address) {
        return modules[role];
    }

    /// @notice The launch toolchain's pin (IMD verifier settings) for a role.
    function creationCodeHash(uint256 role) external pure returns (bytes32) {
        if (role >= 14) revert InvalidValue();
        return ModuleCode.launchHash(role);
    }

    /// @notice Both pins for a role: the launch toolchain's and the repository toolchain's.
    function creationCodeHashes(uint256 role) external pure returns (bytes32 launch, bytes32 repo) {
        if (role >= 14) revert InvalidValue();
        return (ModuleCode.launchHash(role), ModuleCode.repoHash(role));
    }

    function acceptsCreationCode(uint256 role, bytes32 codeHash) external pure returns (bool) {
        return role < 14 && ModuleCode.matches(role, codeHash);
    }

    /// @dev Runtime hash alone cannot prove safe initial storage. CREATE2 over exact initcode can.
    function register(uint256 role, uint64 launchNumber, uint256 index, bytes calldata creationCode)
        external
        returns (address deployed)
    {
        if (role >= 14 || index >= 8 || launchNumber == 0 || !ModuleCode.matches(role, keccak256(creationCode))) {
            revert InvalidValue();
        }
        if (modules[role] != address(0)) revert AlreadyDone();
        deployed = factory.predictContract(launchNumber, index, bytes.concat(creationCode, abi.encode(address(this))));
        if (deployed.code.length == 0) revert NotConfigured();
        modules[role] = deployed;
        registered++;
        emit Registered(role, deployed, launchNumber, index);
    }
}
