// SPDX-License-Identifier: MIT
import {ERC20} from "@solmate/tokens/ERC20.sol";

interface ILoanCoordinator {
    struct Loan {
        uint256 id;
        address borrower;
        address lender;
        ERC20 collateralToken;
        ERC20 debtToken;
        uint256 collateralAmount;
        uint256 debtAmount;
        uint256 interestRate;
        uint256 startingTime;
        uint256 duration;
        uint256 terms;
    }

    struct Terms {
        uint256 liquidationBonus;
        uint256 dutchAuctionMultiplier;
        uint256 settlementMultiplier;
        uint256 auctionLength;
    }

    struct Auction {
        uint256 id;
        uint256 loanId;
        uint256 duration;
        uint256 startingPrice;
        uint256 startingTime;
        uint256 endingPrice;
    }

    /** STATE  */
    function loanCount() external view returns (uint256);

    function durations(uint256 index) external view returns (uint256);

    function auctions(uint256 index) external view returns (Auction memory);

    function loanTerms(uint256 index) external view returns (Terms memory);

    function loanIdToAuction(uint256 index) external view returns (uint256);

    function loans(uint256 index) external view returns (Loan memory);

    function borrowerLoans(
        address account
    ) external view returns (uint256[] memory);

    /** EVENTS */
    event LoanRepaid(
        uint256 indexed id,
        address indexed borrower,
        address indexed lender,
        uint256 amount
    );
    event LoanCreated(uint256 indexed id, Loan loan);
    event AuctionCreated(Auction auction);
    event AuctionSettled(
        uint256 indexed auction,
        address bidder,
        uint256 price
    );
    event RateRebalanced(uint256 indexed loanId, uint256 newRate);
    event AuctionReclaimed(uint256 indexed loanId, uint256 amount);
    event LoanLiquidated(uint256 indexed loanId);
    event TermsSet(uint256 termId, Terms term);

    /** CONTRACT FUNCTIONS */
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

    function liquidateLoan(uint256 _loanId) external;

    function repayLoan(uint256 _loanId) external;

    function repayLoan(uint256 _loanId, address onBehalfof) external;

    function rebalanceRate(uint256 _loanId, uint256 _newRate) external;

    function bid(uint256 _auctionId) external;

    function reclaim(uint256 _auctionId) external;

    function getCurrentPrice(
        uint256 _auctionId
    ) external view returns (uint256);

    function setTerms(Terms memory _terms) external returns (uint256);

    function getLoan(uint256 _loanId) external view returns (Loan memory loan);
}
