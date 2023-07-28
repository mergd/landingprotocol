// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "forge-std/Test.sol";

import "src/LoanCoordinator.sol";
import "./mocks/MockLender.sol";
import "./mocks/MockERC20.sol";

contract LoanCoordinatorTest is Test {
    LoanCoordinator coordinator;
    MockERC20 _collateral;
    MockERC20 _borrow;
    address _borrower = address(0x1);
    address _liquidator = address(0x2);
    MockLender _lender;

    function setUp() external {
        coordinator = new LoanCoordinator();
        Terms memory _term = Terms(1.005 * 1e6, 3, 2, 1000);
        coordinator.setTerms(_term);
        _collateral = new MockERC20("LEND", "LENDING TOKEN", 18);
        _borrow = new MockERC20("BORROW", "BORROWING TOKEN", 18);
        _lender = new MockLender(coordinator, _borrow);
        _collateral.mint(address(this), 1000 * 1e18);
    }

    // Or at https://github.com/foundry-rs/forge-std
    function testLend() public {
        _borrow.mint(address(_lender), 1000e18);
        collateralmintAndApprove(_borrower, 1000 * 1e18);

        vm.startPrank(_borrower);
        coordinator.createLoan(
            address(_lender),
            _collateral,
            _borrow,
            10 * 1e18,
            10 * 1e18,
            0.1 * 1e6,
            0,
            0
        );
        assertEq(_borrow.balanceOf(_borrower), 10 * 1e18);
    }

    function testLiquidate() public {
        _borrow.mint(address(_lender), 1000e18);
        collateralmintAndApprove(_borrower, 1000 * 1e18);
        vm.startPrank(_borrower);
        coordinator.createLoan(
            address(_lender),
            _collateral,
            _borrow,
            1 * 1e18,
            1 * 1e18,
            0.5 * 1e6,
            0,
            0
        );

        vm.warp(8 hours - 1);
        // _lender.liquidate(0);
        // vm.expectRevert();

        vm.warp(1);
        _lender.liquidate(1);
    }

    function testRebalanceRate() public {
        _borrow.mint(address(_lender), 1000e18);
        collateralmintAndApprove(_borrower, 1000 * 1e18);
        vm.startPrank(_borrower);
        coordinator.createLoan(
            address(_lender),
            _collateral,
            _borrow,
            1 * 1e18,
            1 * 1e18,
            0.5 * 1e6,
            0,
            0
        );

        vm.warp(8 hours + 1);
        _lender.rebalanceRate(1, 0.2 * 1e6);
    }

    function collateralmintAndApprove(
        address receipient,
        uint256 amount
    ) public {
        _collateral.mint(receipient, amount);
        vm.prank(receipient);
        _collateral.approve(address(coordinator), amount);
    }
}
