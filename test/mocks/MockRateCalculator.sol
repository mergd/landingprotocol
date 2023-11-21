// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {ICoordRateCalculator} from "src/ICoordRateCalculator.sol";

contract MockRateCalc is ICoordRateCalculator {
    function getNewRate(uint256 _termId, uint256 _timeElapsed) external view override returns (uint64 _newRatePerSec) {
        return 100;
    }
}
