//     ▄▄▄▄                                           ▄▄▄▄▄▄                        ▄▄
//   ██▀▀▀▀█                                          ██▀▀▀▀██                      ██                    ██
//  ██▀        ▄████▄   ▄▄█████▄  ████▄██▄   ▄████▄   ██    ██   ▄█████▄  ▄▄█████▄  ██ ▄██▀    ▄████▄   ███████
//  ██        ██▀  ▀██  ██▄▄▄▄ ▀  ██ ██ ██  ██▀  ▀██  ███████    ▀ ▄▄▄██  ██▄▄▄▄ ▀  ██▄██     ██▄▄▄▄██    ██
//  ██▄       ██    ██   ▀▀▀▀██▄  ██ ██ ██  ██    ██  ██    ██  ▄██▀▀▀██   ▀▀▀▀██▄  ██▀██▄    ██▀▀▀▀▀▀    ██
//   ██▄▄▄▄█  ▀██▄▄██▀  █▄▄▄▄▄██  ██ ██ ██  ▀██▄▄██▀  ██▄▄▄▄██  ██▄▄▄███  █▄▄▄▄▄██  ██  ▀█▄   ▀██▄▄▄▄█    ██▄▄▄
//     ▀▀▀▀     ▀▀▀▀     ▀▀▀▀▀▀   ▀▀ ▀▀ ▀▀    ▀▀▀▀    ▀▀▀▀▀▀▀    ▀▀▀▀ ▀▀   ▀▀▀▀▀▀   ▀▀   ▀▀▀    ▀▀▀▀▀      ▀▀▀▀

// Author: Kevin Lee
// Date: 2025-11-06
// Description: Global Shared Debt Pool Contract

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {
    ReentrancyGuard
} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ISynAsset} from "./interfaces/ISynAsset.sol";
import {IPriceOracle} from "./interfaces/IPriceOracle.sol";
import {IDebtPool} from "./interfaces/IDebtPool.sol";

contract DebtPool is ReentrancyGuard, Ownable, AccessControl {
    bytes32 public constant DEBT_MANAGER_ROLE = keccak256("DEBT_MANAGER_ROLE");
    bytes32 public constant REWARD_DISTRIBUTOR_ROLE =
        keccak256("REWARD_DISTRIBUTOR_ROLE");
    // ============ Errors ============
    error DebtPool__InsufficientDebt();
    error DebtPool__ZeroAmount();
    error DebtPool__ZeroTotalDebt();
    error DebtPool__UserNoDebt();
    error DebtPool__NonRewardAccumulation();
    error DebtPool__InvalidPrice();

    // ============ Events ============
    event DebtIncreased(
        address indexed user,
        uint256 amount,
        uint256 newTotalDebt
    );
    event DebtDecreased(
        address indexed user,
        uint256 amount,
        uint256 newTotalDebt
    );
    event RewardsClaimed(address indexed user, uint256 amount);

    // ============ State Variables ============
    uint256 public constant DECIMAL_PRECISION = 1e18;
    // To track each user's debt shares
    mapping(address => uint256) private s_userDebtShares;
    // To track each user's accumulated reward index
    mapping(address => uint256) private s_userRewardIndex;
    // To track pending rewards for each user
    mapping(address => uint256) private s_userPendingRewards;

    uint256 private s_totalDebtShares;
    ISynAsset[] private s_synAssets;
    mapping(address => bool) private s_supportedSynAssets;
    ISynAsset private immutable i_susd;
    IPriceOracle private s_priceOracle;
    uint256 private s_globalAccRewardIndex;

    // ============ Constructor ============

    constructor(
        address owner,
        IPriceOracle priceOracle,
        ISynAsset[] memory synAssets,
        ISynAsset susdAddress
    ) Ownable(owner) {
        s_priceOracle = priceOracle;
        s_synAssets = synAssets;
        for (uint256 i = 0; i < synAssets.length; i++) {
            s_supportedSynAssets[address(synAssets[i])] = true;
        }
        i_susd = susdAddress;
        s_supportedSynAssets[address(susdAddress)] = true;
        _grantRole(DEFAULT_ADMIN_ROLE, owner);
    }

    // ============ Asset Management ============

    function addSynAsset(address asset) external onlyRole(DEBT_MANAGER_ROLE) {
        if (s_supportedSynAssets[asset]) return;
        s_supportedSynAssets[asset] = true;
        s_synAssets.push(ISynAsset(asset));
    }

    function removeSynAsset(
        address asset
    ) external onlyRole(DEBT_MANAGER_ROLE) {
        if (!s_supportedSynAssets[asset]) return;
        s_supportedSynAssets[asset] = false;

        // Remove from array - O(N) but N is small
        for (uint256 i = 0; i < s_synAssets.length; i++) {
            if (address(s_synAssets[i]) == asset) {
                s_synAssets[i] = s_synAssets[s_synAssets.length - 1];
                s_synAssets.pop();
                break;
            }
        }
    }

    // ============ External Functions ============

    function increaseDebt(
        address user,
        uint256 amountUSD
    ) external onlyRole(DEBT_MANAGER_ROLE) nonReentrant {
        if (amountUSD == 0) revert DebtPool__ZeroAmount();

        // First, update user's rewards before changing debt shares
        // We don't want to new debt calculated rewards immediately
        _updateUserRewards(user);

        if (s_totalDebtShares == 0) {
            s_totalDebtShares = amountUSD;
            s_userDebtShares[user] = amountUSD;
        } else {
            uint256 currentTotalDebt = _calculateTotalDebtUSD();
            if (currentTotalDebt == 0) revert DebtPool__ZeroTotalDebt();

            uint256 newShares = (amountUSD * s_totalDebtShares) /
                currentTotalDebt;
            s_totalDebtShares += newShares;
            s_userDebtShares[user] += newShares;
        }

        emit DebtIncreased(user, amountUSD, _calculateTotalDebtUSD());
    }

    function decreaseDebt(
        address user,
        uint256 amountUSD
    ) external onlyRole(DEBT_MANAGER_ROLE) nonReentrant {
        if (amountUSD == 0) revert DebtPool__ZeroAmount();

        // First, update user's rewards before changing debt shares
        _updateUserRewards(user);

        uint256 total_debt_usd = _calculateTotalDebtUSD();
        if (total_debt_usd == 0) revert DebtPool__ZeroTotalDebt();

        uint256 shares_to_burn = (amountUSD * s_totalDebtShares) /
            total_debt_usd;

        if (shares_to_burn > s_userDebtShares[user]) {
            revert DebtPool__InsufficientDebt();
        }

        s_userDebtShares[user] -= shares_to_burn;
        s_totalDebtShares -= shares_to_burn;

        emit DebtDecreased(user, amountUSD, _calculateTotalDebtUSD());
    }

    function distributeRewards(
        uint256 rewardAmountUSD
    ) external onlyRole(REWARD_DISTRIBUTOR_ROLE) nonReentrant {
        if (rewardAmountUSD == 0) {
            revert DebtPool__ZeroAmount();
        }
        if (s_totalDebtShares == 0) {
            revert DebtPool__ZeroTotalDebt();
        }

        // Update global accumulated reward index
        s_globalAccRewardIndex +=
            (rewardAmountUSD * DECIMAL_PRECISION) /
            s_totalDebtShares;
    }

    function claimRewards() external nonReentrant returns (uint256) {
        // Fix: Use msg.sender
        uint256 userShareLocal = s_userDebtShares[msg.sender];
        if (userShareLocal == 0) revert DebtPool__UserNoDebt();
        _updateUserRewards(msg.sender);
        uint256 pendingRewards = s_userPendingRewards[msg.sender];
        if (pendingRewards > 0) {
            s_userPendingRewards[msg.sender] = 0;
            // Transfer rewards to user
            i_susd.mint(msg.sender, pendingRewards);
        } else {
            revert DebtPool__NonRewardAccumulation();
        }
        emit RewardsClaimed(msg.sender, pendingRewards);
        return pendingRewards;
    }

    // ========================== Internal Functions ==========================
    function _updateUserRewards(address user) internal {
        uint256 userShare = s_userDebtShares[user];
        if (userShare > 0) {
            // Calculate pending rewards
            uint256 rewardDelta = s_globalAccRewardIndex -
                s_userRewardIndex[user];
            uint256 pendingReward = (userShare * rewardDelta) /
                DECIMAL_PRECISION;
            // Update user's pending rewards
            s_userPendingRewards[user] += pendingReward;
        }
        // Prevent double counting
        s_userRewardIndex[user] = s_globalAccRewardIndex;
    }

    // This function is used to calculate the debt of a single asset
    function _calculateSingleDebtUSD(
        ISynAsset synAsset
    ) internal view returns (uint256) {
        // This address was used to query the price in Oracle
        address anchor_address = synAsset.anchorAddress();
        int256 price = s_priceOracle.getPrice(anchor_address);
        if (price <= 0) {
            revert DebtPool__InvalidPrice();
        }
        // calculate how much synAsset is minted(debt)
        uint256 total_supply = synAsset.totalSupply();
        return (uint256(price) * total_supply) / DECIMAL_PRECISION;
    }

    function _calculateTotalDebtUSD() internal view returns (uint256) {
        uint256 totalDebt = 0;
        for (uint8 i = 0; i < s_synAssets.length; i++) {
            totalDebt += _calculateSingleDebtUSD(s_synAssets[i]);
        }
        return totalDebt;
    }

    // ============ View Functions ============

    function getUserDebtUSD(address user) external view returns (uint256) {
        if (s_totalDebtShares == 0) return 0;

        uint256 total_debt_usd = _calculateTotalDebtUSD();
        uint256 user_debt_shares = s_userDebtShares[user];

        return (user_debt_shares * total_debt_usd) / s_totalDebtShares;
    }

    function getTotalDebtUSD() external view returns (uint256) {
        return _calculateTotalDebtUSD();
    }

    function getUserDebtShares(address user) external view returns (uint256) {
        return s_userDebtShares[user];
    }

    function getTotalDebtShares() external view returns (uint256) {
        return s_totalDebtShares;
    }

    function getUserPendingRewards(
        address user
    ) external view returns (uint256) {
        uint256 userShare = s_userDebtShares[user];
        if (userShare == 0) return 0;

        uint256 rewardDelta = s_globalAccRewardIndex - s_userRewardIndex[user];
        uint256 pendingReward = (userShare * rewardDelta) / DECIMAL_PRECISION;

        return s_userPendingRewards[user] + pendingReward;
    }

    function getGlobalAccRewardIndex() external view returns (uint256) {
        return s_globalAccRewardIndex;
    }

    function isSynAssetSupported(address asset) external view returns (bool) {
        return s_supportedSynAssets[asset];
    }

    function getSynAssets() external view returns (address[] memory) {
        address[] memory assets = new address[](s_synAssets.length);
        for (uint256 i = 0; i < s_synAssets.length; i++) {
            assets[i] = address(s_synAssets[i]);
        }
        return assets;
    }
}
