// SPDX-License-Identifier: MIT

pragma solidity ^0.8.17;

import "../LoanCoordinator.sol";
import "@solmate/auth/Owned.sol";

contract LenderRegistry is Owned {
    LoanCoordinator public immutable loanCoordinator;

    mapping(bytes32 => Lender[]) public lenders;

    constructor(LoanCoordinator _coordinator, address _owner) Owned(_owner) {
        loanCoordinator = _coordinator;
    }

    function addLender(uint256 _pair, address _collateral, address _debt, Lender _lender) public onlyOwner {
        bytes32 key = keccak256(abi.encodePacked(_pair, _collateral, _debt));
        lenders[key].push(_lender);
    }

    function removeLender(uint256 _pair, address _collateral, address _debt, Lender _lender, uint256 _id)
        public
        onlyOwner
    {
        bytes32 key = keccak256(abi.encodePacked(_pair, _collateral, _debt));
        Lender[] storage lenderList = lenders[key];
        require(lenderList[_id] == _lender, "INVALID_LENDER");
        // Remove the lender from the list
        lenderList[_id] = lenderList[lenderList.length - 1];
        lenderList.pop();
    }

    /**
     * Optimize for the best interest rate, collateral, or borrow amount
     * @param _pair uint256 pair
     * @param _callback Whether the lender can execute callbacks – somewhat trusted
     * @param _collateral Collateral Token
     * @param _debt Debt token
     * @param _collateralAmount Collateral provided - set at max to find the highest LTV
     * @param _debtAmount Debt amount – set at max to find the best lender
     * @param _duration Duration of the loan
     * @param _interest Maximum desired interest rate
     */
    function getLender(
        uint256 _pair,
        bool _callback,
        address _collateral,
        address _debt,
        uint256 _collateralAmount,
        uint256 _debtAmount,
        uint256 _duration,
        uint256 _interest
    ) public view returns (ILoanCoordinator.Loan memory loan) {
        bytes32 key = keccak256(abi.encodePacked(_pair, _collateral, _debt));
        Lender[] memory lenderList = lenders[key];
        loan.debtAmount = _debtAmount;
        loan.collateralAmount = _collateralAmount;
        loan.interestRate = _interest;
        loan.lender = address(0);

        loan = ILoanCoordinator.Loan(
            0,
            msg.sender,
            address(0),
            _callback,
            ERC20(_collateral),
            ERC20(_debt),
            _collateralAmount,
            _debtAmount,
            _interest,
            block.timestamp,
            _duration,
            _pair
        );

        for (uint256 i = 0; i < lenderList.length; i++) {
            ILoanCoordinator.Loan memory _loan = ILoanCoordinator.Loan(
                0,
                msg.sender,
                address(0),
                _callback,
                ERC20(_collateral),
                ERC20(_debt),
                loan.collateralAmount,
                loan.debtAmount,
                loan.interestRate,
                block.timestamp,
                _duration,
                _pair
            );
            Lender _lender = lenderList[i];
            (uint256 interest, uint256 borrow, uint256 collateral) = _lender.getQuote(_loan);
            if (interest + borrow + collateral == 0) {
                continue; // Not supported by pool
            }

            if (loan.debtAmount == type(uint256).max) {
                loan.debtAmount = borrow;
            }
            if (loan.collateralAmount == type(uint256).max) {
                loan.collateralAmount = collateral;
            }
            if (loan.interestRate == type(uint256).max) {
                loan.interestRate = interest;
            }

            // Specify borrow and collateral amounts -> get best interest rate
            if (
                interest < loan.interestRate && _interest == 0 && _debtAmount != type(uint256).max
                    && _collateralAmount != type(uint256).max
            ) {
                loan.interestRate = interest;
                loan.lender = address(_lender);
            }

            // Specify borrow, interest rate -> get best collateral amount
            if (
                collateral < loan.collateralAmount && _interest != 0 && _debtAmount != type(uint256).max
                    && _collateralAmount == type(uint256).max
            ) {
                loan.collateralAmount = collateral;
                loan.lender = address(_lender);
            }
            // Specify collateral, interest rate -> get best borrow amount
            if (
                borrow < loan.debtAmount && _interest != 0 && _debtAmount == type(uint256).max
                    && _collateralAmount != type(uint256).max
            ) {
                loan.debtAmount = borrow;
                loan.lender = address(_lender);
            }
        }
    }
}
