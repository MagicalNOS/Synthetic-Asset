// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IDebtPool {
    function increaseDebt(address user, uint256 amount) external;
    function decreaseDebt(address user, uint256 amount) external;
    function claimRewards(address user) external returns (uint256);
    function distributeRewards(uint256 amount) external;
    function getUserPendingRewards(
        address user
    ) external view returns (uint256);
    function getUserDebtUSD(address user) external view returns (uint256);
    function getTotalDebtUSD() external view returns (uint256);
    function getUserDebtShare(address user) external view returns (uint256);
    function updateUserBoost(address user) external;

    // Asset Management
    function isSynAssetSupported(address asset) external view returns (bool);
    function getSynAssets() external view returns (address[] memory);
    function addSynAsset(address asset) external;
    function removeSynAsset(address asset) external;
}
