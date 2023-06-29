// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.15;

import "src/LoanCoordinator.sol";

contract LoopZap is Borrower {
    constructor(LoanCoordinator _loanCoordinator) Borrower(_loanCoordinator) {}

    function liquidationHook(Loan memory loan) external override {}

    function auctionSettledHook(
        Loan memory loan,
        uint256 lenderReturn,
        uint256 borrowerReturn
    ) external override {}
}
