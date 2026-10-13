// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {BaseTest} from "./Base.t.sol";
import {TestV4Market, MockV4Manager} from "./mocks/MockV4Manager.sol";
import {SwapParams} from "../src/interfaces/IV4.sol";
import {GridOperator} from "../src/GridOperator.sol";
import {GameRegistry} from "../src/GameRegistry.sol";
import {MarketFactory} from "../src/MarketFactory.sol";
import {V4Market} from "../src/V4Market.sol";
import {FeeRouter} from "../src/FeeRouter.sol";
import {ModuleCode} from "../src/lib/ModuleCode.sol";
import {SwarmCode} from "../src/lib/SwarmCode.sol";
import {LocalApplicationFactory} from "../script/Deploy.s.sol";
import "../src/lib/Errors.sol";

/// @notice v3.9: 1% hook share to rewards, no network share, no team half of the base fee, severity floor 3000,
/// dual toolchain pins.
contract V39Test is BaseTest {
    MockV4Manager private manager;
    TestV4Market private hook;

    function setUp() public override {
        super.setUp();
        manager = new MockV4Manager();
        hook = new TestV4Market(address(manager), address(token), address(desk), bindingConfigHash());
        d.fees = canonicalFees(address(hook));
        bindHook(hook, address(d.fees));
        vm.deal(address(manager), 10000 ether);
        token.transfer(address(manager), 10000 ether);
        manager.initializeHook(hook);
    }

    // ------------------------------------------------------------------ severity floor

    function testGridAcceptsSeverityFromThreeThousandAndRejectsBelow() public {
        // canonicalFees() re-points d.grid at the hook fixture's twin graph; the epochs run on the fixture graph.
        GridOperator grid = GridOperator(d.registry.module(7));
        uint256 e = d.rewards.epoch() + 1;
        assertEq(grid.SEVERITY_FLOOR(), 3000);
        vm.expectRevert(InvalidValue.selector);
        vm.prank(swarm);
        grid.submitPlan(e, GridOperator.Kind.Outage, 2999, keccak256("plan"), "too mild");
        vm.expectRevert(InvalidValue.selector);
        vm.prank(swarm);
        grid.submitPlan(e, GridOperator.Kind.Outage, 10001, keccak256("plan"), "too severe");
        vm.expectRevert(Unauthorized.selector);
        grid.submitPlan(e, GridOperator.Kind.Outage, 3000, keccak256("plan"), "not the desk");
        vm.prank(swarm);
        grid.submitPlan(e, GridOperator.Kind.Outage, 3000, keccak256("plan"), "floor severity");
        assertEq(grid.planAt(e).severity, 3000);
        // The resolved event carries the planned floor severity (epoch e starts, then resolves when e + 1 starts).
        entropy();
        vm.warp(d.rewards.epochEnd());
        d.rewards.advanceEpoch();
        assertEq(d.rewards.epoch(), e);
        entropy();
        vm.warp(d.rewards.epochEnd());
        d.rewards.advanceEpoch();
        (GridOperator.Kind kind, uint16 severity,,, bool resolved) = grid.eventAt(e);
        assertTrue(resolved);
        assertEq(uint256(kind), uint256(GridOperator.Kind.Outage));
        assertEq(severity, 3000);
        (, uint16 settledSeverity,,,) = d.rewards.eventAt(e);
        assertEq(settledSeverity, 3000);
        // The Desk band stays narrower than the on-chain floor.
        assertEq(desk.SEVERITY_MIN(), 5000);
        assertEq(desk.SEVERITY_MAX(), 7000);
        assertLt(grid.SEVERITY_FLOOR(), desk.SEVERITY_MIN());
    }

    // ------------------------------------------------------------------ fee router base stream

    function testBaseDepositsAreEntirelyRewardEth() public {
        uint256 team0 = d.fees.credit(team);
        uint256 h0 = d.fees.heartbeatBalance();
        d.fees.depositBaseFee{value: 1 ether}();
        assertEq(d.fees.rewardETH(), 1 ether);
        // Plain ETH transfers from any sender follow the same base routing.
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool ok,) = address(d.fees).call{value: 0.5 ether}("");
        assertTrue(ok);
        assertEq(d.fees.rewardETH(), 1.5 ether);
        assertEq(d.fees.credit(team), team0);
        assertEq(d.fees.heartbeatBalance(), h0);
        assertEq(d.fees.potETH(), 0);
        vm.expectRevert(InvalidValue.selector);
        d.fees.depositBaseFee{value: 0}();
    }

    // ------------------------------------------------------------------ hook share

    function testHookAddsExactlyOnePercentOnBuysAndSellsAfterLaunchWindow() public {
        vm.warp(hook.initializedAt() + 60 minutes);
        SwapParams memory buy = SwapParams(true, -int256(3 ether), 4295128740);
        (, int256 delta,) = manager.invokeBefore(hook, buy);
        assertEq(uint256(delta >> 128), 0.03 ether);
        // Record the buy volume as the pool would after the swap.
        manager.invokeAfter(hook, buy, (int256(-int128(int256(3 ether))) << 128) | int256(uint256(uint128(3 ether))));
        assertEq(hook.heldBase(), 0.03 ether);
        assertEq(hook.heldSellTax(), 0);
        assertEq(hook.heldLaunchTax(), 0);
        // A sell smaller than the preceding buys has no imbalance and no deviation: exactly 1%.
        SwapParams memory p = SwapParams(false, -int256(1 ether), type(uint160).max - 1);
        manager.invokeBefore(hook, p);
        int256 sellDelta = (int256(0.1 ether) << 128) | int256(uint256(uint128(type(uint128).max - 1)));
        (, int128 fee) = manager.invokeAfter(hook, p, sellDelta);
        assertEq(uint256(uint128(fee)), 0.001 ether);
        assertEq(hook.heldBase(), 0.031 ether);
        assertEq(hook.heldSellTax(), 0);
        hook.flushFees();
        assertEq(d.fees.rewardETH(), 0.031 ether);
        assertEq(d.fees.credit(team), 0);
        assertEq(hook.PROJECT_BPS(), 100);
        assertEq(hook.projectBps(), 100);
        assertEq(hook.currentBuyTaxBps(), 100);
        // v3.14: quotes net the pool's 1.25% LP fee as well as the hook's 1% (0.99 x 0.9875).
        assertEq(hook.quote(1 ether), 0.977625 ether);
        assertEq(hook.quoteSell(1 ether), 0.977625 ether);
    }

    function testSellSurchargeStillProgressiveAndCappedAtFifteenPercent() public {
        vm.warp(hook.initializedAt() + 31 minutes);
        manager.setSqrt(uint160(4 << 96));
        SwapParams memory p = SwapParams(false, -int256(1 ether), type(uint160).max - 1);
        manager.invokeBefore(hook, p);
        int256 sellDelta = (int256(10 ether) << 128) | int256(uint256(uint128(type(uint128).max - 1)));
        (, int128 fee) = manager.invokeAfter(hook, p, sellDelta);
        assertGt(uint256(uint128(fee)), 0.1 ether);
        assertLe(uint256(uint128(fee)), 1.5 ether);
        assertEq(hook.heldBase(), 0.1 ether, "base stays exactly 1% of the output");
        assertEq(hook.heldSellTax(), uint256(uint128(fee)) - 0.1 ether);
        assertEq(hook.TOTAL_CAP_BPS(), 1500);
    }

    function testStepLaunchTaxUnchangedAndFullyToRewards() public {
        (, int256 delta,) = manager.invokeBefore(hook, SwapParams(true, -int256(1 ether), 4295128740));
        assertEq(uint256(delta >> 128), 0.9 ether);
        vm.warp(hook.initializedAt() + 10 minutes);
        (, delta,) = manager.invokeBefore(hook, SwapParams(true, -int256(1 ether), 4295128740));
        assertEq(uint256(delta >> 128), 0.5 ether);
        vm.warp(hook.initializedAt() + 20 minutes);
        (, delta,) = manager.invokeBefore(hook, SwapParams(true, -int256(1 ether), 4295128740));
        assertEq(uint256(delta >> 128), 0.25 ether);
        assertEq(hook.heldLaunchTax(), 1.65 ether);
        assertEq(hook.heldBase(), 0);
        hook.flushFees();
        assertEq(d.fees.rewardETH(), 1.65 ether);
        assertEq(d.fees.credit(team), 0);
    }

    function testHookHasNoNetworkShareRecipientOrWithdrawal() public {
        bytes4[4] memory removed = [
            bytes4(keccak256("NETWORK_BPS()")),
            bytes4(keccak256("networkRecipient()")),
            bytes4(keccak256("networkCredit()")),
            bytes4(keccak256("withdrawNetwork()"))
        ];
        for (uint256 i; i < 4; ++i) {
            (bool ok,) = address(hook).call(abi.encodeWithSelector(removed[i]));
            assertFalse(ok);
        }
        vm.expectRevert(InvalidValue.selector);
        new V4Market(address(manager), address(token), 12499, 60, address(this), address(desk), bindingConfigHash());
    }

    function testMarketFactoryConfigHasNoNetworkRecipient() public {
        MarketFactory factory = new MarketFactory();
        MarketFactory.Config memory c = MarketFactory.Config(
            address(manager), address(token), 60, address(this), address(desk), bindingConfigHash()
        );
        (bytes32 salt, address predicted) = factory.findSalt(c, 0, 100000);
        V4Market deployed = factory.deploy(c, salt);
        assertEq(address(deployed), predicted);
        assertEq(deployed.poolFee(), 12500);
        assertEq(deployed.PROJECT_BPS(), 100);
        assertEq(deployed.currentBuyTaxBps(), 9000);
    }

    // ------------------------------------------------------------------ dual toolchain pins

    function testRegistryAcceptsEitherToolchainPinAndNothingElse() public {
        LocalApplicationFactory f = deployment.localFactory();
        GameRegistry r = new GameRegistry(
            address(token), address(d.params), address(market), keccak256("root"), freePackRoot(), 123, 0
        );
        for (uint256 role; role < 14; ++role) {
            (bytes32 launchPin, bytes32 repoPin) = r.creationCodeHashes(role);
            assertTrue(r.acceptsCreationCode(role, launchPin));
            assertTrue(r.acceptsCreationCode(role, repoPin));
            assertEq(r.creationCodeHash(role), launchPin);
            assertTrue(ModuleCode.matches(role, launchPin) && ModuleCode.matches(role, repoPin));
            assertFalse(r.acceptsCreationCode(role, keccak256(abi.encode(role, "forged"))));
            // A pin of another role never matches.
            assertFalse(ModuleCode.matches((role + 1) % 14, launchPin));
        }
        assertFalse(ModuleCode.matches(14, ModuleCode.launchHash(0)));
        vm.expectRevert(InvalidValue.selector);
        r.creationCodeHashes(14);
        // Registration with a byte-modified copy of a genuine build is refused before any prediction.
        bytes memory code = vm.getCode("RewardPool.sol:RewardPool");
        vm.expectRevert(InvalidValue.selector);
        r.register(0, 5, 0, abi.encodePacked(code, bytes1(0x00)));
        assertTrue(SwarmCode.isRegistry(SwarmCode.REGISTRY_LAUNCH) && SwarmCode.isRegistry(SwarmCode.REGISTRY_REPO));
        assertTrue(SwarmCode.isParams(SwarmCode.PARAMS_LAUNCH) && SwarmCode.isParams(SwarmCode.PARAMS_REPO));
        assertFalse(SwarmCode.isRegistry(SwarmCode.PARAMS_LAUNCH));
        assertFalse(SwarmCode.isParams(SwarmCode.REGISTRY_REPO));
        assertFalse(SwarmCode.isRegistry(bytes32(0)));
    }
}
