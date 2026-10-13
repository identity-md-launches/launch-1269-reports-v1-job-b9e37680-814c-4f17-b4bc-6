// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice IMD protocol addresses on Robinhood Chain (4663), fixed in bytecode (v3.14).
/// @dev The IMD manifest gate refuses any constructor argument equal to an IMD protocol address, so none of
/// these may be a constructor word. They are compile-time constants instead; the platform placeholders
/// ($poolManager, $token, $factory, $contract:Name) stay constructor words. Sources: research job b94e6839
/// (ProjectFactory, its launch registry, LaunchFactory), the oracle reference (Intake v2, IntakeDelivery,
/// attester, Robinhood IMD) and LaunchFactory.poolManager() confirmed on the v3.11 fork.
library IMD {
    /// @notice ProjectFactory: CREATE2 deployer of every application launch (predictContract proofs).
    address internal constant PROJECT_FACTORY = 0x9C9D2FCB75c2C132C0AC0C42DF3819A42347265e;
    /// @notice The ProjectFactory's launch registry (isRecorded proofs).
    address internal constant PROJECT_RECORDS = 0xF52bbE066B7Ad2d28C2195D066Ea08DCbcA88406;
    /// @notice Intake version 2 (oracle.request with requestWithFailure).
    address internal constant INTAKE = 0xa43e6F75ee006411F79Ac1C84120606C2330DE82;
    /// @notice IntakeDelivery: results bought on another chain arrive from here.
    address internal constant INTAKE_DELIVERY = 0xCE0E6a670AA75E161d02aca3C7F00B94cA428CCb;
    /// @notice The oracle attester (EIP-712 signer of every attestation).
    address internal constant ATTESTER = 0x5598Aa9146215Bc13eb26f2c692Ad1461Fd32982;
    /// @notice Robinhood IMD, the asset the Intake is paid in.
    address internal constant IMD_TOKEN = 0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127;
    /// @notice LaunchFactory: initializes the launch pool ($factory placeholder in the hook constructor).
    address internal constant LAUNCH_FACTORY = 0xA25B02A1e93903b790E6aaf7dA1b8B8d50294645;
    /// @notice Uniswap v4 PoolManager ($poolManager placeholder in the hook constructor).
    address internal constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
}
