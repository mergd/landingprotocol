// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {LoanCoordinator} from "./LoanCoordinator.sol";
import "./ILoanCoordinator.sol";
import "./periphery/NoDelegateCall.sol";

abstract contract Lender is NoDelegateCall {
    // Callback contracts can prevent repayments and bidding, so it's somewhat trusted
    constructor(ILoanCoordinator _coordinator, bool _callback) NoDelegateCall() {
        coordinator = _coordinator;
        callback = _callback;
    }

    bool public immutable callback; // False - No callbacks, True - Allow callbacks
    ILoanCoordinator public immutable coordinator;

    /**
     * Verify the loans - should be noDelegateCall
     * @dev THIS SHOULD BE RESTRICTED TO ONLY THE COORDINATOR IF IT UPDATES STATE
     * @param loan Loan struct
     * @param data Any additional identifying data
     */
    function verifyLoan(ILoanCoordinator.Loan memory loan, bytes32 data) external virtual returns (bool);

    /**
     * Verify the loans - should be noDelegateCall
     * View function for verifying loan for UI
     * @param loan Loan struct
     * @param data Any additional identifying data
     */
    function viewVerifyLoan(ILoanCoordinator.Loan memory loan, bytes32 data) public view virtual returns (bool);

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
