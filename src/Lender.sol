// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {LoanCoordinator} from "./LoanCoordinator.sol";
import "./ILoanCoordinator.sol";

abstract contract Lender {
    // Callback contracts can prevent repayments and bidding, so it's somewhat trusted
    constructor(ILoanCoordinator _coordinator) {
        coordinator = _coordinator;
    }

    error Lender_OnlyCoordinator();

    modifier onlyCoordinator() {
        if (msg.sender != address(coordinator)) revert Lender_OnlyCoordinator();
        _;
    }

    ILoanCoordinator public immutable coordinator;

    /**
     * Verify the loans
     * @dev THIS SHOULD BE RESTRICTED TO ONLY THE COORDINATOR IF IT UPDATES STATE
     * @param _loan Loan struct
     * @param _data Any additional identifying data
     */
    function verifyLoan(ILoanCoordinator.Loan memory _loan, bytes calldata _data) external virtual returns (bytes4);

    /**
     * View function for verifying loan for UI
     * @param _loan Loan struct
     * @param _data Any additional identifying data
     */
    function viewVerifyLoan(ILoanCoordinator.Loan memory _loan, bytes calldata _data)
        public
        view
        virtual
        returns (bool);

    /**
     * Called after _loan is repaid
     * @param _loan Loan struct
     * @param _lenderReturn Amount returned to lender – at max this is principal + interest + penalty
     * @param _borrowerReturn Excess collateral returned to borrower
     */
    function auctionSettledHook(ILoanCoordinator.Loan memory _loan, uint256 _lenderReturn, uint256 _borrowerReturn)
        external
        virtual
        returns (bytes4);

    /**
     * Called after loan is changed
     * @param _loan Loan struct
     * @param _debtChgAmount Amount of debt token borrowed or repaid (negative)
     * @param _isFullRepayment True if loan is fully repaid
     * @param _interest Interest delta since last change
     */
    function debtChangedHook(
        ILoanCoordinator.Loan memory _loan,
        int256 _debtChgAmount,
        bool _isFullRepayment,
        uint256 _interest
    ) external virtual returns (bytes4);

    /**
     * Called after loan has a collateral change
     * @param _loan Loan struct
     * @param _collateralChgAmount Amount of collateral added or removed (negative)
     * @param _interest Interest delta since last change
     */
    function collateralChangedHook(ILoanCoordinator.Loan memory _loan, int256 _collateralChgAmount, uint256 _interest)
        external
        virtual
        returns (bytes4);

    /**
     * @dev Claim collateral from an auction that fails to clear
     * @param _loanId The _loan ID
     */
    function reclaim(uint256 _loanId) external virtual;
}
