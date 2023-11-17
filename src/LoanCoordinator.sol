// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {ERC20} from "@solmate/tokens/ERC20.sol";
import {SafeTransferLib} from "@solmate/utils/SafeTransferLib.sol";
import {ReentrancyGuard} from "@solmate/utils/ReentrancyGuard.sol";
import {Lender} from "./Lender.sol";
import {Borrower} from "./Borrower.sol";
import "prb-math/UD60x18.sol";
import "./ILoanCoordinator.sol";
import "forge-std/Console2.sol";

uint256 constant SCALAR = 1e6;
uint256 constant WAD = 1e18;
/**
 * @dev Helper function to calculate interest – uses continually compound interest formula
 */

function calculateInterest(uint256 _interestRate, uint256 _debtAmount, uint256 _startTime, uint256 _endTime)
    pure
    returns (uint256 interest)
{
    UD60x18 udRT = ud(_endTime - _startTime).div(ud(365 days)).mul(ud(_interestRate + WAD));
    interest = unwrap(exp(udRT).mul(ud(_debtAmount)).sub(ud(_debtAmount)));
}

/**
 * @title LoanCoordinator
 * @author mergd
 */
contract LoanCoordinator is ReentrancyGuard, ILoanCoordinator {
    using SafeTransferLib for ERC20;

    //State
    uint256 public loanCount;
    Auction[] public auctions;
    Term[] public loanTerms;
    uint256[5] public durations = [0, 8 hours, 1 days, 2 days, 7 days];
    mapping(uint256 loanId => uint256 auctionId) public loanIdToAuction;
    mapping(uint256 loanId => Loan loan) public loans;
    mapping(address borrower => uint256[] loanIds) public borrowerLoans;
    mapping(uint256 loanId => uint256 borrowerIndex) private borrowerLoanIndex;
    // Lender loans should be tracked in lender contract

    constructor() {
        // Create initial term
        Term memory _term = Term(0, 0);
        loanTerms.push(_term);
        emit TermsSet(0, _term);
    }

    // ============================================================================================
    // Functions: Lending
    // ============================================================================================
    /// @inheritdoc ILoanCoordinator
    function createLoan(
        address _lender,
        address _borrower,
        ERC20 _collateral,
        ERC20 _debt,
        uint256 _collateralAmount,
        uint256 _debtAmount,
        uint256 _interestRate,
        uint256 _duration,
        uint256 _terms,
        bytes calldata _data
    ) external returns (uint256) {
        Loan memory _loan = Loan(
            0,
            _borrower,
            _lender,
            false,
            _collateral,
            _debt,
            _collateralAmount,
            _debtAmount,
            _interestRate,
            0,
            durations[_duration],
            _terms
        );
        return createLoan(_loan, _data);
    }

    /// @inheritdoc ILoanCoordinator
    function createLoan(Loan memory _loan, bytes calldata _data) public nonReentrant returns (uint256 _tokenId) {
        if (_loan.duration == type(uint256).max) revert Coordinator_InvalidDuration();
        loanCount++;
        _tokenId = loanCount;
        Loan memory _newLoan = Loan(
            _tokenId,
            _loan.borrower,
            _loan.lender,
            Lender(_loan.lender).callback(),
            _loan.collateralToken,
            _loan.debtToken,
            _loan.collateralAmount,
            _loan.debtAmount,
            _loan.interestRate,
            block.timestamp,
            _loan.duration,
            _loan.terms
        );

        loans[_tokenId] = _newLoan;

        // Lender Hook to verify loan details
        if (Lender(_loan.lender).verifyLoan(_newLoan, _data) != Lender.verifyLoan.selector) {
            revert Coordinator_LoanNotVerified();
        }

        _loan.collateralToken.safeTransferFrom(msg.sender, address(this), _loan.collateralAmount);

        borrowerLoans[_loan.borrower].push(_tokenId);
        borrowerLoanIndex[_tokenId] = borrowerLoans[_loan.borrower].length - 1;

        _loan.debtToken.safeTransferFrom(_loan.lender, address(this), _loan.debtAmount);
        _loan.debtToken.safeTransfer(msg.sender, _loan.debtAmount);

        emit LoanCreated(_tokenId, _newLoan);
    }

    ///@inheritdoc ILoanCoordinator
    function liquidateLoan(uint256 _loanId) external returns (uint256 _auctionId) {
        Loan storage _loan = loans[_loanId];
        Term memory _terms = loanTerms[_loan.terms];

        if (_loan.lender != msg.sender) revert Coordinator_OnlyLender();

        if (
            _loan.duration + _loan.startingTime > block.timestamp || _loan.duration == type(uint256).max // Auction in liquidation
        ) revert Coordinator_LoanNotLiquidatable();

        uint256 interest = calculateInterest(_loan.interestRate, _loan.debtAmount, _loan.startingTime, block.timestamp);
        uint256 totalDebt = ((_loan.debtAmount + interest) * _terms.liquidationBonus) / SCALAR;

        // Borrower Hook
        if (isContract(_loan.borrower)) {
            (bool _success,) = _loan.borrower.call(abi.encodeWithSignature("liquidationHook(Loan)", _loan));
            if (_success) emit BorrowerNotified(_loanId);
        }

        // Skip auction if auction period is set to 0
        if (!(_terms.auctionLength == 0)) {
            _startAuction(_loanId, totalDebt, _terms.auctionLength);
            _loan.duration = type(uint256).max; // Auction off _loan
            _auctionId = auctions.length - 1;
        } else {
            deleteLoan(_loanId, _loan.borrower);
            _loan.collateralToken.safeTransfer(msg.sender, _loan.collateralAmount);
            delete loans[_loanId];
            _auctionId = 0;
        }

        emit LoanLiquidated(_loanId);
    }

    /// @inheritdoc ILoanCoordinator
    function repayLoan(uint256 _loanId) public nonReentrant {
        Loan memory loan = loans[_loanId];
        uint256 interest = calculateInterest(loan.interestRate, loan.debtAmount, loan.startingTime, block.timestamp);
        uint256 totalDebt = loan.debtAmount + interest;
        loan.debtToken.safeTransferFrom(msg.sender, loan.lender, totalDebt);

        if (loan.callback && Lender(loan.lender).loanRepaidHook(loan) != Lender.loanRepaidHook.selector) {
            revert Coordinator_LenderUpdateFailed();
        }

        deleteLoan(_loanId, loan.borrower);
        // Delete corresponding liquidation if the loan is repaid
        if (loan.duration == type(uint256).max) delete auctions[loanIdToAuction[_loanId]];

        emit LoanRepaid(_loanId, loan.borrower, loan.lender, totalDebt);
    }

    /// @inheritdoc ILoanCoordinator
    function rebalanceRate(uint256 _loanId, uint256 _newRate) external nonReentrant returns (uint256 _interest) {
        Loan storage _loan = loans[_loanId];
        if (_loan.lender != msg.sender) revert Coordinator_OnlyLender();

        if (
            _loan.duration == type(uint256).max // Loan is in liquidation
                || _loan.duration + _loan.startingTime > block.timestamp
        ) revert Coordinator_LoanNotAdjustable();

        // Add a check to prevent rate from being too high, or as long as it's lower than the existing rate – maximum rate is 1000% APY
        if (_newRate >= WAD * 10 || (_newRate >= WAD * 10 && _newRate > _loan.interestRate)) {
            revert Coordinator_InterestRateTooHigh();
        }

        // Calculate the accrued interest
        _interest = calculateInterest(_loan.interestRate, _loan.debtAmount, _loan.startingTime, block.timestamp);
        _loan.debtAmount = _loan.debtAmount + _interest; // Recalculate debt amount
        _loan.startingTime = block.timestamp; // Reset starting time
        _loan.interestRate = _newRate;

        // Borrower Hook
        if (isContract(_loan.borrower)) {
            (bool _success,) =
                _loan.borrower.call(abi.encodeWithSignature("interestRateUpdateHook(Loan,uint256)", _loan, _newRate));
            if (_success) emit BorrowerNotified(_loanId);
        }

        emit RateRebalanced(_loanId, _newRate);
    }

    // ============================================================================================
    // Functions: Auctions
    // ============================================================================================

    function _startAuction(uint256 _loanId, uint256 _debtAmount, uint256 _auctionLength) internal {
        Auction memory newAuction = Auction(_loanId, _debtAmount, _auctionLength, block.timestamp);
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
        if (
            _loan.callback
                && Lender(_loan.lender).auctionSettledHook(_loan, _bidAmount, _borrowerReturn)
                    != Lender.auctionSettledHook.selector
        ) revert Coordinator_LenderUpdateFailed();

        if (isContract(_loan.borrower)) {
            (bool _success,) = _loan.borrower.call(
                abi.encodeWithSignature("auctionSettledHook(Loan,uint256,uint256)", _loan, _bidAmount, _borrowerReturn)
            );
            if (_success) emit BorrowerNotified(_auction.loanId);
        }

        // Delete the loan
        delete auctions[_auctionId];
        delete loanIdToAuction[_auction.loanId];
        deleteLoan(_auction.loanId, _loan.borrower);

        _loan.debtToken.safeTransferFrom(msg.sender, address(this), _bidAmount);
        _loan.collateralToken.safeTransfer(msg.sender, _collateralAmt);
        _loan.debtToken.safeTransfer(_loan.lender, _bidAmount);
        if (_borrowerReturn > 0) {
            _loan.collateralToken.safeTransfer(_loan.borrower, _borrowerReturn);
        }

        emit AuctionSettled(_auctionId, msg.sender, _bidAmount);
    }

    /// @inheritdoc ILoanCoordinator
    function getCurrentPrice(uint256 _auctionId) public view returns (uint256 _bidAmount, uint256 _collateral) {
        Auction memory _auction = auctions[_auctionId];
        Loan memory _loan = loans[_auction.loanId];
        if (_auction.loanId == 0) revert Coordinator_AuctionNotEnded();
        // todo this can revert if _auction hasn't been touched
        uint256 _timeElapsed = block.timestamp - _auction.startTime;
        uint256 _midPoint = _auction.duration / 2;
        // Offer 100% of the debt to be repaid, but increase the amount of _collateral offered
        if (_midPoint >= _timeElapsed) {
            _bidAmount = _auction.recoveryAmount;
            _collateral = (_timeElapsed * _loan.collateralAmount) / _midPoint;
        } else if (_timeElapsed < _auction.duration) {
            // Offer all the _ollateral, but reduce the amount of debt to be offered
            _bidAmount = _auction.recoveryAmount - (((_timeElapsed - _midPoint) * _auction.recoveryAmount) / _midPoint);
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
        if (_auction.startTime + _auction.duration > block.timestamp) {
            revert Coordinator_AuctionNotEnded();
        }

        Loan memory loan = loans[_auction.loanId];
        delete auctions[_auctionId];
        delete loanIdToAuction[_auction.loanId];

        deleteLoan(_auction.loanId, loan.borrower);
        loan.collateralToken.safeTransfer(loan.lender, loan.collateralAmount);

        emit AuctionReclaimed(_auctionId, loan.collateralAmount);
    }

    // ============================================================================================
    // Functions: Misc
    // ============================================================================================
    /// @inheritdoc ILoanCoordinator
    function getFlashLoan(address _borrower, ERC20 _token, uint256 _amount, bytes memory _data) external {
        _token.safeTransfer(_borrower, _amount);

        if (!Borrower(_borrower).executeOperation(_token, _amount, msg.sender, _data)) {
            revert Coordinator_FlashloanFailed();
        }

        _token.safeTransferFrom(_borrower, address(this), _amount);
        emit Flashloan(_borrower, _token, _amount);
    }

    ///@inheritdoc ILoanCoordinator
    function setTerms(Term memory _terms) external returns (uint256) {
        // Check that liquidation bonus is within bounds
        if (_terms.liquidationBonus > SCALAR * 2 || _terms.liquidationBonus < SCALAR) revert Coordinator_InvalidTerms();
        // Check that auction length is within bounds
        if (_terms.auctionLength > 30 days || _terms.auctionLength == 0) revert Coordinator_InvalidTerms();

        loanTerms.push(_terms);
        emit TermsSet(loanTerms.length - 1, _terms);
        return loanTerms.length - 1;
    }

    function deleteLoan(uint256 _loanId, address _borrower) internal {
        // Delete _loanId from borrowerLoans and lenderLoans
        uint256[] storage borrowerLoanList = borrowerLoans[_borrower];
        borrowerLoanList[borrowerLoanIndex[_loanId]] = borrowerLoanList[borrowerLoanList.length - 1];
    }

    // ============================================================================================
    // Functions: View
    // ============================================================================================

    function getLoan(uint256 _loanId, bool _interest) external view returns (Loan memory loan) {
        loan = loans[_loanId];
        // Account for pending interest for this loan
        if (_interest) {
            loan.debtAmount += calculateInterest(loan.interestRate, loan.debtAmount, loan.startingTime, block.timestamp);
        }
        if (loan.borrower == address(0)) revert Coordinator_LoanNotVerified();
    }

    function viewBorrowerLoans(address _borrower) external view returns (uint256[] memory loanList) {
        loanList = borrowerLoans[_borrower];
    }

    function getAuction(uint256 _auctionId) external view returns (Auction memory auction) {
        auction = auctions[_auctionId];
    }

    function isContract(address _addr) private view returns (bool) {
        uint256 size;
        assembly {
            size := extcodesize(_addr)
        }
        return size > 0;
    }
}
