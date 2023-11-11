// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {LoanCoordinator} from "./LoanCoordinator.sol";
import "./ILoanCoordinator.sol";

abstract contract Lender {
    // Callback contracts can prevent repayments and bidding, so it's somewhat trusted
    constructor(ILoanCoordinator _coordinator, bool _callback) {
        coordinator = _coordinator;
        callback = _callback;
    }

    modifier onlyCoordinator() {
        require(msg.sender == address(coordinator), "Lender: Only coordinator");
        _;
    }

    bool public immutable callback; // False - No callbacks, True - Allow callbacks
    ILoanCoordinator public immutable coordinator;

    /**
     * Verify the loans
     * @dev THIS SHOULD BE RESTRICTED TO ONLY THE COORDINATOR IF IT UPDATES STATE
     * @param loan Loan struct
     * @param data Any additional identifying data
     */
    function verifyLoan(ILoanCoordinator.Loan memory loan, bytes calldata data) external virtual returns (bytes4);

    /**
     * View function for verifying loan for UI
     * @param loan Loan struct
     * @param data Any additional identifying data
     */
    function viewVerifyLoan(ILoanCoordinator.Loan memory loan, bytes calldata data)
        public
        view
        virtual
        returns (bool);

    /**
     * Called after loan is repaid
     * @param loan Loan struct
     * @param lenderReturn Amount returned to lender – at max this is principal + interest + penalty
     * @param borrowerReturn Excess collateral returned to borrower
     */
    function auctionSettledHook(ILoanCoordinator.Loan memory loan, uint256 lenderReturn, uint256 borrowerReturn)
        external
        virtual
        returns (bytes4)
    {}

    function loanRepaidHook(ILoanCoordinator.Loan memory loan) external virtual returns (bytes4);

    /**
     * @dev Could be optimized
     * @param loan Pass in a loan struct.
     *      loan.debtAmount == Max Uint -> Max borrowable
     *      loan.collateralAmount == Max Uint -> Min Collateral required
     * @return _interest Provide the interest rate for given params
     * @return _lendAmount Provide the amount that can be borrowed
     * @return _collateral Provide the amount of collateral required
     */
    function getQuote(ILoanCoordinator.Loan memory loan) external view virtual returns (uint256, uint256, uint256);
}
