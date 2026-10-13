// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {BaseTest} from "./Base.t.sol";
import {EndowmentEscrow} from "../src/EndowmentEscrow.sol";
import {GameRegistry} from "../src/GameRegistry.sol";
import {RewardPool} from "../src/RewardPool.sol";
import {Params} from "../src/Params.sol";
import {LocalApplicationFactory} from "../script/Deploy.s.sol";
import {SwarmDesk} from "../src/SwarmDesk.sol";
import {SwarmArgs} from "../script/SwarmArgs.sol";
import {MockToken} from "./mocks/MockToken.sol";
import {IMD} from "../src/lib/IMD.sol";
import "../src/lib/Errors.sol";

/// @dev v3.8: the token launch's remainderTo is an ownerless escrow deployed before the token; it forwards
/// its whole balance once to the RewardPool of the registry the Desk bound to, proven on chain.
contract EndowmentEscrowV38Test is BaseTest {
    EndowmentEscrow private escrow;
    bytes private registryCode;
    bytes private poolCode;

    function launchFeatures() internal pure override returns (bool) {
        return false;
    }

    function setUp() public override {
        super.setUp();
        vm.clearMockedCalls();
        LocalApplicationFactory f = LocalApplicationFactory(address(d.registry.factory()));
        escrow = new EndowmentEscrow(address(desk));
        registryCode = type(GameRegistry).creationCode;
        poolCode = vm.getCode("RewardPool.sol:RewardPool");
    }

    function testConstructorRejectsMissingInputs() public {
        vm.expectRevert(InvalidValue.selector);
        new EndowmentEscrow(address(0));
        vm.expectRevert(InvalidValue.selector);
        new EndowmentEscrow(IMD.PROJECT_FACTORY);
        vm.expectRevert(InvalidValue.selector);
        new EndowmentEscrow(IMD.PROJECT_RECORDS);
        // v3.14: the factory and its launch registry are bytecode constants, never constructor words.
        assertEq(escrow.factory(), IMD.PROJECT_FACTORY);
        assertEq(escrow.records(), IMD.PROJECT_RECORDS);
    }

    function testForwardSendsWholeBalanceOnceToAuthenticatedPoolAndFundsEndowment() public {
        uint256 amount = 200_000_000 ether;
        token.transfer(address(escrow), amount);
        assertEq(token.balanceOf(address(escrow)), amount);
        vm.expectRevert(AlreadyDone.selector);
        d.pool.fundEndowment(); // Fixture endowment is zero; a zero principal is never "funded".
        uint256 before_ = token.balanceOf(address(d.pool));
        vm.prank(bob);
        uint256 sent = escrow.forward(address(d.registry), 1, 1, registryCode, 1, 2, poolCode);
        assertEq(sent, amount);
        assertEq(token.balanceOf(address(escrow)), 0);
        assertEq(token.balanceOf(address(d.pool)), before_ + amount);
        assertTrue(escrow.forwarded());
        token.transfer(address(escrow), 1 ether);
        vm.expectRevert(AlreadyDone.selector);
        escrow.forward(address(d.registry), 1, 1, registryCode, 1, 2, poolCode);
    }

    function testForwardWithRealEndowmentActivatesDrip() public {
        // A registry with a 20% endowment, bound to a fresh Desk, at fresh coordinates of the fixture factory.
        uint256 endowment = 200_000_000 ether;
        (address fresh, GameRegistry r, RewardPool pool) = _freshGame(endowment, address(token));
        EndowmentEscrow e = new EndowmentEscrow(fresh);
        token.transfer(address(e), endowment);
        // The fixture registry is not the one this Desk bound to.
        vm.expectRevert(InvalidProof.selector);
        e.forward(address(d.registry), 1, 1, registryCode, 1, 2, poolCode);
        assertEq(pool.available(), 0);
        vm.expectRevert(InsufficientBalance.selector);
        pool.fundEndowment();
        e.forward(address(r), 21, 1, registryCode, 22, 0, poolCode);
        assertEq(token.balanceOf(address(pool)), endowment);
        pool.fundEndowment();
        assertTrue(pool.endowed());
        assertEq(pool.lockedEndowment(), endowment);
        vm.warp(block.timestamp + 21 days);
        assertEq(pool.lockedEndowment(), endowment / 2);
    }

    /// @dev Launches Desk (20/0), Params (21/0), Registry (21/1) and RewardPool (22/0) through the fixture factory
    /// and binds the Desk. Split into helpers so the test compiles without via-IR (IMD verifier settings).
    function _freshGame(uint256 endowment, address gameToken)
        private
        returns (address fresh, GameRegistry r, RewardPool pool)
    {
        LocalApplicationFactory f = LocalApplicationFactory(address(d.registry.factory()));
        bytes32 configHash = keccak256(
            abi.encode(d.registry.starterRoot(), d.registry.freeRoot(), d.registry.snapshotBlock(), endowment)
        );
        fresh = f.deploy(20, 0, bytes.concat(vm.getCode("SwarmDesk.sol:SwarmDesk"), _deskWords(address(f), configHash)));
        Params p = Params(
            f.deploy(21, 0, bytes.concat(type(Params).creationCode, abi.encode(fresh, uint256(200), uint256(1 ether))))
        );
        r = GameRegistry(
            f.deploy(21, 1, bytes.concat(registryCode, _registryArgs(gameToken, address(p), endowment, address(f))))
        );
        pool = RewardPool(f.deploy(22, 0, bytes.concat(poolCode, abi.encode(address(r)))));
        r.register(0, 22, 0, poolCode);
        market.configureHook(fresh, configHash); // the mock market answers the v3.14 bind probe for this Desk
        (bool ok,) = fresh.call(
            abi.encodeWithSignature(
                "bind(address,bytes,bytes,uint64,uint8,uint64,uint8)",
                address(r),
                registryCode,
                type(Params).creationCode,
                uint64(21),
                uint8(1),
                uint64(21),
                uint8(0)
            )
        );
        // v3.14: bind probes the market; a registry naming a token the hook was not launched for is refused.
        assertEq(ok, gameToken == address(token), "bind");
    }

    function _registryArgs(address gameToken, address params, uint256 endowment, address)
        private
        view
        returns (bytes memory)
    {
        return abi.encode(
            gameToken,
            params,
            address(market),
            d.registry.starterRoot(),
            d.registry.freeRoot(),
            d.registry.snapshotBlock(),
            endowment
        );
    }

    /// @dev v3.10 review (twin front-run): a twin game bound to the Desk with a token other than the launched
    /// token cannot move the escrowed launch tokens; forward reads the bound registry's token and finds nothing.
    /// Capturing the endowment needs the real token AND the private game configuration (roots, snapshot,
    /// endowment) before the honest Desk.bind, which is why the runbook binds right after job A.
    function testTwinWithForeignTokenCannotDrainEscrow() public {
        uint256 endowment = 200_000_000 ether;
        MockToken other = new MockToken();
        (address fresh, GameRegistry twin, RewardPool pool) = _freshGame(endowment, address(other));
        // v3.14 (audit a8730286 M): the twin never captures the Desk, so the escrow stays forwardable to the
        // honest game; the forward to the twin fails on the Desk check rather than on an empty balance.
        assertEq(address(SwarmDesk(fresh).registry()), address(0));
        EndowmentEscrow e = new EndowmentEscrow(fresh);
        token.transfer(address(e), endowment);
        vm.expectRevert(InvalidProof.selector);
        e.forward(address(twin), 21, 1, registryCode, 22, 0, poolCode);
        assertEq(token.balanceOf(address(e)), endowment);
        assertEq(token.balanceOf(address(pool)), 0);
        assertFalse(e.forwarded());
    }

    function testForwardRejectsBadProofs() public {
        token.transfer(address(escrow), 1 ether);
        vm.expectRevert(InvalidValue.selector);
        escrow.forward(address(d.registry), 0, 1, registryCode, 1, 2, poolCode);
        vm.expectRevert(InvalidValue.selector);
        escrow.forward(address(d.registry), 1, 8, registryCode, 1, 2, poolCode);
        vm.expectRevert(InvalidProof.selector);
        escrow.forward(address(d.registry), 1, 1, hex"ff", 2, 0, poolCode);
        vm.expectRevert(InvalidProof.selector);
        escrow.forward(address(d.registry), 1, 1, registryCode, 2, 0, hex"ff");
        // Wrong coordinates for a real registry/pool.
        vm.expectRevert(InvalidProof.selector);
        escrow.forward(address(d.registry), 1, 0, registryCode, 1, 2, poolCode);
        vm.expectRevert(InvalidProof.selector);
        escrow.forward(address(d.registry), 1, 1, registryCode, 1, 3, poolCode);
        // Unrecorded launch number.
        vm.expectRevert(InvalidProof.selector);
        escrow.forward(address(d.registry), 77, 1, registryCode, 1, 2, poolCode);
        // A look-alike registry the Desk never bound to, even with the same configuration.
        GameRegistry spoof = new GameRegistry(
            address(token),
            address(d.params),
            address(market),
            d.registry.starterRoot(),
            d.registry.freeRoot(),
            d.registry.snapshotBlock(),
            d.registry.endowment()
        );
        vm.expectRevert(InvalidProof.selector);
        escrow.forward(address(spoof), 1, 1, registryCode, 1, 2, poolCode);
        assertEq(token.balanceOf(address(escrow)), 1 ether);
        assertFalse(escrow.forwarded());
    }

    function testForwardRequiresBalance() public {
        vm.expectRevert(InsufficientBalance.selector);
        escrow.forward(address(d.registry), 1, 1, registryCode, 1, 2, poolCode);
    }

    /// @dev Re-encode the fixture Desk's oracle configuration through the canonical twelve-word encoder.
    function _deskWords(address factory, bytes32 configHash) private view returns (bytes memory) {
        return
            SwarmArgs.encode(
                desk.oracleConfig(), SwarmDesk.BindingConfig(factory, 0, 0, 0, 0, configHash, 200, 1 ether)
            );
    }
}
