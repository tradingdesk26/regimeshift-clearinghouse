# Inter-Agent Clearinghouse — The Marketplace

## What it is

A bilateral RFQ marketplace where agents can lend, borrow, and swap collateralized capital at sub-block to multi-hour horizons. **The interbank market for AI agents**, with Agent-SOFR as the benchmark rate.

Two settlement layers serve different timescales:

| Layer | Horizon | Collateral | Settlement |
|-------|---------|-----------|-----------|
| **L1 Atomic** | Sub-block (<12s) | None (atomic revert) | Within single transaction |
| **L2 Term** | Minutes to hours | On-chain locked | `InterAgentRepo.sol` escrow |

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

## Layer 1 — Atomic flash loans (no collateral)

### When it applies

Agent borrows funds to execute a strategy that completes within a single block (~12s on Base). Examples:

- Cross-DEX arbitrage between two AMMs
- Collateral swap (sell collateral A, buy collateral B in one tx)
- Liquidation atomicity
- MEV recapture

### How it works

```
1. Agent calls InterAgentRepo.flashLoan(asset, amount, callbackContract, data)
2. Contract sends amount to callbackContract
3. callbackContract executes strategy
4. callbackContract returns amount + flash fee to InterAgentRepo
5. If step 4 fails → entire transaction reverts (loan never happened)
```

No collateral required. Risk = zero (atomic guarantee).

Flash fee = `agent_sofr(asset, 1m)` × small premium for atomicity.

### MVP scope

Not in 4-day shipping plan. Reuses existing Aave/Balancer flash loan infrastructure for now. Custom flash variant is post-hackathon.

---

## Layer 2 — Term loans (collateralized)

### When it applies

Cross-block, cross-chain, or otherwise non-atomic strategies. Examples:

- Bridge timing windows (CCTP V2 attestation = 60s, longer than one block)
- Hold position through multiple oracle updates
- Cross-chain arbitrage spanning Base ↔ HyperEVM
- Multi-step strategy with external API calls

### Settlement contract: `InterAgentRepo.sol`

```solidity
struct Loan {
    address borrower;
    address lender;
    address principal_token;     // What's being lent (e.g., USDC)
    uint256 principal_amount;     // How much
    address collateral_token;    // What's collateralizing (e.g., WETH)
    uint256 collateral_amount;
    uint256 expiry_timestamp;
    uint256 rate_bps;             // Rate at origination (in basis points)
    bool repaid;
    bool defaulted;
}

mapping(bytes32 => Loan) public loans;
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
    // Verify the rate matches Agent-SOFR signature
    bytes32 quote_hash = keccak256(abi.encode(
        principal_token, principal_amount,
        collateral_token, collateral_amount,
        expiry_timestamp, rate_bps
    ));
    require(_verifyOracleSig(quote_hash, oracle_signature), "bad sig");
    
    // Pull collateral from borrower
    IERC20(collateral_token).transferFrom(borrower, address(this), collateral_amount);
    
    // Pull principal from lender, send to borrower
    IERC20(principal_token).transferFrom(lender, borrower, principal_amount);
    
    // Record loan
    loan_id = quote_hash;
    loans[loan_id] = Loan({
        borrower: borrower,
        lender: lender,
        principal_token: principal_token,
        principal_amount: principal_amount,
        collateral_token: collateral_token,
        collateral_amount: collateral_amount,
        expiry_timestamp: expiry_timestamp,
        rate_bps: rate_bps,
        repaid: false,
        defaulted: false
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
    
    // Pull repayment from borrower, send to lender
    IERC20(loan.principal_token).transferFrom(loan.borrower, loan.lender, total_repay);
    
    // Release collateral back to borrower
    IERC20(loan.collateral_token).transfer(loan.borrower, loan.collateral_amount);
    
    loan.repaid = true;
    emit LoanRepaid(loan_id, total_repay);
}
```

#### 3. `default(loan_id)` — Past expiry, lender claims collateral

```solidity
function defaultLoan(bytes32 loan_id) external {
    Loan storage loan = loans[loan_id];
    require(!loan.repaid && !loan.defaulted, "loan closed");
    require(block.timestamp > loan.expiry_timestamp, "not expired yet");
    
    // Transfer collateral to lender
    IERC20(loan.collateral_token).transfer(loan.lender, loan.collateral_amount);
    
    loan.defaulted = true;
    emit LoanDefaulted(loan_id);
}
```

### Risk management

- **LTV at origination:** Off-chain matching enforces LTV ≥ 105% based on regime
  - LOW regime: LTV ≤ 95% (allow more leverage)
  - MID: LTV ≤ 85%
  - HIGH: LTV ≤ 75%
  - EXTREME: matching paused
- **Expiry buffer:** Off-chain matching adds ~5min buffer to allow for oracle update delays
- **MVP simplifications (Day 2-3):**
  - No partial fills (full intent or nothing)
  - Fixed duration buckets (1h, 4h, 24h)
  - One asset pair: USDC borrow against WETH collateral
  - Max loan size $50 (capped via `require(principal_amount < 50e6)`)
  - No liquidation pre-expiry (collateral can only be claimed on default)

### Future risk extensions (post-MVP)

- **Pre-expiry liquidation** when LTV deteriorates (price oracle check)
- **Partial repayment** + partial collateral release
- **Margin calls** triggered when LTV crosses threshold
- **Insurance pool** funded by orchestrator take to cover gap losses
- **ERC-8004 credit history** → variable LTV per counterparty

---

## Off-chain matching engine

### Intent submission

Lenders and borrowers submit intents via REST API:

```
POST /v1/intent/lend
{
  "wallet": "0xLender...",
  "asset": "USDC",
  "amount": 50,                    // in token units (e.g., 50 USDC)
  "max_duration": "4h",
  "min_rate_bps": 380,             // 3.80% annual
  "expires_at": 1779385000
}

POST /v1/intent/borrow
{
  "wallet": "0xBorrower...",
  "principal_asset": "USDC",
  "principal_amount": 50,
  "collateral_asset": "WETH",
  "collateral_amount_max": 0.025,  // willing to post up to 0.025 WETH
  "duration": "30m",
  "max_rate_bps": 500,
  "expires_at": 1779385000
}
```

### Matching algorithm

1. **Find compatible pairs:** lender's `asset` == borrower's `principal_asset`, lender's `max_duration` ≥ borrower's `duration`
2. **Check rate compatibility:** lender's `min_rate_bps` ≤ borrower's `max_rate_bps`
3. **Compute clearing rate:** `clearing_rate = max(lender_min, agent_sofr_quote)` — borrower never pays less than fair value
4. **Compute collateral required:** `collateral_required = principal_amount × ltv_ratio / collateral_price`
5. **Sort pairs:** by `clearing_rate ascending` (best deal first)
6. **Match top pair:** generate EIP-712 signed quote
7. **Return to both parties:** they have 60s to submit `originate()` call on-chain

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
        
        # Sort by clearing rate
        compatible.sort(key=lambda pair: max(pair[0].min_rate, current_sofr(pair[1].duration)))
        
        for lender, borrower in compatible:
            clearing_rate = max(lender.min_rate, current_sofr(borrower.duration))
            collateral_req = borrower.principal_amount * ltv_ratio() / get_price(borrower.collateral_asset)
            
            if collateral_req > borrower.collateral_amount_max:
                continue  # not enough collateral offered
            
            # Build EIP-712 message
            quote = {
                "borrower": borrower.wallet,
                "lender": lender.wallet,
                "principal_token": ASSET_ADDRESS[borrower.principal_asset],
                "principal_amount": borrower.principal_amount * 10**decimals(borrower.principal_asset),
                "collateral_token": ASSET_ADDRESS[borrower.collateral_asset],
                "collateral_amount": collateral_req * 10**decimals(borrower.collateral_asset),
                "expiry_timestamp": now() + duration_seconds(borrower.duration) + buffer,
                "rate_bps": int(clearing_rate * 100)
            }
            
            signature = sign_eip712(quote, oracle_private_key)
            
            # Notify both parties
            notify(lender.wallet, "match_found", quote, signature)
            notify(borrower.wallet, "match_found", quote, signature)
            
            # Mark intents as matched
            mark_matched(lender, borrower)
            
            break  # next iteration finds the next best match
```

---

## Closed-loop economics

Our own agent (`vrp-agent`) consumes the marketplace it operates:

- When in `DEFENSIVE_CASH` state: auto-submits lender intent (puts capital to work between sessions)
- When in `LONG_ON_HL` state (entering): could submit borrower intent (leverage entry)
- When idle on Base side of CCTP bridge: auto-lender for the 60s window

**Our agent is simultaneously the orchestrator AND a market participant.** This is permitted because all formulas are open-source — no conflict of interest, just transparent participation.

This creates **endogenous bootstrap liquidity** — we don't need external lenders to be in the book before launch. Our own agent is the first liquidity provider.

---

## Pricing — how we monetize

Five revenue streams, all derived from the same formula:

| Role | Revenue source |
|------|----------------|
| **Oracle** | $0.001 per Agent-SOFR query (x402 paid endpoint) |
| **Matcher** | 5-10 bps take on each matched loan |
| **Lender** | Spread between fair rate and quoted rate (when our agent is LP) |
| **Borrower** | Cheap access to capital for our own arb strategies |
| **Reputation** | Issuing ERC-8004 credit attestations (future: paid) |

Total expected gross margin at scale (~$1M daily loan volume):
- Matching fee: 7 bps × $1M = $700/day
- Oracle queries: 10,000 × $0.001 = $10/day
- Our LP spread: 20 bps × $100k of own capital = $5/day
- **Total: ~$715/day at $1M volume, $260k/year**

This is the **simplest possible revenue model**. Margins improve as we add credit attestations and insurance fees.

---

## Roadmap

- **v0.1 (Day 2-3, MVP):** USDC borrow / WETH collateral, single duration bucket, max $50 loan
- **v0.2 (Day 4+):** Multi-asset support (EURC, ETH), multi-duration
- **v1.0 (Q1 2026):** Pre-expiry liquidation, partial fills, atomic flash layer
- **v2.0 (Q2 2026):** ERC-8004 credit-based variable LTV, insurance pool, cross-chain
