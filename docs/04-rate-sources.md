# Rate Sources — Live Comparison

Snapshot from **2026-05-21 ~19:00 UTC** when designing the Agent-SOFR weighting.

## Live rates observed

| Source | Type | Raw rate | Adjusted r_USD | Notes |
|--------|------|----------|----------------|-------|
| Aave V3 Base USDC supply | DeFi lend (governance-set) | 2.94% | direct | Lender side, low utilization |
| Aave V3 Base USDC borrow | DeFi borrow (governance-set) | 4.04% | direct | Borrower side |
| Aave V3 Base WETH supply | DeFi lend (governance-set) | 1.62% | direct | Thin demand |
| Aave V3 Base WETH borrow | DeFi borrow (governance-set) | 2.30% | direct | |
| Deribit PCP, ETH-26JUN26 ATM | Options put-call parity | 0.95% | **3.95%** (+ 3% staking) | Deepest options market |
| Aevo PCP, ETH-26JUN26 ATM | Options put-call parity | −0.50% | **2.50%** (+ 3% staking) | Thinner, slightly stale |
| Deribit ETH-26JUN26 futures basis | Futures cost-of-carry | 0.96% | **3.96%** (+ 3% staking) | Cross-check with PCP |
| Deribit ETH-25DEC26 futures basis | Long-dated futures | 2.75% | **5.75%** (+ 3% staking) | Reflects 6mo expected rate |
| Hyperliquid ETH-PERP funding (1h) | Perp funding rate annualized | **+5.40%** | direct | Largest perp venue, leverage demand premium |
| Deribit ETH-PERP funding | Perp funding rate annualized | 0.00% | direct | Balanced longs/shorts |
| SOFR 30-day reference (TradFi) | Sovereign benchmark | ~4.32% | direct | Macro anchor |

## Cluster analysis

Median r_USD across all market-derived sources: **~4.0%**.
Standard deviation: **~80 bps**.
Range: 2.5% (Aevo) to 5.75% (Deribit long-dated futures).

The cluster around 4% suggests fair USD short rate. Outliers above/below represent:
- Liquidity premia (long-dated futures pay term structure premium)
- Venue-specific imbalances (Aevo lagging Deribit)
- Demand spikes (HL funding +1.4% above median = ETH long crowding)

## Spread analysis

| Pair | Gap | Captureable? |
|------|-----|--------------|
| HL funding (5.40%) vs Aave borrow (4.04%) | 1.36 pp | Yes — short ETH on HL, borrow USDC on Aave, collect spread |
| Deribit PCP (3.95%) vs Aevo PCP (2.50%) | 1.45 pp | Yes — options market arbitrage |
| Aave borrow (4.04%) vs Aave supply (2.94%) | 1.10 pp | Captured by Aave protocol (10% reserve factor) |
| Deribit short-dated (3.95%) vs long-dated (5.75%) | 1.80 pp | Term premium — not arbitrageable without taking duration risk |

## Manipulation cost estimate

To move each source by ±50 bps for 60 minutes:

| Source | Cost (rough) | Method |
|--------|-------------|--------|
| Aave USDC | $0 (just one vote) | Governance proposal |
| Compound USDC | $0 (just one vote) | Governance proposal |
| Deribit options PCP | ~$50M sustained | Sustained options orderbook pressure |
| Hyperliquid funding | ~$30M position | Massive concentrated position |
| Aevo PCP | ~$5M | Thinner market |
| Deribit futures basis | ~$20M | Basis trading pressure |
| SOFR | impossible (Fed-set, transactions-based) | n/a |

**This is why Agent-SOFR weights market-derived sources at 70% and reference-only sources at 20%.** A single governance vote on Aave shifts Agent-SOFR by at most ~50 bps, not 200+ bps.

## Sourcing in implementation

| Source | Implementation | Refresh interval |
|--------|---------------|-----------------|
| Deribit options PCP | `https://www.deribit.com/api/v2/public/ticker?instrument_name=ETH-DDMMMYY-STRIKE-{C,P}` | 60s |
| Deribit futures basis | `https://www.deribit.com/api/v2/public/ticker?instrument_name=ETH-DDMMMYY` | 60s |
| Hyperliquid funding | `POST https://api.hyperliquid.xyz/info {"type":"metaAndAssetCtxs"}` | 60s |
| Aevo PCP | `https://api.aevo.xyz/orderbook?instrument_name=ETH-DDMMMYY-STRIKE-{C,P}` | 60s |
| Aave Base USDC/WETH | `eth_call` to Aave V3 Pool `getReserveData` on Base RPC | 60s |
| Compound Base USDC | `eth_call` to Compound cUSDCv3 contract | 60s |
| SOFR 30-day | NY Fed SOFR Average API (off-chain, slow) | hourly |

All public endpoints, no API keys needed except Alchemy RPC for Base reads (already in use).

## Implementation note: deriving r_USD from ETH options

ETH options on both Deribit and Aevo trade strikes in USD but settle in ETH. Put-call parity for these instruments:

```
C_USD − P_USD = S_USD − K × e^(−r_implied × T)
```

Where:
- `C_USD`, `P_USD` = call and put premiums converted to USD (multiply by ETH spot)
- `S_USD` = ETH spot price
- `K` = strike price
- `T` = time to expiry in years
- `r_implied` = implied rate

Solving: `r_implied = −ln((S − C + P) / K) / T`

**Important:** This gives `r_implied = r_USD − q_ETH` where `q_ETH` is the ETH convenience yield (mainly staking yield ≈ 3%). To extract pure USD rate:

```
r_USD = r_implied + q_ETH
```

We use Lido stETH yield as the proxy for `q_ETH` (refreshed daily — slow-moving).

## EUR rate derivation

No direct EURC options market exists. Two derivation paths:

### Path A — CME EUR/USD futures basis

```
F_EURUSD / S_EURUSD = e^((r_USD − r_EUR) × T)
⇒ r_EUR = r_USD − ln(F / S) / T
```

CME publishes `6E` futures with weekly/monthly expiries. Public data via CFTC.

### Path B — Aave EURC + correlation cross-check

Aave EURC borrow rate on Base provides a reference, weighted at 20% (since governance-set).

For Agent-SOFR v1 we use Path A as primary, Path B as cross-check.
