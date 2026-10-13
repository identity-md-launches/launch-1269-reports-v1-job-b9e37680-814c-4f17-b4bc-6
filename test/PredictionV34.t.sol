// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {BaseTest} from "./Base.t.sol";
import {PredictGame} from "../script/PredictGame.s.sol";
import {GameRegistry} from "../src/GameRegistry.sol";
import {RewardPool} from "../src/RewardPool.sol";

contract PredictionV34Test is BaseTest {
    function testFullGraphPredictsPoolBeforeRegistryDeployment() public {
        PredictGame helper = new PredictGame();
        PredictGame.Config memory c = PredictGame.Config(
            address(bindingFactory),
            address(token),
            address(d.params),
            address(market),
            keccak256("snapshot"),
            freePackRoot(),
            123,
            200_000_000 ether,
            20,
            1,
            20,
            2
        );
        (address registry, address remainderTo) = helper.predict(c);
        assertEq(registry.code.length, 0);
        assertEq(remainderTo.code.length, 0);
        token.transfer(remainderTo, c.endowment);
        address deployed = bindingFactory.deploy(
            20,
            1,
            bytes.concat(
                type(GameRegistry).creationCode,
                abi.encode(c.token, c.params, c.hook, c.starterRoot, c.freeRoot, c.snapshotBlock, c.endowment)
            )
        );
        assertEq(deployed, registry);
        address pool = bindingFactory.deploy(20, 2, bytes.concat(type(RewardPool).creationCode, abi.encode(registry)));
        assertEq(pool, remainderTo);
        vm.prank(bob);
        RewardPool(pool).fundEndowment();
        assertEq(RewardPool(pool).lockedEndowment(), c.endowment);
        assertTrue(RewardPool(pool).endowed());
        assertEq(RewardPool(pool).available(), 0);
    }
}
