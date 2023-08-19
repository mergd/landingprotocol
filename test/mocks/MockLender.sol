// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "src/LoanCoordinator.sol";

contract MockLender is Lender {
    function test() public {}

    constructor(LoanCoordinator _coordinator, ERC20 _debt) Lender(_coordinator, true) {
        _debt.approve(address(coordinator), type(uint256).max);
    }

    function verifyLoan(ILoanCoordinator.Loan memory, bytes32) external pure override returns (bool) {
        return true;
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

    function rebalanceRate(uint256 loan, uint256 newRate) external {
        coordinator.rebalanceRate(loan, newRate);
    }

    function getQuote(ILoanCoordinator.Loan memory) external pure override returns (uint256, uint256, uint256) {
        return (0, 0, 0);
    }

    function viewVerifyLoan(ILoanCoordinator.Loan memory loan, bytes32 data)
        public
        view
        virtual
        override
        returns (bool)
    {
        return true;
    }
}
