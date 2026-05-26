# Agent-SOFR — The Oracle

## What it is

A decentralized benchmark rate for short-term borrowing/lending in the agent economy. Inspired by TradFi's SOFR (Secured Overnight Financing Rate) — but published every 60 seconds, sourced from on-chain market data, methodology fully open and IPFS-pinned.

**Production calibration heritage:** Regime classifier and jump-diffusion parameters are inherited from [ARMSHookV3](https://github.com/tradingdesk26/arms) — our Uniswap v4 hook deployed on Base mainnet. Calibrated on 730 days of ETH/USDT 5-minute bars (210,228 observations). We don't ship hand-picked numbers; we ship production-tested ones.

**Three rates published:**

| Endpoint | What it represents |
|----------|-------------------|
| `/v1/rate/sofr/usd?horizon={d}` | Fair USD short-term rate for collateralized agent borrowing |
| `/v1/rate/sofr/eur?horizon={d}` | Fair EUR rate (derived via FX cross from USD) |
| `/v1/rate/sofr/eth?horizon={d}` | Fair ETH rate (cost of holding ETH, includes staking yield) |

`horizon` parameter: `1m`, `5m`, `30m`, `1h`, `4h`, `24h` (different jump premium at different horizons).

---

## Why a new benchmark?

Existing rate signals are all flawed for agent use:

| Source | Problem |
|--------|---------|
| Aave USDC borrow rate | Governance-set, reflexive incentives, manipulation risk |
| Compound rates | Same |
| Fed Funds / SOFR | Off-chain, no real-time integration with on-chain agents |
| Chainlink price feeds | Centralized oracle network, censorship risk |
| Single-exchange perp funding | Venue-specific manipulation possible |

**Agent-SOFR aggregates multiple market-derived sources, weights by manipulation resistance, and publishes with full decomposition.** No single source can move the rate alone.

---

## Source aggregation

```
                  ┌───────────────────────────────────────┐
                  │            Agent-SOFR Oracle           │
                  │       (refresh every 60s, cached)       │
                  └───────────────────┬───────────────────┘
                                      │
        ┌─────────────────────────────┼─────────────────────────────┐
        │                             │                             │
        ▼                             ▼                             ▼
  MARKET-DERIVED            REFERENCE-ONLY              MACRO ANCHOR
  (weight: 0.75)            (weight: 0.15)              (weight: 0.10)
        │                             │                             │
   ┌────┴────┐               ┌────────┴────────┐                   │
   ▼         ▼               ▼                 ▼                   ▼
 Deribit   Aevo           Hyperliquid       Aave V3 (Base)      SOFR (Fed)
 options   options        perp funding      USDC borrow         30-day
 PCP       PCP            (largest perp)    (DeFi reference)   reference
 0.32      0.11           0.22              0.10                0.10
                                            +
                                            Compound USDC borrow
                                            0.05
                          (Deribit basis 3m
                           0.10 — sanity)
```

### Why this weighting

**Market-derived = 75%:** These rates emerge from arbitrage and competitive trading. Hard to manipulate. Deribit options PCP weighted highest because options market is deepest and most resistant to short-term pressure.

**Reference-only = 15%:** Aave/Compound **USDC** rates included for sanity-check, but capped so a single governance vote cannot move Agent-SOFR by more than ~60 bps. These rates inform but don't anchor.

**Macro anchor = 10%:** TradFi SOFR included as long-horizon floor. Prevents Agent-SOFR from drifting wildly from real-economy USD short rate during illiquid crypto markets.

**Why not WETH borrow rate:** It's the ETH lending market (interest paid in ETH), structurally separate from USDC short rate. Including it would pollute the signal — we measure the rate at which agents borrow USD against ETH collateral, not the rate at which someone borrows ETH itself. Removed in v1.0.1.

---

## Rate decomposition formula

```
agent_sofr(asset, horizon) =
    base_anchor(asset)                  # Weighted median of market sources
  + variance_premium(asset, horizon)    # Total variance: continuous + jump
  + regime_adjustment(asset)            # 6-mode regime ladder, calibrated
```

### Base anchor

```python
def base_anchor(asset):
    sources = fetch_all_sources(asset)
    weights = source_weights(asset)
    return weighted_median(sources, weights)
```

Sources fetched live, weights applied, median taken. Median (not mean) so outliers don't move the anchor — a single venue going stale or briefly manipulated cannot dominate.

### Total variance premium (continuous + jump combined)

We use the **production-tested variance decomposition** from ARMSHookV3 instead of inventing new math:

```
total_variance_per_bar = cv + λ·j²

  where:
    cv = continuous variance (Derman-style, 5-min realized variance excluding jumps)
    j² = jump variance squared (Merton spike component, |r| > p95 threshold)
    λ  = 1.097  (calibrated jump weight; see arms/src/bench/FeeFormulaV2.sol)
```

This is the **exact formula deployed on-chain** in our Uniswap v4 hook. `cv` and `j²` are computed live from price data using a rolling 1h window (12 bars) for sub-hour quotes, and 4h window (48 bars) for hourly-and-above.

For an arbitrary horizon T (expressed in 5-min bars):

```
variance_over_T = (cv + λ·j²) × T

variance_premium(T) = √variance_over_T × LTV × P_default(LTV, σ_T) × LGD × (1 year / T)
                    (annualized)
```

Where:
- `P_default` = Black-Cox first-passage probability of LTV breach
- `LGD` ≈ 1 - 0.95 = 5% (conservative recovery from liquidation slippage)

For ETH at LTV=80%:
- 1h horizon in RESTING regime: ≈ 4 bps annualized
- 1h horizon in HIGH regime: ≈ 60 bps annualized
- 24h horizon in EXTREME regime: ≈ 300 bps annualized

### Regime adjustment (6-mode ladder, production-calibrated)

The 6-mode classifier matches our [ARMSHookV3 hook](https://github.com/tradingdesk26/arms/blob/main/src/bench/FeeFormulaV2.sol) deployed on Base mainnet. Calibration source: [`research/round25_calibration.csv`](https://github.com/tradingdesk26/arms/blob/main/research/round25_calibration.csv) — 210,228 ETH/USDT 5-min bars (2024-04-26 → 2026-04-26).

| Mode | σ_5min boundary | Time-share | Risk premium |
|------|-----------------|-----------|--------------|
| **RESTING** | < 14.2 bp | 46.4% | +0 bps |
| **LOW** | 14.2 – 17.8 bp | 15.6% | +5 bps |
| **NORMAL** | 17.8 – 23.3 bp | 16.0% | +15 bps |
| **ELEVATED** | 23.3 – 34.4 bp | 14.3% | +30 bps |
| **HIGH** | 34.4 – 62.9 bp | 6.7% | +60 bps |
| **EXTREME** | > 62.9 bp | 1.1% | +200 bps |

**Hysteresis:** Up-transitions are instant (shocks priced immediately, no lag). Down-transitions require σ to fall 10% below the boundary (`eps_down = 0.10`). This cuts mode-changes per day from 33.7 (naive) to 24.1 (-30%) while preserving 100% of HIGH/EXTREME shock-coverage. Source: [`research/cooldown_matrix.py`](https://github.com/tradingdesk26/arms/blob/main/research/cooldown_matrix.py).

**Premium curve rationale:** Mirrors RegimeCaps.sol retail fee escalation (0.9 / 5 / 20 / 60 / 120 / 250 bp), scaled down to 24h loan horizons. The exponential shape (not linear) reflects empirical jump distribution — HIGH and EXTREME modes have much larger expected losses than linear extrapolation suggests.

**Asset extension:** ETH thresholds are authoritative. For BTC, we scale by historical volatility ratio (BTC ≈ 0.85× ETH RV). For EUR/USD (pegged stablecoin pair), we use Aave-derived thresholds with ETH-relative scaling (≈ 0.05× ETH). Re-calibration per asset is roadmap (v2).

---

## API specification

### `GET /v1/rate/sofr/{asset}?horizon={h}`

**Asset:** `usd`, `eur`, `eth`
**Horizon:** `1m`, `5m`, `30m`, `1h`, `4h`, `24h`

**Response (200 OK after x402 settlement):**

```json
{
  "ok": true,
  "asset": "USD",
  "horizon": "1h",
  "rate": 4.12,
  "decomposition": {
    "base_anchor": 3.95,
    "variance_premium": 0.02,
    "regime_adjustment": 0.15
  },
  "sources": {
    "deribit_pcp_30d": 4.05,
    "deribit_basis_3m": 4.74,
    "aevo_pcp": 3.00,
    "hl_funding_smoothed": 10.95,
    "aave_borrow_usdc": 4.17,
    "compound_borrow_usdc": null,
    "sofr_30d": 4.32
  },
  "weights_applied": {
    "deribit_pcp_30d": 0.32,
    "deribit_basis_3m": 0.10,
    "aevo_pcp": 0.11,
    "hl_funding_smoothed": 0.22,
    "aave_borrow_usdc": 0.10,
    "compound_borrow_usdc": 0.05,
    "sofr_30d": 0.10
  },
  "regime": {
    "mode": "NORMAL",
    "mode_index": 2,
    "sigma_5min_bp": 19.8,
    "thresholds_bp": {
      "p50": 14.2,
      "p65": 17.8,
      "p80": 23.3,
      "p93": 34.4,
      "p99": 62.9
    }
  },
  "variance": {
    "cv_per_bar": 1.85e-6,
    "j2_per_bar": 3.21e-7,
    "lambda": 1.097,
    "total_per_bar": 2.20e-6
  },
  "methodology": {
    "url": "https://regimeshift.xyz/methodology/agent-sofr-v1",
    "ipfs": "QmXXX...",
    "hash": "0xYYY...",
    "calibration_source": "arms/research/round25_calibration.csv",
    "calibration_data": "210228 ETH/USDT 5-min bars (2024-04-26 → 2026-04-26)"
  },
  "computed_at": 1779380000,
  "valid_until": 1779380060,
  "cache_ttl_sec": 60
}
```

### Pricing

**Current price: $0.001 per call — onboarding tier.** Held at the minimum probe amount (matches what external agents pay when evaluating unknown services) to keep the friction floor near zero while we acquire organic traffic. Eventual target: $0.10 (Messari Enterprise tier — Agent-SOFR is a category-defining product, no other on-chain decentralized USD benchmark rate exists). x402 paywall on Base mainnet, two-tier facilitator (CDP primary + self-hosted fallback).

All other paid endpoints follow the same onboarding tier ($0.001). Post-acquisition target tiers: VRP $0.005 (CMC-pro), max-LTV $0.005 (risk signal), signed loan quotes $0.05 flat / 5 bps of principal (action tier).

### Signed quote variant

For use in InterAgentRepo settlement, an additional endpoint returns an EIP-712 signed quote:

```
GET /v1/rate/sofr/{asset}/signed?horizon={h}&loan_id={uuid}

Returns the rate + decomposition + EIP-712 signature from Agent-SOFR oracle keypair
that can be verified by InterAgentRepo.sol on-chain.
```

This is what enables off-chain quote generation → on-chain settlement.

### Max-safe-LTV endpoint

The same calibrator that prices rates also produces **maximum-safe LTV** for any loan configuration. This is a separately-callable paid endpoint:

```
GET /v1/risk/max-ltv?asset={asset}&duration_sec={N}&max_default_prob={p}
```

**Response (200 OK after x402 settlement, $0.001):**

```json
{
  "ok": true,
  "asset": "ETH",
  "duration_sec": 3600,
  "max_default_prob": 0.001,
  "max_ltv": 0.962,
  "regime": "NORMAL",
  "regime_cap_ltv": 0.92,
  "math_max_ltv": 0.962,
  "binding_constraint": "math",
  "sigma_T": 0.00514,
  "computed_at": 1779380000,
  "valid_until": 1779380060,
  "methodology": {
    "url": "https://regimeshift.xyz/methodology/agent-sofr-v1",
    "hash": "0xYYY..."
  }
}
```

**Why it's a separate endpoint:** Any agent or protocol doing their own loan/lending logic needs the max-safe-LTV signal — not just users of our matching engine. We sell the **risk signal** independently of the marketplace. Aave or any competing protocol could query this to inform their own LTV decisions.

**Three quote-mode endpoint** for loan-specific full pricing:

```
POST /v1/quote
{
  "principal_asset": "USDC",
  "principal_amount": 50,
  "collateral_asset": "WETH",
  "mode": "compute_rate" | "compute_collateral" | "compute_max_duration",
  // Plus the two fixed inputs depending on mode
}
```

Returns a fully-signed EIP-712 quote ready for `InterAgentRepo.originate()`. Price: $0.0002 (more compute per call than raw rate).

---

## Methodology versioning

Each version of the methodology is pinned to IPFS. API response includes the IPFS hash for that version.

```
agent-sofr-v1.md           QmAAA...  (current — Day 1 of clearinghouse)
agent-sofr-v2.md           future    (refinements based on observed usage)
```

If we change weighting, add a source, or update the regime classifier, we bump the version and pin a new IPFS doc. Old methodologies remain queryable for historical verification.

**Trust through immutable transparency.** Any agent that paid for a rate at time T can verify exactly which formula produced it.

### Calibration provenance

Each methodology version cites its **calibration provenance** — what data was used to produce the constants in the formula:

| Constant | Value | Source | Calibration period |
|----------|-------|--------|-------------------|
| σ thresholds (p50/p65/p80/p93/p99) | 14.2 / 17.8 / 23.3 / 34.4 / 62.9 bp | `arms/research/percentile_grid.py` | 2024-04-26 → 2026-04-26 (730d, 210k bars) |
| λ (jump weight) | 1.097 | `arms/research/round25_calibration.csv` | Same as above |
| Hysteresis ε_down | 0.10 (10%) | `arms/research/cooldown_matrix.py` | Same — optimized for naive→hysteresis mode-change rate reduction |
| Regime premium (RESTING/LOW/.../EXTREME) | 0 / 5 / 15 / 30 / 60 / 200 bps | Derived from RegimeCaps.sol fee schedule, scaled to loan horizons | Production hook live since 2026-04 |
| Source weights | 75/15/10 (market/reference/macro) | This document | v1 defined 2026-05-21; v1.0.1 removed WETH borrow source 2026-05-22 |

When we update any of these, the methodology version bumps. Old API responses remain verifiable against their original methodology hash.

---

## Why this is hard to manipulate

- **Six independent sources** — no single venue can dominate
- **Weighted median (not mean)** — outliers don't move the result
- **60-second refresh** — sustained manipulation needed, not flash
- **Market-derived weight = 70%** — governance-set sources capped at 20%
- **Methodology IPFS-pinned** — cannot be silently changed
- **Open source** — formula is auditable, no black boxes

Estimated cost to move Agent-SOFR by ±50 bps for one hour:
- Manipulating Deribit options PCP: ~$50M sustained capital
- Manipulating HL perp funding: ~$30M sustained position
- Combination needed (since each is ≤30% weight): ~$100M+

For comparison, manipulating Aave USDC borrow rate by similar amount = one successful governance vote.

---

## Roadmap

- **v1 (Day 1):** Three rate endpoints (USD/EUR/ETH) + max-LTV endpoint, fixed weights, 6-mode regime adjustment inherited from production ARMSHookV3
- **v1.1 (Day 2-3):** Three quote-mode endpoint (compute_rate / compute_collateral / compute_max_duration) — exposes the calibrator surface to borrowers
- **v1.2 (Day 3-4):** Per-asset calibration for BTC, EUR (currently using ETH-scaled defaults)
- **v2 (post-hackathon):** Dynamic source weights based on observed liquidity / spread (Kelly-style optimal)
- **v2.1:** Continuous re-calibration of σ thresholds — rolling 730d window with monthly recompute
- **v3 (Q1 2026):** ZK proofs of correct computation (zk-circuits over the aggregation logic)
- **v4 (Q2 2026):** Multi-region Agent-SOFR (JPY, GBP, USDT-anchored variants)

---

## Reference implementations

The math is not new — what's new is the *agent-native distribution* of it. References:

- **Variance + jump decomposition (cv + λ·j²):** Deployed in [`ARMSHookV3.sol`](https://github.com/tradingdesk26/arms/blob/main/src/bench/ARMSHookV3.sol) (Base mainnet, live since 2026-04)
- **6-mode classifier with hysteresis:** [`FeeFormulaV2.classifyModeHyst`](https://github.com/tradingdesk26/arms/blob/main/src/bench/FeeFormulaV2.sol)
- **σ threshold calibration:** [`research/percentile_grid.py`](https://github.com/tradingdesk26/arms/blob/main/research/percentile_grid.py)
- **Hysteresis tuning:** [`research/cooldown_matrix.py`](https://github.com/tradingdesk26/arms/blob/main/research/cooldown_matrix.py)
- **Volatility calibration scripts:** [`research/vol_calibration.py`](https://github.com/tradingdesk26/arms/blob/main/research/vol_calibration.py)
- **Calibration CSV:** [`research/round25_calibration.csv`](https://github.com/tradingdesk26/arms/blob/main/research/round25_calibration.csv)

**The hackathon contribution is not the math — it's wrapping production-tested math behind a paid x402 oracle and using it to price the agent-to-agent repo market.**
