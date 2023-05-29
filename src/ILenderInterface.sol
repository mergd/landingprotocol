// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "./LoanCoordinator.sol";

interface ILenderInterface {
    function verifyLoan(LoanCoordinator.Loan memory loan) external returns (bool);

    function liquidateLoan(uint256 loanId) external;

    function loanRepaidHook(LoanCoordinator.Loan memory loan) external;
}
