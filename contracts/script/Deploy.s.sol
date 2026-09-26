// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {PolicySpender, IERC20, IWorldID, IResolver} from "../src/PolicySpender.sol";
import {dnsEncode} from "./SetupEns.s.sol";

/// forge script script/Deploy.s.sol --rpc-url sepolia --broadcast
/// Env: OPERATOR_PK, WORLD_APP_ID, MERCHANT_RESOLVER, MERCHANT_REGISTRY (e.g. "verified.proviso.eth")
///      optional: USDC, WORLD_ROUTER, WORLD_ACTION, HERO_ATTESTER (backend key that signs World ID for Agents approvals)
/// admin (resetFor) = the operator/deployer.
contract Deploy is Script {
    function run() external returns (PolicySpender ps) {
        uint256 pk = vm.envUint("OPERATOR_PK");
        vm.startBroadcast(pk);
        ps = new PolicySpender(
            IERC20(vm.envOr("USDC", address(0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238))),
            IWorldID(vm.envOr("WORLD_ROUTER", address(0x469449f251692E0779667583026b5A1E99512157))),
            vm.envString("WORLD_APP_ID"),
            vm.envOr("WORLD_ACTION", string("buy")),
            IResolver(vm.envAddress("MERCHANT_RESOLVER")),
            dnsEncode(vm.envString("MERCHANT_REGISTRY")),
            vm.envOr("HERO_ATTESTER", address(0xCD0d0eF44e493EAD7De8C043047C9D324a1776f5)),
            vm.addr(pk)
        );
        vm.stopBroadcast();
        console.log("POLICY_SPENDER", address(ps));
    }
}
