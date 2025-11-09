

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
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ISynAsset} from "./interfaces/ISynAsset.sol";
import {IPriceOracle} from "./interfaces/IPriceOracle.sol";
import {IDebtPool} from "./interfaces/IDebtPool.sol";

contract DebtPool is ReentrancyGuard, Ownable {

    // ============ Errors ============
    error DebtPool__InsufficientDebt();
    error DebtPool__ZeroAmount();
    error DebtPool__ZeroTotalDebt();
    error DebtPool__UserNoDebt();
    error DebtPool__NonRewardAccumulation();

    // ============ Events ============
    event DebtIncreased(address indexed user, uint256 amount, uint256 newTotalDebt);
    event DebtDecreased(address indexed user, uint256 amount, uint256 newTotalDebt);
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
    address private immutable i_btc_address;
    address private immutable i_susd_address;
    address private immutable i_usdc_address;
    address private immutable i_eth_address;
    address private immutable i_price_oracle_address;
    uint256 private s_globalAccRewardIndex;

    // ============ Constructor ============
    
    constructor(
        address owner, 
        address price_oracle_address, 
        address usdc_address, 
        address btc_address, 
        address eth_address,
        address susd_address
    ) Ownable(owner) {
        i_btc_address = btc_address;
        i_eth_address = eth_address;
        i_usdc_address = usdc_address;
        i_susd_address = susd_address;
        i_price_oracle_address = price_oracle_address;
    }

    // ============ External Functions ============
    
    function increaseDebt(address user, uint256 amountUSD) 
        external 
        onlyOwner 
        nonReentrant 
    {
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
            
            uint256 newShares = (amountUSD * s_totalDebtShares) / currentTotalDebt;
            s_totalDebtShares += newShares;
            s_userDebtShares[user] += newShares;
        }
        
        emit DebtIncreased(user, amountUSD, _calculateTotalDebtUSD());
    }

    function decreaseDebt(address user, uint256 amountUSD) 
        external 
        onlyOwner 
        nonReentrant 
    {
        if (amountUSD == 0) revert DebtPool__ZeroAmount();

        // First, update user's rewards before changing debt shares
        _updateUserRewards(user);

        uint256 total_debt_usd = _calculateTotalDebtUSD();
        if (total_debt_usd == 0) revert DebtPool__ZeroTotalDebt();

        uint256 shares_to_burn = (amountUSD * s_totalDebtShares) / total_debt_usd;
        
        if (shares_to_burn > s_userDebtShares[user]) {
            revert DebtPool__InsufficientDebt();
        }
        
        s_userDebtShares[user] -= shares_to_burn;
        s_totalDebtShares -= shares_to_burn;
        
        emit DebtDecreased(user, amountUSD, _calculateTotalDebtUSD());
    }

    function _calculateTotalDebtUSD() internal view returns (uint256) {
        address btc_rep = ISynAsset(i_btc_address).representativeAsset();
        address usdc_rep = ISynAsset(i_usdc_address).representativeAsset();
        address eth_rep = ISynAsset(i_eth_address).representativeAsset();
        
        int256 btc_price = IPriceOracle(i_price_oracle_address).getPrice(btc_rep);
        int256 usdc_price = IPriceOracle(i_price_oracle_address).getPrice(usdc_rep);
        int256 eth_price = IPriceOracle(i_price_oracle_address).getPrice(eth_rep);
        
        uint256 btc_debt = ISynAsset(i_btc_address).totalSupply();
        uint256 usdc_debt = ISynAsset(i_usdc_address).totalSupply();
        uint256 eth_debt = ISynAsset(i_eth_address).totalSupply();
        
        uint256 total_debt_usd = (
            btc_debt * uint256(btc_price) + 
            usdc_debt * uint256(usdc_price) + 
            eth_debt * uint256(eth_price)
        ) / 1e18;
        
        return total_debt_usd;
    }

    function distributeRewards(uint256 rewardAmountUSD) external onlyOwner nonReentrant {
        if(rewardAmountUSD == 0){
            revert DebtPool__ZeroAmount();
        }
        if(s_totalDebtShares == 0){
            revert DebtPool__ZeroTotalDebt();
        }

        // Update global accumulated reward index
        s_globalAccRewardIndex += (rewardAmountUSD * DECIMAL_PRECISION) / s_totalDebtShares;
    }

    function claimRewards() external nonReentrant returns(uint256) {
        uint256 userShare = s_userDebtShares[msg.sender];
        if(userShare == 0) revert DebtPool__UserNoDebt();
        _updateUserRewards(msg.sender);
        uint256 pendingRewards = s_userPendingRewards[msg.sender];
        if(pendingRewards > 0){
            s_userPendingRewards[msg.sender] = 0;
            // Transfer rewards to user
            ISynAsset(i_susd_address).mint(msg.sender, pendingRewards);
        }
        else {
            revert DebtPool__NonRewardAccumulation();
        }
        emit RewardsClaimed(msg.sender, pendingRewards);
        return pendingRewards;
    }

    function _updateUserRewards(address user) internal {
        uint256 userShare = s_userDebtShares[user];
        if(userShare > 0){
            // Calculate pending rewards
            uint256 rewardDelta = s_globalAccRewardIndex - s_userRewardIndex[user];
            uint256 pendingReward = (userShare * rewardDelta) / DECIMAL_PRECISION;
            // Update user's pending rewards
            s_userPendingRewards[user] += pendingReward;
        }
        // Prevent double counting
        s_userRewardIndex[user] = s_globalAccRewardIndex;
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

    function getUserPendingRewards(address user) external view returns (uint256) {
        uint256 userShare = s_userDebtShares[user];
        if(userShare == 0) return 0;

        uint256 rewardDelta = s_globalAccRewardIndex - s_userRewardIndex[user];
        uint256 pendingReward = (userShare * rewardDelta) / DECIMAL_PRECISION;

        return s_userPendingRewards[user] + pendingReward;
    }

    function getGlobalAccRewardIndex() external view returns (uint256) {
        return s_globalAccRewardIndex;
    }
    
}