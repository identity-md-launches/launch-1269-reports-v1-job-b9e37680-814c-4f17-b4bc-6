// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {BaseTest} from "./Base.t.sol";
import {LocalApplicationFactory} from "../script/Deploy.s.sol";
import {GameRegistry} from "../src/GameRegistry.sol";
import {RewardPool} from "../src/RewardPool.sol";
import {FeeRouter} from "../src/FeeRouter.sol";
import "../src/lib/Errors.sol";

contract RegistryTest is BaseTest {
    function testAllModulePinsMatchExactPinnedCompilerArtifacts() public view {
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
        // v3.9: two toolchain pins per role. This build matches exactly one of them for every role, never a mix.
        uint256 launchMatches;
        uint256 repoMatches;
        for (uint256 i; i < 14; ++i) {
            assertLe(d.registry.module(i).code.length, 24576, "runtime must fit EIP-170");
            bytes32 built = keccak256(vm.getCode(string.concat(names[i], ".sol:", names[i])));
            assertTrue(d.registry.acceptsCreationCode(i, built), "pin must accept this build");
            (bytes32 launchPin, bytes32 repoPin) = d.registry.creationCodeHashes(i);
            assertEq(d.registry.creationCodeHash(i), launchPin);
            assertTrue(launchPin != bytes32(0) && repoPin != bytes32(0) && launchPin != repoPin, "distinct pins");
            if (built == launchPin) launchMatches++;
            if (built == repoPin) repoMatches++;
            assertFalse(d.registry.acceptsCreationCode(i, keccak256(abi.encodePacked(built))));
        }
        assertTrue(launchMatches == 14 || repoMatches == 14, "one toolchain for all fourteen modules");
        assertFalse(d.registry.acceptsCreationCode(14, keccak256(vm.getCode("RewardPool.sol:RewardPool"))));
        assertFalse(d.registry.acceptsCreationCode(0, bytes32(0)));
        assertEq(d.registry.registered(), 14);
        assertEq(address(d.rewards.registry()), address(d.registry));
        assertEq(address(d.pool.registry()), address(d.registry));
        assertEq(d.registry.module(0), address(d.pool));
    }

    function _fresh(LocalApplicationFactory f) private returns (GameRegistry) {
        return new GameRegistry(
            address(token),
            address(d.params),
            address(market),
            keccak256("real test root"),
            freePackRoot(),
            123,
            100_000_000 ether
        );
    }

    function testAuthenticatedEnrollmentRejectsUncreatedWrongCodeAndWrongRegistry() public {
        LocalApplicationFactory f = deployment.localFactory();
        GameRegistry r = _fresh(f);
        bytes memory code = vm.getCode("RewardPool.sol:RewardPool");
        vm.expectRevert(NotConfigured.selector);
        r.module(0);
        vm.expectRevert(NotConfigured.selector);
        r.register(0, 5, 0, code);
        vm.expectRevert(InvalidValue.selector);
        r.register(0, 5, 0, abi.encodePacked(code, bytes1(0x00)));
        vm.expectRevert(InvalidValue.selector);
        r.register(14, 5, 0, code);
        vm.expectRevert(InvalidValue.selector);
        r.register(0, 5, 8, code);
        // Same canonical creation code, but a different graph, cannot enroll into this graph.
        f.deploy(5, 0, abi.encodePacked(code, abi.encode(address(d.registry))));
        vm.expectRevert(NotConfigured.selector);
        r.register(0, 5, 0, code);
        address expected = f.deploy(5, 1, abi.encodePacked(code, abi.encode(address(r))));
        vm.prank(bob);
        assertEq(r.register(0, 5, 1, code), expected);
        assertEq(r.module(0), expected);
        vm.expectRevert(AlreadyDone.selector);
        r.register(0, 5, 1, code);
    }

    function testCounterfeitRuntimeAtAnotherFactoryCannotEnroll() public {
        LocalApplicationFactory canonical = deployment.localFactory();
        LocalApplicationFactory rogue = new LocalApplicationFactory(); // a genuinely different factory
        GameRegistry r = _fresh(canonical);
        bytes memory code = vm.getCode("RewardPool.sol:RewardPool");
        rogue.deploy(5, 0, abi.encodePacked(code, abi.encode(address(r))));
        vm.expectRevert(NotConfigured.selector);
        r.register(0, 5, 0, code);
    }

    function testConstructorAcceptsEmptyGraphWithoutExternalCalls() public {
        RewardPool pool = new RewardPool(makeAddr("future registry with no code"));
        assertGt(address(pool).code.length, 0);
        vm.expectRevert();
        pool.available();
    }

    function testCounterfeitRuntimeWithPoisonedCreditCannotEnroll() public {
        LocalApplicationFactory canonical = deployment.localFactory();
        GameRegistry r = _fresh(canonical);
        bytes memory code = vm.getCode("FeeRouter.sol:FeeRouter");
        address genuine = canonical.deploy(5, 0, abi.encodePacked(code, abi.encode(address(r))));
        bytes memory runtime = genuine.code;
        assertLt(runtime.length, 65536);

        address attacker = makeAddr("storage poisoner");
        // Constructor-only registry slot0, guard1, token queues2/3, pot4, sell5/6, ETH7/8, buy9, credits10.
        bytes32 creditSlot = keccak256(abi.encode(attacker, uint256(10)));
        // Seed storage, copy the exact legitimate runtime starting at offset80, then return it.
        bytes memory poisonedInit = abi.encodePacked(
            hex"7f",
            bytes32(uint256(1 ether)),
            hex"7f",
            creditSlot,
            hex"55",
            hex"61",
            uint16(runtime.length),
            hex"6100505f3961",
            uint16(runtime.length),
            hex"5ff3",
            runtime
        );
        address fake = canonical.deploy(5, 1, poisonedInit);
        assertEq(fake.codehash, genuine.codehash, "runtime hashes are indistinguishable");
        assertEq(address(FeeRouter(payable(fake)).registry()), address(0), "runtime copy lacks constructor binding");
        assertEq(FeeRouter(payable(fake)).credit(attacker), 1 ether);

        vm.expectRevert(InvalidValue.selector);
        r.register(6, 5, 1, poisonedInit);
        vm.expectRevert(NotConfigured.selector);
        r.register(6, 5, 1, code);
        assertEq(r.registeredModule(6), address(0));
    }
}
