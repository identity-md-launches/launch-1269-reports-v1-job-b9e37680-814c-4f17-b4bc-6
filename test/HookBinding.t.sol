// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {BaseTest} from "./Base.t.sol";
import {TestV4Market, MockV4Manager} from "./mocks/MockV4Manager.sol";
import {FeeRouter} from "../src/FeeRouter.sol";
import {SwapParams} from "../src/interfaces/IV4.sol";
import "../src/lib/Errors.sol";

contract RejectingHookRouter {
    address public token;
    address public market;
    address public params;

    constructor(address t, address m, address p) {
        token = t;
        market = m;
        params = p;
    }

    function depositBaseFee() external payable {
        revert("reject");
    }

    function depositSellTax() external payable {
        revert("reject");
    }
}

contract HookBindingTest is BaseTest {
    TestV4Market private hook;
    MockV4Manager private manager;

    function setUp() public override {
        super.setUp();
        manager = new MockV4Manager();
        hook = new TestV4Market(address(manager), address(token), address(desk), bindingConfigHash());
        vm.deal(address(manager), 100 ether);
        manager.initializeHook(hook);
        vm.warp(vm.getBlockTimestamp() + 60 minutes); // past the v3.3 launch tax and max-buy window
    }

    function _buy() private {
        manager.invokeBefore(hook, SwapParams(true, -int256(1 ether), 4295128740));
    }

    function _sell() private {
        SwapParams memory p = SwapParams(false, -int256(1 ether), type(uint160).max - 1);
        manager.invokeBefore(hook, p);
        manager.invokeAfter(hook, p, (int256(1 ether) << 128) | int256(uint256(type(uint128).max - 1)));
    }

    function testHoldBeforeGameExistsThenBindOnceAndFlushExactStreams() public {
        _buy();
        _sell();
        assertEq(address(hook.fees()), address(0));
        assertEq(address(hook.params()), address(0));
        uint256 base = hook.heldBase();
        uint256 surcharge = hook.heldSellTax();
        assertEq(base, 0.02 ether); // 1% of the 1 ETH buy and 1% of the 1 ETH sell output
        assertGt(surcharge, 0);
        assertEq(address(hook).balance, base + surcharge);
        vm.expectRevert(NotConfigured.selector);
        hook.flushFees();
        FeeRouter f = canonicalFees(address(hook));
        vm.prank(team);
        bindHook(hook, address(f));
        assertEq(address(hook.fees()), address(f));
        assertEq(address(hook.params()), address(d.params));
        vm.expectRevert(AlreadyDone.selector);
        vm.prank(team);
        bindHook(hook, address(f));
        vm.prank(bob);
        hook.flushFees();
        assertEq(hook.heldBase(), 0);
        assertEq(hook.heldSellTax(), 0);
        assertEq(f.credit(team), surcharge * 1000 / 10000, "team gets nothing from the base stream");
        assertEq(f.heartbeatBalance(), surcharge * 200 / 10000);
        assertEq(f.credit(team) + f.heartbeatBalance() + f.rewardETH() + f.potETH(), base + surcharge);
        assertEq(address(hook).balance, 0);
        vm.expectRevert(InsufficientBalance.selector);
        hook.flushFees();
        _buy();
        assertEq(hook.heldBase(), 0.01 ether);
        hook.flushFees();
    }

    function testWrongRouterAndMissingCodeRejectedBeforePermanentBind() public {
        vm.expectRevert(InvalidAddress.selector);
        vm.prank(team);
        bindHook(hook, alice);
        vm.expectRevert();
        vm.prank(team);
        bindHook(hook, address(d.fees));
        assertEq(address(hook.fees()), address(0));
        FeeRouter f = canonicalFees(address(hook));
        vm.prank(team);
        bindHook(hook, address(f));
    }

    function testLookAlikeCannotBindEvenWhenTeamCalls() public {
        _buy();
        RejectingHookRouter f = new RejectingHookRouter(address(token), address(hook), address(d.params));
        vm.expectRevert();
        vm.prank(team);
        bindHook(hook, address(f));
        assertEq(address(hook.fees()), address(0));
        assertEq(hook.heldBase(), 0.01 ether);
        _buy();
        assertEq(hook.heldBase(), 0.02 ether);
    }
}
