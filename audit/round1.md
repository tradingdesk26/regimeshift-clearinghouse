# Audit Round 1 — InterAgentRepoV2 → V3 Remediation

**Date:** 2026-05-22
**Scope:** `InterAgentRepoV2.sol` deployed at `0x2bfE0f1142B04049d867389Bf91A84e498ED11E4` on Base mainnet
**Result:** 4 HIGH + 3 MEDIUM + 3 LOW findings → V3 deployed at `0xFfca5d80c3413Bd5D17971550cCD615f57f22945`
**Tests:** 15/15 passing including 4 PoC against V2 + 4 fix-validation against V3

---

## Root cause

`originate()` in V2 ratified the oracle's EIP-712 signature without checking any **economic invariants**. Even with an HONEST oracle, three concrete holes existed:

1. Quote with initial LTV ≥ 95% (already at liquidation threshold) was accepted
2. Quote with duration shorter than grace period bypassed liquidation entirely
3. Quote with arbitrarily high `rateBps` (e.g. 10,000% APR) accepted

Plus a fourth architectural issue: `defaultLoan()` transferred 100% of collateral to the lender — asymmetric vs `liquidate()` (which carves out 3% bounty + 1% insurance + leaves excess to borrower).

---

## HIGH findings + V3 remediation

### #1 — Origination below liquidation threshold not validated

**Bug:** Oracle (compromised, buggy, or just at wrong moment) could sign a quote where `principalValue / collateralValue ≥ 95%`. After `originate()`, the loan is already at the liquidation threshold. After 61s grace period, any liquidator burns 100% of collateral; borrower loses everything they posted.

**PoC** (in [`test/InterAgentRepoV3.t.sol`](../contracts/test/InterAgentRepoV3.t.sol) `test_AuditPoC_V2_acceptsAlreadyLiquidatableLoan`):

```solidity
InterAgentRepoV2.Quote memory q = _buildV2Quote(
    nonce, 50_000_000, 0.025 ether,  // $50 USDC vs 0.025 WETH @ $2080 → LTV ~96%
    block.timestamp + 1 hours, 425
);
v2.originate(q, sig);  // ← V2 accepts (bug)
vm.warp(block.timestamp + 61);
v2.liquidate(nonce);   // ← Succeeds immediately, borrower wiped out
```

**Fix in V3** (`originate()` line ~205):

```solidity
(uint256 initialLtvBps, ) = _computeLtv(q.principalAmount, q.collateralAmount);
uint256 maxOriginationLtv = LIQUIDATION_LTV_BPS - MIN_LTV_BUFFER_BPS;  // 9500 - 200 = 9300
if (initialLtvBps >= maxOriginationLtv) {
    revert InitialLtvTooHigh(initialLtvBps, maxOriginationLtv);
}
```

`MIN_LTV_BUFFER_BPS = 200` (2%) → max origination LTV = 93%.

**Side-effect:** Off-chain `REGIME_MAX_LTV` lowered across all regimes in `oracle/calibration.py` so matching engine doesn't generate quotes the contract would reject:
- RESTING: 98% → **92%**
- LOW: 96% → **90%**
- NORMAL: 92% → **85%**
- ELEVATED: 85% → **80%**
- HIGH: 75% → **70%**
- EXTREME: 60% → 55% (matching paused anyway)

Trade-off: lose "98% LTV in calm markets" marketing claim. Keep "more efficient than Aave 4 out of 5 regimes + safer in stress".

### #2 — Duration < GRACE_PERIOD bypasses liquidation

**Bug:** Quote with `expiryTimestamp = block.timestamp + 30s` was valid. Since liquidate() is blocked during the first 60s grace period, the only way to settle this loan is via `defaultLoan()` after expiry. Combined with bug #4 (default gives lender 100%), the lender gets full collateral with NO carve-outs (no bounty, no insurance).

**PoC** (`test_AuditPoC_V2_acceptsSubGracePeriodDuration`): demonstrates 30s loan → grace blocks liquidate → default fires → lender gets 100%.

**Fix in V3**:

```solidity
uint256 minimumExpiry = block.timestamp + GRACE_PERIOD_SECONDS + MIN_DURATION_BUFFER_SECONDS;
if (q.expiryTimestamp < minimumExpiry) {
    revert LoanDurationTooShort(q.expiryTimestamp, minimumExpiry);
}
```

`MIN_DURATION_BUFFER_SECONDS = 60` → min total duration = grace (60s) + buffer (60s) = 120s. Liquidation window always opens before default window.

### #3 — No upper bound on rateBps

**Bug:** Oracle could (buggy, malicious, or test misuse) sign a quote with `rateBps = 1_000_000` = 10,000% APR. Borrower obligated to repay astronomical interest. At MVP cap of $50 principal, damage is small (~$0.01/hour at 1000% APR for 1h loan), but **semantically broken**.

**PoC** (`test_AuditPoC_V2_acceptsUsuriousRate`): originate with rate=1_000_000 succeeds in V2.

**Fix in V3**:

```solidity
if (q.rateBps > MAX_RATE_BPS) revert RateTooHigh(q.rateBps, MAX_RATE_BPS);
```

`MAX_RATE_BPS = 100_000` (1000% APR — generous sanity ceiling; legitimate quotes rarely exceed 50% APR).

### #4 — `defaultLoan()` transfers 100% collateral including excess

**Bug:** When loan expires without repayment, V2 transfers ALL collateral to lender — no carve-outs (asymmetric vs `liquidate()` which carves out 3% bounty + 1% insurance). Worse: if borrower is heavily over-collateralized (e.g. $30 USDC borrowed against 0.040 WETH = $83), lender pockets the $53 excess. Borrower loses everything because they missed expiry — disproportionate to debt.

This is also the **enabler for finding #5** (USDC blacklist DOS): lender can engineer blacklist of own address → repay's `transferFrom(borrower, lender, USDC)` fails → loan expires → defaultLoan() gives lender 100% windfall. Attack only profitable because of #4.

**PoC** (`test_AuditPoC_V2_defaultTransfersFullCollateral`): borrower posts $83 against $30 debt, misses expiry, lender pockets all $83.

**Fix in V3** — Aave-style fair split applied to `defaultLoan()` too:

```solidity
// Compute debt at expiry (interest stops accruing after expiry)
uint256 elapsed = loan.expiryTimestamp - loan.originationTimestamp;
uint256 interest = (loan.principalAmount * loan.rateBps * elapsed) / (365 days * 10_000);
uint256 debtUsdcRaw = loan.principalAmount + interest;

// Get current Chainlink price + convert debt to collateral-equivalent
(, uint256 ethPriceE8) = _computeLtv(loan.principalAmount, loan.collateralAmount);
uint256 debtCollateralEquiv = (debtUsdcRaw * 1e20) / ethPriceE8;

// Splits: same 3% bounty + 1% insurance carve-out as liquidate
uint256 bounty = (loan.collateralAmount * LIQUIDATOR_BOUNTY_BPS) / 10_000;
uint256 insuranceFee = (loan.collateralAmount * INSURANCE_FEE_BPS) / 10_000;
uint256 remaining = loan.collateralAmount - bounty - insuranceFee;

// Lender gets min(debt-equivalent, remaining-after-carveouts)
uint256 lenderShare = debtCollateralEquiv < remaining ? debtCollateralEquiv : remaining;
uint256 borrowerRefund = remaining - lenderShare;

IERC20(loan.collateralToken).safeTransfer(msg.sender, bounty);          // 3% bounty (incentive to trigger)
IERC20(loan.collateralToken).safeTransfer(insurancePoolAddress, insuranceFee);  // 1% insurance
IERC20(loan.collateralToken).safeTransfer(loan.lender, lenderShare);    // fair debt amount
if (borrowerRefund > 0) {
    IERC20(loan.collateralToken).safeTransfer(loan.borrower, borrowerRefund);  // excess back
}
```

**Result:** Lender never gets more than debt-equivalent at expiry. Borrower never loses excess. Eliminates #5 attack incentive.

---

## MEDIUM findings + status

### #5 — USDC blacklist DOS on repay() (Combo with #4)

**Status:** **Eliminated by #4 fix.** Lender no longer profits from forcing default → blacklist attack has no payoff. Withdraw pattern for repay() not needed at MVP scope.

### #6 — `setOracleSigner` / `setInsurancePool` instant (no timelock)

**Status:** **Acknowledged as MVP scope.** V3 inherits this; mitigated by:
- Owner key kept in cold storage / multisig (post-MVP)
- Pausable mixin allows emergency halt during admin compromise window
- Per-version EIP-712 domain bump means new V required for breaking changes

**v2.0+ roadmap:** Governor with 3-day timelock on admin functions.

### #7 — Single EOA = oracleSigner + insurancePool

**Status:** **Acknowledged as MVP scope** (documented in README). Currently both = burner `0x3d6EF3B451...`. Conflict of interest in theory (1% of every liquidation accrues to oracle operator), zero impact in practice because:
- Liquidations are bound by Chainlink-priced fair split (operator can't manipulate)
- Methodology is open + version-hashed (operator can't change pricing)

**Post-Day 3 action:** Rotate `insurancePool` to multisig address.

---

## LOW / INFO findings

### #8 — Chainlink read without `answeredInRound >= roundId` check

**Status:** **FIXED in V3** `_readEthUsdE8()`:

```solidity
(uint80 roundId, int256 priceI, , uint256 updatedAt, uint80 answeredInRound)
    = ethUsdFeed.latestRoundData();
if (block.timestamp - updatedAt > PRICE_STALENESS_LIMIT) revert PriceStale();
if (priceI <= 0) revert PriceInvalid();
if (answeredInRound < roundId) revert InvalidRoundData();  // ← V3 addition
```

### #9 — No Pausable

**Status:** **FIXED in V3.** OZ `Pausable` mixin added:

```solidity
contract InterAgentRepoV3 is EIP712, ReentrancyGuard, Ownable, Pausable {

function emergencyPause() external onlyOwner { _pause(); emit EmergencyPaused(msg.sender); }
function emergencyUnpause() external onlyOwner { _unpause(); emit EmergencyUnpaused(msg.sender); }

// originate / repay / defaultLoan / liquidate all gated by `whenNotPaused`
```

### #10 — Misc design choices

- `loanId = q.nonce` (predictable): **acknowledged**. Nonces are deterministic-by-design from off-chain matcher; collisions impossible because `consumedNonces` mapping enforces uniqueness.
- `borrower == lender` not blocked: **acknowledged**. Edge case (self-loan = no-op modulo fees). Not exploitable.
- No partial repay: **acknowledged**. v2.0+ roadmap.

---

## Deferred (v2.0+)

| Item | Why deferred |
|------|--------------|
| Governor timelock on admin | MVP scope — adding 250+ lines of OZ Governor adds attack surface for minor MVP benefit |
| Multi-asset collateral (BTC, EURC) | Each asset needs own Chainlink feed + interest model |
| Partial repayment | Adds significant complexity to interest accrual + collateral release |
| Dutch auction liquidation | Bounty-based liquidation works fine for $50 cap; auction needed only at >$10k loan size |
| ERC-8004 credit-based LTV | Requires identity infrastructure not yet productionized |
| DAO governance over insurance pool | Currently burner; will be multisig in next 7 days |

---

## Verification

```bash
$ cd contracts
$ forge test --match-contract InterAgentRepoV3Test
Ran 15 tests:
[PASS] test_AuditPoC_V2_acceptsAlreadyLiquidatableLoan       (V2 bug confirmed)
[PASS] test_AuditPoC_V2_acceptsSubGracePeriodDuration        (V2 bug confirmed)
[PASS] test_AuditPoC_V2_acceptsUsuriousRate                  (V2 bug confirmed)
[PASS] test_AuditPoC_V2_defaultTransfersFullCollateral       (V2 bug confirmed)
[PASS] test_V3_Fix1_rejectsAlreadyLiquidatableLoan           (V3 reverts)
[PASS] test_V3_Fix1_acceptsLoanInSafeRange                   (V3 happy path)
[PASS] test_V3_Fix2_rejectsSubGracePeriodDuration            (V3 reverts)
[PASS] test_V3_Fix2_acceptsMinValidDuration                  (V3 happy path)
[PASS] test_V3_Fix3_rejectsUsuriousRate                      (V3 reverts)
[PASS] test_V3_Fix3_acceptsRateAtCeiling                     (V3 happy path)
[PASS] test_V3_Fix4_defaultUsesFairSplit                     (V3 Aave-style split verified)
[PASS] test_V3_HappyPath_Originate_Then_Repay                (V3 normal flow)
[PASS] test_V3_LiquidatePath                                  (V3 liquidate unchanged)
[PASS] test_V3_Pausable_BlocksOriginate                       (V3 pausable works)
[PASS] test_V3_Pausable_UnpauseRestoresFlow                   (V3 unpause works)
```

## On-chain artifacts

- V3 contract: [`0xFfca5d80c3413Bd5D17971550cCD615f57f22945`](https://basescan.org/address/0xFfca5d80c3413Bd5D17971550cCD615f57f22945)
- V3 deploy tx: [`0x2ac8943ad54821ecdfe647da185cfe7e65c6812b512c54ddedbd7267ada186a7`](https://basescan.org/tx/0x2ac8943ad54821ecdfe647da185cfe7e65c6812b512c54ddedbd7267ada186a7)
- EIP-712 domain bumped: `("InterAgentRepo", "3")` — V2 quotes can't replay
- V2 left live for reference / historical demo, but `INTERAGENT_REPO_ADDRESS` → V3
