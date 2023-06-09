// SPDX-License-Identifier: MIT
import "../LoanCoordinator.sol";
import {ERC20} from "@solmate/tokens/ERC20.sol";

contract SimpleStablecoin is ERC20, ILenderInterface {
    // uint256[10] public immutable collateral;
    ERC20 public immutable collateral;

    uint256 highestUnliquidatedLoan; // highest unliquidated loan eligible for liquidation

    uint256 public constant SCALAR = 1e6;

    mapping(uint256 => uint256[]) public lupToLoanID; // loan id to LUP (loan utilization percentage)
    mapping(uint256 => address) public loanToLiquidator; // loan id to liquidator
    uint256[] public lups; // sorted LUPs
    uint256 public constant LIQUIDATION_CR = 0.02e6; // 2%
    uint256 public constant SLASH_BUFFER = 0.05e6; // 5%
    uint256 public constant HIGH_WATERMARK = 0.03e6; // 3%
    uint256 public constant INTEREST_RATE = 0.01e6; // 1%
    LoanCoordinator public immutable loanCoordinator;

    mapping(address => uint256) public liquidatorUtilizedCollateral;
    mapping(address => uint256) public liquidatorCollateral;

    constructor(
        ERC20 _collateral,
        LoanCoordinator _coordinator
    ) ERC20("Min", "MIN", 18) {
        collateral = _collateral;
        loanCoordinator = _coordinator;
    }

    // need a loan initialized, and then
    // find the highest unliquidated loan
    // anyone can make loan +- 3% of that high watermark
    function verifyLoan(Loan memory loan) external override returns (bool) {
        require(ERC20(address(this)) == loan.debtToken, "Not min");
        // check if collateral is a collateral token
        require(collateral == loan.collateralToken, "Not collateral");
        require(msg.sender == address(loanCoordinator), "Not loan coordinator");

        // check if loan is within 3% of the highest unliquidated loan
        uint256 _lup = calculateRatio(loan.debtAmount, loan.collateralAmount);
        uint256 _highWatermark = calculateRatio(
            loanCoordinator.getLoan(highestUnliquidatedLoan).debtAmount,
            loanCoordinator.getLoan(highestUnliquidatedLoan).collateralAmount
        );

        require(
            _lup <= (_highWatermark * HIGH_WATERMARK) / SCALAR,
            "Loan not within 3% of highest unliquidated loan"
        );

        // check if loan is within 3% of the highest unliquidated loan
        if (_lup > _highWatermark) {
            highestUnliquidatedLoan = loan.id;
        }
    }

    // avoid needing to go into a loop - maybe autoselect best possible loan
    function liquidateLoan(uint256 loanId) external {
        Loan memory loan = loanCoordinator.getLoan(loanId);
        require(
            loan.startingTime + loan.duration <= block.timestamp,
            "Loan not liquidatable"
        );
        uint256 _liquidatorAmount = liquidatorCollateral[msg.sender];
        uint256 _amount = calculateRatio(
            loan.debtAmount,
            loan.collateralAmount
        ) * LIQUIDATION_CR;
        require(_liquidatorAmount >= _amount, "Not enough collateral");
        liquidatorCollateral[msg.sender] -= _amount;
        liquidatorUtilizedCollateral[msg.sender] += _amount;

        loanCoordinator.liquidateLoan(loanId);
        // Update LUP
        updateLUP(calculateRatio(loan.debtAmount, loan.collateralAmount));
    }

    function loanRepaidHook(Loan memory loan) external override {
        // if it is, check which loan is the highest unliquidated loan
        updateLUP(calculateRatio(loan.debtAmount, loan.collateralAmount));
        // Need to check if it's in auction and the liquidator bond is returned
        if (loan.duration == 0) {
            // loan is in auction
            // check to liquidator bond is returned
            address liq = loanToLiquidator[loan.id];
            uint256 _amount = (calculateRatio(
                loan.debtAmount,
                loan.collateralAmount
            ) * LIQUIDATION_CR) / SCALAR;
            liquidatorUtilizedCollateral[liq] -= _amount;
            liquidatorCollateral[liq] += _amount;
        }
    }

    function checkLUP() public returns (uint256) {
        Loan memory loan = loanCoordinator.getLoan(highestUnliquidatedLoan);
        require(
            loan.startingTime + loan.duration < block.timestamp,
            "Loan not liquidatable"
        );

        // uint256 _lup = (loan.collateralAmount * SCALAR) / loan.debtAmount;
        // calculateInterest(
        //     INTEREST_RATE,
        //     loan.debtAmount,
        //     loan.startingTime,
        //     block.timestamp
        // );
    }

    function auctionSettledHook(
        Loan memory loan,
        uint256 lenderReturn,
        uint256 borrowerReturn
    ) external override {
        uint256 liquidatorReturn = (calculateRatio(
            loan.debtAmount,
            loan.collateralAmount
        ) * LIQUIDATION_CR) / SCALAR;
        require(msg.sender == address(loanCoordinator), "Not loan coordinator");
        if (borrowerReturn == 0) {
            // Maximum return
            liquidatorReturn += (lenderReturn * 5 * 1e3) / SCALAR;
        } else if (
            borrowerReturn <= (loan.debtAmount * SLASH_BUFFER) / SCALAR
        ) {
            // in between
            liquidatorReturn +=
                ((loan.debtAmount * SLASH_BUFFER) / SCALAR - borrowerReturn) *
                5 *
                1e3;
        } else {
            // Liquidator slashed
            uint256 slash = borrowerReturn -
                (loan.debtAmount * SLASH_BUFFER) /
                SCALAR;
            liquidatorReturn = (slash >= liquidatorReturn)
                ? 0
                : liquidatorReturn - slash;
        }
        address liq = loanToLiquidator[loan.id];
        liquidatorCollateral[liq] += liquidatorReturn;
        liquidatorUtilizedCollateral[liq] -= liquidatorReturn;
    }

    function addLiquidatorCollateral(uint256 amount) external {
        transferFrom(msg.sender, address(this), amount);
        liquidatorCollateral[msg.sender] += amount;
    }

    function removeLiquidatorCollateral(uint256 amount) external {
        require(
            liquidatorCollateral[msg.sender] >= amount,
            "Not enough collateral"
        );
        liquidatorCollateral[msg.sender] -= amount;
        transfer(msg.sender, amount);
    }

    function calculateRatio(
        uint256 debtAmt,
        uint256 collateralAmt
    ) private pure returns (uint256) {
        return (debtAmt * SCALAR) / collateralAmt;
    }

    function updateLUP(uint256 _lup) private {
        uint256[] storage _lupToLoanID = lupToLoanID[_lup];
        bool updateHighest;
        if (highestUnliquidatedLoan == _lupToLoanID[_lupToLoanID.length - 1]) {
            updateHighest = true;
        }
        _lupToLoanID.pop();
        if (_lupToLoanID.length == 0) {
            for (uint256 i = 0; i < lups.length; i++) {
                if (lups[i] == _lup) {
                    lups[i] = lups[lups.length - 1];
                    lups.pop();
                    break;
                }
            }
        }
    }
}
