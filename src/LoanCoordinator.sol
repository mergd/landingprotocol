// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {ERC20} from "@solmate/tokens/ERC20.sol";
import {SafeTransferLib} from "@solmate/utils/SafeTransferLib.sol";

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

uint256 constant SCALAR = 1e6;

// Use the autocompounding or simple interest, above is the autocompounding
// Calculate notional accrued interest
function calculateInterest(
    uint256 _interestRate,
    uint256 _debtAmount,
    uint256 _startTime,
    uint256 _endTime
) pure returns (uint256 interest) {
    uint256 timeElapsed = _endTime - _startTime;
    interest =
        (_interestRate * _debtAmount * timeElapsed) /
        (365 days * SCALAR);
}

// Add NoDelegateCall to prevent delegatecalls into any state modifying hooks
abstract contract NoDelegateCall {
    error DelegateCallNotAllowed();

    /// @dev The original address of this contract
    address private immutable original;

    constructor() {
        // Immutables are computed in the init code of the contract, and then inlined into the deployed bytecode.
        // In other words, this variable won't change when it's checked at runtime.
        original = address(this);
    }

    /// @dev Private method is used instead of inlining into modifier because modifiers are copied into each method,
    ///     and the use of immutable means the address bytes are copied in every place the modifier is used.
    function checkNotDelegateCall() private view {
        if (address(this) != original) revert DelegateCallNotAllowed();
    }

    /// @notice Prevents delegatecall into the modified method
    modifier noDelegateCall() {
        checkNotDelegateCall();
        _;
    }
}

abstract contract Lender is NoDelegateCall {
    // Callback contracts can prevent repayments and bidding, so it's somewhat trusted
    constructor(LoanCoordinator _coordinator, bool _callback) NoDelegateCall() {
        coordinator = _coordinator;
        callback = _callback;
    }

    bool public immutable callback; // False - No callbacks, True - Allow callbacks
    LoanCoordinator public immutable coordinator;

    /**
     * Verify the loans - should be noDelegateCall
     * @dev THIS SHOULD BE RESTRICTED TO ONLY THE COORDINATOR IF IT UPDATES STATE
     * @param loan Loan struct
     * @param data Any additional identifying data
     */
    function verifyLoan(
        Loan memory loan,
        bytes32 data
    ) external virtual returns (bool);

    /**
     * Verify the loans - should be noDelegateCall
     * View function for verifying loan for UI
     * @param loan Loan struct
     * @param data Any additional identifying data
     */
    function viewVerifyLoan(
        Loan memory loan,
        bytes32 data
    ) public view virtual returns (bool);

    /**
     * Called after loan is repaid
     * @param loan Loan struct
     * @param lenderReturn Amount returned to lender – at max this is principal + interest + penalty
     * @param borrowerReturn Excess returned to borrower
     */
    function auctionSettledHook(
        Loan memory loan,
        uint256 lenderReturn,
        uint256 borrowerReturn
    ) external virtual returns (bytes4) {}

    function loanRepaidHook(Loan memory loan) external virtual returns (bytes4);

    /**
     * @dev Could be optimized
     * @param loan Pass in a loan struct.
     *      loan.debtAmount == Max Uint -> Max borrowable
     *      loan.collateralAmount == Max Uint -> Min Collateral required
     * @return _interest Provide the interest rate for given params
     * @return _lendAmount Provide the amount that can be borrowed
     * @return _collateral Provide the amount of collateral required
     */
    function getQuote(
        Loan memory loan
    ) external view virtual returns (uint256, uint256, uint256);
}

/// @dev Optional interface for borrowers to implement
abstract contract Borrower is NoDelegateCall {
    constructor(LoanCoordinator _coordinator) {
        coordinator = _coordinator;
    }

    LoanCoordinator public immutable coordinator;

    /**
     * @dev Called when loan is liquidated
     * @param loan Loan struct
     */
    function liquidationHook(Loan memory loan) external virtual;

    /**
     * @dev Called when the interest rate is rebalanced
     * @param loan Loan struct
     * @param newRate New interest rate
     */
    function interestRateUpdateHook(
        Loan memory loan,
        uint256 newRate
    ) external virtual;

    /**
     * @dev Called when the auction is settled
     * @param loan Loan struct
     * @param lenderReturn Amount returned to lender – at max this is principal + interest + penalty
     * @param borrowerReturn Excess returned to borrower
     */
    function auctionSettledHook(
        Loan memory loan,
        uint256 lenderReturn,
        uint256 borrowerReturn
    ) external virtual;

    /**
     * @dev Flashloan callback
     */
    function executeOperation(
        ERC20 _token,
        uint256 _amount,
        address _initiator,
        bytes memory _params
    ) external virtual returns (bool);
}

contract LoanCoordinator is NoDelegateCall {
    using SafeTransferLib for ERC20;

    //State
    uint256 public loanCount;
    Auction[] public auctions;
    Terms[] public loanTerms;
    uint256[5] public durations = [8 hours, 1 days, 2 days, 7 days, 0];
    mapping(uint256 loanId => uint256 auctionId) public loanIdToAuction;
    mapping(uint256 loanId => Loan loan) public loans;
    mapping(address borrower => uint256[] loanIds) public borrowerLoans;
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
    error Coordinator_LoanNotSettled();
    error Coordinator_FlashloanFailed();

    constructor() {}

    // ============================================================================================
    // Functions: Lending
    // ============================================================================================

    event LoanRepaid(
        uint256 indexed id,
        address indexed borrower,
        address indexed lender,
        uint256 amount
    );
    event LoanCreated(uint256 indexed id, Loan loan);
    event RateRebalanced(uint256 indexed loanId, uint256 newRate);
    event LoanLiquidated(uint256 indexed loanId);

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
        return
            createLoan(
                _lender,
                msg.sender,
                _collateral,
                _debt,
                _collateralAmount,
                _debtAmount,
                _interestRate,
                _duration,
                _terms,
                ""
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
        bytes32 _data
    ) public noDelegateCall returns (uint256) {
        loanCount++;
        Loan memory newLoan = Loan(
            loanCount,
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

        loans[loanCount] = newLoan;

        // Lender Hook to verify loan details
        if (Lender(_lender).verifyLoan(newLoan, _data)) {
            revert Coordinator_LoanNotVerified();
        }
        _collateral.safeTransferFrom(
            msg.sender,
            address(this),
            _collateralAmount
        );

        borrowerLoans[_borrower].push(loanCount);
        _debt.safeTransferFrom(_lender, address(this), _debtAmount);
        _debt.safeTransfer(msg.sender, _debtAmount);
        emit LoanCreated(loanCount, newLoan);
        return loanCount;
    }

    /**
     * @dev Initiate a dutch auction to liquidate the laon
     * @param _loanId the loan to liquidate
     */
    function liquidateLoan(uint256 _loanId) external {
        Loan storage loan = loans[_loanId];
        if (loan.lender != msg.sender) {
            revert Coordinator_OnlyLender();
        }

        if (
            loan.duration + loan.startingTime <= block.timestamp ||
            loan.duration == type(uint256).max
        ) {
            revert Coordinator_LoanNotLiquidatable();
        }
        uint256 interest = calculateInterest(
            loan.interestRate,
            loan.debtAmount,
            loan.startingTime,
            block.timestamp
        );
        uint256 totalDebt = loan.debtAmount + interest;
        startAuction(_loanId, totalDebt, loan.terms);

        loan.duration = type(uint256).max; // Auction off loan

        // Borrower Hook
        if (isContract(loan.borrower)) {
            try Borrower(loan.borrower).liquidationHook(loan) {} catch {}
        }
        emit LoanLiquidated(_loanId);
    }

    function repayLoan(uint256 _loanId) external {
        repayLoan(_loanId, msg.sender);
    }

    function repayLoan(
        uint256 _loanId,
        address onBehalfof
    ) public noDelegateCall {
        Loan memory loan = loans[_loanId];
        uint256 interest = calculateInterest(
            loan.interestRate,
            loan.debtAmount,
            loan.startingTime,
            block.timestamp
        );
        uint256 totalDebt = loan.debtAmount + interest;
        loan.debtToken.safeTransferFrom(onBehalfof, loan.lender, totalDebt);

        if (
            loan.callback &&
            Lender(loan.lender).loanRepaidHook(loan) !=
            Lender.loanRepaidHook.selector
        ) {
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
    function rebalanceRate(uint256 _loanId, uint256 _newRate) external {
        // Prevent lender hook from reverting
        Loan storage loan = loans[_loanId];
        if (loan.lender != msg.sender) {
            revert Coordinator_OnlyLender();
        }
        if (loan.duration + loan.startingTime > block.timestamp) {
            revert Coordinator_LoanNotLiquidatable();
        }
        // Add a check to prevent rate from being too high – maximum rate is 200% APY
        if (_newRate >= SCALAR * 2) {
            revert Coordinator_InterestRateTooHigh();
        }
        uint256 interest = calculateInterest(
            loan.interestRate,
            loan.debtAmount,
            loan.startingTime,
            block.timestamp
        );
        loan.debtAmount = loan.debtAmount + interest; // Recalculate debt amount
        loan.startingTime = block.timestamp; // Reset starting time
        loan.interestRate = _newRate;
        // Borrower Hook
        if (isContract(loan.borrower)) {
            try
                Borrower(loan.borrower).interestRateUpdateHook(loan, _newRate)
            {} catch {}
        }
        emit RateRebalanced(_loanId, _newRate);
    }

    // ============================================================================================
    // Functions: Auctions
    // ============================================================================================
    event AuctionCreated(Auction auction);
    event AuctionSettled(
        uint256 indexed auction,
        address bidder,
        uint256 price
    );
    event AuctionReclaimed(uint256 indexed loanId, uint256 amount);

    function startAuction(
        uint256 _loanId,
        uint256 _amount,
        uint256 _terms
    ) internal {
        Terms memory terms = loanTerms[_terms];
        uint256 startPrice = (_amount * terms.dutchAuctionMultiplier) / SCALAR;
        uint256 endPrice = _amount / (terms.settlementMultiplier * SCALAR);
        Auction memory newAuction = Auction(
            auctions.length,
            _loanId,
            terms.auctionLength,
            startPrice,
            block.timestamp,
            endPrice
        );
        auctions.push(newAuction);
        emit AuctionCreated(newAuction);
    }

    /**
     * @dev Settle the auction by putting a bid in
     * @param _auctionId the auction to settle
     */
    function bid(uint256 _auctionId) external noDelegateCall {
        Auction memory auction = auctions[_auctionId];
        Loan memory loan = loans[auction.loanId];
        Terms memory terms = loanTerms[loan.terms];
        if (auction.startingTime + auction.duration <= block.timestamp) {
            revert Coordinator_AuctionEnded(
                auction.startingTime + auction.duration
            );
        }

        uint256 currentPrice = getCurrentPrice(_auctionId);
        loan.debtToken.safeTransferFrom(
            msg.sender,
            address(this),
            currentPrice
        );
        loan.collateralToken.safeTransfer(msg.sender, loan.collateralAmount);

        uint256 interest = calculateInterest(
            loan.interestRate,
            loan.debtAmount,
            loan.startingTime,
            block.timestamp
        );
        uint256 _lenderClearing = ((loan.debtAmount + interest) *
            terms.liquidationBonus) / SCALAR;

        uint256 lenderReturn = (_lenderClearing > currentPrice)
            ? currentPrice
            : _lenderClearing;
        uint256 borrowerReturn = currentPrice - lenderReturn;

        deleteLoan(auction.loanId, loan.borrower);

        loan.debtToken.safeTransfer(loan.lender, lenderReturn);

        if (
            loan.callback &&
            Lender(loan.lender).auctionSettledHook(
                loan,
                lenderReturn,
                borrowerReturn
            ) !=
            Lender.auctionSettledHook.selector
        ) {
            revert Coordinator_LenderUpdateFailed();
        }
        if (isContract(loan.borrower)) // Borrower Hook
        {
            try
                Borrower(loan.borrower).auctionSettledHook(
                    loan,
                    lenderReturn,
                    borrowerReturn
                )
            {} catch {}
        }
        if (borrowerReturn > 0) {
            loan.debtToken.safeTransfer(loan.borrower, borrowerReturn);
        }
        emit AuctionSettled(_auctionId, msg.sender, currentPrice);
    }

    /**
     * @dev Lender can reclaim the collateral if the auction doesn't clear reserve price
     * @param _auctionId the auction to reclaim
     */
    function reclaim(uint256 _auctionId) external {
        Auction memory auction = auctions[_auctionId];
        if (auction.startingTime + auction.duration >= block.timestamp) {
            revert Coordinator_AuctionNotEnded();
        }

        Loan memory loan = loans[auction.loanId];
        delete auctions[_auctionId];
        delete loanIdToAuction[auction.loanId];

        loan.collateralToken.safeTransfer(loan.lender, loan.collateralAmount);
        deleteLoan(auction.loanId, loan.borrower);

        emit AuctionReclaimed(_auctionId, loan.collateralAmount);
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
            return startPrice - ((startPrice - endPrice) * elapsed) / remaining;
        }
    }

    // ============================================================================================
    // Functions: Misc
    // ============================================================================================
    event TermsSet(uint256 termId, Terms term);
    event Flashloan(address borrower, ERC20 token, uint256 amount);

    function getFlashLoan(
        address _borrower,
        ERC20 _token,
        uint256 _amount,
        bytes memory _data
    ) external noDelegateCall {
        _token.safeTransfer(_borrower, _amount);

        if (
            !Borrower(_borrower).executeOperation(
                _token,
                _amount,
                msg.sender,
                _data
            )
        ) {
            revert Coordinator_FlashloanFailed();
        }

        _token.safeTransferFrom(_borrower, address(this), _amount);
        emit Flashloan(_borrower, _token, _amount);
    }

    /**
     * @dev Set the terms of the loan
     * @param _terms the terms to set
     */
    function setTerms(Terms memory _terms) external returns (uint256) {
        loanTerms.push(_terms);
        emit TermsSet(loanTerms.length - 1, _terms);
        return loanTerms.length - 1;
    }

    function deleteLoan(uint256 _loanId, address _borrower) internal {
        // Delete _loanId from borrowerLoans and lenderLoans
        uint256[] storage borrowerLoanIds = borrowerLoans[_borrower];
        uint256 borrowerLoanIdsLength = borrowerLoanIds.length;
        for (uint256 i = 0; i < borrowerLoanIdsLength; i++) {
            if (borrowerLoanIds[i] == _loanId) {
                borrowerLoanIds[i] = borrowerLoanIds[borrowerLoanIdsLength - 1];
                borrowerLoanIds.pop();
                break;
            }
        }
    }

    // ============================================================================================
    // Functions: View
    // ============================================================================================

    function getLoan(uint256 _loanId) external view returns (Loan memory loan) {
        loan = loans[_loanId];

        // Account for pending interest for this loan
        loan.debtAmount += calculateInterest(
            loan.interestRate,
            loan.debtAmount,
            loan.startingTime,
            block.timestamp
        );
    }

    function isContract(address _addr) private view returns (bool) {
        uint256 size;
        assembly {
            size := extcodesize(_addr)
        }
        return size > 0;
    }
}
