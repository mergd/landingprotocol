// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {ERC20} from "@solmate/tokens/ERC20.sol";
import {SafeTransferLib} from "@solmate/utils/SafeTransferLib.sol";
import {ReentrancyGuard} from "@solmate/utils/ReentrancyGuard.sol";
import {Lender} from "./Lender.sol";
import {Borrower} from "./Borrower.sol";
import "prb-math/UD60x18.sol";
import "./periphery/NoDelegateCall.sol";
import "./ILoanCoordinator.sol";
import "forge-std/console2.sol";

uint256 constant SCALAR = 1e6;
// Autocompounding interest rate on continual basis

function calculateInterest(uint256 _interestRate, uint256 _debtAmount, uint256 _startTime, uint256 _endTime)
    pure
    returns (uint256 interest)
{
    UD60x18 udRT = ud(_endTime - _startTime).div(ud(365 days)).mul(ud(_interestRate + SCALAR));
    interest = unwrap(exp(udRT).mul(ud(_debtAmount)).sub(ud(_debtAmount)));
}
// function calculateInterest(uint256 _interestRate, uint256 _debtAmount, uint256 _startTime, uint256 _endTime)
//     pure
//     returns (uint256 interest)
// {
//     interest = (_interestRate * _debtAmount * _endTime - _startTime) / (365 days * SCALAR);
// }

contract LoanCoordinator is NoDelegateCall, ReentrancyGuard, ILoanCoordinator {
    using SafeTransferLib for ERC20;

    //State
    uint256 public loanCount;
    Auction[] public auctions;
    Term[] public loanTerms;
    uint256[5] public durations = [8 hours, 1 days, 2 days, 7 days, 0];
    mapping(uint256 loanId => uint256 auctionId) public loanIdToAuction;
    mapping(uint256 loanId => Loan loan) public loans;
    mapping(address borrower => uint256[] loanIds) public borrowerLoans;
    mapping(uint256 loanId => uint256 borrowerIndex) private borrowerLoanIndex;
    // Lender loans should be tracked in lender contract

    // Errors
    error Coordinator_LoanNotVerified();
    error Coordinator_LoanNotLiquidatable();
    error Coordinator_LoanNotAdjustable();
    error Coordinator_InterestRateTooHigh();
    error Coordinator_OnlyLender();
    error Coordinator_AuctionNotEnded();
    error Coordinator_LenderUpdateFailed();
    error Coordinator_AuctionEnded(uint256);
    error Coordinator_FlashloanFailed();

    constructor() {}

    // ============================================================================================
    // Functions: Lending
    // ============================================================================================

    function createLoan(
        address _lender,
        ERC20 _collateral,
        ERC20 _debt,
        uint256 _collateralAmount,
        uint256 _debtAmount,
        uint256 _interestRate,
        uint256 _duration,
        uint256 _terms
    ) external returns (uint256) {
        return createLoan(
            _lender, msg.sender, _collateral, _debt, _collateralAmount, _debtAmount, _interestRate, _duration, _terms, 0
        );
    }

    /**
     * @dev User initiates the loan
     * @param _lender Lender contract. Lender contract MUST be somewhat trusted
     * @param _borrower Borrower address
     * @param _collateral ERC20 Collateral
     * @param _debt ERC20 debt token
     * @param _collateralAmount the amount of collateral, denominated in _collateral
     * @param _debtAmount the amount of debt denominated in _debt
     * @param _interestRate the APR on the loan, scaled by SCALAR (noncompounding)
     * @param _duration the duration of the loan a selection of one of the durations array
     * @param _terms terms of the loan
     * @param _data data to be passed to the lender contract
     */
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
        uint256 _data
    ) public noDelegateCall nonReentrant returns (uint256) {
        loanCount++;
        uint256 _tokenId = loanCount;
        Loan memory newLoan = Loan(
            _tokenId,
            _borrower,
            _lender,
            Lender(_lender).callback(),
            _collateral,
            _debt,
            _collateralAmount,
            _debtAmount,
            _interestRate,
            block.timestamp,
            durations[_duration],
            _terms
        );

        loans[_tokenId] = newLoan;

        // Lender Hook to verify loan details
        if (!Lender(_lender).verifyLoan(newLoan, _data)) {
            revert Coordinator_LoanNotVerified();
        }

        _collateral.safeTransferFrom(msg.sender, address(this), _collateralAmount);

        borrowerLoans[_borrower].push(_tokenId);
        borrowerLoanIndex[_tokenId] = borrowerLoans[_borrower].length - 1;
        _debt.safeTransferFrom(_lender, address(this), _debtAmount);
        _debt.safeTransfer(msg.sender, _debtAmount);
        emit LoanCreated(_tokenId, newLoan);
        return _tokenId;
    }

    /**
     * @dev Initiate a dutch auction to liquidate the laon
     * @param _loanId the loan to liquidate
     * @return the auction id
     */
    function liquidateLoan(uint256 _loanId) external returns (uint256) {
        Loan storage loan = loans[_loanId];
        Term memory terms = loanTerms[loan.terms];

        if (loan.lender != msg.sender) revert Coordinator_OnlyLender();

        if (
            loan.duration + loan.startingTime > block.timestamp || loan.duration == type(uint256).max // Auction in liquidation
        ) revert Coordinator_LoanNotLiquidatable();

        uint256 interest = calculateInterest(loan.interestRate, loan.debtAmount, loan.startingTime, block.timestamp);
        bool skipAuction = terms.auctionLength == 0;
        uint256 totalDebt = ((loan.debtAmount + interest) * terms.liquidationBonus) / SCALAR;

        // Borrower Hook
        if (isContract(loan.borrower)) {
            loan.borrower.call(abi.encodeWithSignature("liquidationHook(Loan)", loan));
        }

        emit LoanLiquidated(_loanId);
        if (!skipAuction) {
            _startAuction(_loanId, totalDebt, terms.auctionLength);
            loan.duration = type(uint256).max; // Auction off loan
            return auctions.length - 1;
        } else {
            deleteLoan(_loanId, loan.borrower);
            loan.collateralToken.safeTransfer(msg.sender, loan.collateralAmount);
            delete loans[_loanId];
            return 0;
        }
    }

    function repayLoan(uint256 _loanId) public noDelegateCall nonReentrant {
        Loan memory loan = loans[_loanId];
        uint256 interest = calculateInterest(loan.interestRate, loan.debtAmount, loan.startingTime, block.timestamp);
        uint256 totalDebt = loan.debtAmount + interest;
        loan.debtToken.safeTransferFrom(msg.sender, loan.lender, totalDebt);

        if (loan.callback && Lender(loan.lender).loanRepaidHook(loan) != Lender.loanRepaidHook.selector) {
            revert Coordinator_LenderUpdateFailed();
        }

        deleteLoan(_loanId, loan.borrower);
        if (loan.duration == 0) delete auctions[loanIdToAuction[_loanId]];

        emit LoanRepaid(_loanId, loan.borrower, loan.lender, totalDebt);
    }

    /**
     * @dev Rebalance the interest rate
     * @param _loanId the loan to rebalance
     * @param _newRate the new rate
     */
    function rebalanceRate(uint256 _loanId, uint256 _newRate) external nonReentrant {
        Loan storage loan = loans[_loanId];
        if (loan.lender != msg.sender) revert Coordinator_OnlyLender();

        if (
            loan.duration == type(uint256).max // Loan is in liquidation
                || loan.duration + loan.startingTime > block.timestamp
        ) revert Coordinator_LoanNotAdjustable();

        // Add a check to prevent rate from being too high, or as long as it's lower than the existing rate – maximum rate is 200% APY
        if (_newRate >= SCALAR * 2 || (_newRate >= SCALAR * 2 && _newRate > loan.interestRate)) {
            revert Coordinator_InterestRateTooHigh();
        }

        uint256 interest = calculateInterest(loan.interestRate, loan.debtAmount, loan.startingTime, block.timestamp);
        loan.debtAmount = loan.debtAmount + interest; // Recalculate debt amount
        loan.startingTime = block.timestamp; // Reset starting time
        loan.interestRate = _newRate;
        // Borrower Hook
        if (isContract(loan.borrower)) {
            loan.borrower.call(abi.encodeWithSignature("interestRateUpdateHook(Loan,uint256)", loan, _newRate));
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

    /**
     * @dev Bid on an auction at the current price
     */
    function bid(uint256 _auctionId) external noDelegateCall nonReentrant {
        Auction memory auction = auctions[_auctionId];
        Loan memory loan = loans[auction.loanId];
        (uint256 bidAmount, uint256 collateralAmt) = getCurrentPrice(_auctionId);
        // Offer 100% of the debt to be repaid, but increase the amount of collateral offered
        if (collateralAmt == 0 || bidAmount == 0) {
            revert Coordinator_AuctionEnded(_auctionId);
        }

        uint256 borrowerReturn = loan.collateralAmount - collateralAmt;
        if (
            loan.callback
                && Lender(loan.lender).auctionSettledHook(loan, bidAmount, borrowerReturn)
                    != Lender.auctionSettledHook.selector
        ) revert Coordinator_LenderUpdateFailed();

        if (isContract(loan.borrower)) {
            loan.borrower.call(
                abi.encodeWithSignature("auctionSettledHook(Loan,uint256,uint256)", loan, bidAmount, borrowerReturn)
            );
        }

        // Delete the loan
        delete auctions[_auctionId];
        delete loanIdToAuction[auction.loanId];
        deleteLoan(auction.loanId, loan.borrower);

        loan.debtToken.safeTransferFrom(msg.sender, address(this), bidAmount);
        loan.collateralToken.safeTransfer(msg.sender, collateralAmt);
        loan.debtToken.safeTransfer(loan.lender, bidAmount - borrowerReturn);
        if (borrowerReturn > 0) {
            loan.debtToken.safeTransfer(loan.borrower, borrowerReturn);
        }

        emit AuctionSettled(_auctionId, msg.sender, bidAmount);
    }

    /**
     * @dev Lender can reclaim the collateral if the auction doesn't clear
     * @param _auctionId the auction to reclaim
     */
    function reclaim(uint256 _auctionId) external nonReentrant {
        Auction memory auction = auctions[_auctionId];
        if (auction.startTime + auction.duration >= block.timestamp) {
            revert Coordinator_AuctionNotEnded();
        }

        Loan memory loan = loans[auction.loanId];
        delete auctions[_auctionId];
        delete loanIdToAuction[auction.loanId];

        deleteLoan(auction.loanId, loan.borrower);
        loan.collateralToken.safeTransfer(loan.lender, loan.collateralAmount);

        emit AuctionReclaimed(_auctionId, loan.collateralAmount);
    }

    /**
     * Get current price of auction
     * @param _auctionId Id of the auction
     * @return bidAmount Amount of debt token to bid
     * @return collateral Amount of collateral token to receive
     */

    function getCurrentPrice(uint256 _auctionId) public view returns (uint256 bidAmount, uint256 collateral) {
        Auction memory auction = auctions[_auctionId];
        Loan memory loan = loans[auction.loanId];
        if (auction.loanId == 0) revert Coordinator_AuctionNotEnded();
        // todo this can revert if auction hasn't been touched
        uint256 timeElapsed = block.timestamp - auction.startTime;
        uint256 midPoint = auction.duration / 2;
        // Offer 100% of the debt to be repaid, but increase the amount of collateral offered
        if (midPoint >= timeElapsed) {
            bidAmount = auction.recoveryAmount;
            collateral = (timeElapsed * loan.collateralAmount) / midPoint;
        } else if (timeElapsed < auction.duration) {
            // Offer all the collateral, but reduce the amount of debt to be offered
            bidAmount = auction.recoveryAmount - (((timeElapsed - midPoint) * auction.recoveryAmount) / midPoint);
            collateral = loan.collateralAmount;
        } else {
            // Auction lapsed
            bidAmount = 0;
            collateral = 0;
        }
    }

    // ============================================================================================
    // Functions: Misc
    // ============================================================================================

    function getFlashLoan(address _borrower, ERC20 _token, uint256 _amount, bytes memory _data)
        external
        noDelegateCall
    {
        _token.safeTransfer(_borrower, _amount);

        if (!Borrower(_borrower).executeOperation(_token, _amount, msg.sender, _data)) {
            revert Coordinator_FlashloanFailed();
        }

        _token.safeTransferFrom(_borrower, address(this), _amount);
        emit Flashloan(_borrower, _token, _amount);
    }

    /**
     * @dev Set the terms of the loan
     * @param _terms the terms to set
     */
    function setTerms(Term memory _terms) external returns (uint256) {
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
