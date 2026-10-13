// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {BaseTest} from "./Base.t.sol";
import {TestV4Market, MockV4Manager} from "./mocks/MockV4Manager.sol";
import {SwapParams} from "../src/interfaces/IV4.sol";
import {FarmRewards} from "../src/FarmRewards.sol";
import {GridOperator} from "../src/GridOperator.sol";
import "../src/lib/Errors.sol";

/// @notice v3.3: idle expiry, anti-rush, team split, PackSale opening.
contract V33Test is BaseTest {
    function advanceOnly() internal {
        calmNext();
        entropy();
        vm.warp(d.rewards.epochEnd());
        d.rewards.advanceEpoch();
    }

    function catchUp(address p) internal {
        while (d.rewards.lastSettled(p) < d.rewards.settledEpoch()) d.rewards.settle(p, 8);
    }

    // ---------------------------------------------------------------- idle expiry

    function testIdleFarmLeavesDenominatorAfterTwelveEpochs() public {
        fund(10_000_000 ether);
        place(alice, 0, 1, 0);
        uint256 w = d.rewards.configuredWeight(alice);
        assertGt(w, 0);
        assertEq(d.rewards.expiresAt(alice), 14);
        assertTrue(d.rewards.committed(alice));
        for (uint256 i; i < 12; ++i) {
            advanceOnly();
        }
        assertEq(d.rewards.epoch(), 13);
        assertEq(d.rewards.epochData(13).raw, w);
        assertEq(d.rewards.expiring(14), w);
        assertFalse(d.rewards.committed(alice));
        advanceOnly();
        assertEq(d.rewards.epochData(14).raw, 0);
        assertEq(d.rewards.nextTotalHash(), 0);
        assertEq(d.rewards.expiring(14), 0);
        assertEq(d.rewards.farmWeight(alice, 13), w);
        assertEq(d.rewards.farmWeight(alice, 14), 0);
        // Configuration is remembered; only the commitment lapsed.
        assertEq(d.rewards.configuredWeight(alice), w);
    }

    function testRewardsEarnedBeforeExpiryAreNeverLost() public {
        fund(10_000_000 ether);
        place(alice, 0, 1, 0);
        place(bob, 0, 1, 0);
        // Bob settles every epoch; Alice is idle and settles only after her farm expired.
        for (uint256 i; i < 16; ++i) {
            advanceOnly();
            catchUp(bob);
        }
        assertEq(d.rewards.pending(alice), 0);
        catchUp(alice);
        uint256 a = d.rewards.pending(alice);
        assertGt(a, 0);
        // Same loadout, same committed epochs: identical credit, whether settled late or on time.
        if (d.farm.district(alice) == d.farm.district(bob)) assertEq(a, d.rewards.pending(bob));
        else assertApproxEqRel(a, d.rewards.pending(bob), 0.05e18);
        // Nothing accrues after expiry.
        advanceOnly();
        catchUp(alice);
        assertEq(d.rewards.pending(alice), a);
        // Claim still pays what was earned.
        uint256 before_ = token.balanceOf(alice);
        vm.prank(alice);
        d.rewards.claim(a);
        assertGt(token.balanceOf(alice), before_);
    }

    function testSyncRecommitsFromNextEpoch() public {
        fund(10_000_000 ether);
        place(alice, 0, 1, 0);
        uint256 w = d.rewards.configuredWeight(alice);
        for (uint256 i; i < 14; ++i) {
            advanceOnly();
        }
        assertEq(d.rewards.epochData(15).raw, 0);
        catchUp(alice);
        vm.prank(alice);
        d.farm.sync();
        assertTrue(d.rewards.committed(alice));
        assertEq(d.rewards.expiresAt(alice), 16 + 12);
        assertEq(d.rewards.farmWeight(alice, 15), 0); // Current epoch is not back-filled.
        assertEq(d.rewards.nextTotalHash(), w);
        advanceOnly();
        assertEq(d.rewards.epochData(16).raw, w);
    }

    function testActionBeforeExpiryMovesBucketWithoutDoubleCount() public {
        place(alice, 0, 1, 0);
        uint256 w = d.rewards.configuredWeight(alice);
        advanceOnly();
        advanceOnly();
        vm.prank(alice);
        d.farm.sync();
        assertEq(d.rewards.expiring(14), 0);
        assertEq(d.rewards.expiring(16), w);
        assertEq(d.rewards.nextTotalHash(), w);
        vm.prank(alice);
        d.farm.sync(); // Second action in the same epoch replaces, never adds.
        assertEq(d.rewards.expiring(16), w);
        assertEq(d.rewards.nextTotalHash(), w);
        for (uint256 i; i < 13; ++i) {
            advanceOnly();
        }
        assertEq(d.rewards.epochData(15).raw, w);
        assertEq(d.rewards.epochData(16).raw, 0);
    }

    function testClaimRecommitsAndPackRecommits() public {
        fund(10_000_000 ether);
        place(alice, 0, 1, 0);
        uint256 w = d.rewards.configuredWeight(alice);
        for (uint256 i; i < 14; ++i) {
            advanceOnly();
        }
        catchUp(alice);
        uint256 owed = d.rewards.pending(alice);
        assertGt(owed, 0);
        vm.prank(alice);
        d.rewards.claim(owed / 2);
        assertTrue(d.rewards.committed(alice));
        assertEq(d.rewards.nextTotalHash(), w);
        for (uint256 i; i < 13; ++i) {
            advanceOnly();
        }
        assertFalse(d.rewards.committed(alice));
        catchUp(alice);
        payPack(alice);
        assertTrue(d.rewards.committed(alice));
    }

    function testClaimDoesNotRecommitWhileBehind() public {
        fund(10_000_000 ether);
        place(alice, 0, 1, 0);
        for (uint256 i; i < 6; ++i) {
            advanceOnly();
        }
        catchUp(alice);
        for (uint256 i; i < 12; ++i) {
            advanceOnly();
        }
        assertFalse(d.rewards.committed(alice));
        uint256 owed = d.rewards.pending(alice);
        vm.prank(alice);
        d.rewards.claim(owed); // Settles 8 of 12 epochs: withdrawal works, no re-commit.
        assertFalse(d.rewards.committed(alice));
    }

    function testAdvanceIsConstantInExpiringFarms() public {
        place(alice, 0, 1, 0); // expires at 14
        advanceOnly();
        for (uint256 i; i < 15; ++i) {
            address p = makeAddr(string(abi.encode("farm", i)));
            place(p, 0, 1, 0); // all expire at 15
        }
        for (uint256 i; i < 11; ++i) {
            advanceOnly();
        }
        assertEq(d.rewards.epoch(), 13);
        calmNext();
        entropy();
        vm.warp(d.rewards.epochEnd());
        uint256 g = gasleft();
        d.rewards.advanceEpoch();
        uint256 one = g - gasleft();
        calmNext();
        entropy();
        vm.warp(d.rewards.epochEnd());
        g = gasleft();
        d.rewards.advanceEpoch();
        uint256 many = g - gasleft();
        assertEq(d.rewards.epochData(15).raw, 0);
        // Fifteen expirations cost the same bucket write as one.
        assertLt(many > one ? many - one : one - many, 50_000);
    }

    // ---------------------------------------------------------------- anti-rush

    function testAgeCapsAtBoundaries() public {
        vm.prank(alice);
        d.farm.register(alice);
        uint256 born = vm.getBlockTimestamp();
        assertEq(d.farm.maxLevelByAge(alice), 4);
        vm.warp(born + 1 days - 1);
        assertEq(d.farm.maxLevelByAge(alice), 4);
        vm.warp(born + 1 days);
        assertEq(d.farm.maxLevelByAge(alice), 6);
        vm.warp(born + 3 days - 1);
        assertEq(d.farm.maxLevelByAge(alice), 6);
        vm.warp(born + 3 days);
        assertEq(d.farm.maxLevelByAge(alice), 9);
        vm.warp(born + 5 days - 1);
        assertEq(d.farm.maxLevelByAge(alice), 9);
        vm.warp(born + 5 days);
        assertEq(d.farm.maxLevelByAge(alice), 10);
        assertEq(d.farm.maxLevelByAge(bob), 4); // No farm, no age.
    }

    function testPaidXpCappedPerDayActivityUncapped() public {
        place(alice, 0, 0, 0);
        uint256 q = d.packs.quote(16);
        vm.prank(alice);
        d.packs.openPack(16);
        assertEq(d.farm.xp(alice), 400);
        assertEq(d.farm.paidXpRoom(alice), 0);
        q = d.packs.quote(40);
        vm.prank(alice);
        d.packs.openPack(40); // whale buy: packs delivered, XP not
        assertEq(d.farm.xp(alice), 400);
        assertEq(d.farm.paidPacks(alice), 56);
        uint256 day = vm.getBlockTimestamp() / 1 days;
        calmNext();
        step();
        calmNext();
        step();
        assertEq(vm.getBlockTimestamp() / 1 days, day);
        assertEq(d.farm.xp(alice), 600); // activity XP arrives after the paid cap
        while (vm.getBlockTimestamp() / 1 days == day) {
            calmNext();
            step();
        }
        assertEq(d.farm.paidXpRoom(alice), 400);
        uint256 xp = d.farm.xp(alice);
        payPack(alice);
        assertEq(d.farm.xp(alice), xp + 25);
        assertEq(d.farm.paidXpRoom(alice), 375);
    }

    function testPartialRoomIsClippedNotReverted() public {
        uint256 q = d.packs.quote(15);
        vm.prank(alice);
        d.packs.openPack(15);
        assertEq(d.farm.paidXpRoom(alice), 25);
        q = d.packs.quote(2);
        vm.prank(alice);
        d.packs.openPack(2);
        assertEq(d.farm.xp(alice), 400);
        assertEq(d.farm.paidXpRoom(alice), 0);
        assertEq(d.farm.paidPacks(alice), 17);
    }

    function testPaidXpCannotBypassAgeGates() public {
        vm.warp(vm.getBlockTimestamp() + 1 hours); // born mid-epoch, so day boundaries fall between steps
        place(alice, 0, 0, 0);
        uint256 born = vm.getBlockTimestamp();
        for (uint256 dayN; dayN < 5; ++dayN) {
            uint256 q = d.packs.quote(16);
            vm.prank(alice);
            d.packs.openPack(16);
            for (uint256 i; i < 4; ++i) {
                calmNext();
                step();
            }
            uint256 age = vm.getBlockTimestamp() - born;
            uint256 cap = age >= 5 days ? 10 : age >= 3 days ? 9 : age >= 1 days ? 6 : 4;
            assertLe(d.farm.level(alice), cap);
            if (dayN == 2) {
                assertLt(age, 3 days);
                assertGe(d.farm.xpLevel(alice), 7);
                assertEq(d.farm.level(alice), 6);
                assertFalse(d.farm.roomUnlocked(alice, 2));
            }
        }
        assertLt(vm.getBlockTimestamp() - born, 5 days);
        assertEq(d.farm.xpLevel(alice), 10);
        assertEq(d.farm.level(alice), 9);
        assertFalse(d.farm.roomUnlocked(alice, 3));
        uint256 mythic = mintItem(alice, 2, 4);
        vm.expectRevert(InvalidValue.selector);
        vm.prank(alice);
        d.farm.place(mythic, 0, 2);
        vm.warp(born + 5 days);
        assertEq(d.farm.level(alice), 10);
        assertTrue(d.farm.roomEligible(alice, 3));
    }

    function testMergeRemoved() public {
        uint256[3] memory ids;
        for (uint256 i; i < 3; ++i) {
            ids[i] = mintItem(alice, 0, 0);
        }
        vm.prank(alice);
        (bool ok,) = address(d.farm).call(abi.encodeWithSignature("merge(uint256[3],bool)", ids, true));
        assertFalse(ok);
        assertEq(d.items.inventory(alice), 3);
    }

    function _inDistrict(uint256 dist, uint256 n, string memory tag) internal returns (address[] memory out) {
        out = new address[](n);
        uint256 found;
        for (uint256 i; found < n; ++i) {
            address p = makeAddr(string(abi.encode(tag, i)));
            if (d.farm.district(p) == dist) out[found++] = p;
        }
    }

    function _spend(address p, uint256 value) internal {
        vm.prank(address(d.farm));
        d.season.recordSpend(p, value, true);
    }

    function _active(address p) internal {
        vm.prank(address(d.rewards));
        d.season.recordActivity(p, 0, 1, 10000);
    }

    function testDistrictScoreAveragePerFarmAndTenPercentWalletCap() public {
        address[] memory a = _inDistrict(3, 12, "d3");
        // Ten equal spenders, ten active farms: full spend counts, average 1 ETH.
        for (uint256 i; i < 10; ++i) {
            _spend(a[i], 1 ether);
            _active(a[i]);
        }
        (uint256 score, uint256 counted) = d.season.districtScore(0, 3);
        assertEq(counted, 10 ether);
        assertEq(score, 1 ether);
        // A whale joins with 100 ETH: it counts as at most 10% of the counted spend.
        _spend(a[10], 100 ether);
        _active(a[10]);
        (score, counted) = d.season.districtScore(0, 3);
        assertEq(counted, 21 ether);
        assertEq(Math10.min(100 ether, 110 ether / 10), 11 ether);
        assertEq(score, counted / 11);
        // Inactive farms add nothing to the denominator; an extra active zero-spend farm dilutes the average.
        _active(a[11]);
        (uint256 diluted,) = d.season.districtScore(0, 3);
        assertEq(diluted, counted / 11);
    }

    function testSingleWhaleDistrictCannotWinAlone() public {
        address[] memory w = _inDistrict(1, 1, "whale");
        address[] memory s = _inDistrict(2, 10, "small");
        _spend(w[0], 1000 ether);
        _active(w[0]);
        for (uint256 i; i < 10; ++i) {
            _spend(s[i], 0.01 ether);
            _active(s[i]);
        }
        (uint256 whaleScore,) = d.season.districtScore(0, 1);
        (uint256 smallScore,) = d.season.districtScore(0, 2);
        assertEq(whaleScore, 100 ether);
        assertEq(smallScore, 0.01 ether);
    }

    function testTopSpenderTrackingIsExact() public {
        address[] memory a = _inDistrict(5, 14, "track");
        for (uint256 i; i < 14; ++i) {
            _spend(a[i], (i + 1) * 1 ether);
            _active(a[i]);
        }
        // A late riser from the bottom becomes the largest and must be capped.
        _spend(a[0], 500 ether);
        (, uint256 counted) = d.season.districtScore(0, 5);
        uint256 total = 501 ether;
        for (uint256 i = 1; i < 14; ++i) {
            total += (i + 1) * 1 ether;
        }
        assertLt(counted, total);
        // Brute-force fixed point: c = sum(min(s_i, c)) / 10.
        uint256 c = total / 10;
        uint256 sum = Math10.min(501 ether, c);
        for (uint256 i = 1; i < 14; ++i) {
            sum += Math10.min((i + 1) * 1 ether, c);
        }
        assertApproxEqAbs(sum, counted, 100);
    }

    // ---------------------------------------------------------------- team split

    function testPackLobbySellSplit88Team10Heartbeat2() public {
        vm.deal(address(d.packs), 1 ether);
        uint256 team0 = d.fees.credit(team);
        uint256 r0 = d.fees.rewardETH();
        uint256 h0 = d.fees.heartbeatBalance();
        vm.prank(address(market));
        d.fees.depositSellTax{value: 1 ether}();
        assertEq(d.fees.credit(team) - team0, 0.1 ether);
        assertEq(d.fees.heartbeatBalance() - h0, 0.02 ether);
        assertEq(d.fees.rewardETH() - r0, 0.38 ether);
        vm.deal(address(d.grid), 1 ether);
        vm.prank(address(market));
        d.fees.depositSellTax{value: 1 ether}();
        assertEq(d.fees.credit(team) - team0, 0.2 ether);
        vm.deal(address(market), 1 ether);
        vm.prank(address(market));
        d.fees.depositSellTax{value: 1 ether}();
        assertEq(d.fees.credit(team) - team0, 0.3 ether);
        assertEq(d.fees.rewardETH() - r0, 1.14 ether);
    }

    function testHeartbeatCapExcessGoesToPoolAndBaseFeeIsAllRewards() public {
        vm.deal(address(d.packs), 200 ether);
        uint256 team0 = d.fees.credit(team);
        uint256 r0 = d.fees.rewardETH();
        uint256 h0 = d.fees.heartbeatBalance();
        vm.prank(address(market));
        d.fees.depositSellTax{value: 100 ether}();
        assertEq(d.fees.heartbeatBalance(), 1 ether);
        assertEq(d.fees.credit(team) - team0, 10 ether);
        assertEq(d.fees.rewardETH() - r0, 50 ether - 10 ether - (1 ether - h0));
        d.fees.depositBaseFee{value: 1 ether}();
        assertEq(d.fees.credit(team) - team0, 10 ether, "v3.9: no team half of the base fee");
        assertEq(d.fees.rewardETH() - r0, 41 ether - (1 ether - h0));
    }

    function testLaunchTaxDepositIsAllPoolAndMarketOnly() public {
        uint256 team0 = d.fees.credit(team);
        uint256 r0 = d.fees.rewardETH();
        vm.expectRevert(Unauthorized.selector);
        d.fees.depositLaunchTax{value: 1 ether}();
        vm.deal(address(market), 1 ether);
        vm.prank(address(market));
        d.fees.depositLaunchTax{value: 1 ether}();
        assertEq(d.fees.rewardETH() - r0, 1 ether);
        assertEq(d.fees.credit(team), team0);
    }

    // ---------------------------------------------------------------- PackSale opening

    function testPackSaleOpensSixtyMinutesAfterLaunch() public {
        assertEq(d.packs.opensAt(), tokenLaunch() + 60 minutes);
        vm.warp(tokenLaunch() + 60 minutes - 1);
        assertFalse(d.packs.isOpen());
        uint256 price = d.packs.price();
        vm.expectRevert(TooEarly.selector);
        vm.prank(alice);
        d.packs.openPack(1);
        vm.warp(tokenLaunch() + 60 minutes);
        assertTrue(d.packs.isOpen());
        payPack(alice);
        assertEq(d.packs.sold(), 1);
        // Price curve starts at the opening, not at token launch.
        assertEq(d.packs.priceAt(0), 15000 ether);
    }

    function testTokenPacksAlsoWaitForOpening() public {
        vm.warp(tokenLaunch() + 60 minutes - 1);
        vm.prank(address(d.farm));
        vm.expectRevert(TooEarly.selector);
        d.packs.tokenPack(alice);
    }
}

library Math10 {
    function min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
}

/// @notice Launch protection on the custom hook.
contract LaunchProtectionTest is BaseTest {
    MockV4Manager internal manager;
    TestV4Market internal hook;
    uint256 internal t0;

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
        t0 = hook.initializedAt();
    }

    function buyFee(uint256 ethIn) internal returns (uint256) {
        (, int256 delta,) = manager.invokeBefore(hook, SwapParams(true, -int256(ethIn), 4295128740));
        return uint256(delta >> 128);
    }

    function testViewsBeforeInitialization() public {
        TestV4Market fresh = new TestV4Market(address(manager), address(token), address(desk), bindingConfigHash());
        assertEq(fresh.currentBuyTaxBps(), 9000);
        assertEq(fresh.launchTaxTimeLeft(), 30 minutes);
        assertEq(fresh.maxBuy(), type(uint256).max);
        assertEq(fresh.maxBuyTimeLeft(), 0);
    }

    function testBuyTaxHasImmutableSteps() public {
        assertEq(hook.currentBuyTaxBps(), 9000);
        assertEq(hook.launchTaxTimeLeft(), 30 minutes);
        vm.warp(t0 + 15 minutes);
        assertEq(hook.currentBuyTaxBps(), 5000);
        vm.warp(t0 + 29 minutes);
        assertEq(hook.currentBuyTaxBps(), 2500);
        vm.warp(t0 + 30 minutes);
        assertEq(hook.currentBuyTaxBps(), 100);
        assertEq(hook.launchTaxTimeLeft(), 0);
        vm.warp(t0 + 10 days);
        assertEq(hook.currentBuyTaxBps(), 100);
        (uint256 bps, uint256 left, uint256 mb, uint256 mbl) = hook.launchStatus();
        assertEq(bps, 100);
        assertEq(left, 0);
        assertEq(mb, type(uint256).max);
        assertEq(mbl, 0);
    }

    function testLaunchTaxChargedAndRoutedEntirelyToPool() public {
        uint256 fee = buyFee(0.5 ether);
        assertEq(fee, 0.45 ether);
        assertEq(hook.heldBase(), 0);
        assertEq(hook.heldLaunchTax(), 0.45 ether);
        uint256 team0 = d.fees.credit(team);
        uint256 r0 = d.fees.rewardETH();
        hook.flushFees();
        assertEq(hook.heldLaunchTax(), 0);
        // The 1% base is reward buys as well; every launch-tax wei goes to reward buys.
        assertEq(d.fees.credit(team) - team0, 0);
        assertEq(d.fees.rewardETH() - r0, 0.45 ether);
    }

    function testNormalBuyAfterDecayHasNoLaunchTax() public {
        vm.warp(t0 + 30 minutes);
        uint256 fee = buyFee(0.3 ether);
        assertEq(fee, 0.3 ether * 100 / 10000);
        assertEq(hook.heldLaunchTax(), 0);
    }

    function testSellsPayNormalFeeDuringLaunch() public {
        SwapParams memory p = SwapParams(false, -int256(1 ether), type(uint160).max - 1);
        (, int256 before_,) = manager.invokeBefore(hook, p);
        assertEq(before_, int256(0));
        int256 delta = (int256(1 ether) << 128) | int256(uint256(uint128(type(uint128).max - 1)));
        (, int128 fee) = manager.invokeAfter(hook, p, delta);
        assertLe(uint256(uint128(fee)), 1 ether * 1500 / 10000);
        assertEq(hook.heldLaunchTax(), 0);
    }

    function testNoBuySizeLimitAtAnyLaunchStep() public {
        assertEq(buyFee(5 ether), 4.5 ether);
        vm.warp(t0 + 15 minutes);
        assertEq(buyFee(5 ether), 2.5 ether);
        vm.warp(t0 + 25 minutes);
        assertEq(buyFee(5 ether), 1.25 ether);
        vm.warp(t0 + 30 minutes);
        assertEq(buyFee(5 ether), 0.05 ether);
    }

    function testSnipersSplittingBuysStillPayTheCurve() public {
        uint256 paid;
        for (uint256 i; i < 10; ++i) {
            paid += buyFee(0.5 ether);
        }
        assertEq(paid, 4.5 ether);
        assertEq(hook.heldLaunchTax(), 4.5 ether);
    }
}
