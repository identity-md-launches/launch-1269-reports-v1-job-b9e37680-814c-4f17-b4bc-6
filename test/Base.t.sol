// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {Test} from "forge-std/Test.sol";
import {GameRegistry} from "../src/GameRegistry.sol";
import {RewardPool} from "../src/RewardPool.sol";
import {LocalApplicationFactory} from "../script/Deploy.s.sol";
import {Deploy} from "../script/Deploy.s.sol";
import {MockToken} from "./mocks/MockToken.sol";
import {MockMarket} from "./mocks/MockMarket.sol";
import {FarmCore} from "../src/FarmCore.sol";
import {FarmItems} from "../src/FarmItems.sol";
import {PackSale} from "../src/PackSale.sol";
import {FeeRouter} from "../src/FeeRouter.sol";
import {MockGameRegistry} from "./mocks/MockGameRegistry.sol";
import {SwarmDesk} from "../src/SwarmDesk.sol";
import {Params} from "../src/Params.sol";
import {V4Market} from "../src/V4Market.sol";
import {GridOperator} from "../src/GridOperator.sol";
import "../src/lib/Errors.sol";

abstract contract BaseTest is Test {
    Deploy.Deployment internal d;
    SwarmDesk internal desk;
    Deploy internal deployment;
    LocalApplicationFactory internal bindingFactory;
    MockToken internal token;
    MockMarket internal market;
    address internal alice;
    address internal bob;
    address internal swarm;
    address internal team;
    uint256 internal launch;

    function setUp() public virtual {
        vm.warp(1_800_000_000);
        vm.roll(1000);
        vm.txGasPrice(20_000_000);
        launch = block.timestamp;
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        swarm = makeAddr("swarm");
        team = 0x6d51cBE774aeAe4dd40bCA2560E9bc2695A0d007;
        token = new MockToken();
        market = new MockMarket(address(token));
        market.configureLaunch(launch - 1 hours, address(this));
        token.transfer(address(market), 100_000_000 ether);
        address fixture = makeAddr("deployment script fixture");
        vm.etch(fixture, vm.getDeployedCode("Deploy.s.sol:Deploy"));
        deployment = Deploy(fixture);
        bindingFactory = deployment.localFactory();
        d = deployment.deploy(
            Deploy.Config(
                address(token),
                abi.encode(oracleFixture()),
                address(market),
                launch - 1 hours,
                keccak256(abi.encode(uint256(17), alice)),
                freePackRoot(),
                23_000_000,
                0,
                200,
                1 ether
            )
        );
        market.configureLaunch(launch - 1 hours, address(d.fees));
        // Zero-endowment accounting fixtures explicitly mock only the purchase readiness flag.
        vm.mockCall(address(d.pool), abi.encodeWithSignature("endowed()"), abi.encode(true));
        vm.deal(alice, 10000 ether);
        vm.deal(bob, 10000 ether);
        vm.deal(address(this), 10000 ether);
        vm.deal(address(market), 10000 ether);
        token.transfer(alice, 10_000_000 ether);
        token.transfer(bob, 10_000_000 ether);
        vm.prank(alice);
        token.approve(address(d.farm), type(uint256).max);
        vm.prank(bob);
        token.approve(address(d.farm), type(uint256).max);
        swarm = d.params.swarmWallet();
        desk = SwarmDesk(swarm);
        // v3.6 ships growth features disabled; legacy fixtures enable them through the real notice path.
        if (launchFeatures()) {
            for (uint256 i = 3; i < 8; ++i) {
                enableFeature(i);
            }
        }
        vm.prank(alice);
        token.approve(address(d.packs), type(uint256).max);
        vm.prank(bob);
        token.approve(address(d.packs), type(uint256).max);
        vm.prank(alice);
        token.approve(address(d.economy), type(uint256).max);
        vm.prank(bob);
        token.approve(address(d.economy), type(uint256).max);
        d.rewards.advanceEpoch();
    }

    function freePackRoot() internal view virtual returns (bytes32) {
        return keccak256(abi.encode(uint256(0), alice));
    }

    function oracleFixture() internal returns (SwarmDesk.OracleConfig memory o) {
        o.intake = makeAddr("intake");
        o.delivery = makeAddr("delivery");
        o.signer = vm.addr(0x123456);
        o.asset = address(token);
        o.action = bytes32("oracle.request@oracle-1");
        o.maxPrice = 0.5 ether;
        o.questionChain = 1;
        o.fromBlock = 100;
        o.toBlock = 200;
        o.questions = [keccak256("event question"), keccak256("regulator question")];
        o.bodies = [keccak256("event body"), keccak256("regulator body")];
    }

    /// @dev Override to return false for a launch-core fixture (v3.6 phased release, nothing enabled).
    function launchFeatures() internal pure virtual returns (bool) {
        return true;
    }

    /// @dev Announce, wait the mandatory 48 hours, enable, then restore the fixture clock.
    function enableFeature(uint256 feature) internal {
        uint256 now_ = vm.getBlockTimestamp();
        vm.prank(swarm);
        d.civic.announce(feature, "v3.6 phase notice: feature opens in 48 hours");
        vm.warp(now_ + 48 hours);
        d.civic.enable(feature);
        vm.warp(now_);
    }

    /// @dev Fixture token launch is one hour before `launch`, so PackSale (launch + 60 min) is open at setUp.
    function tokenLaunch() internal view returns (uint256) {
        return launch - 1 hours;
    }

    /// @dev Legacy fixtures: backdate a registered farm by five days and give it level-10 XP.
    function veteran(address p) internal {
        bytes32 base = keccak256(abi.encode(p, uint256(3)));
        uint256 s0 = uint256(vm.load(address(d.farm), base));
        uint256 born = vm.getBlockTimestamp() - 5 days;
        s0 = (s0 & ~uint256(type(uint64).max)) | born;
        vm.store(address(d.farm), base, bytes32(s0));
        vm.store(address(d.farm), bytes32(uint256(base) + 2), bytes32(uint256(2800)));
        assertEq(d.farm.level(p), 10);
    }

    function mockRegistry(address market_, uint256 endowment_) internal returns (MockGameRegistry r) {
        r = new MockGameRegistry(
            address(token),
            address(d.params),
            market_,
            launch - 1 hours,
            keccak256(abi.encode(uint256(17), alice)),
            23_000_000,
            endowment_
        );
        address[14] memory a = [
            address(d.pool),
            address(d.rewards),
            address(d.farm),
            address(d.items),
            address(d.packs),
            address(d.starter),
            address(d.fees),
            address(d.grid),
            address(d.season),
            address(d.engine),
            address(d.economy),
            address(d.enhancement),
            address(d.civic),
            address(d.billboards)
        ];
        for (uint256 i; i < 14; ++i) {
            r.setModule(i, a[i]);
        }
    }

    /// @dev v3.8: the frozen game configuration only (no token, Params or launch coordinates).
    function bindingConfigHash() internal view returns (bytes32) {
        return keccak256(
            abi.encode(keccak256(abi.encode(uint256(17), alice)), freePackRoot(), uint256(23_000_000), uint256(0))
        );
    }

    /// @dev Fixture coordinates: the hook registry sits at (7,1) in the local factory.
    function bindHook(V4Market hook_, address router) internal {
        hook_.bindFeeRouter(router, 7, 1);
    }

    function canonicalFees(address hook_) internal returns (FeeRouter f) {
        bytes memory code = bytes.concat(
            type(GameRegistry).creationCode,
            abi.encode(
                address(token),
                address(d.params),
                hook_,
                keccak256(abi.encode(uint256(17), alice)),
                freePackRoot(),
                uint256(23_000_000),
                uint256(0)
            )
        );
        GameRegistry r = GameRegistry(bindingFactory.deploy(7, 1, code));
        string[14] memory names = [
            "RewardPool",
            "FarmRewards",
            "FarmCore",
            "FarmItems",
            "PackSale",
            "StarterClaim",
            "FeeRouter",
            "GridOperator",
            "Season",
            "FarmEngine",
            "Economy",
            "Enhancement",
            "Civic",
            "Billboards"
        ];
        for (uint256 i; i < 14; ++i) {
            bytes memory creation = vm.getCode(string.concat(names[i], ".sol:", names[i]));
            uint64 launchNumber = i < 6 ? 8 : 9;
            uint256 idx = i < 6 ? i : i - 6;
            bindingFactory.deploy(launchNumber, idx, bytes.concat(creation, abi.encode(address(r))));
            r.register(i, launchNumber, idx, creation);
        }
        d.pool = RewardPool(r.module(0));
        // Hook tests use these identities for authorized fee streams, without purchasing farm items.
        d.packs = PackSale(r.module(4));
        d.grid = GridOperator(r.module(7));
        f = FeeRouter(payable(r.module(6)));
    }

    function newFees(address market_) internal returns (FeeRouter f) {
        MockGameRegistry r = mockRegistry(market_, 0);
        f = new FeeRouter(address(r));
        r.setModule(6, address(f));
    }

    function fund(uint256 amount) internal {
        token.approve(address(d.pool), amount);
        d.pool.donate(amount);
    }

    function mintItem(address p, uint8 k, uint8 r) internal returns (uint256 id) {
        vm.prank(address(d.packs));
        id = d.items.mint(p, k, r, false);
    }

    function place(address p, uint8 k, uint8 r, uint256 slot) internal returns (uint256 id) {
        id = mintItem(p, k, r);
        vm.prank(p);
        d.farm.place(id, 0, slot);
    }

    function payPack(address p) internal returns (uint256 id) {
        uint256 price = d.packs.price();
        if (token.balanceOf(p) < price) token.transfer(p, price - token.balanceOf(p));
        vm.prank(p);
        token.approve(address(d.packs), type(uint256).max);
        vm.prank(p);
        id = d.packs.openPack(1);
    }

    function entropy() internal {
        uint256 n = vm.getBlockNumber();
        vm.roll(n + 3);
        vm.setBlockhash(n + 1, keccak256(abi.encode(n, "shift")));
        vm.setBlockhash(n + 2, keccak256(abi.encode(n, "pack")));
    }

    function finish() internal {
        for (uint256 i; i < d.farm.count(); ++i) {
            address p = d.farm.playerAt(i);
            while (d.rewards.lastSettled(p) < d.rewards.settledEpoch()) d.rewards.settle(p, 8);
        }
    }

    function step() internal {
        entropy();
        vm.warp(d.rewards.epochEnd());
        d.rewards.advanceEpoch();
        finish();
    }

    function calmNext() internal {
        uint256 e = d.rewards.epoch() + 1;
        vm.prank(swarm);
        d.grid.submitPlan(e, GridOperator.Kind.Calm, 10000, keccak256("test calm"), "Calm test epoch");
    }

    function resolvePack(uint256 id) internal {
        entropy();
        d.packs.resolve(id, 1);
    }
}

/// @dev Established-farm snapshot fixtures used by legacy event/accounting unit tests.
/// Suppress only the first-entry admission shortcut; all normal epoch processing is real.
/// V34 and invariant tests inherit BaseTest and exercise live admission without this mock.
abstract contract DeferredEntryTest is BaseTest {
    function setUp() public virtual override {
        super.setUp();
        vm.mockCall(address(d.rewards), abi.encodeWithSignature("beginMining(address,uint256)"), abi.encode(false));
    }
}
