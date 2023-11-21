// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {ERC20} from "@solmate/tokens/ERC20.sol";
import {ICoordRateCalculator} from "src/ICoordRateCalculator.sol";
import {IFlashloanReceiver} from "src/IFlashloanReceiver.sol";

interface ILoanCoordinator {
    // 5 words
    struct Loan {
        LoanState state;
        uint48 id;
        uint24 termId;
        address borrower;
        // 1 word
        address lender;
        bool callback;
        // 2 words
        ERC20 collateralToken;
        uint96 collateralAmount;
        // 3 words
        ERC20 debtToken;
        uint96 debtAmount;
        // 4 words
        uint64 userBorrowIndex;
        uint40 lastUpdateTime;
    }

    /// @dev Rate Calculator is immutable – can move to a new term though
    // 1 word
    struct Term {
        uint24 liquidationBonus;
        uint24 auctionLength;
        uint40 lastUpdateTime;
        uint64 baseBorrowIndex;
        ICoordRateCalculator rateCalculator;
    }

    // 1 word
    struct Auction {
        uint48 loanId;
        uint96 recoveryAmount;
        uint24 duration;
        uint40 startTime;
    }

    enum LoanState {
        Inactive,
        Active,
        Liquidating
    }

    /* -------------------------------------------------------------------------- */
    /*                                    State                                   */
    /* -------------------------------------------------------------------------- */
    function loanCount() external view returns (uint256);

    function loanIdToAuction(uint256 loanId) external view returns (uint256);

    function borrowerLoans(address borrower, uint256 index) external view returns (uint256);

    /* -------------------------------------------------------------------------- */
    /*                                   Events                                   */
    /* -------------------------------------------------------------------------- */
    event LoanRepaid(uint256 indexed id, address indexed borrower, address indexed lender, uint256 amount);
    event LoanCreated(uint256 indexed id, Loan loan);
    event AuctionCreated(Auction auction);
    event AuctionSettled(uint256 indexed auction, address bidder, uint256 price);
    event RateRebalanced(uint256 indexed loanId, uint256 newRate);
    event AuctionReclaimed(uint256 indexed loanId, uint256 amount);
    event LoanLiquidated(uint256 indexed loanId);
    event TermsSet(uint256 termId, Term term);
    event Flashloan(address borrower, ERC20 token, uint256 amount);
    event BorrowerNotified(uint256 loanId);

    /* -------------------------------------------------------------------------- */
    /*                                   Errors                                   */
    /* -------------------------------------------------------------------------- */

    error Coordinator_InvalidDuration();
    error Coordinator_LoanNotVerified();
    error Coordinator_LoanNotLiquidatable();
    error Coordinator_LoanNotAdjustable();
    error Coordinator_InterestRateTooHigh();
    error Coordinator_OnlyLender();
    error Coordinator_AuctionNotEnded();
    error Coordinator_LenderUpdateFailed();
    error Coordinator_AuctionEnded(uint256);
    error Coordinator_FlashloanFailed();
    error Coordinator_InvalidTerms();
    error Coordinator_InvalidLoan();

    /* -------------------------------------------------------------------------- */
    /*                             Contract Functions                             */
    /* -------------------------------------------------------------------------- */
    /**
     * @dev User initiates the loan
     * @param _lender Lender contract. Lender contract MUST be somewhat trusted
     * @param _borrower Borrower address
     * @param _collateral ERC20 Collateral
     * @param _debt ERC20 debt token
     * @param _collateralAmount the amount of collateral, denominated in _collateral
     * @param _debtAmount the amount of debt denominated in _debt
     * @param _terms terms of the loan
     * @param _data data to be passed to the lender contract
     * @return _tokenId the loan id
     */
    function createLoan(
        address _lender,
        address _borrower,
        ERC20 _collateral,
        ERC20 _debt,
        uint256 _collateralAmount,
        uint256 _debtAmount,
        uint256 _terms,
        bytes calldata _data
    ) external returns (uint256);
    /**
     * Create a loan
     * @param _loan Loan struct
     * @param _data Additional callback data
     */
    function createLoan(Loan memory _loan, bytes calldata _data) external returns (uint256);
    /**
     * @dev Initiate a dutch auction to liquidate the loan
     * @param _loanId the loan to liquidate
     * @return _auctionId auction id
     */
    function liquidateLoan(uint256 _loanId) external returns (uint256);
    /**
     * Repay the loan
     * @param _loanId LoanId to repay
     * @param _from Address to repay from
     */
    function repayLoan(uint256 _loanId, address _from) external;

    /**
     * @dev Accrue the borrow index for a term
     * @param _termId the term to accrue
     * @return _borrowIndex the new borrow index
     */
    function accrueBorrowIndex(uint256 _termId) external returns (uint64);

    /**
     * @dev Settle the auction based on the current price
     * @param _auctionId the auction to bid on
     * @notice Unless loan is repaid, no additional interest is accounted for in the liquidation period
     */
    function bid(uint256 _auctionId) external;
    /**
     * Get current price of auction
     * @param _auctionId Id of the auction
     * @return _bidAmount Amount of debt token to bid
     * @return _collateral Amount of collateral token to receive
     */
    function getCurrentPrice(uint256 _auctionId) external view returns (uint256 _bidAmount, uint256 _collateral);
    /**
     * @dev Lender can reclaim the collateral if the auction doesn't clear
     * @param _auctionId the auction to reclaim
     */
    function reclaim(uint256 _auctionId) external;

    /**
     * @dev Set the terms of the loan
     * @param _terms the terms to set
     * @param _rate If the RateCalc is set to 0, the rate will be set to this
     */
    function setTerms(Term memory _terms, uint256 _rate) external returns (uint256);

    /**
     * Get a flashloan
     * @param _receiver Callback address
     * @param _token Token to borrow
     * @param _amount Amount
     * @param _data Data to pass in callback
     */
    function getFlashLoan(IFlashloanReceiver _receiver, ERC20 _token, uint256 _amount, bytes memory _data) external;

    function getLoan(uint256 _loanId, bool _interest) external view returns (Loan memory loan);

    function getAuction(uint256 _auctionId) external view returns (Auction memory auction);
}
