// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "forge-std/Script.sol";

import {LoanCoordinator} from "src/LoanCoordinator.sol";

import "test/mocks/MockERC20.sol";

/// @notice A very simple deployment script
contract Deploy is Script {
    function test() public {}

    function run() external returns (LoanCoordinator loanCoordinator) {
        vm.startBroadcast();
        loanCoordinator = new LoanCoordinator();
        console2.log("Deployed LoanCoordinator at address: ", address(loanCoordinator));

        // LenderRegistry lenderRegistry = new LenderRegistry(
        //     loanCoordinator,
        //     address(this)
        // );
        // console2.log("Deployed Lender Registry at address: ", address(lenderRegistry));

        MockERC20 debtToken = new MockERC20("Debt Token", "DEBT", 18);
        console2.log("Deployed Debt Token at address: ", address(debtToken));

        MockERC20 collateralToken = new MockERC20(
            "Collateral Token",
            "COLL",
            18
        );

        console2.log("Deployed Collateral Token at address: ", address(collateralToken));

        vm.stopBroadcast();
    }
}
