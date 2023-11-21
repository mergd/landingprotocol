// SPDX-License-Identifier: ISC
pragma solidity ^0.8.21;

interface ICoordRateCalculator {
    function getNewRate(uint256 _termId, uint256 _timeElapsed) external view returns (uint64 _newRatePerSec);
}
