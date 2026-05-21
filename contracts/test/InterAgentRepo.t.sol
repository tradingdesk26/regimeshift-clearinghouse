// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {InterAgentRepo} from "../src/InterAgentRepo.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";

contract MockERC20 is ERC20 {
    uint8 private immutable _dec;
    constructor(string memory n, string memory s, uint8 d) ERC20(n, s) { _dec = d; }
    function decimals() public view override returns (uint8) { return _dec; }
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

contract InterAgentRepoTest is Test {
    InterAgentRepo public repo;
    MockERC20 public usdc;
    MockERC20 public weth;

    address public owner = address(this);
    uint256 public oraclePk = 0xA11CE; // arbitrary test private key
    address public oracle;

    address public lender = address(0xBEEF);
    address public borrower = address(0xCAFE);

    function setUp() public {
        oracle = vm.addr(oraclePk);
        repo = new InterAgentRepo(oracle);

        usdc = new MockERC20("USD Coin", "USDC", 6);
        weth = new MockERC20("Wrapped Ether", "WETH", 18);

        // Mint balances
        usdc.mint(lender, 1000_000_000);    // 1000 USDC
        weth.mint(borrower, 1 ether);       // 1 WETH

        // Pre-approve repo from both sides
        vm.prank(lender);
        usdc.approve(address(repo), type(uint256).max);
        vm.prank(borrower);
        weth.approve(address(repo), type(uint256).max);
        // Borrower needs USDC approval too for repayment
        vm.prank(borrower);
        usdc.approve(address(repo), type(uint256).max);
    }

    // ─────────────────────────────────────────────────────────────────────
    //  Test helpers
    // ─────────────────────────────────────────────────────────────────────

    function _buildQuote(bytes32 nonce, uint256 principal, uint256 collateral, uint256 expiry, uint256 rateBps)
        internal view returns (InterAgentRepo.Quote memory q)
    {
        q = InterAgentRepo.Quote({
            borrower: borrower,
            lender: lender,
            principalToken: address(usdc),
            principalAmount: principal,
            collateralToken: address(weth),
            collateralAmount: collateral,
            expiryTimestamp: expiry,
            rateBps: rateBps,
            nonce: nonce
        });
    }

    function _sign(InterAgentRepo.Quote memory q, uint256 pk) internal view returns (bytes memory) {
        bytes32 digest = repo.hashQuote(q);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    // ─────────────────────────────────────────────────────────────────────
    //  Happy path: originate → repay
    // ─────────────────────────────────────────────────────────────────────

    function test_HappyPath_Originate_Then_Repay() public {
        uint256 principal = 50_000_000;        // 50 USDC
        uint256 collateral = 0.025 ether;      // 0.025 WETH (LTV ~96% at $2080/ETH)
        uint256 expiry = block.timestamp + 1 hours;
        uint256 rateBps = 425;                 // 4.25%
        bytes32 nonce = keccak256("loan-1");

        InterAgentRepo.Quote memory q = _buildQuote(nonce, principal, collateral, expiry, rateBps);
        bytes memory sig = _sign(q, oraclePk);

        // Pre-state
        assertEq(usdc.balanceOf(lender), 1000_000_000);
        assertEq(usdc.balanceOf(borrower), 0);
        assertEq(weth.balanceOf(borrower), 1 ether);

        // Originate (lender triggers)
        vm.prank(lender);
        bytes32 loanId = repo.originate(q, sig);

        assertEq(loanId, nonce);
        // Borrower received principal
        assertEq(usdc.balanceOf(borrower), principal);
        // Lender drained
        assertEq(usdc.balanceOf(lender), 1000_000_000 - principal);
        // Collateral locked in escrow
        assertEq(weth.balanceOf(address(repo)), collateral);
        assertEq(weth.balanceOf(borrower), 1 ether - collateral);

        // Skip 30 minutes
        vm.warp(block.timestamp + 30 minutes);

        // Borrower repays
        uint256 owed = repo.currentOwed(loanId);
        assertGt(owed, principal);  // some interest accrued
        // give borrower enough USDC to repay (mint more to cover interest)
        usdc.mint(borrower, owed);

        vm.prank(borrower);
        repo.repay(loanId);

        // Lender got principal + interest
        assertEq(usdc.balanceOf(lender), 1000_000_000 - principal + owed);
        // Borrower got collateral back
        assertEq(weth.balanceOf(borrower), 1 ether);
        // Escrow empty
        assertEq(weth.balanceOf(address(repo)), 0);

        (bool exists, bool repaid, bool defaulted, bool expired) = repo.loanStatus(loanId);
        assertTrue(exists);
        assertTrue(repaid);
        assertFalse(defaulted);
    }

    // ─────────────────────────────────────────────────────────────────────
    //  Default path: borrower doesn't repay
    // ─────────────────────────────────────────────────────────────────────

    function test_DefaultPath_LenderClaimsCollateral() public {
        uint256 principal = 30_000_000;
        uint256 collateral = 0.02 ether;
        uint256 expiry = block.timestamp + 1 hours;
        bytes32 nonce = keccak256("loan-2");

        InterAgentRepo.Quote memory q = _buildQuote(nonce, principal, collateral, expiry, 500);
        bytes memory sig = _sign(q, oraclePk);

        vm.prank(lender);
        bytes32 loanId = repo.originate(q, sig);

        // Time passes past expiry, no repayment
        vm.warp(expiry + 1);

        // Anyone can trigger default (here: lender does it)
        vm.prank(lender);
        repo.defaultLoan(loanId);

        // Lender now holds the collateral
        assertEq(weth.balanceOf(lender), collateral);
        // Borrower still has the principal (their gain, kind of — but lost collateral)
        assertEq(usdc.balanceOf(borrower), principal);

        (, bool repaid, bool defaulted,) = repo.loanStatus(loanId);
        assertFalse(repaid);
        assertTrue(defaulted);
    }

    // ─────────────────────────────────────────────────────────────────────
    //  Revert: invalid signature
    // ─────────────────────────────────────────────────────────────────────

    function test_Revert_InvalidSignature() public {
        bytes32 nonce = keccak256("loan-bad-sig");
        InterAgentRepo.Quote memory q = _buildQuote(nonce, 10_000_000, 0.01 ether, block.timestamp + 1 hours, 400);
        // Sign with the WRONG key
        uint256 wrongPk = 0xBADBAD;
        bytes memory sig = _sign(q, wrongPk);

        vm.expectRevert(InterAgentRepo.InvalidSignature.selector);
        repo.originate(q, sig);
    }

    // ─────────────────────────────────────────────────────────────────────
    //  Revert: expired quote
    // ─────────────────────────────────────────────────────────────────────

    function test_Revert_ExpiredQuote() public {
        bytes32 nonce = keccak256("loan-expired");
        InterAgentRepo.Quote memory q = _buildQuote(nonce, 10_000_000, 0.01 ether, block.timestamp - 1, 400);
        bytes memory sig = _sign(q, oraclePk);

        vm.expectRevert(InterAgentRepo.QuoteExpired.selector);
        repo.originate(q, sig);
    }

    // ─────────────────────────────────────────────────────────────────────
    //  Revert: nonce replay
    // ─────────────────────────────────────────────────────────────────────

    function test_Revert_NonceReplay() public {
        bytes32 nonce = keccak256("loan-replay");
        InterAgentRepo.Quote memory q = _buildQuote(nonce, 10_000_000, 0.01 ether, block.timestamp + 1 hours, 400);
        bytes memory sig = _sign(q, oraclePk);

        // First call succeeds
        repo.originate(q, sig);

        // Second call with same nonce should revert
        vm.expectRevert(InterAgentRepo.NonceConsumed.selector);
        repo.originate(q, sig);
    }

    // ─────────────────────────────────────────────────────────────────────
    //  Revert: principal cap (MVP safety)
    // ─────────────────────────────────────────────────────────────────────

    function test_Revert_PrincipalCapExceeded() public {
        bytes32 nonce = keccak256("loan-too-big");
        InterAgentRepo.Quote memory q = _buildQuote(nonce, 60_000_000, 0.05 ether, block.timestamp + 1 hours, 400);
        bytes memory sig = _sign(q, oraclePk);
        usdc.mint(lender, 60_000_000);

        vm.expectRevert(InterAgentRepo.PrincipalCapExceeded.selector);
        repo.originate(q, sig);
    }

    // ─────────────────────────────────────────────────────────────────────
    //  Owner rotates oracle signer
    // ─────────────────────────────────────────────────────────────────────

    function test_OracleSignerRotation() public {
        address newSigner = address(0xDEAD);

        repo.setOracleSigner(newSigner);
        assertEq(repo.oracleSigner(), newSigner);

        // Old key signatures should now fail
        bytes32 nonce = keccak256("loan-after-rotation");
        InterAgentRepo.Quote memory q = _buildQuote(nonce, 10_000_000, 0.01 ether, block.timestamp + 1 hours, 400);
        bytes memory sig = _sign(q, oraclePk);  // still signed by OLD key

        vm.expectRevert(InterAgentRepo.InvalidSignature.selector);
        repo.originate(q, sig);
    }

    // ─────────────────────────────────────────────────────────────────────
    //  Cannot repay past expiry (must default)
    // ─────────────────────────────────────────────────────────────────────

    function test_Revert_RepayAfterExpiry() public {
        bytes32 nonce = keccak256("loan-late-repay");
        uint256 expiry = block.timestamp + 1 hours;
        InterAgentRepo.Quote memory q = _buildQuote(nonce, 10_000_000, 0.01 ether, expiry, 400);
        bytes memory sig = _sign(q, oraclePk);

        repo.originate(q, sig);
        vm.warp(expiry + 1);

        usdc.mint(borrower, 100_000_000);
        vm.prank(borrower);
        vm.expectRevert(InterAgentRepo.LoanNotExpired.selector);  // path-named "NotExpired" but here it means "past expiry"
        repo.repay(nonce);
    }

    // ─────────────────────────────────────────────────────────────────────
    //  Cannot default before expiry
    // ─────────────────────────────────────────────────────────────────────

    function test_Revert_DefaultBeforeExpiry() public {
        bytes32 nonce = keccak256("loan-early-default");
        uint256 expiry = block.timestamp + 1 hours;
        InterAgentRepo.Quote memory q = _buildQuote(nonce, 10_000_000, 0.01 ether, expiry, 400);
        bytes memory sig = _sign(q, oraclePk);

        repo.originate(q, sig);

        vm.expectRevert(InterAgentRepo.LoanNotExpired.selector);
        repo.defaultLoan(nonce);
    }

    // ─────────────────────────────────────────────────────────────────────
    //  Repay/default once — closed loan stays closed
    // ─────────────────────────────────────────────────────────────────────

    function test_Revert_DoubleRepay() public {
        bytes32 nonce = keccak256("loan-double-repay");
        InterAgentRepo.Quote memory q = _buildQuote(nonce, 10_000_000, 0.01 ether, block.timestamp + 1 hours, 400);
        bytes memory sig = _sign(q, oraclePk);

        repo.originate(q, sig);

        usdc.mint(borrower, 100_000_000);
        vm.prank(borrower);
        repo.repay(nonce);

        vm.prank(borrower);
        vm.expectRevert(InterAgentRepo.LoanAlreadyClosed.selector);
        repo.repay(nonce);
    }
}
