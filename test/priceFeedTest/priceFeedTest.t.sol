// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {PriceOracle} from "../../src/priceOracle.sol";
import {Test, console} from "forge-std/Test.sol";

// Test in Mainnet sepolia fork
contract PriceOracleTest is Test {
    PriceOracle private priceOracle;

    function setUp() public {
        address[] memory assets = new address[](2);
        address[] memory feeds = new address[](2);

        address btcAddress = address(makeAddr("BTC"));
        address usdcAddress = address(makeAddr("USDC"));
        assets[0] = btcAddress;
        assets[1] = usdcAddress;
        feeds[0] = 0x1b44F3514812d835EB1BDB0acB33d3fA3351Ee43;
        feeds[1] = 0xA2F78ab2355fe2f984D808B5CeE7FD0A93D5270E;
        priceOracle = new PriceOracle(assets, feeds, btcAddress, usdcAddress);
    }

    function testGetPriceBTC() public {
        // This is just to ensure that the contract is set up correctly.
        // Actual price fetching tests would require mocking the Chainlink feed.
        int256 price = priceOracle.getPrice(address(makeAddr("BTC")));
        console.log("BTC Price:", price);
    }

    function testGetPriceUSDC() public {
        int256 price = priceOracle.getPrice(address(makeAddr("USDC")));
        console.log("USDC Price:", price);
    }
    
}