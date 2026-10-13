// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "./Base.t.sol";
import {TestV4Market, StrictTestV4Market, MockV4Manager} from "./mocks/MockV4Manager.sol";
import {FarmRewards} from "../src/FarmRewards.sol";
import {GameRegistry} from "../src/GameRegistry.sol";
import {FeeRouter} from "../src/FeeRouter.sol";
import {GridOperator} from "../src/GridOperator.sol";
import {Params} from "../src/Params.sol";
import "../src/lib/Errors.sol";

/// @notice Regression cases written by the separate v3.4 review contributor.
contract ReviewV34Test is BaseTest {
    function testLateGreenEntrySettlesWithinReservedEnvelope() public {
        fund(1_000_000 ether);
        uint256 closing = d.rewards.epochEnd();
        vm.warp(closing - 8);
        place(alice, 0, 0, 0); // Unpaid common compute: 10,000 full-epoch hash.
        assertEq(d.rewards.entrySeconds(1, alice), 8);
        assertEq(d.rewards.entryWeight(1, alice), 3);

        // Without the entry rounding fix, floor(5,500 * 8 / 21,600) = 2 productive
        // hash exceeds floor(1 * 110%) = 1 reserved hash, permanently reverting settle.
        vm.mockCall(
            address(d.grid),
            abi.encodeCall(d.grid.eventAt, (uint256(1))),
            abi.encode(
                GridOperator.Kind.Green,
                uint16(10000),
                uint8(d.farm.district(alice)),
                keccak256("review late Green"),
                true
            )
        );
        uint256 available = d.pool.available();
        entropy();
        vm.warp(closing);
        d.rewards.advanceEpoch();
        d.rewards.settle(alice, 8);

        FarmRewards.Epoch memory e = d.rewards.epochData(1);
        assertEq(e.mining, available * 350 * 8 / (40000 * 6 hours));
        assertEq(e.settledHash, e.raw);
        assertLe(e.spent, e.budget);
        assertEq(d.rewards.lastSettled(alice), 1);
        assertGt(d.rewards.pending(alice), 0);
        assertLe(d.pool.reserved(), token.balanceOf(address(d.pool)));
        vm.prank(alice);
        d.farm.sync(); // The player can continue playing after the entry epoch.
    }

    function _router(address hook, address params_, uint64 registryLaunch) private returns (FeeRouter router) {
        bytes memory registryCode = bytes.concat(
            type(GameRegistry).creationCode,
            abi.encode(
                address(token),
                params_,
                hook,
                keccak256(abi.encode(uint256(17), alice)),
                freePackRoot(),
                uint256(23_000_000),
                uint256(0)
            )
        );
        GameRegistry registry = GameRegistry(bindingFactory.deploy(registryLaunch, 1, registryCode));
        bytes memory routerCode = vm.getCode("FeeRouter.sol:FeeRouter");
        router =
            FeeRouter(payable(bindingFactory.deploy(10, 0, bytes.concat(routerCode, abi.encode(address(registry))))));
        registry.register(6, 10, 0, routerCode);
        assertEq(registry.module(6), address(router));
        assertEq(address(router.registry()), address(registry));
    }

    function testCanonicalCompetingRegistryCannotTakeOverBinding() public {
        MockV4Manager manager = new MockV4Manager();
        TestV4Market hook = new TestV4Market(address(manager), address(token), address(desk), bindingConfigHash());
        Params attackerParams = new Params(bob, 200, 1 ether);
        FeeRouter competing = _router(address(hook), address(attackerParams), 7);

        // The attacker has exact canonical registry/router code from the intended factory,
        // the correct token/hook and back-reference, and the intended deployment coordinates.
        // The immutable game-configuration commitment must still reject their Params.
        vm.expectRevert(InvalidProof.selector);
        vm.prank(bob);
        bindHook(hook, address(competing));
        assertEq(address(hook.fees()), address(0));

        // The production factory admits a launch number only once. A wrongly authorized
        // configuration cannot be replaced at its reserved coordinate: stop that launch.
        vm.expectRevert(AlreadyDone.selector);
        bindingFactory.deploy(7, 1, hex"00");
        assertEq(address(hook.fees()), address(0));
    }

    /// @dev v3.8: a twin registry with identical configuration and canonical Params at other coordinates
    /// passes every static proof but is not the registry the Desk bound to, so the strict hook refuses it.
    function testSameConfigurationAtUncommittedCoordinatesCannotBind() public {
        MockV4Manager manager = new MockV4Manager();
        StrictTestV4Market hook =
            new StrictTestV4Market(address(manager), address(token), address(desk), bindingConfigHash());
        FeeRouter competing = _router(address(hook), address(d.params), 8);
        vm.expectRevert(InvalidProof.selector);
        vm.prank(bob);
        hook.bindFeeRouter(address(competing), 8, 1);
        // Wrong coordinates for the same twin are refused as well.
        vm.expectRevert(InvalidProof.selector);
        hook.bindFeeRouter(address(competing), 9, 1);
        assertEq(address(hook.fees()), address(0));
    }

    function testDustBuyCannotConsumeGlobalBuyInterval() public {
        d.fees.depositBaseFee{value: 1 ether}();
        uint256 reward = d.fees.rewardETH();
        uint256 dustQuote = market.quote(1);
        assertGt(dustQuote, 0);
        vm.expectRevert(InvalidValue.selector);
        vm.prank(bob);
        d.fees.executeBuys(1, dustQuote);
        assertEq(d.fees.lastBuy(), 0);
        assertEq(d.fees.rewardETH(), reward);

        uint256 batch = d.params.get(Params.Key.BuyBatch);
        uint256 q = market.quote(batch);
        vm.prank(bob);
        d.fees.executeBuys(batch, q);
        assertEq(d.fees.lastBuy(), block.timestamp);
        assertEq(d.fees.rewardETH(), reward - batch);
    }

    function testMeaningfulSmallBuyCanUseLessThanMaximumBatch() public {
        d.fees.depositBaseFee{value: 1 ether}();
        uint256 reward = d.fees.rewardETH();
        uint256 amount = 0.05 ether;
        assertLt(amount, d.params.get(Params.Key.BuyBatch));
        uint256 minimum = market.quote(amount);
        vm.prank(bob);
        d.fees.executeBuys(amount, minimum);
        assertEq(d.fees.rewardETH(), reward - amount);
        assertEq(d.fees.lastBuy(), block.timestamp);
    }
}
