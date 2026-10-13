// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {BaseTest} from "./Base.t.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {StandardAdapter} from "../src/StandardAdapter.sol";
import {MockStandardTwap} from "./StandardAdapter.t.sol";
import {IntegrationStandardMarket} from "./mocks/MockV4Manager.sol";
import {StandardMarket} from "../src/StandardMarket.sol";
import {V4Market} from "../src/V4Market.sol";
import {MockGameRegistry} from "./mocks/MockGameRegistry.sol";
import {FeeRouter} from "../src/FeeRouter.sol";
import {IV4PoolManager, PoolKey, SwapParams} from "../src/interfaces/IV4.sol";

struct StandardLiquidityParams {
    int24 tickLower;
    int24 tickUpper;
    int256 liquidityDelta;
    bytes32 salt;
}

interface StandardRealManager is IV4PoolManager {
    function initialize(PoolKey memory, uint160) external returns (int24);
    function modifyLiquidity(PoolKey memory, StandardLiquidityParams memory, bytes calldata)
        external
        returns (int256, int256);
    function sync(address) external;
}

contract StandardV4IntegrationTest is BaseTest {
    StandardRealManager internal manager;
    V4Market internal hook;
    FeeRouter internal router;
    StandardAdapter internal adapter;
    MockStandardTwap internal oracle;

    function setUp() public override {
        super.setUp();
        vm.deal(address(this), 10000 ether);
        manager = StandardRealManager(address(new PoolManager(address(this))));
        oracle = new MockStandardTwap();
        bytes memory code = abi.encodePacked(
            type(IntegrationStandardMarket).creationCode,
            abi.encode(
                address(manager),
                address(token),
                uint24(12500),
                int24(60),
                address(this),
                address(desk),
                bindingConfigHash()
            )
        );
        bytes32 hash = keccak256(code);
        bytes32 salt;
        for (uint256 i;; ++i) {
            salt = bytes32(i);
            address target = vm.computeCreate2Address(salt, hash, address(this));
            if (uint160(target) & 0x3fff == 0x10cc) break;
        }
        hook = new IntegrationStandardMarket{salt: salt}(
            address(manager), address(token), 12500, 60, address(this), address(desk), bindingConfigHash()
        );
        router = canonicalFees(address(hook));
        adapter =
            new StandardAdapter(address(manager), address(token), address(oracle), address(this), address(hook), 60);
        vm.prank(team);
        bindHook(hook, address(router));
        manager.initialize(hook.key(), uint160(1 << 96));
        manager.unlock(abi.encode(uint8(0), uint256(1000 ether)));
        vm.warp(vm.getBlockTimestamp() + 60 minutes);
        oracle.configure(adapter.poolId(), block.timestamp, 30 minutes);
    }
    receive() external payable {}

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager));
        (uint8 action, uint256 amount) = abi.decode(data, (uint8, uint256));
        int256 delta;
        if (action == 0) {
            (delta,) = manager.modifyLiquidity(
                hook.key(), StandardLiquidityParams(-887220, 887220, int256(amount), bytes32(0)), ""
            );
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

    function testStandardAdapterRealPoolPaysExistingHookExactlyOnce() public {
        uint256 poolBefore = token.balanceOf(address(d.pool));
        uint256 teamBefore = router.credit(team);
        adapter.buy{value: 0.5 ether}(0.485 ether, address(d.pool));
        assertGe(token.balanceOf(address(d.pool)) - poolBefore, 0.485 ether);
        if (hook.heldBase() != 0) hook.flushFees();
        assertEq(router.credit(team) - teamBefore, 0);
        assertEq(router.rewardETH(), 0.005 ether);
        assertEq(router.heartbeatBalance(), 0);
        assertEq(address(adapter).balance, 0);
        assertEq(adapter.key().hooks, address(hook));
    }
}
