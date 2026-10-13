// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {V4Market} from "./V4Market.sol";

/// @notice Executable standard-fee reference path: the same 1% hook share to rewards, no progressive
/// surcharge and no launch-tax difference. The real IMD standard hook keeps its own fee recipient; never
/// stack this hook on it. Not a launch contract.
contract StandardMarket is V4Market {
    constructor(
        address manager_,
        address token_,
        uint24 fee_,
        int24 spacing_,
        address launcher_,
        address desk_,
        bytes32 gameConfigHash_
    ) V4Market(manager_, token_, fee_, spacing_, launcher_, desk_, gameConfigHash_) {}

    function _surcharged() internal pure override returns (bool) {
        return false;
    }
}
