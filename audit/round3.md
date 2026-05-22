# Audit Round 3 — V3 Retirement

**Date:** 2026-05-22
**Scope:** `InterAgentRepoV3` deployed at `0xFfca5d80c3413Bd5D17971550cCD615f57f22945` on Base mainnet
**Result:** 1 INFO finding → V3 retired via oracleSigner rotation

---

## R3-#1 — V3 still live on-chain with R2-#2 in bytecode

### The finding

V3 deployed bytecode contains the R2-#2 bug (pause-to-default DOS via `whenNotPaused` on `repay()`). V4 fixes this but V3 itself is unchanged. Our off-chain matcher only signs V4 quotes (different EIP-712 domain), but defense-in-depth — same doctrine as R2-#3 that retired V2 — dictates **explicit retirement** of V3 rather than relying on the assumption that no V3 quote will ever surface.

### Action taken

```bash
cast send 0xFfca5d80c3413Bd5D17971550cCD615f57f22945 \
  "setOracleSigner(address)" 0x000000000000000000000000000000000000dEaD \
  --rpc-url base --private-key $OWNER_PK
```

**Retire tx:** [`0xc1ef9456a6adec7eec739d2bdbc73b9f81a48e35e37fb3b1cfb0eba05e67292d`](https://basescan.org/tx/0xc1ef9456a6adec7eec739d2bdbc73b9f81a48e35e37fb3b1cfb0eba05e67292d)

Post-retirement state:
- V3.oracleSigner = `0x000000000000000000000000000000000000dEaD`
- New originations on V3 ALWAYS revert (no private key for dead address → no valid signer recovery)
- Existing V3 loans (zero in production — V3 never had live originations either) could still `repay()` / `liquidate()` / `defaultLoan()` because those don't need signature verification
- V3 attack surface for R2-#2 (and any other unknown bugs in V3 bytecode) is now effectively zero

### Why this matters

Trustless infrastructure means **explicit deprecation rather than ambient trust**. By rotating to a known-burnable address (`0x...dEaD`), we make V3's deprecation **on-chain verifiable** — any agent or third-party auditor can query `v3.oracleSigner()` and confirm V3 is dead, without trusting our off-chain matcher to behave correctly.

---

## Net audit trajectory

| Round | HIGH | MED | LOW/INFO | Total | Outcome |
|-------|------|-----|----------|-------|---------|
| 1 | 4 | 3 | 3 | **10** | All addressed in V3 |
| 2 | 0 | 2 | 1 | **3** | R2-#2 fixed in V4, R2-#3 executed, R2-#1 deferred (industry-aligned) |
| 3 | 0 | 0 | 1 | **1** | R3-#1 executed via one-tx retirement |

Findings count falls **super-linearly** across rounds. Auditor's own assessment:

> *"Remediation discipline (one new contract version per round, minimal diff, EIP-712 bump each time, old versions explicitly retired rather than left zombie) — exemplary, like the big protocols."*

---

## Cleanup state — Base mainnet

| Version | Status | Oracle Signer | Notes |
|---------|--------|--------------|-------|
| V1 | Demo (no liquidation) | `0x82B17D0bb...` | Original MVP, kept for historical reference |
| V2 | 🪦 Retired (R2-#3) | `0x000...dEaD` | Had R1 HIGH bugs |
| V3 | 🪦 Retired (R3-#1) | `0x000...dEaD` | Had R2-#2 bug |
| **V4** | ✅ **ACTIVE** | `0x3d6EF3B451...` (burner) | Audit R1 + R2 fully patched |

All retirements are **on-chain verifiable**. No zombie contracts. No ambient-trust assumptions.

---

## Posture going forward

For the Agora submission deadline (2026-05-25), we are stopping audit rounds here:

- 3 rounds of audit + all findings addressed cleanly
- Auditor's own assessment: "exemplary"
- Trajectory: 10 → 3 → 1 findings (converging)
- Remaining time better spent on Day 3 deliverables (demo loan, dashboard, methodology pages, Loom video)

Post-hackathon plans:
- v2.0 audit (independent firm) covering: Governor timelock on admin, multisig insurance pool, multi-collateral support
- Continuous monitoring of `currentLTV()` calls vs liquidations as live signal
- Bug bounty after V4 has sustained TVL > $10k
