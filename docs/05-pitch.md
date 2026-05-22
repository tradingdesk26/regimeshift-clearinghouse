# Submission Pitch — Agora Agents Hackathon

## Project info

- **Project name:** RegimeShift
- **RFB target:** 04 — Adaptive Portfolio Manager
- **Demo URL:** https://regimeshift.xyz
- **GitHub:** https://github.com/tradingdesk26/regimeshift-clearinghouse (made public on submission day)
- **Related repos:** [vrp-agent](https://github.com/tradingdesk26/vrp-agent), [armsys-signals](https://github.com/tradingdesk26/armsys-signals), [regimeshift-fx](https://github.com/tradingdesk26/regimeshift-fx)

---

## One-line pitch

The first decentralized benchmark rate for AI agents (Agent-SOFR), plus the bilateral RFQ marketplace that lets agents lend, borrow, and swap collateralized capital at sub-hour horizons — built on Base mainnet with our adaptive portfolio agent as the first reference customer.

---

## Two-paragraph version

RegimeShift is an autonomous portfolio agent that's already running on Base mainnet — classifying volatility regimes, allocating across Uniswap v4 LP, Hyperliquid perps, and defensive cash, and rebalancing via CCTP V2 cross-chain bridges. Yesterday it caught its first **organic** paid call: a cross-service AI agent (which also pays CMC, CoinGecko, and Messari) paid $0.001 for our ETH VRP signal. Settled on-chain. Real revenue.

But the deeper play is what we've identified through running this agent in production: **DeFi 1.0 was built for humans on week-to-month timescales, not for agents who optimize at minute-to-hour scale**. Aave's governance-set rates are reflexive and manipulable. Uniswap's whitelist gating is bureaucratic. AMMs add slippage and LVR for no benefit when agents can bilateral-quote in milliseconds. So we're building the three primitives agents actually need: **(1) market-derived rate benchmarks (Agent-SOFR), (2) verifiable open-source formulas with IPFS-pinned methodology, and (3) blockchain as registry — not as trading venue**. Our portfolio agent is the first user; every other adaptive portfolio agent will be the next.

---

## Long-form for submission writeup

### The problem

Existing DeFi infrastructure breaks for agents in three structural ways:

**1. Timescale.** Aave/Compound are designed for week+ deposits. Gas costs (~$0.02 on Base) exceed yield over short durations. Agent rebalancing happens hourly, sometimes more often. Math: at 5% APY on $100, you earn $0.0006/hour. Breakeven for a single Aave round-trip is ~4 hours. Agents need access at minute-scale, which is mathematically negative-EV on Aave.

**2. Rate source.** Aave's interest rates are governance-set parameters (`baseVariableBorrowRate`, `variableRateSlope1`, etc.). One vote changes them. Reflexive incentive loops (AAVE token rewards inflate effective APY) create structural pyramid risk. Agents need rates that are arbitrage-resistant and market-derived, not voted-upon.

**3. Settlement primitive.** AMMs (Uniswap, Balancer) compensate for the absence of human market makers by using constant function curves with slippage and LVR. Agents CAN auto-quote. TradFi doesn't use AMMs for major markets — equities, FX, bonds all use bilateral RFQ or CLOBs. Same applies to agent-to-agent capital flows.

### The solution

Three primitives, mirroring TradFi's architecture but on permissionless rails:

| TradFi function | Our equivalent |
|-----------------|----------------|
| Bloomberg / Refinitiv (data feeds) | x402 paid endpoints (`/v1/asset/eth/vrp`, `/v1/rate/sofr/usd`) |
| Exchange matching | Off-chain bilateral RFQ engine |
| DTCC / clearinghouse | On-chain settlement contract (`InterAgentRepo.sol`) |
| Trade repository | On-chain event logs + IPFS methodology hashes |
| Identity / KYC | ERC-8004 agent identity |

**Compute happens off-chain at agent speed. Blockchain is the trust anchor — identity, payments, audit trail.** Same pattern TradFi has used for 50 years, applied to permissionless agentic finance.

### What's live today

- **Adaptive portfolio agent** on Base mainnet with real capital (~$105 AUM, growing)
- **Custom Uniswap v4 hook** (ARMSHookV3) — regime-aware dynamic fees, materially reduces LVR; submitted to Uniswap whitelist review after ~1.5× TVL traded in first 14 hours
- **CCTP V2 cross-chain** Base ↔ HyperEVM, 180s settlement, zero failed transfers since resilience fixes
- **Two paid x402 data endpoints** — ETH VRP and BTC VRP, both with on-chain validated settlements
- **First organic paid call** caught 2026-05-20 from a cross-service AI agent
- **Listed on agentic.market** (Bazaar discovery)

### What we're shipping for the hackathon (4 days)

- **Agent-SOFR Oracle** — three new paid endpoints publishing fair USD/EUR/ETH rates, aggregated from Deribit options PCP, Hyperliquid perp funding, Deribit futures basis, Aevo options, Aave/Compound (reference only), SOFR (macro anchor). Weighted to be manipulation-resistant.
- **`InterAgentRepo.sol`** — escrow + settlement contract on Base for collateralized agent loans. EIP-712 signed quote verification. Originate / repay / default paths.
- **Off-chain matching engine** — intent submission, priority queue, EIP-712 quote generation. REST API for lender and borrower intents.
- **Live demo loan** — real $5-10 loan between two test wallets, originate + repay on-chain.
- **Methodology pages** — IPFS-pinned, hash-referenced in API responses. Trust through transparency.
- **Closed-loop integration** — our own agent uses the marketplace it operates. When in `DEFENSIVE_CASH`, auto-submits lender intent. Endogenous bootstrap liquidity.
- **Match notifications — no polling required** — `webhook_url` push (Variant A) for hosted agents, `GET /v1/intent/{id}/match?wait=N` long-poll (Variant B) for local/serverless. End-to-end tested: webhook delivers signed quote within ~1s of match. Industry-aligned with Stripe/GitHub webhook patterns.

### Why this is RFB 04

RFB 04 — Adaptive Portfolio Manager — explicitly lists RegimeShift as an example build. Our submission delivers:

| RFB 04 ask | What's live |
|-----------|-------------|
| Asset allocation based on market regime | LOW/MID/HIGH classifier drives 3-bucket allocation |
| When to rebalance vs let winners run | Cross-zero VRP triggers + persistent-mode upgrade |
| Yield allocation during risk-off | DEFENSIVE_CASH → soon: lender intent in our own marketplace |
| Correlation-based diversification (DeFi + TradFi) | Uniswap LP + Hyperliquid perp + Aevo options (next) |
| Risk management — reduce exposure during high vol | Stop-loss, VRP sign flip, de-risk to USDC |
| Cross-chain rebalancing with CCTP / Gateway | CCTP V2 in production |
| Tax-loss harvesting | Trade log persisted, harvester layer on roadmap |
| Regime detection w/ automatic allocation | Core of agent state machine |

But we go beyond RFB 04 — we're building the **infrastructure layer** that other RFB 04 submissions will need to consume. Every other portfolio manager needs a rate signal. Every other portfolio manager needs to park idle capital somewhere. Every other portfolio manager needs cross-chain bridges. **We're building those, with our own portfolio manager as the first user.**

### Traction metrics (as of Day 2 — 2026-05-21)

```
Live on Base mainnet since:      2026-04-26 (~4 weeks at submission)
AUM under agent management:      ~$105 of own capital + active LP positions
Paid x402 endpoints live:        4 (ETH VRP, BTC VRP, USD SOFR, max-LTV)
On-chain organic paid calls:     1 (cross-service AI agent on /v1/asset/eth/vrp)
Self-validated paid calls:       4 (one per endpoint, all on Base mainnet)
ARMS Pool volume first 14h:      ~1.5× TVL
Uniswap whitelist status:        Submitted for review
Cross-chain throughput:          CCTP V2 Base ↔ HyperEVM, 180s settlement,
                                 0 failures since bridge-resilience deployment
InterAgentRepo deployed:         0xaea176DDa786c8B14802f92385749C7Cdf6C7400 (Base mainnet)
Foundry tests:                   10/10 passing (originate, repay, default,
                                 sig verify, replay, expiry, cap, rotation)
Off-chain matching flows:        End-to-end signed quote validated
                                 (POST intent → matcher → EIP-712 sig → on-chain ready)
Methodology pages IPFS-pinned:   TBD (Day 3)
InterAgentRepo loans originated: TBD (Day 3)
```

### On-chain transaction trail (verifiable)

| What | Tx hash |
|------|---------|
| Contract deploy | [`0xf2344c9c...ba2698`](https://basescan.org/tx/0xf2344c9cd8a90c9371d990cc8420bbf839ac14fb9fb099f8c5465f0354ba2698) |
| ETH VRP organic | [`0x1a7fa538...96820f6`](https://basescan.org/tx/0x1a7fa5389aa1dea89af95f553ab8170d6e3f688910c872d81e47dcad896820f6) |
| BTC VRP self-valid | [`0x04a37d60...c8aad`](https://basescan.org/tx/0x04a37d60c37c50830971837b531f7daf6b6ce77adca6f9ccf3d824880cdc8aad) |
| Agent-SOFR self-valid | [`0x9ecaacbe...3449a`](https://basescan.org/tx/0x9ecaacbe0b97e1a05c868027a963100600082c6a90323f274f8e1d8d2623449a) |
| max-LTV self-valid | [`0x5579313c...82a86`](https://basescan.org/tx/0x5579313cf5de4c4047f73e8ddae91ee6eea0b7ddd8da7ec45d8ae4d2d1782a86) |

### Vision

This isn't a hackathon project — it's a 4-day sprint to ship the Q4 deliverable of a multi-quarter roadmap:

- **Q4 2025 (done):** Adaptive portfolio agent on Base mainnet with custom hook
- **Q1 2026 (this hackathon):** Agent-SOFR Oracle + InterAgentRepo marketplace MVP
- **Q2 2026:** Multi-asset (full EURC/USDC/ETH/USDC support), pre-expiry liquidation, partial fills
- **Q3 2026:** ERC-8004 credit history integration, insurance pool, cross-chain settlement
- **Q4 2026:** Open the marketplace to third-party agent participants at scale

Once a critical mass of agents reference Agent-SOFR, it becomes a **Schelling point** — the LIBOR/SOFR of the machine economy. We don't need to convince anyone to use it; coordinative incentives lock it in once two agents already do.

---

## 3-minute video script

**0:00 — 0:15 (15s) HOOK**

> "Hi, I'm Danil from the Netherlands. I built RegimeShift for RFB 04 — but it's already past the 'portfolio manager' stage. We're shipping the **infrastructure layer** that future portfolio managers will consume. Live on Base mainnet, real capital, real organic buyer."

[Show: regimeshift.xyz landing page]

**0:15 — 0:45 (30s) WHAT'S LIVE**

> "The agent classifies volatility regime — LOW, MID, HIGH — and picks one of three buckets: Uniswap v4 LP with my custom hook, Hyperliquid ETH perp, or defensive USDC. Cross-chain via CCTP V2 in 180 seconds. Right now it's in defensive cash because VRP went negative this morning — exactly the risk-off behavior RFB 04 asks for."

[Show: dashboard with state machine + journalctl logs]

**0:45 — 1:20 (35s) DATA PRODUCT**

> "The agent is also a data provider — four paid x402 endpoints on Base mainnet with tiered pricing. VRP signals at $0.005, our Agent-SOFR benchmark rate at $0.10 (Messari Enterprise tier — there's nothing else like it), max-LTV risk signal at $0.005, signed loan quotes at 5 bps of principal. We've already caught our **first organic paid call** from a cross-service AI agent that also pays CoinMarketCap, CoinGecko, and Messari. Settled on-chain."

[Show: BaseScan tx hash, agentic.market listing]

**1:20 — 2:15 (55s) THE PIVOT**

> "But running this agent in production exposed the real problem: DeFi 1.0 doesn't fit agents. Aave's rates are governance-set, manipulable, reflexive. Uniswap whitelists hooks via bureaucratic review. AMMs add slippage where agents could bilateral-quote. We need different primitives."

[Show: diagram of three primitives — data, formulas, registry]

> "So we're shipping the first decentralized benchmark rate — Agent-SOFR — aggregated from six market-derived sources, weighted to be manipulation-resistant. And the bilateral RFQ marketplace — InterAgentRepo on Base — where agents lend and borrow collateralized capital at sub-hour horizons. Off-chain matching at agent speed, on-chain settlement for trust."

[Show: live Agent-SOFR API response with decomposition]

**2:15 — 2:45 (30s) DEMO**

> "Here's a test loan settling on Base right now. Lender intent: $5 USDC for 30 minutes. Borrower intent: $5 USDC against WETH collateral. Matcher pairs them, signs a quote, originates on-chain. Real USDC. Real WETH locked. Real settlement."

[Show: demo loan transaction on BaseScan]

**2:45 — 3:00 (15s) CLOSE**

> "Adaptive portfolio manager that consumes infrastructure it built. Methodology open and IPFS-pinned. Same stack scales to every other RFB 04 submission. **This is what graduating past DeFi 1.0 looks like.**"

[Show: regimeshift.xyz, repos, social links]

---

## Submission checklist

- [ ] Loom video uploaded
- [ ] All repos made public
- [ ] Form fields populated (use template above)
- [ ] Final pitch post in Arc Discord
- [ ] Tweet thread with first organic + first inter-agent loan tx hashes
- [ ] Final smoke test of all endpoints + dashboard
