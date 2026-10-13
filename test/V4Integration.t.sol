// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {BaseTest} from "./Base.t.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IntegrationV4Market} from "./mocks/MockV4Manager.sol";
import {V4Market} from "../src/V4Market.sol";
import {FeeRouter} from "../src/FeeRouter.sol";
import {IV4PoolManager, PoolKey, SwapParams} from "../src/interfaces/IV4.sol";

struct LiquidityParams {
    int24 tickLower;
    int24 tickUpper;
    int256 liquidityDelta;
    bytes32 salt;
}

interface RealManager is IV4PoolManager {
    function initialize(PoolKey memory, uint160) external returns (int24);
    function modifyLiquidity(PoolKey memory, LiquidityParams memory, bytes calldata) external returns (int256, int256);
    function sync(address) external;
}

contract V4IntegrationTest is BaseTest {
    RealManager internal manager;
    V4Market internal hook;
    FeeRouter internal router;

    function setUp() public override {
        super.setUp();
        vm.deal(address(this), 10000 ether);
        manager = RealManager(address(new PoolManager(address(this))));
        bytes memory code = abi.encodePacked(
            type(IntegrationV4Market).creationCode,
            abi.encode(
                address(manager),
                address(token),
                uint24(12500),
                int24(60),
                address(this),
                address(desk),
                bindingConfigHash()
            )
        );
        bytes32 hash = keccak256(code);
        bytes32 salt;
        for (uint256 i;; ++i) {
            salt = bytes32(i);
            address target = vm.computeCreate2Address(salt, hash, address(this));
            if (uint160(target) & 0x3fff == 0x10cc) break;
        }
        hook = new IntegrationV4Market{salt: salt}(
            address(manager), address(token), 12500, 60, address(this), address(desk), bindingConfigHash()
        );
        router = canonicalFees(address(hook));
        vm.prank(team);
        bindHook(hook, address(router));
        manager.initialize(hook.key(), uint160(1 << 96));
        manager.unlock(abi.encode(uint8(0), uint256(1000 ether)));
        vm.warp(vm.getBlockTimestamp() + 60 minutes);
    }
    receive() external payable {}

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager));
        (uint8 action, uint256 amount) = abi.decode(data, (uint8, uint256));
        int256 delta;
        if (action == 0) {
            (delta,) =
                manager.modifyLiquidity(hook.key(), LiquidityParams(-887220, 887220, int256(amount), bytes32(0)), "");
        } else {
            delta = manager.swap(
                hook.key(),
                SwapParams(
                    action == 1,
                    -int256(amount),
                    action == 1 ? 4295128740 : 1461446703485210103287273052203988822378723970341
                ),
                ""
            );
        }
        int128 a = int128(delta >> 128);
        int128 b = int128(delta);
        if (a < 0) manager.settle{value: uint256(-int256(a))}();
        else if (a > 0) manager.take(address(0), address(this), uint256(uint128(a)));
        if (b < 0) {
            manager.sync(address(token));
            token.transfer(address(manager), uint256(-int256(b)));
            manager.settle();
        } else if (b > 0) {
            manager.take(address(token), address(this), uint256(uint128(b)));
        }
        return abi.encode(delta);
    }

    function testRealV4BuyAndSingleSwapSellTaxConserveSettlement() public {
        uint256 before = address(this).balance;
        manager.unlock(abi.encode(uint8(1), uint256(1 ether)));
        assertEq(before - address(this).balance, 1 ether);
        assertEq(hook.heldBase(), 0.01 ether, "exactly 1% of the buy input");
        hook.flushFees();
        assertEq(router.rewardETH(), 0.01 ether);
        assertEq(router.credit(team), 0);
        uint256 oldPrice = hook.lastPrice();
        manager.unlock(abi.encode(uint8(2), uint256(100 ether)));
        assertGt(hook.heldBase(), 0);
        assertGt(hook.heldSellTax(), 0);
        assertGt(hook.lastPrice(), oldPrice);
        assertGt(hook.storedFeeWad(), 1000 ether);
        assertLe(hook.storedFeeWad(), 1500 ether);
    }

    function testRealV4SystemBuyUsesTwapAndOnlySystemFunds() public {
        router.depositBaseFee{value: 1 ether}();
        uint256 beforePool = token.balanceOf(address(d.pool));
        uint256 quoted = hook.quote(0.5 ether);
        router.executeBuys(0.5 ether, quoted * 985 / 1000);
        assertGe(token.balanceOf(address(d.pool)) - beforePool, quoted * 985 / 1000);
        (uint256 hour, uint256 day) = hook.imbalances();
        assertEq(hour, 0);
        assertEq(day, 0);
    }

    function testRealV4SystemSalesUseDepthTwapNormalFeesAndConserveTokens() public {
        uint256 beforePool = token.balanceOf(address(d.pool));
        token.transfer(address(router), 10 ether);
        vm.prank(address(d.packs));
        router.routeTokens(10 ether);
        assertEq(token.balanceOf(address(d.pool)) - beforePool, 8.8 ether);
        (uint256 amount, uint256 minimum) = router.sellBatchQuote();
        assertGt(amount, 0);
        assertLe(amount, 0.1 ether);
        uint256 beforeRouter = token.balanceOf(address(router));
        uint256 beforeManager = token.balanceOf(address(manager));
        uint256 received = router.executeSells(amount, minimum);
        assertEq(beforeRouter - token.balanceOf(address(router)), amount);
        assertEq(token.balanceOf(address(manager)) - beforeManager, amount);
        assertGe(received, minimum);
        assertGt(hook.heldBase(), 0);
        assertEq(hook.heldSellTax(), 0, "system sale has no sell surcharge");
        assertEq(router.credit(team) + router.heartbeatBalance(), received);
        assertEq(address(router).balance, received);
    }

    function testRealV4ManipulatedSpotCannotInstantlySetBuybackQuote() public {
        uint256 quote = hook.quote(1 ether);
        manager.unlock(abi.encode(uint8(2), uint256(100 ether)));
        assertEq(hook.quote(1 ether), quote);
        assertGt(hook.lastPrice(), quote);
    }

    function testRealV4SmallBuyPaysPositiveKeeperMargin() public {
        vm.deal(address(hook), 2 ether);
        vm.prank(address(hook));
        router.depositSellTax{value: 2 ether}();
        uint256 q = hook.quote(0.5 ether) * 985 / 1000;
        uint256 beforeCredit = router.credit(address(this));
        uint256 start = gasleft();
        router.executeBuys(0.5 ether, q);
        uint256 used = start - gasleft();
        uint256 paid = router.credit(address(this)) - beforeCredit;
        emit log_named_uint("real V4 0.2ETH buy gas", used);
        emit log_named_uint("real V4 buy bounty wei", paid);
        assertGt(paid, (used + 21000) * tx.gasprice);
    }

    function testSystemBuybackOffsetsRecordedSellImbalance() public {
        manager.unlock(abi.encode(uint8(2), uint256(0.1 ether)));
        (uint256 hourBefore, uint256 dayBefore) = hook.imbalances();
        assertGt(hourBefore, 0);
        assertGt(dayBefore, 0);

        router.depositBaseFee{value: 1 ether}();
        uint256 beforePool = token.balanceOf(address(d.pool));
        router.executeBuys(0.5 ether, hook.quote(0.5 ether) * 985 / 1000);
        assertGt(token.balanceOf(address(d.pool)), beforePool);

        // 0.48875 ETH of pool buy input exceeds the preceding ~0.1 ETH sell output.
        (uint256 hourAfter, uint256 dayAfter) = hook.imbalances();
        assertEq(hourAfter, 0, "real buyback must offset recorded hourly sell pressure");
        assertEq(dayAfter, 0, "real buyback must offset recorded daily sell pressure");
    }
}
