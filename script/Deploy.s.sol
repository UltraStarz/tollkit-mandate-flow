// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {ConsentMandateRegistry} from "../src/ConsentMandateRegistry.sol";

/**
 * @title Deploy
 * @notice Deploys ConsentMandateRegistry to whichever network is
 *         configured by the active --rpc-url flag.
 *
 *         Required env vars:
 *         - DEPLOYER_PRIVATE_KEY  — funds the deploy
 *         - SELLER_ADDRESS        — tollkit-sms seller wallet (receives x402 USDC)
 *
 *         Usage (Arbitrum Sepolia):
 *
 *         forge script script/Deploy.s.sol \
 *           --rpc-url arbitrum_sepolia \
 *           --broadcast \
 *           --verify
 */
contract Deploy is Script {
    function run() external returns (ConsentMandateRegistry registry) {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address seller = vm.envAddress("SELLER_ADDRESS");

        vm.startBroadcast(deployerKey);
        registry = new ConsentMandateRegistry(seller);
        vm.stopBroadcast();

        console2.log("ConsentMandateRegistry deployed at:", address(registry));
        console2.log("Seller authorized:", seller);
    }
}
