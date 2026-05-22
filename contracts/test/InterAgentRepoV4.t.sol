// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {InterAgentRepoV4, IChainlinkFeed} from "../src/InterAgentRepoV4.sol";
import {InterAgentRepoV3} from "../src/InterAgentRepoV3.sol";
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
    constructor(int256 _initialPrice) { price = _initialPrice; updatedAt = block.timestamp; }
    function decimals() external pure returns (uint8) { return 8; }
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (roundId, price, updatedAt, updatedAt, answeredInRound);
    }
    function setPrice(int256 p) external { price = p; updatedAt = block.timestamp; roundId++; answeredInRound = roundId; }
}

contract InterAgentRepoV4Test is Test {
    InterAgentRepoV4 public v4;
    InterAgentRepoV3 public v3;  // for R2 PoC comparison

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
        vm.warp(1_000_000);
        oracle = vm.addr(oraclePk);
        usdc = new MockERC20("USDC", "USDC", 6);
        weth = new MockERC20("WETH", "WETH", 18);
        feed = new MockChainlinkFeed(INITIAL_ETH_USD_E8);

        v4 = new InterAgentRepoV4(
            oracle, address(feed), address(weth), address(usdc), insurancePool
        );
        v3 = new InterAgentRepoV3(
            oracle, address(feed), address(weth), address(usdc), insurancePool
        );

        usdc.mint(lender, 1000_000_000);
        weth.mint(borrower, 1 ether);

        vm.prank(lender); usdc.approve(address(v4), type(uint256).max);
        vm.prank(borrower); weth.approve(address(v4), type(uint256).max);
        vm.prank(borrower); usdc.approve(address(v4), type(uint256).max);

        vm.prank(lender); usdc.approve(address(v3), type(uint256).max);
        vm.prank(borrower); weth.approve(address(v3), type(uint256).max);
        vm.prank(borrower); usdc.approve(address(v3), type(uint256).max);
    }

    function _buildV4Quote(bytes32 nonce, uint256 principal, uint256 collateral, uint256 expiry, uint256 rateBps)
        internal view returns (InterAgentRepoV4.Quote memory q)
    {
        q = InterAgentRepoV4.Quote({
            borrower: borrower, lender: lender,
            principalToken: address(usdc), principalAmount: principal,
            collateralToken: address(weth), collateralAmount: collateral,
            expiryTimestamp: expiry, rateBps: rateBps,
            nonce: nonce
        });
    }
    function _signV4(InterAgentRepoV4.Quote memory q, uint256 pk) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, v4.hashQuote(q));
        return abi.encodePacked(r, s, v);
    }

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

    // ─────────────────────────────────────────────────────────────────────────
    //  R2-#2 PoC — confirm bug exists on V3 (deployed bytecode at 0xFfca...2945)
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Demonstrates the pause-to-default DOS on V3:
    ///  1. Borrower opens loan (over-collateralized)
    ///  2. Owner pauses before expiry
    ///  3. Borrower can't repay (whenNotPaused blocks)
    ///  4. Expiry passes
    ///  5. Owner unpauses
    ///  6. Repay reverts with LoanNotExpired
    ///  7. Anyone calls defaultLoan → borrower loses 4% to bounty + insurance
    function test_AuditR2PoC_V3_pauseBlocksRepay_forcesDefault() public {
        bytes32 nonce = keccak256("r2-2-poc");
        // Over-collateralized: $30 USDC against 0.040 WETH ($83.20)
        // Duration: just over min (200s) so we can pause/unpause around expiry
        uint256 expiry = block.timestamp + 200;
        InterAgentRepoV3.Quote memory q = _buildV3Quote(nonce, 30_000_000, 0.040 ether, expiry, 425);
        bytes memory sig = _signV3(q, oraclePk);

        vm.prank(lender);
        v3.originate(q, sig);

        uint256 borrowerWethBefore = weth.balanceOf(borrower);

        // Step into pause window — 30s before expiry
        vm.warp(expiry - 30);
        v3.emergencyPause();  // owner pauses

        // Borrower can't repay
        usdc.mint(borrower, 100_000_000);
        vm.prank(borrower);
        vm.expectRevert();  // EnforcedPause
        v3.repay(nonce);

        // Expiry passes
        vm.warp(expiry + 1);
        // Unpause
        v3.emergencyUnpause();

        // Now repay fails with LoanNotExpired (past expiry)
        vm.prank(borrower);
        vm.expectRevert(InterAgentRepoV3.LoanNotExpired.selector);
        v3.repay(nonce);

        // Refresh Chainlink so defaultLoan can succeed
        feed.setPrice(INITIAL_ETH_USD_E8);

        // Someone calls defaultLoan — borrower loses 4% to carve-outs
        vm.prank(liquidator);
        v3.defaultLoan(nonce);

        // Borrower kept SOME refund (over-collateralized) but lost 4% to bounty + insurance
        // 4% of 0.040 = 0.0016 WETH lost compared to normal repay
        uint256 borrowerRefund = weth.balanceOf(borrower) - borrowerWethBefore;
        // Without pause attack, borrower would have gotten 0.040 ether back (full collateral)
        // With pause attack, borrower gets ~0.040 - bounty (3% = 0.0012) - insurance (1% = 0.0004)
        //                                       = 0.040 - 0.0016 - debt-equiv ≈ much less
        assertLt(borrowerRefund, 0.040 ether);  // BUG: borrower lost what they should have kept
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  V4 fix — repay allowed even during pause
    // ─────────────────────────────────────────────────────────────────────────

    function test_V4_Fix_repayAllowedDuringPause() public {
        bytes32 nonce = keccak256("v4-r2-fix");
        InterAgentRepoV4.Quote memory q = _buildV4Quote(
            nonce, 30_000_000, 0.040 ether, block.timestamp + 200, 425
        );
        bytes memory sig = _signV4(q, oraclePk);

        vm.prank(lender);
        v4.originate(q, sig);

        // Pause
        v4.emergencyPause();

        // Borrower can repay anyway
        vm.warp(block.timestamp + 30);
        usdc.mint(borrower, 100_000_000);
        vm.prank(borrower);
        v4.repay(nonce);  // ✓ succeeds — V4 fix

        // Borrower keeps full collateral (no carve-outs paid)
        assertEq(weth.balanceOf(borrower), 1 ether);
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  V4 — pause still blocks ENTRY (originate)
    // ─────────────────────────────────────────────────────────────────────────

    function test_V4_pauseStillBlocksOriginate() public {
        v4.emergencyPause();

        bytes32 nonce = keccak256("v4-pause-orig");
        InterAgentRepoV4.Quote memory q = _buildV4Quote(
            nonce, 30_000_000, 0.040 ether, block.timestamp + 1 hours, 425
        );
        bytes memory sig = _signV4(q, oraclePk);

        vm.expectRevert();  // EnforcedPause
        vm.prank(lender);
        v4.originate(q, sig);
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  V4 — pause still blocks liquidate + defaultLoan (entry to settlement)
    // ─────────────────────────────────────────────────────────────────────────

    function test_V4_pauseStillBlocksLiquidate() public {
        bytes32 nonce = keccak256("v4-pause-liq");
        InterAgentRepoV4.Quote memory q = _buildV4Quote(
            nonce, 50_000_000, 0.030 ether, block.timestamp + 1 hours, 425
        );
        bytes memory sig = _signV4(q, oraclePk);
        vm.prank(lender);
        v4.originate(q, sig);

        vm.warp(block.timestamp + 61);
        feed.setPrice(1700 * 1e8);  // drop price, LTV climbs

        v4.emergencyPause();

        vm.expectRevert();  // EnforcedPause
        vm.prank(liquidator);
        v4.liquidate(nonce);
    }

    function test_V4_pauseStillBlocksDefault() public {
        bytes32 nonce = keccak256("v4-pause-default");
        InterAgentRepoV4.Quote memory q = _buildV4Quote(
            nonce, 30_000_000, 0.040 ether, block.timestamp + 200, 425
        );
        bytes memory sig = _signV4(q, oraclePk);
        vm.prank(lender);
        v4.originate(q, sig);

        vm.warp(block.timestamp + 250);
        feed.setPrice(INITIAL_ETH_USD_E8);
        v4.emergencyPause();

        vm.expectRevert();  // EnforcedPause
        v4.defaultLoan(nonce);
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  V4 — all V3 happy paths still work
    // ─────────────────────────────────────────────────────────────────────────

    function test_V4_HappyPath_Originate_Then_Repay() public {
        bytes32 nonce = keccak256("v4-happy");
        InterAgentRepoV4.Quote memory q = _buildV4Quote(
            nonce, 30_000_000, 0.030 ether, block.timestamp + 1 hours, 425
        );
        bytes memory sig = _signV4(q, oraclePk);

        vm.prank(lender);
        v4.originate(q, sig);

        vm.warp(block.timestamp + 30 minutes);
        uint256 owed = v4.currentOwed(nonce);
        usdc.mint(borrower, owed);
        vm.prank(borrower);
        v4.repay(nonce);

        assertEq(weth.balanceOf(borrower), 1 ether);
    }

    function test_V4_DefaultPath_FairSplit() public {
        bytes32 nonce = keccak256("v4-default");
        InterAgentRepoV4.Quote memory q = _buildV4Quote(
            nonce, 30_000_000, 0.040 ether, block.timestamp + 1 hours, 425
        );
        bytes memory sig = _signV4(q, oraclePk);
        vm.prank(lender);
        v4.originate(q, sig);

        vm.warp(block.timestamp + 1 hours + 1);
        feed.setPrice(INITIAL_ETH_USD_E8);  // refresh feed

        uint256 borrowerWethBefore = weth.balanceOf(borrower);
        vm.prank(liquidator);
        v4.defaultLoan(nonce);

        // Borrower receives excess refund (V3's fair split inherited)
        uint256 borrowerRefund = weth.balanceOf(borrower) - borrowerWethBefore;
        assertGt(borrowerRefund, 0.02 ether);
    }

    function test_V4_RejectsAlreadyLiquidatableLoan() public {
        // V3's audit-1 fix #1 inherited — LTV ≥ 93% rejected
        bytes32 nonce = keccak256("v4-r1-ltv");
        InterAgentRepoV4.Quote memory q = _buildV4Quote(
            nonce, 50_000_000, 0.025 ether, block.timestamp + 1 hours, 425
        );
        bytes memory sig = _signV4(q, oraclePk);

        vm.expectRevert();
        vm.prank(lender);
        v4.originate(q, sig);
    }
}
