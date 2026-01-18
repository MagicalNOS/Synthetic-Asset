// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {CollateralManager} from "../../src/CollateralManager.sol";
import {DebtPool} from "../../src/DebtPool.sol";
import {Exchanger} from "../../src/Exchanger.sol";
import {PriceOracle} from "../../src/PriceOracle.sol";
import {sUSD} from "../../src/syntheticAsset/sUSD.sol";
import {sBTC} from "../../src/syntheticAsset/sBTC.sol";
import {sETH} from "../../src/syntheticAsset/sETH.sol";
import {sSPY} from "../../src/syntheticAsset/sSPY.sol";
import {MockWBTC} from "../../src/MockERC20/MockWBTC.sol";
import {MockWETH} from "../../src/MockERC20/MockWETH.sol";
import {MockUSDC} from "../../src/MockERC20/MockUSDC.sol";
import {MockAggregator} from "./MockAggregator.sol";

/**
 * @title Handler
 * @notice Fuzzer handler for invariant testing of Synthetic Asset protocol
 * @dev Wraps protocol interactions with bounded parameters and ghost variable tracking
 */
contract Handler is Test {
    // ============ Protocol Contracts ============
    CollateralManager public collateralManager;
    DebtPool public debtPool;
    Exchanger public exchanger;
    PriceOracle public priceOracle;

    // ============ Assets ============
    sUSD public susd;
    sBTC public sbtc;
    sETH public seth;
    sSPY public sspy;
    MockWBTC public wbtc;
    MockWETH public weth;
    MockUSDC public usdc;

    // ============ Ghost Variables ============
    uint256 public ghost_totalDeposited;
    uint256 public ghost_totalWithdrawn;
    uint256 public ghost_totalMinted;
    uint256 public ghost_totalBurned;
    uint256 public ghost_totalExchangeFees;
    uint256 public ghost_totalRewardsClaimed;
    uint256 public ghost_lastGlobalRewardIndex;

    // ============ Actor Management ============
    address[] public actors;
    address internal currentActor;

    // ============ Collateral & SynAsset Arrays ============
    address[] public collateralAssets;
    address[] public syntheticAssets;

    // ============ Mock Price Feeds ============
    MockAggregator public btcFeed;
    MockAggregator public ethFeed;
    MockAggregator public usdcFeed;

    // ============ Call Counters ============
    mapping(bytes32 => uint256) public calls;

    // ============ Price Tracking ============
    uint256 public ghost_priceDropCount;

    constructor(
        CollateralManager _collateralManager,
        DebtPool _debtPool,
        Exchanger _exchanger,
        PriceOracle _priceOracle,
        sUSD _susd,
        sBTC _sbtc,
        sETH _seth,
        sSPY _sspy,
        MockWBTC _wbtc,
        MockWETH _weth,
        MockUSDC _usdc
    ) {
        collateralManager = _collateralManager;
        debtPool = _debtPool;
        exchanger = _exchanger;
        priceOracle = _priceOracle;
        susd = _susd;
        sbtc = _sbtc;
        seth = _seth;
        sspy = _sspy;
        wbtc = _wbtc;
        weth = _weth;
        usdc = _usdc;

        // Setup collateral assets
        collateralAssets.push(address(wbtc));
        collateralAssets.push(address(weth));
        collateralAssets.push(address(usdc));

        // Setup synthetic assets (excluding sUSD for exchange targets)
        syntheticAssets.push(address(susd));
        syntheticAssets.push(address(sbtc));
        syntheticAssets.push(address(seth));
        syntheticAssets.push(address(sspy));

        // Create initial actors
        for (uint256 i = 0; i < 5; i++) {
            address actor = makeAddr(string(abi.encodePacked("actor", i)));
            actors.push(actor);
            _fundActor(actor);
        }
    }

    /// @notice Set mock price feeds for price manipulation testing
    function setPriceFeeds(
        MockAggregator _btcFeed,
        MockAggregator _ethFeed,
        MockAggregator _usdcFeed
    ) external {
        btcFeed = _btcFeed;
        ethFeed = _ethFeed;
        usdcFeed = _usdcFeed;
    }

    // ============ Modifiers ============
    modifier useActor(uint256 actorSeed) {
        currentActor = actors[actorSeed % actors.length];
        vm.startPrank(currentActor);
        _;
        vm.stopPrank();
    }

    modifier countCall(bytes32 key) {
        calls[key]++;
        _;
    }

    // ============ Handler Functions ============

    function depositCollateral(
        uint256 actorSeed,
        uint256 assetSeed,
        uint256 amount
    ) external useActor(actorSeed) countCall("depositCollateral") {
        address asset = collateralAssets[assetSeed % collateralAssets.length];

        // Bound amount to reasonable range to prevent overflow in USD calculations (especially for low-decimal assets like WBTC)
        uint256 balance = IERC20(asset).balanceOf(currentActor);
        if (balance == 0) return;

        // Cap at 1e20 to prevent overflow in Health Factor and Rewards calculations
        // WBTC (8 decimals) -> scaled by 1e10 -> 1e30. Price 1e23 -> Value 1e53.
        // HF Calc: 1e53 * 1e18 = 1e71 < 1e77 (Max Uint). Safe even with 1 wei debt.
        uint256 maxAmount = balance > 1e20 ? 1e20 : balance;
        amount = bound(amount, 1, maxAmount);

        IERC20(asset).approve(address(collateralManager), amount);

        try collateralManager.depositCollateral(asset, amount) {
            // Safe calculation for ghost variable - skip if price query fails or overflows
            try priceOracle.getPrice(asset) returns (int256 priceInt) {
                if (priceInt > 0) {
                    uint256 price = uint256(priceInt);
                    ghost_totalDeposited += Math.mulDiv(amount, price, 1e18);
                }
            } catch {}
        } catch {}
    }

    function withdrawCollateral(
        uint256 actorSeed,
        uint256 assetSeed,
        uint256 amount
    ) external useActor(actorSeed) countCall("withdrawCollateral") {
        address asset = collateralAssets[assetSeed % collateralAssets.length];

        uint256 deposited = collateralManager.getStakerCollateral(
            currentActor,
            asset
        );
        if (deposited == 0) return;

        amount = bound(amount, 1, deposited);

        try collateralManager.withdrawCollateral(asset, amount) {
            // Safe calculation for ghost variable - skip if price query fails or overflows
            try priceOracle.getPrice(asset) returns (int256 priceInt) {
                if (priceInt > 0) {
                    uint256 price = uint256(priceInt);
                    ghost_totalWithdrawn += Math.mulDiv(amount, price, 1e18);
                }
            } catch {}
        } catch {}
    }

    function mintSyntheticAsset(
        uint256 actorSeed,
        uint256 synAssetSeed,
        uint256 amount
    ) external useActor(actorSeed) countCall("mintSyntheticAsset") {
        address synAsset = syntheticAssets[
            synAssetSeed % syntheticAssets.length
        ];

        // Bound amount to prevent excessive minting
        uint256 userCollateral = collateralManager.getUserCollateralUSD(
            currentActor
        );
        if (userCollateral == 0) return;

        // Max mint is collateral / 2 (200% ratio) minus current debt
        uint256 userDebt = debtPool.getUserDebtUSD(currentActor);
        uint256 maxMint = userCollateral > userDebt * 2
            ? (userCollateral / 2) - userDebt
            : 0;
        if (maxMint < 1e18) return; // Skip if can't meet minimum

        amount = bound(amount, 1e18, maxMint);

        try collateralManager.mintSyntheticAsset(synAsset, amount) {
            ghost_totalMinted += amount;
        } catch {}
    }

    function burnSyntheticAsset(
        uint256 actorSeed,
        uint256 synAssetSeed,
        uint256 amount
    ) external useActor(actorSeed) countCall("burnSyntheticAsset") {
        address synAsset = syntheticAssets[
            synAssetSeed % syntheticAssets.length
        ];

        uint256 balance = IERC20(synAsset).balanceOf(currentActor);
        if (balance == 0) return;

        amount = bound(amount, 1, balance);

        // Approve if not sUSD (for swap path)
        if (synAsset != address(susd)) {
            IERC20(synAsset).approve(address(collateralManager), amount);
        }

        try collateralManager.burnSyntheticAsset(synAsset, amount) {
            ghost_totalBurned += amount;
        } catch {}
    }

    function exchangeSynAsset(
        uint256 actorSeed,
        uint256 fromSeed,
        uint256 toSeed,
        uint256 amount
    ) external useActor(actorSeed) countCall("exchangeSynAsset") {
        address fromAsset = syntheticAssets[fromSeed % syntheticAssets.length];
        address toAsset = syntheticAssets[toSeed % syntheticAssets.length];

        if (fromAsset == toAsset) return;

        uint256 balance = IERC20(fromAsset).balanceOf(currentActor);
        if (balance < 1e15) return; // Skip if balance is too small

        amount = bound(amount, 1e15, balance);

        IERC20(fromAsset).approve(address(exchanger), amount);

        uint256 rewardIndexBefore = debtPool.getGlobalAccRewardIndex();

        try
            exchanger.exchangeSynAssetExactInput(
                fromAsset,
                toAsset,
                amount,
                currentActor
            )
        {
            uint256 rewardIndexAfter = debtPool.getGlobalAccRewardIndex();
            ghost_totalExchangeFees += rewardIndexAfter - rewardIndexBefore;
            ghost_lastGlobalRewardIndex = rewardIndexAfter;
        } catch {}
    }

    function claimRewards(
        uint256 actorSeed
    ) external useActor(actorSeed) countCall("claimRewards") {
        uint256 pendingBefore = debtPool.getUserPendingRewards(currentActor);

        try debtPool.claimRewards() returns (uint256 claimed) {
            ghost_totalRewardsClaimed += claimed;
        } catch {}
    }

    function liquidate(
        uint256 actorSeed,
        uint256 targetSeed,
        uint256 amount
    ) external useActor(actorSeed) countCall("liquidate") {
        // Select a different actor as target (avoid overflow with modulo)
        uint256 targetIndex = (targetSeed % actors.length);
        uint256 liquidatorIndex = (actorSeed % actors.length);
        if (targetIndex == liquidatorIndex) {
            targetIndex = (targetIndex + 1) % actors.length;
        }
        address target = actors[targetIndex];
        if (target == currentActor) return;

        // Check if target is liquidatable
        uint256 targetDebt = debtPool.getUserDebtUSD(target);
        uint256 targetCollateral = collateralManager.getUserCollateralUSD(
            target
        );

        if (targetDebt == 0) return;
        uint256 healthFactor = (targetCollateral * 1e18) / targetDebt;
        if (healthFactor >= 15e17) return; // 150% threshold

        // Liquidator needs sUSD
        uint256 susdBalance = susd.balanceOf(currentActor);
        if (susdBalance < 1e18) return; // Skip if balance is too small

        amount = bound(amount, 1e18, susdBalance);

        try collateralManager.liquidate(target, amount) {
            // Liquidation successful
        } catch {}
    }

    function mockPriceDrop(
        uint256 assetSeed,
        uint256 dropPercent
    ) external countCall("mockPriceDrop") {
        // Select which asset's price to drop (collateral assets)
        uint256 assetIndex = assetSeed % collateralAssets.length;
        address asset = collateralAssets[assetIndex];

        // Bound drop percent: 10% to 50% (less aggressive to avoid extreme scenarios)
        dropPercent = bound(dropPercent, 10, 50);

        // Get the corresponding mock feed and apply price drop
        MockAggregator feed;
        int256 minPrice;
        if (asset == address(wbtc)) {
            feed = btcFeed;
            minPrice = 10000e8; // BTC minimum $10,000
        } else if (asset == address(weth)) {
            feed = ethFeed;
            minPrice = 500e8; // ETH minimum $500
        } else {
            feed = usdcFeed;
            minPrice = int256(0.5e8); // USDC minimum $0.50
        }

        // Get current price from oracle and calculate new price
        int256 currentPrice = priceOracle.getPrice(asset);
        int256 newPrice = (currentPrice * int256(100 - dropPercent)) / 100;

        // Ensure price doesn't drop below reasonable floor
        if (newPrice < minPrice) {
            newPrice = minPrice;
        }

        // Apply the price drop to the mock feed
        feed.setPrice(newPrice);
        ghost_priceDropCount++;
    }

    // ============ Helper Functions ============

    function _fundActor(address actor) internal {
        wbtc.mint(actor, 10e8); // 10 BTC
        weth.mint(actor, 100e18); // 100 ETH
        usdc.mint(actor, 100_000e6); // 100,000 USDC
    }

    function getActorCount() external view returns (uint256) {
        return actors.length;
    }

    function getActor(uint256 index) external view returns (address) {
        return actors[index % actors.length];
    }

    function callSummary() external view {
        console.log("=== Call Summary ===");
        console.log("depositCollateral:", calls["depositCollateral"]);
        console.log("withdrawCollateral:", calls["withdrawCollateral"]);
        console.log("mintSyntheticAsset:", calls["mintSyntheticAsset"]);
        console.log("burnSyntheticAsset:", calls["burnSyntheticAsset"]);
        console.log("exchangeSynAsset:", calls["exchangeSynAsset"]);
        console.log("claimRewards:", calls["claimRewards"]);
        console.log("liquidate:", calls["liquidate"]);
        console.log("mockPriceDrop:", calls["mockPriceDrop"]);
        console.log("ghost_priceDropCount:", ghost_priceDropCount);
    }
}
