// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import {Script} from "forge-std/Script.sol";

import "src/LoanCoordinator.sol";

import "src/periphery/LenderRegistry.sol";

/// @notice A very simple deployment script
contract Deploy is Script {
    function run() external returns (LoanCoordinator loanCoordinator) {
        vm.startBroadcast();
        loanCoordinator = new LoanCoordinator();
        vm.stopBroadcast();
    }
}
