// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {LoanCoordinator} from "./LoanCoordinator.sol";
import "./ILoanCoordinator.sol";

/// @dev Optional interface for borrowers to implement
abstract contract Borrower {
    constructor(ILoanCoordinator _coordinator) {
        coordinator = _coordinator;
    }

    modifier onlyCoordinator() {
        require(msg.sender == address(coordinator), "Borrower: Only coordinator");
        _;
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
