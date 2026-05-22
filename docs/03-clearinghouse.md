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
| RESTING | 46% | <14 bp | **98%** | 80% | **+18%** |
| LOW | 16% | 17 bp | **96%** | 80% | **+16%** |
| NORMAL | 16% | 20 bp | **92%** | 80% | **+12%** |
| ELEVATED | 14% | 28 bp | **85%** | 80% | **+5%** |
| HIGH | 7% | 45 bp | **75%** | 80% | **−5%** (safer for lenders) |
| EXTREME | 1% | 80+ bp | **60%** or pause | 80% | **−20%** (safer for lenders) |

**Weighted average: ~12% capital efficiency gain in calm markets + better lender protection in shocks.**

### Numerical example

For a $1,000 USDC loan over 1 hour:

| Regime | Aave required collateral | Our required collateral | Borrower frees up |
|--------|--------------------------|-------------------------|-------------------|
| RESTING | $1,250 (LTV 80%) | $1,020 (LTV 98%) | **$230 in liquid capital** |
| NORMAL | $1,250 | $1,087 (LTV 92%) | **$163** |
| HIGH | $1,250 | $1,333 (LTV 75%) | (lender protected from default cascade) |
| EXTREME | $1,250 | $1,667 or paused | (matching halted to prevent bad debt) |

In RESTING + LOW + NORMAL (78% of time) borrowers save 12-23% of collateral that's locked up under Aave's static model. **This freed capital becomes liquidity in our pool**, compounding the efficiency.

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
    "RESTING":  0.98,
    "LOW":      0.96,
    "NORMAL":   0.92,
    "ELEVATED": 0.85,
    "HIGH":     0.75,
    "EXTREME":  0.60,  # or pause matching entirely
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

### Liquidation mechanism (V2 — deployed)

V2 of the contract ([`0x2bfE0f1142B04049d867389Bf91A84e498ED11E4`](https://basescan.org/address/0x2bfE0f1142B04049d867389Bf91A84e498ED11E4)) adds pre-expiry liquidation. V1 (`0xaea1...7400`) stays live as the MVP-no-liquidation demonstration.

| Mechanism | V1 (`0xaea1...7400`) | V2 (`0x2bfE...11E4`) |
|-----------|---------------------|---------------------|
| Expiry default | ✅ `defaultLoan()` | ✅ kept |
| Pre-expiry liquidation | ❌ None | ✅ `liquidate()` with Chainlink ETH/USD |
| LTV threshold | N/A | 95% — current_ltv_bps ≥ 9500 triggers liquidation |
| Liquidator bounty | N/A | **3%** of collateral to msg.sender |
| Insurance pool fee | N/A | **1%** of collateral accrues to insurance pool |
| Grace period (anti-flash) | N/A | **60 seconds** after origination |
| Price feed staleness limit | N/A | **1 hour** (Chainlink heartbeat) |
| LTV cap by regime | ✅ Static (RESTING 98% → HIGH 75%) | ✅ Same caps applied off-chain at origination |
| Matching pause | ✅ in EXTREME regime | ✅ Same |
| `currentLTV(loanId)` view | ❌ | ✅ Returns (ltv_bps, eth_price, liquidatable_bool) |
| Asset whitelist | All | USDC principal + WETH collateral (multi-asset is v2.0+) |

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

Lenders and borrowers submit intents via REST API:

```json
POST /v1/intent/lend
{
  "wallet": "0xLender...",
  "asset": "USDC",
  "amount": 50,
  "max_duration": "4h",
  "min_rate_bps": 380,
  "max_default_prob": 0.001,    // 0.1% default tolerance (risk preference)
  "expires_at": 1779385000
}

POST /v1/intent/borrow
{
  "wallet": "0xBorrower...",
  "principal_asset": "USDC",
  "principal_amount": 50,
  "collateral_asset": "WETH",
  "collateral_amount_max": 0.025,
  "duration": "30m",
  "max_rate_bps": 500,
  "expires_at": 1779385000
}
```

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
| **Oracle (VRP signals)** | $0.005 per VRP query (commodity tier — competitive with CMC pro) |
| **Oracle (Agent-SOFR rate)** | **$0.10** per query (Messari Enterprise tier — category-defining product) |
| **Oracle (Max-LTV risk)** | $0.005 per query (risk signal tier) |
| **Oracle (signed loan quote)** | $0.05 flat OR 5 bps of principal — whichever larger (action tier) |
| **Matcher** | 5-10 bps take on each matched loan (on-chain settlement) |
| **Insurance accruals** | 1% of liquidated collateral on each `V2.liquidate()` |
| **Lender** | Spread between fair rate and quoted rate (when our agent is LP) |
| **Borrower** | Cheap access to capital for our own arb strategies |
| **Reputation** | Issuing ERC-8004 credit attestations (future: paid) |

Total expected gross margin at scale (~$1M daily loan volume, ~10k Agent-SOFR queries):
- Matching fee: 7 bps × $1M = $700/day
- Agent-SOFR queries: 10,000 × $0.10 = $1,000/day
- VRP + max-LTV queries: 50,000 × $0.005 = $250/day
- Loan quote fees: 5 bps × $1M = $500/day (assumes quote-per-match)
- Insurance pool accruals: ~$50/day at modest liquidation rate
- Our LP spread: 20 bps × $100k of own capital = $5/day
- **Total: ~$2,500/day at $1M volume = ~$910k/year**

Pricing rationale: VRP and max-LTV at $0.005 keep them competitive vs CMC/CoinGecko pro (broad adoption). **Agent-SOFR at $0.10 reflects that no equivalent product exists** — it's the only on-chain decentralized USD benchmark rate aggregated from manipulation-resistant sources. Signed loan quotes scale with loan value (5 bps), aligning our incentive with marketplace utilization. Margins improve as we add credit attestations, insurance disbursements, and variance swap products.

---

## Roadmap

- **v0.1 (Day 2-3, MVP):** USDC borrow / WETH collateral, fixed durations, max $50 loan, single regime cap per mode
- **v0.2 (Day 4+):** Multi-asset support (EURC, ETH borrow), multi-duration, all 3 quote modes
- **v1.0 (Q1 2026):** Pre-expiry liquidation, partial fills, ERC-8004 credit spreads
- **v1.5 (Q2 2026):** Insurance pool, variance swap products on top of same calibrator
- **v2.0 (Q3 2026):** Cross-chain settlement (Base ↔ HyperEVM ↔ Arc), atomic flash layer for sub-block opportunities (only if demand justifies)
