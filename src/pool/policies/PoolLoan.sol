// SPDX License-Identifier: MIT
pragma solidity ^0.8.17;

import "../Kernel.sol";
import {PRICEv1} from "../modules/PRICE/PRICE.v1.sol";
import "src/LoanCoordinator.sol";

contract Pool is ILenderInterface, Policy {
    LoanCoordinator public immutable coordinator;
    PRICEv1 public PRICE;

    constructor(Kernel _kernel, LoanCoordinator _coordinator) Policy(_kernel) {
        coordinator = _coordinator;
        // By default it's 8
    }

    function configureDependencies()
        external
        override
        returns (Keycode[] memory dependencies)
    {
        dependencies = new Keycode[](1);
        dependencies[0] = Keycode(toKeycode("PRICE"));
        PRICE = PRICEv1(getModuleAddress(dependencies[0]));
    }

    /// @notice Function called by kernel to set module function permissions.
    /// @return requests - Array of keycodes and function selectors for requested permissions.
    function requestPermissions()
        external
        view
        override
        returns (Permissions[] memory requests)
    {}

    function verifyLoan(Loan memory loan) external override returns (bool) {
        return true;
    }

    function auctionSettledHook(
        Loan memory loan,
        uint256 lenderReturn,
        uint256 borrowerReturn
    ) external override {}

    function loanRepaidHook(Loan memory loan) external override {}
}
