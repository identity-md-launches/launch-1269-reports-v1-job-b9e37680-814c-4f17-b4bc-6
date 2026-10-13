// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {FarmEngine} from "../src/FarmEngine.sol";
import {Params} from "../src/Params.sol";
import {DeferredEntryTest} from "./Base.t.sol";
import {GridOperator} from "../src/GridOperator.sol";
import "../src/lib/Errors.sol";

contract RegressionTest is DeferredEntryTest {
    function testUnlimitedFreshPacksCannotDrainPoolByScrapping() public {
        fund(1_000_000 ether);
        payPack(alice);
        place(alice, 0, 0, 0);
        calmNext();
        step();
        calmNext();
        step();
        market.setRate(1000 ether);
        uint256 allowance = d.rewards.scrapAllowance();
        assertGt(allowance, 0);
        uint256 pending = d.rewards.pending(alice);
        uint256 poolBalance = token.balanceOf(address(d.pool));
        vm.prank(alice);
        uint256 pack = d.farm.buyTokenPack(true);
        uint256 first = d.items.nextId();
        vm.roll(vm.getBlockNumber() + 300);
        d.packs.resolve(pack, 1);
        entropy();
        d.packs.resolve(pack, 1);
        for (uint256 i; i < 3; ++i) {
            vm.prank(alice);
            d.farm.scrap(first + i, 0);
        }
        assertLe(d.rewards.pending(alice) - pending, allowance);
        assertEq(d.rewards.scrapAllowance(), 0);
        assertGe(token.balanceOf(address(d.pool)), poolBalance);
        uint256 another = mintItem(alice, 0, 0);
        vm.expectRevert(InsufficientBalance.selector);
        vm.prank(alice);
        d.farm.scrap(another, 1);
        assertEq(d.items.data(another).holder, alice);
    }

    function testEmptyEpochPreservesLastSettledRateButResetsScrapAllowance() public {
        fund(1_000_000 ether);
        payPack(alice);
        place(alice, 0, 0, 0);
        calmNext();
        step();
        calmNext();
        step();
        assertGt(d.rewards.lastYieldPerHash(), 0);
        vm.prank(alice);
        d.farm.unplace(0, 0);
        calmNext();
        step();
        calmNext();
        step();
        assertGt(d.rewards.lastYieldPerHash(), 0);
        assertEq(d.rewards.scrapAllowance(), 0);
    }

    function testRepairAndPaidPackCannotRetroactivelyBoostEpoch() public {
        uint256 id = place(alice, 0, 0, 0);
        calmNext();
        step();
        // Freeze the epoch before restoring the holder-account discount with a purchase.
        payPack(alice);
        calmNext();
        step();
        (uint256 raw,,,) = d.rewards.shares(2, alice);
        assertEq(raw, 10000);
        uint256 previous = d.items.data(id).durability;
        vm.prank(alice);
        d.farm.repair(id, true);
        calmNext();
        step();
        (uint256 raw3, uint256 productive,,) = d.rewards.shares(3, alice);
        assertEq(raw3, 10000);
        assertEq(productive, 10000); // Both snapshots remain in the top output tier.
    }

    function testCableRepairRestoresOnlyRemainingHalfEpoch() public {
        payPack(alice);
        place(alice, 8, 0, 0);
        calmNext();
        step();
        bytes32 seed;
        for (uint256 i;; ++i) {
            seed = bytes32(i);
            if (uint256(keccak256(abi.encode(seed, alice))) % 10000 < 2000) break;
        }
        vm.mockCall(
            address(d.grid),
            abi.encodeCall(d.grid.eventAt, (uint256(2))),
            abi.encode(GridOperator.Kind.Theft, uint16(10000), uint8(d.farm.district(alice)), seed, true)
        );
        step();
        vm.warp(d.rewards.epochEnd() - 3 hours);
        vm.prank(alice);
        d.farm.repairCable(true);
        calmNext();
        step();
        (, uint256 productive,,) = d.rewards.shares(3, alice);
        assertEq(productive, 6000 / 2);
        calmNext();
        step();
        (, productive,,) = d.rewards.shares(4, alice);
        assertGt(productive, 0);
    }

    function testFuzzCableRepairBlendHandlesNonMonotonicRarityBonuses(uint16 part) public {
        uint256 fraction = bound(part, 1, 10000);
        vm.mockCall(
            address(d.params), abi.encodeCall(d.params.get, (Params.Key.MythicSetBps)), abi.encode(uint256(1500))
        );
        vm.mockCall(
            address(d.params), abi.encodeCall(d.params.get, (Params.Key.LegendarySetBps)), abi.encode(uint256(2000))
        );
        FarmEngine.Snapshot memory snap;
        uint8[6] memory kinds = [uint8(8), 3, 4, 6, 7, 9];
        snap.paid = true;
        snap.theftUntil = 2;
        for (uint256 i; i < 6; ++i) {
            snap.ids[i] = mintItem(alice, kinds[i], i < 3 ? 4 : 3);
            snap.health[i] = i == 0 ? 0 : 10000;
        }
        FarmEngine.RoomStats memory blocked = d.engine.stats(snap, 0, false, 1);
        snap.theftUntil = 0;
        FarmEngine.RoomStats memory restored = d.engine.stats(snap, 0, false, 1);
        assertLt(restored.bonus, blocked.bonus);
        assertLt(restored.productive, blocked.productive);
        snap.theftUntil = 2;
        snap.routerRepairBps = uint16(fraction);
        FarmEngine.RoomStats memory mixed = d.engine.stats(snap, 0, false, 1);
        assertEq(mixed.productive, (blocked.productive * (10000 - fraction) + restored.productive * fraction) / 10000);
        assertEq(mixed.bonus, (blocked.bonus * (10000 - fraction) + restored.bonus * fraction) / 10000);
    }

    function testRegisterOnlyAccountsDoNotAddSettlementWorkAndEmptyFarmCanRetire() public {
        vm.prank(bob);
        d.farm.register(bob);
        assertEq(d.farm.count(), 0);
        place(alice, 0, 0, 0);
        assertEq(d.farm.count(), 1);
        vm.expectRevert(Unauthorized.selector); // v3.14: only the owner retires their farm
        d.farm.retire(alice);
        vm.expectRevert(InvalidValue.selector);
        vm.prank(alice);
        d.farm.retire(alice);
        vm.prank(alice);
        d.farm.unplace(0, 0);
        vm.expectRevert(Unauthorized.selector);
        vm.prank(bob);
        d.farm.retire(alice);
        vm.prank(alice);
        d.farm.retire(alice);
        assertEq(d.farm.count(), 0);
        assertTrue(d.farm.hasFarm(alice));
    }
}
