// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "src/LoanCoordinator.sol";

contract MockLender is Lender {
    function test() public {}

    constructor(LoanCoordinator _coordinator, ERC20 _debt) Lender(_coordinator, true) {
        _debt.approve(address(coordinator), type(uint256).max);
    }

    function verifyLoan(ILoanCoordinator.Loan memory, bytes calldata) external pure override returns (bytes4) {
        return Lender.verifyLoan.selector;
    }

    function auctionSettledHook(ILoanCoordinator.Loan memory, uint256, uint256)
        external
        pure
        override
        returns (bytes4)
    {
        return Lender.auctionSettledHook.selector;
    }

    function loanRepaidHook(ILoanCoordinator.Loan memory) external pure override returns (bytes4) {
        return Lender.loanRepaidHook.selector;
    }

    function liquidate(uint256 loan) external returns (uint256) {
        return coordinator.liquidateLoan(loan);
    }

    function reclaim(uint256 _loanId) external virtual override {
        coordinator.reclaim(_loanId);
    }

    function viewVerifyLoan(ILoanCoordinator.Loan memory, bytes calldata) public view virtual override returns (bool) {
        return true;
    }
}
