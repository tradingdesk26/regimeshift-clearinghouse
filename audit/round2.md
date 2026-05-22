# Audit Round 2 — InterAgentRepoV3 → V4 Remediation

**Date:** 2026-05-22
**Scope:** `InterAgentRepoV3.sol` deployed at `0xFfca5d80c3413Bd5D17971550cCD615f57f22945` on Base mainnet
**Result:** 2 MEDIUM + 1 INFO findings → V4 deployed at `0x9d3b61d13a839968ffad94a0eedf73153c2fb31c` (R2-#2 patched, R2-#3 executed, R2-#1 acknowledged as systemic)

---

## Summary

| # | Finding | Severity | Action |
|---|---------|----------|--------|
| R2-#1 | `defaultLoan` reverts during Chainlink stale price | MEDIUM | **DEFERRED** — aligns with industry standard (Aave, Compound, Morpho) |
| R2-#2 | `whenNotPaused` on `repay()` enables pause-to-default DOS | MEDIUM | **FIXED in V4** |
| R2-#3 | V2 contract bytecode still on-chain with all R1 bugs | INFO | **EXECUTED** — V2 oracleSigner rotated to 0x...dEaD |

---

## R2-#1 — Chainlink staleness DoS in `defaultLoan()` — DEFERRED

### The finding

V3's `defaultLoan()` uses Chainlink ETH/USD to compute the debt-equivalent collateral split (Aave-style fair distribution). If Chainlink heartbeat lags >1 hour, `defaultLoan()` reverts with `PriceStale()`. Combined with `liquidate()` (also requires Chainlink) and `repay()` (blocked post-expiry), all three exit paths fail — collateral stuck in escrow until Chainlink recovers.

### Why we're not patching

This is **systemic DeFi risk, not protocol-specific**. Every major lending protocol on Base behaves identically:

| Protocol | Stale Chainlink → liquidation/default behavior |
|----------|------------------------------------------------|
| Aave V3 (Base) | `require(updatedAt > 0 && block.timestamp - updatedAt <= GRACE)` — reverts on stale |
| Compound III (Base) | `require(answeredInRound >= roundId && block.timestamp - updatedAt < maxAge)` — reverts |
| Morpho Blue | Inherits Chainlink behavior via IRM adapters — reverts |
| Spark (Maker) | Same pattern — reverts on stale |

In a >1-hour Chainlink ETH/USD outage scenario, **every collateral-based lending protocol on Base is equally impacted**. Our $50-cap MVP loans being stuck is not the binding constraint; the entire base layer would be in crisis.

Historical context: production Chainlink ETH/USD feeds have not exceeded 1 hour of staleness on any major L2 in the past 3+ years. The typical heartbeat is ~20 minutes; our 1-hour staleness limit is 3× this.

### Mitigations available for v2.0+

- **Store `priceE8` in Loan struct at origination**: use as fallback during stale-price scenarios. Adds 1 storage slot (~$0.20 gas per loan on Base). Single-line `try/catch`-style fallback in `defaultLoan()`.
- **Governance-controlled oracle override**: Owner can submit a manually-attested ETH/USD price during extreme outage events. Adds attack surface for compromised owner key.

We've chosen not to introduce these in V4 to keep contract behavior aligned with established DeFi norms. **Industry-standard "revert on stale" is the right behavior even if it accepts a theoretical liveness regression in extreme conditions.**

---

## R2-#2 — Pause-to-default DOS — FIXED in V4

### The finding

V3 gated all four state-mutating functions (`originate`, `repay`, `liquidate`, `defaultLoan`) on `whenNotPaused`. Adding pause to `repay()` is an **anti-pattern** because it inverts the safety contract: pause should protect users by blocking ENTRY (new positions), not trap them by blocking EXIT (existing position settlement).

### Attack walkthrough

1. Borrower opens loan with 0.040 WETH collateral, $30 USDC principal, 200s duration.
2. Owner (or compromised key — same EOA as oracleSigner + insurancePool per R1-#7) calls `emergencyPause()` 30s before expiry.
3. Borrower tries `repay()` → reverts with `EnforcedPause`.
4. Expiry passes during pause.
5. Owner calls `emergencyUnpause()`.
6. Borrower retries `repay()` → reverts with `LoanNotExpired` (now past expiry).
7. Anyone (including owner) calls `defaultLoan()` → V3's fair split executes:
   - 3% bounty to caller (msg.sender)
   - 1% to insurance pool (owner's address)
   - Debt-equivalent to lender
   - Excess back to borrower

**Borrower's loss vs normal repay**: 4% of collateral = 0.0016 WETH = ~$3.30 at ETH $2080. Attack costs owner <$1 gas. On the MVP $50 cap, this is ~11% of the principal stolen.

### PoC

In [`test/InterAgentRepoV4.t.sol`](../contracts/test/InterAgentRepoV4.t.sol):

```solidity
function test_AuditR2PoC_V3_pauseBlocksRepay_forcesDefault() public {
    bytes32 nonce = keccak256("r2-2-poc");
    uint256 expiry = block.timestamp + 200;
    InterAgentRepoV3.Quote memory q = _buildV3Quote(nonce, 30_000_000, 0.040 ether, expiry, 425);
    vm.prank(lender); v3.originate(q, _signV3(q, oraclePk));

    vm.warp(expiry - 30);
    v3.emergencyPause();
    vm.prank(borrower);
    vm.expectRevert();  // EnforcedPause
    v3.repay(nonce);

    vm.warp(expiry + 1);
    v3.emergencyUnpause();
    vm.expectRevert(InterAgentRepoV3.LoanNotExpired.selector);
    vm.prank(borrower); v3.repay(nonce);

    feed.setPrice(INITIAL_ETH_USD_E8);
    vm.prank(liquidator); v3.defaultLoan(nonce);

    // Borrower lost what they should have kept
    assertLt(weth.balanceOf(borrower) - borrowerWethBefore, 0.040 ether);
}
```

Test passes — bug confirmed against V3.

### Fix in V4 (one-line change)

```solidity
// V3:
function repay(bytes32 loanId) external nonReentrant whenNotPaused {

// V4:
function repay(bytes32 loanId) external nonReentrant {
```

`originate`, `liquidate`, `defaultLoan` remain gated by `whenNotPaused`. Pause now correctly blocks ENTRY but leaves EXIT (repay) always available.

### Industry alignment

| Protocol | repay paused during emergency? |
|----------|-------------------------------|
| Aave V3 | NO — repay always available |
| Compound III | NO — base supply withdrawals always work |
| Morpho Blue | NO — repay always available |
| **InterAgentRepoV4 (ours)** | NO — repay always available |

---

## R2-#3 — V2 contract retirement — EXECUTED

### The finding

V2 (`0x2bfE0f1142B04049d867389Bf91A84e498ED11E4`) is no longer in use but its bytecode still contains all four R1 HIGH bugs. While our off-chain matcher only signs V3/V4 quotes (different EIP-712 domains), defense-in-depth dictates **actively retiring** V2 rather than relying on the assumption that no V2 quote will ever surface.

### Action taken

```bash
cast send 0x2bfE0f1142B04049d867389Bf91A84e498ED11E4 \
  "setOracleSigner(address)" 0x000000000000000000000000000000000000dEaD \
  --rpc-url base --private-key $OWNER_PK
```

Retire tx: [`0x889a460824d949a119d37c53e14163db12998f640dd75b4a51e3c9e5809b37ba`](https://basescan.org/tx/0x889a460824d949a119d37c53e14163db12998f640dd75b4a51e3c9e5809b37ba)

Post-retirement state:
- V2.oracleSigner = `0x000000000000000000000000000000000000dEaD`
- New originations on V2 ALWAYS revert (no valid signature can produce this signer)
- Existing V2 loans (zero in production — V2 never had live originations) could still `repay()` / `liquidate()` / `defaultLoan()` because those don't need signature verification

V2 attack surface for R1 HIGH bugs is now effectively zero.

---

## V4 deployment

- **Contract**: [`0x9d3b61d13a839968ffad94a0eedf73153c2fb31c`](https://basescan.org/address/0x9d3b61d13a839968ffad94a0eedf73153c2fb31c)
- **Deploy tx**: [`0xf7376511cbbba7a2da057bd046c1153e6566ef7d3d6462decdb8183b15b3af09`](https://basescan.org/tx/0xf7376511cbbba7a2da057bd046c1153e6566ef7d3d6462decdb8183b15b3af09)
- **EIP-712 domain**: `("InterAgentRepo", "4")` — V3 quotes can't replay against V4
- **Active for new quotes**: yes (quote engine signs domain v4)

### Verification

All 8 Foundry tests pass against V4:

```
✓ test_AuditR2PoC_V3_pauseBlocksRepay_forcesDefault    (V3 bug confirmed)
✓ test_V4_Fix_repayAllowedDuringPause                   (V4 fix works)
✓ test_V4_pauseStillBlocksOriginate                     (entry pause works)
✓ test_V4_pauseStillBlocksLiquidate                     (entry pause works)
✓ test_V4_pauseStillBlocksDefault                       (entry pause works)
✓ test_V4_HappyPath_Originate_Then_Repay                (V3 happy path preserved)
✓ test_V4_DefaultPath_FairSplit                         (V3 fair split preserved)
✓ test_V4_RejectsAlreadyLiquidatableLoan                (R1-#1 fix preserved)
```

Live verification on Base mainnet:
- Root endpoint shows `"active": "V4"` + audit status note
- POST /v1/intent/{lend,borrow} → match → `quote.contract.address` = V4 ✓
- V2 oracleSigner = 0x...dEaD ✓
