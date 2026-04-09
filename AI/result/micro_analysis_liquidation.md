# Deep Context Builder: Phase 2 (Ultra-Granular Function Analysis)

## Introduction

This artifact details the Phase 2 Micro-Analysis of the Aave v4 Core Liquidation Engine entry point (`Spoke.liquidationCall`), as prioritized by the user. The methodology maps code blocks directly against First Principles, assumptions, and cross-functional invariant checks defined by `OUTPUT_REQUIREMENTS.md`.

---

## 1. Function: `Spoke.liquidationCall`

### **1. Purpose**

- Serves as the primary external entry point for liquidators to trigger a liquidation on undercollateralized positions.
- Aggregates the existing `UserAccountData` and marshalls the data required for calculating Dutch Auction variable liquidation bonuses, Target Health Factors, and dust-prevention checks.
- Modifies the user's risk premium post-liquidation, or, if the position has no collateral left but remaining debt across any reserve, initiates protocol deficit reporting loops.

### **2. Inputs & Assumptions**

- `uint256 collateralReserveId`: Risk asset the liquidator intends to seize.
  - _Source:_ Untrusted Input.
  - _Trust Level:_ Untrusted.
- `uint256 debtReserveId`: The borrowed asset the liquidator intends to repay.
  - _Source:_ Untrusted Input.
  - _Trust Level:_ Untrusted.
- `address user`: The borrower being targeted.
  - _Source:_ Untrusted Input.
  - _Trust Level:_ Untrusted.
- `uint256 debtToCover`: Exact or maximum depth of repayment.
  - _Source:_ Untrusted Input.
- `bool receiveShares`: Flag explicitly asking for the underlying Hub yielding shares instead of the actual withdrawal of tokens.
  - _Source:_ Untrusted Input.
- **Key Assumptions:**
  - The `TargetHealthFactor` established by the `Governor` is strictly `>= 1.0` to avoid continuous cyclic liquidations.
  - The caller is _not_ liquidating themselves (Self-liquidation reverts as a rule).
  - The caller has provided sufficient allowance / balances in the underlying asset space of `debtReserveId` to cover their `debtToCover`.

### **3. Outputs & Effects**

- **Return Values:** Void
- **Events Emitted:** None directly in this function block (delegated to library).
- **State Writes:**
  - Core state writes are delegated passing storage pointers to `LiquidationLogic`.
  - Writes to `_positionStatus` (to mark `riskPremium` as 0 if deficit, or a freshly calculated riskPremium if partially survived).
- **External Interactions:**
  - Indirectly queries `IHub(hub).previewRemoveByShares` during the inner library functions execution.
  - Uses `IAaveOracle(ORACLE).getReservePrice(reserveId)`.
- **Postconditions:**
  - The `user` Health Factor is returned precisely to the configured `TargetHealthFactor` OR all debts/collaterals involved are entirely consumed.
  - The dynamic configuration keys (`dynamicConfigKey`) for the user represent accurate post-action factors.

### **4. Block-by-Block Analysis**

#### Block 1: Initial Account Data Retrieval

```solidity
L354: UserAccountData memory userAccountData = _calculateUserAccountData(user);
```

- **What:** Retrieves complete snapshot of the user's collateral, debt, borrow counts, and `riskPremium` _without_ forcing an atomic refresh of the dynamic config.
- **Why here:** Must assess whether the position is actually underwater (`<1.0 HF`) according to its _stored bound state_, not to a newer config that they haven't explicitly bound to yet.
- **Assumptions:** `_calculateUserAccountData(user)` does not modify storage; it purely reflects active keys.
- **First Principles Analysis:** If a user’s position is safe under the old dynamic config but extremely toxic under the new one (e.g. the Governor drastically reduced Collateral Factor), the protocol intentionally _avoids_ forcefully liquidating them on this pass if `refreshConfig = false` is used. However, wait! If `refreshConfig = false` is used to gather `userAccountData`, are we allowing users to escape liquidation if the config worsened? _Yes_, dynamic binding in Aave v4 intentionally grandfathers older states until the user interacts with the protocol via state-changing operations.

#### Block 2: Struct Marshalling

```solidity
L355: LiquidationLogic.LiquidateUserParams memory params = LiquidationLogic.LiquidateUserParams({
L356:   collateralReserveId: collateralReserveId,
L357:   debtReserveId: debtReserveId,
L358:   liquidationConfig: _liquidationConfig,
L359:   oracle: ORACLE,
...
```

- **What:** Packs parameters, configurations, and dynamic environment pointers into memory structures.
- **Why here:** Circumvents EVM stack limits when passing 10+ arguments into the library execution.
- **Assumptions:** `_liquidationConfig` contains valid properties (tested by `updateLiquidationConfig` invariant limits).
- **5 Hows:** How does the Spoke maintain synchronization with the library? By passing exactly the required subsets so the library doesn't need to read unassociated Spoke contract state internally.

#### Block 3: Delegation to `LiquidationLogic`

```solidity
L367: bool isUserInDeficit = LiquidationLogic.liquidateUser({
L368:   reserves: _reserves,
...
L372:   params: params
L373: });
```

- **What:** Modifies user balances, hub states, and transfers assets via library logic, returning a deficit flag indicating unrecoverable bad debt.
- **Why here:** This is the core logic sequence executing the actual repayment and seizures.
- **Assumptions:** Reentrancy is protected at the top level via `nonReentrant` modifier on `liquidationCall`.
- **Depends on:** The health factor being precisely decoded, the `receiveShares` capability being active for the reserve (if requested).

#### Block 4: Deficit & Risk Processing

```solidity
L375: if (isUserInDeficit) {
L376:   // report deficit for all debt reserves, including the reserve being repaid
L377:   LiquidationLogic.notifyReportDeficit(_reserves, _userPositions, _positionStatus, _reserveCount, user);
L378: } else {
L379:   uint256 newRiskPremium = _calculateUserAccountData(user).riskPremium;
L380:   _notifyRiskPremiumUpdate(user, newRiskPremium);
L381: }
```

- **What:** Triggers generalized protocol deficit loops if the user was structurally ruined `isUserInDeficit == true`. If they survived, it recalculates `riskPremium` and normalizes the user's position data for future accrual.
- **Why here:** It must run strictly after modifications.
- **5 Whys:** Why does `notifyReportDeficit` trigger for ALL debt reserves, rather than just `debtReserveId`?
  - _Because_ `isUserInDeficit` indicates the user ran exactly to 0 collateral across the board. If there is 0 total collateral, ALL open debt positions the user possesses are fundamentally bad debt and immediately un-repayable by seizing collateral. Therefore, the hub handles all remaining debt segments as socialized protocol deficit simultaneously instead of waiting for multiple liquidators.

---

### **5. Cross-Function Dependencies & Risk Analysis**

- **Internal Dependencies:**
  - `_calculateUserAccountData(user)`: Shared state engine. Essential invariant: Must not revert under edge cases, otherwise liquidations freeze.
  - `_notifyRiskPremiumUpdate(user, premium)`: Pushes premium index updates to position status.
- **External Calls:**
  - library `LiquidationLogic`: Performs SafeERC20 asset transfers and Hub accounting adjustments internally.
  - `Hub.reportDeficit`: Highly privileged function to socialize losses across the protocol.
    - **Risk:** If a malicious user manages to spoof an artificial `isUserInDeficit` flag (via math inflation), they could pass millions holding principal on Spoke reserves into the Hub deficit, diluting the protocol aggressively.

---

### **Summary of Invariants Satisfied & Identified**

1. **Invariant:** The user's `riskPremium` must always accurately reflect the current ratio of weighted collateral risk immediately following a partial liquidation.
2. **Invariant:** Liquidators must never leave partial debt dust (<$1,000 equivalent) if they are attempting full liquidation.
3. **Invariant:** Deficit loops must aggressively clear ALL remaining debt if user collateral falls to precisely 0.

_Analysis of LiquidationLogic calculations will continue if deeper dive into Dutch Auction mechanisms is required._
