// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

interface ICoordRateCalculator {
    /**
     * @dev Get the new rate per second for a term
     * @param _termId The term ID
     * @param _timeElapsed Time elapsed since last update of the term
     */
    function getNewRate(uint256 _termId, uint256 _timeElapsed) external view returns (uint64 _newRatePerSec);
}
