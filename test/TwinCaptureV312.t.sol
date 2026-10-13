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
import "../src/lib/Errors.sol";

/// @dev v3.12 (docs/m2-trust-assumption.md): what a twin capture of `SwarmDesk.bind` can and cannot do. Test only;
/// no contract changed. The attacker knows the private configuration and launches a byte-identical twin
/// (Params + GameRegistry + RewardPool from the pinned code) through the same factory before the honest bind.
contract TwinCaptureV312Test is BaseTest {
    uint256 private constant ENDOWMENT = 200_000_000 ether;
    address private attacker;
    LocalApplicationFactory private f;
    address private freshDesk;
    EndowmentEscrow private escrow;
    bytes private registryCode;
    bytes private poolCode;

    struct Game {
        Params params;
        GameRegistry registry;
        RewardPool pool;
    }

    function launchFeatures() internal pure override returns (bool) {
        return false;
    }

    function setUp() public override {
        super.setUp();
        vm.clearMockedCalls();
        attacker = makeAddr("attacker");
        f = LocalApplicationFactory(address(d.registry.factory()));
        registryCode = type(GameRegistry).creationCode;
        poolCode = vm.getCode("RewardPool.sol:RewardPool");
        bytes32 configHash = keccak256(
            abi.encode(d.registry.starterRoot(), d.registry.freeRoot(), d.registry.snapshotBlock(), ENDOWMENT)
        );
        freshDesk = f.deploy(
            40,
            0,
            bytes.concat(
                vm.getCode("SwarmDesk.sol:SwarmDesk"),
                SwarmArgs.encode(
                    desk.oracleConfig(), SwarmDesk.BindingConfig(address(f), 0, 0, 0, 0, configHash, 200, 1 ether)
                )
            )
        );
        escrow = new EndowmentEscrow(freshDesk);
        market.configureHook(freshDesk, configHash); // the mock market answers the v3.14 bind probe for this Desk
        token.transfer(address(escrow), ENDOWMENT); // the token launch's remainderTo share
    }

    /// @dev Params at (launch, 0), Registry at (launch, 1), RewardPool at (launch, 2), pool registered as role 0.
    function _launch(uint64 launch) private returns (Game memory g) {
        g.params = Params(
            f.deploy(
                launch,
                0,
                bytes.concat(type(Params).creationCode, abi.encode(freshDesk, uint256(200), uint256(1 ether)))
            )
        );
        bytes memory args = abi.encode(
            address(token),
            address(g.params),
            address(market),
            d.registry.starterRoot(),
            d.registry.freeRoot(),
            d.registry.snapshotBlock(),
            ENDOWMENT
        );
        g.registry = GameRegistry(f.deploy(launch, 1, bytes.concat(registryCode, args)));
        g.pool = RewardPool(f.deploy(launch, 2, bytes.concat(poolCode, abi.encode(address(g.registry)))));
        g.registry.register(0, launch, 2, poolCode);
    }

    function _bind(Game memory g, uint64 launch) private returns (bool ok, bytes memory ret) {
        (ok, ret) = freshDesk.call(
            abi.encodeWithSignature(
                "bind(address,bytes,bytes,uint64,uint8,uint64,uint8)",
                address(g.registry),
                registryCode,
                type(Params).creationCode,
                launch,
                uint8(1),
                launch,
                uint8(0)
            )
        );
    }

    /// Success path without a twin: the honest game binds and the escrow pays its pinned RewardPool.
    function testHonestBindThenForwardReachesHonestPool() public {
        Game memory honest = _launch(41);
        (bool ok,) = _bind(honest, 41);
        assertTrue(ok);
        escrow.forward(address(honest.registry), 41, 1, registryCode, 41, 2, poolCode);
        assertEq(token.balanceOf(address(honest.pool)), ENDOWMENT);
        honest.pool.fundEndowment();
        assertEq(honest.pool.lockedEndowment(), ENDOWMENT);
    }

    /// The twin wins the race: the honest bind is refused and the honest modules are orphaned.
    function testTwinCaptureOrphansHonestGame() public {
        vm.startPrank(attacker);
        Game memory twin = _launch(41);
        (bool ok,) = _bind(twin, 41);
        vm.stopPrank();
        assertTrue(ok);
        assertEq(address(SwarmDesk(freshDesk).registry()), address(twin.registry));

        Game memory honest = _launch(42);
        (bool ok2, bytes memory ret) = _bind(honest, 42);
        assertFalse(ok2);
        assertEq(bytes4(ret), AlreadyDone.selector);
        vm.expectRevert(InvalidProof.selector);
        escrow.forward(address(honest.registry), 42, 1, registryCode, 42, 2, poolCode);
        vm.expectRevert(InsufficientBalance.selector);
        honest.pool.fundEndowment();
        assertEq(token.balanceOf(address(escrow)), ENDOWMENT);
    }

    /// The escrow pays only the twin's pinned RewardPool, never a wallet or code of the attacker's choice, and
    /// nothing becomes withdrawable by the attacker.
    function testTwinCaptureCannotPayAttacker() public {
        uint256 attackerTokens = token.balanceOf(attacker);
        uint256 attackerEth = attacker.balance;
        vm.startPrank(attacker);
        Game memory twin = _launch(41);
        (bool ok,) = _bind(twin, 41);
        assertTrue(ok);

        // An attacker-chosen pool (other code, or a plain wallet) is refused.
        vm.expectRevert(InvalidProof.selector);
        escrow.forward(address(twin.registry), 41, 1, registryCode, 41, 2, type(MockToken).creationCode);
        vm.expectRevert(InvalidProof.selector);
        escrow.forward(address(twin.registry), 41, 1, registryCode, 41, 3, poolCode);

        // The only exit: the whole balance to the twin's pinned RewardPool.
        uint256 sent = escrow.forward(address(twin.registry), 41, 1, registryCode, 41, 2, poolCode);
        assertEq(sent, ENDOWMENT);
        assertEq(token.balanceOf(address(twin.pool)), ENDOWMENT);
        vm.expectRevert(NotConfigured.selector);
        twin.pool.rewards(); // no FarmRewards registered yet: nothing can pay out
        bytes memory rewardsCode = vm.getCode("FarmRewards.sol:FarmRewards");
        address farmRewards = f.deploy(41, 3, bytes.concat(rewardsCode, abi.encode(address(twin.registry))));
        twin.registry.register(1, 41, 3, rewardsCode);
        assertEq(twin.pool.rewards(), farmRewards);

        // The pool pays only its registry's pinned FarmRewards, by the mining rules; no withdrawal for anyone else.
        vm.expectRevert(Unauthorized.selector);
        twin.pool.pay(attacker, 1 ether);
        vm.expectRevert(Unauthorized.selector);
        twin.pool.reserve(1 ether);
        vm.expectRevert(Unauthorized.selector);
        twin.pool.recycle(1 ether);
        vm.expectRevert(AlreadyDone.selector);
        escrow.forward(address(twin.registry), 41, 1, registryCode, 41, 2, poolCode);
        vm.stopPrank();

        twin.pool.fundEndowment(); // the drip runs exactly as in the honest game
        assertEq(twin.pool.lockedEndowment(), ENDOWMENT);
        assertEq(token.balanceOf(attacker), attackerTokens);
        assertEq(attacker.balance, attackerEth);
        // The twin is governed by the same Desk: its Params answer only to the attested oracle.
        assertEq(twin.params.swarmWallet(), freshDesk);
    }
}
