// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {BaseTest} from "./Base.t.sol";
import {TestV4Market, MockV4Manager} from "./mocks/MockV4Manager.sol";
import {PoolKey, SwapParams} from "../src/interfaces/IV4.sol";
import {FeeRouter} from "../src/FeeRouter.sol";
import {V4Market} from "../src/V4Market.sol";
import "../src/lib/Errors.sol";

contract MarketTest is BaseTest {
    MockV4Manager internal manager;
    TestV4Market internal hook;

    function setUp() public override {
        super.setUp();
        manager = new MockV4Manager();
        hook = new TestV4Market(address(manager), address(token), address(desk), bindingConfigHash());
        d.fees = canonicalFees(address(hook));
        vm.prank(team);
        bindHook(hook, address(d.fees));
        vm.deal(address(manager), 10000 ether);
        token.transfer(address(manager), 10000 ether);
        manager.initializeHook(hook);
    }

    function sell(uint256 ethOut) internal returns (uint256 charged) {
        SwapParams memory p = SwapParams(false, -int256(1 ether), type(uint160).max - 1);
        manager.invokeBefore(hook, p);
        int256 delta = (int256(ethOut) << 128) | int256(uint256(uint128(type(uint128).max - 1)));
        (, int128 fee) = manager.invokeAfter(hook, p, delta);
        return uint256(uint128(fee));
    }

    function testTwapWarmupAndFlashManipulationResistance() public {
        vm.expectRevert(NotConfigured.selector);
        hook.quote(1 ether);
        vm.warp(launch + 31 minutes);
        assertEq(hook.quote(1 ether), 0.977625 ether); // 0.99 x 0.9875: hook 1% and pool 1.25% (v3.14)
        manager.setSqrt(uint160(2 << 96));
        sell(5 ether);
        assertEq(hook.quote(1 ether), 0.977625 ether); // 0.99 x 0.9875: hook 1% and pool 1.25% (v3.14)
        assertEq(hook.lastPrice(), 4 ether);
        vm.warp(vm.getBlockTimestamp() + 31 minutes);
        assertEq(hook.quote(1 ether), 3.9105 ether); // 3.96 x 0.9875
    }

    function testSingleDumpIncludesItselfAndFeeDecaysWithoutGriefReset() public {
        vm.warp(launch + 31 minutes);
        manager.setSqrt(uint160(2 << 96));
        uint256 fee = sell(5 ether);
        assertGt(fee, 5 ether * 1000 / 10000);
        assertLe(fee, 5 ether * 1500 / 10000);
        uint256 peak = hook.storedFeeWad();
        manager.setSqrt(uint160(1 << 96));
        for (uint256 i; i < 60; ++i) {
            vm.warp(vm.getBlockTimestamp() + 10);
            sell(1);
        }
        assertLt(hook.storedFeeWad(), peak);
        vm.warp(vm.getBlockTimestamp() + 25 hours);
        sell(1);
        assertLe(hook.storedFeeWad(), 101 ether);
    }

    function testTwapAveragesEthPriceAcrossUnequalPrices() public {
        uint256 start = ((launch + 31 minutes) / 60 + 1) * 60;
        vm.warp(start);
        manager.setSqrt(uint160(2 << 96));
        sell(1 ether);
        vm.warp(start + 15 minutes);
        manager.setSqrt(uint160(1 << 96));
        sell(1 ether);
        vm.warp(start + 30 minutes);
        // Fifteen minutes at 0.25 ETH/token and fifteen at 1 ETH/token average 0.625; 1% hook share.
        assertEq(hook.quote(1 ether), 1.5642 ether); // 1.584 x 0.9875
    }

    function testOnlyManagerCorrectPoolExactInputAndHookAddress() public {
        SwapParams memory p = SwapParams(false, -1, 1);
        PoolKey memory k = hook.key();
        vm.expectRevert(Unauthorized.selector);
        hook.beforeSwap(alice, k, p, "");
        p.amountSpecified = 1;
        vm.expectRevert(InvalidValue.selector);
        manager.invokeBefore(hook, p);
        vm.expectRevert(Unauthorized.selector);
        hook.unlockCallback("");
        vm.expectRevert(InvalidAddress.selector);
        new V4Market(address(manager), address(token), 12500, 60, address(this), address(desk), bindingConfigHash());
    }

    /// @dev v3.9: after the launch window a buy pays exactly 1% to the hook, all of it to reward buys.
    function testBuyChargesExactlyOnePercentAllToRewards() public {
        vm.warp(hook.initializedAt() + 60 minutes);
        SwapParams memory p = SwapParams(true, -int256(1 ether), 4295128740);
        (, int256 delta,) = manager.invokeBefore(hook, p);
        assertEq(uint256(delta >> 128), 0.01 ether);
        assertEq(hook.heldBase(), 0.01 ether);
        assertEq(address(hook).balance, 0.01 ether);
        hook.flushFees();
        assertEq(d.fees.rewardETH(), 0.01 ether);
        assertEq(d.fees.credit(team), 0);
        assertEq(d.fees.heartbeatBalance(), 0);
        assertEq(address(hook).balance, 0);
        (bool ok,) = address(hook).call(abi.encodeWithSignature("withdrawNetwork()"));
        assertFalse(ok, "no network share remains in the hook");
        (ok,) = address(hook).call(abi.encodeWithSignature("networkCredit()"));
        assertFalse(ok);
    }

    function testFuzzTotalFeeHardCap(uint96 amount) public {
        uint256 output = bound(amount, 1, 100 ether);
        vm.warp(launch + 31 minutes);
        manager.setSqrt(uint160(4 << 96));
        uint256 paid = sell(output);
        assertLe(paid, output * 1500 / 10000);
        assertLe(hook.storedFeeWad(), 1500 ether);
    }
}
