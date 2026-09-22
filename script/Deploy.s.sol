// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {SachetMarket} from "../src/SachetMarket.sol";

contract Deploy is Script {
    function run() external {
        // Read addresses from environment variables or provide defaults/placeholders
        address sachetMarketTokenAddress = vm.envOr("BETTING_TOKEN", address(0));
        address adminMultisig = vm.envOr("ADMIN_MULTISIG", address(0));
        address cronWalletAddress = vm.envOr("CRON_WALLET", address(0));

        require(sachetMarketTokenAddress != address(0), "SachetMarket: Must set BETTING_TOKEN");
        require(adminMultisig != address(0), "SachetMarket: Must set ADMIN_MULTISIG");
        require(cronWalletAddress != address(0), "SachetMarket: Must set CRON_WALLET");

        vm.startBroadcast();
        SachetMarket escrow = new SachetMarket(sachetMarketTokenAddress, adminMultisig);
        escrow.grantRole(escrow.RESOLVER_ROLE(), cronWalletAddress);
        vm.stopBroadcast();
    }
}
