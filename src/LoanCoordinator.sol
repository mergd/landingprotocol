// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {ERC20} from "@solmate/tokens/ERC20.sol";
import {SafeTransferLib} from "@solmate/utils/SafeTransferLib.sol";
import {ReentrancyGuard} from "@solmate/utils/ReentrancyGuard.sol";
import {SafeCastLib} from "@solmate/utils/SafeCastLib.sol";
import {FixedPointMathLib} from "@solmate/utils/FixedPointMathLib.sol";

import {IFlashloanReceiver} from "./IFlashloanReceiver.sol";
import {Lender} from "./Lender.sol";
import "./ILoanCoordinator.sol";
import "forge-std/console2.sol";

uint256 constant SCALAR = 1e6;
uint256 constant WAD = 1e18;

/**
 * @title LoanCoordinator (v1)
 * @author mergd
 */
contract LoanCoordinator is ReentrancyGuard, ILoanCoordinator {
    using SafeTransferLib for ERC20;
    using SafeCastLib for uint256;
    using FixedPointMathLib for uint256;

    //State
    uint256 public loanCount = 1;
    Auction[] public auctions;
    Term[] public loanTerms;
    uint256 public constant MAX_INTEREST_RATE = WAD * 10; // Max interest rate is 10_000%
    mapping(uint256 loanId => uint256 auctionId) public loanIdToAuction;
    mapping(uint256 loanId => Loan loan) public loans;
    mapping(address borrower => uint256[] loanIds) public borrowerLoans;
    mapping(uint256 loanId => uint256 borrowerIndex) private borrowerLoanIndex;
    mapping(uint256 termId => uint256 rate) public termIdToFixedRate;

    // Lender loans should be tracked in lender contract

    constructor() {}

    // ============================================================================================
    // Functions: Lending
    // ============================================================================================
    /// @inheritdoc ILoanCoordinator
    function createLoan(
        address _borrower,
        address _lender,
        ERC20 _collateral,
        ERC20 _debt,
        uint256 _collateralAmount,
        uint256 _debtAmount,
        uint256 _terms,
        bytes calldata _data
    ) external returns (uint256) {
        Loan memory _loan = Loan(
            LoanState.Active,
            0,
            uint24(_terms),
            _borrower,
            _lender,
            false,
            _collateral,
            _collateralAmount.safeCastTo96(),
            _debt,
            _debtAmount.safeCastTo96(),
            0,
            0
        );
        return createLoan(_loan, _data);
    }

    /// @inheritdoc ILoanCoordinator
    function createLoan(Loan memory _loan, bytes calldata _data) public nonReentrant returns (uint256 _tokenId) {
        if (_loan.state == LoanState.Liquidating) {
            revert Coordinator_InvalidTerms();
        }

        uint64 _baseBorrowIndex = 0;
        _baseBorrowIndex = accrueBorrowIndex(_loan.termId);

        ++loanCount;
        _tokenId = loanCount;

        Loan memory _newLoan = Loan(
            _loan.state,
            uint48(_tokenId),
            _loan.termId,
            _loan.borrower,
            _loan.lender,
            Lender(_loan.lender).callback(),
            _loan.collateralToken,
            _loan.collateralAmount,
            _loan.debtToken,
            _loan.debtAmount,
            _baseBorrowIndex,
            uint40(block.timestamp)
        );

        loans[_tokenId] = _newLoan;

        borrowerLoans[_loan.borrower].push(_tokenId);
        borrowerLoanIndex[_tokenId] = borrowerLoans[_loan.borrower].length - 1;

        // Lender Hook to verify loan details
        if (Lender(_loan.lender).verifyLoan(_newLoan, _data) != Lender.verifyLoan.selector) {
            revert Coordinator_LoanNotVerified();
        }

        _loan.collateralToken.safeTransferFrom(msg.sender, address(this), _loan.collateralAmount);
        _loan.debtToken.safeTransferFrom(_loan.lender, address(this), _loan.debtAmount);
        _loan.debtToken.safeTransfer(_loan.borrower, _loan.debtAmount);

        emit LoanCreated(_tokenId, _newLoan);
    }

    ///@inheritdoc ILoanCoordinator
    function liquidateLoan(uint256 _loanId) external returns (uint256 _auctionId) {
        Loan memory _loan = loans[_loanId];
        Term memory _terms = loanTerms[_loan.termId];
        console2.log("liquidateLoan");
        if (_loan.lender != msg.sender) revert Coordinator_OnlyLender();

        if (_loan.state == LoanState.Liquidating) {
            revert Coordinator_LoanNotLiquidatable();
        }

        console2.log("liquidateLoan");

        // Update the loan if there is interest to be accrued
        uint64 _baseBorrowIndex = accrueBorrowIndex(_loan.termId);
        uint256 _interest = (block.timestamp - _loan.lastUpdateTime) * (_baseBorrowIndex - _loan.userBorrowIndex);
        console2.log("liquidateLoan1");
        loanTerms[_loan.termId].lastUpdateTime = uint40(block.timestamp);
        loanTerms[_loan.termId].baseBorrowIndex = _baseBorrowIndex;
        console2.log("liquidateLoan2");

        uint96 totalDebt = uint96(((_loan.debtAmount + _interest) * _terms.liquidationBonus) / SCALAR);
        console2.log("liquidateLoan3");

        // Skip auction if auction period is set to 0
        if (!(_terms.auctionLength == 0)) {
            console2.log("auction called");
            _startAuction(uint48(_loanId), totalDebt, _terms.auctionLength);

            loans[_loanId].state = LoanState.Liquidating;
            _auctionId = auctions.length - 1;
            loans[_loanId].state = LoanState.Liquidating;
        } else {
            console2.log("auction not called");
            _deleteLoan(_loanId, _loan.borrower);
            console2.log("loan deleted");
            _loan.collateralToken.safeTransfer(msg.sender, _loan.collateralAmount);
            _auctionId = 0;
        }

        emit LoanLiquidated(_loanId, _loan);
    }

    /// @inheritdoc ILoanCoordinator
    function changeDebt(uint256 _loanId, address _onBehalfOf, int256 _amount) external nonReentrant {
        Loan storage _loan = loans[_loanId];

        if (_loan.state == LoanState.Inactive) revert Coordinator_InvalidLoan();

        if (_amount == 0) revert Coordinator_InvalidDebtAmount();
        bool _isFullRepayment = false;
        uint256 _interest = getAccruedInterest(_loan);
        uint256 _totalDebt = _loan.debtAmount + _interest;

        if (_amount < 0) {
            if (msg.sender != _loan.borrower) revert Coordinator_OnlyBorrower();
            // Borrow more
            // Accrue interest
            uint256 __amount = uint256(-_amount);

            _loan.userBorrowIndex = uint64(accrueBorrowIndex(_loan.termId));
            _loan.lastUpdateTime = uint40(block.timestamp);
            _loan.debtAmount += __amount.safeCastTo96();

            _loan.debtToken.safeTransferFrom(_loan.lender, _onBehalfOf, __amount);
        } else {
            // Repay debt
            uint256 _repayAmount = min(uint256(_amount), _totalDebt);
            _isFullRepayment = _totalDebt == _repayAmount;
            if (_isFullRepayment && _loan.state == LoanState.Liquidating) {
                // Delete corresponding auction if the _loan is repaid
                delete auctions[loanIdToAuction[_loanId]];
            } else {
                // Accrue interest
                _loan.userBorrowIndex = uint64(accrueBorrowIndex(_loan.termId));
                _loan.lastUpdateTime = uint40(block.timestamp);
                _loan.debtAmount = (_totalDebt - _repayAmount).safeCastTo96();
            }

            _loan.debtToken.safeTransferFrom(msg.sender, _loan.lender, _repayAmount);
        }

        if (
            _loan.callback
                && Lender(_loan.lender).debtChangedHook(_loan, _amount, _isFullRepayment, _interest)
                    != Lender.debtChangedHook.selector
        ) {
            revert Coordinator_LenderUpdateFailed();
        }

        // Delete loan if fully repaid – done after to ensure Lender can still access loan
        if (_isFullRepayment) {
            console2.log("delete loan");
            _deleteLoan(_loanId, _loan.borrower);
        }

        emit LoanDebtAdjusted(_loanId, _loan, _amount, _isFullRepayment);
    }

    /// @inheritdoc ILoanCoordinator
    function changeCollateral(uint256 _loanId, address _onBehalfOf, int256 _amount) external nonReentrant {
        Loan storage _loan = loans[_loanId];

        if (_loan.state == LoanState.Inactive) revert Coordinator_InvalidLoan();

        // Accrue interest
        uint256 _interest = getAccruedInterest(_loan);
        _loan.debtAmount += uint96(_interest);
        _loan.userBorrowIndex = uint64(accrueBorrowIndex(_loan.termId));
        _loan.lastUpdateTime = uint40(block.timestamp);

        if (_amount == 0) {
            revert Coordinator_InvalidCollateralAmount();
        } else if (_amount < 0) {
            if (msg.sender != _loan.borrower) revert Coordinator_OnlyBorrower();
            // Withdraw Collateral
            // Subtract from collateralAmount
            _loan.collateralAmount -= uint256(-_amount).safeCastTo96();
            _loan.collateralToken.safeTransfer(_onBehalfOf, uint256(-_amount));
        } else {
            // Deposit more Collateral
            // Add to collateralAmount
            _loan.collateralAmount += uint256(_amount).safeCastTo96();
            _loan.collateralToken.safeTransferFrom(msg.sender, address(this), uint256(_amount));
        }

        if (
            _loan.callback
                && Lender(_loan.lender).collateralChangedHook(_loan, _amount, _interest)
                    != Lender.collateralChangedHook.selector
        ) {
            revert Coordinator_LenderUpdateFailed();
        }

        emit LoanCollateralAdjusted(_loanId, _loan, _amount);
    }

    /// @inheritdoc ILoanCoordinator
    function accrueBorrowIndex(uint256 _termId) public returns (uint64) {
        Term storage _term = loanTerms[_termId];
        if (_term.lastUpdateTime != block.timestamp) {
            uint256 _timeElapsed = block.timestamp - _term.lastUpdateTime;
            uint256 _rate;
            if (_term.rateCalculator != ICoordRateCalculator(address(0))) {
                _rate = _term.rateCalculator.getNewRate(_termId, _timeElapsed);
            } else {
                _rate = termIdToFixedRate[_termId];
            }

            console2.log("accrueBorrowIndex", (_timeElapsed * _rate) / WAD);
            _term.baseBorrowIndex += (_timeElapsed.mulWadUp(_rate)).safeCastTo64();
            _term.lastUpdateTime = uint40(block.timestamp);
        }

        return _term.baseBorrowIndex;
    }

    // ============================================================================================
    // Functions: Auctions
    // ============================================================================================

    function _startAuction(uint48 _loanId, uint96 _debtAmount, uint24 _auctionLength) internal {
        Auction memory newAuction = Auction(_loanId, _debtAmount, _auctionLength, uint40(block.timestamp));
        auctions.push(newAuction);
        emit AuctionCreated(newAuction);
    }

    ///@inheritdoc ILoanCoordinator
    function bid(uint256 _auctionId) external nonReentrant {
        Auction memory _auction = auctions[_auctionId];
        Loan memory _loan = loans[_auction.loanId];
        (uint256 _bidAmount, uint256 _collateralAmt) = getCurrentPrice(_auctionId);
        // Offer 100% of the debt to be repaid, but increase the amount of collateral offered
        if (_collateralAmt == 0 || _bidAmount == 0) {
            revert Coordinator_AuctionEnded(_auctionId);
        }

        uint256 _borrowerReturn = _loan.collateralAmount - _collateralAmt;

        // Delete the loan
        delete auctions[_auctionId];
        delete loanIdToAuction[_auction.loanId];
        _deleteLoan(_auction.loanId, _loan.borrower);

        _loan.debtToken.safeTransferFrom(msg.sender, address(this), _bidAmount);
        _loan.collateralToken.safeTransfer(msg.sender, _collateralAmt);
        _loan.debtToken.safeTransfer(_loan.lender, _bidAmount);

        // Transfer auction surplus to borrower
        if (_borrowerReturn > 0) {
            _loan.collateralToken.safeTransfer(_loan.borrower, _borrowerReturn);
        }

        if (
            _loan.callback
                && Lender(_loan.lender).auctionSettledHook(_loan, _bidAmount, _borrowerReturn)
                    != Lender.auctionSettledHook.selector
        ) revert Coordinator_LenderUpdateFailed();

        accrueBorrowIndex(_loan.termId);
        emit AuctionSettled(_auctionId, msg.sender, _bidAmount);
    }

    /// @inheritdoc ILoanCoordinator
    function getCurrentPrice(uint256 _auctionId) public view returns (uint256 _bidAmount, uint256 _collateral) {
        Auction memory _auction = auctions[_auctionId];
        Loan memory _loan = loans[_auction.loanId];
        if (_auction.loanId == 0) revert Coordinator_AuctionNotEnded();

        uint256 _timeElapsed = block.timestamp - _auction.startTime;
        uint256 _midPoint = _auction.duration / 2;
        // Offer 100% of the debt to be repaid, but increase the amount of _collateral offered
        if (_midPoint >= _timeElapsed) {
            _bidAmount = _auction.recoveryAmount;
            _collateral = _timeElapsed.mulDivDown(_loan.collateralAmount, _midPoint);
        } else if (_timeElapsed < _auction.duration) {
            // Offer all the collateral, but reduce the amount of debt to be offered
            _bidAmount =
                _auction.recoveryAmount - (_timeElapsed - _midPoint).mulDivDown(_auction.recoveryAmount, _midPoint);

            _collateral = _loan.collateralAmount;
        } else {
            // Auction lapsed
            _bidAmount = 0;
            _collateral = 0;
        }
    }

    ///@inheritdoc ILoanCoordinator
    function reclaim(uint256 _auctionId) external nonReentrant {
        Auction memory _auction = auctions[_auctionId];
        Loan memory loan = loans[_auction.loanId];
        if (_auction.startTime + _auction.duration > block.timestamp) {
            revert Coordinator_AuctionNotEnded();
        }

        delete auctions[_auctionId];
        delete loanIdToAuction[_auction.loanId];
        _deleteLoan(_auction.loanId, loan.borrower);

        loan.collateralToken.safeTransfer(loan.lender, loan.collateralAmount);

        emit AuctionReclaimed(_auctionId, loan.collateralAmount);
    }

    ///@inheritdoc ILoanCoordinator
    function stopAuction(uint256 _auctionId) external nonReentrant {
        Auction memory _auction = auctions[_auctionId];
        Loan memory _loan = loans[_auction.loanId];
        if (_loan.lender != msg.sender) revert Coordinator_OnlyLender();

        delete auctions[_auctionId];
        delete loanIdToAuction[_auction.loanId];
        _deleteLoan(_auction.loanId, _loan.borrower);

        emit AuctionClosed(_auctionId);
    }

    // ============================================================================================
    // Functions: Misc
    // ============================================================================================
    /// @inheritdoc ILoanCoordinator
    function getFlashLoan(IFlashloanReceiver _receiver, ERC20 _token, uint256 _amount, bytes memory _data) external {
        _token.safeTransfer(address(_receiver), _amount);

        if (!_receiver.executeOperation(_token, _amount, msg.sender, _data)) {
            revert Coordinator_FlashloanFailed();
        }

        _token.safeTransferFrom(address(_receiver), address(this), _amount);
        emit Flashloan(address(_receiver), _token, _amount);
    }

    ///@inheritdoc ILoanCoordinator
    function setTerms(Term memory _term, uint256 _rate) external returns (uint256 _termId) {
        if (_term.liquidationBonus > SCALAR * 2 || _term.liquidationBonus < SCALAR) revert Coordinator_InvalidTerms();
        if (_term.auctionLength > 30 days) revert Coordinator_InvalidTerms();

        _termId = loanTerms.length;

        // Set fixed rate if a Rate Calculator isn't set for this term
        if (_term.rateCalculator == ICoordRateCalculator(address(0))) {
            termIdToFixedRate[_termId] = _rate;
        }

        loanTerms.push(_term);
        accrueBorrowIndex(_termId);
        emit TermsSet(_termId, _term);
    }

    function _deleteLoan(uint256 _loanId, address _borrower) internal {
        loans[_loanId].state = LoanState.Inactive;
        // Delete _loanId from borrowerLoans and lenderLoans
        uint256[] storage borrowerLoanList = borrowerLoans[_borrower];
        borrowerLoanList[borrowerLoanIndex[_loanId]] = borrowerLoanList[borrowerLoanList.length - 1];
    }

    function min(uint256 _a, uint256 _b) internal pure returns (uint256) {
        return _a < _b ? _a : _b;
    }

    // ============================================================================================
    // Functions: View
    // ============================================================================================
    /// @inheritdoc ILoanCoordinator
    function getLoan(uint256 _loanId, bool _interest) external view returns (Loan memory _loan) {
        _loan = loans[_loanId];

        // Account for pending interest for this loan
        if (_interest) _loan.debtAmount += uint96(getAccruedInterest(_loan));

        // Loan doesn't exist
        if (_loan.state == LoanState.Inactive) revert Coordinator_InvalidLoan();
    }

    /// @inheritdoc ILoanCoordinator
    function getAccruedInterest(Loan memory _loan) public view returns (uint256 _accrued) {
        Term memory _term = loanTerms[_loan.termId];
        uint256 _timeElapsed = block.timestamp - _term.lastUpdateTime;

        if (block.timestamp - _loan.lastUpdateTime == 0) return 0;

        // Account for most recent interest
        uint256 _rate;
        if (_timeElapsed == 0) {
            _rate = _term.baseBorrowIndex;
        } else if (_term.rateCalculator != ICoordRateCalculator(address(0))) {
            _rate = _term.rateCalculator.getNewRate(_loan.termId, _timeElapsed);
        } else {
            _rate = termIdToFixedRate[_loan.termId];
        }

        uint256 _newIndex = _timeElapsed.mulWadUp(_rate) + _term.baseBorrowIndex;

        _accrued = (block.timestamp - _loan.lastUpdateTime) * (_newIndex - _loan.userBorrowIndex);
    }

    ///@inheritdoc ILoanCoordinator
    function getTerms(uint256 _termId) external view returns (Term memory _term) {
        _term = loanTerms[_termId];
    }

    /// @inheritdoc ILoanCoordinator
    function getAuction(uint256 _auctionId) external view returns (Auction memory _auction) {
        _auction = auctions[_auctionId];
    }
}
