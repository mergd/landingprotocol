// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "src/LoanCoordinator.sol";

contract MockLender is ILenderInterface {
    LoanCoordinator coordinator;

    constructor(LoanCoordinator _coordinator, ERC20 _debt) {
        coordinator = _coordinator;
        _debt.approve(address(coordinator), type(uint256).max);
    }

    function verifyLoan(
        Loan memory loan,
        bytes32 data
    ) external override returns (bool) {
        return true;
    }

    function auctionSettledHook(
        Loan memory loan,
        uint256 lenderReturn,
        uint256 borrowerReturn
    ) external override {}

    function loanRepaidHook(Loan memory loan) external override {}

    function liquidate(uint256 loan) external {
        coordinator.liquidateLoan(loan);
    }
}
