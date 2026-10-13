// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {Test} from "forge-std/Test.sol";
import {SwarmDesk} from "../src/SwarmDesk.sol";
import {SwarmArgs} from "../script/SwarmArgs.sol";
import {IMD} from "../src/lib/IMD.sol";
import {MockAttester} from "./mocks/MockAttester.sol";
import {OracleAttestation} from "../src/oracle/OracleAttestation.sol";

contract SwarmVectorHarness is SwarmDesk {
    constructor(OracleConfig memory o, BindingConfig memory b)
        SwarmDesk(
            o.action, SwarmArgs.policy(o, b), o.questions[0], o.questions[1], o.bodies[0], o.bodies[1], b.gameConfigHash
        )
    {}

    function verifyVector(OracleAttestation.Attestation calldata a, bytes calldata sig) external view {
        _verifyAttestation(a, sig);
    }
}

contract OracleConformanceV37Test is Test {
    uint256 constant VECTOR_CHAIN = 11155111;
    address constant VECTOR_CONSUMER = 0x0000000000000000000000000000000000002748;
    bytes32 constant VECTOR_DIGEST = 0x95fefa8b7c529852f4e2b6aec888930eb2bf5078e6443a85808e36df19e1325c;
    bytes constant VECTOR_SIGNATURE =
        hex"a26b14918607eb565af126beb54d3c5d19e923c41506def500b3521a4f9aa6d603ab44fd22f15dd2191732961a7131e4641244add8b0f09f20e6ae64381be8481b";
    /// @dev anvil's second account: the vector's attester. A test key, never a real one.
    address constant SIGNER = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
    uint256 constant SIGNER_KEY = 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d;
    uint64 constant ISSUED_AT = 1800000000;
    uint64 constant EXPIRES_AT = 1800003600;

    function vector() internal pure returns (OracleAttestation.Attestation memory a) {
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = bytes32(uint256(1));
        a = OracleAttestation.Attestation({
            requestId: 0x0000000000004000800000000000000100000000000000000000000000000000,
            chainId: 1,
            questionHash: 0x2117f4362ebfa37aa8a8c0fed548604fe09ac46faf8ae7559cd64780f26a46fb,
            answerType: OracleAttestation.ANSWER_BYTES32_LIST,
            answer: abi.encode(ids),
            figure: 12345,
            fromBlock: 100,
            toBlock: 200,
            blockHash: bytes32(uint256(7)),
            panelJobId: 0x0000000000004000800000000000000200000000000000000000000000000000,
            panelSize: 5,
            quorum: 4,
            agreed: 5,
            issuedAt: ISSUED_AT,
            expiresAt: EXPIRES_AT
        });
    }

    SwarmVectorHarness consumer;

    function setUp() public {
        vm.chainId(VECTOR_CHAIN);
        vm.warp(ISSUED_AT);
        // v3.14: the Desk's signer is the constant attester; the vector's test key is vouched for through ERC-1271.
        vm.etch(IMD.ATTESTER, address(new MockAttester(SIGNER)).code);
        SwarmDesk.OracleConfig memory o;
        o.intake = makeAddr("intake");
        o.delivery = makeAddr("delivery");
        o.asset = makeAddr("imd");
        o.signer = SIGNER;
        o.action = bytes32("oracle.request@oracle-1");
        o.maxPrice = 0.5 ether;
        o.questionChain = 1;
        o.fromBlock = 100;
        o.toBlock = 200;
        o.questions = [vector().questionHash, keccak256("regulator")];
        o.bodies = [keccak256("event body"), keccak256("regulator body")];
        SwarmDesk.BindingConfig memory b =
            SwarmDesk.BindingConfig(makeAddr("factory"), 0, 0, 0, 0, keccak256("config"), 200, 1 ether);
        deployCodeTo("OracleConformanceV37.t.sol:SwarmVectorHarness", abi.encode(o, b), VECTOR_CONSUMER);
        consumer = SwarmVectorHarness(VECTOR_CONSUMER);
    }

    function testDigestMatchesUnmodifiedProtocolVector() public view {
        assertEq(consumer.attestationDigest(vector()), VECTOR_DIGEST);
    }

    function testAcceptsOriginalProtocolSignature() public view {
        consumer.verifyVector(vector(), VECTOR_SIGNATURE);
    }

    function testFreshVectorSignerSignature() public view {
        OracleAttestation.Attestation memory a = vector();
        a.requestId = keccak256("fresh");
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_KEY, consumer.attestationDigest(a));
        consumer.verifyVector(a, abi.encodePacked(r, s, v));
    }

    function testSelectorsExactlyMatchLiveProtocol() public view {
        assertEq(consumer.onOracleResult.selector, bytes4(0x510379c7));
        assertEq(consumer.onOracleFailure.selector, bytes4(0xa7980e31));
    }
}
