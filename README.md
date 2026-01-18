# CosmoBasket

![CosmoBasket poster](./image.jpg)

[English](#english) | [中文](#chinese)

<a name="english"></a>
## English

**CosmoBasket** is a decentralized synthetic asset protocol that enables users to mint synthetic assets backed by collateral.

### Overview

CosmoBasket is a collateral-backed synthetic asset protocol built on Ethereum. Users can deposit supported collateral assets (like BTC, ETH) and mint synthetic assets (like sBTC, sETH, sSPY, sUSD) that track the value of real-world assets.

### Key Features

- **Collateral Management**: Deposit and withdraw multiple types of collateral assets
- **Synthetic Asset Minting**: Mint synthetic assets backed by your collateral
- **Debt Pool System**: Track user debt positions across the protocol
- **Liquidation Mechanism**: Maintain protocol health through liquidations of risky positions
- **Price Oracle Integration**: Real-time price feeds for accurate valuations

### Architecture

#### Core Contracts

- **CollateralManager.sol**: Main contract for managing collateral deposits, withdrawals, minting, and liquidations
- **DebtPool.sol**: Tracks and manages user debt positions
- **PriceOracle.sol**: Provides price feeds for assets
- **SyntheticAsset/** (sBTC, sETH, sSPY, sUSD): ERC20 tokens representing synthetic assets

#### Interfaces

- **IDebtPool.sol**: Interface for debt pool operations
- **IPriceOracle.sol**: Interface for price oracle queries
- **ISynAsset.sol**: Interface for synthetic asset operations

### Risk Parameters

| Parameter | Value | Description |
|-----------|-------|-------------|
| Health Factor | 300% | Target collateralization ratio |
| Mint Risk Ratio | 200% | Minimum ratio required to mint new assets |
| Liquidation Risk Ratio | 180% | Threshold for withdrawal restrictions |
| Liquidation Threshold | 150% | Position becomes eligible for liquidation |
| Liquidation Bonus | 5% | Reward for liquidators |

### Usage

#### Depositing Collateral

```solidity
collateralManager.depositCollateral(assetAddress, amount);
```

Users must approve the CollateralManager contract to transfer their collateral tokens first.

#### Minting Synthetic Assets

```solidity
collateralManager.mintSyntheticAsset(synAssetAddress, amount);
```

Requirements:
- Sufficient collateral deposited
- Position must maintain at least 200% collateralization ratio after minting
- Final health factor must remain above 180%

#### Burning Synthetic Assets

```solidity
collateralManager.burnSyntheticAsset(synAssetAddress, amount);
```

Burns synthetic assets to reduce debt position.

#### Withdrawing Collateral

```solidity
collateralManager.withdrawCollateral(assetAddress, amount);
```

Requirements:
- Sufficient collateral balance
- If debt exists, position must maintain at least 180% collateralization after withdrawal

#### Liquidating Positions

```solidity
collateralManager.liquidate(userAddress, amountInUSD);
```

Liquidators can liquidate undercollateralized positions (below 150%) and receive a 5% bonus. Liquidations use sUSD to repay debt and distribute collateral proportionally.

### Security Features

- **ReentrancyGuard**: Protection against reentrancy attacks
- **SafeERC20**: Safe token transfer operations
- **Balance Validation**: Verifies actual token transfers match expected amounts
- **Health Factor Checks**: Multiple validation points to prevent risky positions

### Key Functions

#### View Functions

- `getUserCollateralUSD(address user)`: Returns total collateral value in USD
- `getStakerCollateral(address staker, address asset)`: Returns collateral balance for specific asset
- `isAssetSupported(address asset)`: Check if collateral asset is supported
- `isSyntheticAssetSupported(address synAsset)`: Check if synthetic asset is supported

### Development Setup

#### Prerequisites

- Solidity ^0.8.0
- OpenZeppelin Contracts
- Foundry or Hardhat for testing

#### Installation

```bash
# Clone the repository
git clone <repository-url>

# Install dependencies
forge install OpenZeppelin/openzeppelin-contracts
```

#### Testing

```bash
# Run tests
forge test

# Run tests with coverage
forge coverage
```

### Deployment

The CollateralManager contract requires the following constructor parameters:

- `priceOracleAddress`: Address of the deployed PriceOracle contract
- `debtPoolAddress`: Address of the deployed DebtPool contract
- `supportedAssets`: Array of supported collateral asset addresses
- `supportedSyntheticAssets`: Array of supported synthetic asset addresses

### Author

**Kevin Lee**  
Date: November 6, 2025

### License

MIT License

### Disclaimer

This is experimental software. Use at your own risk. Always conduct thorough audits before deploying to mainnet.

---

<a name="chinese"></a>
## 中文 (Chinese)

**CosmoBasket** 是一个去中心化合成资产协议，允许用户通过抵押品铸造合成资产。

### 概览

CosmoBasket 是建立在 Ethereum 上的抵押支持合成资产协议。用户可以存入支持的抵押资产（如 BTC, ETH）并铸造追踪现实世界资产价值的合成资产（如 sBTC, sETH, sSPY, sUSD）。

### 主要功能

- **抵押品管理**: 存入和提取多种类型的抵押资产
- **合成资产铸造**: 利用你的抵押品铸造合成资产
- **债务池系统**: 追踪整个协议中的用户债务头寸
- **清算机制**: 通过清算风险头寸来维护协议健康
- **价格预言机集成**: 实时价格源以确保准确估值

### 架构

#### 核心合约

- **CollateralManager.sol**: 管理抵押品存取、铸造和清算的主合约
- **DebtPool.sol**: 追踪和管理用户债务头寸
- **PriceOracle.sol**: 提供资产价格源
- **SyntheticAsset/** (sBTC, sETH, sSPY, sUSD): 代表合成资产的 ERC20 代币

#### 接口

- **IDebtPool.sol**: 债务池操作接口
- **IPriceOracle.sol**: 价格预言机查询接口
- **ISynAsset.sol**: 合成资产操作接口

### 风险参数

| 参数 | 数值 | 描述 |
|-----------|-------|-------------|
| 健康因子 (Health Factor) | 300% | 目标抵押率 |
| 铸造风险率 (Mint Risk Ratio) | 200% | 铸造新资产所需的最小比率 |
| 清算风险率 (Liquidation Risk Ratio) | 180% | 提款限制阈值 |
| 清算阈值 (Liquidation Threshold) | 150% | 头寸可被清算的阈值 |
| 清算奖励 (Liquidation Bonus) | 5% | 清算人的奖励 |

### 使用方法

#### 存入抵押品

```solidity
collateralManager.depositCollateral(assetAddress, amount);
```

用户必须先批准 CollateralManager 合约转移其抵押代币。

#### 铸造合成资产

```solidity
collateralManager.mintSyntheticAsset(synAssetAddress, amount);
```

要求:
- 已存入足够的抵押品
- 铸造后头寸必须保持至少 200% 的抵押率
- 最终健康因子必须保持在 180% 以上

#### 销毁合成资产

```solidity
collateralManager.burnSyntheticAsset(synAssetAddress, amount);
```

销毁合成资产以减少债务头寸。

#### 提取抵押品

```solidity
collateralManager.withdrawCollateral(assetAddress, amount);
```

要求:
- 足够的抵押品余额
- 如果存在债务，提取后头寸必须保持至少 180% 的抵押率

#### 清算头寸

```solidity
collateralManager.liquidate(userAddress, amountInUSD);
```

清算人可以清算抵押不足的头寸（低于 150%）并获得 5% 的奖励。清算使用 sUSD 偿还债务并按比例分配抵押品。

### 安全特性

- **ReentrancyGuard**: 防范重入攻击
- **SafeERC20**: 安全的代币转移操作
- **Balance Validation**: 验证实际代币转移是否与预期金额匹配
- **Health Factor Checks**: 多重验证点以防止风险头寸

### 关键函数

#### 视图函数

- `getUserCollateralUSD(address user)`: 返回以 USD 计价的总抵押品价值
- `getStakerCollateral(address staker, address asset)`: 返回特定资产的抵押余额
- `isAssetSupported(address asset)`: 检查抵押资产是否受支持
- `isSyntheticAssetSupported(address synAsset)`: 检查合成资产是否受支持

### 开发设置

####以此为基础

- Solidity ^0.8.0
- OpenZeppelin Contracts
- Foundry 或 Hardhat 用于测试

#### 安装

```bash
# 克隆仓库
git clone <repository-url>

# 安装依赖
forge install OpenZeppelin/openzeppelin-contracts
```

#### 测试

```bash
# 运行测试
forge test

# 运行带覆盖率的测试
forge coverage
```

### 部署

CollateralManager 合约需要以下构造函数参数:

- `priceOracleAddress`: 已部署的 PriceOracle 合约地址
- `debtPoolAddress`: 已部署的 DebtPool 合约地址
- `supportedAssets`: 支持的抵押资产地址数组
- `supportedSyntheticAssets`: 支持的合成资产地址数组

### 作者

**Kevin Lee**  
日期: 2025年11月6日

### 许可证

MIT License

### 免责声明

这是实验性软件。使用风险自负。在部署到主网之前，请务必进行彻底的审计。