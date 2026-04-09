# State Compression

## HubStorage.sol

### Protocol State

| Variable               | Type                             | Meaning                                                                | Who Can Update                                  | Updated In                                                                                         | Read In                                                | Risk Notes                                                             |
| ---------------------- | -------------------------------- | ---------------------------------------------------------------------- | ----------------------------------------------- | -------------------------------------------------------------------------------------------------- | ------------------------------------------------------ | ---------------------------------------------------------------------- |
| `_assetCount`          | `uint256`                        | Number of distinct underlying assets registered in the Hub             | `admin`                                         | `addAsset()`                                                                                       | `updateAssetConfig()`, `addSpoke()`, `getAssetCount()` | Cannot delete assets, counter only goes up                             |
| `_assets`              | `mapping(uint256 => IHub.Asset)` | Core accounting for each listed asset (liquidity, debt, premium, etc.) | `admin` (config), `any Spoke` (user operations) | `addAsset()`, `updateAssetConfig()`, `add()`, `remove()`, `draw()`, `restore()`, `reportDeficit()` | Almost all asset operations and view functions         | Single source of truth for Hub liquidity; rounding bugs here are fatal |
| `_underlyingToAssetId` | `mapping(address => uint256)`    | Maps an underlying token address to its assigned Hub asset ID          | `admin`                                         | `addAsset()`                                                                                       | `isUnderlyingListed()`, `getAssetId()`                 | Assumes 1:1 token-to-asset mapping (no duplicates)                     |

### Spoke Tracking

| Variable         | Type                                                     | Meaning                                                             | Who Can Update                             | Updated In                                                                                              | Read In                                                     | Risk Notes                                                       |
| ---------------- | -------------------------------------------------------- | ------------------------------------------------------------------- | ------------------------------------------ | ------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------- | ---------------------------------------------------------------- |
| `_spokes`        | `mapping(uint256 => mapping(address => IHub.SpokeData))` | Tracks a specific Spoke's shares and deficit for a particular asset | `admin` (config), `any Spoke` (operations) | `updateAssetConfig()`, `_updateSpokeConfig()`, `add()`, `draw()`, `reportDeficit()`, `transferShares()` | View functions, limit validations                           | Shares held here must not exceed `_assets` added/drawn shares    |
| `_assetToSpokes` | `mapping(uint256 => EnumerableSet.AddressSet)`           | List of all registered Spokes for a given asset ID                  | `admin`                                    | `_addSpoke()`                                                                                           | `updateSpokeConfig()`, `getSpokeCount()`, `isSpokeListed()` | Unbounded iteration possible if many Spokes are added (gas risk) |

### Auditor Mental Model — Hub.sol / HubStorage.sol

- **Trust hierarchy**: admin > registered spoke > user traversing a spoke
- **Critical state flow**: `_assets` and `_spokes` are updated atomically in most operations. Total Spoke shares must exactly equal Total Asset shares.
- **Dangerous combos**: Rounding discrepancy between Spoke's calculation and Hub's storage leads to user deficit or locked funds if not perfectly synced.
- **Key invariants to check**: `Sum(spoke.addedShares) == asset.addedShares`, `Sum(spoke.drawnShares) == asset.drawnShares`
- **Missing protections**: No apparent way to remove/deregister a Spoke completely (only halt/deactivate).

## SpokeStorage.sol

### Core Configurations

| Variable                 | Type                                                                 | Meaning                                                                           | Who Can Update | Updated In                                                                  | Read In                                             | Risk Notes                                                                             |
| ------------------------ | -------------------------------------------------------------------- | --------------------------------------------------------------------------------- | -------------- | --------------------------------------------------------------------------- | --------------------------------------------------- | -------------------------------------------------------------------------------------- |
| `_reserveCount`          | `uint256`                                                            | Number of reserves registered locally in this Spoke                               | `admin`        | `addReserve()`                                                              | `_processUserAccountData()`, `getReserveCount()`    | Used as bound for user reserve iteration                                               |
| `_liquidationConfig`     | `ISpoke.LiquidationConfig`                                           | Spoke-wide liquidation targets (target HF, max bonus, etc.)                       | `admin`        | `updateLiquidationConfig()`                                                 | `liquidationCall()`, `getLiquidationBonus()`        | Over-aggressive bonus can lead to bad debt generation                                  |
| `_reserves`              | `mapping(uint256 => ISpoke.Reserve)`                                 | Local configurations per reserve, maps to Hub asset and holds pause/freeze flags  | `admin`        | `addReserve()`, `updateReserveConfig()`, `addDynamicReserveConfig()`        | Most state-changing core functions (supply, borrow) | Flags control critical stop features. Incorrect settings halt protocol.                |
| `_hubAssetIdToReserveId` | `mapping(address => mapping(uint256 => uint256))`                    | Reverse lookup: from Hub address and Asset ID to Spoke Reserve ID                 | `admin`        | `addReserve()`                                                              | `getReserveId()`                                    | Ensures no duplicate reserve initialization                                            |
| `_dynamicConfig`         | `mapping(uint256 => mapping(uint32 => ISpoke.DynamicReserveConfig))` | Historical record of changing reserve risk params (allows lazy updates for users) | `admin`        | `addReserve()`, `addDynamicReserveConfig()`, `updateDynamicReserveConfig()` | `liquidationCall()`, `_processUserAccountData()`    | Outdated config keys aren't deleted, allowing historical tracing at minor storage cost |

### User Tracking

| Variable           | Type                                                          | Meaning                                                                            | Who Can Update                              | Updated In                                                                                         | Read In                                               | Risk Notes                                                                     |
| ------------------ | ------------------------------------------------------------- | ---------------------------------------------------------------------------------- | ------------------------------------------- | -------------------------------------------------------------------------------------------------- | ----------------------------------------------------- | ------------------------------------------------------------------------------ |
| `_positionStatus`  | `mapping(address => ISpoke.PositionStatus)`                   | Bitmaps for user's active collateral/borrow status and their cached risk premium   | `user`, `liquidator`, `admin (via manager)` | `borrow()`, `repay()`, `liquidationCall()`, `setUsingAsCollateral()`, `_notifyRiskPremiumUpdate()` | `withdraw()`, `borrow()`, `_processUserAccountData()` | Bitmaps limit user to MAX_USER_RESERVES_LIMIT. Risk premium is lazily stored.  |
| `_userPositions`   | `mapping(address => mapping(uint256 => ISpoke.UserPosition))` | User's supplied shares, drawn shares, and last used dynamic config key per reserve | `user`, `liquidator`                        | `supply()`, `withdraw()`, `borrow()`, `repay()`, `liquidationCall()`                               | `_processUserAccountData()`, view methods             | Relies heavily on accurate share-to-asset math from the Hub.                   |
| `_positionManager` | `mapping(address => ISpoke.PositionManagerConfig)`            | Tracks global active state of position managers and user-specific approvals        | `admin`, `user`                             | `updatePositionManager()`, `setUserPositionManager()`, `renouncePositionManagerRole()`             | `isPositionManager()`, `isPositionManagerActive()`    | Over-permissive manager could drain user funds if global active toggle is true |

### Auditor Mental Model — Spoke.sol / SpokeStorage.sol

- **Trust hierarchy**: admin > approved position manager > user
- **Critical state flow**: `_userPositions` must align with `_positionStatus`. When debt goes to 0, borrowing bit must flip. When shares grow, Hub must match.
- **Dangerous combos**: A badly configured `_dynamicConfig` coupled with laggy user updates might create an arbitrage or unsafe liquidation window before full sync.
- **Key invariants to check**: Debt shares == 0 implies `_positionStatus.borrowing == false`. Collateral flag requires `suppliedShares > 0`.
- **Missing protections**: User might theoretically lag on an old `dynamicConfigKey` indefinitely if they avoid transactions, though liquidators/managers can force update.

## ConfigPositionManager.sol

### Action Permissions

| Variable  | Type                                                                            | Meaning                                                                                                      | Who Can Update     | Updated In             | Read In             | Risk Notes                                                       |
| --------- | ------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------ | ------------------ | ---------------------- | ------------------- | ---------------------------------------------------------------- |
| `_config` | `mapping(address => mapping(address => mapping(address => ConfigPermissions)))` | Maps Spoke -> Delegator -> Delegatee to their specific granted config capabilities (like setting collateral) | `user (delegator)` | `_updatePermissions()` | `_getPermissions()` | Permissions don't expire automatically; no time-bound delegation |

### Auditor Mental Model — ConfigPositionManager.sol

- **Trust hierarchy**: user (delegator) > delegatee
- **Critical state flow**: `_config` grants fine-grained config rights. Requires validation of Spoke support and signature nonces.
- **Dangerous combos**: Phishing a user to sign a permit for global permissions gives attacker full control over collateral toggles.
- **Key invariants to check**: Revoking permissions immediately blocks delegatee access across all specified capabilities.

## TakerPositionManager.sol

### Allowances

| Variable              | Type                                                                                      | Meaning                                                                          | Who Can Update | Updated In                   | Read In                   | Risk Notes                                                                |
| --------------------- | ----------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------- | -------------- | ---------------------------- | ------------------------- | ------------------------------------------------------------------------- |
| `_withdrawAllowances` | `mapping(address => mapping(uint256 => mapping(address => mapping(address => uint256))))` | Tracks how much a spender can withdraw on behalf of an owner for a Spoke/Reserve | `user (owner)` | `_updateWithdrawAllowance()` | `_getWithdrawAllowance()` | Consumption logic uses zeroFloorSub to handle Hub rounding; can be tricky |
| `_borrowAllowances`   | `mapping(address => mapping(uint256 => mapping(address => mapping(address => uint256))))` | Tracks how much a spender can borrow on behalf of an owner for a Spoke/Reserve   | `user (owner)` | `_updateBorrowAllowance()`   | `_getBorrowAllowance()`   | Consumption logic uses zeroFloorSub to handle Hub rounding; can be tricky |

### Auditor Mental Model — TakerPositionManager.sol

- **Trust hierarchy**: user (owner) > spender
- **Critical state flow**: Allowances decrease based on the actual delta of `getUserSuppliedAssets` / `getUserTotalDebt`, rather than the input amount, absorbing Hub rounding noise.
- **Dangerous combos**: Rounding errors could occasionally make an allowance deplete slightly faster or slower than expected, though `zeroFloorSub` protects against underflow.
- **Key invariants to check**: `allowance == type(uint256).max` means infinite allowance (does not decrement).
