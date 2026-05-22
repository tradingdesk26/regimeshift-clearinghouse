# 4-Day Shipping Plan — Agora Submission Deadline 2026-05-25

**Status: Day 2 complete + v1.0 liquidation + audit R1 (V3) + audit R2 (V4) all shipped — 2026-05-22**

- ✅ **Day 1 complete** — Agent-SOFR Oracle + max-LTV endpoint, both validated on-chain
- ✅ **Day 2 complete** — InterAgentRepo V1 deployed, matching engine live, end-to-end signed-quote flow validated
- ✅ **v1.0 liquidation shipped** — V2 with Chainlink-driven pre-expiry liquidation, 14/14 Foundry tests
- ✅ **Audit round-1 patched (V3)** — all 4 HIGH + 2 LOW findings fixed, 15/15 Foundry tests. See [`audit/round1.md`](audit/round1.md).
- ✅ **Audit round-2 patched (V4)** — R2-#2 (pause-to-default DOS) fixed, R2-#3 (V2 retirement) executed, R2-#1 acknowledged as systemic. V4 at `0x9d3b...b31c`. See [`audit/round2.md`](audit/round2.md).
- ✅ **Audit round-3 cleanup** — R3-#1 (V3 retirement) executed. Findings trajectory: 10 → 3 → 1. Auditor: "exemplary remediation discipline". See [`audit/round3.md`](audit/round3.md).
- ✅ **Match notifications shipped** — `webhook_url` push (Variant A) + `/v1/intent/{id}/match?wait=N` long-poll (Variant B). End-to-end tested on Base mainnet: webhook delivered within ~1s of match.
- ✅ **Landing page** at `regimeshift.xyz` — Bloomberg-style terminal aesthetic with live metric strip (PAID / REVENUE / PROBES / CONVERSION / HOT ENDPOINT + sparklines from client-side history)
- 🔄 **Day 3** — Demo loan on V4 + agent template repo + methodology pages
- 🔄 **Day 4** — Loom video + submission

## Operating principles

1. **Ship working code over polished slides.** Each day must end with something demonstrable on-chain.
2. **Reuse over rebuild.** We have an existing agent, x402 paywall, and rate engine — extend, don't rewrite.
3. **One commit = one capability.** No branch sprawl. Trunk-based with descriptive commits.
4. **Document as we ship.** Every code commit pairs with a docs update so the artifact tells the full story.
5. **Default to on-chain demonstrability.** Even MVP loan = real wallet, real tx hash on BaseScan.

---

## Day 1 — 2026-05-21 ✅ COMPLETE — Agent-SOFR Oracle live

**Delivered: Two new paid x402 endpoints on Base mainnet with full decomposition.**
EUR + ETH variants deferred to v1.1.

### Tasks

- [x] `oracle/calibration.py` — production constants from `arms/research/round25_calibration.csv`
  - [x] σ thresholds (p50/p65/p80/p93/p99) in bp + wad
  - [x] λ = 1.097 (jump weight from FeeFormulaV2)
  - [x] Regime premium table (6 modes — RESTING/LOW/NORMAL/ELEVATED/HIGH/EXTREME)
  - [x] Hysteresis epsilon = 0.10
- [x] `oracle/regime_classifier.py` — port of `FeeFormulaV2.classifyModeHyst`
  - [x] 6-mode classifier with 10% down-hysteresis
  - [x] State persistence — RegimeClassifier class
- [x] `oracle/variance_engine.py` — cv + j² decomposition + live Binance fetcher
  - [x] Continuous variance (cv) excluding p95 jumps
  - [x] Jump variance (j²) for above-threshold bars
  - [x] `fetch_live_eth_returns()` — pulls last N 5-min closes from Binance
- [x] `oracle/rate_aggregator.py` — 8-source weighted median *(reduced to 7 in v1.0.1; see Changelog)*
  - [x] Deribit options PCP (30d), Deribit futures basis (3m), Hyperliquid perp funding,
        Aevo options PCP, Aave V3 Base USDC + WETH borrow, SOFR 30d (Compound TODO)
        — `aave_borrow_weth` removed in v1.0.1 (WETH is ETH lending market, not USDC short rate)
  - [x] Weighted median anchor (market-derived 75%, reference 15%, macro 10%)
  - [x] 60s TTL cache
- [x] `oracle/max_ltv.py` — math max LTV + regime cap, Black-Cox first-passage
- [x] `oracle/agent_sofr.py` — composition entry point
- [x] Wire into `arms-signals/app.py` as new routes:
  - [x] `GET /v1/rate/sofr/usd?horizon=1h` — initially $0.001, **bumped to $0.10 (Messari Enterprise tier) post-launch**
  - [x] `GET /v1/risk/max-ltv?asset=ETH&...` — initially $0.001, **bumped to $0.005 post-launch**
- [x] Bazaar discovery extension for both
- [x] Deploy to VM, restart systemd
- [x] Self-validate with burner wallet
- [ ] EUR + ETH rate variants (deferred to v1.1)

### Outcome

- Agent-SOFR USD validated on-chain — tx `0x9ecaacbe0b97e1a05c868027a963100600082c6a90323f274f8e1d8d2623449a`
  - Live response: rate 4.72%, regime HIGH, base anchor 4.12% + regime premium 60bps
- max-LTV validated on-chain — tx `0x5579313cf5de4c4047f73e8ddae91ee6eea0b7ddd8da7ec45d8ae4d2d1782a86`
  - Live response: max_ltv 0.75 (regime cap binding in HIGH), math_max_ltv 0.96
- `/stats` shows `.200` counter incremented
- 7/8 rate sources live (Compound implementation TODO)

---

## Day 2 — 2026-05-21 ✅ COMPLETE — Clearinghouse contract + matching live

**Delivered: `InterAgentRepo.sol` deployed on Base; intent submission live; quote engine + matcher end-to-end validated.**
First real on-chain loan deferred to Day 3.

### Tasks

- [x] `contracts/InterAgentRepo.sol` — Foundry project (single-tier collateralized term loans)
  - [x] State: `loans` mapping + `consumedNonces` (replay protection)
  - [x] `originate(Quote, sig)` — verify EIP-712 → pull collateral + principal → emit event
  - [x] `repay(loanId)` — pull principal+interest, release collateral
  - [x] `defaultLoan(loanId)` — past expiry → seize collateral to lender
  - [x] OpenZeppelin EIP712 + ECDSA + SafeERC20 + ReentrancyGuard + Ownable
  - [x] PRINCIPAL_CAP = $50 USDC for MVP safety
  - [x] Custom errors (gas-efficient + typed)
  - [x] 10/10 Foundry tests pass (happy, default, replay, expired, cap, sig fail, rotation, etc.)
- [x] Deploy to Base mainnet — [`0xaea176DDa786c8B14802f92385749C7Cdf6C7400`](https://basescan.org/address/0xaea176DDa786c8B14802f92385749C7Cdf6C7400)
  - Deploy tx: [`0xf2344c9cd8a90c9371d990cc8420bbf839ac14fb9fb099f8c5465f0354ba2698`](https://basescan.org/tx/0xf2344c9cd8a90c9371d990cc8420bbf839ac14fb9fb099f8c5465f0354ba2698)
- [x] `matcher/quote_engine.py` — three quote modes
  - [x] `compute_rate(P, C, T)` — fair rate from variance + regime
  - [x] `compute_collateral(P, r, T)` — bisection over LTV
  - [x] `compute_max_duration(P, C, r)` — bisection over duration buckets
  - [x] EIP-712 signing → output ready for `InterAgentRepo.originate()`
  - [x] Signature verified via deployed `recoverSigner()` — matches oracleSigner exactly
- [x] `matcher/intent_book.py` — SQLite-backed order book
  - [x] LenderIntent / BorrowerIntent dataclasses with full field set
  - [x] `add_lender()` / `add_borrower()` with auto intent_id
  - [x] `open_lenders()` / `open_borrowers()` queries
  - [x] `record_match()` + atomic status updates
- [x] `matcher/matcher.py` — priority-queue matcher
  - [x] Asset / amount / duration / rate compatibility checks
  - [x] Applies lender's `max_default_prob` for LTV
  - [x] Generates signed EIP-712 quote on match
- [x] API endpoints in arms-signals:
  - [x] `GET /v1/risk/max-ltv` — paid (initially $0.001, now $0.005)
  - [x] `POST /v1/intent/lend` — free
  - [x] `POST /v1/intent/borrow` — free, auto-fires matcher
  - [x] `GET /v1/intents/open` — free
  - [x] `GET /v1/matches/recent` — free
- [ ] `POST /v1/quote` paid $0.0002 (deferred — covered by intent flow for MVP)

### Outcome

- Contract live on Base mainnet, 10/10 Foundry tests pass
- EIP-712 signature roundtrip: off-chain Python signs → contract `recoverSigner()` returns oracle address ✓
- Live API end-to-end flow validated:
  - Lender intent `lend_63cefd79...` posted ($50 USDC, max 4h, min 480 bps)
  - Borrower intent `bor_d4ac70ab...` posted (need $50 for 1h, max 550 bps, 0.04 WETH max)
  - Matcher fired immediately → `match_d4222968...`
  - Quote: LTV 0.75 (HIGH regime cap binding), rate 480 bps, 0.0321 WETH collateral
  - Signature valid, ready for on-chain `originate()`

---

## Day 3 — 2026-05-22 — Audit remediation, demo loan, landing terminal

**Delivered: Three audit rounds completed (10 → 3 → 1 → 0 findings); V4 deployed and active; V2 + V3 retired. First live demo loan executed end-to-end on Base mainnet. Bloomberg-style landing live at regimeshift.xyz.**

### Tasks

- [x] **Audit rounds 1-3 remediation** — V4 deployed at `0x9d3b61d13a839968ffad94a0eedf73153c2fb31c`, V2 + V3 retired (oracleSigner rotated to `0x...dEaD`)
  - [x] R1: initial LTV cap (93%), min duration (120s), rate cap, Aave-style default split
  - [x] R2: `whenNotPaused` removed from `repay()` so owner can't grief borrower
  - [x] R3: V3 retirement cleanup pass
- [x] **Match notifications** — both variants shipped (webhook push + long-poll `GET /v1/intent/{id}/match?wait=N`)
- [x] **Bloomberg-style landing** at `regimeshift.xyz` — ticker, paid-call metrics, sparklines, TX rate, HOT ENDPOINT, match-notifications section. VRP trading dashboard moved to `/v1`.
- [x] **First live demo loan** executed on V4 — `$0.50` USDC / `0.0005` WETH / 300s / 480 bps / RESTING:
  - originate(): `0xdf8967ce5ce8dd61d60b4736cfdc9c6d7de86450d0a3c59c02b80070f68e639b`
  - repay():    `0xb1b14009eff0bfbcbc919176078151932df7b7edfa06b0fd780e1f089fc5ed59`
  - match_id: `match_b74ab408985c6581`, loan_id: `0xd3ad2b133f18198a091222373d57c10e119c32cb98553749dcdf27ec81552e95`
- [ ] Dashboard panel "Live Intents" on `regimeshift.xyz` (deferred — landing terminal is sufficient for submission)
  - [ ] Show open lender intents (asset, amount, rate)
  - [ ] Show open borrower intents
  - [ ] Show recent matches with tx hash links to BaseScan
- [x] **Agent template repo** [`tradingdesk26/regimeshift-agent-starter`](https://github.com/tradingdesk26/regimeshift-agent-starter) — public, MIT, ~600 LOC across 4 roles (lender/borrower/liquidator/data_only). `python -m starter_agent` end-to-end smoke-tested against prod API. Strategy hooks (`decide_*` functions) for fork-and-customize workflow.
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
  - [ ] Project name: **RegimeShift Clearinghouse**
  - [ ] Tagline: **"AI central bank for the agent economy"**
  - [ ] RFB: 04 — pivoted from "Adaptive Portfolio Manager" to clearinghouse / Agent-SOFR
  - [ ] Demo URL: regimeshift.xyz
  - [ ] Video URL: Loom link
  - [ ] GitHub: this repo + related (made public on submission day)
  - [ ] Traction metrics (see template below)
- [ ] Make repos public (last action before submission)
- [ ] Post pitch in Arc Discord chat (final version)

### Traction metrics template

```
Live on Base mainnet since: 2026-04-XX (ARMSHookV3) / 2026-05-21 (clearinghouse)
Paid x402 endpoints: 4 (ETH VRP $0.005, BTC VRP $0.005, USD SOFR $0.10, max-LTV $0.005)
On-chain organic paid calls received: 370+ on ETH VRP (auto-discovered via Bazaar)
Active settlement contract: InterAgentRepoV4 (post 3-round audit, 0 findings)
Demo loans executed end-to-end on V4: 1 (full originate → repay cycle, basescan tx hashes)
Methodology pages IPFS-pinned: 2 (vrp-v1, agent-sofr-v1)  [agent-sofr-v1 pin pending]
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
