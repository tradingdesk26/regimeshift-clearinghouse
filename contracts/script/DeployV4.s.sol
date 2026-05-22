// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {InterAgentRepoV4} from "../src/InterAgentRepoV4.sol";

/// @notice Deploy InterAgentRepoV4 to Base mainnet (audit round-2 patched).
contract DeployV4 is Script {
    address constant ETH_USD_FEED_BASE = 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70;
    address constant WETH_BASE          = 0x4200000000000000000000000000000000000006;
    address constant USDC_BASE          = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    function run() external returns (InterAgentRepoV4 deployed) {
        address oracleSigner = vm.envAddress("ORACLE_SIGNER");
        address insurancePool = vm.envAddress("INSURANCE_POOL");
        require(oracleSigner != address(0), "ORACLE_SIGNER not set");
        require(insurancePool != address(0), "INSURANCE_POOL not set");

        vm.startBroadcast();
        deployed = new InterAgentRepoV4(
            oracleSigner, ETH_USD_FEED_BASE, WETH_BASE, USDC_BASE, insurancePool
        );
        vm.stopBroadcast();

        console.log("InterAgentRepoV4 deployed at:", address(deployed));
        console.log("  R2 fix: whenNotPaused removed from repay()");
    }
}
