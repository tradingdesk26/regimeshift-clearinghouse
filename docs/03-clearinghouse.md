# Inter-Agent Clearinghouse — The Marketplace

## What it is

A bilateral RFQ marketplace where agents lend, borrow, and swap collateralized capital at minute-to-hour horizons. **The interbank market for AI agents**, with Agent-SOFR as the benchmark rate.

**Single pricing principle:** collateralized term loans. No atomic flash tier — that's already commoditized (Aave / Balancer). Our unique value is duration-aware, regime-aware pricing that doesn't exist anywhere on-chain today.

---

## Core principle

**Off-chain matching, on-chain settlement.** Same as TradFi exchanges — the matching engine runs at agent speed (millisecond), and the blockchain records the settled trade.

```
Agent A (lender) intent ──┐
                          ├─► Off-chain matching engine ─► EIP-712 signed quote
Agent B (borrower) intent ┘                                       │
                                                                  ▼
                                                          On-chain settlement
                                                          (InterAgentRepo.sol)
```

---

## Trinity: Collateral ↔ Duration ↔ Rate

Every loan has three pricing dimensions. **Any two determine the third** via the calibrator:

```
         duration (T)
              ▲
              │     ╱
              │   ╱  surface defined by calibrator:
              │ ╱    total_variance(T) × LTV → P_default → required_premium
              │╱
              └──────────► LTV (collateral inverse)
             ╱
           ╱
       rate (r)
```

### Three quote modes

| Mode | Borrower fixes | We compute |
|------|---------------|------------|
| `compute_rate` | collateral + duration | fair rate |
| `compute_collateral` | rate + duration | required collateral (LTV) |
| `compute_max_duration` | rate + collateral | maximum safe duration |

This is exposed via `POST /v1/quote`:

```json
{
  "principal_asset": "USDC",
  "principal_amount": 50,
  "collateral_asset": "WETH",
  "mode": "compute_rate",
  "collateral_amount": 0.025,
  "duration_sec": 3600
}

// Response (after $0.0002 x402 settlement):
{
  "rate_bps": 425,
  "ltv": 0.962,
  "regime": "NORMAL",
  "variance_premium_bps": 0.04,
  "regime_premium_bps": 15,
  "max_safe_ltv_at_this_duration": 0.92,
  "expiry_timestamp": 1779385000,
  "oracle_signature": "0x...",
  "methodology_hash": "0x..."
}
```

`compute_collateral` mode does numerical inversion (Newton's method) to solve for LTV given target rate. `compute_max_duration` solves the inverse: max T such that required premium ≤ target rate.

---

## Dynamic LTV — capital efficiency vs Aave

Aave V3 statically sets WETH collateral LTV to **80%**, calibrated for the worst-case regime. Our calibrator dynamically sizes LTV to actual variance:

| Regime | Time-share | σ_5min | Our max LTV | Aave (static) | Capital efficiency gain |
|--------|-----------|--------|-------------|---------------|-------------------------|
| RESTING | 46% | <14 bp | **92%** | 80% | **+12%** |
| LOW | 16% | 17 bp | **90%** | 80% | **+10%** |
| NORMAL | 16% | 20 bp | **85%** | 80% | **+5%** |
| ELEVATED | 14% | 28 bp | **80%** | 80% | **0%** (matched Aave cap) |
| HIGH | 7% | 45 bp | **70%** | 80% | **−10%** (safer for lenders) |
| EXTREME | 1% | 80+ bp | **55%** or pause | 80% | **−25%** (safer for lenders) |

**Weighted average: ~8% capital efficiency gain in calm markets + materially better lender protection in shocks.** Caps lowered from initial v1 values after audit round 1 (3% buffer below contract liquidation threshold).

### Numerical example

For a $1,000 USDC loan over 1 hour:

| Regime | Aave required collateral | Our required collateral | Borrower frees up |
|--------|--------------------------|-------------------------|-------------------|
| RESTING | $1,250 (LTV 80%) | $1,087 (LTV 92%) | **$163 in liquid capital** |
| NORMAL | $1,250 | $1,177 (LTV 85%) | **$73** |
| HIGH | $1,250 | $1,429 (LTV 70%) | (lender protected from default cascade) |
| EXTREME | $1,250 | $1,818 or paused | (matching halted to prevent bad debt) |

In RESTING + LOW + NORMAL (78% of time) borrowers save 6-13% of collateral that's locked up under Aave's static model. **This freed capital becomes liquidity in our pool**, compounding the efficiency.

### Why Aave can't do this

| Aspect | Aave constraint | We sidestep because |
|--------|-----------------|---------------------|
| LTV requires governance vote | Multi-week timelock | Calibrator updates per-block |
| No on-chain regime classifier | Gas-expensive | Compute off-chain, sig on-chain |
| Massive TVL = cascade risk on liquidations | Conservative LTV to prevent runs | Bilateral atomic — no cascades |
| One LTV for all lenders | Can't satisfy varied risk preferences | Lenders specify `max_default_prob` per intent |

**Each is a structural disadvantage Aave can't fix without rebuilding.** Our agent-native architecture sidesteps all four.

---

## Settlement contract: `InterAgentRepo.sol`

```solidity
struct Loan {
    address borrower;
    address lender;
    address principal_token;     // What's being lent (e.g., USDC)
    uint256 principal_amount;
    address collateral_token;    // What's collateralizing (e.g., WETH)
    uint256 collateral_amount;
    uint256 origination_timestamp;
    uint256 expiry_timestamp;
    uint256 rate_bps;             // Rate at origination (basis points)
    bool repaid;
    bool defaulted;
}

mapping(bytes32 => Loan) public loans;
address public agentSofrOracle;   // Oracle keypair address for sig verification
```

### Three core functions

#### 1. `originate(...)` — Open a loan

```solidity
function originate(
    address borrower,
    address lender,
    address principal_token,
    uint256 principal_amount,
    address collateral_token,
    uint256 collateral_amount,
    uint256 expiry_timestamp,
    uint256 rate_bps,
    bytes calldata oracle_signature  // EIP-712 sig from Agent-SOFR
) external returns (bytes32 loan_id) {
    // Verify the quote signature
    bytes32 quote_hash = keccak256(abi.encode(
        principal_token, principal_amount,
        collateral_token, collateral_amount,
        expiry_timestamp, rate_bps
    ));
    require(_verifyOracleSig(quote_hash, oracle_signature), "bad sig");
    require(block.timestamp < expiry_timestamp, "expired quote");
    
    // Pull collateral from borrower
    IERC20(collateral_token).transferFrom(borrower, address(this), collateral_amount);
    
    // Pull principal from lender, send to borrower
    IERC20(principal_token).transferFrom(lender, borrower, principal_amount);
    
    // Record loan
    loan_id = quote_hash;
    loans[loan_id] = Loan({
        borrower: borrower, lender: lender,
        principal_token: principal_token, principal_amount: principal_amount,
        collateral_token: collateral_token, collateral_amount: collateral_amount,
        origination_timestamp: block.timestamp,
        expiry_timestamp: expiry_timestamp,
        rate_bps: rate_bps,
        repaid: false, defaulted: false
    });
    
    emit LoanOriginated(loan_id, borrower, lender, principal_amount, rate_bps);
}
```

#### 2. `repay(loan_id)` — Borrower returns principal + interest

```solidity
function repay(bytes32 loan_id) external {
    Loan storage loan = loans[loan_id];
    require(!loan.repaid && !loan.defaulted, "loan closed");
    require(block.timestamp <= loan.expiry_timestamp, "expired");
    
    uint256 time_elapsed = block.timestamp - loan.origination_timestamp;
    uint256 interest = loan.principal_amount * loan.rate_bps * time_elapsed / (365 days * 10000);
    uint256 total_repay = loan.principal_amount + interest;
    
    IERC20(loan.principal_token).transferFrom(loan.borrower, loan.lender, total_repay);
    IERC20(loan.collateral_token).transfer(loan.borrower, loan.collateral_amount);
    
    loan.repaid = true;
    emit LoanRepaid(loan_id, total_repay);
}
```

#### 3. `defaultLoan(loan_id)` — Past expiry, lender claims collateral

```solidity
function defaultLoan(bytes32 loan_id) external {
    Loan storage loan = loans[loan_id];
    require(!loan.repaid && !loan.defaulted, "loan closed");
    require(block.timestamp > loan.expiry_timestamp, "not expired yet");
    
    IERC20(loan.collateral_token).transfer(loan.lender, loan.collateral_amount);
    
    loan.defaulted = true;
    emit LoanDefaulted(loan_id);
}
```

---

## Risk management

**LTV enforcement is off-chain.** The matching engine computes max safe LTV per regime + duration + lender risk tolerance, and only generates quotes within that envelope. The on-chain contract trusts the signed quote.

### Max safe LTV calculation

```python
def max_safe_ltv(
    asset: str,
    duration_sec: int,
    regime: str,
    lender_max_default_prob: float = 0.001,  # 0.1% default tolerance
) -> float:
    bars = duration_sec / 300  # 5-min bars
    cv, j2 = current_variance(asset)
    sigma_T = sqrt((cv + 1.097 * j2) * bars)
    
    # Mathematical max from variance:
    # P_default = Φ(-ln(1/LTV) / σ_T) ≤ lender_max_default_prob
    z = abs(norm_ppf(lender_max_default_prob))
    math_max_ltv = exp(-z * sigma_T)
    
    # Hard regime cap (additional safety against jump risk):
    return min(math_max_ltv, REGIME_MAX_LTV[regime])


REGIME_MAX_LTV = {
    # Audit round-1 enforced 3% buffer below contract liquidation threshold
    # (95% contract threshold − 2% origination buffer = 93% absolute cap;
    # we set caps a further 1-2% below to give matching engine wiggle room).
    "RESTING":  0.92,   # was 0.98 — still way more efficient than Aave 80%
    "LOW":      0.90,   # was 0.96
    "NORMAL":   0.85,   # was 0.92
    "ELEVATED": 0.80,   # was 0.85 — matches Aave static cap
    "HIGH":     0.70,   # was 0.75 — 10% safer than Aave in stress
    "EXTREME":  0.55,   # was 0.60 — matching paused entirely in EXTREME anyway
}
```

### Other risk controls

- **Expiry buffer:** Off-chain matching adds 5-min buffer between quote expiry and loan expiry to allow for oracle update delays
- **Lender risk tolerance:** Each lender intent includes `max_default_prob` (default 0.1%). Conservative lenders get tighter LTV; aggressive lenders accept looser LTV at higher rate
- **MVP simplifications (Day 2-3):**
  - No partial fills (full intent or nothing)
  - Fixed duration buckets (1h, 4h, 24h)
  - Single asset pair: USDC borrow against WETH collateral
  - Max loan size $50 (capped via `require(principal_amount < 50e6)`)
  - No pre-expiry liquidation (collateral claimable only on default)

### Liquidation mechanism (V4 — active)

The current production contract is **V4** ([`0x9d3b61d13a839968ffad94a0eedf73153c2fb31c`](https://basescan.org/address/0x9d3b61d13a839968ffad94a0eedf73153c2fb31c)) after three audit rounds. V1 stays live as the MVP-no-liquidation reference; V2 and V3 are retired (oracleSigner rotated to `0x...dEaD`).

| Contract | Status | Address |
|----------|--------|---------|
| **V4** | **ACTIVE** (production, post 3-round audit) | `0x9d3b...b31c` |
| V3 | Retired after R3 cleanup | `0xFfca...2945` |
| V2 | Retired after R2 (`whenNotPaused` on repay = griefing vector) | `0x2bfE...11E4` |
| V1 | Demo reference (no liquidation) | `0xaea1...7400` |

| Mechanism | V1 (demo) | V4 (active) |
|-----------|-----------|-------------|
| Expiry default | ✅ `defaultLoan()` | ✅ kept |
| Pre-expiry liquidation | ❌ None | ✅ `liquidate()` with Chainlink ETH/USD |
| LTV threshold | N/A | 95% — current_ltv_bps ≥ 9500 triggers liquidation |
| Initial LTV cap (on-chain) | N/A | **93%** — origination reverts above this (R1-#1) |
| Min loan duration | N/A | **120s** — origination reverts below this (R1-#2) |
| Rate cap | N/A | sanity ceiling enforced on-chain (R1-#3) |
| Default split | Collateral → lender | **Aave-style** (R1-#4): 3% bounty / 1% insurance / debt-equiv to lender / excess refund to borrower |
| Liquidator bounty | N/A | **3%** of collateral to msg.sender |
| Insurance pool fee | N/A | **1%** of collateral accrues to insurance pool |
| Grace period (anti-flash) | N/A | **60 seconds** after origination |
| Price feed staleness limit | N/A | **1 hour** (Chainlink heartbeat) |
| Repay path pausability | N/A | **NOT pausable** (R2-#2): owner cannot force borrower into default |
| LTV cap by regime | ✅ Static (RESTING 92% → HIGH 70%) | ✅ Same caps applied off-chain at origination |
| Matching pause | ✅ in EXTREME regime | ✅ Same |
| `currentLTV(loanId)` view | ❌ | ✅ Returns (ltv_bps, eth_price, liquidatable_bool) |
| Asset whitelist | All | USDC principal + WETH collateral (multi-asset is v2.0+) |
| EIP-712 domain | `("InterAgentRepo", "1")` | `("InterAgentRepo", "4")` — non-replayable across versions |

#### How liquidation works in V2

1. **Anyone** can call `liquidate(loanId)` — no permissioning, gas-incentivized via bounty
2. Contract pulls current ETH/USD price from Chainlink feed (reverts if stale > 1h or zero)
3. Computes `current_ltv_bps = principalValue × 10000 / collateralValue` (USD-scaled)
4. Reverts if LTV < 9500 (95% threshold) — `LtvNotBreached(currentLtvBps, 9500)`
5. Reverts if within grace period — `GracePeriodActive()`
6. Splits collateral:
   - **3%** → msg.sender (liquidator bounty, gas-positive even at $5 loan size)
   - **1%** → insurance pool (currently burner wallet, will rotate to multisig)
   - **96%** → lender (recovered value)
7. Emits `LoanLiquidated(loanId, liquidator, currentLtvBps, ethPriceE8, bounty, insuranceFee, lenderRecovered)`

#### Off-chain liquidation monitoring

Two free REST endpoints expose live state to potential liquidators:

- **`GET /v1/active-loans`** — all originated loans with current LTV (for dashboard)
- **`GET /v1/liquidatable-loans`** — only loans where LTV ≥ 95% AND grace passed
                                     (ready-to-trigger feed for liquidator bots)

The matcher calls `currentLTV()` view function on V2 per loan via `eth_call`,
no events scanning needed.

### Future risk extensions (post-hackathon, v2.0+)

- **Partial repayment** + proportional collateral release
- **Margin call notifications** (off-chain → borrower webhook before liquidation)
- **Multi-collateral support** (BTC, EURC, ETH-as-principal — needs per-asset Chainlink feeds)
- **Dutch auction liquidation** instead of fixed-bounty for large positions
- **ERC-8004 credit-based variable LTV** per counterparty default history
- **Insurance pool governance** — DAO over disbursement, claim mechanics

---

## Off-chain matching engine

### Intent submission

Lenders and borrowers submit intents via REST API. Both schemas accept an optional `webhook_url` for push notification on match:

```json
POST /v1/intent/lend
{
  "wallet": "0xLender...",
  "asset": "USDC",
  "amount": 50,
  "max_duration_sec": 14400,
  "min_rate_bps": 380,
  "max_default_prob": 0.001,
  "expires_at": 1779385000,
  "webhook_url": "https://my-agent.example.com/match-callback"   // optional
}

POST /v1/intent/borrow
{
  "wallet": "0xBorrower...",
  "principal_asset": "USDC",
  "principal_amount": 50,
  "collateral_asset": "WETH",
  "collateral_amount_max": 0.025,
  "duration_sec": 1800,
  "max_rate_bps": 500,
  "expires_at": 1779385000,
  "webhook_url": "https://my-agent.example.com/match-callback"   // optional
}
```

### Match notifications — no polling required

Once an intent is submitted, agents have three ways to learn about a match:

**(A) Webhook (push)** — agent provides `webhook_url` at submit time. When matcher
fires, server POSTs the full signed quote to that URL within ~1 second.
Best-effort: 5s timeout, no retries. Idempotency on the agent's side via
`match_id` deduplication.

```json
POST https://my-agent.example.com/match-callback
{
  "event": "match_found",
  "match_id": "match_xyz...",
  "your_role": "lender",
  "your_intent_id": "lend_abc...",
  "quote": { /* full Quote struct + EIP-712 sig, ready for V4.originate() */ },
  "created_at": 1779449...
}
```

Headers:
```
Content-Type: application/json
X-RegimeShift-Event: match_found
User-Agent: regimeshift-clearinghouse-webhook/1.0
```

**(B) Long-poll** — for agents without public endpoints (local, serverless,
or behind NAT):

```
GET /v1/intent/{intent_id}/match?wait=N   (max wait = 300s)
```

Response when matched (returns immediately if already matched, otherwise holds connection):
```json
{
  "ok": true,
  "matched": true,
  "match_id": "match_xyz...",
  "elapsed_sec": 8.2,
  "quote": { /* full signed payload */ }
}
```

Response on timeout (re-poll with same intent_id):
```json
{
  "ok": true,
  "matched": false,
  "timeout_sec": 300,
  "hint": "Re-poll with the same intent_id, or submit with webhook_url..."
}
```

**(C) Manual polling** — `GET /v1/matches/recent?limit=N` + filter by wallet.
Not recommended (wastes resources), but supported for compatibility.

### Matching algorithm

1. **Find compatible pairs:** asset match, duration overlap, rate compatibility
2. **Compute clearing rate:** `max(lender.min_rate, agent_sofr_quote)`
3. **Compute required collateral:** `principal / max_safe_ltv(regime, duration, lender.max_default_prob) / collateral_price`
4. **Verify borrower can provide:** `required_collateral ≤ borrower.collateral_amount_max`
5. **Sort by clearing rate (ascending)** — best deal first
6. **Match top pair:** generate EIP-712 signed quote
7. **Notify both parties:** 60s to submit `originate()` on-chain

### Matching engine pseudocode

```python
def match():
    while True:
        lenders = open_intents(side="lend")
        borrowers = open_intents(side="borrow")
        
        compatible = [
            (l, b) for l in lenders for b in borrowers
            if l.asset == b.principal_asset
            and l.max_duration >= b.duration
            and l.min_rate <= b.max_rate
        ]
        
        if not compatible:
            sleep(1)
            continue
        
        # Sort by clearing rate (cheapest first)
        compatible.sort(
            key=lambda pair: max(pair[0].min_rate, current_sofr(pair[1].duration))
        )
        
        for lender, borrower in compatible:
            regime = current_regime()
            max_ltv = max_safe_ltv(
                asset=borrower.collateral_asset,
                duration_sec=duration_to_seconds(borrower.duration),
                regime=regime,
                lender_max_default_prob=lender.max_default_prob,
            )
            
            clearing_rate = max(lender.min_rate, current_sofr(borrower.duration))
            collateral_req = borrower.principal_amount / max_ltv / get_price(borrower.collateral_asset)
            
            if collateral_req > borrower.collateral_amount_max:
                continue  # not enough collateral offered for this regime
            
            # Build EIP-712 quote
            quote = build_quote(
                borrower, lender, clearing_rate, collateral_req,
                duration=borrower.duration,
                regime=regime,
            )
            signature = sign_eip712(quote, oracle_private_key)
            
            notify(lender.wallet, "match_found", quote, signature)
            notify(borrower.wallet, "match_found", quote, signature)
            
            mark_matched(lender, borrower)
            break  # next iteration finds next best match
```

---

## Closed-loop economics

Our own agent (`vrp-agent`) consumes the marketplace it operates:

- **`DEFENSIVE_CASH` state** → auto-submits **lender intent** (puts capital to work between sessions)
- **Entering session-long mode** → could submit **borrower intent** (leverage entry beyond own capital)
- **Idle on Base side of CCTP bridge** → auto-lender for the 60-180s window
- **VRP signal feeds back** → agent's regime classifier informs marketplace pricing

**Our agent is simultaneously orchestrator AND market participant.** Permitted because all formulas are open-source — no conflict of interest, just transparent participation. This creates **endogenous bootstrap liquidity** — we don't wait for external lenders, we start with our own inventory.

---

## Pricing — how we monetize

Five revenue streams, all derived from the same calibrator. Tiered pricing reflects value delivered:

| Role | Revenue source |
|------|----------------|
| **Oracle (VRP signals)** | $0.001 per query — onboarding tier (eventual target $0.005, CMC-pro level) |
| **Oracle (Agent-SOFR rate)** | $0.001 per query — onboarding tier (eventual target $0.10 Messari-Enterprise — category-defining product, no equivalent on-chain benchmark exists) |
| **Oracle (Max-LTV risk)** | $0.001 per query — onboarding tier (eventual target $0.005) |
| **Oracle (signed loan quote)** | $0.05 flat OR 5 bps of principal — whichever larger (action tier) |
| **Matcher** | 5-10 bps take on each matched loan (on-chain settlement) |
| **Insurance accruals** | 1% of liquidated collateral on each `V2.liquidate()` |
| **Lender** | Spread between fair rate and quoted rate (when our agent is LP) |
| **Borrower** | Cheap access to capital for our own arb strategies |
| **Reputation** | Issuing ERC-8004 credit attestations (future: paid) |

Total expected gross margin at scale (~$1M daily loan volume, ~10k Agent-SOFR queries) — **post-acquisition tier pricing**:
- Matching fee: 7 bps × $1M = $700/day
- Agent-SOFR queries: 10,000 × $0.10 (target) = $1,000/day
- VRP + max-LTV queries: 50,000 × $0.005 (target) = $250/day
- Loan quote fees: 5 bps × $1M = $500/day (assumes quote-per-match)
- Insurance pool accruals: ~$50/day at modest liquidation rate
- Our LP spread: 20 bps × $100k of own capital = $5/day
- **Total target: ~$2,500/day at $1M volume = ~$910k/year**

Pricing rationale: during the acquisition phase, **all endpoints are held at $0.001 per call** — the minimum probe amount external agents pay when evaluating unknown services. Friction-free trial keeps the funnel open while we build organic traffic; revenue base in this phase is loan-interest spread + V4 liquidator bounty (3%), not endpoint micro-payments. Once organic external paying-agent traffic stabilises, VRP and max-LTV move to $0.005 (CMC-pro level), Agent-SOFR to $0.10 (Messari-Enterprise — no equivalent on-chain benchmark exists). Signed loan quotes will scale with loan value (5 bps), aligning our incentive with marketplace utilisation.

---

## Roadmap

- **v0.1 (Day 2-3, MVP):** USDC borrow / WETH collateral, fixed durations, max $50 loan, single regime cap per mode
- **v0.2 (Day 4+):** Multi-asset support (EURC, ETH borrow), multi-duration, all 3 quote modes
- **v1.0 (Q1 2026):** Pre-expiry liquidation, partial fills, ERC-8004 credit spreads
- **v1.5 (Q2 2026):** Insurance pool, variance swap products on top of same calibrator
- **v2.0 (Q3 2026):** Cross-chain settlement (Base ↔ HyperEVM ↔ Arc), atomic flash layer for sub-block opportunities (only if demand justifies)
