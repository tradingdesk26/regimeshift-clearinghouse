// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {EIP712} from "openzeppelin-contracts/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "openzeppelin-contracts/contracts/utils/cryptography/ECDSA.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";

/// @title InterAgentRepo
/// @notice Bilateral collateralized term-loan escrow for agent-to-agent capital markets.
///         Loan quotes are produced off-chain by the Agent-SOFR oracle and signed with
///         the oracle's keypair (EIP-712). This contract verifies the signature, locks
///         collateral from the borrower, transfers principal from lender to borrower,
///         and exposes repay() / defaultLoan() lifecycle functions.
///
/// @dev    Hackathon MVP — single-tier collateralized term lending. No partial fills,
///         no pre-expiry liquidation, no flash loans. Capped at \$50 principal in MVP
///         (see PRINCIPAL_CAP). All hardening = post-hackathon.
contract InterAgentRepo is EIP712, ReentrancyGuard, Ownable {
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
        uint256 rateBps;          // annualized basis points (4.04% = 404)
        bytes32 nonce;            // anti-replay (matching engine assigns UUID)
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
    }

    // ─── EIP-712 type hash ──────────────────────────────────────────────────

    bytes32 public constant QUOTE_TYPEHASH = keccak256(
        "Quote(address borrower,address lender,address principalToken,"
        "uint256 principalAmount,address collateralToken,uint256 collateralAmount,"
        "uint256 expiryTimestamp,uint256 rateBps,bytes32 nonce)"
    );

    // ─── State ──────────────────────────────────────────────────────────────

    /// @notice The Agent-SOFR oracle signer address (set by owner; rotated via
    ///         setOracleSigner). Quotes are valid iff signed by this key.
    address public oracleSigner;

    /// @notice loanId → Loan (loanId = quote nonce, unique per quote)
    mapping(bytes32 => Loan) public loans;

    /// @notice nonce → consumed flag (prevents replay)
    mapping(bytes32 => bool) public consumedNonces;

    /// @notice MVP safety cap on principal size
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
    event OracleSignerRotated(address indexed oldSigner, address indexed newSigner);

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

    // ─── Constructor ────────────────────────────────────────────────────────

    constructor(address _oracleSigner)
        EIP712("InterAgentRepo", "1")
        Ownable(msg.sender)
    {
        if (_oracleSigner == address(0)) revert ZeroAddress();
        oracleSigner = _oracleSigner;
        emit OracleSignerRotated(address(0), _oracleSigner);
    }

    // ─── Admin ──────────────────────────────────────────────────────────────

    function setOracleSigner(address newSigner) external onlyOwner {
        if (newSigner == address(0)) revert ZeroAddress();
        emit OracleSignerRotated(oracleSigner, newSigner);
        oracleSigner = newSigner;
    }

    // ─── EIP-712 helpers ────────────────────────────────────────────────────

    /// @notice Hash a quote per EIP-712
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

    /// @notice Recover signer from quote + signature
    function recoverSigner(Quote calldata q, bytes calldata sig) public view returns (address) {
        return ECDSA.recover(hashQuote(q), sig);
    }

    // ─── Core: originate ────────────────────────────────────────────────────

    /// @notice Open a loan from a signed quote.
    ///
    /// Pulls collateral from `q.borrower` (must have approved this contract).
    /// Pulls principal from `q.lender` (must have approved this contract).
    /// Transfers principal to borrower in same tx.
    ///
    /// Anyone can call originate() as long as both parties have set approvals —
    /// in practice the lender or borrower will trigger it themselves.
    ///
    /// @param q     The signed quote (from off-chain matcher)
    /// @param sig   Oracle's EIP-712 signature over the quote
    /// @return loanId  The loan identifier (= q.nonce)
    function originate(Quote calldata q, bytes calldata sig)
        external
        nonReentrant
        returns (bytes32 loanId)
    {
        // Basic sanity
        if (q.borrower == address(0) || q.lender == address(0)) revert ZeroAddress();
        if (q.principalAmount == 0 || q.collateralAmount == 0) revert ZeroAmount();
        if (q.expiryTimestamp <= block.timestamp) revert QuoteExpired();
        if (q.principalAmount > PRINCIPAL_CAP) revert PrincipalCapExceeded();
        if (consumedNonces[q.nonce]) revert NonceConsumed();

        // Verify oracle signature
        address signer = recoverSigner(q, sig);
        if (signer != oracleSigner) revert InvalidSignature();

        // Mark nonce consumed BEFORE external calls (re-entrancy belt & braces)
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
            defaulted: false
        });

        // Pull collateral from borrower → escrow
        IERC20(q.collateralToken).safeTransferFrom(
            q.borrower, address(this), q.collateralAmount
        );
        // Pull principal from lender → borrower
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

    /// @notice Borrower returns principal + interest, gets collateral back.
    /// @dev    Interest is straight-line accrual: principal × rate × time / year.
    ///         Caller must be the borrower (re-entrancy protected).
    function repay(bytes32 loanId) external nonReentrant {
        Loan storage loan = loans[loanId];
        if (loan.borrower == address(0)) revert LoanNotFound();
        if (loan.repaid || loan.defaulted) revert LoanAlreadyClosed();
        if (block.timestamp > loan.expiryTimestamp) revert LoanNotExpired();  // past expiry → default path

        uint256 timeElapsed = block.timestamp - loan.originationTimestamp;
        uint256 interest = (loan.principalAmount * loan.rateBps * timeElapsed)
                            / (365 days * 10_000);
        uint256 totalRepay = loan.principalAmount + interest;

        loan.repaid = true;  // CEI: state before external

        // Pull repayment from borrower → lender
        IERC20(loan.principalToken).safeTransferFrom(
            loan.borrower, loan.lender, totalRepay
        );
        // Release collateral back to borrower
        IERC20(loan.collateralToken).safeTransfer(loan.borrower, loan.collateralAmount);

        emit LoanRepaid(loanId, loan.principalAmount, interest, loan.collateralAmount);
    }

    // ─── Core: default ──────────────────────────────────────────────────────

    /// @notice Past expiry, lender claims collateral. Anyone can trigger.
    function defaultLoan(bytes32 loanId) external nonReentrant {
        Loan storage loan = loans[loanId];
        if (loan.borrower == address(0)) revert LoanNotFound();
        if (loan.repaid || loan.defaulted) revert LoanAlreadyClosed();
        if (block.timestamp <= loan.expiryTimestamp) revert LoanNotExpired();

        loan.defaulted = true;
        IERC20(loan.collateralToken).safeTransfer(loan.lender, loan.collateralAmount);

        emit LoanDefaulted(loanId, loan.collateralAmount);
    }

    // ─── View helpers ───────────────────────────────────────────────────────

    /// @notice Returns the current owed amount (principal + accrued interest) if
    ///         the borrower were to repay now. Useful for off-chain UIs.
    function currentOwed(bytes32 loanId) external view returns (uint256 owed) {
        Loan storage loan = loans[loanId];
        if (loan.borrower == address(0) || loan.repaid || loan.defaulted) return 0;
        uint256 elapsed = block.timestamp > loan.expiryTimestamp
            ? loan.expiryTimestamp - loan.originationTimestamp
            : block.timestamp - loan.originationTimestamp;
        uint256 interest = (loan.principalAmount * loan.rateBps * elapsed)
                            / (365 days * 10_000);
        return loan.principalAmount + interest;
    }

    function loanStatus(bytes32 loanId) external view returns (
        bool exists, bool repaid, bool defaulted, bool expired
    ) {
        Loan storage loan = loans[loanId];
        exists = loan.borrower != address(0);
        repaid = loan.repaid;
        defaulted = loan.defaulted;
        expired = exists && block.timestamp > loan.expiryTimestamp;
    }
}
