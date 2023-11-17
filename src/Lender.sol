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

    error Lender_OnlyCoordinator();

    modifier onlyCoordinator() {
        if (msg.sender != address(coordinator)) revert Lender_OnlyCoordinator();
        _;
    }

    bool public immutable callback; // False - No callbacks, True - Allow callbacks
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
        returns (bytes4)
    {}

    /**
     * Called after _loan is repaid
     * @param _loan Loan struct
     */
    function loanRepaidHook(ILoanCoordinator.Loan memory _loan) external virtual returns (bytes4);

    /**
     * @dev Claim collateral from an auction that fails to clear
     * @param _loanId The _loan ID
     */
    function reclaim(uint256 _loanId) external virtual;

    /**
     * @dev The maximum amount of debt token borrowable for a given loan.
     * @param _loan Pass in a _loan struct.
     */
    function getLTV(ILoanCoordinator.Loan memory _loan) external view virtual returns (uint256);

    /**
     * @dev Returns the interest rate for a given loan.
     * @param _loan Pass in a _loan struct.
     * @return The interest rate.
     */
    function getRate(ILoanCoordinator.Loan memory _loan) external view virtual returns (uint256);
}
