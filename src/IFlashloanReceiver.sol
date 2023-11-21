// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {ERC20} from "@solmate/tokens/ERC20.sol";

interface IFlashloanReceiver {
    /**
     * @dev Flashloan receiver callback
     * @param token ERC20 token
     * @param amount amount of tokens
     * @param sender Originator of the flashloan
     * @param data Data to be executed
     */
    function executeOperation(ERC20 token, uint256 amount, address sender, bytes memory data) external returns (bool);
}
