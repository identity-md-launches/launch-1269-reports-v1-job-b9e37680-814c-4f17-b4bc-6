// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {PoolKey, SwapParams, IV4PoolManager} from "../../src/interfaces/IV4.sol";
import {GameRegistry} from "../../src/GameRegistry.sol";
import {StandardMarket} from "../../src/StandardMarket.sol";
import {V4Market} from "../../src/V4Market.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract TestV4Market is V4Market {
    constructor(address manager_, address token_, address desk_, bytes32 config_)
        V4Market(manager_, token_, 12500, 60, msg.sender, desk_, config_)
    {}
    function _validateHookAddress() internal pure override {}

    /// @dev Fixtures bind a second canonical-code registry whose market is this hook while the fixture Desk
    /// stays bound to the mock-market registry. Every other proof (coordinates, Params, config) is real.
    function _canonical(GameRegistry) internal pure override returns (bool) {
        return true;
    }
}

/// @dev Full v3.8 proof including the Desk binding, for adversarial tests.
contract StrictTestV4Market is V4Market {
    constructor(address manager_, address token_, address desk_, bytes32 config_)
        V4Market(manager_, token_, 12500, 60, msg.sender, desk_, config_)
    {}
    function _validateHookAddress() internal pure override {}
}

contract MockV4Manager is IV4PoolManager {
    uint160 public sqrtPrice = uint160(1 << 96);
    address private unlockedBy;

    function setSqrt(uint160 p) external {
        sqrtPrice = p;
    }

    function extsload(bytes32) external view returns (bytes32) {
        return bytes32(uint256(sqrtPrice));
    }

    function initializeHook(V4Market hook) external {
        hook.afterInitialize(msg.sender, hook.key(), sqrtPrice, 0);
    }

    function invokeBefore(V4Market hook, SwapParams memory p) external returns (bytes4, int256, uint24) {
        return hook.beforeSwap(msg.sender, hook.key(), p, "");
    }

    function invokeAfter(V4Market hook, SwapParams memory p, int256 delta) external returns (bytes4, int128) {
        return hook.afterSwap(msg.sender, hook.key(), p, delta, "");
    }

    function unlock(bytes calldata data) external returns (bytes memory) {
        unlockedBy = msg.sender;
        bytes memory result = V4Market(payable(msg.sender)).unlockCallback(data);
        unlockedBy = address(0);
        return result;
    }

    function swap(PoolKey memory, SwapParams memory p, bytes calldata) external view returns (int256) {
        require(msg.sender == unlockedBy);
        uint256 input = uint256(-p.amountSpecified);
        uint256 output = input;
        if (!p.zeroForOne) return (int256(output) << 128) | int256(uint256(uint128(-int128(int256(input)))));
        return (int256(-int128(int256(input))) << 128) | int256(output);
    }

    function take(address currency, address to, uint256 amount) external {
        if (currency == address(0)) {
            (bool ok,) = to.call{value: amount}("");
            require(ok);
        } else {
            IERC20(currency).transfer(to, amount);
        }
    }

    function sync(address) external {}

    function settle() external payable returns (uint256) {
        return msg.value;
    }
}

/// @dev Real flag validation and real PoolManager path; only the fixture's two-registry Desk relaxation.
contract IntegrationV4Market is V4Market {
    constructor(
        address manager_,
        address token_,
        uint24 fee_,
        int24 spacing_,
        address launcher_,
        address desk_,
        bytes32 config_
    ) V4Market(manager_, token_, fee_, spacing_, launcher_, desk_, config_) {}

    function _canonical(GameRegistry) internal pure override returns (bool) {
        return true;
    }
}

contract IntegrationStandardMarket is StandardMarket {
    constructor(
        address manager_,
        address token_,
        uint24 fee_,
        int24 spacing_,
        address launcher_,
        address desk_,
        bytes32 config_
    ) StandardMarket(manager_, token_, fee_, spacing_, launcher_, desk_, config_) {}

    function _canonical(GameRegistry) internal pure override returns (bool) {
        return true;
    }
}
