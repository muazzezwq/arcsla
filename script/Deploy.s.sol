// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Script, console2 } from "forge-std/Script.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { ServiceRegistry } from "../src/ServiceRegistry.sol";
import { PayPerCall } from "../src/PayPerCall.sol";
import { IServiceRegistry } from "../src/interfaces/IServiceRegistry.sol";

/// @title Deploy
/// @notice Deploys ServiceRegistry + PayPerCall and wires them together.
///
/// Usage (Arc Testnet, with shell keystore):
///
///   forge script script/Deploy.s.sol:Deploy \
///     --account main \
///     --sender 0xYOUR_DEPLOYER \
///     --rpc-url arc_testnet \
///     --broadcast
///
/// Env vars required:
///   USDC_ADDRESS — USDC contract (Arc Testnet: 0x3600000000000000000000000000000000000000)
///   MIN_STAKE    — (optional) minimum stake in USDC base units; defaults to 10 USDC
contract Deploy is Script {
    function run() external returns (ServiceRegistry registry, PayPerCall payPerCall) {
        address usdcAddress = vm.envAddress("USDC_ADDRESS");
        uint256 minStake = vm.envOr("MIN_STAKE", uint256(10e6)); // default: 10 USDC

        console2.log("Deployer       :", msg.sender);
        console2.log("USDC           :", usdcAddress);
        console2.log("Min stake      :", minStake, "(6 decimals)");

        vm.startBroadcast();

        // 1. Deploy ServiceRegistry
        registry = new ServiceRegistry(IERC20(usdcAddress), minStake);
        console2.log("ServiceRegistry:", address(registry));

        // 2. Deploy PayPerCall, pointing at the registry
        payPerCall = new PayPerCall(IERC20(usdcAddress), IServiceRegistry(address(registry)));
        console2.log("PayPerCall     :", address(payPerCall));

        // 3. Wire them — admin (deployer) authorizes PayPerCall to call slash/mark hooks
        registry.setPayPerCall(address(payPerCall));
        console2.log("Wired PayPerCall -> ServiceRegistry");

        vm.stopBroadcast();
    }
}
