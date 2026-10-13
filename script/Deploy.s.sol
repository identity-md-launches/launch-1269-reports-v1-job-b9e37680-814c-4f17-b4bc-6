// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {Script} from "forge-std/Script.sol";
import {SwarmDesk} from "../src/SwarmDesk.sol";
import {SwarmArgs} from "./SwarmArgs.sol";
import {Params} from "../src/Params.sol";
import {GameRegistry} from "../src/GameRegistry.sol";
import {RewardPool} from "../src/RewardPool.sol";
import {FarmRewards} from "../src/FarmRewards.sol";
import {FarmEngine} from "../src/FarmEngine.sol";
import {FarmCore} from "../src/FarmCore.sol";
import {FarmItems} from "../src/FarmItems.sol";
import {PackSale} from "../src/PackSale.sol";
import {StarterClaim} from "../src/StarterClaim.sol";
import {FeeRouter} from "../src/FeeRouter.sol";
import {GridOperator} from "../src/GridOperator.sol";
import {Economy} from "../src/Economy.sol";
import {Enhancement} from "../src/Enhancement.sol";
import {Billboards} from "../src/Billboards.sol";
import {Civic} from "../src/Civic.sol";
import {Season} from "../src/Season.sol";
import {IMD} from "../src/lib/IMD.sol";
import {MockAttester} from "../test/mocks/MockAttester.sol";
import "../src/lib/Errors.sol";

/// @dev Local fixture for the platform's predictContract/CREATE2 behavior, never a launch target.
contract LocalApplicationFactory {
    mapping(uint64 => mapping(uint256 => bool)) public used;
    mapping(uint64 => bool) public isRecorded;

    function predictContract(uint64 launchNumber, uint256 index, bytes calldata initCode)
        external
        view
        returns (address)
    {
        return address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(
                            bytes1(0xff), address(this), keccak256(abi.encode(launchNumber, index)), keccak256(initCode)
                        )
                    )
                )
            )
        );
    }

    function deploy(uint64 launchNumber, uint256 index, bytes memory initCode) external returns (address result) {
        if (index >= 8 || launchNumber == 0) revert InvalidValue();
        if (used[launchNumber][index]) revert AlreadyDone();
        used[launchNumber][index] = true;
        isRecorded[launchNumber] = true;
        bytes32 salt = keccak256(abi.encode(launchNumber, index));
        assembly ("memory-safe") { result := create2(0, add(initCode, 32), mload(initCode), salt) }
        if (result == address(0)) revert InvalidValue();
    }
}

/// @dev Stands in for the ProjectFactory's launch registry: a launch is recorded once the local factory deployed it.
contract LocalLaunchRecords {
    function isRecorded(uint64 launchNumber) external view returns (bool) {
        return LocalApplicationFactory(IMD.PROJECT_FACTORY).isRecorded(launchNumber);
    }
}

/// @notice Offline rehearsal of a Desk bootstrap and two application launches. Explicit values only; no broadcasts or environment reads.
contract Deploy is Script {
    struct Config {
        address token;
        bytes oracle;
        address market;
        uint256 launchTime;
        bytes32 starterRoot;
        bytes32 freeRoot;
        uint256 snapshotBlock;
        uint256 endowmentBps;
        uint256 heartbeatBps;
        uint256 heartbeatCap;
    }

    struct Deployment {
        Params params;
        RewardPool pool;
        FarmRewards rewards;
        FarmCore farm;
        FarmItems items;
        PackSale packs;
        StarterClaim starter;
        FeeRouter fees;
        GridOperator grid;
        Season season;
        FarmEngine engine;
        GameRegistry registry;
        Economy economy;
        Enhancement enhancement;
        Civic civic;
        Billboards billboards;
    }

    /// @dev v3.14: the factory is shared (one constant address), so each later deployment in the same VM takes
    /// its own launch numbers (offset 1000 per generation); the first keeps the historical 1/3/8/9 numbers.
    uint64 public generation;
    uint64 private offset;

    function deploy(Config memory c) public returns (Deployment memory d) {
        offset = 1000 * generation++;
        if (
            c.token == address(0) || c.oracle.length == 0 || c.market == address(0) || c.launchTime == 0
                || c.freeRoot == bytes32(0) || c.starterRoot == bytes32(0) || c.snapshotBlock == 0
        ) revert InvalidValue();
        if (
            c.endowmentBps != 0 && c.endowmentBps != 1000 && c.endowmentBps != 1500 && c.endowmentBps != 2000
                && c.endowmentBps != 2500
        ) revert InvalidValue();
        LocalApplicationFactory factory = localFactory();
        SwarmDesk desk = _desk(factory, c);
        d.params = Params(
            factory.deploy(
                1 + offset,
                0,
                abi.encodePacked(type(Params).creationCode, abi.encode(address(desk), c.heartbeatBps, c.heartbeatCap))
            )
        );
        d.registry = _registry(factory, c, address(d.params));
        // A mock market learns the Desk and configuration it must answer for at bind time (v3.14 probe).
        (bool configured,) = c.market
            .call(
                abi.encodeWithSignature(
                    "configureHook(address,bytes32)",
                    address(desk),
                    keccak256(abi.encode(c.starterRoot, c.freeRoot, c.snapshotBlock, _endowment(c)))
                )
            );
        configured;
        desk.bind(
            address(d.registry),
            type(GameRegistry).creationCode,
            type(Params).creationCode,
            1 + offset,
            1,
            1 + offset,
            0
        );
        address[14] memory modules = _modules(factory, address(d.registry));
        d.pool = RewardPool(modules[0]);
        d.rewards = FarmRewards(modules[1]);
        d.farm = FarmCore(modules[2]);
        d.items = FarmItems(modules[3]);
        d.packs = PackSale(modules[4]);
        d.starter = StarterClaim(modules[5]);
        d.fees = FeeRouter(payable(modules[6]));
        d.grid = GridOperator(modules[7]);
        d.season = Season(modules[8]);
        d.engine = FarmEngine(modules[9]);
        d.economy = Economy(modules[10]);
        d.enhancement = Enhancement(modules[11]);
        d.civic = Civic(modules[12]);
        d.billboards = Billboards(modules[13]);
    }

    /// @dev v3.14: the contracts fix the IMD ProjectFactory and its launch registry in bytecode, so the local
    /// fixture lives at those addresses (etched once per test VM; the records mock forwards isRecorded).
    function localFactory() public returns (LocalApplicationFactory factory) {
        factory = LocalApplicationFactory(IMD.PROJECT_FACTORY);
        if (address(factory).code.length == 0) {
            vm.etch(IMD.PROJECT_FACTORY, address(new LocalApplicationFactory()).code);
            vm.etch(IMD.PROJECT_RECORDS, address(new LocalLaunchRecords()).code);
            // The attester is fixed in bytecode; local tests sign with key 0x123456 through an ERC-1271 stand-in.
            vm.etch(IMD.ATTESTER, address(new MockAttester(vm.addr(0x123456))).code);
        }
    }

    function _endowment(Config memory c) private pure returns (uint256) {
        return 1_000_000_000 ether * c.endowmentBps / 10000;
    }

    /// @dev v3.8: no launch coordinates at construction; the token is excluded (Desk precedes the token launch).
    function _desk(LocalApplicationFactory factory, Config memory c) private returns (SwarmDesk) {
        SwarmDesk.BindingConfig memory binding = SwarmDesk.BindingConfig(
            address(factory),
            0,
            0,
            0,
            0,
            keccak256(abi.encode(c.starterRoot, c.freeRoot, c.snapshotBlock, _endowment(c))),
            c.heartbeatBps,
            c.heartbeatCap
        );
        bytes memory args = SwarmArgs.encode(abi.decode(c.oracle, (SwarmDesk.OracleConfig)), binding);
        return SwarmDesk(factory.deploy(3 + offset, 0, bytes.concat(vm.getCode("SwarmDesk.sol:SwarmDesk"), args)));
    }

    function _registry(LocalApplicationFactory factory, Config memory c, address params)
        private
        returns (GameRegistry)
    {
        bytes memory args = abi.encode(
            c.token, params, c.market, c.starterRoot, c.freeRoot, c.snapshotBlock, _endowment(c)
        );
        return GameRegistry(factory.deploy(1 + offset, 1, abi.encodePacked(type(GameRegistry).creationCode, args)));
    }

    function _modules(LocalApplicationFactory factory, address registry) private returns (address[14] memory modules) {
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
            bytes memory code = vm.getCode(string.concat(names[i], ".sol:", names[i]));
            uint64 launchNumber = (i < 6 ? 1 : 2) + offset;
            uint256 index = i < 6 ? i + 2 : i - 6;
            modules[i] = factory.deploy(launchNumber, index, abi.encodePacked(code, abi.encode(registry)));
            assert(GameRegistry(registry).register(i, launchNumber, index, code) == modules[i]);
        }
    }
}
