// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {GameRegistry, IApplicationFactory} from "../src/GameRegistry.sol";
import {RewardPool} from "../src/RewardPool.sol";
import "../src/lib/Errors.sol";

/// @notice Read-only prediction helper, with explicit accepted launch configuration. Never broadcasts.
contract PredictGame {
    struct Config {
        address factory;
        address token;
        address params;
        address hook;
        bytes32 starterRoot;
        bytes32 freeRoot;
        uint256 snapshotBlock;
        uint256 endowment;
        uint64 registryLaunch;
        uint256 registryIndex;
        uint64 poolLaunch;
        uint256 poolIndex;
    }

    function commitment(Config memory c) public pure returns (bytes32) {
        return keccak256(
            abi.encode(
                c.params, c.starterRoot, c.freeRoot, c.snapshotBlock, c.endowment, c.registryLaunch, c.registryIndex
            )
        );
    }

    function predict(Config memory c) external view returns (address registry, address remainderTo) {
        if (
            c.factory == address(0) || c.token == address(0) || c.params == address(0) || c.hook == address(0)
                || c.freeRoot == bytes32(0) || c.starterRoot == bytes32(0) || c.snapshotBlock == 0 || c.endowment == 0
                || c.endowment > 250_000_000 ether || c.registryLaunch == 0 || c.poolLaunch == 0 || c.registryIndex >= 8
                || c.poolIndex >= 8
        ) revert InvalidValue();
        bytes memory registryCode = bytes.concat(
            type(GameRegistry).creationCode,
            abi.encode(c.token, c.params, c.hook, c.starterRoot, c.freeRoot, c.snapshotBlock, c.endowment)
        );
        registry = IApplicationFactory(c.factory).predictContract(c.registryLaunch, c.registryIndex, registryCode);
        remainderTo = IApplicationFactory(c.factory)
            .predictContract(
                c.poolLaunch, c.poolIndex, bytes.concat(type(RewardPool).creationCode, abi.encode(registry))
            );
    }
}
