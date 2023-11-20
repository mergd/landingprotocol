// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "forge-std/Test.sol";

import {LoanCoordinator, ILoanCoordinator} from "src/LoanCoordinator.sol";
import {MockLender} from "./mocks/MockLender.sol";
import "./mocks/MockERC20.sol";
import {MockBorrower} from "./mocks/MockBorrower.sol";

contract LoanCoordinatorTest is Test {
    LoanCoordinator coordinator;
    MockERC20 _collateral;
    MockERC20 _debt;
    address _borrower;
    address _borrowerContract;
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
        _collateral = new MockERC20("COLLATERAL", "COLLATERAL TOKEN", 18);
        _debt = new MockERC20("DEBT", "DEBT TOKEN", 18);
        _lender = new MockLender(coordinator, _debt);
        _borrower = address(2);
        _borrowerContract = address(new MockBorrower(coordinator));
        _collateral.mint(address(this), 1000 * 1e18);
    }

    function testLend() public {
        _debt.mint(address(_lender), 1e18);
        collateralmintAndApprove(_borrower, 1e18);

        vm.startPrank(_borrower);
        coordinator.createLoan(_borrower, address(_lender), _collateral, _debt, 1e18, 1e18, 0.1 * 1e6, 1, termSet, "");
        assertEq(_debt.balanceOf(_borrower), 1e18);
    }

    function testReclaim() public {
        uint256 _termSet = createTerm(1.5 * 1e6, 10);
        uint256 _loan = createLoan(_borrower, 0.5 * 1e6, 0, _termSet);
        vm.warp(8 hours + 1);

        _lender.liquidate(_loan);

        vm.warp(8 hours + 102);
        coordinator.reclaim(0);
    }

    function testLiquidate() public {
        uint256 _loan = createLoan(_borrower, 0.5 * 1e6, 0, 0);

        vm.warp(8 hours + 1);
        _lender.liquidate(_loan);
    }

    // Test when the a descending amount of collateral is offered
    function testBid1() public {
        uint256 _termSet = createTerm(1.5 * 1e6, 100);
        uint256 _loan = createLoan(_borrower, 0.5 * 1e6, 0, _termSet);

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
        uint256 _termSet = createTerm(1.5 * 1e6, 100);

        uint256 _loan = createLoan(_borrower, 0.5 * 1e6, 0, _termSet);

        vm.warp(1 days + 1);
        uint256 liqd = _lender.liquidate(_loan);
        vm.warp(block.timestamp + 90);
        (uint256 bidAmt, uint256 collateralAmt) = coordinator.getCurrentPrice(liqd);
        assertLt(bidAmt, 1e18);
        assertEq(collateralAmt, 1e18);
        // assertEq(collateralAmt, 1e18);
        borrowMintAndApprove(address(1), 1e18);

        console2.log("Auction Price", bidAmt);
        console2.log("Coll amt Price", collateralAmt);
        vm.startPrank(address(1));
        coordinator.bid(0);
    }
    // Test reclaim

    function testBid3() public {
        uint256 _termSet = createTerm(1.5 * 1e6, 100);
        uint256 _loan = createLoan(_borrower, 0.5 * 1e6, 0, _termSet);

        vm.warp(1 days + 1);
        uint256 liqd = _lender.liquidate(_loan);
        vm.warp(block.timestamp + 100);
        (uint256 bidAmt, uint256 collateralAmt) = coordinator.getCurrentPrice(liqd);
        assertEq(bidAmt, 0);
        assertEq(collateralAmt, 0);
        borrowMintAndApprove(address(1), bidAmt);

        console2.log("Auction Price", bidAmt);
        console2.log("Coll amt Price", collateralAmt);
        vm.startPrank(address(1));
        // Auction has failed to clear
        vm.expectRevert();
        coordinator.bid(0);

        // Reclaim
        _lender.reclaim(0);
        // Collateral sent to lender

        assertEq(_collateral.balanceOf(address(_lender)), 1e18);
    }

    function testLoanNoAuction() public {
        uint256 loanId = createLoan(_borrower, 0.5 * 1e6, 0, 0);

        vm.startPrank(address(_lender));
        _lender.liquidate(loanId);
        console2.log("amount", _collateral.balanceOf(address(_lender)));
        assertEq(1e18, _collateral.balanceOf(address(_lender)));
    }

    function testRebalanceRate() public {
        uint256 loanId = createLoan(_borrower, 0.5 * 1e6, 0, 0);

        vm.warp(8 hours + 1);
        uint256 _amount = _lender.rebalanceRate(loanId, 0.2 * 1e6);
        console2.log("Realized interest from principal", _amount);
        // Add some checks here
    }

    function testRepay() public {
        uint256 loanId = createLoan(_borrower, 0.5 * 1e6, 0, 0);

        borrowMintAndApprove(_borrower, 1.01 * 1e18);
        vm.startPrank(_borrower);
        coordinator.repayLoan(loanId);
    }

    function testRepayWhileAuction() public {
        uint256 _term = createTerm(1.5 * 1e6, 10);
        uint256 loanId = createLoan(_borrower, 0.5 * 1e6, 0, _term);

        borrowMintAndApprove(_borrower, 1.01 * 1e18);
        vm.startPrank(_borrower);
        _lender.liquidate(loanId);
        vm.warp(block.timestamp + 1);
        // Borrower should still be able to repay
        coordinator.repayLoan(loanId);
    }

    function testInvalidTerms() public {
        vm.expectRevert();
        createTerm(1.5 * 1e6, 0);
        vm.expectRevert();
        createTerm(2e7, 10);
    }

    function testFlashLoan() public {
        createLoan(_borrower, 0.5 * 1e6, 0, 0);
        MockBorrower(_borrowerContract).getFlashloan(true, _collateral);
    }

    function testFailFlashLoan() public {
        _debt.mint(address(coordinator), 1001e18);
        // Flashloan reverts since callback returns false
        MockBorrower(_borrowerContract).getFlashloan(false, _collateral);
    }

    /* -------------------------------------------------------------------------- */
    /*                                 Test Utils                                 */
    /* -------------------------------------------------------------------------- */
    function createLoan(address borrowAddress, uint256 rate, uint256 duration, uint256 terms)
        public
        returns (uint256)
    {
        vm.startPrank(borrowAddress);
        uint256 _borrowAmt = 1e18;
        uint256 _collateralAmt = 1e18;

        collateralmintAndApprove(borrowAddress, _collateralAmt);
        _debt.mint(address(_lender), _borrowAmt);
        return coordinator.createLoan(
            borrowAddress, address(_lender), _collateral, _debt, _collateralAmt, _borrowAmt, rate, duration, terms, ""
        );
    }

    function collateralmintAndApprove(address recipient, uint256 amount) public {
        _collateral.mint(recipient, amount);
        vm.startPrank(recipient);
        _collateral.approve(address(coordinator), amount);
    }

    function borrowMintAndApprove(address recipient, uint256 amount) public {
        _debt.mint(recipient, amount);
        vm.startPrank(recipient);
        _debt.approve(address(coordinator), amount);
    }

    function createTerm(uint256 bonus, uint256 duration) public returns (uint256) {
        ILoanCoordinator.Term memory _term = ILoanCoordinator.Term(uint24(bonus), uint24(duration));
        return coordinator.setTerms(_term);
    }
}
