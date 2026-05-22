// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {InterAgentRepoV3, IChainlinkFeed} from "../src/InterAgentRepoV3.sol";
import {InterAgentRepoV2} from "../src/InterAgentRepoV2.sol";
import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";

contract MockERC20 is ERC20 {
    uint8 private immutable _dec;
    constructor(string memory n, string memory s, uint8 d) ERC20(n, s) { _dec = d; }
    function decimals() public view override returns (uint8) { return _dec; }
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

contract MockChainlinkFeed is IChainlinkFeed {
    int256 public price;
    uint256 public updatedAt;
    uint80 public roundId = 1;
    uint80 public answeredInRound = 1;

    constructor(int256 _initialPrice) {
        price = _initialPrice;
        updatedAt = block.timestamp;
    }
    function decimals() external pure returns (uint8) { return 8; }
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (roundId, price, updatedAt, updatedAt, answeredInRound);
    }
    function setPrice(int256 p) external { price = p; updatedAt = block.timestamp; roundId++; answeredInRound = roundId; }
    function setStalePrice(int256 p, uint256 staleAt) external { price = p; updatedAt = staleAt; }
    function setStaleRound(uint80 _round, uint80 _answeredInRound) external { roundId = _round; answeredInRound = _answeredInRound; }
}

contract InterAgentRepoV3Test is Test {
    InterAgentRepoV3 public v3;
    InterAgentRepoV2 public v2;  // for audit PoC comparison

    MockERC20 public usdc;
    MockERC20 public weth;
    MockChainlinkFeed public feed;

    address public insurancePool = address(0x1115);
    uint256 public oraclePk = 0xA11CE;
    address public oracle;
    address public lender = address(0xBEEF);
    address public borrower = address(0xCAFE);
    address public liquidator = address(0x71D);

    int256 public constant INITIAL_ETH_USD_E8 = 2080 * 1e8;

    function setUp() public {
        // Warp to a sane future timestamp so we can subtract hours
        vm.warp(1_000_000);

        oracle = vm.addr(oraclePk);
        usdc = new MockERC20("USDC", "USDC", 6);
        weth = new MockERC20("WETH", "WETH", 18);
        feed = new MockChainlinkFeed(INITIAL_ETH_USD_E8);

        v3 = new InterAgentRepoV3(
            oracle, address(feed), address(weth), address(usdc), insurancePool
        );
        v2 = new InterAgentRepoV2(
            oracle, address(feed), address(weth), address(usdc), insurancePool
        );

        usdc.mint(lender, 1000_000_000);
        weth.mint(borrower, 1 ether);

        vm.prank(lender); usdc.approve(address(v3), type(uint256).max);
        vm.prank(borrower); weth.approve(address(v3), type(uint256).max);
        vm.prank(borrower); usdc.approve(address(v3), type(uint256).max);

        vm.prank(lender); usdc.approve(address(v2), type(uint256).max);
        vm.prank(borrower); weth.approve(address(v2), type(uint256).max);
        vm.prank(borrower); usdc.approve(address(v2), type(uint256).max);
    }

    // ─── Quote builders for V2 / V3 ─────────────────────────────────────────

    function _buildV3Quote(bytes32 nonce, uint256 principal, uint256 collateral, uint256 expiry, uint256 rateBps)
        internal view returns (InterAgentRepoV3.Quote memory q)
    {
        q = InterAgentRepoV3.Quote({
            borrower: borrower, lender: lender,
            principalToken: address(usdc), principalAmount: principal,
            collateralToken: address(weth), collateralAmount: collateral,
            expiryTimestamp: expiry, rateBps: rateBps,
            nonce: nonce
        });
    }

    function _signV3(InterAgentRepoV3.Quote memory q, uint256 pk) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, v3.hashQuote(q));
        return abi.encodePacked(r, s, v);
    }

    function _buildV2Quote(bytes32 nonce, uint256 principal, uint256 collateral, uint256 expiry, uint256 rateBps)
        internal view returns (InterAgentRepoV2.Quote memory q)
    {
        q = InterAgentRepoV2.Quote({
            borrower: borrower, lender: lender,
            principalToken: address(usdc), principalAmount: principal,
            collateralToken: address(weth), collateralAmount: collateral,
            expiryTimestamp: expiry, rateBps: rateBps,
            nonce: nonce
        });
    }

    function _signV2(InterAgentRepoV2.Quote memory q, uint256 pk) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, v2.hashQuote(q));
        return abi.encodePacked(r, s, v);
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  PART A — Audit PoC against V2 (confirm bugs exist)
    // ─────────────────────────────────────────────────────────────────────────

    /// PoC #1 from audit — V2 accepts loan with LTV at/above liquidation threshold
    function test_AuditPoC_V2_acceptsAlreadyLiquidatableLoan() public {
        // $50 USDC against 0.025 WETH (~$52 at $2080) → LTV ~96% > 95% threshold
        bytes32 nonce = keccak256("audit-1");
        InterAgentRepoV2.Quote memory q = _buildV2Quote(
            nonce, 50_000_000, 0.025 ether, block.timestamp + 1 hours, 425
        );
        bytes memory sig = _signV2(q, oraclePk);

        // V2 accepts — this is the bug
        vm.prank(lender);
        v2.originate(q, sig);

        // After grace, anyone can liquidate immediately — borrower loses everything
        vm.warp(block.timestamp + 61);
        vm.prank(liquidator);
        v2.liquidate(nonce);  // succeeds — bug confirmed
    }

    /// PoC #2 — V2 accepts duration shorter than grace period
    function test_AuditPoC_V2_acceptsSubGracePeriodDuration() public {
        bytes32 nonce = keccak256("audit-2");
        // expiry = now+30s, which is less than 60s grace period
        InterAgentRepoV2.Quote memory q = _buildV2Quote(
            nonce, 30_000_000, 0.030 ether, block.timestamp + 30, 425
        );
        bytes memory sig = _signV2(q, oraclePk);

        vm.prank(lender);
        v2.originate(q, sig);  // V2 accepts — bug confirmed

        // Skip past expiry but within grace
        vm.warp(block.timestamp + 31);
        // liquidate blocked by grace
        // defaultLoan succeeds and gives lender 100% (bug #4 compounding)
        v2.defaultLoan(nonce);
        assertEq(weth.balanceOf(lender), 0.030 ether);  // 100% transfer — bug #4
    }

    /// PoC #3 — V2 accepts usurious rate
    function test_AuditPoC_V2_acceptsUsuriousRate() public {
        bytes32 nonce = keccak256("audit-3");
        // 1,000,000 bps = 10,000% APR — should be rejected
        InterAgentRepoV2.Quote memory q = _buildV2Quote(
            nonce, 30_000_000, 0.030 ether, block.timestamp + 1 hours, 1_000_000
        );
        bytes memory sig = _signV2(q, oraclePk);

        vm.prank(lender);
        v2.originate(q, sig);  // V2 accepts — bug #3 confirmed
    }

    /// PoC #4 — V2 default transfers 100% even when borrower is super-over-collateralized
    function test_AuditPoC_V2_defaultTransfersFullCollateral() public {
        bytes32 nonce = keccak256("audit-4");
        // $30 USDC against 0.040 WETH = $83.20 worth — 36% LTV, way over-collateralized
        InterAgentRepoV2.Quote memory q = _buildV2Quote(
            nonce, 30_000_000, 0.040 ether, block.timestamp + 1 hours, 425
        );
        bytes memory sig = _signV2(q, oraclePk);
        vm.prank(lender);
        v2.originate(q, sig);

        // Skip past expiry
        vm.warp(block.timestamp + 1 hours + 1);
        v2.defaultLoan(nonce);

        // Lender pockets 100% of 0.040 WETH = $83 — for a $30 debt
        assertEq(weth.balanceOf(lender), 0.040 ether);  // bug #4 confirmed
        // Borrower lost $53 of excess collateral
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  PART B — V3 fixes (same PoCs should REVERT)
    // ─────────────────────────────────────────────────────────────────────────

    /// V3 fix #1 — initial LTV at/above (threshold - buffer) reverts
    function test_V3_Fix1_rejectsAlreadyLiquidatableLoan() public {
        bytes32 nonce = keccak256("v3-1");
        // Same setup as audit PoC #1 — V3 should reject
        InterAgentRepoV3.Quote memory q = _buildV3Quote(
            nonce, 50_000_000, 0.025 ether, block.timestamp + 1 hours, 425
        );
        bytes memory sig = _signV3(q, oraclePk);

        vm.expectRevert(); // InitialLtvTooHigh
        vm.prank(lender);
        v3.originate(q, sig);
    }

    /// V3 fix #1 (positive) — LTV within safe range accepts
    function test_V3_Fix1_acceptsLoanInSafeRange() public {
        bytes32 nonce = keccak256("v3-1ok");
        // $50 against 0.030 WETH = $62.40 → LTV 80% < 93% buffer — OK
        InterAgentRepoV3.Quote memory q = _buildV3Quote(
            nonce, 50_000_000, 0.030 ether, block.timestamp + 1 hours, 425
        );
        bytes memory sig = _signV3(q, oraclePk);

        vm.prank(lender);
        bytes32 loanId = v3.originate(q, sig);
        assertEq(loanId, nonce);
    }

    /// V3 fix #2 — sub-grace duration reverts
    function test_V3_Fix2_rejectsSubGracePeriodDuration() public {
        bytes32 nonce = keccak256("v3-2");
        InterAgentRepoV3.Quote memory q = _buildV3Quote(
            nonce, 30_000_000, 0.040 ether, block.timestamp + 30, 425
        );
        bytes memory sig = _signV3(q, oraclePk);

        vm.expectRevert();  // LoanDurationTooShort
        vm.prank(lender);
        v3.originate(q, sig);
    }

    /// V3 fix #2 (positive) — duration just above min accepts
    function test_V3_Fix2_acceptsMinValidDuration() public {
        bytes32 nonce = keccak256("v3-2ok");
        // Min = 60 (grace) + 60 (buffer) = 120s; use 121s
        InterAgentRepoV3.Quote memory q = _buildV3Quote(
            nonce, 30_000_000, 0.040 ether, block.timestamp + 121, 425
        );
        bytes memory sig = _signV3(q, oraclePk);

        vm.prank(lender);
        v3.originate(q, sig);  // succeeds
    }

    /// V3 fix #3 — usurious rate reverts
    function test_V3_Fix3_rejectsUsuriousRate() public {
        bytes32 nonce = keccak256("v3-3");
        InterAgentRepoV3.Quote memory q = _buildV3Quote(
            nonce, 30_000_000, 0.040 ether, block.timestamp + 1 hours, 1_000_000
        );
        bytes memory sig = _signV3(q, oraclePk);

        vm.expectRevert();  // RateTooHigh
        vm.prank(lender);
        v3.originate(q, sig);
    }

    /// V3 fix #3 — rate at exact ceiling accepts (MAX_RATE_BPS = 100_000)
    function test_V3_Fix3_acceptsRateAtCeiling() public {
        bytes32 nonce = keccak256("v3-3ok");
        InterAgentRepoV3.Quote memory q = _buildV3Quote(
            nonce, 30_000_000, 0.040 ether, block.timestamp + 1 hours, 100_000
        );
        bytes memory sig = _signV3(q, oraclePk);

        vm.prank(lender);
        v3.originate(q, sig);
    }

    /// V3 fix #4 — default uses Aave-style fair split, NOT 100% to lender
    function test_V3_Fix4_defaultUsesFairSplit() public {
        bytes32 nonce = keccak256("v3-4");
        // Over-collateralized loan: $30 USDC against 0.040 WETH ($83.20)
        InterAgentRepoV3.Quote memory q = _buildV3Quote(
            nonce, 30_000_000, 0.040 ether, block.timestamp + 1 hours, 425
        );
        bytes memory sig = _signV3(q, oraclePk);
        vm.prank(lender);
        v3.originate(q, sig);

        // Capture pre-default balances
        uint256 borrowerWethBefore = weth.balanceOf(borrower);

        // Skip past expiry — anyone can default
        vm.warp(block.timestamp + 1 hours + 1);
        // Refresh feed (mock would otherwise be stale > 1h)
        feed.setPrice(INITIAL_ETH_USD_E8);

        vm.prank(liquidator);
        v3.defaultLoan(nonce);

        // Expected math:
        //  bounty       = 0.040 × 3% = 0.0012 WETH
        //  insurance    = 0.040 × 1% = 0.0004 WETH
        //  remaining    = 0.0384 WETH
        //  debt @expiry = 30 + (30 × 0.0425 × 1h/year) ≈ \$30.000146
        //  ≈ 30.000146 / 2080 ≈ 0.01442315 WETH (debt-equiv)
        //  lenderShare  = 0.01442315 WETH (< remaining 0.0384)
        //  borrowerRefund = 0.0384 - 0.01442315 ≈ 0.024 WETH

        assertEq(weth.balanceOf(liquidator), 0.0012 ether);  // 3% bounty
        assertEq(weth.balanceOf(insurancePool), 0.0004 ether); // 1% insurance

        // Lender gets debt-equivalent, NOT 100%
        uint256 lenderBal = weth.balanceOf(lender);
        assertLt(lenderBal, 0.02 ether);  // way less than 100% (was 0.040 in V2)
        assertGt(lenderBal, 0.014 ether); // but close to debt-equivalent

        // Borrower gets the excess refund — would be ZERO in V2!
        uint256 borrowerRefund = weth.balanceOf(borrower) - borrowerWethBefore;
        assertGt(borrowerRefund, 0.02 ether);
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  PART C — V1 happy paths still work
    // ─────────────────────────────────────────────────────────────────────────

    function test_V3_HappyPath_Originate_Then_Repay() public {
        bytes32 nonce = keccak256("v3-happy");
        InterAgentRepoV3.Quote memory q = _buildV3Quote(
            nonce, 30_000_000, 0.030 ether, block.timestamp + 1 hours, 425
        );
        bytes memory sig = _signV3(q, oraclePk);

        vm.prank(lender);
        bytes32 loanId = v3.originate(q, sig);
        assertEq(usdc.balanceOf(borrower), 30_000_000);

        vm.warp(block.timestamp + 30 minutes);
        uint256 owed = v3.currentOwed(loanId);
        usdc.mint(borrower, owed);

        vm.prank(borrower);
        v3.repay(loanId);

        assertEq(weth.balanceOf(borrower), 1 ether);  // collateral returned
    }

    function test_V3_LiquidatePath() public {
        bytes32 nonce = keccak256("v3-liq");
        // Origination LTV ~80%, then price drops → LTV climbs above 95%
        InterAgentRepoV3.Quote memory q = _buildV3Quote(
            nonce, 50_000_000, 0.030 ether, block.timestamp + 1 hours, 425
        );
        bytes memory sig = _signV3(q, oraclePk);
        vm.prank(lender);
        v3.originate(q, sig);

        // Skip grace, drop ETH price to push LTV > 95%
        // LTV ≥ 95% iff price ≤ $50/(0.03 × 0.95) = $1754
        vm.warp(block.timestamp + 61);
        feed.setPrice(1700 * 1e8);  // ETH dropped to $1700

        vm.prank(liquidator);
        v3.liquidate(nonce);

        // Same splits as V2 liquidate
        assertEq(weth.balanceOf(liquidator), 0.0009 ether);  // 3%
        assertEq(weth.balanceOf(insurancePool), 0.0003 ether); // 1%
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  PART D — Pausable (V3 new)
    // ─────────────────────────────────────────────────────────────────────────

    function test_V3_Pausable_BlocksOriginate() public {
        v3.emergencyPause();

        bytes32 nonce = keccak256("v3-pause");
        InterAgentRepoV3.Quote memory q = _buildV3Quote(
            nonce, 30_000_000, 0.030 ether, block.timestamp + 1 hours, 425
        );
        bytes memory sig = _signV3(q, oraclePk);

        vm.expectRevert();  // EnforcedPause
        vm.prank(lender);
        v3.originate(q, sig);
    }

    function test_V3_Pausable_UnpauseRestoresFlow() public {
        v3.emergencyPause();
        v3.emergencyUnpause();

        bytes32 nonce = keccak256("v3-unpause");
        InterAgentRepoV3.Quote memory q = _buildV3Quote(
            nonce, 30_000_000, 0.030 ether, block.timestamp + 1 hours, 425
        );
        bytes memory sig = _signV3(q, oraclePk);
        vm.prank(lender);
        v3.originate(q, sig);  // succeeds
    }
}
