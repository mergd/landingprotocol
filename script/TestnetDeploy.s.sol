// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "forge-std/Script.sol";

import {LoanCoordinator} from "src/LoanCoordinator.sol";

import "test/mocks/MockERC20.sol";

/// @notice A very simple deployment script
contract Deploy is Script {
    function test() public {}

    function run() external returns (LoanCoordinator loanCoordinator) {
        uint256 deployer_key = vm.envUint("DEPLOYER_KEY");

        vm.startBroadcast(deployer_key);
        loanCoordinator = new LoanCoordinator();
        console2.log("Deployed LoanCoordinator at address: ", address(loanCoordinator));
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
