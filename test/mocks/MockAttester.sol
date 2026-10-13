// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";

/// @dev Test-only ERC-1271 stand-in etched at the constant attester address (src/lib/IMD.sol): the Desk's
/// signer is fixed in bytecode, so local tests sign with a test key that this contract vouches for.
/// The expected signer is an immutable, so the deployed code carries it through vm.etch.
contract MockAttester is IERC1271 {
    address public immutable expected;

    constructor(address expected_) {
        expected = expected_;
    }

    function isValidSignature(bytes32 hash, bytes memory signature) external view returns (bytes4) {
        (address recovered, ECDSA.RecoverError err,) = ECDSA.tryRecover(hash, signature);
        return err == ECDSA.RecoverError.NoError && recovered == expected ? this.isValidSignature.selector : bytes4(0);
    }
}
