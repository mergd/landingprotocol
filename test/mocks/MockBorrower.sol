// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "src/LoanCoordinator.sol";

contract MockBorrower is Borrower {
    constructor(ILoanCoordinator _coordinator) Borrower(_coordinator) {}

    /**
     * @dev Called when loan is liquidated
     * @param loan Loan struct
     */
    function liquidationHook(ILoanCoordinator.Loan memory loan) external override {}

    /**
     * @dev Called when the interest rate is rebalanced
     * @param loan Loan struct
     * @param newRate New interest rate
     */
    function interestRateUpdateHook(ILoanCoordinator.Loan memory loan, uint256 newRate) external virtual override {}

    /**
     * @dev Called when the auction is settled
     * @param loan Loan struct
     * @param lenderReturn Amount returned to lender – at max this is principal + interest + penalty
     * @param borrowerReturn Excess collateral returned to borrower
     */
    function auctionSettledHook(ILoanCoordinator.Loan memory loan, uint256 lenderReturn, uint256 borrowerReturn)
        external
        override
    {}

    /**
     * @dev Flashloan callback
     */
    function executeOperation(ERC20, uint256, address, bytes memory) external override returns (bool) {
        return true;
    }
}
