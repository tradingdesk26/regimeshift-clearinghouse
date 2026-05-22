// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {InterAgentRepoV2} from "../src/InterAgentRepoV2.sol";

/// @notice Deploy InterAgentRepoV2 to Base mainnet.
///
/// Required env vars:
///   ORACLE_SIGNER      — burner / oracle keypair address
///   INSURANCE_POOL     — address to accumulate liquidation insurance fees
///
/// Hardcoded for Base mainnet:
///   ETH/USD Chainlink:  0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70
///   WETH:               0x4200000000000000000000000000000000000006
///   USDC:               0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913
///
/// Usage:
///   ORACLE_SIGNER=0x... INSURANCE_POOL=0x... forge script script/DeployV2.s.sol:DeployV2 \
///     --rpc-url base --broadcast --private-key $DEPLOYER_PK
contract DeployV2 is Script {
    address constant ETH_USD_FEED_BASE = 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70;
    address constant WETH_BASE          = 0x4200000000000000000000000000000000000006;
    address constant USDC_BASE          = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    function run() external returns (InterAgentRepoV2 deployed) {
        address oracleSigner    = vm.envAddress("ORACLE_SIGNER");
        address insurancePool   = vm.envAddress("INSURANCE_POOL");

        require(oracleSigner != address(0), "ORACLE_SIGNER not set");
        require(insurancePool != address(0), "INSURANCE_POOL not set");

        vm.startBroadcast();
        deployed = new InterAgentRepoV2(
            oracleSigner,
            ETH_USD_FEED_BASE,
            WETH_BASE,
            USDC_BASE,
            insurancePool
        );
        vm.stopBroadcast();

        console.log("InterAgentRepoV2 deployed at:", address(deployed));
        console.log("  oracle signer:        ", oracleSigner);
        console.log("  insurance pool:       ", insurancePool);
        console.log("  ETH/USD Chainlink:    ", ETH_USD_FEED_BASE);
        console.log("  WETH:                 ", WETH_BASE);
        console.log("  USDC:                 ", USDC_BASE);
        console.log("  liquidation LTV bps:  ", deployed.LIQUIDATION_LTV_BPS());
        console.log("  liquidator bounty bps:", deployed.LIQUIDATOR_BOUNTY_BPS());
        console.log("  insurance fee bps:    ", deployed.INSURANCE_FEE_BPS());
        console.log("  grace period seconds: ", deployed.GRACE_PERIOD_SECONDS());
    }
}
