// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "src/ILender.sol";
import "./Kernel.sol";

contract LoanPoolFactory is Policy {
    constructor(Kernel _kernel) Policy(_kernel) {}
    // implement default factory here?

    function configureDependencies() external override returns (Keycode[] memory dependencies) {
        dependencies = new Keycode[](1);
        // dependencies[0] = Keycode(address());
    }

    function requestPermissions() external view override returns (Permissions[] memory requests) {
        requests = new Permissions[](1);
        // requests[0] = Permissions.LOAN;
    }

    function createNewPool() external {}
}
