// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {BaseTest} from "./Base.t.sol";
import "../src/lib/Errors.sol";

contract PotV35Test is BaseTest {
    function _fundPot(uint256 amount) internal {
        token.transfer(address(d.season), amount);
        vm.prank(address(d.fees));
        d.season.depositPot(amount);
    }

    function _participant(address p) internal {
        vm.prank(address(d.farm));
        d.season.recordSpend(p, 3000 ether, true);
        for (uint256 i; i < 20; ++i) {
            vm.prank(address(d.rewards));
            d.season.recordActivity(p, 0, 100 ether, 10000);
        }
    }

    function _finalize() internal {
        vm.warp(tokenLaunch() + 7 days);
        entropy();
        d.rewards.advanceEpoch();
        vm.prank(address(d.rewards));
        d.season.complete(alice, 0);
        vm.prank(address(d.rewards));
        d.season.complete(bob, 0);
        vm.warp(d.season.deadline(0));
        d.season.prepare(0, 1);
        entropy();
        d.season.finalize(0);
    }

    function testPotSplitDistinctLotteryDistrictAndRollbackOnFullInventory() public {
        _fundPot(1000 ether);
        _participant(alice);
        _participant(bob);
        _finalize();
        (,, address best,,) = d.season.result(0);
        vm.prank(best);
        d.season.claimBest(0);
        assertEq(d.season.potRemaining(0), 600 ether);
        vm.expectRevert(InvalidValue.selector);
        vm.prank(best);
        d.season.claimBest(0);
        assertTrue(d.season.lotteryWon(0, alice));
        assertTrue(d.season.lotteryWon(0, bob));
        for (uint256 i; i < 15; ++i) {
            mintItem(alice, uint8(i % 12), 0);
        }
        // v3.14: the lottery item is a lazy pack receipt (like claimDistrict), so a full inventory never blocks
        // the 10% token share; the receipt is revealed later like any pack.
        uint256 before_ = token.balanceOf(alice);
        vm.prank(alice);
        uint256 id = d.season.claimLottery(0);
        assertTrue(d.season.lotteryClaimed(0, alice));
        assertEq(token.balanceOf(alice) - before_, 100 ether);
        (address receiptOwner,,,,, bool guaranteed,,,) = d.packs.commits(id);
        assertEq(receiptOwner, alice);
        assertTrue(guaranteed);
        vm.prank(bob);
        d.season.claimLottery(0);
        (, uint8 district,,,) = d.season.result(0);
        address winner = d.farm.district(alice) == district ? alice : bob;
        vm.prank(winner);
        d.season.claimDistrict(0);
        assertEq(d.season.potRemaining(0), 100 ether); // Missing third winner rolls over.
        assertEq(token.balanceOf(address(d.season)), 100 ether);
        assertEq(d.season.potLiability(), 100 ether);
    }

    function testPotUnclaimedRolloverOnlyAfterFourWeeksNoDoubleClaim() public {
        _fundPot(1000 ether);
        _participant(alice);
        _participant(bob);
        _finalize();
        vm.expectRevert(TooEarly.selector);
        d.season.rollover(0);
        vm.warp(d.season.claimDeadline(0));
        vm.expectRevert(TooEarly.selector);
        vm.prank(alice);
        d.season.claimLottery(0);
        d.season.rollover(0);
        uint256 current = (block.timestamp - tokenLaunch()) / 7 days;
        assertEq(d.season.potRemaining(0), 0);
        assertEq(d.season.pot(current), 1000 ether);
        assertEq(d.season.potLiability(), 1000 ether);
        vm.expectRevert(TooEarly.selector);
        d.season.rollover(0);
    }

    function testPotDepositRequiresActualTokensAndAuthority() public {
        vm.expectRevert(Unauthorized.selector);
        d.season.depositPot(1);
        vm.expectRevert(InvalidValue.selector);
        vm.prank(address(d.fees));
        d.season.depositPot(1);
        _fundPot(123 ether);
        assertEq(d.season.potRemaining(0), 123 ether);
    }
}
