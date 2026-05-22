// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {EIP712} from "openzeppelin-contracts/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "openzeppelin-contracts/contracts/utils/cryptography/ECDSA.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {Pausable} from "openzeppelin-contracts/contracts/utils/Pausable.sol";

/// @notice Minimal Chainlink AggregatorV3 interface.
interface IChainlinkFeed {
    function decimals() external view returns (uint8);
    function latestRoundData() external view returns (
        uint80 roundId,
        int256 answer,
        uint256 startedAt,
        uint256 updatedAt,
        uint80 answeredInRound
    );
}

/// @title InterAgentRepoV3
/// @notice V3 — addresses audit round-1 HIGH findings #1-#4 + LOW #8-#9.
///
/// Changes vs V2:
///  - originate() validates: initial LTV ≤ (LIQUIDATION_LTV - MIN_LTV_BUFFER),
///                            duration ≥ GRACE_PERIOD + MIN_DURATION_BUFFER,
///                            rateBps ≤ MAX_RATE_BPS
///  - defaultLoan() now uses Chainlink-based fair split (3% bounty / 1% insurance /
///                  min(debt-equiv, remaining) to lender / excess back to borrower)
///  - Chainlink read checks answeredInRound >= roundId (defense in depth)
///  - OZ Pausable mixin — owner can emergencyPause()/Unpause()
///  - EIP-712 domain bumped to ("InterAgentRepo", "3") — V2 quotes can't replay
///
/// Audit reference: see audit/round1.md
contract InterAgentRepoV3 is EIP712, ReentrancyGuard, Ownable, Pausable {
    using SafeERC20 for IERC20;

    // ─── Types ──────────────────────────────────────────────────────────────

    struct Quote {
        address borrower;
        address lender;
        address principalToken;
        uint256 principalAmount;
        address collateralToken;
        uint256 collateralAmount;
        uint256 expiryTimestamp;
        uint256 rateBps;
        bytes32 nonce;
    }

    struct Loan {
        address borrower;
        address lender;
        address principalToken;
        uint256 principalAmount;
        address collateralToken;
        uint256 collateralAmount;
        uint256 originationTimestamp;
        uint256 expiryTimestamp;
        uint256 rateBps;
        bool repaid;
        bool defaulted;
        bool liquidated;
    }

    // ─── EIP-712 ────────────────────────────────────────────────────────────

    bytes32 public constant QUOTE_TYPEHASH = keccak256(
        "Quote(address borrower,address lender,address principalToken,"
        "uint256 principalAmount,address collateralToken,uint256 collateralAmount,"
        "uint256 expiryTimestamp,uint256 rateBps,bytes32 nonce)"
    );

    // ─── Constants ──────────────────────────────────────────────────────────

    uint256 public constant LIQUIDATION_LTV_BPS = 9_500;          // 95% — same as V2
    uint256 public constant LIQUIDATOR_BOUNTY_BPS = 300;          // 3% bounty
    uint256 public constant INSURANCE_FEE_BPS = 100;              // 1% insurance
    uint256 public constant GRACE_PERIOD_SECONDS = 60;            // anti-flash window

    /// @notice Per audit #1 — initial LTV must be at least this far below the
    /// liquidation threshold. 200 bps = 2% buffer → max origination LTV = 93%.
    uint256 public constant MIN_LTV_BUFFER_BPS = 200;

    /// @notice Per audit #2 — loan duration must exceed GRACE_PERIOD + this.
    /// 60s buffer means min total duration = 120s (2 minutes).
    /// Ensures liquidation window opens before default window.
    uint256 public constant MIN_DURATION_BUFFER_SECONDS = 60;

    /// @notice Per audit #3 — rateBps must not exceed this. 100_000 = 1000% APR.
    /// Sanity ceiling — anything higher signals a buggy oracle or bad UX.
    uint256 public constant MAX_RATE_BPS = 100_000;

    /// @notice Chainlink price staleness limit (1 hour).
    uint256 public constant PRICE_STALENESS_LIMIT = 1 hours;

    /// @notice MVP safety cap on principal size.
    uint256 public constant PRINCIPAL_CAP = 50_000_000;  // 50 USDC (6 dp)

    // ─── Immutable config ───────────────────────────────────────────────────

    IChainlinkFeed public immutable ethUsdFeed;
    address public immutable wethAddress;
    address public immutable usdcAddress;

    // ─── Mutable state ──────────────────────────────────────────────────────

    address public oracleSigner;
    address public insurancePoolAddress;

    mapping(bytes32 => Loan) public loans;
    mapping(bytes32 => bool) public consumedNonces;

    // ─── Events ─────────────────────────────────────────────────────────────

    event LoanOriginated(
        bytes32 indexed loanId,
        address indexed borrower,
        address indexed lender,
        address principalToken,
        uint256 principalAmount,
        address collateralToken,
        uint256 collateralAmount,
        uint256 expiryTimestamp,
        uint256 rateBps,
        uint256 initialLtvBps,
        uint256 ethPriceE8AtOrigination
    );
    event LoanRepaid(
        bytes32 indexed loanId,
        uint256 principalRepaid,
        uint256 interestPaid,
        uint256 collateralReleased
    );
    event LoanDefaulted(
        bytes32 indexed loanId,
        address indexed triggerer,
        uint256 ethPriceE8,
        uint256 bountyPaid,
        uint256 insuranceFee,
        uint256 lenderRecovered,
        uint256 borrowerRefund
    );
    event LoanLiquidated(
        bytes32 indexed loanId,
        address indexed liquidator,
        uint256 currentLtvBps,
        uint256 ethPriceE8,
        uint256 bountyPaid,
        uint256 insuranceFee,
        uint256 lenderRecovered
    );
    event OracleSignerRotated(address indexed oldSigner, address indexed newSigner);
    event InsurancePoolRotated(address indexed oldPool, address indexed newPool);
    event EmergencyPaused(address indexed by);
    event EmergencyUnpaused(address indexed by);

    // ─── Errors ─────────────────────────────────────────────────────────────

    error InvalidSignature();
    error QuoteExpired();
    error NonceConsumed();
    error LoanNotFound();
    error LoanAlreadyClosed();
    error LoanNotExpired();
    error PrincipalCapExceeded();
    error ZeroAddress();
    error ZeroAmount();
    error UnsupportedPrincipal();
    error UnsupportedCollateral();
    error PriceStale();
    error PriceInvalid();
    error InvalidRoundData();
    error LtvNotBreached(uint256 currentLtvBps, uint256 thresholdBps);
    error GracePeriodActive();
    // V3-specific
    error InitialLtvTooHigh(uint256 initialLtvBps, uint256 maxAllowedBps);
    error LoanDurationTooShort(uint256 expiryTimestamp, uint256 minimumExpiryTimestamp);
    error RateTooHigh(uint256 rateBps, uint256 maxRateBps);

    // ─── Constructor ────────────────────────────────────────────────────────

    constructor(
        address _oracleSigner,
        address _ethUsdFeed,
        address _wethAddress,
        address _usdcAddress,
        address _insurancePool
    )
        EIP712("InterAgentRepo", "3")
        Ownable(msg.sender)
    {
        if (_oracleSigner == address(0)) revert ZeroAddress();
        if (_ethUsdFeed == address(0)) revert ZeroAddress();
        if (_wethAddress == address(0)) revert ZeroAddress();
        if (_usdcAddress == address(0)) revert ZeroAddress();
        if (_insurancePool == address(0)) revert ZeroAddress();

        oracleSigner = _oracleSigner;
        ethUsdFeed = IChainlinkFeed(_ethUsdFeed);
        wethAddress = _wethAddress;
        usdcAddress = _usdcAddress;
        insurancePoolAddress = _insurancePool;

        emit OracleSignerRotated(address(0), _oracleSigner);
        emit InsurancePoolRotated(address(0), _insurancePool);
    }

    // ─── Admin ──────────────────────────────────────────────────────────────

    function setOracleSigner(address newSigner) external onlyOwner {
        if (newSigner == address(0)) revert ZeroAddress();
        emit OracleSignerRotated(oracleSigner, newSigner);
        oracleSigner = newSigner;
    }

    function setInsurancePool(address newPool) external onlyOwner {
        if (newPool == address(0)) revert ZeroAddress();
        emit InsurancePoolRotated(insurancePoolAddress, newPool);
        insurancePoolAddress = newPool;
    }

    function emergencyPause() external onlyOwner {
        _pause();
        emit EmergencyPaused(msg.sender);
    }

    function emergencyUnpause() external onlyOwner {
        _unpause();
        emit EmergencyUnpaused(msg.sender);
    }

    // ─── EIP-712 helpers ────────────────────────────────────────────────────

    function hashQuote(Quote calldata q) public view returns (bytes32) {
        bytes32 structHash = keccak256(abi.encode(
            QUOTE_TYPEHASH,
            q.borrower, q.lender,
            q.principalToken, q.principalAmount,
            q.collateralToken, q.collateralAmount,
            q.expiryTimestamp, q.rateBps,
            q.nonce
        ));
        return _hashTypedDataV4(structHash);
    }

    function recoverSigner(Quote calldata q, bytes calldata sig) public view returns (address) {
        return ECDSA.recover(hashQuote(q), sig);
    }

    // ─── Core: originate ────────────────────────────────────────────────────

    function originate(Quote calldata q, bytes calldata sig)
        external
        nonReentrant
        whenNotPaused
        returns (bytes32 loanId)
    {
        if (q.borrower == address(0) || q.lender == address(0)) revert ZeroAddress();
        if (q.principalAmount == 0 || q.collateralAmount == 0) revert ZeroAmount();
        if (q.expiryTimestamp <= block.timestamp) revert QuoteExpired();
        if (q.principalAmount > PRINCIPAL_CAP) revert PrincipalCapExceeded();
        if (consumedNonces[q.nonce]) revert NonceConsumed();

        // Asset whitelist
        if (q.principalToken != usdcAddress) revert UnsupportedPrincipal();
        if (q.collateralToken != wethAddress) revert UnsupportedCollateral();

        // ─── V3 new economic invariants ─────────────────────────────────────

        // Audit #3: rate sanity ceiling
        if (q.rateBps > MAX_RATE_BPS) revert RateTooHigh(q.rateBps, MAX_RATE_BPS);

        // Audit #2: duration must exceed grace + buffer
        // This guarantees liquidation window opens before default window
        uint256 minimumExpiry = block.timestamp + GRACE_PERIOD_SECONDS + MIN_DURATION_BUFFER_SECONDS;
        if (q.expiryTimestamp < minimumExpiry) {
            revert LoanDurationTooShort(q.expiryTimestamp, minimumExpiry);
        }

        // Audit #1: initial LTV must leave buffer below liquidation threshold
        (uint256 initialLtvBps, uint256 priceE8) = _computeLtv(q.principalAmount, q.collateralAmount);
        uint256 maxOriginationLtv = LIQUIDATION_LTV_BPS - MIN_LTV_BUFFER_BPS;  // 9300 bps
        if (initialLtvBps >= maxOriginationLtv) {
            revert InitialLtvTooHigh(initialLtvBps, maxOriginationLtv);
        }

        // ─── Signature check (same as V2) ───────────────────────────────────

        address signer = recoverSigner(q, sig);
        if (signer != oracleSigner) revert InvalidSignature();

        // ─── Record + transfer (CEI pattern) ────────────────────────────────

        consumedNonces[q.nonce] = true;
        loanId = q.nonce;

        loans[loanId] = Loan({
            borrower: q.borrower,
            lender: q.lender,
            principalToken: q.principalToken,
            principalAmount: q.principalAmount,
            collateralToken: q.collateralToken,
            collateralAmount: q.collateralAmount,
            originationTimestamp: block.timestamp,
            expiryTimestamp: q.expiryTimestamp,
            rateBps: q.rateBps,
            repaid: false,
            defaulted: false,
            liquidated: false
        });

        IERC20(q.collateralToken).safeTransferFrom(
            q.borrower, address(this), q.collateralAmount
        );
        IERC20(q.principalToken).safeTransferFrom(
            q.lender, q.borrower, q.principalAmount
        );

        emit LoanOriginated(
            loanId, q.borrower, q.lender,
            q.principalToken, q.principalAmount,
            q.collateralToken, q.collateralAmount,
            q.expiryTimestamp, q.rateBps,
            initialLtvBps, priceE8
        );
    }

    // ─── Core: repay (unchanged from V2) ────────────────────────────────────

    function repay(bytes32 loanId) external nonReentrant whenNotPaused {
        Loan storage loan = loans[loanId];
        if (loan.borrower == address(0)) revert LoanNotFound();
        if (loan.repaid || loan.defaulted || loan.liquidated) revert LoanAlreadyClosed();
        if (block.timestamp > loan.expiryTimestamp) revert LoanNotExpired();

        uint256 timeElapsed = block.timestamp - loan.originationTimestamp;
        uint256 interest = (loan.principalAmount * loan.rateBps * timeElapsed)
                            / (365 days * 10_000);
        uint256 totalRepay = loan.principalAmount + interest;

        loan.repaid = true;

        IERC20(loan.principalToken).safeTransferFrom(
            loan.borrower, loan.lender, totalRepay
        );
        IERC20(loan.collateralToken).safeTransfer(loan.borrower, loan.collateralAmount);

        emit LoanRepaid(loanId, loan.principalAmount, interest, loan.collateralAmount);
    }

    // ─── Core: defaultLoan — V3 fair split (audit #4) ───────────────────────

    /// @notice Post-expiry settlement with Aave-style fair split.
    /// Lender receives collateral equivalent to debt (principal + accrued
    /// interest at expiry). Excess collateral goes back to borrower.
    /// 3% bounty to msg.sender, 1% to insurance pool.
    ///
    /// This eliminates the audit #5 attack (lender USDC-blacklist DOS):
    /// even if lender's repay path is sabotaged, they don't get a windfall
    /// via default — just their fair debt-equivalent.
    function defaultLoan(bytes32 loanId) external nonReentrant whenNotPaused {
        Loan storage loan = loans[loanId];
        if (loan.borrower == address(0)) revert LoanNotFound();
        if (loan.repaid || loan.defaulted || loan.liquidated) revert LoanAlreadyClosed();
        if (block.timestamp <= loan.expiryTimestamp) revert LoanNotExpired();

        loan.defaulted = true;

        // Compute debt at expiry (NOT current time — interest stops accruing post-expiry)
        uint256 elapsed = loan.expiryTimestamp - loan.originationTimestamp;
        uint256 interest = (loan.principalAmount * loan.rateBps * elapsed) / (365 days * 10_000);
        uint256 debtUsdcRaw = loan.principalAmount + interest;  // in USDC native units (6 dp)

        // Get current Chainlink price
        (, uint256 ethPriceE8) = _computeLtv(loan.principalAmount, loan.collateralAmount);

        // Convert debt (USDC raw 6 dp) → collateral equivalent (WETH wei 18 dp)
        // debt_USD_e18 = debtUsdcRaw × 1e12
        // collateral_wei = debt_USD_e18 × 1e8 / priceE8
        // = (debtUsdcRaw × 1e12 × 1e8) / priceE8
        // = (debtUsdcRaw × 1e20) / priceE8
        uint256 debtCollateralEquiv = (debtUsdcRaw * 1e20) / ethPriceE8;

        // Splits: 3% bounty + 1% insurance carve out BEFORE lender debt claim
        uint256 bounty = (loan.collateralAmount * LIQUIDATOR_BOUNTY_BPS) / 10_000;
        uint256 insuranceFee = (loan.collateralAmount * INSURANCE_FEE_BPS) / 10_000;
        uint256 remaining = loan.collateralAmount - bounty - insuranceFee;

        // Lender gets min(debt-equivalent, remaining-after-carveouts)
        // If collateral is below debt-equivalent (underwater), lender gets remainder
        // (still less than V2's 100% — bounty/insurance take precedence as in liquidate)
        uint256 lenderShare = debtCollateralEquiv < remaining ? debtCollateralEquiv : remaining;
        uint256 borrowerRefund = remaining - lenderShare;

        IERC20(loan.collateralToken).safeTransfer(msg.sender, bounty);
        IERC20(loan.collateralToken).safeTransfer(insurancePoolAddress, insuranceFee);
        IERC20(loan.collateralToken).safeTransfer(loan.lender, lenderShare);
        if (borrowerRefund > 0) {
            IERC20(loan.collateralToken).safeTransfer(loan.borrower, borrowerRefund);
        }

        emit LoanDefaulted(
            loanId, msg.sender, ethPriceE8,
            bounty, insuranceFee, lenderShare, borrowerRefund
        );
    }

    // ─── Core: liquidate (unchanged from V2) ────────────────────────────────

    function liquidate(bytes32 loanId) external nonReentrant whenNotPaused {
        Loan storage loan = loans[loanId];
        if (loan.borrower == address(0)) revert LoanNotFound();
        if (loan.repaid || loan.defaulted || loan.liquidated) revert LoanAlreadyClosed();

        if (block.timestamp < loan.originationTimestamp + GRACE_PERIOD_SECONDS) {
            revert GracePeriodActive();
        }

        (uint256 currentLtvBps, uint256 ethPriceE8) =
            _computeLtv(loan.principalAmount, loan.collateralAmount);

        if (currentLtvBps < LIQUIDATION_LTV_BPS) {
            revert LtvNotBreached(currentLtvBps, LIQUIDATION_LTV_BPS);
        }

        loan.liquidated = true;

        uint256 bounty = (loan.collateralAmount * LIQUIDATOR_BOUNTY_BPS) / 10_000;
        uint256 insuranceFee = (loan.collateralAmount * INSURANCE_FEE_BPS) / 10_000;
        uint256 lenderShare = loan.collateralAmount - bounty - insuranceFee;

        IERC20(loan.collateralToken).safeTransfer(msg.sender, bounty);
        IERC20(loan.collateralToken).safeTransfer(insurancePoolAddress, insuranceFee);
        IERC20(loan.collateralToken).safeTransfer(loan.lender, lenderShare);

        emit LoanLiquidated(
            loanId, msg.sender, currentLtvBps, ethPriceE8,
            bounty, insuranceFee, lenderShare
        );
    }

    // ─── Internal Chainlink + LTV computation ───────────────────────────────

    /// @dev Reads ETH/USD from Chainlink with full sanity checks (V3 fix #8):
    ///      - block.timestamp - updatedAt ≤ STALENESS_LIMIT
    ///      - answer > 0
    ///      - answeredInRound ≥ roundId  (defense-in-depth, audit LOW #8)
    function _readEthUsdE8() internal view returns (uint256 priceE8) {
        (uint80 roundId, int256 priceI, , uint256 updatedAt, uint80 answeredInRound)
            = ethUsdFeed.latestRoundData();
        if (block.timestamp - updatedAt > PRICE_STALENESS_LIMIT) revert PriceStale();
        if (priceI <= 0) revert PriceInvalid();
        if (answeredInRound < roundId) revert InvalidRoundData();
        priceE8 = uint256(priceI);
    }

    /// @dev Compute LTV from amounts directly (works pre-origination too).
    function _computeLtv(uint256 principalAmount, uint256 collateralAmount)
        internal view returns (uint256 ltvBps, uint256 priceE8)
    {
        priceE8 = _readEthUsdE8();

        uint256 principalValueE18 = principalAmount * 1e12;
        uint256 collateralValueE18 = (collateralAmount * priceE8) / 1e8;
        if (collateralValueE18 == 0) revert PriceInvalid();
        ltvBps = (principalValueE18 * 10_000) / collateralValueE18;
    }

    // ─── View helpers ───────────────────────────────────────────────────────

    function currentOwed(bytes32 loanId) external view returns (uint256 owed) {
        Loan storage loan = loans[loanId];
        if (loan.borrower == address(0)) return 0;
        if (loan.repaid || loan.defaulted || loan.liquidated) return 0;
        uint256 elapsed = block.timestamp > loan.expiryTimestamp
            ? loan.expiryTimestamp - loan.originationTimestamp
            : block.timestamp - loan.originationTimestamp;
        uint256 interest = (loan.principalAmount * loan.rateBps * elapsed)
                            / (365 days * 10_000);
        return loan.principalAmount + interest;
    }

    function loanStatus(bytes32 loanId) external view returns (
        bool exists, bool repaid, bool defaulted, bool liquidated, bool expired
    ) {
        Loan storage loan = loans[loanId];
        exists = loan.borrower != address(0);
        repaid = loan.repaid;
        defaulted = loan.defaulted;
        liquidated = loan.liquidated;
        expired = exists && block.timestamp > loan.expiryTimestamp;
    }

    function currentLTV(bytes32 loanId) external view returns (
        uint256 currentLtvBps,
        uint256 ethPriceE8,
        bool liquidatable
    ) {
        Loan storage loan = loans[loanId];
        if (loan.borrower == address(0) || loan.repaid || loan.defaulted || loan.liquidated) {
            return (0, 0, false);
        }
        if (loan.collateralToken != wethAddress) {
            return (0, 0, false);
        }

        (uint80 roundId, int256 priceI, , uint256 updatedAt, uint80 answeredInRound)
            = ethUsdFeed.latestRoundData();
        if (priceI <= 0
            || block.timestamp - updatedAt > PRICE_STALENESS_LIMIT
            || answeredInRound < roundId) {
            return (0, 0, false);
        }
        ethPriceE8 = uint256(priceI);

        uint256 principalValueE18 = loan.principalAmount * 1e12;
        uint256 collateralValueE18 = (loan.collateralAmount * ethPriceE8) / 1e8;
        if (collateralValueE18 == 0) {
            return (0, ethPriceE8, false);
        }
        currentLtvBps = (principalValueE18 * 10_000) / collateralValueE18;

        bool gracePassed = block.timestamp >= loan.originationTimestamp + GRACE_PERIOD_SECONDS;
        liquidatable = currentLtvBps >= LIQUIDATION_LTV_BPS && gracePassed;
    }
}
