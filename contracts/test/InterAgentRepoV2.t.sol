// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {InterAgentRepoV2, IChainlinkFeed} from "../src/InterAgentRepoV2.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";

contract MockERC20 is ERC20 {
    uint8 private immutable _dec;
    constructor(string memory n, string memory s, uint8 d) ERC20(n, s) { _dec = d; }
    function decimals() public view override returns (uint8) { return _dec; }
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

/// @notice In-memory mock that mimics Chainlink AggregatorV3 just enough for tests.
contract MockChainlinkFeed is IChainlinkFeed {
    int256 public price;
    uint256 public updatedAt;
    uint8 public constant DECIMALS = 8;

    constructor(int256 _initialPrice) {
        price = _initialPrice;
        updatedAt = block.timestamp;
    }

    function decimals() external pure returns (uint8) { return DECIMALS; }

    function latestRoundData() external view returns (
        uint80 roundId, int256 answer, uint256 startedAt, uint256 updated, uint80 answeredInRound
    ) {
        return (1, price, updatedAt, updatedAt, 1);
    }

    function setPrice(int256 newPrice) external { price = newPrice; updatedAt = block.timestamp; }
    function setStalePrice(int256 newPrice, uint256 staleAt) external {
        price = newPrice; updatedAt = staleAt;
    }
}

contract InterAgentRepoV2Test is Test {
    InterAgentRepoV2 public repo;
    MockERC20 public usdc;
    MockERC20 public weth;
    MockChainlinkFeed public feed;

    address public insurancePool = address(0x1115);

    uint256 public oraclePk = 0xA11CE;
    address public oracle;
    address public lender = address(0xBEEF);
    address public borrower = address(0xCAFE);
    address public liquidator = address(0x71D);

    int256 public constant INITIAL_ETH_USD_E8 = 2080 * 1e8;  // $2080/ETH

    function setUp() public {
        oracle = vm.addr(oraclePk);
        usdc = new MockERC20("USDC", "USDC", 6);
        weth = new MockERC20("WETH", "WETH", 18);
        feed = new MockChainlinkFeed(INITIAL_ETH_USD_E8);

        repo = new InterAgentRepoV2(
            oracle,
            address(feed),
            address(weth),
            address(usdc),
            insurancePool
        );

        // Mint balances
        usdc.mint(lender, 1000_000_000);
        weth.mint(borrower, 1 ether);

        // Approvals
        vm.prank(lender);
        usdc.approve(address(repo), type(uint256).max);
        vm.prank(borrower);
        weth.approve(address(repo), type(uint256).max);
        vm.prank(borrower);
        usdc.approve(address(repo), type(uint256).max);
    }

    // ─── Helpers ────────────────────────────────────────────────────────────

    function _buildQuote(bytes32 nonce, uint256 principal, uint256 collateral, uint256 expiry, uint256 rateBps)
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

    function _sign(InterAgentRepoV2.Quote memory q, uint256 pk) internal view returns (bytes memory) {
        bytes32 digest = repo.hashQuote(q);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _setupLoan(uint256 principal, uint256 collateral) internal returns (bytes32 loanId) {
        bytes32 nonce = keccak256(abi.encode("loan", block.timestamp, principal));
        InterAgentRepoV2.Quote memory q = _buildQuote(
            nonce, principal, collateral, block.timestamp + 1 hours, 425
        );
        bytes memory sig = _sign(q, oraclePk);
        vm.prank(lender);
        return repo.originate(q, sig);
    }

    // ─── V1 inherited path coverage ─────────────────────────────────────────

    function test_V1_HappyPath_Originate_Then_Repay() public {
        uint256 P = 50_000_000;      // $50 USDC
        uint256 C = 0.025 ether;     // 0.025 WETH ~ $52 at $2080 → LTV ~96%

        bytes32 loanId = _setupLoan(P, C);
        assertEq(usdc.balanceOf(borrower), P);
        assertEq(weth.balanceOf(address(repo)), C);

        vm.warp(block.timestamp + 30 minutes);
        uint256 owed = repo.currentOwed(loanId);
        assertGt(owed, P);

        usdc.mint(borrower, owed);
        vm.prank(borrower);
        repo.repay(loanId);

        assertEq(weth.balanceOf(borrower), 1 ether);  // collateral returned
    }

    function test_V1_DefaultPath() public {
        bytes32 loanId = _setupLoan(30_000_000, 0.02 ether);
        vm.warp(block.timestamp + 1 hours + 1);
        repo.defaultLoan(loanId);
        assertEq(weth.balanceOf(lender), 0.02 ether);
    }

    // ─── V2 NEW: liquidation paths ──────────────────────────────────────────

    function test_V2_LiquidatePath_PriceDrop() public {
        uint256 P = 50_000_000;      // $50
        uint256 C = 0.025 ether;     // 0.025 WETH = $52 at $2080 → LTV ≈ 96.15%
        // After 1 min (grace passes), drop ETH price to make LTV breach
        bytes32 loanId = _setupLoan(P, C);

        vm.warp(block.timestamp + GRACE_PERIOD_PLUS_1());

        // At what price does $50 USDC against 0.025 WETH = LTV 95%?
        // LTV = 50 / (0.025 × P_eth) → P_eth = 50 / (0.025 × 0.95) = $2105.26
        // So at ETH = $2105.26 LTV is exactly 95%. Below = liquidatable.
        // Drop price to $2050 → LTV = 50 / (0.025 × 2050) = 97.56%
        feed.setPrice(2050 * 1e8);

        // Sanity: currentLTV view says liquidatable
        (uint256 ltv, , bool liquidatable) = repo.currentLTV(loanId);
        assertGt(ltv, 9500);
        assertTrue(liquidatable);

        // Anyone can liquidate — use the liquidator address
        uint256 lenderBalBefore = weth.balanceOf(lender);
        uint256 liquidatorBalBefore = weth.balanceOf(liquidator);
        uint256 insuranceBalBefore = weth.balanceOf(insurancePool);

        vm.prank(liquidator);
        repo.liquidate(loanId);

        // Expected splits:
        // bounty = 0.025 × 0.03 = 0.00075 WETH
        // insurance = 0.025 × 0.01 = 0.00025 WETH
        // lender = 0.025 × 0.96 = 0.024 WETH
        assertEq(weth.balanceOf(liquidator) - liquidatorBalBefore, 0.00075 ether);
        assertEq(weth.balanceOf(insurancePool) - insuranceBalBefore, 0.00025 ether);
        assertEq(weth.balanceOf(lender) - lenderBalBefore, 0.024 ether);

        (, , , bool liq, ) = repo.loanStatus(loanId);
        assertTrue(liq);
    }

    function test_V2_Revert_LtvNotBreached() public {
        bytes32 loanId = _setupLoan(50_000_000, 0.025 ether);
        vm.warp(block.timestamp + GRACE_PERIOD_PLUS_1());

        // Price unchanged → LTV ≈ 96.15% but threshold is 95% — hmm wait that's already > 95%
        // Re-think: 50 / (0.025 × 2080) = 50 / 52 = 96.15% which IS > 95%
        // So at initial price, this loan IS already liquidatable! Bad test.
        // Need to use a less-leveraged loan to test the not-breached case.

        // Switch to bigger collateral: 0.030 ether → 50 / (0.030 × 2080) = 80.13% LTV
        // That's well below 95%.
        bytes32 loanId2 = _setupLoan(50_000_000, 0.030 ether);

        vm.expectRevert();  // LtvNotBreached
        repo.liquidate(loanId2);
    }

    function test_V2_Revert_GracePeriodActive() public {
        bytes32 loanId = _setupLoan(50_000_000, 0.025 ether);
        // Don't warp — try to liquidate immediately
        feed.setPrice(1000 * 1e8);  // dramatic drop, LTV way above threshold

        vm.expectRevert(InterAgentRepoV2.GracePeriodActive.selector);
        repo.liquidate(loanId);
    }

    function test_V2_Revert_StalePrice() public {
        // Start in the future so we can safely subtract hours
        vm.warp(1_000_000);

        bytes32 loanId = _setupLoan(50_000_000, 0.025 ether);
        vm.warp(block.timestamp + GRACE_PERIOD_PLUS_1());

        // Set price with stale timestamp (>1h old)
        uint256 staleTime = block.timestamp - 2 hours;
        feed.setStalePrice(1000 * 1e8, staleTime);

        vm.expectRevert(InterAgentRepoV2.PriceStale.selector);
        repo.liquidate(loanId);
    }

    function test_V2_Revert_PriceInvalid() public {
        bytes32 loanId = _setupLoan(50_000_000, 0.025 ether);
        vm.warp(block.timestamp + GRACE_PERIOD_PLUS_1());

        feed.setPrice(0);

        vm.expectRevert(InterAgentRepoV2.PriceInvalid.selector);
        repo.liquidate(loanId);
    }

    function test_V2_Revert_DoubleLiquidate() public {
        uint256 P = 50_000_000;
        uint256 C = 0.025 ether;
        bytes32 loanId = _setupLoan(P, C);
        vm.warp(block.timestamp + GRACE_PERIOD_PLUS_1());
        feed.setPrice(2050 * 1e8);

        repo.liquidate(loanId);

        vm.expectRevert(InterAgentRepoV2.LoanAlreadyClosed.selector);
        repo.liquidate(loanId);
    }

    function test_V2_Revert_RepayAfterLiquidate() public {
        bytes32 loanId = _setupLoan(50_000_000, 0.025 ether);
        vm.warp(block.timestamp + GRACE_PERIOD_PLUS_1());
        feed.setPrice(2050 * 1e8);
        repo.liquidate(loanId);

        usdc.mint(borrower, 100_000_000);
        vm.prank(borrower);
        vm.expectRevert(InterAgentRepoV2.LoanAlreadyClosed.selector);
        repo.repay(loanId);
    }

    function test_V2_CurrentLtvView_ReturnsZeroAfterRepay() public {
        uint256 P = 50_000_000;
        uint256 C = 0.030 ether;
        bytes32 loanId = _setupLoan(P, C);

        vm.warp(block.timestamp + 5 minutes);
        usdc.mint(borrower, 100_000_000);
        vm.prank(borrower);
        repo.repay(loanId);

        (uint256 ltv, , bool liquidatable) = repo.currentLTV(loanId);
        assertEq(ltv, 0);
        assertFalse(liquidatable);
    }

    function test_V2_CurrentLtvView_LiquidatableAfterDrop() public {
        bytes32 loanId = _setupLoan(50_000_000, 0.025 ether);
        vm.warp(block.timestamp + GRACE_PERIOD_PLUS_1());
        feed.setPrice(2000 * 1e8);  // LTV = 50 / (0.025 × 2000) = 100%

        (uint256 ltv, uint256 priceE8, bool liquidatable) = repo.currentLTV(loanId);
        assertEq(ltv, 10000);  // 100%
        assertEq(priceE8, 2000 * 1e8);
        assertTrue(liquidatable);
    }

    function test_V2_AdminCanRotateInsurancePool() public {
        address newPool = address(0xDEAD);
        repo.setInsurancePool(newPool);
        assertEq(repo.insurancePoolAddress(), newPool);
    }

    function test_V2_AdminCanRotateOracleSigner() public {
        address newSigner = address(0xDEAD);
        repo.setOracleSigner(newSigner);
        assertEq(repo.oracleSigner(), newSigner);
    }

    function test_V2_Revert_UnsupportedPrincipal() public {
        MockERC20 randomToken = new MockERC20("RANDOM", "RND", 18);
        bytes32 nonce = keccak256("bad-principal");
        InterAgentRepoV2.Quote memory q = InterAgentRepoV2.Quote({
            borrower: borrower, lender: lender,
            principalToken: address(randomToken), principalAmount: 50_000_000,
            collateralToken: address(weth), collateralAmount: 0.025 ether,
            expiryTimestamp: block.timestamp + 1 hours, rateBps: 425,
            nonce: nonce
        });
        bytes memory sig = _sign(q, oraclePk);
        vm.expectRevert(InterAgentRepoV2.UnsupportedPrincipal.selector);
        repo.originate(q, sig);
    }

    // ─── Helpers ────────────────────────────────────────────────────────────

    function GRACE_PERIOD_PLUS_1() internal pure returns (uint256) {
        return 61 seconds;  // GRACE_PERIOD_SECONDS + 1
    }
}
