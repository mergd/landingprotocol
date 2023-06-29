// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "../LoanCoordinator.sol";
import {ERC20} from "@solmate/tokens/ERC20.sol";
import {ERC4626} from "@solmate/mixins/ERC4626.sol";
import {Owned} from "@solmate/auth/Owned.sol";

interface PriceOracle {
    /**
     * Return price of collateral in the debt token, scaled by 1e6
     * @param collateral Collateral token
     * @param debt Debt Token
     */
    function price(
        address collateral,
        address debt
    ) external view returns (uint256);
}

contract YieldLooping is Lender, Owned, ERC4626 {
    using SafeTransferLib for ERC20;

    struct LoanPair {
        uint256 vaultCap;
        uint256 vaultUtilization;
        uint256 kink;
        uint256 baseRate;
        uint256 jumpMultiplier;
        uint256 minCollateralRatio;
        uint256 minDebtAmount;
        uint256 maxDuration;
        uint256 terms;
        PriceOracle oracle;
        ERC20 collateralToken;
    }

    struct WithdrawalQueue {
        address caller;
        address owner;
        address receiver;
        uint256 shares;
    }

    WithdrawalQueue[] public withdrawalQueue;

    // ========= EVENTS ========= //

    // ========= ERRORS ========= //

    // ========= STATE ========= //
    uint256 public withdrawalQueueIndex;

    mapping(ERC20 => LoanPair) public LoanPairs;

    ERC20 public immutable debtToken;

    uint256 public globalUtilization;
    uint256 public globalKink;
    uint256 public globalBaseRate;
    uint256 public globalJumpMultiplier;
    uint256 public userAssets;

    constructor(
        uint256 _globalKink,
        uint256 _globalBaseRate,
        uint256 _globalJumpMultiplier,
        ERC20 _debtToken,
        LoanCoordinator _coordinator
    )
        Owned(msg.sender)
        ERC4626(_debtToken, "Yield Token", "YLDL")
        Lender(_coordinator)
    {
        globalKink = _globalKink;
        globalBaseRate = _globalBaseRate;
        globalJumpMultiplier = _globalJumpMultiplier;
        debtToken = _debtToken;
    }

    //============================================================================================//
    //                        LENDER INTERFACE OVERRIDES                                          //
    //============================================================================================//
    function verifyLoan(
        Loan memory loan,
        bytes32
    ) external override returns (bool valid) {
        require(msg.sender == address(coordinator), "Only coordinator");
        valid = _verifyLoan(loan);
        if (valid) {
            globalUtilization += loan.debtAmount;
        }
    }

    function auctionSettledHook(
        Loan memory loan,
        uint256 lenderReturn,
        uint256
    ) external override {
        require(msg.sender == address(coordinator), "Only coordinator");

        uint256 debtAmount = loan.debtAmount > lenderReturn
            ? lenderReturn
            : loan.debtAmount;

        // Update global utilization
        globalUtilization -= debtAmount;
        // Update vault utilization
        LoanPairs[loan.collateralToken].vaultUtilization -= debtAmount;
        processWithdrawalQueue();
    }

    function loanRepaidHook(Loan memory loan) external override {
        // Update global utilization
        globalUtilization -= loan.debtAmount;
        // Update vault utilization
        LoanPairs[loan.collateralToken].vaultUtilization -= loan.debtAmount;
        processWithdrawalQueue();
    }

    function getQuote(
        Loan memory loan
    )
        external
        view
        override
        returns (uint256 _interest, uint256 _borrow, uint256 _collateral)
    {
        LoanPair memory pair = LoanPairs[loan.collateralToken];

        uint256 _price = pair.oracle.price(
            address(loan.collateralToken),
            address(loan.debtToken)
        );
        if (loan.debtAmount == type(uint256).max) {
            uint256 amt = (loan.collateralAmount *
                _price *
                pair.minCollateralRatio) / (SCALAR * SCALAR);
            _borrow = (pair.vaultCap >= pair.vaultUtilization + amt)
                ? amt
                : pair.vaultCap - pair.vaultUtilization;
            loan.debtAmount = _borrow;
        } else if (loan.collateralAmount == type(uint256).max) {
            _collateral =
                (loan.debtAmount * SCALAR * SCALAR) /
                (_price * pair.minCollateralRatio);
            _borrow = loan.debtAmount;
        } else {
            _borrow = loan.debtAmount;
        }

        _interest = jumprateModel(
            pair.vaultUtilization + _borrow,
            pair.vaultCap,
            pair.kink,
            pair.baseRate,
            pair.jumpMultiplier
        );
        // Basic checks
        bool valid;
        valid = (loan.debtToken == debtToken) ? true : false;
        valid = (pair.vaultCap >= pair.vaultUtilization + loan.debtAmount)
            ? valid
            : false;
        valid = (pair.minCollateralRatio <=
            (loan.collateralAmount * _price) / loan.debtAmount)
            ? valid
            : false;
        valid = (pair.minDebtAmount <= loan.debtAmount) ? valid : false;
        valid = (loan.duration <= pair.maxDuration) ? valid : false;
        valid = (loan.terms == pair.terms) ? valid : false;
        if (valid) return (0, 0, 0);
    }

    //============================================================================================//
    //                             4626 Overrides                                                 //
    //============================================================================================//

    function redeem(
        uint256 shares,
        address receiver,
        address owner
    ) public override returns (uint256 assets) {
        processWithdrawalQueue();
        assets = previewWithdraw(shares);
        // If there are not enough assets, or if there are pending withdrawals, add to queue
        if (
            assets > asset.balanceOf(address(this)) ||
            withdrawalQueueIndex < withdrawalQueue.length
        ) {
            WithdrawalQueue memory queueItem = WithdrawalQueue({
                caller: msg.sender,
                owner: owner,
                receiver: receiver,
                shares: shares
            });
            withdrawalQueue.push(queueItem);
            return 0;
        }
        if (msg.sender != owner) {
            uint256 allowed = allowance[owner][msg.sender]; // Saves gas for limited approvals.

            if (allowed != type(uint256).max)
                allowance[owner][msg.sender] = allowed - shares;
        }

        // Check for rounding error since we round down in previewRedeem.
        require(assets != 0, "ZERO_ASSETS");

        beforeWithdraw(assets, shares);

        _burn(owner, shares);

        emit Withdraw(msg.sender, receiver, owner, assets, shares);

        asset.safeTransfer(receiver, assets);
    }

    /**
     * Force withdraw assets – take on withdraw slippage if necessary
     * @param assets Assets to withdraw
     * @param receiver Address to receive assets
     * @param owner Owner
     */
    function forceRedeem(
        uint256 shares,
        address receiver,
        address owner
    ) public returns (uint256 assets) {
        assets = previewWithdraw(shares); // No need to check for rounding error, previewWithdraw rounds up.

        if (msg.sender != owner) {
            uint256 allowed = allowance[owner][msg.sender]; // Saves gas for limited approvals.

            if (allowed != type(uint256).max)
                allowance[owner][msg.sender] = allowed - shares;
        }
        _burn(owner, shares);

        assets = asset.balanceOf(address(this)) < assets
            ? asset.balanceOf(address(this))
            : assets;

        emit Withdraw(msg.sender, receiver, owner, assets, shares);

        asset.safeTransfer(receiver, assets);
    }

    function processWithdrawalQueue() public {
        for (
            uint256 i = withdrawalQueueIndex;
            i < withdrawalQueue.length;
            i++
        ) {
            WithdrawalQueue memory queueItem = withdrawalQueue[i];
            uint256 assets = previewWithdraw(queueItem.shares);
            if (assets <= asset.balanceOf(address(this))) {
                // Process withdrawal since there's enough cash
                // Approval check already done in withdraw()

                // If user balance dips below withdrawal amount, their withdraw request gets cancelled
                if (balanceOf[queueItem.owner] >= queueItem.shares) {
                    beforeWithdraw(assets, queueItem.shares);
                    _burn(queueItem.owner, queueItem.shares);

                    asset.transfer(queueItem.receiver, queueItem.shares);

                    emit Withdraw(
                        queueItem.caller,
                        queueItem.receiver,
                        queueItem.owner,
                        assets,
                        queueItem.shares
                    );
                }

                delete withdrawalQueue[i];
                withdrawalQueueIndex++;
            } else {
                break; // Break until there's enough cash in the vault again
            }
        }
    }

    // Brick redeem() to prevent users from withdrawing, redeems only
    function previewWithdraw(uint256) public pure override returns (uint256) {
        return 0;
    }

    function totalAssets() public view override returns (uint256) {
        return debtToken.balanceOf(address(this)) + globalUtilization;
    }

    function afterDeposit(uint256 assets, uint256) internal override {
        userAssets += assets;
    }

    //============================================================================================//
    //                                  ADMIN                                                     //
    //============================================================================================//

    function assessFee(uint256 amount) external onlyOwner {
        require(totalAssets() >= amount + userAssets, "Not enough assets");
        asset.safeTransfer(msg.sender, amount);
    }

    function liquidate(uint256 loanId) external onlyOwner {
        coordinator.liquidateLoan(loanId);
    }

    // Liquidate liquidated loans that have not cleared auction
    function reclaim(uint256 loanId) external onlyOwner {
        coordinator.reclaim(loanId);
        // Write down value in global utilization
    }

    // Claim unrecovered tokens, including tokens from any non reclaimed tokens.
    function recoverUnsupported(ERC20 token) external onlyOwner {
        if (token != debtToken)
            token.transfer(msg.sender, token.balanceOf(address(this)));
    }

    // Send in proceds from manually processed liquidations if there are any
    function updateUtilization(uint256 amount, ERC20 pair) external onlyOwner {
        asset.transferFrom(msg.sender, address(this), amount);
        LoanPairs[pair].vaultUtilization -= amount;
        globalUtilization -= amount;
    }

    function setGlobalKink(uint256 _globalKink) external onlyOwner {
        globalKink = _globalKink;
    }

    function setGlobalBaseRate(uint256 _globalBaseRate) external onlyOwner {
        globalBaseRate = _globalBaseRate;
    }

    function setGlobalJumpMultiplier(
        uint256 _globalJumpMultiplier
    ) external onlyOwner {
        globalJumpMultiplier = _globalJumpMultiplier;
    }

    function setNewLoanPair(LoanPair memory _loanPair) external onlyOwner {
        LoanPairs[_loanPair.collateralToken] = _loanPair;
    }

    function setLoanPair(LoanPair memory _loanPair) external onlyOwner {
        LoanPair memory pair = LoanPairs[_loanPair.collateralToken];
        _loanPair.vaultUtilization = pair.vaultUtilization;
        LoanPairs[_loanPair.collateralToken] = _loanPair;
    }

    //============================================================================================//
    //                             INTERNAL                                                       //
    //============================================================================================//

    function _verifyLoan(Loan memory loan) public view returns (bool valid) {
        LoanPair memory pair = LoanPairs[loan.collateralToken];
        uint256 _price = pair.oracle.price(
            address(loan.collateralToken),
            address(loan.debtToken)
        );
        uint256 _interestRate = jumprateModel(
            pair.vaultUtilization + loan.debtAmount,
            pair.vaultCap,
            pair.kink,
            pair.baseRate,
            pair.jumpMultiplier
        );
        // Check loan validity
        valid = (loan.debtToken == debtToken) ? true : false;
        valid = (pair.vaultCap >= pair.vaultUtilization + loan.debtAmount)
            ? valid
            : false;
        valid = (pair.minCollateralRatio <=
            (loan.collateralAmount * _price) / loan.debtAmount)
            ? valid
            : false;
        valid = (pair.minDebtAmount <= loan.debtAmount) ? valid : false;
        valid = (loan.duration <= pair.maxDuration) ? valid : false;
        valid = (loan.interestRate >= _interestRate) ? valid : false;
        valid = (loan.terms == pair.terms) ? valid : false;
    }

    /**
     * Calculate local interest rate
     * @param utilization Pair utilization
     * @param cap Pair debt cap
     * @param kink Kink, scaled by SCALAR
     * @param baseRate Base rate, scaled by SCALAR
     * @param jumpMultiplier Jump rate past kink, scaled by SCALAR
     */
    function jumprateModel(
        uint256 utilization,
        uint256 cap,
        uint256 kink,
        uint256 baseRate,
        uint256 jumpMultiplier
    ) public view returns (uint256 interestRate) {
        uint256 _globalUtil = ((globalUtilization + utilization) * SCALAR) /
            debtToken.balanceOf(address(this));
        // Global Jump rate model
        if (_globalUtil > globalKink) {
            interestRate =
                ((globalKink * globalBaseRate) /
                    SCALAR +
                    ((_globalUtil - globalKink) * globalJumpMultiplier)) /
                SCALAR;
        } else {
            interestRate = (_globalUtil * globalBaseRate) / SCALAR;
        }
        // Pair specific
        if ((utilization * SCALAR) / cap > kink) {
            interestRate +=
                ((kink * baseRate) /
                    SCALAR +
                    ((utilization / cap - kink) * jumpMultiplier)) /
                SCALAR;
        } else {
            interestRate += ((utilization / cap) * baseRate) / SCALAR;
        }
    }
}
