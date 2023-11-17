// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {LoanCoordinator} from "./LoanCoordinator.sol";
import "./ILoanCoordinator.sol";

/// @dev Optional interface for borrowers to implement
abstract contract Borrower {
    constructor(ILoanCoordinator _coordinator) {
        coordinator = _coordinator;
    }

    error Borrower_OnlyCoordinator();

    modifier onlyCoordinator() {
        if (msg.sender != address(coordinator)) revert Borrower_OnlyCoordinator();
        _;
    }

    ILoanCoordinator public immutable coordinator;

    /**
     * @dev Called when loan is liquidated
     * @param _loan Loan struct
     */
    function liquidationHook(ILoanCoordinator.Loan memory _loan) external virtual;

    /**
     * @dev Called when the interest rate is rebalanced
     * @param _loan Loan struct
     * @param _newRate New interest rate
     */
    function interestRateUpdateHook(ILoanCoordinator.Loan memory _loan, uint256 _newRate) external virtual;

    /**
     * @dev Called when the auction is settled
     * @param _loan Loan struct
     * @param _lenderReturn Amount returned to lender – at max this is principal + interest + penalty
     * @param _borrowerReturn Excess collateral returned to borrower
     */
    function auctionSettledHook(ILoanCoordinator.Loan memory _loan, uint256 _lenderReturn, uint256 _borrowerReturn)
        external
        virtual;

    /**
     * @dev Flashloan callback
     */
    function executeOperation(ERC20 _token, uint256 _amount, address _initiator, bytes memory _params)
        external
        virtual
        returns (bool);
}
