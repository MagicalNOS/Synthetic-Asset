// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {
    AggregatorV3Interface
} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

/**
 * @title MockAggregator
 * @notice Mock Chainlink price feed for testing
 */
contract MockAggregator is AggregatorV3Interface {
    int256 private _price;
    uint8 private _decimals;
    string private _description;

    constructor(
        int256 initialPrice,
        uint8 decimals_,
        string memory description_
    ) {
        _price = initialPrice;
        _decimals = decimals_;
        _description = description_;
    }

    function setPrice(int256 newPrice) external {
        _price = newPrice;
    }

    function decimals() external view override returns (uint8) {
        return _decimals;
    }

    function description() external view override returns (string memory) {
        return _description;
    }

    function version() external pure override returns (uint256) {
        return 1;
    }

    function getRoundData(
        uint80 _roundId
    )
        external
        view
        override
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        )
    {
        return (_roundId, _price, block.timestamp, block.timestamp, _roundId);
    }

    function latestRoundData()
        external
        view
        override
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        )
    {
        return (1, _price, block.timestamp, block.timestamp, 1);
    }
}
