// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "forge-std/Script.sol";

import "src/LoanCoordinator.sol";

import "src/periphery/LenderRegistry.sol";
import "src/periphery/YieldLooping.sol";

import "test/mocks/MockERC20.sol";

/// @notice A very simple deployment script
contract Deploy is Script {
    function run() external returns (LoanCoordinator loanCoordinator) {
        vm.startBroadcast();
        loanCoordinator = new LoanCoordinator();
        console2.log(
            "Deployed LoanCoordinator at address: ",
            address(loanCoordinator)
        );

        LenderRegistry lenderRegistry = new LenderRegistry(
            loanCoordinator,
            address(this)
        );
        console2.log(
            "Deployed Lender Registry at address: ",
            address(lenderRegistry)
        );

        MockERC20 debtToken = new MockERC20("Debt Token", "DEBT", 18);
        console2.log("Deployed Debt Token at address: ", address(debtToken));

        MockERC20 collateralToken = new MockERC20(
            "Collateral Token",
            "COLL",
            18
        );

        console2.log(
            "Deployed Collateral Token at address: ",
            address(collateralToken)
        );

        YieldLooping looper = new YieldLooping(
            0.70 * 1e6, // 70%
            0.03 * 1e6, // 3%
            0.01 * 1e6, // 1%
            debtToken,
            loanCoordinator
        );

        console2.log("Deployed YieldLooping at address: ", address(looper));

        vm.stopBroadcast();
    }
}
