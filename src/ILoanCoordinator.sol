// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {ERC20} from "@solmate/tokens/ERC20.sol";

interface ILoanCoordinator {
    struct Loan {
        uint256 id;
        address borrower;
        address lender;
        bool callback;
        ERC20 collateralToken;
        ERC20 debtToken;
        uint256 collateralAmount;
        uint256 debtAmount;
        uint256 interestRate;
        uint256 startingTime;
        uint256 duration;
        uint256 terms;
    }

    struct Term {
        uint256 liquidationBonus;
        uint256 auctionLength;
    }

    struct Auction {
        uint256 loanId;
        uint256 recoveryAmount;
        uint256 duration;
        uint256 startTime;
    }

    /**
     * STATE
     */
    function loanCount() external view returns (uint256);

    function durations(uint256 index) external view returns (uint256);

    function loanIdToAuction(uint256 loanId) external view returns (uint256);

    function borrowerLoans(address borrower, uint256 index) external view returns (uint256);

    /**
     * EVENTS
     */
    event LoanRepaid(uint256 indexed id, address indexed borrower, address indexed lender, uint256 amount);
    event LoanCreated(uint256 indexed id, Loan loan);
    event AuctionCreated(Auction auction);
    event AuctionSettled(uint256 indexed auction, address bidder, uint256 price);
    event RateRebalanced(uint256 indexed loanId, uint256 newRate);
    event AuctionReclaimed(uint256 indexed loanId, uint256 amount);
    event LoanLiquidated(uint256 indexed loanId);
    event TermsSet(uint256 termId, Term term);
    event Flashloan(address borrower, ERC20 token, uint256 amount);

    /**
     * CONTRACT FUNCTIONS
     */
    function createLoan(
        address _lender,
        ERC20 _collateral,
        ERC20 _debt,
        uint256 _collateralAmount,
        uint256 _debtAmount,
        uint256 _interestRate,
        uint256 _duration,
        uint256 _terms
    ) external returns (uint256);

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
        bytes32 _data
    ) external returns (uint256);

    function liquidateLoan(uint256 _loanId) external returns (uint256);

    function repayLoan(uint256 _loanId) external;

    function rebalanceRate(uint256 _loanId, uint256 _newRate) external;

    function bid(uint256 _auctionId) external;

    function reclaim(uint256 _auctionId) external;

    function getCurrentPrice(uint256 _auctionId) external view returns (uint256 bidAmount, uint256 collateral);

    function setTerms(Term memory _terms) external returns (uint256);

    function getLoan(uint256 _loanId, bool _interest) external view returns (Loan memory loan);

    function getAuction(uint256 _auctionId) external view returns (Auction memory auction);

    function getFlashLoan(address _borrower, ERC20 _token, uint256 _amount, bytes memory _data) external;
}
