// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test, console} from "forge-std/Test.sol";
import {PriceOracle} from "../../src/PriceOracle.sol";
import {DebtPool} from "../../src/DebtPool.sol";
import {CollateralManager} from "../../src/CollateralManager.sol";
import {sUSD} from "../../src/syntheticAsset/sUSD.sol";
import {sBTC} from "../../src/syntheticAsset/sBTC.sol";
import {sETH} from "../../src/syntheticAsset/sETH.sol";
import {sSPY} from "../../src/syntheticAsset/sSPY.sol";
import {MockUSDC} from "../../src/MockERC20/MockUSDC.sol";
import {MockWBTC} from "../../src/MockERC20/MockWBTC.sol";
import {MockWETH} from "../../src/MockERC20/MockWETH.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ISynAsset} from "../../src/interfaces/ISynAsset.sol";
import {IPriceOracle} from "../../src/interfaces/IPriceOracle.sol";
import {Exchanger} from "../../src/Exchanger.sol";

contract DepositAndMintTest is Test {
    PriceOracle public priceOracle;
    DebtPool public debtPool;
    CollateralManager public collateralManager;
    sUSD public susd;
    sBTC public sbtc;
    sETH public seth;
    sSPY public sspy;

    // Real Addresses on Arbitrum Sepolia
    address constant BTC_FEED = 0x56a43EB56Da12C0dc1D972ACb089c06a5dEF8e69;
    address constant USDC_FEED = 0x0153002d20B96532C639313c2d54c3dA09109309;
    address constant ETH_FEED = 0x14F11B9C146f738E627f0edB259fEdFd32e28486;
    address constant SPY_FEED = 0x4fB44FC4FA132d1a846Bd4143CcdC5a9f1870b06;

    // Mock tokens for collateral (using addresses from PriceOracleTest for consistency,
    // but in a fork test we should ideally use real tokens or mock them if we don't need real logic)
    // Since we are forking, let's pretend these are the real tokens.
    // For simplicity in this test, we will deploy mock ERC20s to represent them
    // so we can mint to ourselves effortlessly.
    MockWBTC public btcToken;
    MockUSDC public usdcToken;
    MockWETH public ethToken;

    address public user = makeAddr("user");

    function setUp() public {
        string memory rpcUrl = vm.envString("RPC_URL");
        vm.createSelectFork(rpcUrl);

        // 1. Deploy Mock Tokens
        btcToken = new MockWBTC();
        usdcToken = new MockUSDC();
        ethToken = new MockWETH();

        // 2. Deploy SynAsset
        susd = new sUSD();
        sbtc = new sBTC();
        seth = new sETH();
        sspy = new sSPY();

        // 3. Setup PriceOracle with collateral token addresses
        // Note: sUSD doesn't need to be registered since getPrice returns 1e18 for sUSD
        address[] memory assets = new address[](7);
        assets[0] = address(btcToken);
        assets[1] = address(usdcToken);
        assets[2] = address(ethToken);

        assets[3] = address(sbtc);
        assets[4] = address(seth);
        assets[5] = address(sspy);

        address[] memory feeds = new address[](7);
        feeds[0] = BTC_FEED;
        feeds[1] = USDC_FEED;
        feeds[2] = ETH_FEED;

        feeds[3] = BTC_FEED;
        feeds[4] = ETH_FEED;
        feeds[5] = SPY_FEED;

        priceOracle = new PriceOracle(assets, feeds, address(susd));

        // 4. Deploy DebtPool
        ISynAsset[] memory synAssets = new ISynAsset[](4);
        synAssets[0] = ISynAsset(address(sbtc));
        synAssets[1] = ISynAsset(address(seth));
        synAssets[2] = ISynAsset(address(sspy));
        synAssets[3] = ISynAsset(address(susd));

        debtPool = new DebtPool(
            address(this), // Owner temporarily
            IPriceOracle(address(priceOracle)),
            synAssets,
            ISynAsset(address(susd))
        );

        // 5. Deploy Exchanger (Standalone)
        Exchanger exchanger = new Exchanger(
            address(priceOracle),
            address(debtPool),
            address(susd)
        );

        // 6. Deploy CollateralManager
        address[] memory supportedAssets = new address[](3);
        supportedAssets[0] = address(btcToken);
        supportedAssets[1] = address(usdcToken);
        supportedAssets[2] = address(ethToken);

        collateralManager = new CollateralManager(
            address(priceOracle),
            address(debtPool),
            address(susd),
            address(exchanger),
            supportedAssets
        );

        // 7. Configure Permissions (AccessControl)
        bytes32 MINTER_ROLE = keccak256("MINTER_ROLE");
        bytes32 BURNER_ROLE = keccak256("BURNER_ROLE");

        susd.grantRole(MINTER_ROLE, address(collateralManager));
        susd.grantRole(BURNER_ROLE, address(collateralManager));
        susd.grantRole(MINTER_ROLE, address(exchanger));
        susd.grantRole(BURNER_ROLE, address(exchanger));

        // debtPool transfer ownership to CollateralManager
        debtPool.transferOwnership(address(collateralManager));

        // Grant DebtPool roles
        bytes32 DEBT_MANAGER_ROLE = keccak256("DEBT_MANAGER_ROLE");
        // CollateralManager needs DEBT_MANAGER_ROLE
        debtPool.grantRole(DEBT_MANAGER_ROLE, address(collateralManager));

        // 8. Deal tokens to user (with correct decimals)
        btcToken.mint(user, 10e8); // 10 BTC (8 decimals)
        usdcToken.mint(user, 100_000e6); // 100k USDC (6 decimals)
        ethToken.mint(user, 100e18); // 100 ETH (18 decimals)
    }

    function test_DepositSingleCollateralAndMint() public {
        vm.startPrank(user);

        // 1. Approve and Deposit BTC
        uint256 depositAmount = 1e8; // 1 BTC (8 decimals)
        btcToken.approve(address(collateralManager), depositAmount);
        collateralManager.depositCollateral(address(btcToken), depositAmount);

        // Verify deposit
        uint256 collateralBalance = collateralManager.getStakerCollateral(
            user,
            address(btcToken)
        );
        assertEq(
            collateralBalance,
            depositAmount,
            "Collateral Balance mismatch"
        );

        // 2. Mint sUSD
        // BTC price is approx $98,000 (based on recent data, but oracle will give real price)
        // Let's check oracle price first to be safe
        int256 btcPrice = priceOracle.getPrice(address(btcToken));
        uint256 btcPriceUint = uint256(btcPrice);

        // Max mintable = (Collateral Value / MINT_RISK_RATIO)
        // MINT_RISK_RATIO = 2e18 (200%)
        // Collateral Value = 1 * Price
        // Have been tested the edging case
        uint256 maxMint = (depositAmount * btcPriceUint) / (2e18 + 1);
        uint256 mintAmount = maxMint; // Mint half of max to be safe

        collateralManager.mintSyntheticAsset(address(susd), mintAmount);

        // Verify sUSD balance
        assertEq(susd.balanceOf(user), mintAmount, "sUSD balance mismatch");

        // Verify Debt
        uint256 userDebt = debtPool.getUserDebtUSD(user);
        int256 susdPrice = priceOracle.getPrice(address(susd));
        uint256 expectedDebt = (mintAmount * uint256(susdPrice)) / 1e18;

        console.log("User Debt: ", userDebt);
        console.log("Mint Amount: ", mintAmount);
        assertApproxEqAbs(userDebt, expectedDebt, 100000, "User debt mismatch");

        vm.stopPrank();
    }

    function test_DepositMultiCollateralAndMint() public {
        vm.startPrank(user);

        // 1. Deposit BTC
        uint256 btcAmount = 1e8; // 1 BTC (8 decimals)
        btcToken.approve(address(collateralManager), btcAmount);
        collateralManager.depositCollateral(address(btcToken), btcAmount);

        // 2. Deposit USDC
        uint256 usdcAmount = 50_000e6; // 50k USDC (6 decimals)
        usdcToken.approve(address(collateralManager), usdcAmount);
        collateralManager.depositCollateral(address(usdcToken), usdcAmount);

        // Verify total collateral value
        int256 btcPrice = priceOracle.getPrice(address(btcToken));
        int256 usdcPrice = priceOracle.getPrice(address(usdcToken));

        // Need to normalize to 18 decimals before price calculation
        // BTC: 8 decimals, need to multiply by 1e10
        // USDC: 6 decimals, need to multiply by 1e12
        uint256 expectedValue = ((btcAmount * 1e10 * uint256(btcPrice)) /
            1e18) + ((usdcAmount * 1e12 * uint256(usdcPrice)) / 1e18);

        uint256 actualValue = collateralManager.getUserCollateralUSD(user);

        // Allow small rounding diff
        assertApproxEqAbs(actualValue, expectedValue, 1e18);

        // 3. Mint sUSD
        uint256 maxMint = expectedValue / 2; // 200% CR
        uint256 mintAmount = maxMint / 2;
        collateralManager.mintSyntheticAsset(address(susd), mintAmount);
        console.log("Mint Amount: ", mintAmount);
        console.log("User Debt: ", debtPool.getUserDebtUSD(user));
        assertEq(susd.balanceOf(user), mintAmount);

        vm.stopPrank();
    }

    // ==========================================
    //              Fuzz Tests
    // ==========================================

    /// @notice Test depositing random amounts of collateral and minting, ensuring success within healthy ranges.
    /// @dev Use uint96 to limit input size to prevent uint256 overflow during calculations (even though 1e18 is large, multiplication risks overflow).
    function testFuzz_DepositBTCAndMint_Safe(
        uint96 depositAmountRaw,
        uint96 mintRatioRaw
    ) public {
        vm.startPrank(user);

        // 1. Bound Inputs
        // Collateral amount: from 0.001 BTC to 1,000,000 BTC (8 decimals)
        uint256 depositAmount = bound(depositAmountRaw, 1e5, 1_000_000e8);

        // Mint ratio: from 1% to 99% of the maximum mintable amount (ensure no revert)
        // Note: Ratio base is 10000 (100.00%)
        uint256 ratio = bound(mintRatioRaw, 100, 9900);

        // 2. Ensure user has enough Mock Tokens
        // Mint tokens to user to prevent insufficient balance if fuzzer generates large numbers
        btcToken.mint(user, depositAmount);
        btcToken.approve(address(collateralManager), depositAmount);

        // 3. Execute Deposit
        collateralManager.depositCollateral(address(btcToken), depositAmount);

        // 4. Calculate maximum mintable amount
        int256 btcPrice = priceOracle.getPrice(address(btcToken));
        uint256 collateralValue = (depositAmount * uint256(btcPrice)) / 1e18;

        // 5. Calculate mint amount based on random ratio
        // MINT_RISK_RATIO = 2e18 (200%)
        uint256 maxMint = (collateralValue * 1e18) / 2e18;

        // If collateral is too small causing maxMint to be 0, return early; this is not a failure
        if (maxMint == 0) return;

        uint256 mintAmount = (maxMint * ratio) / 10000;

        if (mintAmount == 0) return; // Avoid minting 0 which causes revert

        // 6. Execute Mint
        collateralManager.mintSyntheticAsset(address(susd), mintAmount);

        // 7. Verify State
        assertEq(susd.balanceOf(user), mintAmount, "sUSD Balance mismatch");

        // Verify debt (allow 0.0001 relative error due to Solidity division truncation)
        uint256 actualDebt = debtPool.getUserDebtUSD(user);
        assertApproxEqRel(
            actualDebt,
            mintAmount,
            1e14,
            "Debt calculation accuracy issue"
        );

        vm.stopPrank();
    }

    /// @notice Test: Must revert if attempting to mint more than the collateral ratio limit.
    function testFuzz_RevertIfMintTooMuch(
        uint96 depositAmountRaw,
        uint96 excessRatioRaw
    ) public {
        vm.startPrank(user);

        // 1. Bound Inputs - Use larger minimum to avoid precision issues
        // Use 0.1 BTC minimum to ensure meaningful collateral value
        uint256 depositAmount = bound(depositAmountRaw, 1e7, 1_000e8); // 0.1 BTC to 1000 BTC (8 decimals)
        // Excess as a percentage of maxMint (10% to 100% over the limit)
        uint256 excessRatio = bound(excessRatioRaw, 1000, 10000); // 10% to 100%

        // 2. Prepare Funds
        btcToken.mint(user, depositAmount);
        btcToken.approve(address(collateralManager), depositAmount);
        collateralManager.depositCollateral(address(btcToken), depositAmount);

        // 3. Calculate Threshold
        int256 btcPrice = priceOracle.getPrice(address(btcToken));
        uint256 collateralValue = (depositAmount * uint256(btcPrice)) / 1e18;
        uint256 maxMint = collateralValue / 2; // 200% CR

        // Skip test if maxMint is too small (less than 100 sUSD to avoid edge cases)
        if (maxMint < 100e18) {
            vm.stopPrank();
            return;
        }

        // 4. Set a mint amount guaranteed to fail (add percentage-based excess)
        uint256 excess = (maxMint * excessRatio) / 10000;
        uint256 invalidMintAmount = maxMint + excess;

        // 5. Expect Revert
        bytes4 selector = bytes4(
            keccak256("CollateralManager__InsufficientCollateral()")
        );
        vm.expectRevert(selector);

        collateralManager.mintSyntheticAsset(address(susd), invalidMintAmount);

        vm.stopPrank();
    }

    /// @notice Complex Scenario: Randomly mix collateral (BTC + ETH + USDC) and mint.
    function testFuzz_MultiCollateralMint(
        uint64 btcAmountRaw,
        uint64 ethAmountRaw,
        uint64 usdcAmountRaw
    ) public {
        vm.startPrank(user);

        // 1. Bound Inputs (Use uint64 to prevent sum overflow, though unlikely)
        uint256 btcAmt = bound(btcAmountRaw, 1e6, 1000e8); // 0.01 BTC to 1000 BTC (8 decimals)
        uint256 ethAmt = bound(ethAmountRaw, 1e16, 10000e18); // 0.01 ETH to 10000 ETH (18 decimals)
        uint256 usdcAmt = bound(usdcAmountRaw, 1e6, 10_000_000e6); // 1 USDC to 10M USDC (6 decimals)

        // 2. Mint tokens & Approve & Deposit
        btcToken.mint(user, btcAmt);
        ethToken.mint(user, ethAmt);
        usdcToken.mint(user, usdcAmt);

        btcToken.approve(address(collateralManager), btcAmt);
        ethToken.approve(address(collateralManager), ethAmt);
        usdcToken.approve(address(collateralManager), usdcAmt);

        collateralManager.depositCollateral(address(btcToken), btcAmt);
        collateralManager.depositCollateral(address(ethToken), ethAmt);
        collateralManager.depositCollateral(address(usdcToken), usdcAmt);

        // 3. Calculate Total Value
        uint256 totalCollateralValue = 0;
        totalCollateralValue +=
            (btcAmt * uint256(priceOracle.getPrice(address(btcToken)))) /
            1e18;
        totalCollateralValue +=
            (ethAmt * uint256(priceOracle.getPrice(address(ethToken)))) /
            1e18;
        totalCollateralValue +=
            (usdcAmt * uint256(priceOracle.getPrice(address(usdcToken)))) /
            1e18;

        // 4. Attempt to mint 40% (safe range)
        uint256 safeMintAmount = (totalCollateralValue * 40) / 100; // Equivalent to 250% CR

        if (safeMintAmount == 0) return;

        collateralManager.mintSyntheticAsset(address(susd), safeMintAmount);

        // 5. Verify
        assertEq(susd.balanceOf(user), safeMintAmount);

        // Verify if the system's debt pool calculation is correct
        assertApproxEqRel(debtPool.getUserDebtUSD(user), safeMintAmount, 1e14);

        vm.stopPrank();
    }
}

contract MockERC20 is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
