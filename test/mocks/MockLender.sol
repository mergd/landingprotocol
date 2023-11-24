// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "../../src/LoanCoordinator.sol";

contract MockLender is Lender {
    function test() public {}

    constructor(LoanCoordinator _coordinator, ERC20 _debt) Lender(_coordinator) {
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

    function debtChangedHook(ILoanCoordinator.Loan memory, int256, bool, uint256)
        external
        pure
        override
        returns (bytes4)
    {
        return Lender.debtChangedHook.selector;
    }

    function collateralChangedHook(ILoanCoordinator.Loan memory, int256, uint256)
        external
        pure
        override
        returns (bytes4)
    {
        return Lender.collateralChangedHook.selector;
    }

    function liquidate(uint256 loan) external returns (uint256) {
        (uint256 auctionid,) = coordinator.liquidateLoan(loan);
        return auctionid;
    }

    function reclaim(uint256 _loanId) external virtual override {
        coordinator.reclaim(_loanId);
    }

    function viewVerifyLoan(ILoanCoordinator.Loan memory, bytes calldata) public view virtual override returns (bool) {
        return true;
    }

    function stop(uint256 _auctionId) external {
        coordinator.stopAuction(_auctionId);
    }
}
