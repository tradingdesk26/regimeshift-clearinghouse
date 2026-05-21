# 4-Day Shipping Plan — Agora Submission Deadline 2026-05-25

**Status: Day 1 of 4 — 2026-05-21**

## Operating principles

1. **Ship working code over polished slides.** Each day must end with something demonstrable on-chain.
2. **Reuse over rebuild.** We have an existing agent, x402 paywall, and rate engine — extend, don't rewrite.
3. **One commit = one capability.** No branch sprawl. Trunk-based with descriptive commits.
4. **Document as we ship.** Every code commit pairs with a docs update so the artifact tells the full story.
5. **Default to on-chain demonstrability.** Even MVP loan = real wallet, real tx hash on BaseScan.

---

## Day 1 — 2026-05-21 (Today) — Agent-SOFR Oracle live

**Deliverable: Three new paid x402 endpoints on `regimeshift.xyz/api/v1/rate/sofr/{usd,eur,eth}` returning Agent-SOFR with full decomposition.**

### Tasks

- [ ] `oracle/calibration.py` — copy calibrated constants from `arms/research/round25_calibration.csv`
  - [ ] σ thresholds (p50/p65/p80/p93/p99) in bp + wad
  - [ ] λ = 1.097 (jump weight from FeeFormulaV2)
  - [ ] Regime premium table (6 modes)
  - [ ] Hysteresis epsilon = 0.10
- [ ] `oracle/regime_classifier.py` — port `FeeFormulaV2.classifyModeHyst` to Python
  - [ ] 6-mode classifier with 10% down-hysteresis
  - [ ] State persistence (last_mode) for hysteresis to work across calls
- [ ] `oracle/variance_engine.py` — compute cv + j² from live price data
  - [ ] Continuous variance (cv) — rolling realized variance excluding jumps
  - [ ] Jump variance (j²) — bars where |r| > p95, squared
  - [ ] Use `arms/research/ethusdt_5m.parquet` as reference dataset for ETH
- [ ] `oracle/rate_aggregator.py` — multi-source rate aggregator
  - [ ] Fetch live rates: Deribit options PCP, Deribit futures basis, Hyperliquid perp funding, Aevo PCP, Aave Base USDC/WETH, Compound, SOFR reference
  - [ ] Weighted median anchor (market-derived 70%, governance reference 20%, macro 10%)
  - [ ] Cache layer (60s TTL — same as VRP endpoint)
- [ ] `oracle/agent_sofr.py` — main entry point combining the above
  - [ ] Compose: base_anchor + variance_premium + regime_adjustment
- [ ] Wire into `arms-signals/app.py` as new routes:
  - [ ] `GET /v1/rate/sofr/usd?horizon=1h` — $0.001
  - [ ] `GET /v1/rate/sofr/eur?horizon=1h` — $0.001
  - [ ] `GET /v1/rate/sofr/eth?horizon=1h` — $0.001
- [ ] Bazaar discovery extension for each
- [ ] Deploy to VM, restart systemd
- [ ] Self-validate with burner wallet (one paid call per endpoint)
- [ ] Update README + dashboard panel

### Success criteria

- [ ] Three new on-chain tx hashes for `/sofr/{usd,eur,eth}` endpoints
- [ ] `/stats` shows `.200` counter for each
- [ ] Response contains: rate, full decomposition, sources, methodology hash, expiry

### Risks & mitigations

- **Deribit/Aevo API rate-limit during dev** → cache aggressively, use single shared client
- **Jump-diffusion calibration takes too long** → start with hardcoded reasonable defaults (λ=40, α=-0.01, δ=0.04 for ETH), refine later
- **CDP facilitator rejects new endpoint** → already tested pattern for VRP — should JustWork™

---

## Day 2 — 2026-05-22 — Clearinghouse contract + matching API

**Deliverable: `InterAgentRepo.sol` deployed on Base; intent submission API live; first test loan settles between two test wallets.**

### Tasks

- [ ] `contracts/InterAgentRepo.sol` — Foundry project
  - [ ] State: `loans` mapping (loan_id → terms)
  - [ ] `originate(borrower, lender, principal, collateral, expiry, rate, oracle_sig)` — pull funds, transfer principal, emit event
  - [ ] `repay(loan_id)` — pull principal+interest, release collateral
  - [ ] `default(loan_id)` — past expiry → release collateral to lender
  - [ ] Verify Agent-SOFR oracle signature (EIP-712) on origination
  - [ ] Foundry tests for all paths (happy, default, partial)
- [ ] Deploy to Base mainnet (deterministic CREATE2 address)
- [ ] `matcher/intent_book.py` — in-memory order book
  - [ ] Lender intent: `{address, asset, amount, max_duration, min_rate, expires_at}`
  - [ ] Borrower intent: `{address, principal_asset, principal_amount, collateral_asset, collateral_amount, duration, max_rate, expires_at}`
  - [ ] Persisted to SQLite
- [ ] `matcher/matcher.py` — priority queue matcher
  - [ ] Find compatible lender/borrower pairs
  - [ ] Generate signed EIP-712 quote (server signs as Agent-SOFR oracle)
  - [ ] Return ready-to-submit `originate()` call data
- [ ] API endpoints:
  - [ ] `POST /v1/intent/lend` — submit lender intent (free, just adds to book)
  - [ ] `POST /v1/intent/borrow` — submit borrower intent
  - [ ] `GET /v1/intents/open` — see active intents
  - [ ] `GET /v1/matches/recent` — see executed matches

### Success criteria

- [ ] Contract verified on BaseScan
- [ ] One test loan originated, settled, and repaid on-chain
- [ ] All Foundry tests pass

### Risks & mitigations

- **Contract bugs** → audit-grade foundry fuzz tests, cap MVP at $10 max loan size
- **EIP-712 signature verification gnarly** → use OpenZeppelin's `ECDSA.recover` boilerplate
- **Matching engine over-engineered** → simplest possible: linear scan, single-fill, no partial

---

## Day 3 — 2026-05-23 — Dashboard, real demo loan, methodology page

**Deliverable: Dashboard shows live intents + matches. Real $5-10 loan executes between agent wallet and burner wallet. Methodology pages live and IPFS-pinned.**

### Tasks

- [ ] Dashboard panel "Live Intents" on `regimeshift.xyz`
  - [ ] Show open lender intents (asset, amount, rate)
  - [ ] Show open borrower intents
  - [ ] Show recent matches with tx hash links to BaseScan
  - [ ] Auto-refresh every 10s
- [ ] Demo loan choreography:
  - [ ] Burner wallet (existing 0x3d6...) submits lender intent (lend $5 USDC, max duration 1h)
  - [ ] Second burner wallet (fund $1 WETH as collateral) submits borrower intent (borrow $5 USDC against WETH for 30min)
  - [ ] Matcher pairs them, generates signed quote
  - [ ] Originate transaction submitted on-chain
  - [ ] After 30min: borrower repays (or default path triggers)
- [ ] Methodology pages:
  - [ ] `regimeshift.xyz/methodology/agent-sofr-v1` — full Agent-SOFR formula
  - [ ] `regimeshift.xyz/methodology/repo-pricing-v1` — how rate maps to loan
  - [ ] Pin to IPFS, reference hashes in API responses
- [ ] Update agentic.market listings:
  - [ ] List `/v1/rate/sofr/usd` (and EUR, ETH)
  - [ ] Refresh existing VRP listings
- [ ] README polish + architecture diagram

### Success criteria

- [ ] One real on-chain loan executed and settled
- [ ] Dashboard shows live state
- [ ] Methodology page is permanent (IPFS-pinned)
- [ ] At least 3 new Agent-SOFR queries from external IPs (i.e., agentic.market crawlers)

---

## Day 4 — 2026-05-24 — Submission deliverables

**Deliverable: Loom video uploaded, Agora form submitted with all required artifacts.**

### Tasks

- [ ] Loom video (3 min, see [docs/05-pitch.md](docs/05-pitch.md) for script)
  - [ ] Pre-record dry-run to check timing
  - [ ] Final cut with subtitles (Loom AI auto-generate)
- [ ] Submission form fields:
  - [ ] Project name: RegimeShift
  - [ ] RFB: 04 — Adaptive Portfolio Manager
  - [ ] Demo URL: regimeshift.xyz
  - [ ] Video URL: Loom link
  - [ ] GitHub: this repo + related (made public on submission day)
  - [ ] Traction metrics (see template below)
- [ ] Make repos public (last action before submission)
- [ ] Post pitch in Arc Discord chat (final version)

### Traction metrics template

```
Live on Base mainnet since: 2026-04-XX
AUM under agent management: $XXX
Paid x402 endpoints: 5 (ETH VRP, BTC VRP, USD SOFR, EUR SOFR, ETH SOFR)
On-chain organic paid calls received: X
Test loans executed via InterAgentRepo: X
Total tx volume on Base: $XXX
Methodology pages IPFS-pinned: 2 (vrp-v1, agent-sofr-v1)
```

### Risks & mitigations

- **Loom upload fails / quota** → fallback to YouTube unlisted
- **Submission form has unexpected fields** → review form template Day 3, don't surprise on Day 4
- **Repo publicization exposes secrets** → final sweep for `.env*`, private keys, API keys

---

## Stretch goals (if main path completes early)

- [ ] **Layer 1 atomic flash-loan tier** — alternative settlement path for sub-block loans (no collateral needed)
- [ ] **ERC-8004 credit history integration** — per-counterparty rate spread
- [ ] **Cross-chain settlement** — borrow on Base, deploy to Hyperliquid via CCTP
- [ ] **Public demo on agentic.market** — make `/v1/intent/*` endpoints discoverable
- [ ] **Tweet thread with first inter-agent loan** — distribution

---

## Risk register

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|-----------|
| Contract bug at deploy → loss of test funds | Med | High | Foundry fuzz, $10 caps, deploy to testnet first |
| Oracle signature implementation buggy | Med | High | OpenZeppelin EIP-712 boilerplate, contract test |
| Matching engine deadlock under load | Low | Low | Single-threaded, FIFO, no concurrent ops |
| Deribit API rate-limit on data ingest | Low | Med | 60s cache + shared HTTP client |
| Agentic.market crawler not picking up Agent-SOFR listings | Med | Low | Pattern matches existing VRP listings — should JustWork |
| Submission form changes from current expectations | Low | Med | Review final form Day 3 |
| Cannot reach 4-day shipping pace | Med | High | Have fallback: Oracle-only submission (no marketplace) — still strong |

---

## Daily standup template

End of each day, post in this repo as `daily-log-{date}.md`:

```markdown
## Day X — YYYY-MM-DD

**Shipped:**
- [thing 1]
- [thing 2]

**Blocked on:**
- [blocker, if any]

**Tomorrow's first action:**
- [single specific next thing]

**Confidence level (1-10):**
- [number] — [one-line reason]
```
