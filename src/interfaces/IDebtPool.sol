
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IDebtPool {
    function increaseDebt(address user, uint256 amount) external;
    function decreaseDebt(address user, uint256 amount) external;
    function getUserDebt(address user) external view returns (uint256);
    function getTotalDebt() external view returns (uint256);
    function getUserDebtShare(address user) external view returns (uint256);
}