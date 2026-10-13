// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {BaseTest} from "./Base.t.sol";
import {Deploy, LocalApplicationFactory} from "../script/Deploy.s.sol";
import {TestV4Market, MockV4Manager} from "./mocks/MockV4Manager.sol";
import {MockGameRegistry} from "./mocks/MockGameRegistry.sol";
import {RewardPool} from "../src/RewardPool.sol";
import {Params} from "../src/Params.sol";
import {FarmRewards} from "../src/FarmRewards.sol";
import {GridOperator} from "../src/GridOperator.sol";
import "../src/lib/Errors.sol";

contract V34Test is BaseTest {
    function testEntropyAt256BoundaryAndAt257RearmsWithoutPayOrMint() public {
        uint256 id = payPack(alice);
        (, uint64 target,,,,,,,) = d.packs.commits(id);
        vm.roll(uint256(target) + 256);
        vm.setBlockhash(target, keccak256("last capturable block"));
        d.packs.captureEntropy(id);
        (,,,,,, bytes32 seed, bool fixedSeed,) = d.packs.commits(id);
        assertTrue(fixedSeed);
        vm.roll(uint256(target) + 1000);
        vm.expectRevert(TooEarly.selector);
        d.packs.rearm(id);
        d.packs.resolve(id, 1);
        assertEq(d.items.inventory(alice), 3);
        (,,,,,, bytes32 preserved,,) = d.packs.commits(id);
        assertEq(seed, preserved);

        uint256 other = payPack(bob);
        (, target,,,,,,,) = d.packs.commits(other);
        vm.roll(uint256(target) + 257);
        uint256 credit = d.fees.credit(address(this));
        d.packs.resolve(other, 1);
        (, uint64 next,, uint256 opened,,, bytes32 absent, bool captured,) = d.packs.commits(other);
        assertEq(next, block.number + 2);
        assertEq(opened, 0);
        assertEq(absent, bytes32(0));
        assertFalse(captured);
        assertEq(d.items.inventory(bob), 0);
        assertEq(d.fees.credit(address(this)), credit);
        entropy();
        d.packs.captureEntropy(other);
        d.packs.resolve(other, 1);
        assertEq(d.items.inventory(bob), 3);
    }

    function testStarterEntropyRearmsAfterClaimWindowAndNoDoubleMint() public {
        vm.warp(tokenLaunch() + 48 hours);
        vm.prank(alice);
        d.starter.claim(17, new bytes32[](0));
        vm.roll(vm.getBlockNumber() + 300);
        vm.warp(tokenLaunch() + 30 days);
        d.starter.resolve(17);
        assertFalse(d.starter.entropyCaptured(17));
        assertEq(d.items.inventory(alice), 0);
        entropy();
        d.starter.captureEntropy(17);
        vm.roll(vm.getBlockNumber() + 300);
        d.starter.resolve(17);
        assertEq(d.items.inventory(alice), 3);
        vm.expectRevert(AlreadyDone.selector);
        d.starter.resolve(17);
    }

    function testMythicGateEvaluatedAtRevealNotAtPayment() public {
        uint256 id = payPack(alice);
        (,,,, bool eligible,,,,) = d.packs.commits(id);
        assertFalse(eligible);
        veteran(alice);
        resolvePack(id);
        (,,,, eligible,,,,) = d.packs.commits(id);
        assertTrue(eligible);
    }

    function testGameReadinessBothChecksRollbackEthAndTokenPurchase() public {
        vm.mockCall(address(d.pool), abi.encodeWithSignature("endowed()"), abi.encode(false));
        uint256 q = d.packs.price();
        uint256 before_ = alice.balance;
        vm.expectRevert(NotConfigured.selector);
        vm.prank(alice);
        d.packs.openPack(1);
        assertEq(alice.balance, before_);
        assertEq(d.packs.sold(), 0);
        uint256 tokensBefore = token.balanceOf(alice);
        vm.expectRevert(NotConfigured.selector);
        vm.prank(alice);
        d.farm.buyTokenPack(true);
        assertEq(token.balanceOf(alice), tokensBefore);
        vm.mockCall(address(d.pool), abi.encodeWithSignature("endowed()"), abi.encode(true));
        market.configureLaunch(tokenLaunch(), bob);
        vm.expectRevert(NotConfigured.selector);
        vm.prank(alice);
        d.packs.openPack(1);
        vm.expectRevert(NotConfigured.selector);
        vm.prank(alice);
        d.farm.buyTokenPack(true);
        market.configureLaunch(tokenLaunch(), address(d.fees));
        payPack(alice);
        vm.prank(alice);
        d.farm.buyTokenPack(true);
        assertEq(d.packs.sold(), 2);
    }

    function testHookUninitializedCannotOpenOrStartEpochAndCallerCannotStartClock() public {
        MockV4Manager manager = new MockV4Manager();
        TestV4Market hook = new TestV4Market(address(manager), address(token), address(desk), bindingConfigHash());
        vm.expectRevert(Unauthorized.selector);
        vm.prank(bob);
        manager.initializeHook(hook);
        assertEq(hook.initializedAt(), 0);
        market.configureLaunch(0, address(d.fees));
        assertFalse(d.packs.isOpen());
        vm.warp(d.rewards.epochEnd());
        vm.expectRevert(NotConfigured.selector);
        d.rewards.advanceEpoch();
        manager.initializeHook(hook);
        assertEq(hook.initializedAt(), block.timestamp);
        vm.expectRevert(AlreadyDone.selector);
        manager.initializeHook(hook);
    }

    function testLaunchTaxExactBoundaries() public {
        MockV4Manager manager = new MockV4Manager();
        TestV4Market hook = new TestV4Market(address(manager), address(token), address(desk), bindingConfigHash());
        manager.initializeHook(hook);
        uint256 t = hook.initializedAt();
        vm.warp(t + 10 minutes - 1);
        assertEq(hook.currentBuyTaxBps(), 9000);
        assertEq(hook.nextStepIn(), 1);
        vm.warp(t + 10 minutes);
        assertEq(hook.currentBuyTaxBps(), 5000);
        vm.warp(t + 20 minutes - 1);
        assertEq(hook.currentBuyTaxBps(), 5000);
        vm.warp(t + 20 minutes);
        assertEq(hook.currentBuyTaxBps(), 2500);
        vm.warp(t + 30 minutes - 1);
        assertEq(hook.currentBuyTaxBps(), 2500);
        vm.warp(t + 30 minutes);
        assertEq(hook.currentBuyTaxBps(), 100);
        assertEq(hook.nextStepIn(), 0);
    }

    function testPackOpeningFollowsHookAndNotLegacyDeployTimestamp() public {
        uint256 start = block.timestamp;
        market.configureLaunch(start, address(d.fees));
        assertEq(d.packs.opensAt(), start + 60 minutes);
        vm.warp(start + 60 minutes - 1);
        assertFalse(d.packs.isOpen());
        vm.warp(start + 60 minutes);
        assertTrue(d.packs.isOpen());
    }

    function testRemainderTransferredToPredictedPoolBeforeDeploymentAndNoApprovalNeeded() public {
        uint256 principal = 200_000_000 ether;
        MockGameRegistry r = mockRegistry(address(market), principal);
        LocalApplicationFactory f = deployment.localFactory();
        bytes memory init = bytes.concat(type(RewardPool).creationCode, abi.encode(address(r)));
        address predicted = f.predictContract(30, 0, init);
        assertEq(predicted.code.length, 0);
        token.transfer(predicted, principal);
        RewardPool pool = RewardPool(f.deploy(30, 0, init));
        assertEq(address(pool), predicted);
        assertFalse(pool.endowed());
        vm.prank(bob);
        pool.fundEndowment();
        assertTrue(pool.endowed());
        assertEq(pool.lockedEndowment(), principal);
        assertEq(pool.available(), 0);
        assertEq(token.balanceOf(predicted), principal);
        (bool ok,) = predicted.call(abi.encodeWithSignature("activateEndowment()"));
        assertFalse(ok);
    }

    function testDonationsAndOrdinaryInflowsCannotPretendToBeEndowment() public {
        uint256 principal = 100 ether;
        RewardPool pool = new RewardPool(address(mockRegistry(address(market), principal)));
        token.approve(address(pool), principal);
        pool.donate(principal);
        assertEq(pool.otherInflow(), principal);
        assertFalse(pool.endowed());
        assertEq(pool.available(), 0);
        vm.expectRevert();
        pool.fundEndowment();
        token.transfer(address(pool), principal);
        pool.fundEndowment();
        assertEq(token.balanceOf(address(pool)), 2 * principal);
        assertEq(pool.available(), principal);
    }

    function testFirstRewardStartsCurrentEpochAtHalfTimeAndSnapshotCannotBeReplaced() public {
        fund(1_000_000 ether);
        vm.warp(d.rewards.epochStart() + 3 hours);
        place(alice, 0, 0, 0);
        uint256 entry = d.rewards.entryWeight(1, alice);
        assertEq(entry, 5000);
        assertEq(d.rewards.epochData(1).raw, 5000);
        place(alice, 1, 0, 1);
        assertEq(d.rewards.entryWeight(1, alice), entry);
        assertGt(d.rewards.nextTotalHash(), entry);
        vm.mockCall(
            address(d.grid),
            abi.encodeCall(d.grid.eventAt, (uint256(1))),
            abi.encode(GridOperator.Kind.Calm, uint16(10000), uint8(0), keccak256("calm"), true)
        );
        uint256 available = d.pool.available();
        step();
        assertEq(d.rewards.epochData(1).mining, available * 350 / 80000);
        assertGt(d.rewards.pending(alice), 0);
        assertEq(d.rewards.epochData(1).settledHash, entry);
    }

    function testBuybackSlippage150BpsMaxAndIntervalCannotBeBypassed() public {
        d.fees.depositBaseFee{value: 2 ether}();
        uint256 q = market.quote(0.1 ether);
        vm.expectRevert(InvalidValue.selector);
        d.fees.executeBuys(0.1 ether, q * 9849 / 10000);
        market.setFill(9849);
        vm.expectRevert(InsufficientBalance.selector);
        d.fees.executeBuys(0.1 ether, q * 985 / 1000);
        assertEq(d.fees.lastBuy(), 0);
        market.setFill(9850);
        d.fees.executeBuys(0.1 ether, q * 985 / 1000);
        vm.expectRevert(TooEarly.selector);
        d.fees.executeBuys(0.1 ether, q * 985 / 1000);
        vm.warp(block.timestamp + 5 minutes - 1);
        vm.expectRevert(TooEarly.selector);
        d.fees.executeBuys(0.1 ether, q * 985 / 1000);
        vm.warp(block.timestamp + 1);
        d.fees.executeBuys(0.1 ether, q * 985 / 1000);
        vm.warp(block.timestamp + 1 days);
        vm.prank(swarm);
        vm.expectRevert(InvalidValue.selector);
        d.params.set(Params.Key.SlippageBps, 151, "Cannot loosen past immutable maximum");
    }

    function _activity(address p, uint256 epochs_, uint256 hash) internal {
        vm.startPrank(address(d.rewards));
        for (uint256 i; i < epochs_; ++i) {
            d.season.recordActivity(p, 0, 1 ether, hash);
        }
        vm.stopPrank();
    }

    function _spend(address p, uint256 value) internal {
        vm.prank(address(d.farm));
        d.season.recordSpend(p, value, true);
    }

    function testBestFarmNeedsTwentyEpochsAndUsesCappedAbsoluteSpend() public {
        _spend(alice, 0.9 ether);
        _spend(bob, 5 ether);
        _activity(alice, 20, 10000);
        _activity(bob, 19, 1000000);
        vm.mockCall(address(d.rewards), abi.encodeCall(d.rewards.seasonReady, (0)), abi.encode(true));
        vm.startPrank(address(d.rewards));
        d.season.complete(bob, 0);
        d.season.complete(alice, 0);
        vm.stopPrank();
        (,, address best,,) = d.season.result(0);
        assertEq(best, alice);
        assertEq(d.season.tickets(0, bob), 19 * 100000);
        assertEq(d.season.tickets(0, alice), 20 * 10000);
    }

    function testBestFarmCapsAbsoluteSpendAndBreaksTiesByAddress() public {
        _spend(alice, 2 ether);
        _spend(bob, 100 ether);
        _activity(alice, 20, 10000);
        _activity(bob, 28, 10000);
        vm.mockCall(address(d.rewards), abi.encodeCall(d.rewards.seasonReady, (0)), abi.encode(true));
        vm.startPrank(address(d.rewards));
        d.season.complete(alice, 0);
        d.season.complete(bob, 0);
        vm.stopPrank();
        (,, address best,,) = d.season.result(0);
        assertEq(best, uint160(alice) < uint160(bob) ? alice : bob);
    }

    function testFreeFarmDoesNotDiluteDistrictOrClaimPaidPrize() public {
        address free;
        for (uint256 i = 1;; i++) {
            free = address(uint160(100000 + i));
            if (d.farm.district(free) == d.farm.district(alice)) break;
        }
        _spend(alice, 1 ether);
        _activity(alice, 20, 10000);
        _activity(free, 20, 10000);
        assertEq(d.season.activeFarms(0, d.farm.district(alice)), 1);
        (uint256 score, uint256 counted) = d.season.districtScore(0, d.farm.district(alice));
        assertEq(score, 0.1 ether);
        assertEq(counted, 0.1 ether);
        vm.mockCall(address(d.rewards), abi.encodeCall(d.rewards.seasonReady, (0)), abi.encode(true));
        vm.startPrank(address(d.rewards));
        d.season.complete(alice, 0);
        d.season.complete(free, 0);
        vm.stopPrank();
        vm.warp(d.season.deadline(0));
        d.season.prepare(0, 1);
        entropy();
        d.season.finalize(0);
        vm.expectRevert(InvalidValue.selector);
        vm.prank(free);
        d.season.claimDistrict(0);
        vm.prank(alice);
        d.season.claimDistrict(0);
        vm.expectRevert(InvalidValue.selector);
        vm.prank(alice);
        d.season.claimDistrict(0);
    }
}
