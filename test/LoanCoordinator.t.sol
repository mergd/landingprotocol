// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "forge-std/Test.sol";

import "src/LoanCoordinator.sol";
import "./mocks/MockLender.sol";
import "./mocks/MockERC20.sol";
import "./mocks/MockBorrower.sol";

contract LoanCoordinatorTest is Test {
    LoanCoordinator coordinator;
    MockERC20 _collateral;
    MockERC20 _borrow;
    address _borrower;
    address _liquidator = address(0x2);
    MockLender _lender;
    uint256 termSet;

    function setUp() external {
        coordinator = new LoanCoordinator();
        ILoanCoordinator.Term memory _term = ILoanCoordinator.Term(
            1.005 * 1e6, // Liquidation bonus
            100 // Auction duration
        );
        termSet = coordinator.setTerms(_term);
        _collateral = new MockERC20("LEND", "LENDING TOKEN", 18);
        _borrow = new MockERC20("BORROW", "BORROWING TOKEN", 18);
        _lender = new MockLender(coordinator, _borrow);
        _borrower = address(new MockBorrower(coordinator));
        _collateral.mint(address(this), 1000 * 1e18);
    }

    // Or at https://github.com/foundry-rs/forge-std
    function testLend() public {
        _borrow.mint(address(_lender), 1000e18);
        collateralmintAndApprove(_borrower, 1000 * 1e18);

        vm.startPrank(_borrower);
        coordinator.createLoan(address(_lender), _collateral, _borrow, 1, 1, 0.1 * 1e6, 1, termSet);
        // assertEq(_borrow.balanceOf(_borrower), 10 * 1e18);
    }

    function testReclaim() public {
        _borrow.mint(address(_lender), 1000e18);
        collateralmintAndApprove(_borrower, 1000 * 1e18);
        vm.startPrank(_borrower);
        uint256 loanId =
            coordinator.createLoan(address(_lender), _collateral, _borrow, 1 * 1e18, 1 * 1e18, 0.5 * 1e6, 4, 0);

        vm.warp(8 hours + 1);

        _lender.liquidate(1);

        vm.warp(8 hours + 102);
        coordinator.reclaim(0);
    }

    function testLiquidate() public {
        _borrow.mint(address(_lender), 1000e18);
        collateralmintAndApprove(_borrower, 1000 * 1e18);
        vm.startPrank(_borrower);
        coordinator.createLoan(address(_lender), _collateral, _borrow, 1 * 1e18, 1 * 1e18, 0.5 * 1e6, 4, 0);

        vm.warp(8 hours + 1);
        _lender.liquidate(1);
    }

    // Test when the a descending amount of collateral is offered
    function testBid1() public {
        _borrow.mint(address(_lender), 1000e18);
        collateralmintAndApprove(_borrower, 1000 * 1e18);
        vm.startPrank(_borrower);
        uint256 _loan = coordinator.createLoan(address(_lender), _collateral, _borrow, 1e18, 1e18, 0.5 * 1e6, 1, 0);

        vm.warp(1 days + 1);
        uint256 liqd = _lender.liquidate(_loan);
        vm.warp(block.timestamp + 20);
        (uint256 bidAmt, uint256 collateralAmt) = coordinator.getCurrentPrice(liqd);
        assertGt(bidAmt, 1e18); // Inclusive of interest
        assertLt(collateralAmt, 1e18);
        console2.log("Auction Price", bidAmt);
        borrowMintAndApprove(address(1), bidAmt);

        vm.startPrank(address(1));
        coordinator.bid(0);
    }

    // Test when a descending amount of principal is offered
    function testBid2() public {
        _borrow.mint(address(_lender), 1000e18);
        collateralmintAndApprove(_borrower, 1000 * 1e18);
        vm.startPrank(_borrower);
        uint256 _loan =
            coordinator.createLoan(address(_lender), _collateral, _borrow, 100e18, 100e18, 0.01 * 10e6, 1, 0);

        vm.warp(1 days + 1);
        uint256 liqd = _lender.liquidate(_loan);
        vm.warp(block.timestamp + 90);
        (uint256 bidAmt, uint256 collateralAmt) = coordinator.getCurrentPrice(liqd);
        assertLt(bidAmt, 100e18);
        assertEq(collateralAmt, 100e18);
        // assertEq(collateralAmt, 1e18);
        borrowMintAndApprove(address(1), bidAmt);

        console2.log("Auction Price", bidAmt);
        console2.log("Coll amt Price", collateralAmt);
        vm.startPrank(address(1));
        coordinator.bid(0);
    }

    function testLoanNoAuction() public {
        ILoanCoordinator.Term memory _term = ILoanCoordinator.Term(
            1.005 * 1e6, // Liquidation bonus
            0 // Auction duration
        );
        termSet = coordinator.setTerms(_term);
        _borrow.mint(address(_lender), 100e18);
        collateralmintAndApprove(_borrower, 100 * 1e18);
        vm.startPrank(_borrower);
        uint256 _loan =
            coordinator.createLoan(address(_lender), _collateral, _borrow, 100e18, 100e18, 0.01 * 10e6, 4, termSet);

        vm.startPrank(address(_lender));
        _lender.liquidate(_loan);
        assertEq(100e18, _collateral.balanceOf(address(_lender)));
    }

    function testRebalanceRate() public {
        _borrow.mint(address(_lender), 1000e18);
        collateralmintAndApprove(_borrower, 1000 * 1e18);
        vm.startPrank(_borrower);
        coordinator.createLoan(address(_lender), _collateral, _borrow, 1 * 1e18, 1 * 1e18, 0.5 * 1e6, 0, 0);

        vm.warp(8 hours + 1);
        _lender.rebalanceRate(1, 0.2 * 1e6);
    }

    function testRepay() public {
        _borrow.mint(address(_lender), 1000e18);
        collateralmintAndApprove(_borrower, 1000e18);
        vm.startPrank(_borrower);
        coordinator.createLoan(address(_lender), _collateral, _borrow, 1 * 1e18, 1 * 1e18, 0.5 * 1e6, 0, 0);

        borrowMintAndApprove(_borrower, 1.01 * 1e18);
        vm.startPrank(_borrower);
        coordinator.repayLoan(1);
    }

    function testFlashLoan() public {
        _borrow.mint(address(_lender), 1000e18);
        collateralmintAndApprove(_borrower, 1000 * 1e18);
        vm.startPrank(_borrower);
        coordinator.createLoan(address(_lender), _collateral, _borrow, 1 * 1e18, 1 * 1e18, 0.5 * 1e6, 0, 0);
        MockBorrower(_borrower).getFlashloan(true, _collateral);
    }

    function testFailFlashLoan() public {
        _borrow.mint(address(_lender), 1000e18);
        collateralmintAndApprove(_borrower, 1000 * 1e18);
        vm.startPrank(_borrower);
        coordinator.createLoan(address(_lender), _collateral, _borrow, 1 * 1e18, 1 * 1e18, 0.5 * 1e6, 0, 0);

        MockBorrower(_borrower).getFlashloan(false, _collateral);
        vm.expectRevert();
    }

    function collateralmintAndApprove(address receipient, uint256 amount) public {
        _collateral.mint(receipient, amount);
        vm.startPrank(receipient);
        _collateral.approve(address(coordinator), amount);
    }

    function borrowMintAndApprove(address receipient, uint256 amount) public {
        _borrow.mint(receipient, amount);
        vm.startPrank(receipient);
        _borrow.approve(address(coordinator), amount);
    }
}
