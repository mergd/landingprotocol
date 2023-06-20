// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "./LoanCoordinator.sol";
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

contract YieldLooping is ILenderInterface, Owned, ERC4626 {
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

    uint256 private constant SCALAR = 1e6;
    ERC20 public immutable debtToken;
    LoanCoordinator public immutable coordinator;

    uint256 public globalUtilization;
    uint256 public globalKink;
    uint256 public globalBaseRate;
    uint256 public globalJumpMultiplier;

    constructor(
        uint256 _globalKink,
        uint256 _globalBaseRate,
        uint256 _globalJumpMultiplier,
        ERC20 _debtToken,
        LoanCoordinator _coordinator
    ) Owned(msg.sender) ERC4626(_debtToken, "Yield Token", "YLDL") {
        globalKink = _globalKink;
        globalBaseRate = _globalBaseRate;
        globalJumpMultiplier = _globalJumpMultiplier;
        debtToken = _debtToken;
        coordinator = _coordinator;
    }

    //============================================================================================//
    //                        LENDER INTERFACE OVERRIDES                                          //
    //============================================================================================//
    function verifyLoan(
        Loan memory loan
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

    //============================================================================================//
    //                             4626 Overrides                                                 //
    //============================================================================================//

    function withdraw(
        uint256 assets,
        address receiver,
        address owner
    ) public override returns (uint256 shares) {
        if (assets > asset.balanceOf(address(this))) {
            // enter withdrawal queue
            // add logic here
            return 0;
        }
        shares = previewWithdraw(assets); // No need to check for rounding error, previewWithdraw rounds up.

        if (msg.sender != owner) {
            uint256 allowed = allowance[owner][msg.sender]; // Saves gas for limited approvals.

            if (allowed != type(uint256).max)
                allowance[owner][msg.sender] = allowed - shares;
        }
        _burn(owner, shares);

        emit Withdraw(msg.sender, receiver, owner, assets, shares);

        asset.safeTransfer(receiver, assets);
    }

    function forceWithdraw(
        uint256 assets,
        address receiver,
        address owner
    ) public returns (uint256 shares) {
        shares = previewWithdraw(assets); // No need to check for rounding error, previewWithdraw rounds up.

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

    function processWithdrawQueue() public {
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

    // Brick redeem() to prevent users from redeeming – withdraws only
    function previewRedeem(uint256) public pure override returns (uint256) {
        return 0;
    }

    function totalAssets() public view override returns (uint256) {
        return debtToken.balanceOf(address(this)) + globalUtilization;
    }

    function processWithdrawalQueue() internal {}

    //============================================================================================//
    //                                  ADMIN                                                     //
    //============================================================================================//

    function liquidate(uint256 loanId) external onlyOwner {
        coordinator.liquidateLoan(loanId);
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
        LoanPair storage pair = LoanPairs[loan.collateralToken];
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
    }

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
