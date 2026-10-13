// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {V4Market, IHookRouter, IHookParams} from "../src/V4Market.sol";
import {FeeRouter} from "../src/FeeRouter.sol";
import {RewardPool} from "../src/RewardPool.sol";
import {Params} from "../src/Params.sol";
import {SwarmDesk} from "../src/SwarmDesk.sol";
import {GameRegistry} from "../src/GameRegistry.sol";
import {EndowmentEscrow} from "../src/EndowmentEscrow.sol";
import {IMD} from "../src/lib/IMD.sol";
import {IV4PoolManager, PoolKey, SwapParams} from "../src/interfaces/IV4.sol";
import {LocalApplicationFactory, LocalLaunchRecords} from "../script/Deploy.s.sol";
import "../src/lib/Errors.sol";

struct LiquidityParams {
    int24 tickLower;
    int24 tickUpper;
    int256 liquidityDelta;
    bytes32 salt;
}

interface RealManager is IV4PoolManager {
    function initialize(PoolKey memory, uint160) external returns (int24);
    function modifyLiquidity(PoolKey memory, LiquidityParams memory, bytes calldata) external returns (int256, int256);
    function sync(address) external;
}

contract QuoteToken is ERC20 {
    constructor() ERC20("T", "T") {
        _mint(msg.sender, 1e27);
    }
}

/// Minimal registry graph: token, params, market (the hook), FeeRouter as role 6, RewardPool as role 0.
contract QuoteRegistry {
    address public token;
    address public params;
    address public market;
    mapping(uint256 => address) public registeredModule;

    constructor(address t, address p, address m) {
        token = t;
        params = p;
        market = m;
    }

    function set(uint256 role, address a) external {
        registeredModule[role] = a;
    }

    function module(uint256 role) external view returns (address a) {
        a = registeredModule[role];
        require(a != address(0), "unset");
    }

    function launchTime() external view returns (uint256) {
        return block.timestamp - 1 days;
    }

    function freeRoot() external pure returns (bytes32) {
        return bytes32(uint256(1));
    }

    function starterRoot() external pure returns (bytes32) {
        return bytes32(uint256(1));
    }

    function snapshotBlock() external pure returns (uint256) {
        return 1;
    }

    function endowment() external pure returns (uint256) {
        return 0;
    }
}

/// The real hook with real flag validation; only the bind proof is replaced by a direct setter.
contract QuoteHook is V4Market {
    constructor(address manager_, address token_, address launcher_, address desk_, bytes32 h)
        V4Market(manager_, token_, 12500, 60, launcher_, desk_, h)
    {}

    function bindForTest(address router, address p) external {
        fees = IHookRouter(router);
        params = IHookParams(p);
    }
}

/// @notice v3.14 audit a8730286 H: quote()/quoteSell() net the pool's 1.25% LP fee, so the router's 1.5% band
/// clears the smallest reward buy and the sell batch on a calm pool of the launch's depth (10 ETH full range).
contract QuoteLpFeeV314Test is Test {
    RealManager internal manager;
    QuoteHook internal hook;
    FeeRouter internal router;
    QuoteToken internal token;
    RewardPool internal pool;

    function setUp() public {
        vm.warp(1_800_000_000);
        vm.deal(address(this), 10000 ether);
        manager = RealManager(address(new PoolManager(address(this))));
        token = new QuoteToken();
        Params params = new Params(address(this), 200, 1 ether);
        bytes32 h = keccak256("config");
        bytes memory code = abi.encodePacked(
            type(QuoteHook).creationCode, abi.encode(address(manager), address(token), address(this), address(0xd), h)
        );
        bytes32 codeHash = keccak256(code);
        bytes32 salt;
        for (uint256 i;; ++i) {
            salt = bytes32(i);
            address target = vm.computeCreate2Address(salt, codeHash, address(this));
            if (uint160(target) & 0x3fff == 0x10cc) break;
        }
        hook = new QuoteHook{salt: salt}(address(manager), address(token), address(this), address(0xd), h);
        QuoteRegistry registry = new QuoteRegistry(address(token), address(params), address(hook));
        router = new FeeRouter(address(registry));
        pool = new RewardPool(address(registry));
        registry.set(0, address(pool));
        registry.set(2, address(this));
        registry.set(4, address(this));
        registry.set(6, address(router));
        hook.bindForTest(address(router), address(params));
        manager.initialize(hook.key(), uint160(1 << 96));
        // Full-range position with virtual reserves of 10 ETH and 10 tokens (price 1:1), the launch's scale.
        manager.unlock(abi.encode(uint8(0), uint256(10 ether)));
        vm.warp(vm.getBlockTimestamp() + 60 minutes);
    }

    receive() external payable {}

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager));
        (uint8 action, uint256 amount) = abi.decode(data, (uint8, uint256));
        int256 delta;
        if (action == 0) {
            (delta,) =
                manager.modifyLiquidity(hook.key(), LiquidityParams(-887220, 887220, int256(amount), bytes32(0)), "");
        } else {
            delta = manager.swap(
                hook.key(),
                SwapParams(
                    action == 1,
                    -int256(amount),
                    action == 1 ? 4295128740 : 1461446703485210103287273052203988822378723970341
                ),
                ""
            );
        }
        int128 a = int128(delta >> 128);
        int128 b = int128(delta);
        if (a < 0) manager.settle{value: uint256(-int256(a))}();
        else if (a > 0) manager.take(address(0), address(this), uint256(uint128(a)));
        if (b < 0) {
            manager.sync(address(token));
            token.transfer(address(manager), uint256(-int256(b)));
            manager.settle();
        } else if (b > 0) {
            manager.take(address(token), address(this), uint256(uint128(b)));
        }
        return abi.encode(delta);
    }

    /// The smallest reward buy the router accepts (0.05 ETH) at the widest slippage it allows (150 bps).
    function testMinimumRewardBuyClearsAtFlatPriceOnLaunchDepth() public {
        router.depositBaseFee{value: 0.1 ether}();
        assertEq(hook.twap(), hook.spot(), "calm pool: TWAP equals spot");
        uint256 q = hook.quote(0.05 ether);
        // The quote nets the hook's 1% and the pool's 1.25%: 0.05 x 0.99 x 0.9875 at 1:1.
        assertEq(q, 0.05 ether * 99 / 100 * 987_500 / 1_000_000);
        uint256 minOut = q * 9850 / 10000;
        uint256 before_ = token.balanceOf(address(pool));
        uint256 received = router.executeBuys(0.05 ether, minOut);
        assertGe(received, minOut);
        assertEq(token.balanceOf(address(pool)) - before_, received);
        assertEq(router.rewardETH(), 0.05 ether);
    }

    /// A buy quoted without the pool fee (the v3.13 quote) still fails the band: the fix is what makes it clear.
    function testBuyAtOldQuoteStillRevertsOnLaunchDepth() public {
        router.depositBaseFee{value: 0.1 ether}();
        uint256 oldQuote = (0.05 ether - 0.05 ether * 100 / 10000) * hook.twap() / 1 ether;
        vm.expectRevert(InsufficientBalance.selector);
        router.executeBuys(0.05 ether, oldQuote * 9850 / 10000);
        assertEq(router.rewardETH(), 0.1 ether);
    }

    /// The sell side: the keeper's batch at quoteSell x 0.985 clears and the team credit grows.
    function testSellBatchClearsAtFlatPriceOnLaunchDepth() public {
        token.transfer(address(router), 1_000_000 ether);
        router.routeTokens(1_000_000 ether);
        (uint256 amount, uint256 minimum) = router.sellBatchQuote();
        assertEq(amount, hook.maxSellBatch());
        assertEq(hook.quoteSell(1 ether), 1 ether * 987_500 / 1_000_000 * 99 / 100);
        uint256 received = router.executeSells(amount, minimum);
        assertGe(received, minimum);
        assertGt(router.credit(router.team()), 0);
    }
}

/// @notice v3.14 audit a8730286 M: SwarmDesk.bind probes registry.market() as a launch hook of this Desk.
contract DeskBindProbeV314Test is Test {
    LocalApplicationFactory internal factory;
    QuoteToken internal realToken;
    SwarmDesk internal desk;
    Params internal params;
    bytes32 internal constant STARTER_ROOT = keccak256("starter root");
    bytes32 internal constant FREE_ROOT = keccak256("free root");
    uint256 internal constant SNAPSHOT = 23_000_000;
    uint256 internal constant ENDOWMENT = 200_000_000 ether;
    bytes32 internal configHash;
    address internal attacker = makeAddr("attacker");
    QuoteHook internal hook;
    QuoteHook internal foreignHook;

    function setUp() public {
        vm.warp(1_800_000_000);
        vm.etch(IMD.PROJECT_FACTORY, address(new LocalApplicationFactory()).code);
        vm.etch(IMD.PROJECT_RECORDS, address(new LocalLaunchRecords()).code);
        factory = LocalApplicationFactory(IMD.PROJECT_FACTORY);
        realToken = new QuoteToken();
        configHash = keccak256(abi.encode(STARTER_ROOT, FREE_ROOT, SNAPSHOT, ENDOWMENT));
        uint256 policyWord = uint256(1) | (uint256(100) << 32) | (uint256(200) << 80) | (uint256(0.5 ether) << 128)
            | (uint256(200) << 224);
        desk = new SwarmDesk(
            bytes32("oracle.request@oracle-1"),
            policyWord,
            keccak256("event question"),
            keccak256("regulator question"),
            keccak256("event body"),
            keccak256("regulator body"),
            configHash
        );
        params = Params(
            factory.deploy(
                1, 0, bytes.concat(type(Params).creationCode, abi.encode(address(desk), uint256(200), uint256(1 ether)))
            )
        );
        hook = _hook(address(realToken), address(desk), configHash);
    }

    function _hook(address t, address d, bytes32 h) private returns (QuoteHook) {
        address manager = makeAddr("manager");
        bytes32 codeHash =
            keccak256(abi.encodePacked(type(QuoteHook).creationCode, abi.encode(manager, t, address(this), d, h)));
        bytes32 salt;
        for (uint256 i;; ++i) {
            salt = bytes32(i);
            if (uint160(vm.computeCreate2Address(salt, codeHash, address(this))) & 0x3fff == 0x10cc) break;
        }
        return new QuoteHook{salt: salt}(manager, t, address(this), d, h);
    }

    function _twin(address token, address market, uint64 launch) internal returns (GameRegistry) {
        bytes memory args = abi.encode(token, address(params), market, STARTER_ROOT, FREE_ROOT, SNAPSHOT, ENDOWMENT);
        return GameRegistry(factory.deploy(launch, 1, bytes.concat(type(GameRegistry).creationCode, args)));
    }

    function _bind(GameRegistry r, uint64 launch) internal {
        desk.bind(address(r), type(GameRegistry).creationCode, type(Params).creationCode, launch, 1, 1, 0);
    }

    /// An EOA market cannot answer the probe: bind reverts and the Desk stays unbound.
    function testBindRejectsRegistryWithEoaMarket() public {
        GameRegistry twin = _twin(address(realToken), attacker, 1);
        vm.prank(attacker);
        vm.expectRevert();
        _bind(twin, 1);
        assertEq(address(desk.registry()), address(0), "desk must stay unbound");
    }

    /// A hook launched for another Desk, or another configuration, is a foreign market.
    function testBindRejectsRegistryWithForeignMarket() public {
        foreignHook = _hook(address(realToken), makeAddr("other desk"), configHash);
        GameRegistry twin = _twin(address(realToken), address(foreignHook), 1);
        vm.expectRevert(InvalidProof.selector);
        _bind(twin, 1);
        QuoteHook otherConfig = _hook(address(realToken), address(desk), keccak256("other config"));
        GameRegistry twin2 = _twin(address(realToken), address(otherConfig), 2);
        vm.expectRevert(InvalidProof.selector);
        _bind(twin2, 2);
        assertEq(address(desk.registry()), address(0));
    }

    /// A registry naming a token the hook was not launched for is refused, so the escrow can never be frozen.
    function testBindRejectsRegistryWithForeignToken() public {
        QuoteToken foreign = new QuoteToken();
        GameRegistry twin = _twin(address(foreign), address(hook), 1);
        EndowmentEscrow escrow = new EndowmentEscrow(address(desk));
        realToken.transfer(address(escrow), ENDOWMENT);
        vm.prank(attacker);
        vm.expectRevert(InvalidProof.selector);
        _bind(twin, 1);
        assertEq(address(desk.registry()), address(0));
        assertEq(realToken.balanceOf(address(escrow)), ENDOWMENT);
        assertFalse(escrow.forwarded());
    }

    /// The honest registry (the Desk's own hook, the hook's token, the committed configuration) binds.
    function testHonestRegistryBinds() public {
        GameRegistry honest = _twin(address(realToken), address(hook), 1);
        _bind(honest, 1);
        assertEq(address(desk.registry()), address(honest));
        assertEq(desk.bindingConfig().factory, IMD.PROJECT_FACTORY);
        assertEq(desk.oracleConfig().intake, IMD.INTAKE);
        assertEq(desk.oracleConfig().delivery, IMD.INTAKE_DELIVERY);
        assertEq(desk.oracleConfig().signer, IMD.ATTESTER);
        assertEq(desk.oracleConfig().asset, IMD.IMD_TOKEN);
        assertEq(address(honest.factory()), IMD.PROJECT_FACTORY);
        assertEq(address(hook.applicationFactory()), IMD.PROJECT_FACTORY);
    }
}
