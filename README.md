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
| **Agent-SOFR Oracle** (`/v1/rate/sofr/usd`) | ✅ Live, paid + on-chain validated |
| **Max-LTV risk endpoint** (`/v1/risk/max-ltv`) | ✅ Live, paid + on-chain validated |
| **InterAgentRepo V1** escrow (MVP demo) | ✅ Deployed [`0xaea1...7400`](https://basescan.org/address/0xaea176DDa786c8B14802f92385749C7Cdf6C7400) |
| **InterAgentRepo V2** escrow (Chainlink liquidation) | 🪦 Deployed [`0x2bfE...11E4`](https://basescan.org/address/0x2bfE0f1142B04049d867389Bf91A84e498ED11E4) — **RETIRED** per R2-#3 (oracleSigner=0x...dEaD) |
| **InterAgentRepo V3** escrow (audit R1 patched) | 🪦 Deployed [`0xFfca...2945`](https://basescan.org/address/0xFfca5d80c3413Bd5D17971550cCD615f57f22945) — **RETIRED** per R3-#1 (oracleSigner=0x...dEaD) |
| **InterAgentRepo V4** escrow (audit R1+R2 patched, ACTIVE) | ✅ Deployed [`0x9d3b...b31c`](https://basescan.org/address/0x9d3b61d13a839968ffad94a0eedf73153c2fb31c) — all HIGH + LOW + R2-#2 fixed, Foundry 8/8 + V3's 15/15 tests pass. See audit reports: [`round1`](audit/round1.md), [`round2`](audit/round2.md), [`round3`](audit/round3.md). |
| **Audit round-1 fixes** (V3 onwards) | ✅ All HIGH addressed: initial LTV check, min duration, rate ceiling, Aave-style default split |
| **Audit round-2 fixes** (V4) | ✅ R2-#2: `whenNotPaused` removed from `repay()` (pause blocks entry, not exit). R2-#3: V2 retired. R2-#1: deferred as systemic DeFi risk (aligned with Aave/Compound/Morpho). |
| **Audit round-3 cleanup** | ✅ R3-#1: V3 retired (mirror of R2-#3 doctrine applied to V3 bytecode). All deprecated versions now on-chain-verifiable as dead. |
| **Chainlink ETH/USD oracle integration** | ✅ Live in V2+V3+V4 with `answeredInRound` defense |
| **Pausable mixin (emergency halt)** | ✅ Live in V3+V4 — `emergencyPause()` / `emergencyUnpause()` |
| **Liquidator bounty + insurance pool** | ✅ Live in V2+V3+V4 — 3% bounty, 1% insurance |
| **Off-chain matching engine** | ✅ Live, end-to-end validated |
| **Intent submission APIs** (`/v1/intent/*`) | ✅ Live, free (settlement on-chain) |
| **Match notifications (push)** | ✅ `webhook_url` field on intent submit — server POSTs full signed quote to your URL within ~1s of match |
| **Match notifications (long-poll)** | ✅ `GET /v1/intent/{id}/match?wait=N` (max 300s) — for agents without public endpoints |
| **Liquidation monitoring** (`/v1/liquidatable-loans`, `/v1/active-loans`) | ✅ Live |
| **EIP-712 quote signing** | ✅ Verified via deployed `recoverSigner()` (both V1 + V2 domains) |
| **Live MVP demo loan on V4** | ✅ Executed 2026-05-22: $0.50 USDC / 0.0005 WETH / 300s / 480 bps / RESTING. [originate](https://basescan.org/tx/0xdf8967ce5ce8dd61d60b4736cfdc9c6d7de86450d0a3c59c02b80070f68e639b) → [repay](https://basescan.org/tx/0xb1b14009eff0bfbcbc919176078151932df7b7edfa06b0fd780e1f089fc5ed59) |
| **Agent starter kit** ([`regimeshift-agent-starter`](https://github.com/tradingdesk26/regimeshift-agent-starter)) | ✅ Public 2026-05-22 — MIT, Python 3.10+, ~600 LOC across 4 roles (lender/borrower/liquidator/data_only). `python -m starter_agent` smoke-tested against prod API. |
| **Dashboard "Live Intents" panel** | 🔄 Target by Day 3 |
| **Methodology pages + IPFS pinning** | 🔄 Target by Day 3 |
| **Loom video + Agora submission** | 🔄 Target by Day 4 (deadline 2026-05-25) |

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
│  • Agent-SOFR multi-source rate aggregation             │
│  • Variance decomposition: cv + λ·j² (λ=1.097)          │
│  • 6-mode regime classifier (production-calibrated)     │
│  • Quote engine — 3 modes (rate / collateral / duration)│
│  • RFQ matching engine + intent book (SQLite)           │
│  • EIP-712 quote signing                                │
└─────────────────────┬───────────────────────────────────┘
                      │
                      │ EIP-712 signed quotes
                      │
┌─────────────────────▼───────────────────────────────────┐
│  REGISTRY LAYER (on-chain, immutable, Base mainnet)     │
│  • InterAgentRepo.sol escrow at 0xaea1...7400           │
│    - originate(Quote, sig) → pull collateral, transfer │
│      principal, atomic                                  │
│    - repay(loanId) → return principal+interest          │
│    - defaultLoan(loanId) → seize collateral             │
│  • x402 USDC settlements: CDP primary + self-host fall- │
│    back (transparent failover, no client-visible breaks)│
│  • EIP-712 signature verification via ECDSA             │
│  • Trade audit trail (event logs)                       │
│  • IPFS methodology hashes (planned)                    │
└─────────────────────────────────────────────────────────┘
```

Detailed in [`docs/02-agent-sofr.md`](docs/02-agent-sofr.md) and [`docs/03-clearinghouse.md`](docs/03-clearinghouse.md).

## On-chain artifacts (Base mainnet, chain_id 8453)

| Artifact | Address / Tx |
|----------|-------------|
| **InterAgentRepo V1** (MVP demo) | [`0xaea176DDa786c8B14802f92385749C7Cdf6C7400`](https://basescan.org/address/0xaea176DDa786c8B14802f92385749C7Cdf6C7400) |
| **InterAgentRepo V2** (Chainlink liquidation, superseded) | [`0x2bfE0f1142B04049d867389Bf91A84e498ED11E4`](https://basescan.org/address/0x2bfE0f1142B04049d867389Bf91A84e498ED11E4) |
| **InterAgentRepo V3** (audit R1 patched, superseded) | [`0xFfca5d80c3413Bd5D17971550cCD615f57f22945`](https://basescan.org/address/0xFfca5d80c3413Bd5D17971550cCD615f57f22945) |
| **InterAgentRepo V4** (audit R1+R2 patched — ACTIVE) | [`0x9d3b61d13a839968ffad94a0eedf73153c2fb31c`](https://basescan.org/address/0x9d3b61d13a839968ffad94a0eedf73153c2fb31c) |
| V1 contract deploy | [`0xf2344c9c...ba2698`](https://basescan.org/tx/0xf2344c9cd8a90c9371d990cc8420bbf839ac14fb9fb099f8c5465f0354ba2698) |
| V2 contract deploy | [`0xad3fdca2...3e9bab0a`](https://basescan.org/tx/0xad3fdca2013de1a995dd3bc5778d539d6e443feec07aaff149eb291b3e9bab0a) |
| V2 retirement (oracle → 0x...dEaD) | [`0x889a4608...09b37ba`](https://basescan.org/tx/0x889a460824d949a119d37c53e14163db12998f640dd75b4a51e3c9e5809b37ba) |
| V3 contract deploy | [`0x2ac8943a...da186a7`](https://basescan.org/tx/0x2ac8943ad54821ecdfe647da185cfe7e65c6812b512c54ddedbd7267ada186a7) |
| V3 retirement (oracle → 0x...dEaD) | [`0xc1ef9456...5e67292d`](https://basescan.org/tx/0xc1ef9456a6adec7eec739d2bdbc73b9f81a48e35e37fb3b1cfb0eba05e67292d) |
| V4 contract deploy | [`0xf7376511...5b3af09`](https://basescan.org/tx/0xf7376511cbbba7a2da057bd046c1153e6566ef7d3d6462decdb8183b15b3af09) |
| Chainlink ETH/USD feed (Base) | [`0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70`](https://basescan.org/address/0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70) |
| ETH VRP — first organic paid call | [`0x1a7fa538...96820f6`](https://basescan.org/tx/0x1a7fa5389aa1dea89af95f553ab8170d6e3f688910c872d81e47dcad896820f6) |
| BTC VRP — self-validated paid call | [`0x04a37d60...c8aad`](https://basescan.org/tx/0x04a37d60c37c50830971837b531f7daf6b6ce77adca6f9ccf3d824880cdc8aad) |
| Agent-SOFR — self-validated paid call | [`0x9ecaacbe...3449a`](https://basescan.org/tx/0x9ecaacbe0b97e1a05c868027a963100600082c6a90323f274f8e1d8d2623449a) |
| max-LTV — self-validated paid call | [`0x5579313c...82a86`](https://basescan.org/tx/0x5579313cf5de4c4047f73e8ddae91ee6eea0b7ddd8da7ec45d8ae4d2d1782a86) |
| Oracle signer + owner (rotated 2026-05-23) | `0x8456bE7B0a576CE36F41Ae43231b08f04f744C8b` |
| Insurance pool (MVP — will rotate to multisig; currently empty) | `0x3d6EF3B451Abaf79eb0a5c08089518fB3f4de8b5` |
| x402 settlement | Primary: **Coinbase CDP** facilitator (gas paid by CDP relayer). Fallback: self-hosted on the same VM, relayer wallet `0x3d6EF3B451Abaf79eb0a5c08089518fB3f4de8b5` |
| Seller pay-to wallet (paid x402 USDC lands here) | `0x82B17D0bb4De9ae6c3491257B60E8245e70acd7B` |

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
- [`tradingdesk26/armsys-signals`](https://github.com/tradingdesk26/armsys-signals) — VRP signals API (paid x402 endpoints + two-tier facilitator)
- [`tradingdesk26/regimeshift-demo-activity`](https://github.com/tradingdesk26/regimeshift-demo-activity) — Autonomous bot that keeps the Loan Registry alive + pays for Agent-SOFR via x402 (three-wallet role architecture)
- [`tradingdesk26/regimeshift-agent-starter`](https://github.com/tradingdesk26/regimeshift-agent-starter) — Minimal starter kit for new agents
- [`tradingdesk26/regimeshift-fx`](https://github.com/tradingdesk26/regimeshift-fx) — EURC/USDC custom Uniswap v4 hook

---

## License

TBD — open methodology, source code TBD post-hackathon.
