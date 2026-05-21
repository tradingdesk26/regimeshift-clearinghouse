// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {InterAgentRepo} from "../src/InterAgentRepo.sol";

/// @notice Deploy InterAgentRepo to Base mainnet.
///
/// Usage:
///   ORACLE_SIGNER=0x...  forge script script/Deploy.s.sol:Deploy \
///     --rpc-url $BASE_RPC --broadcast --private-key $DEPLOYER_PK \
///     --verify --etherscan-api-key $BASESCAN_KEY
contract Deploy is Script {
    function run() external returns (InterAgentRepo deployed) {
        address oracleSigner = vm.envAddress("ORACLE_SIGNER");
        require(oracleSigner != address(0), "ORACLE_SIGNER not set");

        vm.startBroadcast();
        deployed = new InterAgentRepo(oracleSigner);
        vm.stopBroadcast();

        console.log("InterAgentRepo deployed at:", address(deployed));
        console.log("  oracle signer:", oracleSigner);
        console.log("  owner:        ", deployed.owner());
        console.log("  domain:       ", "InterAgentRepo v1");
        console.log("  principal cap:", deployed.PRINCIPAL_CAP());
    }
}
