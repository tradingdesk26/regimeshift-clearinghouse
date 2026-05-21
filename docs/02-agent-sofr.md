# Agent-SOFR — The Oracle

## What it is

A decentralized benchmark rate for short-term borrowing/lending in the agent economy. Inspired by TradFi's SOFR (Secured Overnight Financing Rate) — but published every 60 seconds, sourced from on-chain market data, methodology fully open and IPFS-pinned.

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
  (weight: 0.70)            (weight: 0.20)              (weight: 0.10)
        │                             │                             │
   ┌────┴────┐               ┌────────┴────────┐                   │
   ▼         ▼               ▼                 ▼                   ▼
 Deribit   Aevo           Hyperliquid       Aave (Base)         SOFR (Fed)
 options   options        perp funding      USDC borrow         30-day
 PCP       PCP            (largest perp)    (largest DeFi      reference
 0.30      0.10           0.20              lending)            0.10
                                            0.10
                                            +
                                            Compound borrow
                                            0.05
                                            +
                                            Aave WETH borrow
                                            0.05
```

### Why this weighting

**Market-derived = 70%:** These rates emerge from arbitrage and competitive trading. Hard to manipulate. Deribit options PCP weighted highest because options market is deepest and most resistant to short-term pressure.

**Reference-only = 20%:** Aave/Compound rates included for sanity-check, but capped at 20% so a single governance vote cannot move Agent-SOFR by more than ~80 bps. These rates inform but don't anchor.

**Macro anchor = 10%:** TradFi SOFR included as long-horizon floor. Prevents Agent-SOFR from drifting wildly from real-economy USD short rate during illiquid crypto markets.

---

## Rate decomposition formula

```
agent_sofr(asset, horizon) =
    base_anchor(asset)                  # Weighted median of sources above
  + variance_premium(asset, horizon)    # Derman variance swap, scaled to horizon
  + jump_premium(asset, horizon)        # Merton jump-diffusion, scaled to horizon
  + regime_adjustment(asset)            # +0, +20, +50, or +200 bps based on regime
```

### Base anchor

```python
def base_anchor(asset):
    sources = fetch_all_sources(asset)
    weights = source_weights(asset)
    return weighted_median(sources, weights)
```

Sources fetched live, weights applied, median taken. Median (not mean) so outliers don't move the anchor — a single venue going stale or briefly manipulated cannot dominate.

### Variance premium (Derman)

For continuous diffusion risk over horizon T:

```
variance_premium = DVOL² × T × LTV × P_continuous_default × LGD / T
                 = DVOL² × LTV × P_continuous_default × LGD
                 (annualized)
```

Where:
- `DVOL` = Deribit Volatility Index (already a Derman variance swap fair strike)
- `LTV` = loan-to-value ratio at origination (e.g., 80%)
- `P_continuous_default` = Black-Cox first-passage approximation
- `LGD` = loss given default = 1 - recovery_rate

For ETH at DVOL=50%, LTV=80%, 24h horizon: ≈ 5-10 bps annualized.

### Jump premium (Merton)

For Poisson-driven discrete jumps:

```
jump_premium = λ × T × E[J²] × LTV × LGD / T
             = λ × E[J²] × LTV × LGD
             (annualized)

where E[J²] = (α² + δ²) for J ~ lognormal(α, δ)
```

Calibrated from 90-day jump history per asset:

| Asset | λ (jumps/year) | α (mean) | δ (vol) |
|-------|----------------|----------|---------|
| ETH   | ~40            | -0.01    | 0.04    |
| BTC   | ~30            | -0.008   | 0.035   |
| EUR/USD | ~5           | 0        | 0.01    |
| USD/USD | ~0           | 0        | 0       |

For ETH at LTV=80%: ≈ 30-50 bps annualized over short horizons (jumps dominate at small T).

### Regime adjustment

Imports from existing `regimeshift-fx/regime_classifier`:

| Regime | Premium |
|--------|---------|
| LOW    | +0 bps  |
| MID    | +20 bps |
| HIGH   | +50 bps |
| EXTREME| +200 bps|

When regime classifier flags HIGH or EXTREME, all rates spike — protecting lenders during volatile periods. When LOW, rates compress — encouraging utilization.

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
  "rate": 4.07,
  "decomposition": {
    "base_anchor": 3.95,
    "variance_premium": 0.04,
    "jump_premium": 0.03,
    "regime_adjustment": 0.05
  },
  "sources": {
    "deribit_pcp_30d": 3.95,
    "deribit_basis_3m": 3.85,
    "aevo_pcp": 3.40,
    "hl_funding_smoothed": 4.85,
    "aave_borrow_usdc": 4.04,
    "compound_borrow_usdc": 4.12,
    "aave_borrow_weth": 2.30,
    "sofr_30d": 4.32
  },
  "weights_applied": {
    "deribit_pcp_30d": 0.30,
    "deribit_basis_3m": 0.10,
    "aevo_pcp": 0.10,
    "hl_funding_smoothed": 0.20,
    "aave_borrow_usdc": 0.10,
    "compound_borrow_usdc": 0.05,
    "aave_borrow_weth": 0.05,
    "sofr_30d": 0.10
  },
  "regime": "MID",
  "methodology": {
    "url": "https://regimeshift.xyz/methodology/agent-sofr-v1",
    "ipfs": "QmXXX...",
    "hash": "0xYYY..."
  },
  "computed_at": 1779380000,
  "valid_until": 1779380060,
  "cache_ttl_sec": 60
}
```

### Pricing

$0.001 per call (same as VRP endpoints). x402 paywall on Base mainnet. CDP facilitator for settlement.

### Signed quote variant

For use in InterAgentRepo settlement, an additional endpoint returns an EIP-712 signed quote:

```
GET /v1/rate/sofr/{asset}/signed?horizon={h}&loan_id={uuid}

Returns the rate + decomposition + EIP-712 signature from Agent-SOFR oracle keypair
that can be verified by InterAgentRepo.sol on-chain.
```

This is what enables off-chain quote generation → on-chain settlement.

---

## Methodology versioning

Each version of the methodology is pinned to IPFS. API response includes the IPFS hash for that version.

```
agent-sofr-v1.md           QmAAA...  (current — Day 1 of clearinghouse)
agent-sofr-v2.md           future    (refinements based on observed usage)
```

If we change weighting, add a source, or update the regime classifier, we bump the version and pin a new IPFS doc. Old methodologies remain queryable for historical verification.

**Trust through immutable transparency.** Any agent that paid for a rate at time T can verify exactly which formula produced it.

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

- **v1 (Day 1):** Initial launch with current source list, fixed weights, regime adjustment
- **v2 (post-hackathon):** Dynamic weights based on source liquidity (Kelly-style optimal)
- **v3 (Q1 2026):** ZK proofs of correct computation (zk-circuits over the aggregation logic)
- **v4 (Q2 2026):** Multi-region Agent-SOFR (JPY, GBP, USDT-anchored variants)
