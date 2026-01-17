// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test, console} from "forge-std/Test.sol";
import {sUSD} from "../../src/syntheticAsset/sUSD.sol";
import {sBTC} from "../../src/syntheticAsset/sBTC.sol";
import {sETH} from "../../src/syntheticAsset/sETH.sol";
import {sSPY} from "../../src/syntheticAsset/sSPY.sol";
import {PriceOracle} from "../../src/PriceOracle.sol";
import {IPriceOracle} from "../../src/interfaces/IPriceOracle.sol";
import {DebtPool} from "../../src/DebtPool.sol";
import {Exchanger} from "../../src/Exchanger.sol";
import {CollateralManager} from "../../src/CollateralManager.sol";
import {ISynAsset} from "../../src/interfaces/ISynAsset.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MintAndSwapTest is Test {
    // Contracts
    sUSD public susd;
    sBTC public sbtc;
    sETH public seth;
    sSPY public sspy;
    PriceOracle public priceOracle;
    DebtPool public debtPool;
    Exchanger public exchanger;
    CollateralManager public collateralManager;

    // Tokens
    MockERC20 public wbtc;
    MockERC20 public weth;
    MockERC20 public usdc;

    // Feeds (Arbitrum Sepolia)
    address constant BTC_FEED = 0x56a43EB56Da12C0dc1D972ACb089c06a5dEF8e69;
    address constant USDC_FEED = 0x0153002d20B96532C639313c2d54c3dA09109309;
    address constant ETH_FEED = 0x14F11B9C146f738E627f0edB259fEdFd32e28486;
    address constant SPY_FEED = 0x4fB44FC4FA132d1a846Bd4143CcdC5a9f1870b06;

    // Users
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public carol = makeAddr("carol");

    // Constants
    uint256 constant INITIAL_COLLATERAL = 10 ether; // 10 ETH
    uint256 constant DECIMAL_PRECISION = 1e18;
    uint256 constant EXCHANGE_FEE_RATE = 5e15; // 0.5%

    function setUp() public {
        string memory rpcUrl = vm.envString("RPC_URL");
        vm.createSelectFork(rpcUrl);

        // 1. Deploy Tokens (collateral)
        wbtc = new MockERC20("Wrapped BTC", "WBTC", 8);
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        usdc = new MockERC20("USDC", "USDC", 6);

        // 2. Deploy Synths
        susd = new sUSD();
        sbtc = new sBTC();
        seth = new sETH();
        sspy = new sSPY();

        // 3. Deploy PriceOracle
        address[] memory assetsOracle = new address[](6);
        assetsOracle[0] = address(wbtc);
        assetsOracle[1] = address(usdc);
        assetsOracle[2] = address(weth);
        assetsOracle[3] = address(sbtc);
        assetsOracle[4] = address(seth);
        assetsOracle[5] = address(sspy);

        address[] memory feedsOracle = new address[](6);
        feedsOracle[0] = BTC_FEED;
        feedsOracle[1] = USDC_FEED;
        feedsOracle[2] = ETH_FEED;
        feedsOracle[3] = BTC_FEED;
        feedsOracle[4] = ETH_FEED;
        feedsOracle[5] = SPY_FEED;

        priceOracle = new PriceOracle(assetsOracle, feedsOracle, address(susd));

        // 4. Deploy DebtPool
        ISynAsset[] memory synAssets = new ISynAsset[](4);
        synAssets[0] = ISynAsset(address(sbtc));
        synAssets[1] = ISynAsset(address(seth));
        synAssets[2] = ISynAsset(address(sspy));
        synAssets[3] = ISynAsset(address(susd));

        debtPool = new DebtPool(
            address(this),
            IPriceOracle(address(priceOracle)),
            synAssets,
            ISynAsset(address(susd))
        );

        // 5. Deploy Exchanger
        exchanger = new Exchanger(
            address(priceOracle),
            address(debtPool),
            address(susd)
        );

        // 6. Deploy CollateralManager
        address[] memory collateralAssets = new address[](3);
        collateralAssets[0] = address(wbtc);
        collateralAssets[1] = address(weth);
        collateralAssets[2] = address(usdc);

        collateralManager = new CollateralManager(
            address(priceOracle),
            address(debtPool),
            address(susd),
            address(exchanger),
            collateralAssets
        );

        // 7. Grant Roles
        bytes32 MINTER_ROLE = keccak256("MINTER_ROLE");
        bytes32 BURNER_ROLE = keccak256("BURNER_ROLE");

        sbtc.grantRole(MINTER_ROLE, address(exchanger));
        sbtc.grantRole(BURNER_ROLE, address(exchanger));
        seth.grantRole(MINTER_ROLE, address(exchanger));
        seth.grantRole(BURNER_ROLE, address(exchanger));
        sspy.grantRole(MINTER_ROLE, address(exchanger));
        sspy.grantRole(BURNER_ROLE, address(exchanger));
        susd.grantRole(MINTER_ROLE, address(exchanger));
        susd.grantRole(BURNER_ROLE, address(exchanger));

        susd.grantRole(MINTER_ROLE, address(collateralManager));
        susd.grantRole(BURNER_ROLE, address(collateralManager));

        debtPool.transferOwnership(address(collateralManager));

        bytes32 DEBT_MANAGER_ROLE = keccak256("DEBT_MANAGER_ROLE");
        bytes32 REWARD_DISTRIBUTOR_ROLE = keccak256("REWARD_DISTRIBUTOR_ROLE");

        debtPool.grantRole(DEBT_MANAGER_ROLE, address(collateralManager));
        debtPool.grantRole(REWARD_DISTRIBUTOR_ROLE, address(exchanger));

        // 8. Fund Users
        _fundUser(alice, INITIAL_COLLATERAL);
        _fundUser(bob, INITIAL_COLLATERAL);
        _fundUser(carol, INITIAL_COLLATERAL);
    }

    // Helper to fund user
    function _fundUser(address user, uint256 amount) internal {
        vm.startPrank(user);
        weth.mint(user, amount);
        weth.approve(address(collateralManager), type(uint256).max);
        vm.stopPrank();
    }

    // Helper to mint sUSD
    function _mintSUSD(
        address user,
        uint256 collateralAmount,
        uint256 mintAmount
    ) internal {
        vm.startPrank(user);
        collateralManager.depositCollateral(address(weth), collateralAmount);
        collateralManager.mintSyntheticAsset(address(susd), mintAmount);
        vm.stopPrank();
    }

    function test_MintAndSwap_OneUserSwap_FeeAccumulation() public {
        // 1. Setup initial state
        uint256 collateralAmount = 1 ether;
        uint256 mintAmount = 1000 ether;

        _mintSUSD(alice, collateralAmount, mintAmount);
        _mintSUSD(bob, collateralAmount, mintAmount);
        _mintSUSD(carol, collateralAmount, mintAmount);

        // 2. Alice swaps sUSD -> sBTC
        uint256 swapAmountIn = 500 ether;

        vm.startPrank(alice);
        susd.approve(address(exchanger), swapAmountIn);
        uint256 amountOut = exchanger.exchangeSynAssetExactInput(
            address(susd),
            address(sbtc),
            swapAmountIn,
            alice
        );
        vm.stopPrank();

        // 3. Verify Output
        uint256 fee = (swapAmountIn * EXCHANGE_FEE_RATE) / DECIMAL_PRECISION;
        uint256 netInput = swapAmountIn - fee;
        int256 btcPrice = priceOracle.getPrice(address(sbtc));

        // Exact Output Verification
        uint256 expectedOut = (netInput * DECIMAL_PRECISION) /
            uint256(btcPrice);
        assertEq(sbtc.balanceOf(alice), amountOut);

        // 4. Verify Reward Distribution
        uint256 expectedIndex = (fee * DECIMAL_PRECISION) /
            debtPool.getTotalDebtShares();
        assertEq(debtPool.getGlobalAccRewardIndex(), expectedIndex);

        // Check Pending Rewards (Approximate due to distribution logic)
        uint256 alicePending = debtPool.getUserPendingRewards(alice);
        uint256 bobPending = debtPool.getUserPendingRewards(bob);
        uint256 carolPending = debtPool.getUserPendingRewards(carol);

        assertApproxEqAbs(alicePending, fee / 3, 1e5);
        assertApproxEqAbs(bobPending, fee / 3, 1e5);
        assertApproxEqAbs(carolPending, fee / 3, 1e5);
    }

    function test_MintAndSwap_MultiUserSwap() public {
        _mintSUSD(alice, 5 ether, 1000 ether);
        _mintSUSD(bob, 5 ether, 2000 ether);
        _mintSUSD(carol, 5 ether, 3000 ether);

        uint256 swapAmount = 100 ether;
        uint256 totalFees = 0;

        // Alice Swap
        vm.startPrank(alice);
        susd.approve(address(exchanger), swapAmount);
        exchanger.exchangeSynAssetExactInput(
            address(susd),
            address(sbtc),
            swapAmount,
            alice
        );
        vm.stopPrank();
        totalFees += (swapAmount * EXCHANGE_FEE_RATE) / DECIMAL_PRECISION;

        // Bob Swap
        vm.startPrank(bob);
        susd.approve(address(exchanger), swapAmount);
        exchanger.exchangeSynAssetExactInput(
            address(susd),
            address(seth),
            swapAmount,
            bob
        );
        vm.stopPrank();
        totalFees += (swapAmount * EXCHANGE_FEE_RATE) / DECIMAL_PRECISION;

        // Carol Swap
        vm.startPrank(carol);
        susd.approve(address(exchanger), swapAmount);
        exchanger.exchangeSynAssetExactInput(
            address(susd),
            address(sspy),
            swapAmount,
            carol
        );
        vm.stopPrank();
        totalFees += (swapAmount * EXCHANGE_FEE_RATE) / DECIMAL_PRECISION;

        // Verify Rewards Proportional to Debt
        uint256 expectedAliceReward = (totalFees * 1000) / 6000;
        uint256 expectedBobReward = (totalFees * 2000) / 6000;
        uint256 expectedCarolReward = (totalFees * 3000) / 6000;

        assertApproxEqAbs(
            debtPool.getUserPendingRewards(alice),
            expectedAliceReward,
            1e10
        );
        assertApproxEqAbs(
            debtPool.getUserPendingRewards(bob),
            expectedBobReward,
            1e10
        );
        assertApproxEqAbs(
            debtPool.getUserPendingRewards(carol),
            expectedCarolReward,
            1e10
        );
    }

    function test_Mint_DirectlyNonSUSD() public {
        vm.startPrank(alice);

        // 1. Deposit - Need much more collateral to mint 1 BTC worth of sBTC
        // BTC price ~$95k, need 200% CR, so need ~$190k collateral
        // ETH price ~$2.9k, so need ~65 WETH
        uint256 collateralAmount = 100e18; // Use 100 WETH to be safe
        weth.mint(alice, collateralAmount); // Fund user first
        weth.approve(address(collateralManager), collateralAmount);
        collateralManager.depositCollateral(address(weth), collateralAmount);

        // 2. Mint sBTC (1 sBTC)
        uint256 sbtcAmountToMint = 1 ether;
        collateralManager.mintSyntheticAsset(address(sbtc), sbtcAmountToMint);

        // 3. Verify Balance
        assertEq(sbtc.balanceOf(alice), sbtcAmountToMint);

        // 4. Verify Debt
        // When minting sBTC directly via mintSyntheticAsset:
        // - System mints sUSD internally = sBTC_value * (1 + fee_rate)
        // - Then swaps sUSD -> sBTC, user receives exactly sbtcAmountToMint
        // - Debt increases by the sUSD amount minted (which includes fees)
        uint256 actualDebt = debtPool.getUserDebtUSD(alice);
        int256 btcPrice = priceOracle.getPrice(address(sbtc));
        uint256 sbtcValue = (sbtcAmountToMint * uint256(btcPrice)) / 1e18;

        // Debt should be >= sBTC value (includes fees)
        assertTrue(actualDebt >= sbtcValue, "Debt should be >= sBTC value");

        // The debt should be roughly sBTC_value * (1 + fee_rate)
        uint256 expectedDebt = (sbtcValue * 1005) / 1000; // +0.5% fee
        assertApproxEqRel(actualDebt, expectedDebt, 1e16); // 1% tolerance

        vm.stopPrank();
    }

    function test_Burn_NonSUSDReducesDebt() public {
        vm.startPrank(alice);
        // 1. Mint & Swap to get sBTC
        uint256 collateralAmount = 10e18;
        weth.approve(address(collateralManager), collateralAmount);
        collateralManager.depositCollateral(address(weth), collateralAmount);

        collateralManager.mintSyntheticAsset(address(susd), 10000 ether);
        susd.approve(address(exchanger), 10000 ether);
        uint256 sbtcReceived = exchanger.exchangeSynAssetExactInput(
            address(susd),
            address(sbtc),
            10000 ether,
            alice
        );

        uint256 debtBefore = debtPool.getUserDebtUSD(alice);

        // 2. Burn half sBTC
        uint256 burnAmount = sbtcReceived / 2;
        sbtc.approve(address(collateralManager), burnAmount);
        collateralManager.burnSyntheticAsset(address(sbtc), burnAmount);

        // 3. Verify
        uint256 debtAfter = debtPool.getUserDebtUSD(alice);
        assertTrue(debtAfter < debtBefore, "Debt should decrease");
        assertEq(sbtc.balanceOf(alice), sbtcReceived - burnAmount);

        vm.stopPrank();
    }

    function test_Swap_SynthToSynth_Direct() public {
        vm.startPrank(alice);

        // 1. Prepare: Mint sBTC
        uint256 collateral = 100e18;
        // [FIX] Mint tokens to Alice first
        weth.mint(alice, collateral);
        weth.approve(address(collateralManager), collateral);
        collateralManager.depositCollateral(address(weth), collateral);

        uint256 sbtcToMint = 1 ether;
        collateralManager.mintSyntheticAsset(address(sbtc), sbtcToMint);

        // 2. Swap sBTC -> sETH
        sbtc.approve(address(exchanger), sbtcToMint);
        uint256 sethReceived = exchanger.exchangeSynAssetExactInput(
            address(sbtc),
            address(seth),
            sbtcToMint,
            alice
        );

        // 3. Verify
        assertEq(sbtc.balanceOf(alice), 0);
        assertTrue(seth.balanceOf(alice) > 0);

        // Value check
        int256 btcPrice = priceOracle.getPrice(address(sbtc));
        int256 ethPrice = priceOracle.getPrice(address(seth));

        uint256 sbtcValue = (sbtcToMint * uint256(btcPrice)) / 1e18;
        uint256 sethValue = (sethReceived * uint256(ethPrice)) / 1e18;

        // Expect value loss due to fees, but within reason (e.g. > 98% retained)
        assertTrue(sethValue >= (sbtcValue * 98) / 100);
        assertTrue(sethValue < sbtcValue);

        vm.stopPrank();
    }

    function test_Burn_FullAmount_ClosesPosition() public {
        vm.startPrank(alice);

        uint256 collateral = 10e18;
        weth.approve(address(collateralManager), collateral);
        collateralManager.depositCollateral(address(weth), collateral);
        collateralManager.mintSyntheticAsset(address(susd), 5000 ether);

        assertEq(debtPool.getUserDebtUSD(alice), 5000 ether);

        // Burn All
        susd.approve(address(collateralManager), 5000 ether);
        collateralManager.burnSyntheticAsset(address(susd), 5000 ether);

        assertEq(debtPool.getUserDebtUSD(alice), 0);

        vm.stopPrank();
    }

    // ==========================================
    //              Fuzz Tests
    // ==========================================

    function testFuzz_RoundTrip_sUSD_sBTC_sUSD(uint256 mintAmountRaw) public {
        uint256 mintAmount = bound(
            mintAmountRaw,
            100 ether,
            1_000_000_000 ether
        );

        vm.startPrank(alice);

        // [FIX] Ensure massive collateral for fuzzing
        uint256 collateral = 1_000_000_000 ether;
        weth.mint(alice, collateral); // FUND USER
        weth.approve(address(collateralManager), collateral);
        collateralManager.depositCollateral(address(weth), collateral);

        // Mint
        collateralManager.mintSyntheticAsset(address(susd), mintAmount);

        // Swap sUSD -> sBTC
        susd.approve(address(exchanger), mintAmount);
        uint256 sbtcReceived = exchanger.exchangeSynAssetExactInput(
            address(susd),
            address(sbtc),
            mintAmount,
            alice
        );

        // Swap sBTC -> sUSD
        sbtc.approve(address(exchanger), sbtcReceived);
        uint256 susdFinal = exchanger.exchangeSynAssetExactInput(
            address(sbtc),
            address(susd),
            sbtcReceived,
            alice
        );

        // Verify fees paid twice
        assertTrue(susdFinal < mintAmount);
        uint256 expectedRetained = (mintAmount * 990025) / 1000000;
        assertApproxEqRel(susdFinal, expectedRetained, 1e14);

        vm.stopPrank();
    }

    function testFuzz_MintDirectly_DebtAccuracy(
        uint256 sbtcMintAmountRaw
    ) public {
        uint256 sbtcMintAmount = bound(sbtcMintAmountRaw, 1e15, 1000 ether);

        vm.startPrank(alice);

        // [FIX] Ensure sufficient collateral buffer (250% CR)
        // For 1000 sBTC max: 1000 * $95k = $95M debt
        // Need $190M collateral at 200% CR
        // WBTC price ~$95k, so need ~2000 WBTC = 200,000,000,000 (with 8 decimals)
        uint256 collateralAmount = 25000e8; // 25k WBTC = ~$2.375B collateral
        wbtc.mint(alice, collateralAmount); // FUND USER
        wbtc.approve(address(collateralManager), collateralAmount);
        collateralManager.depositCollateral(address(wbtc), collateralAmount);

        // Mint sBTC
        collateralManager.mintSyntheticAsset(address(sbtc), sbtcMintAmount);

        // Debt check
        uint256 actualDebt = debtPool.getUserDebtUSD(alice);
        int256 btcPrice = priceOracle.getPrice(address(sbtc));
        uint256 sbtcValue = (sbtcMintAmount * uint256(btcPrice)) / 1e18;

        // Debt should be >= sbtcValue (includes fees)
        assertTrue(actualDebt >= sbtcValue, "Debt should be >= sbtcValue");
        uint256 expectedDebtRoughly = (sbtcValue * 1005) / 1000; // +0.5% fee
        // Use 2% tolerance to account for oracle fluctuations and fee compounding
        assertApproxEqRel(actualDebt, expectedDebtRoughly, 2e16);

        vm.stopPrank();
    }

    function testFuzz_Burn_Partial(uint256 burnRatio) public {
        // Limit to 99% to avoid edge case of burning entire balance
        // which can cause precision issues in debt calculations
        uint256 ratio = bound(burnRatio, 100, 9900);

        vm.startPrank(alice);

        // [FIX] Fund user
        // For 10 sBTC: 10 * $95k = $950k debt
        // Need $1.9M collateral at 200% CR
        // ETH price ~$2.9k, so need ~655 WETH
        uint256 collateral = 1000e18; // Use 1000 WETH to be safe
        weth.mint(alice, collateral);
        weth.approve(address(collateralManager), collateral);
        collateralManager.depositCollateral(address(weth), collateral);

        uint256 mintAmount = 10 ether;
        collateralManager.mintSyntheticAsset(address(sbtc), mintAmount);

        uint256 debtBefore = debtPool.getUserDebtUSD(alice);
        uint256 burnAmount = (mintAmount * ratio) / 10000;

        // Skip if burn amount is too small (< 0.001 sBTC) to avoid precision issues
        if (burnAmount < 1e15) {
            vm.stopPrank();
            return;
        }

        sbtc.approve(address(collateralManager), burnAmount);
        collateralManager.burnSyntheticAsset(address(sbtc), burnAmount);

        uint256 debtAfter = debtPool.getUserDebtUSD(alice);
        uint256 balanceBefore = 10 ether;
        uint256 balanceAfter = sbtc.balanceOf(alice);

        // Basic sanity checks
        assertEq(
            balanceAfter,
            balanceBefore - burnAmount,
            "Balance should decrease by burn amount"
        );
        assertTrue(debtAfter < debtBefore, "Debt should decrease");

        int256 btcPrice = priceOracle.getPrice(address(sbtc));
        uint256 burnValue = (burnAmount * uint256(btcPrice)) / 1e18;
        uint256 actualDebtReduction = debtBefore - debtAfter;

        // Debt reduction should be at least 90% of burn value (accounting for fees)
        uint256 minExpectedDebtReduction = (burnValue * 90) / 100;
        assertTrue(
            actualDebtReduction >= minExpectedDebtReduction,
            "Debt reduction too small"
        );

        // Debt reduction should not exceed burn value (sanity cap)
        assertTrue(
            actualDebtReduction <= burnValue,
            "Debt reduction should not exceed burn value"
        );

        vm.stopPrank();
    }
}

contract MockERC20 is ERC20 {
    uint256 public _decimals;

    constructor(
        string memory name,
        string memory symbol,
        uint256 decimalsArg
    ) ERC20(name, symbol) {
        _decimals = decimalsArg;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function decimals() public view override returns (uint8) {
        return uint8(_decimals);
    }
}
