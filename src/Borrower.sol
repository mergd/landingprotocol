// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {LoanCoordinator} from "./LoanCoordinator.sol";
import "./ILoanCoordinator.sol";
import "./periphery/NoDelegateCall.sol";

/// @dev Optional interface for borrowers to implement
abstract contract Borrower is NoDelegateCall {
    constructor(ILoanCoordinator _coordinator) {
        coordinator = _coordinator;
    }

    ILoanCoordinator public immutable coordinator;

    /**
     * @dev Called when loan is liquidated
     * @param loan Loan struct
     */
    function liquidationHook(ILoanCoordinator.Loan memory loan) external virtual;

    /**
     * @dev Called when the interest rate is rebalanced
     * @param loan Loan struct
     * @param newRate New interest rate
     */
    function interestRateUpdateHook(ILoanCoordinator.Loan memory loan, uint256 newRate) external virtual;

    /**
     * @dev Called when the auction is settled
     * @param loan Loan struct
     * @param lenderReturn Amount returned to lender – at max this is principal + interest + penalty
     * @param borrowerReturn Excess collateral returned to borrower
     */
    function auctionSettledHook(ILoanCoordinator.Loan memory loan, uint256 lenderReturn, uint256 borrowerReturn)
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
