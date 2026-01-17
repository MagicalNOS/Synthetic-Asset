// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IExchanger {
    // Constants
    function EXCHANGE_FEE_RATE() external view returns (uint256);
    function DECIMAL_PRECISION() external view returns (uint256);

    // Immutable state getters
    function s_priceOracle() external view returns (address);
    function s_debtPool() external view returns (address);

    // View functions
    function isSyntheticAssetSupported(
        address synAsset
    ) external view returns (bool);

    // Exchange functions
    function exchangeSynAssetExactInput(
        address from,
        address to,
        uint256 amountIn,
        address recipient
    ) external returns (uint256);

    function exchangeSynAssetExactOutput(
        address from,
        address to,
        uint256 amountOut,
        address recipient
    ) external returns (uint256);
}
