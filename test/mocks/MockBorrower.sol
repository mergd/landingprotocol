// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "src/LoanCoordinator.sol";

contract MockBorrower is Borrower {
    function test() public {}
    constructor(ILoanCoordinator _coordinator) Borrower(_coordinator) {}

    /**
     * @dev Called when loan is liquidated
     */
    function liquidationHook(ILoanCoordinator.Loan memory) external override {
        console2.log("Liquidation hook called");
    }

    function interestRateUpdateHook(ILoanCoordinator.Loan memory, uint256, uint256) external virtual override {
        console2.log("Interest rate update hook called");
    }

    function auctionSettledHook(ILoanCoordinator.Loan memory, uint256, uint256) external override {
        console2.log("Auction settled hook called");
    }

    /**
     * @dev Flashloan callback
     */
    function executeOperation(ERC20 token, uint256, address, bytes memory data) external override returns (bool) {
        if (abi.decode(data, (bool))) {
            console2.log("Approving");
            token.approve(msg.sender, type(uint256).max);
        }
        // Should by default revert
        return true;
    }

    function getFlashloan(bool approve, ERC20 collateralToken) external {
        bytes memory data = abi.encode(approve);
        coordinator.getFlashLoan(address(this), collateralToken, 100, data);
    }
}
