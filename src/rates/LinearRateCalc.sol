// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {ICoordRateCalculator} from "src/ICoordRateCalculator.sol";

contract LinearRateCalc is ICoordRateCalculator {
    mapping(uint256 termId => uint64 rate) public rates;

    constructor() {}

    function setRate(uint256 _termId, uint64 _rate) external {
        if (rates[_termId] != 0) revert("RATE SET");
        rates[_termId] = _rate;
    }

    function getNewRate(uint256 _term, uint256) external view override returns (uint64 _newRatePerSec) {
        return rates[_term];
    }
}
