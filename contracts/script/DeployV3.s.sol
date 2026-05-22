// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {InterAgentRepoV3} from "../src/InterAgentRepoV3.sol";

/// @notice Deploy InterAgentRepoV3 to Base mainnet (audit round-1 patched).
contract DeployV3 is Script {
    address constant ETH_USD_FEED_BASE = 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70;
    address constant WETH_BASE          = 0x4200000000000000000000000000000000000006;
    address constant USDC_BASE          = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    function run() external returns (InterAgentRepoV3 deployed) {
        address oracleSigner = vm.envAddress("ORACLE_SIGNER");
        address insurancePool = vm.envAddress("INSURANCE_POOL");
        require(oracleSigner != address(0), "ORACLE_SIGNER not set");
        require(insurancePool != address(0), "INSURANCE_POOL not set");

        vm.startBroadcast();
        deployed = new InterAgentRepoV3(
            oracleSigner, ETH_USD_FEED_BASE, WETH_BASE, USDC_BASE, insurancePool
        );
        vm.stopBroadcast();

        console.log("InterAgentRepoV3 deployed at:", address(deployed));
        console.log("  audit fixes:           1+2+3+4 + LOW 8+9");
        console.log("  MIN_LTV_BUFFER_BPS:    ", deployed.MIN_LTV_BUFFER_BPS());
        console.log("  MIN_DURATION_BUFFER:   ", deployed.MIN_DURATION_BUFFER_SECONDS());
        console.log("  MAX_RATE_BPS:          ", deployed.MAX_RATE_BPS());
    }
}
