

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

    // ============ Events ============
    event DebtIncreased(address indexed user, uint256 amount, uint256 newTotalDebt);
    event DebtDecreased(address indexed user, uint256 amount, uint256 newTotalDebt);

    // ============ State Variables ============
    
    uint256 private s_totalDebtShares;
    
    mapping(address => uint256) private s_userDebtShares;
    
    address private immutable i_btc_address;
    address private immutable i_usdc_address;
    address private immutable i_eth_address;
    
    address private immutable i_price_oracle_address;

    // ============ Constructor ============
    
    constructor(
        address owner, 
        address price_oracle_address, 
        address usdc_address, 
        address btc_address, 
        address eth_address
    ) Ownable(owner) {
        i_btc_address = btc_address;
        i_eth_address = eth_address;
        i_usdc_address = usdc_address;
        i_price_oracle_address = price_oracle_address;
    }

    // ============ External Functions ============
    
    function increaseDebt(address user, uint256 amountUSD) 
        external 
        onlyOwner 
        nonReentrant 
    {
        if (amountUSD == 0) revert DebtPool__ZeroAmount();

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

    // ============ Internal Functions ============
    
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
}