// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "@solmate/utils/SafeTransferLib.sol";
import "@solmate/tokens/ERC20.sol";
import "./ILenderInterface.sol";

contract LoanCoordinator {
    using SafeTransferLib for ERC20;

    uint256 public loanCount;
    uint256 public constant SCALAR = 1e6;
    uint256 public constant LIQUIDATION_BONUS = 1.005e6; // 0.5% fixed bonus

    // enum Duration {
    //     EightHours,
    //     OneDay,
    //     TwoDays,
    //     Auctioned
    // }

    uint256[] public durations = [8 hours, 1 days, 2 days, 0];

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
    }

    struct Auction {
        uint256 id;
        uint256 loanId;
        uint256 duration;
        uint256 startingPrice;
        uint256 startingTime;
        uint256 endingPrice;
    }

    Auction[] public auctions;
    mapping(uint256 => uint256) public loanIdToAuction;
    mapping(uint256 => Loan) public loans;
    mapping(address => uint256[]) public borrowerLoans;
    mapping(address => uint256[]) public lenderLoans;

    event LoanRepaid(uint256 indexed id, address indexed borrower, address indexed lender, uint256 amount);
    event LoanCreated(
        uint256 indexed id,
        address indexed borrower,
        address indexed lender,
        ERC20 collateralToken,
        ERC20 debtToken,
        uint256 collateralAmount,
        uint256 debtAmount,
        uint256 interestRate,
        uint256 startingTime,
        uint256 duration
    );

    constructor() {}

    function createLoan(
        address _lender,
        ERC20 _collateral,
        ERC20 _debt,
        uint256 _collateralAmount,
        uint256 _debtAmount,
        uint256 _interestRate,
        uint256 _minduration
    ) external {
        loanCount++;
        Loan memory newLoan = Loan(
            loanCount,
            msg.sender,
            _lender,
            _collateral,
            _debt,
            _collateralAmount,
            _debtAmount,
            _interestRate,
            block.timestamp,
            _minduration
        );

        loans[loanCount] = newLoan;

        // Lender Hook to verify loan details
        ILenderInterface(_lender).verifyLoan(newLoan);
        _collateral.transferFrom(msg.sender, address(this), _collateralAmount);
        _debt.transferFrom(_lender, address(this), _debtAmount);
        _debt.transfer(msg.sender, _debtAmount);

        borrowerLoans[msg.sender].push(loanCount);
        lenderLoans[_lender].push(loanCount);
    }

    function liquidateLoan(uint256 _loanId) external {
        Loan storage loan = loans[_loanId];
        require(loan.lender == msg.sender, "Only lender can liquidate");
        if (loan.duration + loan.startingTime > block.timestamp || loan.duration == 0) {
            revert("Loan not yet liquidatable");
        }
        uint256 interest = calculateInterest(loan.interestRate, loan.debtAmount, loan.startingTime);
        uint256 totalDebt = loan.debtAmount + interest;
        startAuction(_loanId, totalDebt, interest, loan.duration);
        loan.duration = 0; // Auction off loan
    }

    function repayLoan(uint256 _loanId) external {
        Loan memory loan = loans[_loanId];
        uint256 interest = calculateInterest(loan.interestRate, loan.debtAmount, loan.startingTime);
        uint256 totalDebt = loan.debtAmount + interest;
        loan.debtToken.safeTransferFrom(msg.sender, loan.lender, totalDebt);
        emit LoanRepaid(_loanId, msg.sender, loan.lender, totalDebt);

        ILenderInterface(loan.lender).loanRepaidHook(loan);
        if (loan.duration == 0) {
            delete auctions[loanIdToAuction[_loanId]];
        }
    }

    // AUCTION LOGIC

    function startAuction(uint256 _loanId, uint256 _amount, uint256 _interestRate, uint256 _duration) internal {
        uint256 startPrice = ((_amount + _interestRate) * 2) / SCALAR;
        uint256 endPrice = (_amount * _interestRate) / (2 * SCALAR);
        Auction memory newAuction = Auction(auctions.length, _loanId, _duration, startPrice, block.timestamp, endPrice);
        auctions.push(newAuction);
    }

    function bid(uint256 _auctionId) external {
        Auction memory auction = auctions[_auctionId];
        Loan memory loan = loans[auction.loanId];
        require(auction.startingTime + auction.duration > block.timestamp, "Auction has ended");
        uint256 currentPrice = getCurrentPrice(_auctionId);
        loan.debtToken.transferFrom(msg.sender, address(this), currentPrice);
        loan.collateralToken.transfer(msg.sender, loan.collateralAmount);

        uint256 interest = calculateInterest(loan.interestRate, loan.debtAmount, loan.startingTime);
        uint256 _lenderClearing = ((loan.debtAmount + interest) * LIQUIDATION_BONUS) / SCALAR;

        uint256 lenderReturn = (_lenderClearing > currentPrice) ? currentPrice : _lenderClearing;
        uint256 borrowerReturn = currentPrice - lenderReturn;

        loan.debtToken.transfer(loan.lender, lenderReturn);

        if (borrowerReturn > 0) {
            loan.debtToken.transfer(loan.borrower, borrowerReturn);
        }
    }

    function reclaim(uint256 _auctionId) external {
        // reclaim collateral is auction is lapsed
        Auction memory auction = auctions[_auctionId];
        require(auction.startingTime + auction.duration < block.timestamp, "Auction has not ended");
        require(auction.endingPrice == auction.startingPrice, "Auction has not ended");
        Loan memory loan = loans[auction.loanId];
        loan.collateralToken.transfer(loan.lender, loan.collateralAmount);
    }

    function getCurrentPrice(uint256 _auctionId) public view returns (uint256) {
        Auction memory auction = auctions[_auctionId];
        uint256 startPrice = auction.startingPrice;
        uint256 endPrice = auction.endingPrice;
        uint256 startTime = auction.startingTime;
        uint256 duration = auction.duration;
        if (block.timestamp >= startTime + duration) {
            return endPrice;
        } else {
            uint256 elapsed = block.timestamp - startTime;
            uint256 remaining = duration - elapsed;
            return startPrice - (startPrice - endPrice) * elapsed / remaining;
        }
    }

    // VIEW FUNCTIONS

    function getLoan(uint256 _loanId) external view returns (Loan memory loan) {
        loan = loans[_loanId];
    }

    function getBorrowerLoans(address _borrower) external view returns (uint256[] memory) {
        return borrowerLoans[_borrower];
    }

    function getLenderLoans(address _lender) external view returns (uint256[] memory) {
        return lenderLoans[_lender];
    }

    function calculateInterest(uint256 _interestRate, uint256 _debtAmount, uint256 _startTime)
        public
        view
        returns (uint256 interest)
    {
        uint256 timeElapsed = block.timestamp - _startTime;
        interest = (_interestRate * _debtAmount * timeElapsed) / (SCALAR * 31536000);
    }
}
