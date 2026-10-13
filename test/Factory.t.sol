// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {BaseTest} from "./Base.t.sol";
import {MarketFactory} from "../src/MarketFactory.sol";
import {V4Market} from "../src/V4Market.sol";
import "../src/lib/Errors.sol";

contract FactoryTest is BaseTest {
    function testHookFactoryFlagsImmutableConfigAndIdempotence() public {
        MarketFactory factory = new MarketFactory();
        MarketFactory.Config memory c = MarketFactory.Config(
            makeAddr("test manager"), address(token), 60, address(this), address(desk), bindingConfigHash()
        );
        (bytes32 salt, address predicted) = factory.findSalt(c, 0, 100000);
        assertEq(uint160(predicted) & 0x3fff, 0x10cc);
        assertEq(factory.predict(c, salt), predicted);
        V4Market hook = factory.deploy(c, salt);
        assertEq(address(hook), predicted);
        assertEq(hook.token(), address(token));
        assertEq(address(hook.fees()), address(0));
        assertEq(address(factory.deploy(c, salt)), predicted);
        assertLe(address(factory).code.length, 24576);
    }

    function testFactoryInvalidSearchRange() public {
        MarketFactory factory = new MarketFactory();
        MarketFactory.Config memory c;
        vm.expectRevert(InvalidValue.selector);
        factory.findSalt(c, 0, 0);
    }
}
