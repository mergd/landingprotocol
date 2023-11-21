// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {ICoordRateCalculator} from "src/ICoordRateCalculator.sol";

contract MockRateCalc is ICoordRateCalculator {
    uint256 rate;

    constructor(uint256 _rate) {
        rate = _rate;
    }

    function setRate(uint256 _rate) external {
        rate = _rate;
    }

    function getNewRate(uint256, uint256) external view override returns (uint64 _newRatePerSec) {
        return uint64(rate);
    }
}
