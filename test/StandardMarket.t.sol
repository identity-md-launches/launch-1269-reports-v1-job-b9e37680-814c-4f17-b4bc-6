// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {BaseTest} from "./Base.t.sol";
import {GameRegistry} from "../src/GameRegistry.sol";
import {StandardMarket} from "../src/StandardMarket.sol";
import {FeeRouter} from "../src/FeeRouter.sol";
import {MockV4Manager} from "./mocks/MockV4Manager.sol";
import {SwapParams} from "../src/interfaces/IV4.sol";

contract TestStandardMarket is StandardMarket {
    constructor(address m, address t, address k, bytes32 c) StandardMarket(m, t, 12500, 60, msg.sender, k, c) {}
    function _validateHookAddress() internal pure override {}

    function _canonical(GameRegistry) internal pure override returns (bool) {
        return true;
    }
}

contract StandardMarketTest is BaseTest {
    TestStandardMarket private hook;
    MockV4Manager private manager;
    FeeRouter private fees;

    function setUp() public override {
        super.setUp();
        manager = new MockV4Manager();
        hook = new TestStandardMarket(address(manager), address(token), address(desk), bindingConfigHash());
        fees = canonicalFees(address(hook));
        vm.prank(team);
        bindHook(hook, address(fees));
        vm.deal(address(manager), 1000 ether);
        token.transfer(address(manager), 1000 ether);
        manager.initializeHook(hook);
        vm.warp(launch + 60 minutes);
    }

    function testStandardBuyOnePercentAllToRewards() public {
        (, int256 fee,) = manager.invokeBefore(hook, SwapParams(true, -int256(1 ether), 4295128740));
        assertEq(uint256(fee >> 128), 0.01 ether);
        if (hook.heldBase() + hook.heldSellTax() != 0) hook.flushFees();
        assertEq(fees.credit(team), 0);
        assertEq(fees.rewardETH(), 0.01 ether);
        assertEq(fees.heartbeatBalance(), 0);
    }

    function testFuzzStandardSellNeverAddsProgressiveSurcharge(uint96 amount) public {
        uint256 output = bound(amount, 1, 100 ether);
        manager.setSqrt(uint160(4 << 96));
        SwapParams memory p = SwapParams(false, -int256(1 ether), type(uint160).max - 1);
        manager.invokeBefore(hook, p);
        int256 delta = int256(output << 128) | int256(uint256(uint128(type(uint128).max - 1)));
        (, int128 fee) = manager.invokeAfter(hook, p, delta);
        assertEq(uint256(uint128(fee)), output * 100 / 10000);
        assertEq(fees.heartbeatBalance(), 0);
        if (hook.heldBase() + hook.heldSellTax() != 0) hook.flushFees();
        assertEq(fees.credit(team), 0);
        assertEq(fees.rewardETH(), output * 100 / 10000);
    }
}
