// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {EIP712} from "openzeppelin-contracts/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "openzeppelin-contracts/contracts/utils/cryptography/ECDSA.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";

/// @notice Minimal Chainlink AggregatorV3 interface — only the fields we use.
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

/// @title InterAgentRepoV2
/// @notice Bilateral collateralized term-loan escrow with pre-expiry liquidation.
///
/// Adds to V1:
///  - Chainlink-based pre-expiry liquidation
///  - Liquidator bounty (incentive to monitor + trigger)
///  - Insurance pool accruals (1% of liquidated collateral)
///  - 60s grace period after origination (anti-flash defense)
///  - 1h price feed staleness limit
///
/// MVP scope: principal must be USDC (peg=$1, no feed needed), collateral
/// must be WETH (priced via Chainlink ETH/USD). Multi-asset support is v2.0+.
///
/// EIP-712 domain is bumped to "InterAgentRepo", "2" so quotes signed for
/// V1 cannot be replayed against V2 and vice versa.
contract InterAgentRepoV2 is EIP712, ReentrancyGuard, Ownable {
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
        bool liquidated;          // NEW in V2
    }

    // ─── EIP-712 ────────────────────────────────────────────────────────────

    bytes32 public constant QUOTE_TYPEHASH = keccak256(
        "Quote(address borrower,address lender,address principalToken,"
        "uint256 principalAmount,address collateralToken,uint256 collateralAmount,"
        "uint256 expiryTimestamp,uint256 rateBps,bytes32 nonce)"
    );

    // ─── Liquidation parameters (constants for MVP — governance for v2.0) ───

    /// @notice When current LTV ≥ this threshold, anyone can call liquidate().
    /// 9500 = 95%. Gives 5% buffer between trigger and total loss for lender.
    uint256 public constant LIQUIDATION_LTV_BPS = 9_500;

    /// @notice Bounty paid to whoever triggers liquidate(), as % of collateral.
    /// 300 = 3%. Compensates liquidator for gas + monitoring cost.
    uint256 public constant LIQUIDATOR_BOUNTY_BPS = 300;

    /// @notice Insurance pool fee on each liquidation, as % of collateral.
    /// 100 = 1%. Funds an insurance pool for future bad-debt coverage.
    uint256 public constant INSURANCE_FEE_BPS = 100;

    /// @notice Anti-flash defense: liquidation impossible within first 60s.
    /// Prevents same-block manipulate-feed-then-liquidate attack vectors.
    uint256 public constant GRACE_PERIOD_SECONDS = 60;

    /// @notice Price feed must be updated within this window. Reverts on stale.
    /// 1 hour is well under Chainlink heartbeat for ETH/USD on Base (~20 min).
    uint256 public constant PRICE_STALENESS_LIMIT = 1 hours;

    // ─── Immutable config ───────────────────────────────────────────────────

    IChainlinkFeed public immutable ethUsdFeed;
    address public immutable wethAddress;
    address public immutable usdcAddress;

    // ─── Mutable state ──────────────────────────────────────────────────────

    address public oracleSigner;
    address public insurancePoolAddress;

    mapping(bytes32 => Loan) public loans;
    mapping(bytes32 => bool) public consumedNonces;

    /// @notice MVP safety cap on principal size.
    uint256 public constant PRINCIPAL_CAP = 50_000_000;  // 50 USDC (6 dp)

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
        uint256 rateBps
    );
    event LoanRepaid(
        bytes32 indexed loanId,
        uint256 principalRepaid,
        uint256 interestPaid,
        uint256 collateralReleased
    );
    event LoanDefaulted(
        bytes32 indexed loanId,
        uint256 collateralSeized
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
    // V2-specific
    error PriceStale();
    error PriceInvalid();
    error LtvNotBreached(uint256 currentLtvBps, uint256 thresholdBps);
    error GracePeriodActive();

    // ─── Constructor ────────────────────────────────────────────────────────

    constructor(
        address _oracleSigner,
        address _ethUsdFeed,
        address _wethAddress,
        address _usdcAddress,
        address _insurancePool
    )
        EIP712("InterAgentRepo", "2")
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
        returns (bytes32 loanId)
    {
        if (q.borrower == address(0) || q.lender == address(0)) revert ZeroAddress();
        if (q.principalAmount == 0 || q.collateralAmount == 0) revert ZeroAmount();
        if (q.expiryTimestamp <= block.timestamp) revert QuoteExpired();
        if (q.principalAmount > PRINCIPAL_CAP) revert PrincipalCapExceeded();
        if (consumedNonces[q.nonce]) revert NonceConsumed();

        // Asset whitelist — MVP only supports USDC/WETH
        if (q.principalToken != usdcAddress) revert UnsupportedPrincipal();
        if (q.collateralToken != wethAddress) revert UnsupportedCollateral();

        address signer = recoverSigner(q, sig);
        if (signer != oracleSigner) revert InvalidSignature();

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
            q.expiryTimestamp, q.rateBps
        );
    }

    // ─── Core: repay ────────────────────────────────────────────────────────

    function repay(bytes32 loanId) external nonReentrant {
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

    // ─── Core: defaultLoan (post-expiry, no liquidation needed) ─────────────

    function defaultLoan(bytes32 loanId) external nonReentrant {
        Loan storage loan = loans[loanId];
        if (loan.borrower == address(0)) revert LoanNotFound();
        if (loan.repaid || loan.defaulted || loan.liquidated) revert LoanAlreadyClosed();
        if (block.timestamp <= loan.expiryTimestamp) revert LoanNotExpired();

        loan.defaulted = true;
        IERC20(loan.collateralToken).safeTransfer(loan.lender, loan.collateralAmount);

        emit LoanDefaulted(loanId, loan.collateralAmount);
    }

    // ─── V2 Core: liquidate (pre-expiry, Chainlink-driven) ──────────────────

    /// @notice Liquidate a loan whose collateral value has dropped below
    ///         LIQUIDATION_LTV_BPS threshold. Callable by anyone (liquidator
    ///         receives bounty as incentive).
    ///
    /// Distribution of collateral:
    ///   - 3% to msg.sender (liquidator bounty)
    ///   - 1% to insurance pool
    ///   - 96% to lender (recovered amount)
    ///
    /// Lender's net outcome vs principal depends on how far collateral dropped;
    /// the variance + regime premium baked into rate compensates ex-ante.
    function liquidate(bytes32 loanId) external nonReentrant {
        Loan storage loan = loans[loanId];
        if (loan.borrower == address(0)) revert LoanNotFound();
        if (loan.repaid || loan.defaulted || loan.liquidated) revert LoanAlreadyClosed();

        // Anti-flash: liquidation impossible within first 60s
        if (block.timestamp < loan.originationTimestamp + GRACE_PERIOD_SECONDS) {
            revert GracePeriodActive();
        }

        (uint256 currentLtvBps, uint256 ethPriceE8) = _currentLtvAndPrice(loan);

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

    // ─── Internal LTV computation ───────────────────────────────────────────

    /// @dev Pulls current ETH/USD from Chainlink and computes current LTV.
    ///      Reverts on stale/invalid price. Both outputs scaled appropriately.
    ///
    ///      principal_value_e18 = principalAmount × 10^12  (USDC has 6 dp)
    ///      collateral_value_e18 = collateralAmount × ethPriceE8 / 1e8  (WETH 18 dp)
    ///      currentLtvBps = principal_value × 10000 / collateral_value
    function _currentLtvAndPrice(Loan storage loan) internal view
        returns (uint256 currentLtvBps, uint256 ethPriceE8)
    {
        // Get current ETH price from Chainlink
        (, int256 priceI, , uint256 updatedAt, ) = ethUsdFeed.latestRoundData();
        if (block.timestamp - updatedAt > PRICE_STALENESS_LIMIT) revert PriceStale();
        if (priceI <= 0) revert PriceInvalid();
        ethPriceE8 = uint256(priceI);

        uint256 principalValueE18 = loan.principalAmount * 1e12;
        uint256 collateralValueE18 = (loan.collateralAmount * ethPriceE8) / 1e8;

        if (collateralValueE18 == 0) revert PriceInvalid();
        currentLtvBps = (principalValueE18 * 10_000) / collateralValueE18;
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

    /// @notice Off-chain monitoring helper. Returns current LTV + whether
    ///         loan is liquidatable RIGHT NOW (LTV breached + grace period passed).
    ///         Returns (0, false) for closed or unsupported loans.
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

        // Read Chainlink without reverting on stale (just return liquidatable=false)
        (, int256 priceI, , uint256 updatedAt, ) = ethUsdFeed.latestRoundData();
        if (priceI <= 0 || block.timestamp - updatedAt > PRICE_STALENESS_LIMIT) {
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
