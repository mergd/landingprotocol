// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "forge-std/Test.sol";

import {LoanCoordinator, ILoanCoordinator, ICoordRateCalculator} from "../src/LoanCoordinator.sol";
import {MockRateCalc} from "./mocks/MockRateCalculator.sol";
import {MockLender} from "./mocks/MockLender.sol";
import "./mocks/MockERC20.sol";
import {MockBorrower} from "./mocks/MockBorrower.sol";

contract LoanCoordinatorTest is Test {
    LoanCoordinator coordinator;
    MockERC20 _collateral;
    MockERC20 _debt;
    MockRateCalc _rateCalc;
    address _borrower;
    address _borrowerContract;
    address _liquidator = address(0x2);
    MockLender _lender;
    uint256 termSet;

    function setUp() external {
        _rateCalc = new MockRateCalc(1e14); // 8 % a day
        coordinator = new LoanCoordinator();
        ILoanCoordinator.Term memory _term = ILoanCoordinator.Term(
            1.005 * 1e6, // Liquidation bonus
            100, // Auction duration
            0,
            0,
            _rateCalc
        );
        termSet = coordinator.setTerms(_term, 0);
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
        coordinator.createLoan(_borrower, address(_lender), _collateral, _debt, 1e18, 1e18, termSet, "");
        assertEq(_debt.balanceOf(_borrower), 1e18);
    }

    function testReclaim() public {
        uint256 _termSet = createTerm(1.5 * 1e6, 10);
        uint256 _loan = createLoan(_borrower, 0.5 * 1e6, _termSet);
        vm.warp(8 hours + 1);

        _lender.liquidate(_loan);

        vm.warp(8 hours + 102);
        coordinator.reclaim(0);
    }

    function testLiquidate() public {
        uint256 _loan = createLoan(_borrower, 0.5 * 1e6, 0);

        vm.warp(8 hours + 1);
        _lender.liquidate(_loan);
    }

    // Test when the a descending amount of collateral is offered
    function testBid1() public {
        uint256 _termSet = createTerm(1.5 * 1e6, 100);
        uint256 _loan = createLoan(_borrower, 0.5 * 1e6, _termSet);

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

        uint256 _loan = createLoan(_borrower, 0.5 * 1e6, _termSet);

        vm.warp(1 days + 1);
        uint256 liqd = _lender.liquidate(_loan);
        vm.warp(block.timestamp + 90);
        (uint256 bidAmt, uint256 collateralAmt) = coordinator.getCurrentPrice(liqd);
        assertLt(bidAmt, 1e18);
        assertEq(collateralAmt, 1e18);

        coordinator.accrueBorrowIndex(_termSet);
        (uint256 bidAmt1, uint256 collateralAmt1) = coordinator.getCurrentPrice(liqd);
        // Accruing interest doesn't affect the loan execution
        assertEq(bidAmt1, bidAmt);
        assertEq(collateralAmt1, collateralAmt);

        borrowMintAndApprove(address(1), 1e18);

        console2.log("Auction Price", bidAmt);
        console2.log("Coll amt Price", collateralAmt);
        vm.startPrank(address(1));
        coordinator.bid(0);
    }
    // Test reclaim

    function testBid3() public {
        // Create variable rate loan
        uint256 _termSet = createTerm(1.5 * 1e6, 100);
        uint256 _loan = createLoan(_borrower, 0.5 * 1e6, _termSet);

        // Create a fixed rate loan
        uint256 _fixedTerm = createTermFixed(1.5 * 1e6, 100, 1e14);
        uint256 _loan1 = createLoan(_borrower, 0.5 * 1e6, _fixedTerm);

        vm.warp(1 days + 1);
        uint256 liqd = _lender.liquidate(_loan);
        vm.expectRevert(); // Loan Already undergoing liquidation
        _lender.liquidate(_loan);

        // liquidate the fixed rate loan
        uint256 liqd0 = _lender.liquidate(_loan1);

        vm.warp(block.timestamp + 100);
        {
            (uint256 bidAmt, uint256 collateralAmt) = coordinator.getCurrentPrice(liqd);
            assertEq(bidAmt, 0);
            assertEq(collateralAmt, 0);
            borrowMintAndApprove(address(1), bidAmt);

            console2.log("Auction Price", bidAmt);
            console2.log("Coll amt Price", collateralAmt);
        }
        {
            // Liquidate the fixed rate loan
            (uint256 bidAmt, uint256 collateralAmt) = coordinator.getCurrentPrice(liqd0);
            assertEq(bidAmt, 0);
            assertEq(collateralAmt, 0);
            borrowMintAndApprove(address(1), bidAmt);

            console2.log("Auction Price", bidAmt);
            console2.log("Coll amt Price", collateralAmt);
        }
        vm.startPrank(address(1));
        // Auction has failed to clear
        vm.expectRevert();
        coordinator.bid(0);
        vm.expectRevert();
        coordinator.bid(1);

        // Reclaim
        _lender.reclaim(0);
        _lender.reclaim(1);

        // Collateral for both sent to lender
        assertEq(_collateral.balanceOf(address(_lender)), 2e18);
    }

    function testLoanNoAuction() public {
        uint256 _term = createTerm(1.5 * 1e6, 0);
        uint256 loanId = createLoan(_borrower, 0.5 * 1e6, _term);

        vm.startPrank(address(_lender));
        _lender.liquidate(loanId);
        console2.log("amount", _collateral.balanceOf(address(_lender)));
        assertEq(1e18, _collateral.balanceOf(address(_lender)));
    }

    function testRepay() public {
        uint256 _term = createTerm(1.5 * 1e6, 10);
        uint256 loanId = createLoan(_borrower, 0.5 * 1e6, _term);
        uint256 loanId0 = createLoan(_borrower, 0.5 * 1e6, _term);

        borrowMintAndApprove(_borrower, 1e18);
        vm.startPrank(_borrower);
        // Shouldn't revert as the amount paid will only be the full amount
        coordinator.changeDebt(loanId, _borrower, 1000e18);

        // Repay the loan
        borrowMintAndApprove(_borrower, 0.5e18);
        vm.expectRevert(); // Loan is already repaid
        coordinator.changeDebt(loanId, _borrower, 0.5e18);

        // Repay the loan
        coordinator.changeDebt(loanId0, _borrower, 0.5e18);
        ILoanCoordinator.Loan memory _loan = coordinator.getLoan(loanId0, false);
        // Loan was only half repaid
        assertEq(_loan.debtAmount, 0.5e18);
    }

    function testClose() public {
        uint256 _term = createTerm(1.5 * 1e6, 10);
        uint256 loanId = createLoan(_borrower, 0.5 * 1e6, _term);

        borrowMintAndApprove(_borrower, 1.01 * 1e18);
        vm.startPrank(_borrower);
        coordinator.changeDebt(loanId, _borrower, type(int256).max);
    }

    function testCloseWhileAuction() public {
        uint256 _fixedRateTerm = createTermFixed(1.5 * 1e6, 10, 1e14);
        uint256 loanId0 = createLoan(_borrower, 0.5 * 1e6, _fixedRateTerm);

        uint256 _term = createTerm(1.5 * 1e6, 10);
        uint256 loanId1 = createLoan(_borrower, 0.5 * 1e6, _term);
        {
            // allow for some time to accrue interest
            vm.startPrank(_borrower);
            _lender.liquidate(loanId1);
            vm.warp(block.timestamp + 10);
        }
        borrowMintAndApprove(_borrower, 1e18);
        // Interest has accrued even though auction is still live – so paying just principal should revert
        vm.expectRevert();
        coordinator.changeDebt(loanId1, _borrower, type(int256).max);
        vm.expectRevert();
        coordinator.changeDebt(loanId0, _borrower, type(int256).max);

        // Repay loan with interest
        borrowMintAndApprove(_borrower, 10e18);
        coordinator.changeDebt(loanId1, _borrower, type(int256).max);
        coordinator.changeDebt(loanId0, _borrower, type(int256).max);
    }

    function testAddCollateral() public {
        uint256 _fixedRateTerm = createTermFixed(1.5 * 1e6, 10, 1e14);
        uint256 loanId0 = createLoan(_borrower, 0.5 * 1e6, _fixedRateTerm);

        uint256 _term = createTerm(1.5 * 1e6, 10);
        uint256 loanId1 = createLoan(_borrower, 0.5 * 1e6, _term);

        vm.warp(block.timestamp + 10);
        collateralmintAndApprove(_borrower, 2e18);
        coordinator.changeCollateral(loanId1, _borrower, 1e18);
        coordinator.changeCollateral(loanId0, _borrower, 1e18);
    }

    function testStopAuction() public {
        uint256 _fixedRateTerm = createTermFixed(1.5 * 1e6, 10, 1e14);
        uint256 loanId0 = createLoan(_borrower, 0.5 * 1e6, _fixedRateTerm);
        _lender.liquidate(loanId0);
        _lender.stop(loanId0 - 2);

        borrowMintAndApprove(address(_borrower), 1e18);
        vm.expectRevert(); // Auction is gone
        coordinator.bid(loanId0 - 2);

        coordinator.changeCollateral(loanId0, _borrower, -0.1e18);
    }

    function testInvalidTerms() public {
        vm.expectRevert();
        createTerm(2e7, 10);
        vm.warp(block.timestamp + 10);
    }

    function testFlashLoan() public {
        createLoan(_borrower, 0.5 * 1e6, 0);
        MockBorrower(_borrowerContract).getFlashloan(true, _collateral);
    }

    function testFailFlashLoan() public {
        _debt.mint(address(coordinator), 1001e18);
        // Flashloan reverts since callback returns false
        MockBorrower(_borrowerContract).getFlashloan(false, _collateral);
    }

    function testGetLoan() public {
        uint256 _term = createTerm(1.5 * 1e6, 10);
        uint256 _fixedTerm = createTermFixed(1.5 * 1e6, 10, 1e14);
        uint256 _loan0 = createLoan(_borrower, 0.5 * 1e6, _fixedTerm);
        uint256 _loan1 = createLoan(_borrower, 0.5 * 1e6, _term);

        ILoanCoordinator.Loan memory loan0 = coordinator.getLoan(_loan0, false);
        ILoanCoordinator.Loan memory loan1 = coordinator.getLoan(_loan1, false);
        vm.warp(block.timestamp + 1000);
        _rateCalc.setRate(1e18);
        coordinator.accrueBorrowIndex(_term);
        coordinator.accrueBorrowIndex(_fixedTerm);
        vm.warp(block.timestamp + 1000);

        ILoanCoordinator.Loan memory loan0_ = coordinator.getLoan(_loan0, true);
        ILoanCoordinator.Loan memory loan1_ = coordinator.getLoan(_loan1, true);

        assertGt(loan0_.debtAmount, loan0.debtAmount);
        assertGt(loan1_.debtAmount, loan1.debtAmount);

        // Call rate accumulator
        coordinator.accrueBorrowIndex(_term);
        coordinator.accrueBorrowIndex(_fixedTerm);

        ILoanCoordinator.Loan memory loan0__ = coordinator.getLoan(_loan0, true);
        ILoanCoordinator.Loan memory loan1__ = coordinator.getLoan(_loan1, true);
        // Should still be the same
        assertEq(loan0_.debtAmount, loan0__.debtAmount);
        assertEq(loan1_.debtAmount, loan1__.debtAmount);

        // Check the debtAmount calc is correct
        uint256 _balance = _debt.balanceOf(_borrower);
        borrowMintAndApprove(_borrower, loan0__.debtAmount);
        coordinator.changeDebt(_loan0, _borrower, type(int256).max);
        // Can't repay the same loan twice
        vm.expectRevert();
        coordinator.changeDebt(_loan0, _borrower, type(int256).max);
        assertEq(_debt.balanceOf(_borrower), _balance);

        // Repay the variable rate loan
        borrowMintAndApprove(_borrower, loan1__.debtAmount);
        coordinator.changeDebt(_loan1, _borrower, type(int256).max);
        assertEq(_debt.balanceOf(_borrower), _balance);
    }

    function testChangeCollateral() public {
        uint256 _fixedRateTerm = createTermFixed(1.5 * 1e6, 10, 1e14);
        uint256 loanId0 = createLoan(_borrower, 0.5 * 1e6, _fixedRateTerm);

        uint256 _term = createTerm(1.5 * 1e6, 10);
        uint256 loanId1 = createLoan(_borrower, 0.5 * 1e6, _term);

        vm.warp(block.timestamp + 10);
        collateralmintAndApprove(_borrower, 2e18);
        vm.expectRevert(); // can't change with 0
        coordinator.changeCollateral(loanId1, _borrower, 0);

        collateralmintAndApprove(address(_lender), 1e18);
        vm.expectRevert(); // Collateral changing address isn't the borrower
        coordinator.changeCollateral(loanId1, address(_lender), -0.1e18);

        // Adding Collateral ok - onbehalf doesn't matter
        coordinator.changeCollateral(loanId1, address(0), 0.1e18);

        collateralmintAndApprove(_borrower, 1e18);
        coordinator.changeCollateral(loanId0, _borrower, 1e18);
        assertEq(_collateral.balanceOf(_borrower), 2e18);

        coordinator.changeCollateral(loanId0, _borrower, -0.5e18);
        assertEq(_collateral.balanceOf(_borrower), 2.5e18);
    }

    function testChangeDebt() public {
        uint256 _fixedRateTerm = createTermFixed(1.5 * 1e6, 10, 1e14);
        uint256 loanId0 = createLoan(_borrower, 0.5 * 1e6, _fixedRateTerm);

        uint256 _term = createTerm(1.5 * 1e6, 10);
        uint256 loanId1 = createLoan(_borrower, 0.5 * 1e6, _term);

        vm.warp(block.timestamp + 10);
        collateralmintAndApprove(_borrower, 2e18);
        vm.expectRevert(); // can't change with 0
        coordinator.changeDebt(loanId1, _borrower, 0);

        borrowMintAndApprove(address(_lender), 1e18);
        vm.expectRevert(); // Borrowing address isn't the borrower
        coordinator.changeDebt(loanId1, address(_lender), -1e18);
        // Repaying loans is ok
        coordinator.changeDebt(loanId1, address(_lender), 0.1e18);
        coordinator.changeDebt(loanId0, address(_lender), 0.1e18);

        borrowMintAndApprove(_borrower, 2e18);
        // repay the loan
        coordinator.changeDebt(loanId0, address(_lender), 2e18);

        // Loan was already repaid
        vm.expectRevert();
        coordinator.changeDebt(loanId0, address(_lender), -0.1e18);
        // Borrow
        coordinator.changeDebt(loanId1, address(_lender), -0.1e18);

        // Trigger a liquidation, and repay
        vm.warp(block.timestamp + 10);
        // Fully Repay the loan
        _lender.liquidate(loanId1);
        vm.expectRevert(); // Repay amount should be full
        coordinator.changeDebt(loanId1, address(_lender), 1e17);

        vm.expectRevert(); // Collateral can't be adjusted while auction is running
        coordinator.changeCollateral(loanId1, address(_lender), -1e17);

        // Repay the loan
        coordinator.changeDebt(loanId1, address(_lender), type(int256).max);
    }

    /* -------------------------------------------------------------------------- */
    /*                                 Test Utils                                 */
    /* -------------------------------------------------------------------------- */
    function createLoan(address borrowAddress, uint256, uint256 terms) public returns (uint256) {
        vm.startPrank(borrowAddress);
        uint256 _borrowAmt = 1e18;
        uint256 _collateralAmt = 1e18;

        collateralmintAndApprove(borrowAddress, _collateralAmt);
        _debt.mint(address(_lender), _borrowAmt);
        return coordinator.createLoan(
            borrowAddress, address(_lender), _collateral, _debt, _collateralAmt, _borrowAmt, terms, ""
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
        ILoanCoordinator.Term memory _term = ILoanCoordinator.Term(
            uint24(bonus), // Liquidation bonus
            uint24(duration), // Auction duration
            0,
            0,
            _rateCalc
        );
        return coordinator.setTerms(_term, 0);
    }

    function createTermFixed(uint256 bonus, uint256 duration, uint256 rate) public returns (uint256) {
        ILoanCoordinator.Term memory _term = ILoanCoordinator.Term(
            uint24(bonus), // Liquidation bonus
            uint24(duration), // Auction duration
            0,
            0,
            ICoordRateCalculator(address(0))
        );
        return coordinator.setTerms(_term, rate);
    }
}
