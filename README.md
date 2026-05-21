# RegimeShift Clearinghouse

**Agent-native short-term capital markets — the inter-agent equivalent of TradFi's interbank lending market.**

The first decentralized benchmark rate for AI agents (Agent-SOFR) + the RFQ marketplace that lets agents lend, borrow, and swap collateralized capital at sub-block to multi-hour horizons.

Built for the [Agora Agents Hackathon](https://thecanteenapp.com/) under [RFB 04 — Adaptive Portfolio Manager](https://agora.canteen.app) — but architected as foundational infrastructure that other adaptive portfolio agents will need to consume.

---

## Status snapshot

| Layer | Status |
|-------|--------|
| **VRP signals** (ETH, BTC) | ✅ Live on Base mainnet, paid x402 endpoints |
| **Adaptive portfolio agent** (RegimeShift) | ✅ Live on Base mainnet, real capital |
| **Cross-chain CCTP V2** (Base ↔ HyperEVM) | ✅ Live, 180s settlement |
| **Custom Uniswap v4 hook** (ARMSHookV3) | ✅ Live, ~1.5× TVL in first 14h |
| **Agent-SOFR Oracle** | 🔄 Building (Day 1) |
| **Inter-Agent Repo escrow contract** | 🔄 Building (Day 2-3) |
| **Off-chain matching engine** | 🔄 Building (Day 2-3) |
| **Live MVP demo loan** | 🔄 Target by Day 3 |

---

## Why this exists

DeFi 1.0 was built for humans:
- **Lending pools** (Aave, Compound) — governance-set rates, week-to-month horizons
- **AMMs** (Uniswap, Balancer) — passive LP positions with whitelist gating
- **Yield aggregators** (Yearn) — strategy approval bottlenecks

Agents need different primitives:
- **Minute-to-hour horizons** (not weeks)
- **Market-derived rates** (not governance votes)
- **Bilateral RFQ matching** (not pooled AMMs)
- **Permissionless settlement** (not whitelist-gated venues)

This repo builds those primitives. See [`docs/01-thesis.md`](docs/01-thesis.md) for the full argument.

---

## Architecture (three layers)

```
┌─────────────────────────────────────────────────────────┐
│  COMPUTE LAYER (off-chain, millisecond)                 │
│  • Agent-SOFR rate aggregation (multi-source weighted)  │
│  • Merton jump-diffusion premium                         │
│  • RFQ matching engine                                   │
│  • VRP / regime classification (existing)                │
└─────────────────────┬───────────────────────────────────┘
                      │
                      │ EIP-712 signed quotes
                      │
┌─────────────────────▼───────────────────────────────────┐
│  REGISTRY LAYER (on-chain, immutable)                   │
│  • ERC-8004 agent identity                              │
│  • InterAgentRepo.sol escrow + settlement                │
│  • x402 paid endpoint settlements                        │
│  • IPFS methodology hashes                               │
│  • Trade audit trail (event logs)                        │
└─────────────────────────────────────────────────────────┘
```

Detailed in [`docs/02-agent-sofr.md`](docs/02-agent-sofr.md) and [`docs/03-clearinghouse.md`](docs/03-clearinghouse.md).

---

## Quick links

| Doc | What's inside |
|-----|---------------|
| [`docs/01-thesis.md`](docs/01-thesis.md) | The full agent-native finance thesis |
| [`docs/02-agent-sofr.md`](docs/02-agent-sofr.md) | Oracle architecture, Merton math, API spec |
| [`docs/03-clearinghouse.md`](docs/03-clearinghouse.md) | Marketplace architecture (atomic + term) |
| [`docs/04-rate-sources.md`](docs/04-rate-sources.md) | Live rate comparison across venues |
| [`docs/05-pitch.md`](docs/05-pitch.md) | Submission pitch for Agora |
| [`ROADMAP.md`](ROADMAP.md) | 4-day shipping plan |

---

## Related repos

- [`tradingdesk26/vrp-agent`](https://github.com/tradingdesk26/vrp-agent) — The autonomous portfolio agent (reference customer)
- [`tradingdesk26/armsys-signals`](https://github.com/tradingdesk26/armsys-signals) — VRP signals API (paid x402 endpoints)
- [`tradingdesk26/regimeshift-fx`](https://github.com/tradingdesk26/regimeshift-fx) — EURC/USDC custom Uniswap v4 hook

---

## License

TBD — open methodology, source code TBD post-hackathon.
