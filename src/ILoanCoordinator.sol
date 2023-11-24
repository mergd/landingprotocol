// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {ERC20} from "@solmate/tokens/ERC20.sol";
import {ICoordRateCalculator} from "./ICoordRateCalculator.sol";
import {IFlashloanReceiver} from "./IFlashloanReceiver.sol";

interface ILoanCoordinator {
    // 5 words
    struct Loan {
        LoanState state;
        uint48 id;
        uint24 termId;
        address borrower;
        // 1 word
        address lender;
        uint96 accruedInterest;
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
    event LoanCreated(uint256 indexed loanId, Loan loan);
    event LoanDebtAdjusted(uint256 indexed loanId, Loan loan, int256 amount, bool isFullRepayment);
    event LoanLiquidated(uint256 indexed loanId, Loan loan);
    event LoanCollateralAdjusted(uint256 indexed loanId, Loan loan, int256 amount);

    event AuctionCreated(Auction auction);
    event AuctionSettled(uint256 indexed auction, address bidder, uint256 price);
    event AuctionReclaimed(uint256 indexed loanId, uint256 amount);
    event AuctionClosed(uint256 indexed auction);

    event TermsSet(uint256 termId, Term term);

    event Flashloan(address borrower, ERC20 token, uint256 amount);

    /* -------------------------------------------------------------------------- */
    /*                                   Errors                                   */
    /* -------------------------------------------------------------------------- */

    error Coordinator_LoanNotVerified();
    error Coordinator_LoanNotLiquidatable();
    error Coordinator_OnlyLender();
    error Coordinator_OnlyBorrower();
    error Coordinator_LenderUpdateFailed();

    error Coordinator_InvalidCollateralAmount();
    error Coordinator_InvalidDebtAmount();
    error Coordinator_NeedToPayFull();
    error Coordinator_LiquidationInProgress();

    error Coordinator_AuctionNotEnded();
    error Coordinator_AuctionNotValid();
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
     * @return _tokenId The ID of the loan
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
     * @param _loanId The ID of the loan
     * @return _auctionId The ID of the auction
     * @return _interest Pending interest on the loan
     */
    function liquidateLoan(uint256 _loanId) external returns (uint256 _auctionId, uint256 _interest);

    /**
     * @dev Change the borrow amount (either repay or borrow more)
     * Can revert if the lenderHook fails
     * @param _loanId The ID of the loan
     * @param _onBehalfOf The recipient of the borrow (if the borrower is borrowing more)
     * @param _amount The amount to change the debt by (negative for borrowing more)
     */
    function changeDebt(uint256 _loanId, address _onBehalfOf, int256 _amount) external;

    /**
     * @dev Change the collateral amount (either add or remove collateral)
     * Can revert if the lenderHook fails
     * @param _loanId The ID of the loan
     * @param _onBehalfOf The recipient of the collateral (if the borrower is withdrawing collateral)
     * @param _amount The amount to change the collateral by (negative for withdrawing)
     */
    function changeCollateral(uint256 _loanId, address _onBehalfOf, int256 _amount) external;

    /**
     * @dev Accrue the borrow index for a term
     * @param _termId the term to accrue
     * @return _borrowIndex the new borrow index
     */
    function accrueBorrowIndex(uint256 _termId) external returns (uint64);

    /* -------------------------------------------------------------------------- */
    /*                                   Auction                                  */
    /* -------------------------------------------------------------------------- */

    /**
     * @dev Settle the auction based on the current price
     * @param _auctionId the auction to bid on
     * @notice Unless loan is repaid, no additional interest is accounted for in the liquidation period
     */
    function bid(uint256 _auctionId) external;

    /**
     * Get current price of auction
     * @param _auctionId The ID of the auction
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
     * @dev Stop an ongoing auction
     * @param _auctionId The ID of the auction
     *
     */
    function stopAuction(uint256 _auctionId) external;
    /* -------------------------------------------------------------------------- */
    /*                                    Misc                                    */
    /* -------------------------------------------------------------------------- */
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

    /* -------------------------------------------------------------------------- */
    /*                                    View                                    */
    /* -------------------------------------------------------------------------- */

    /**
     * Get the details about a loan
     * @param _loanId The ID of the loan
     * @param _interest Whether to include pending interest or not
     */
    function getLoan(uint256 _loanId, bool _interest) external view returns (Loan memory _loan);

    /**
     * Calculate pending interest for a loan
     * @param _loan The loan to get the accrued interest for
     */
    function getAccruedInterest(Loan memory _loan) external view returns (uint256 _accrued);

    /**
     * Get the details about a term
     * @param _termId The ID of the term
     */
    function getTerms(uint256 _termId) external view returns (Term memory _term);

    /**
     * Get auction details
     * @param _auctionId the ID of the auction
     */
    function getAuction(uint256 _auctionId) external view returns (Auction memory _auction);
}
