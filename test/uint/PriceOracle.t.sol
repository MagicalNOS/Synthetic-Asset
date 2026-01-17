// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test, console} from "forge-std/Test.sol";
import {PriceOracle} from "../../src/PriceOracle.sol";
import {sUSD} from "../../src/syntheticAsset/sUSD.sol";
import {sSPY} from "../../src/syntheticAsset/sSPY.sol";
import {sBTC} from "../../src/syntheticAsset/sBTC.sol";
import {sETH} from "../../src/syntheticAsset/sETH.sol";

contract PriceOracleTest is Test {
    PriceOracle public priceOracle;

    // Real Addresses on Arbitrum Sepolia
    address constant BTC_FEED = 0x56a43EB56Da12C0dc1D972ACb089c06a5dEF8e69;
    address constant USDC_FEED = 0x0153002d20B96532C639313c2d54c3dA09109309;
    address constant ETH_FEED = 0x14F11B9C146f738E627f0edB259fEdFd32e28486;
    address constant SPY_FEED = 0x4fB44FC4FA132d1a846Bd4143CcdC5a9f1870b06;

    sUSD public susd;
    sBTC public sbtc;
    sETH public seth;
    sSPY public sspy;

    function setUp() public {
        string memory rpcUrl = vm.envString("RPC_URL");
        vm.createSelectFork(rpcUrl);

        susd = new sUSD();
        sbtc = new sBTC();
        seth = new sETH();
        sspy = new sSPY();

        // Since anchorAddress() now returns address(this),
        // we register the synthetic asset addresses directly
        address[] memory assets = new address[](3);
        assets[0] = address(sbtc);
        assets[1] = address(seth);
        assets[2] = address(sspy);

        address[] memory feeds = new address[](3);
        feeds[0] = BTC_FEED;
        feeds[1] = ETH_FEED;
        feeds[2] = SPY_FEED;

        // Deploy Oracle - register synthetic assets directly
        priceOracle = new PriceOracle(assets, feeds, address(susd));
    }

    function test_GetPrice_BTC_Real() public view {
        int256 price = priceOracle.getPrice(address(sbtc));
        console.log("BTC Price (18 decimals):", price);

        assertTrue(price > 0, "Price should be positive");
    }

    function test_GetPrice_USDC_Real() public view {
        int256 price = priceOracle.getPrice(address(susd));
        console.log("USDC Price (18 decimals):", price);

        assertTrue(price > 0, "Price should be positive");
        // Should be roughly 1e18 (+- some variance)
        assertTrue(
            price > 0.9 * 1e18 && price < 1.1 * 1e18,
            "USDC price reasonable"
        );
    }

    function test_GetPrice_ETH_Real() public view {
        int256 price = priceOracle.getPrice(address(seth));
        console.log("ETH Price (18 decimals):", price);

        assertTrue(price > 0, "Price should be positive");
        // ETH ~3000 * 1e18 = 3e21.
        // If it was 8 decimals, it would be 3000 * 1e8 = 3e11.
        assertTrue(price > 1e18, "Price should be scaled to 18 decimals");
    }

    function test_GetPrice_SPY_Real() public view {
        int256 price = priceOracle.getPrice(address(sspy));
        console.log("SPY Price (18 decimals):", price);

        assertTrue(price > 0, "Price should be positive");
        // SPY ~500 * 1e18 = 5e20
        assertTrue(price > 1e18, "Price should be scaled to 18 decimals");
    }

    function test_GetPrice_sUSD() public view {
        int256 price = priceOracle.getPrice(address(susd));
        console.log("sUSD Price (18 decimals):", price);

        assertTrue(price > 0, "Price should be positive");
        // sUSD ~1 * 1e18 = 1e18
        assertTrue(
            price > 0.9 * 1e18 && price < 1.1 * 1e18,
            "sUSD price reasonable"
        );
    }
}
