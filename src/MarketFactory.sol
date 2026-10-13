// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {V4Market} from "./V4Market.sol";
import "./lib/Errors.sol";

/// @notice Optional permissionless CREATE2 factory for the hook's address-bit requirement.
contract MarketFactory {
    struct Config {
        address manager;
        address token;
        int24 tickSpacing;
        address launcher;
        address desk;
        bytes32 gameConfigHash;
    }
    event MarketDeployed(address indexed market, bytes32 indexed salt);

    function initCodeHash(Config calldata c) public pure returns (bytes32) {
        return keccak256(
            bytes.concat(
                type(V4Market).creationCode,
                abi.encode(c.manager, c.token, uint24(12500), c.tickSpacing, c.launcher, c.desk, c.gameConfigHash)
            )
        );
    }

    function predict(Config calldata c, bytes32 salt) public view returns (address) {
        return
            address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, initCodeHash(c))))));
    }

    function findSalt(Config calldata c, uint256 start, uint256 attempts)
        external
        view
        returns (bytes32 salt, address target)
    {
        if (attempts == 0 || attempts > 1_000_000) revert InvalidValue();
        bytes32 hash = initCodeHash(c);
        bytes memory preimage = abi.encodePacked(bytes1(0xff), address(this), bytes32(start), hash);
        for (uint256 i; i < attempts; ++i) {
            salt = bytes32(start + i);
            bytes32 digest;
            assembly ("memory-safe") {
                mstore(add(preimage, 53), salt)
                digest := keccak256(add(preimage, 32), 85)
            }
            target = address(uint160(uint256(digest)));
            if (uint160(target) & 0x3fff == 0x10cc) return (salt, target);
        }
        revert NotConfigured();
    }

    function deploy(Config calldata c, bytes32 salt) external returns (V4Market market) {
        address target = predict(c, salt);
        if (uint160(target) & 0x3fff != 0x10cc) revert InvalidAddress();
        if (target.code.length != 0) return V4Market(payable(target));
        market =
            new V4Market{salt: salt}(c.manager, c.token, 12500, c.tickSpacing, c.launcher, c.desk, c.gameConfigHash);
        emit MarketDeployed(address(market), salt);
    }
}
