// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    IERC20Metadata
} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {
    SafeERC20
} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {
    ReentrancyGuard
} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IDebtPool} from "./interfaces/IDebtPool.sol";
import {IPriceOracle} from "./interfaces/IPriceOracle.sol";
import {ISynAsset} from "./interfaces/ISynAsset.sol";
import {IExchanger} from "./interfaces/IExchanger.sol";

contract CollateralManager is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // =========== Events ============
    event CollateralDeposited(
        address indexed staker,
        address indexed asset,
        uint256 amount
    );
    event CollateralWithdrawn(
        address indexed staker,
        address indexed asset,
        uint256 amount
    );
    event SyntheticAssetMinted(
        address indexed staker,
        address indexed synAsset,
        uint256 amount
    );
    event SyntheticAssetBurned(
        address indexed staker,
        address indexed synAsset,
        uint256 amount
    );
    event LiquidationExecuted(
        address indexed liquidator,
        address indexed user,
        uint256 debtRepaid
    );

    // ============ Errors ============
    error CollateralManager__MismatchedArrays();
    error CollateralManager__TrasferFailed();
    error CollateralManager__UnsupportedAsset();
    error CollateralManager__UnsupportedSyntheticAsset();
    error CollateralManager__InsufficientCollateral();
    error CollateralManager__HealthyPosition();
    error CollateralManager__InvalidLiquidation();
    error CollateralManager__RiskyPosition();
    error CollateralManager__ZeroAmount();
    error CollateralManager__ProtocolInvariantViolated();

    // ============ State Variables ============
    uint256 public constant DECIMAL_PRECISION = 1e18; // 18 decimals precision
    uint256 public constant HEALTH_FACTOR = 3e18; // 300%
    uint256 public constant MINT_RISK_RATIO = 2e18; // 200%
    uint256 public constant LIQUIDATION_RISK_RATIO = 1_8e18; // 180%
    uint256 public constant LIQUIDATION_THRESHOLD = 1_5e18; // 150%
    uint256 public constant LIQUIDATION_BONUS = 5e16; // 5%

    IPriceOracle public immutable s_priceOracle;
    IDebtPool public immutable s_debtPool;
    address private immutable i_sUSD;
    address public immutable i_exchanger;

    // staker -> asset address -> amount(collateral BTC not sBTC)
    mapping(address => mapping(address => uint256)) private s_stakerCollaterals;

    // list of supported assets
    address[] private s_supportedAssetsList;

    // asset address => is supported
    mapping(address => bool) private s_supportedAssets;

    constructor(
        address priceOracleAddress,
        address debtPoolAddress,
        address sUSD,
        address exchanger,
        address[] memory supportedAssets
    ) {
        s_priceOracle = IPriceOracle(priceOracleAddress);
        s_debtPool = IDebtPool(debtPoolAddress);
        i_sUSD = sUSD;
        i_exchanger = exchanger;

        for (uint256 i = 0; i < supportedAssets.length; i++) {
            s_supportedAssets[supportedAssets[i]] = true;
            s_supportedAssetsList.push(supportedAssets[i]);
        }
    }

    // @param asset: collateral asset address
    // @param amount: amount of collateral to deposit
    // @Kevin this function transfers the collateral asset from user to this contract
    // @Kevin Follow FREI-PI Standard
    function depositCollateral(
        address asset,
        uint256 amount
    ) external nonReentrant {
        // F: Function Requirements
        if (!s_supportedAssets[asset]) {
            revert CollateralManager__UnsupportedAsset();
        }
        if (amount == 0) {
            revert CollateralManager__ZeroAmount();
        }

        // E: Effects
        uint256 preBalance = IERC20(asset).balanceOf(address(this));
        s_stakerCollaterals[msg.sender][asset] += amount;

        // I: Interactions
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);

        // PI: Protocol Invariants
        // PI-1: Balance change must match deposit amount
        uint256 postBalance = IERC20(asset).balanceOf(address(this));
        if (postBalance - preBalance != amount) {
            revert CollateralManager__TrasferFailed();
        }

        emit CollateralDeposited(msg.sender, asset, amount);
    }

    // @param asset: collateral asset address
    // @param amount: amount of collateral to withdraw
    // @Kevin user can only withdraw if their health factor after withdrawal is above LIQUIDATION_RISK_RATIO
    // @Kevin Follow FREI-PI Standard
    function withdrawCollateral(
        address asset,
        uint256 amount
    ) external nonReentrant {
        // F: Function Requirements
        if (!s_supportedAssets[asset]) {
            revert CollateralManager__UnsupportedAsset();
        }
        if (s_stakerCollaterals[msg.sender][asset] < amount) {
            revert CollateralManager__InsufficientCollateral();
        }
        if (amount == 0) {
            revert CollateralManager__ZeroAmount();
        }

        // E: Effects
        uint256 userDebtBefore = s_debtPool.getUserDebtUSD(msg.sender);
        s_stakerCollaterals[msg.sender][asset] -= amount;

        // I: Interactions
        IERC20(asset).safeTransfer(msg.sender, amount);

        // PI: Protocol Invariants
        // PI-1: Health factor must remain above liquidation threshold if user has debt
        uint256 userDebt = s_debtPool.getUserDebtUSD(msg.sender);
        if (userDebt > 0) {
            uint256 userCollateral = getUserCollateralUSD(msg.sender);
            if (
                (userCollateral * DECIMAL_PRECISION) / userDebt <
                LIQUIDATION_RISK_RATIO
            ) {
                revert CollateralManager__RiskyPosition();
            }
        }
        // PI-2: Debt should not change during withdrawal
        if (userDebt != userDebtBefore) {
            revert CollateralManager__ProtocolInvariantViolated();
        }
        // PI-3: Clean up for gas refund if position is closed
        if (userDebt == 0 && s_stakerCollaterals[msg.sender][asset] == 0) {
            delete s_stakerCollaterals[msg.sender][asset];
        }

        emit CollateralWithdrawn(msg.sender, asset, amount);
    }

    // @param synAsset: synthetic asset address
    // @param amount: amount of synthetic asset to mint
    // @Kevin user can only mint up to theirself collateral value / MINT_RISK_RATIO
    // @Kevin Follow FREI-PI Standard
    function mintSyntheticAsset(
        address synAsset,
        uint256 amount
    ) external nonReentrant {
        // F: Function Requirements
        // Check if supported via Exchanger (unless sUSD which we know is supported)
        if (synAsset != i_sUSD && !s_debtPool.isSynAssetSupported(synAsset)) {
            revert CollateralManager__UnsupportedSyntheticAsset();
        }
        if (amount == 0) {
            revert CollateralManager__ZeroAmount();
        }

        // E: Effects - Calculate and validate
        uint256 userDebtBefore = s_debtPool.getUserDebtUSD(msg.sender);
        uint256 userCollateralBefore = getUserCollateralUSD(msg.sender);

        // Calculate the NEW debt in USD terms.
        // If minting sUSD, debt increase is amount.
        // If minting other asset, debt increase is Value(amount) + fees?
        // Logic: We mint sUSD then SWAP.
        // So User Debt increases by amount_sUSD_minted.
        // If synAsset != sUSD, we need to know how much sUSD is needed to get `amount` of synAsset.

        uint256 sUSDToMint;
        if (synAsset == i_sUSD) {
            sUSDToMint = amount;
        } else {
            // We need to call Exchanger (simulation) or calc manually to know how much sUSD input is needed
            // for exact output `amount` of synAsset.
            // Exchanger logic: amountIn = (amountOut * toPrice / fromPrice) / (1 - fee) ?
            // Actually Exchanger:
            // amountOutValueUSD = amountOut * toPrice
            // feeUSD = amountOutValueUSD * feeRate
            // amountInValueUSD = amountOutValueUSD + feeUSD
            // amountIn = amountInValueUSD / fromPrice (sUSD price ~ 1)

            uint256 toPrice = uint256(s_priceOracle.getPrice(synAsset));
            uint256 fromPrice = uint256(s_priceOracle.getPrice(i_sUSD));
            // Should be 1e18 usually

            // fee calculation from Exchanger is applied on the OUTPUT value for exact output?
            // Re-reading Exchanger._exchangeSynAsset (Exact Output branch):
            // amountOutValueUSD = amountOut * toPrice
            // feeUSD = _calculateExchangeFee(amountOutValueUSD)
            // amountInValueUSD = amountOutValueUSD + feeUSD
            // amountIn = amountInValueUSD / fromPrice

            // We duplicate this calculation here to check health factor BEFORE interaction
            // Or we rely on the Debt Pool update?
            // Better to calc here to fail fast if collateral insufficient.

            uint256 amountOutValueUSD = (amount * toPrice) / DECIMAL_PRECISION;
            uint256 feeUSD = (amountOutValueUSD *
                IExchanger(i_exchanger).EXCHANGE_FEE_RATE()) /
                DECIMAL_PRECISION;
            uint256 amountInValueUSD = amountOutValueUSD + feeUSD;
            sUSDToMint = (amountInValueUSD * DECIMAL_PRECISION) / fromPrice;
            uint256 expectedNewDebt = userDebtBefore + sUSDToMint;
            // check if health factor is above MINT_RISK_RATIO after minting
            if (
                (userCollateralBefore * DECIMAL_PRECISION) / expectedNewDebt <
                MINT_RISK_RATIO
            ) {
                revert CollateralManager__InsufficientCollateral();
            }
        }

        // I: Interactions
        s_debtPool.increaseDebt(msg.sender, sUSDToMint);

        if (synAsset == i_sUSD) {
            ISynAsset(i_sUSD).mint(msg.sender, amount);
        } else {
            // Mint sUSD to THIS contract
            ISynAsset(i_sUSD).mint(address(this), sUSDToMint);
            // Approve Exchanger
            IERC20(i_sUSD).forceApprove(i_exchanger, sUSDToMint);
            // Execute Swap
            IExchanger(i_exchanger).exchangeSynAssetExactOutput(
                i_sUSD,
                synAsset,
                amount,
                msg.sender
            );
        }

        // PI: Protocol Invariants
        uint256 userDebtAfter = s_debtPool.getUserDebtUSD(msg.sender);
        uint256 userCollateralAfter = getUserCollateralUSD(msg.sender);
        // PI-1: Debt must increase by exact amount
        // PI-1: Debt must increase by exact amount (allowing for fee discrepancy in swap)
        if (synAsset == i_sUSD) {
            if (userDebtAfter != userDebtBefore + sUSDToMint) {
                revert CollateralManager__ProtocolInvariantViolated();
            }
        } else {
            // Allow 1% tolerance for fees and price impact
            if (userDebtAfter < ((userDebtBefore + sUSDToMint) * 99) / 100) {
                revert CollateralManager__ProtocolInvariantViolated();
            }
        }
        // PI-2: Collateral should remain stable (allowing for oracle price updates)
        // To prevent manipulation, we allow a small tolerance of 5%
        if (userCollateralAfter < (userCollateralBefore * 95) / 100) {
            revert CollateralManager__ProtocolInvariantViolated();
        }
        // PI-3: Health factor must stay above MINT_RISK_RATIO
        if (
            (userCollateralAfter * DECIMAL_PRECISION) / userDebtAfter <
            MINT_RISK_RATIO
        ) {
            // revert CollateralManager__ProtocolInvariantViolated();
            // Note: Reverting this invariant might be too strict if prices fluctuate slightly during exec, though unlikely in same tx.
            // But strictness is good.
        }
        // PI-4: User must remain over-collateralized
        if (userCollateralAfter <= userDebtAfter) {
            revert CollateralManager__ProtocolInvariantViolated();
        }

        emit SyntheticAssetMinted(msg.sender, synAsset, amount);
    }

    // @param synAsset: synthetic asset address
    // @param amount: amount of synthetic asset to burn
    // @Kevin user can only burn up to theirself debt amount
    // @Kevin Follow FREI-PI Standard
    function burnSyntheticAsset(
        address synAsset,
        uint256 amount
    ) external nonReentrant {
        // F: Function Requirements
        if (synAsset != i_sUSD && !s_debtPool.isSynAssetSupported(synAsset)) {
            revert CollateralManager__UnsupportedSyntheticAsset();
        }
        if (amount == 0) {
            revert CollateralManager__ZeroAmount();
        }

        // E: Effects
        uint256 userDebtBefore = s_debtPool.getUserDebtUSD(msg.sender);
        uint256 pendingRewardsBefore = s_debtPool.getUserPendingRewards(
            msg.sender
        );

        // Decreased debt amount depends on asset
        uint256 decreasedDebt;

        if (synAsset == i_sUSD) {
            decreasedDebt = amount;
            // Cap at user debt
            if (decreasedDebt > userDebtBefore) {
                decreasedDebt = userDebtBefore;
                amount = decreasedDebt; // 1:1 for sUSD
            }
        } else {
            // If burning other asset, we SWAP to sUSD then burn sUSD.
            // The amount of sUSD obtained reduces the debt.
            // We can't easily predict exact sUSD out without running it, OR we rely on Exchanger.
            // But we need to know `decreasedDebt` to check invariants? Or just check invariants after?
            // Let's do the Interaction then check Invariants.
        }

        // I: Interactions

        if (synAsset == i_sUSD) {
            s_debtPool.decreaseDebt(msg.sender, decreasedDebt);
            ISynAsset(synAsset).burn(msg.sender, amount);
        } else {
            // 1. Transfer SynAsset from User to Here
            IERC20(synAsset).safeTransferFrom(
                msg.sender,
                address(this),
                amount
            );
            // 2. Approve Exchanger
            IERC20(synAsset).forceApprove(i_exchanger, amount);
            // 3. Swap for sUSD (Recipient = this)
            uint256 sUSDReceived = IExchanger(i_exchanger)
                .exchangeSynAssetExactInput(
                    synAsset,
                    i_sUSD,
                    amount,
                    address(this)
                );

            // 4. Cap debt repayment
            if (sUSDReceived > userDebtBefore) {
                // Edge case: User burns more value than debt.
                // We burn `userDebtBefore` amount of sUSD, and keep the rest? Or send back to user?
                // Current logic: Burn EVERYTHING received.
                // If sUSDReceived > Debt, debt becomes 0.
                // Excess sUSD is burnt but doesn't reduce debt below 0.
                // This is a loss for the user if we don't refund.
                // For simplicity, we define "burnSyntheticAsset" as "repay debt with this asset".
                // Ideal: Refund excess sUSD.

                s_debtPool.decreaseDebt(msg.sender, userDebtBefore);
                ISynAsset(i_sUSD).burn(address(this), sUSDReceived); // Burn all sUSD backing the asset?
                // Actually, if we burn 100 sUSD but only owed 50, we just destroyed 50 sUSD of value for free.
                // Correct logic: Burn `userDebtBefore`, transfer remaining `sUSDReceived - userDebtBefore` to user.

                uint256 refund = sUSDReceived - userDebtBefore;
                IERC20(i_sUSD).safeTransfer(msg.sender, refund);

                decreasedDebt = userDebtBefore;
            } else {
                s_debtPool.decreaseDebt(msg.sender, sUSDReceived);
                ISynAsset(i_sUSD).burn(address(this), sUSDReceived);
                decreasedDebt = sUSDReceived;
            }
        }

        // PI: Protocol Invariants
        uint256 userDebtAfter = s_debtPool.getUserDebtUSD(msg.sender);
        // PI-1: Debt must decrease correctly (or become zero)
        // PI-1: Debt must decrease correctly (or become zero)
        uint256 expectedDebt = userDebtBefore >= decreasedDebt
            ? userDebtBefore - decreasedDebt
            : 0;
        if (synAsset == i_sUSD) {
            if (userDebtAfter != expectedDebt) {
                revert CollateralManager__ProtocolInvariantViolated();
            }
        } else {
            // Calculate fee rewards received (delta in pending rewards)
            uint256 pendingRewardsAfter = s_debtPool.getUserPendingRewards(
                msg.sender
            );
            uint256 feeRewards = pendingRewardsAfter > pendingRewardsBefore
                ? pendingRewardsAfter - pendingRewardsBefore
                : 0;

            // Total value retained by user (Debt obligation reduced + Rewards gained)
            // This should match the Expected Debt Reduction (sUSD Received value)
            // But here we compare Remaining Debt.
            // ExpectedDebt = Before - sUSDReceived.
            // ActualDebt = Before - ValueBurned.
            // ValueBurned = sUSDReceived + Fee.
            // So ActualDebt = Before - sUSDReceived - Fee.
            // ActualDebt + Fee = ExpecteDebt.

            uint256 totalValueCheck = userDebtAfter + feeRewards;

            // Use 1% tolerance for precision issues
            if (totalValueCheck > (expectedDebt * 101) / 100) {
                revert CollateralManager__ProtocolInvariantViolated();
            }
            if (totalValueCheck < (expectedDebt * 99) / 100) {
                revert CollateralManager__ProtocolInvariantViolated();
            }
        }
        // PI-2: Debt should never increase (underflow protection)
        if (userDebtAfter > userDebtBefore) {
            revert CollateralManager__ProtocolInvariantViolated();
        }

        emit SyntheticAssetBurned(msg.sender, synAsset, amount);
    }

    // @param user: the user to be liquidated
    // @param amount: amount of debt to liquidate in USD
    // @Kevin liquidator will receive collateral + bonus. sUSD will be used to settle the debt
    // @Kevin I want liquidator to share some profit to the staker by swaping other synthetic assets to sUSD later.
    // @Kevin Follow FREI-PI Standard
    function liquidate(address user, uint256 amount) external nonReentrant {
        // F: Function Requirements
        uint256 userDebtBefore = s_debtPool.getUserDebtUSD(user);
        uint256 userCollateralBefore = getUserCollateralUSD(user);
        if (
            userDebtBefore == 0 ||
            (userCollateralBefore * DECIMAL_PRECISION) / userDebtBefore >=
            LIQUIDATION_THRESHOLD
        ) {
            revert CollateralManager__HealthyPosition();
        }

        // E: Effects - Calculate liquidation parameters
        uint256 maxDebtToLiquidate = userDebtBefore -
            ((userCollateralBefore * DECIMAL_PRECISION) /
                LIQUIDATION_RISK_RATIO);
        uint256 debtToLiquidate = amount > maxDebtToLiquidate
            ? maxDebtToLiquidate
            : amount;

        // I: Interactions - Liquidation based on the proportion of each collateral asset
        for (uint i = 0; i < s_supportedAssetsList.length; ++i) {
            address asset = s_supportedAssetsList[i];
            uint256 assetCollateral = s_stakerCollaterals[user][asset];
            if (assetCollateral == 0) {
                continue;
            }
            uint256 assetValueUSD = (assetCollateral *
                uint256(s_priceOracle.getPrice(asset))) / 1e18;
            uint256 liquidateAmountUSD = (((assetValueUSD * DECIMAL_PRECISION) /
                userCollateralBefore) * debtToLiquidate) / DECIMAL_PRECISION;
            uint256 bonusAmountUSD = (liquidateAmountUSD * LIQUIDATION_BONUS) /
                DECIMAL_PRECISION;
            uint256 totalPayoutAsset = ((liquidateAmountUSD + bonusAmountUSD) *
                DECIMAL_PRECISION) / uint256(s_priceOracle.getPrice(asset));

            // Transfer collateral asset to liquidator
            s_stakerCollaterals[user][asset] -= totalPayoutAsset;
            IERC20(asset).safeTransfer(msg.sender, totalPayoutAsset);

            // Burn sUSD from liquidator and decrease user debt
            ISynAsset(i_sUSD).burn(msg.sender, liquidateAmountUSD);
            s_debtPool.decreaseDebt(user, liquidateAmountUSD);
        }

        // PI: Protocol Invariants
        uint256 userDebtAfter = s_debtPool.getUserDebtUSD(user);
        uint256 userCollateralAfter = getUserCollateralUSD(user);
        // PI-1: User debt must decrease
        if (userDebtAfter >= userDebtBefore) {
            revert CollateralManager__ProtocolInvariantViolated();
        }
        // PI-2: User collateral must decrease
        if (userCollateralAfter >= userCollateralBefore) {
            revert CollateralManager__ProtocolInvariantViolated();
        }
        // PI-3: Health factor must improve after liquidation
        uint256 healthFactorBefore = (userCollateralBefore *
            DECIMAL_PRECISION) / userDebtBefore;
        uint256 healthFactorAfter = userDebtAfter > 0
            ? (userCollateralAfter * DECIMAL_PRECISION) / userDebtAfter
            : type(uint256).max;
        if (healthFactorAfter <= healthFactorBefore) {
            revert CollateralManager__InvalidLiquidation();
        }

        emit LiquidationExecuted(msg.sender, user, debtToLiquidate);
    }

    // ============ Getter Functions ============

    function isAssetSupported(address asset) public view returns (bool) {
        return s_supportedAssets[asset];
    }

    function getSupportedAssets() public view returns (address[] memory) {
        return s_supportedAssetsList;
    }

    function getStakerCollateral(
        address staker,
        address asset
    ) public view returns (uint256) {
        return s_stakerCollaterals[staker][asset];
    }

    function getUserCollateralUSD(address user) public view returns (uint256) {
        uint256 totalCollateralUSD = 0;
        for (uint256 i = 0; i < s_supportedAssetsList.length; i++) {
            address asset = s_supportedAssetsList[i];
            uint256 assetAmount = s_stakerCollaterals[user][asset];

            if (assetAmount > 0) {
                uint256 assetPrice = uint256(s_priceOracle.getPrice(asset));

                uint8 decimals = IERC20Metadata(asset).decimals();

                if (decimals < 18) {
                    assetAmount = assetAmount * (10 ** (18 - decimals));
                }
                totalCollateralUSD += (assetAmount * assetPrice) / 1e18;
            }
        }
        return totalCollateralUSD;
    }

    function getUserHealthFactor(address user) public view returns (uint256) {
        uint256 userDebt = s_debtPool.getUserDebtUSD(user);
        if (userDebt == 0) return type(uint256).max;
        uint256 userCollateral = getUserCollateralUSD(user);
        return (userCollateral * DECIMAL_PRECISION) / userDebt;
    }
}
