// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {SachetMarket} from "../src/SachetMarket.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract MockToken is ERC20 {
    constructor() ERC20("Mock Token", "MTK") {}
    
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract ReentrantMockToken is ERC20 {
    SachetMarket public escrow;
    
    constructor() ERC20("Reentrant Mock Token", "RMTK") {}
    
    function setEscrow(SachetMarket _escrow) external {
        escrow = _escrow;
    }
    
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
    
    function transferFrom(address sender, address recipient, uint256 amount) public override returns (bool) {
        bool result = super.transferFrom(sender, recipient, amount);
        
        // Try to re-enter
        if (address(escrow) != address(0)) {
            try escrow.placeBet(bytes32(0), SachetMarket.Outcome.HOME, amount) {
                // Should revert
            } catch {
                // Expected
            }
        }
        
        return result;
    }
}

contract SachetMarketTest is Test {
    SachetMarket public escrow;
    MockToken public token;

    address public admin = address(1);
    address public resolver = address(2);
    address public alice = address(3);
    address public bob = address(4);
    address public charlie = address(5);
    
    function setUp() public {
        token = new MockToken();
        
        vm.startPrank(admin);
        escrow = new SachetMarket(address(token), admin);
        escrow.grantRole(escrow.RESOLVER_ROLE(), resolver);
        vm.stopPrank();
        
        token.mint(alice, 10000 ether);
        token.mint(bob, 10000 ether);
        token.mint(charlie, 10000 ether);
        
        vm.prank(alice);
        token.approve(address(escrow), type(uint256).max);
        vm.prank(bob);
        token.approve(address(escrow), type(uint256).max);
        vm.prank(charlie);
        token.approve(address(escrow), type(uint256).max);
    }

    // --- Access Control ---
    
    function test_LaunchRound_OnlyAdmin() public {
        vm.prank(alice);
        vm.expectRevert();
        escrow.launchPool(bytes32(0), uint64(block.timestamp + 1 days));
        
        vm.prank(admin);
        escrow.launchPool(bytes32(0), uint64(block.timestamp + 1 days));
        
        (uint64 expiresAt,,,,,,,) = escrow.pools(bytes32(0));
        assertEq(expiresAt, uint64(block.timestamp + 1 days));
    }

    function test_ResolveRound_OnlyResolver() public {
        vm.prank(admin);
        escrow.launchPool(bytes32(0), uint64(block.timestamp + 1 days));
        
        vm.warp(block.timestamp + 2 days);
        
        // Admin cannot resolve
        vm.prank(admin);
        vm.expectRevert();
        escrow.resolvePool(bytes32(0), SachetMarket.Outcome.HOME);
        
        // Alice cannot resolve
        vm.prank(alice);
        vm.expectRevert();
        escrow.resolvePool(bytes32(0), SachetMarket.Outcome.HOME);
        
        // Resolver can resolve
        vm.prank(resolver);
        escrow.resolvePool(bytes32(0), SachetMarket.Outcome.HOME);
    }

    // --- Pool Lifecycle ---

    function test_CannotBetBeforeRoundExists() public {
        vm.prank(alice);
        vm.expectRevert(SachetMarket.PoolDoesNotExist.selector);
        escrow.placeBet(bytes32(0), SachetMarket.Outcome.HOME, 100);
    }

    function test_CannotBetAfterEndTime() public {
        vm.prank(admin);
        escrow.launchPool(bytes32(0), uint64(block.timestamp + 1 days));
        
        vm.warp(block.timestamp + 1 days + 1);
        
        vm.prank(alice);
        vm.expectRevert(SachetMarket.PoolClosed.selector);
        escrow.placeBet(bytes32(0), SachetMarket.Outcome.HOME, 100);
    }

    function test_CannotResolveBeforeEndTime() public {
        vm.prank(admin);
        escrow.launchPool(bytes32(0), uint64(block.timestamp + 1 days));
        
        vm.prank(resolver);
        vm.expectRevert(SachetMarket.PoolStillOpen.selector);
        escrow.resolvePool(bytes32(0), SachetMarket.Outcome.HOME);
    }

    function test_CannotResolveTwice() public {
        vm.prank(admin);
        escrow.launchPool(bytes32(0), uint64(block.timestamp + 1 days));
        vm.warp(block.timestamp + 2 days);
        
        vm.startPrank(resolver);
        escrow.resolvePool(bytes32(0), SachetMarket.Outcome.HOME);
        
        vm.expectRevert(SachetMarket.AlreadyResolvedOrCancelled.selector);
        escrow.resolvePool(bytes32(0), SachetMarket.Outcome.HOME);
        vm.stopPrank();
    }

    // --- Betting ---

    function test_BetRevertsOnAmountZero() public {
        vm.prank(admin);
        escrow.launchPool(bytes32(0), uint64(block.timestamp + 1 days));
        
        vm.prank(alice);
        vm.expectRevert(SachetMarket.AmountMustBeGreaterThan0.selector);
        escrow.placeBet(bytes32(0), SachetMarket.Outcome.HOME, 0);
    }

    function test_BetRevertsOnUnsetOutcome() public {
        vm.prank(admin);
        escrow.launchPool(bytes32(0), uint64(block.timestamp + 1 days));
        
        vm.prank(alice);
        vm.expectRevert(SachetMarket.InvalidOutcome.selector);
        escrow.placeBet(bytes32(0), SachetMarket.Outcome.UNSET, 100);
    }

    function test_BetRevertsOnVoidOutcome() public {
        vm.prank(admin);
        escrow.launchPool(bytes32(0), uint64(block.timestamp + 1 days));
        
        vm.prank(alice);
        vm.expectRevert(SachetMarket.InvalidOutcome.selector);
        escrow.placeBet(bytes32(0), SachetMarket.Outcome.VOID, 100);
    }



    function test_TokenTransferMatchesRecordedAmount() public {
        vm.prank(admin);
        escrow.launchPool(bytes32(0), uint64(block.timestamp + 1 days));
        
        vm.prank(alice);
        escrow.placeBet(bytes32(0), SachetMarket.Outcome.HOME, 100);
        
        (uint256 amount, , ) = escrow.bets(bytes32(0), alice);
        assertEq(amount, 100);
        assertEq(token.balanceOf(address(escrow)), 100);
    }

    // --- Withdrawal ---

    function test_WithdrawSucceedsBeforeEndTime() public {
        vm.prank(admin);
        escrow.launchPool(bytes32(0), uint64(block.timestamp + 1 days));
        
        vm.prank(alice);
        escrow.placeBet(bytes32(0), SachetMarket.Outcome.HOME, 100);
        
        vm.prank(alice);
        escrow.withdrawBet(bytes32(0));
        
        (uint256 amount, , ) = escrow.bets(bytes32(0), alice);
        assertEq(amount, 0);

        
        (,,,,,,uint256 totalPool,) = escrow.pools(bytes32(0));
        assertEq(totalPool, 0);
        assertEq(token.balanceOf(address(escrow)), 0);
    }

    function test_WithdrawRevertsAfterEndTime() public {
        vm.prank(admin);
        escrow.launchPool(bytes32(0), uint64(block.timestamp + 1 days));
        
        vm.prank(alice);
        escrow.placeBet(bytes32(0), SachetMarket.Outcome.HOME, 100);
        
        vm.warp(block.timestamp + 2 days);
        
        vm.prank(alice);
        vm.expectRevert(SachetMarket.TooLateToWithdraw.selector);
        escrow.withdrawBet(bytes32(0));
    }

    function test_WithdrawRevertsIfAlreadyWithdrawn() public {
        vm.prank(admin);
        escrow.launchPool(bytes32(0), uint64(block.timestamp + 1 days));
        
        vm.startPrank(alice);
        escrow.placeBet(bytes32(0), SachetMarket.Outcome.HOME, 100);
        escrow.withdrawBet(bytes32(0));
        vm.expectRevert(SachetMarket.NoActiveBet.selector);
        escrow.withdrawBet(bytes32(0));
        vm.stopPrank();
    }

    function test_WithdrawCannotClaimLater() public {
        vm.prank(admin);
        escrow.launchPool(bytes32(0), uint64(block.timestamp + 1 days));
        
        vm.prank(alice);
        escrow.placeBet(bytes32(0), SachetMarket.Outcome.HOME, 100);
        
        vm.prank(alice);
        escrow.withdrawBet(bytes32(0));
        
        vm.warp(block.timestamp + 2 days);
        vm.prank(resolver);
        escrow.resolvePool(bytes32(0), SachetMarket.Outcome.HOME);
        
        vm.prank(alice);
        vm.expectRevert(SachetMarket.NoClaimableBet.selector);
        escrow.claim(bytes32(0));
    }

    // --- Payout Math ---

    function test_PayoutMath_3WaySplit() public {
        vm.prank(admin);
        escrow.launchPool(bytes32(0), uint64(block.timestamp + 1 days));
        
        // WIN=100 (Alice), DRAW=50 (Bob), LOSE=50 (Charlie)
        vm.prank(alice); escrow.placeBet(bytes32(0), SachetMarket.Outcome.HOME, 100);
        vm.prank(bob); escrow.placeBet(bytes32(0), SachetMarket.Outcome.DRAW, 50);
        vm.prank(charlie); escrow.placeBet(bytes32(0), SachetMarket.Outcome.AWAY, 50);
        
        vm.warp(block.timestamp + 2 days);
        vm.prank(resolver);
        escrow.resolvePool(bytes32(0), SachetMarket.Outcome.HOME);
        
        uint256 aliceBalBefore = token.balanceOf(alice);
        vm.prank(alice);
        escrow.claim(bytes32(0));
        uint256 aliceBalAfter = token.balanceOf(alice);
        
        // Alice bet 100. Winning pool = 100. Losing pool = 50 + 50 = 100.
        // Payout = 100 + (100 * 100 / 100) = 200.
        assertEq(aliceBalAfter - aliceBalBefore, 200);
    }

    function test_PayoutMath_ZeroLosingPool() public {
        vm.prank(admin);
        escrow.launchPool(bytes32(0), uint64(block.timestamp + 1 days));
        
        vm.prank(alice); escrow.placeBet(bytes32(0), SachetMarket.Outcome.HOME, 100);
        vm.prank(bob); escrow.placeBet(bytes32(0), SachetMarket.Outcome.HOME, 50);
        
        vm.warp(block.timestamp + 2 days);
        vm.prank(resolver);
        escrow.resolvePool(bytes32(0), SachetMarket.Outcome.HOME);
        
        uint256 aliceBalBefore = token.balanceOf(alice);
        vm.prank(alice); escrow.claim(bytes32(0));
        assertEq(token.balanceOf(alice) - aliceBalBefore, 100);
        
        uint256 bobBalBefore = token.balanceOf(bob);
        vm.prank(bob); escrow.claim(bytes32(0));
        assertEq(token.balanceOf(bob) - bobBalBefore, 50);
    }

    function test_PayoutMath_ZeroWinningPool() public {
        vm.prank(admin);
        escrow.launchPool(bytes32(0), uint64(block.timestamp + 1 days));
        
        vm.prank(bob); escrow.placeBet(bytes32(0), SachetMarket.Outcome.DRAW, 100);
        vm.prank(charlie); escrow.placeBet(bytes32(0), SachetMarket.Outcome.AWAY, 50);
        
        vm.warp(block.timestamp + 2 days);
        vm.prank(resolver);
        escrow.resolvePool(bytes32(0), SachetMarket.Outcome.HOME); // Nobody bet WIN
        
        // Bob and Charlie should get 0 payout and claim without reverting
        uint256 bobBalBefore = token.balanceOf(bob);
        vm.prank(bob); escrow.claim(bytes32(0));
        assertEq(token.balanceOf(bob), bobBalBefore);
        
        uint256 charlieBalBefore = token.balanceOf(charlie);
        vm.prank(charlie); escrow.claim(bytes32(0));
        assertEq(token.balanceOf(charlie), charlieBalBefore);
    }

    function test_PayoutMath_SingleBettorTotal() public {
        vm.prank(admin);
        escrow.launchPool(bytes32(0), uint64(block.timestamp + 1 days));
        
        vm.prank(alice); escrow.placeBet(bytes32(0), SachetMarket.Outcome.HOME, 100);
        
        vm.warp(block.timestamp + 2 days);
        vm.prank(resolver);
        escrow.resolvePool(bytes32(0), SachetMarket.Outcome.HOME);
        
        uint256 aliceBalBefore = token.balanceOf(alice);
        vm.prank(alice); escrow.claim(bytes32(0));
        assertEq(token.balanceOf(alice) - aliceBalBefore, 100);
    }

    function test_DoubleClaimReverts() public {
        vm.prank(admin);
        escrow.launchPool(bytes32(0), uint64(block.timestamp + 1 days));
        vm.prank(alice); escrow.placeBet(bytes32(0), SachetMarket.Outcome.HOME, 100);
        vm.warp(block.timestamp + 2 days);
        vm.prank(resolver);
        escrow.resolvePool(bytes32(0), SachetMarket.Outcome.HOME);
        
        vm.startPrank(alice);
        escrow.claim(bytes32(0));
        vm.expectRevert(SachetMarket.AlreadyClaimed.selector);
        escrow.claim(bytes32(0));
        vm.stopPrank();
    }
    
    function test_ClaimOnCancelledRound() public {
        vm.prank(admin);
        escrow.launchPool(bytes32(0), uint64(block.timestamp + 1 days));
        vm.prank(alice); escrow.placeBet(bytes32(0), SachetMarket.Outcome.HOME, 100);
        vm.prank(bob); escrow.placeBet(bytes32(0), SachetMarket.Outcome.AWAY, 200);
        
        vm.prank(admin);
        escrow.cancelPool(bytes32(0));
        
        uint256 aliceBalBefore = token.balanceOf(alice);
        vm.prank(alice); escrow.claim(bytes32(0));
        assertEq(token.balanceOf(alice) - aliceBalBefore, 100);
        
        uint256 bobBalBefore = token.balanceOf(bob);
        vm.prank(bob); escrow.claim(bytes32(0));
        assertEq(token.balanceOf(bob) - bobBalBefore, 200);
    }

    function test_ClaimOnVoidRound() public {
        vm.prank(admin);
        escrow.launchPool(bytes32(0), uint64(block.timestamp + 1 days));
        vm.prank(alice); escrow.placeBet(bytes32(0), SachetMarket.Outcome.HOME, 100);
        vm.prank(bob); escrow.placeBet(bytes32(0), SachetMarket.Outcome.AWAY, 200);
        
        vm.warp(block.timestamp + 2 days);
        vm.prank(resolver);
        escrow.resolvePool(bytes32(0), SachetMarket.Outcome.VOID);
        
        uint256 aliceBalBefore = token.balanceOf(alice);
        vm.prank(alice); escrow.claim(bytes32(0));
        assertEq(token.balanceOf(alice) - aliceBalBefore, 100);
        
        uint256 bobBalBefore = token.balanceOf(bob);
        vm.prank(bob); escrow.claim(bytes32(0));
        assertEq(token.balanceOf(bob) - bobBalBefore, 200);
    }

    function test_IncreaseBetSameOutcome() public {
        vm.prank(admin);
        escrow.launchPool(bytes32(0), uint64(block.timestamp + 1 days));
        
        vm.startPrank(alice);
        escrow.placeBet(bytes32(0), SachetMarket.Outcome.HOME, 100);
        escrow.placeBet(bytes32(0), SachetMarket.Outcome.HOME, 200);
        vm.stopPrank();

        SachetMarket.Bet memory b = escrow.getUserStake(bytes32(0), alice);
        assertEq(b.amount, 300);
        assertEq(uint(b.outcome), uint(SachetMarket.Outcome.HOME));
        
        SachetMarket.Pool memory p = escrow.getPool(bytes32(0));
        assertEq(p.poolHome, 300);
        assertEq(p.totalPool, 300);
    }

    function test_CannotChangeOutcomeWithoutWithdraw() public {
        vm.prank(admin);
        escrow.launchPool(bytes32(0), uint64(block.timestamp + 1 days));
        
        vm.startPrank(alice);
        escrow.placeBet(bytes32(0), SachetMarket.Outcome.HOME, 100);
        
        vm.expectRevert(SachetMarket.CannotChangeOutcome.selector);
        escrow.placeBet(bytes32(0), SachetMarket.Outcome.AWAY, 100);
        vm.stopPrank();
    }

    function test_CanBetAgainWithDifferentOutcomeAfterWithdraw() public {
        vm.prank(admin);
        escrow.launchPool(bytes32(0), uint64(block.timestamp + 1 days));
        
        vm.startPrank(alice);
        escrow.placeBet(bytes32(0), SachetMarket.Outcome.HOME, 100);
        escrow.withdrawBet(bytes32(0));
        
        // Bet again on AWAY
        escrow.placeBet(bytes32(0), SachetMarket.Outcome.AWAY, 200);
        vm.stopPrank();
        
        SachetMarket.Bet memory b = escrow.getUserStake(bytes32(0), alice);
        assertEq(b.amount, 200);
        assertEq(uint(b.outcome), uint(SachetMarket.Outcome.AWAY));
        
        SachetMarket.Pool memory p = escrow.getPool(bytes32(0));
        assertEq(p.poolHome, 0); // Withdrawn
        assertEq(p.poolAway, 200);
        assertEq(p.totalPool, 200);
    }

    // --- Fuzz Testing ---

    function testFuzz_PayoutMath(uint128 amount1, uint128 amount2, uint128 amount3, uint8 outcomeChoice) public {
        amount1 = uint128(bound(amount1, 1, 10000 ether));
        amount2 = uint128(bound(amount2, 1, 10000 ether));
        amount3 = uint128(bound(amount3, 1, 10000 ether));
        
        // Convert to Outcome
        SachetMarket.Outcome result = SachetMarket.Outcome((outcomeChoice % 3) + 1);
        
        vm.prank(admin);
        escrow.launchPool(bytes32(0), uint64(block.timestamp + 1 days));
        
        vm.prank(alice); escrow.placeBet(bytes32(0), SachetMarket.Outcome.HOME, amount1);
        vm.prank(bob); escrow.placeBet(bytes32(0), SachetMarket.Outcome.DRAW, amount2);
        vm.prank(charlie); escrow.placeBet(bytes32(0), SachetMarket.Outcome.AWAY, amount3);
        
        uint256 expectedTotalPool = uint256(amount1) + amount2 + amount3;
        (,,,,,,uint256 totalPool,) = escrow.pools(bytes32(0));
        assertEq(totalPool, expectedTotalPool);
        
        vm.warp(block.timestamp + 2 days);
        vm.prank(resolver);
        escrow.resolvePool(bytes32(0), result);
        
        uint256 totalClaimed = 0;
        
        uint256 b1 = token.balanceOf(alice); vm.prank(alice); escrow.claim(bytes32(0)); totalClaimed += token.balanceOf(alice) - b1;
        uint256 b2 = token.balanceOf(bob); vm.prank(bob); escrow.claim(bytes32(0)); totalClaimed += token.balanceOf(bob) - b2;
        uint256 b3 = token.balanceOf(charlie); vm.prank(charlie); escrow.claim(bytes32(0)); totalClaimed += token.balanceOf(charlie) - b3;
        
        assertTrue(totalClaimed <= expectedTotalPool, "totalClaimed exceeds totalPool");
        
        // Assert losers got 0
        if (result != SachetMarket.Outcome.HOME) assertEq(token.balanceOf(alice) - b1, 0);
        if (result != SachetMarket.Outcome.DRAW) assertEq(token.balanceOf(bob) - b2, 0);
        if (result != SachetMarket.Outcome.AWAY) assertEq(token.balanceOf(charlie) - b3, 0);
    }

    // --- Reentrancy ---

    function test_ReentrancyBlocked() public {
        ReentrantMockToken rToken = new ReentrantMockToken();
        
        vm.prank(admin);
        SachetMarket rEscrow = new SachetMarket(address(rToken), admin);
        rToken.setEscrow(rEscrow);
        
        rToken.mint(alice, 1000);
        vm.prank(alice);
        rToken.approve(address(rEscrow), type(uint256).max);
        
        vm.prank(admin);
        rEscrow.launchPool(bytes32(0), uint64(block.timestamp + 1 days));
        
        vm.prank(alice);
        rEscrow.placeBet(bytes32(0), SachetMarket.Outcome.HOME, 100);
        
        (uint256 amt, , ) = rEscrow.bets(bytes32(0), alice);
        assertEq(amt, 100); // Because inner call reverted, so only outer succeeded
        assertEq(rToken.balanceOf(address(rEscrow)), 100);
    }

    // --- Pause ---

    function test_PauseBlocksPlaceBetButNotWithdrawOrClaim() public {
        vm.prank(admin);
        escrow.launchPool(bytes32(0), uint64(block.timestamp + 1 days));
        
        vm.prank(alice); escrow.placeBet(bytes32(0), SachetMarket.Outcome.HOME, 100);
        vm.prank(bob); escrow.placeBet(bytes32(0), SachetMarket.Outcome.AWAY, 200);
        
        vm.prank(admin);
        escrow.pause();
        
        vm.prank(charlie);
        vm.expectRevert();
        escrow.placeBet(bytes32(0), SachetMarket.Outcome.DRAW, 100);
        
        // Withdraw should succeed
        vm.prank(alice);
        escrow.withdrawBet(bytes32(0));
        
        vm.warp(block.timestamp + 2 days);
        vm.prank(resolver);
        escrow.resolvePool(bytes32(0), SachetMarket.Outcome.AWAY);
        
        // Claim should succeed
        vm.prank(bob);
        escrow.claim(bytes32(0));
    }

    function test_UpdateToken_RevertsIfUnpaused() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSignature("ExpectedPause()"));
        escrow.updateToken(address(42));
    }

    function test_UpdateToken_SuccessWhenPaused() public {
        vm.prank(admin);
        escrow.pause();
        
        vm.prank(admin);
        escrow.updateToken(address(42));
        assertEq(address(escrow.sachetMarketToken()), address(42));
    }

    function test_WithdrawTreasury_Success() public {
        // Mint some tokens directly to contract
        token.mint(address(escrow), 1000);
        
        uint256 adminBalBefore = token.balanceOf(admin);
        
        vm.prank(admin);
        escrow.withdrawTreasury(address(token), admin, 400);
        
        assertEq(token.balanceOf(admin) - adminBalBefore, 400);
        assertEq(token.balanceOf(address(escrow)), 600);
        
        // Test withdraw max
        vm.prank(admin);
        escrow.withdrawTreasury(address(token), admin, type(uint256).max);
        
        assertEq(token.balanceOf(address(escrow)), 0);
        assertEq(token.balanceOf(admin) - adminBalBefore, 1000);
    }
}
