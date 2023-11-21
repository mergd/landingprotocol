// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {ERC20} from "@solmate/tokens/ERC20.sol";

interface IFlashLoanReceiver {
    /**
     * @dev Flashloan callback
     */
    function executeOperation(ERC20 _token, uint256 _amount, address _initiator, bytes memory _params)
        external
        returns (bool);
}
