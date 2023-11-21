// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "src/LoanCoordinator.sol";

contract MockBorrower is IFlashLoanReceiver {
    function test() public {}

    ILoanCoordinator public coordinator;

    constructor(ILoanCoordinator _coordinator) {
        coordinator = _coordinator;
    }

    /**
     * @dev Flashloan callback
     */
    function executeOperation(ERC20 token, uint256, address, bytes memory data) external override returns (bool) {
        if (abi.decode(data, (bool))) {
            console2.log("Approving");
            token.approve(msg.sender, type(uint256).max);
        }
        // Should by default revert
        return true;
    }

    function getFlashloan(bool approve, ERC20 collateralToken) external {
        bytes memory data = abi.encode(approve);
        coordinator.getFlashLoan(address(this), collateralToken, 100, data);
    }
}
