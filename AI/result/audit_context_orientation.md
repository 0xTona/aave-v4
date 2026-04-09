# Deep Context Builder: Phase 1 (Initial Orientation)

## Aave v4 Protocol Complete Orientation

### 1. Major Modules and Contracts

The Aave v4 architecture relies on a **hub-and-spoke** model separating liquidity management (Hub) from user-facing operations (Spokes).

- **Hub** (`src/hub/`)
  - `Hub.sol`: The core immutable coordinator for liquidity. Manages asset registries, sets add/draw caps, risk premium thresholds, interest rate strategies, and tracks drawn/premium debt. Ensures global accounting invariant checks.
  - `HubStorage.sol`: State variables for the Hub.
  - `HubConfigurator.sol`: Manages configuration of Hubs.
- **Spokes** (`src/spoke/`)
  - `Spoke.sol`: An upgradeable endpoint that interacts directly with end-users for supplying/borrowing. Routes liquidity to the Hub. Manages reserve level risk factors, oracle logic, max user limits, and liquidation.
  - `TokenizationSpoke.sol`: A specialized spoke introducing ERC20-like tokenization if needed.
  - `TreasurySpoke.sol`: Handles Aave protocol treasury operations.
  - `LiquidationLogic.sol`: Library containing all the logic for Dutch auction-style variable liquidations.
- **Position Managers** (`src/position-manager/`)
  - `TakerPositionManager.sol`, `GiverPositionManager.sol`, `ConfigPositionManager.sol`: Handle cross-user operations, position management, EIP-712 signatures (`SignatureGateway.sol`), and native token handling (`NativeTokenGateway.sol`).
- **Interfaces & Libraries** (`src/libraries/`)
  - `WadRayMath.sol`, `PercentageMath.sol`: Used for the new debt scaling math.
  - Premium & SharesMath algorithms for the dynamic risk pricing.

### 2. General Public/External Entrypoints

**In `Spoke.sol` (User Interactions):**

- `supply(uint256 reserveId, uint256 amount, address onBehalfOf)`
- `withdraw(uint256 reserveId, uint256 amount, address onBehalfOf)`
- `borrow(uint256 reserveId, uint256 amount, address onBehalfOf)`
- `repay(uint256 reserveId, uint256 amount, address onBehalfOf)`
- `liquidationCall(uint256 collateralReserveId, uint256 debtReserveId, address user, uint256 debtToCover, bool receiveShares)`
- `setUsingAsCollateral(...)`
- `updateUserRiskPremium(address onBehalfOf)`
- `updateUserDynamicConfig(address onBehalfOf)`

**In `Hub.sol` (Spoke & Governor Interactions):**

- `add(uint256 assetId, uint256 amount)`
- `remove(uint256 assetId, uint256 amount, address to)`
- `draw(uint256 assetId, uint256 amount, address to)`
- `restore(uint256 assetId, uint256 drawnAmount, PremiumDelta calldata premiumDelta)`
- `reportDeficit(...)` & `eliminateDeficit(...)`

### 3. Likely Actors & Trust Assumptions

| Actor                      | Role / Privilege                                                                                                                    | Trust Level                                                        |
| -------------------------- | ----------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------ |
| **User/Borrower/Supplier** | Supplies assets, borrows, manages collateral.                                                                                       | Untrusted, adversarial.                                            |
| **Liquidator**             | Triggers `liquidationCall` when HF < 1.0.                                                                                           | Untrusted, adversarial. Motivated by profit (Dutch auction bonus). |
| **Position Manager**       | Smart contracts or EOAs authorized to act on behalf of users via `setUserPositionManager`.                                          | Semi-trusted to Untrusted (depending on the manager implemented).  |
| **Governor (DAO)**         | Updates risk configs, `TargetHealthFactor`, `Collateral Risk`, and updates Spoke capabilities. Can trigger `updateUserRiskPremium`. | Trusted. Has sweeping admin powers.                                |
| **AaveOracle**             | Provides pricing for risk calculations.                                                                                             | Trusted external dependency.                                       |

### 4. Important Storage Variables

**Hub.sol:**

- `mapping(uint256 => Asset) _assets;`: Central state for an asset, tracking global `liquidity`, `deficitRay`, `swept`, `addedShares`, `drawnShares`, `premiumShares`, `drawnIndex`, and `drawnRate`.
- `mapping(uint256 => mapping(address => SpokeData)) _spokes;`: Spoke-specific limits such as `addCap`, `drawCap`, `addedShares`, `drawnShares`, `deficitRay`.

**Spoke.sol:**

- `mapping(uint256 => Reserve) _reserves;`: Holds underlying asset mapping, decimals, flags (paused/frozen), static `collateralRisk`, and the `dynamicConfigKey` determining current active risk parameters.
- `mapping(address => mapping(uint256 => UserPosition)) _userPositions;`: Stores the user's `suppliedShares`, `drawnShares`, `premiumShares`, `premiumOffsetRay` and snapshot of `dynamicConfigKey`.
- `mapping(uint256 => mapping(uint32 => DynamicReserveConfig)) _dynamicConfig;`: Stores historical mapping of config states (CF, LB, LF) so updates don't unexpectedly liquidate existing users without action.
- `mapping(address => PositionStatus) _positionStatus;`: A bitmap tracking which reserves the user is borrowing or using as collateral.

### 5. Preliminary System Workflow & Invariants

**System Workflow**

1. User supplies asset to Spoke. Spoke calls `Hub.add`. Hub increases `Spoke.addedShares` and global asset liquidity.
2. User borrows an asset based on Collateral Risk calculations (Dynamic Risk Pricing). Spoke updates user's explicit `riskPremium`, then calls `Hub.draw`.
3. The drawn debt earns the `drawnRate` base index, while user risk composition yields a `premiumDebt`.
4. If a user becomes undercollateralized, a liquidator repays to fetch the position HF back to `TargetHealthFactor` (which is > 1.0), instead of the traditional fixed 50% close factor.

**Critical Core Invariants (Hub):**

1. Total borrowed shares == sum of all Spoke debt shares.
2. Hub added assets amount >= sum of all Spoke added assets amount.
3. Hub added shares == sum of Spoke added shares.
4. Supply share price and drawn index _never_ decrease.
5. User's recorded premium offset remains equal to the actual risk premium applied, avoiding artificial inflation of premium debt.

---

_Note: This concludes Phase 1 Bottom-Up Scan. The environment consists of separate risk configuration dictionaries (dynamic configurations), split premium / drawn debt streams, and a completely replaced liquidation engine (TargetHealthFactor with Dutch bonuses) requiring careful cross-function verification._
