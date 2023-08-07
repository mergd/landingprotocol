// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {ERC20} from "@solmate/tokens/ERC20.sol";
import {SafeTransferLib} from "@solmate/utils/SafeTransferLib.sol";
import "./ILoanCoordinator.sol";

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
    constructor(
        ILoanCoordinator _coordinator,
        bool _callback
    ) NoDelegateCall() {
        coordinator = _coordinator;
        callback = _callback;
    }

    bool public immutable callback; // False - No callbacks, True - Allow callbacks
    ILoanCoordinator public immutable coordinator;

    /**
     * Verify the loans - should be noDelegateCall
     * @dev THIS SHOULD BE RESTRICTED TO ONLY THE COORDINATOR IF IT UPDATES STATE
     * @param loan Loan struct
     * @param data Any additional identifying data
     */
    function verifyLoan(
        ILoanCoordinator.Loan memory loan,
        bytes32 data
    ) external virtual returns (bool);

    /**
     * Verify the loans - should be noDelegateCall
     * View function for verifying loan for UI
     * @param loan Loan struct
     * @param data Any additional identifying data
     */
    function viewVerifyLoan(
        ILoanCoordinator.Loan memory loan,
        bytes32 data
    ) public view virtual returns (bool);

    /**
     * Called after loan is repaid
     * @param loan Loan struct
     * @param lenderReturn Amount returned to lender – at max this is principal + interest + penalty
     * @param borrowerReturn Excess collateral returned to borrower
     */
    function auctionSettledHook(
        ILoanCoordinator.Loan memory loan,
        uint256 lenderReturn,
        uint256 borrowerReturn
    ) external virtual returns (bytes4) {}

    function loanRepaidHook(
        ILoanCoordinator.Loan memory loan
    ) external virtual returns (bytes4);

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
        ILoanCoordinator.Loan memory loan
    ) external view virtual returns (uint256, uint256, uint256);
}

/// @dev Optional interface for borrowers to implement
abstract contract Borrower is NoDelegateCall {
    constructor(ILoanCoordinator _coordinator) {
        coordinator = _coordinator;
    }

    ILoanCoordinator public immutable coordinator;

    /**
     * @dev Called when loan is liquidated
     * @param loan Loan struct
     */
    function liquidationHook(
        ILoanCoordinator.Loan memory loan
    ) external virtual;

    /**
     * @dev Called when the interest rate is rebalanced
     * @param loan Loan struct
     * @param newRate New interest rate
     */
    function interestRateUpdateHook(
        ILoanCoordinator.Loan memory loan,
        uint256 newRate
    ) external virtual;

    /**
     * @dev Called when the auction is settled
     * @param loan Loan struct
     * @param lenderReturn Amount returned to lender – at max this is principal + interest + penalty
     * @param borrowerReturn Excess collateral returned to borrower
     */
    function auctionSettledHook(
        ILoanCoordinator.Loan memory loan,
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

contract LoanCoordinator is NoDelegateCall, ILoanCoordinator {
    using SafeTransferLib for ERC20;

    //State
    uint256 public loanCount;
    Auction[] public auctions;
    Term[] public loanTerms;
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
        Term memory terms = loanTerms[loan.terms];

        if (loan.lender != msg.sender) {
            revert Coordinator_OnlyLender();
        }

        if (
            loan.duration + loan.startingTime <= block.timestamp ||
            loan.duration == type(uint256).max // Auction in liquidation
        ) {
            revert Coordinator_LoanNotLiquidatable();
        }
        uint256 interest = calculateInterest(
            loan.interestRate,
            loan.debtAmount,
            loan.startingTime,
            block.timestamp
        );

        uint256 totalDebt = ((loan.debtAmount + interest) *
            terms.liquidationBonus) / SCALAR;
        startAuction(_loanId, totalDebt, terms.auctionLength);

        loan.duration = type(uint256).max; // Auction off loan

        // Borrower Hook
        if (isContract(loan.borrower))
            loan.borrower.call(
                abi.encodeWithSignature("liquidationHook(Loan)", loan)
            );
        emit LoanLiquidated(_loanId);
    }

    function repayLoan(uint256 _loanId) public noDelegateCall {
        Loan memory loan = loans[_loanId];
        uint256 interest = calculateInterest(
            loan.interestRate,
            loan.debtAmount,
            loan.startingTime,
            block.timestamp
        );
        uint256 totalDebt = loan.debtAmount + interest;
        loan.debtToken.safeTransferFrom(msg.sender, loan.lender, totalDebt);

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
        Loan storage loan = loans[_loanId];
        if (loan.lender != msg.sender) {
            revert Coordinator_OnlyLender();
        }
        if (
            loan.duration == type(uint256).max || // Loan is in liquidation
            loan.duration + loan.startingTime > block.timestamp
        ) {
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
        if (isContract(loan.borrower))
            loan.borrower.call(
                abi.encodeWithSignature(
                    "interestRateUpdateHook(Loan,uint256)",
                    loan,
                    _newRate
                )
            );

        emit RateRebalanced(_loanId, _newRate);
    }

    // ============================================================================================
    // Functions: Auctions
    // ============================================================================================

    function startAuction(
        uint256 _loanId,
        uint256 _amount,
        uint256 _auctionLength
    ) internal {
        Auction memory newAuction = Auction(
            _loanId,
            _amount,
            _auctionLength,
            block.timestamp
        );
        auctions.push(newAuction);
        emit AuctionCreated(newAuction);
    }

    /**
     *
     */
    function bid(uint256 _auctionId) external noDelegateCall {
        Auction memory auction = auctions[_auctionId];
        Loan memory loan = loans[auction.loanId];
        (uint256 bidAmount, uint256 collateralAmt) = getCurrentPrice(
            _auctionId
        );
        // Offer 100% of the debt to be repaid, but increase the amount of collateral offered
        if (collateralAmt == 0 || bidAmount == 0)
            revert Coordinator_AuctionEnded(_auctionId);

        uint256 borrowerReturn = loan.collateralAmount - collateralAmt;

        if (
            loan.callback &&
            Lender(loan.lender).auctionSettledHook(
                loan,
                bidAmount,
                borrowerReturn
            ) !=
            Lender.auctionSettledHook.selector
        ) revert Coordinator_LenderUpdateFailed();

        if (isContract(loan.borrower))
            loan.borrower.call(
                abi.encodeWithSignature(
                    "auctionSettledHook(Loan,uint256,uint256)",
                    loan,
                    bidAmount,
                    borrowerReturn
                )
            );

        // Delete the loan
        delete auctions[_auctionId];
        delete loanIdToAuction[auction.loanId];
        deleteLoan(auction.loanId, loan.borrower);

        loan.debtToken.safeTransferFrom(msg.sender, address(this), bidAmount);
        loan.collateralToken.safeTransfer(msg.sender, collateralAmt);
        loan.debtToken.safeTransfer(loan.lender, bidAmount);
        if (borrowerReturn > 0) {
            loan.debtToken.safeTransfer(loan.borrower, borrowerReturn);
        }

        emit AuctionSettled(_auctionId, msg.sender, bidAmount);
    }

    /**
     * @dev Lender can reclaim the collateral if the auction doesn't clear reserve price
     * @param _auctionId the auction to reclaim
     */
    function reclaim(uint256 _auctionId) public {
        Auction memory auction = auctions[_auctionId];
        if (auction.startTime + auction.duration >= block.timestamp) {
            revert Coordinator_AuctionNotEnded();
        }

        Loan memory loan = loans[auction.loanId];
        delete auctions[_auctionId];
        delete loanIdToAuction[auction.loanId];

        loan.collateralToken.safeTransfer(loan.lender, loan.collateralAmount);
        deleteLoan(auction.loanId, loan.borrower);

        emit AuctionReclaimed(_auctionId, loan.collateralAmount);
    }

    function getCurrentPrice(
        uint256 _auctionId
    ) public view returns (uint256 bidAmount, uint256 collateral) {
        Auction memory auction = auctions[_auctionId];
        Loan memory loan = loans[auction.loanId];
        if (auction.loanId == 0) {
            revert("Auction doesn't exist");
        }
        uint256 timeElapsed = auction.startTime +
            auction.duration -
            block.timestamp;
        uint256 midPoint = auction.duration / 2;
        // Offer 100% of the debt to be repaid, but increase the amount of collateral offered
        if (auction.startTime + midPoint > block.timestamp) {
            bidAmount = auction.recoveryAmount;
            collateral = (timeElapsed * loan.collateralAmount) / midPoint;
        } else if (
            auction.startTime + midPoint < block.timestamp &&
            timeElapsed < auction.duration
        ) {
            // Offer all the collateral, but reduce the amount of debt to be offered
            collateral = loan.collateralAmount;
            bidAmount =
                auction.recoveryAmount -
                (timeElapsed * auction.recoveryAmount) /
                midPoint;
        } else {
            // Auction lapsed
            bidAmount = 0;
            collateral = 0;
        }
    }

    // ============================================================================================
    // Functions: Misc
    // ============================================================================================

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
    function setTerms(Term memory _terms) external returns (uint256) {
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

    function getLoan(
        uint256 _loanId,
        bool _interest
    ) external view returns (Loan memory loan) {
        loan = loans[_loanId];

        // Account for pending interest for this loan
        if (_interest)
            loan.debtAmount += calculateInterest(
                loan.interestRate,
                loan.debtAmount,
                loan.startingTime,
                block.timestamp
            );
    }

    function getAuction(
        uint256 _auctionId
    ) external view returns (Auction memory auction) {
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
