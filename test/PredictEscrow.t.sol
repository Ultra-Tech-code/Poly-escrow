// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {PredictEscrow} from "../src/PredictEscrow.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract MockToken is ERC20 {
    constructor() ERC20("Mock Token", "MTK") {}
    
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract ReentrantMockToken is ERC20 {
    PredictEscrow public escrow;
    
    constructor() ERC20("Reentrant Mock Token", "RMTK") {}
    
    function setEscrow(PredictEscrow _escrow) external {
        escrow = _escrow;
    }
    
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
    
    function transferFrom(address sender, address recipient, uint256 amount) public override returns (bool) {
        bool result = super.transferFrom(sender, recipient, amount);
        
        // Try to re-enter
        if (address(escrow) != address(0)) {
            try escrow.placeBet(0, PredictEscrow.Outcome.WIN, amount) {
                // Should revert
            } catch {
                // Expected
            }
        }
        
        return result;
    }
}

contract PredictEscrowTest is Test {
    PredictEscrow public escrow;
    MockToken public token;

    address public admin = address(1);
    address public resolver = address(2);
    address public alice = address(3);
    address public bob = address(4);
    address public charlie = address(5);
    
    function setUp() public {
        token = new MockToken();
        
        vm.startPrank(admin);
        escrow = new PredictEscrow(address(token), admin);
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
        escrow.launchRound(0, uint64(block.timestamp + 1 days));
        
        vm.prank(admin);
        escrow.launchRound(0, uint64(block.timestamp + 1 days));
        
        (uint64 endTime,,,,,,,) = escrow.rounds(0);
        assertEq(endTime, uint64(block.timestamp + 1 days));
    }

    function test_ResolveRound_OnlyResolver() public {
        vm.prank(admin);
        escrow.launchRound(0, uint64(block.timestamp + 1 days));
        
        vm.warp(block.timestamp + 2 days);
        
        // Admin cannot resolve
        vm.prank(admin);
        vm.expectRevert();
        escrow.resolveRound(0, PredictEscrow.Outcome.WIN);
        
        // Alice cannot resolve
        vm.prank(alice);
        vm.expectRevert();
        escrow.resolveRound(0, PredictEscrow.Outcome.WIN);
        
        // Resolver can resolve
        vm.prank(resolver);
        escrow.resolveRound(0, PredictEscrow.Outcome.WIN);
    }

    // --- Round Lifecycle ---

    function test_CannotBetBeforeRoundExists() public {
        vm.prank(alice);
        vm.expectRevert("round does not exist");
        escrow.placeBet(0, PredictEscrow.Outcome.WIN, 100);
    }

    function test_CannotBetAfterEndTime() public {
        vm.prank(admin);
        escrow.launchRound(0, uint64(block.timestamp + 1 days));
        
        vm.warp(block.timestamp + 1 days + 1);
        
        vm.prank(alice);
        vm.expectRevert("round closed");
        escrow.placeBet(0, PredictEscrow.Outcome.WIN, 100);
    }

    function test_CannotResolveBeforeEndTime() public {
        vm.prank(admin);
        escrow.launchRound(0, uint64(block.timestamp + 1 days));
        
        vm.prank(resolver);
        vm.expectRevert("round still open");
        escrow.resolveRound(0, PredictEscrow.Outcome.WIN);
    }

    function test_CannotResolveTwice() public {
        vm.prank(admin);
        escrow.launchRound(0, uint64(block.timestamp + 1 days));
        vm.warp(block.timestamp + 2 days);
        
        vm.startPrank(resolver);
        escrow.resolveRound(0, PredictEscrow.Outcome.WIN);
        
        vm.expectRevert("already resolved/cancelled");
        escrow.resolveRound(0, PredictEscrow.Outcome.WIN);
        vm.stopPrank();
    }

    // --- Betting ---

    function test_BetRevertsOnAmountZero() public {
        vm.prank(admin);
        escrow.launchRound(0, uint64(block.timestamp + 1 days));
        
        vm.prank(alice);
        vm.expectRevert("amount must be > 0");
        escrow.placeBet(0, PredictEscrow.Outcome.WIN, 0);
    }

    function test_BetRevertsOnUnsetOutcome() public {
        vm.prank(admin);
        escrow.launchRound(0, uint64(block.timestamp + 1 days));
        
        vm.prank(alice);
        vm.expectRevert("invalid outcome");
        escrow.placeBet(0, PredictEscrow.Outcome.UNSET, 100);
    }

    function test_CannotBetTwice() public {
        vm.prank(admin);
        escrow.launchRound(0, uint64(block.timestamp + 1 days));
        
        vm.startPrank(alice);
        escrow.placeBet(0, PredictEscrow.Outcome.WIN, 100);
        vm.expectRevert("already bet this round");
        escrow.placeBet(0, PredictEscrow.Outcome.WIN, 100);
        vm.stopPrank();
    }

    function test_TokenTransferMatchesRecordedAmount() public {
        vm.prank(admin);
        escrow.launchRound(0, uint64(block.timestamp + 1 days));
        
        vm.prank(alice);
        escrow.placeBet(0, PredictEscrow.Outcome.WIN, 100);
        
        (uint256 amount, , , ) = escrow.bets(0, alice);
        assertEq(amount, 100);
        assertEq(token.balanceOf(address(escrow)), 100);
    }

    // --- Withdrawal ---

    function test_WithdrawSucceedsBeforeEndTime() public {
        vm.prank(admin);
        escrow.launchRound(0, uint64(block.timestamp + 1 days));
        
        vm.prank(alice);
        escrow.placeBet(0, PredictEscrow.Outcome.WIN, 100);
        
        vm.prank(alice);
        escrow.withdrawBet(0);
        
        (uint256 amount, , bool withdrawn, ) = escrow.bets(0, alice);
        assertEq(amount, 100);
        assertTrue(withdrawn);
        
        (,,,,,,uint256 totalPool,) = escrow.rounds(0);
        assertEq(totalPool, 0);
        assertEq(token.balanceOf(address(escrow)), 0);
    }

    function test_WithdrawRevertsAfterEndTime() public {
        vm.prank(admin);
        escrow.launchRound(0, uint64(block.timestamp + 1 days));
        
        vm.prank(alice);
        escrow.placeBet(0, PredictEscrow.Outcome.WIN, 100);
        
        vm.warp(block.timestamp + 2 days);
        
        vm.prank(alice);
        vm.expectRevert("too late to withdraw");
        escrow.withdrawBet(0);
    }

    function test_WithdrawRevertsIfAlreadyWithdrawn() public {
        vm.prank(admin);
        escrow.launchRound(0, uint64(block.timestamp + 1 days));
        
        vm.startPrank(alice);
        escrow.placeBet(0, PredictEscrow.Outcome.WIN, 100);
        escrow.withdrawBet(0);
        vm.expectRevert("no active bet");
        escrow.withdrawBet(0);
        vm.stopPrank();
    }

    function test_WithdrawCannotClaimLater() public {
        vm.prank(admin);
        escrow.launchRound(0, uint64(block.timestamp + 1 days));
        
        vm.prank(alice);
        escrow.placeBet(0, PredictEscrow.Outcome.WIN, 100);
        
        vm.prank(alice);
        escrow.withdrawBet(0);
        
        vm.warp(block.timestamp + 2 days);
        vm.prank(resolver);
        escrow.resolveRound(0, PredictEscrow.Outcome.WIN);
        
        vm.prank(alice);
        vm.expectRevert("no claimable bet");
        escrow.claim(0);
    }

    // --- Payout Math ---

    function test_PayoutMath_3WaySplit() public {
        vm.prank(admin);
        escrow.launchRound(0, uint64(block.timestamp + 1 days));
        
        // WIN=100 (Alice), DRAW=50 (Bob), LOSE=50 (Charlie)
        vm.prank(alice); escrow.placeBet(0, PredictEscrow.Outcome.WIN, 100);
        vm.prank(bob); escrow.placeBet(0, PredictEscrow.Outcome.DRAW, 50);
        vm.prank(charlie); escrow.placeBet(0, PredictEscrow.Outcome.LOSE, 50);
        
        vm.warp(block.timestamp + 2 days);
        vm.prank(resolver);
        escrow.resolveRound(0, PredictEscrow.Outcome.WIN);
        
        uint256 aliceBalBefore = token.balanceOf(alice);
        vm.prank(alice);
        escrow.claim(0);
        uint256 aliceBalAfter = token.balanceOf(alice);
        
        // Alice bet 100. Winning pool = 100. Losing pool = 50 + 50 = 100.
        // Payout = 100 + (100 * 100 / 100) = 200.
        assertEq(aliceBalAfter - aliceBalBefore, 200);
    }

    function test_PayoutMath_ZeroLosingPool() public {
        vm.prank(admin);
        escrow.launchRound(0, uint64(block.timestamp + 1 days));
        
        vm.prank(alice); escrow.placeBet(0, PredictEscrow.Outcome.WIN, 100);
        vm.prank(bob); escrow.placeBet(0, PredictEscrow.Outcome.WIN, 50);
        
        vm.warp(block.timestamp + 2 days);
        vm.prank(resolver);
        escrow.resolveRound(0, PredictEscrow.Outcome.WIN);
        
        uint256 aliceBalBefore = token.balanceOf(alice);
        vm.prank(alice); escrow.claim(0);
        assertEq(token.balanceOf(alice) - aliceBalBefore, 100);
        
        uint256 bobBalBefore = token.balanceOf(bob);
        vm.prank(bob); escrow.claim(0);
        assertEq(token.balanceOf(bob) - bobBalBefore, 50);
    }

    function test_PayoutMath_ZeroWinningPool() public {
        vm.prank(admin);
        escrow.launchRound(0, uint64(block.timestamp + 1 days));
        
        vm.prank(bob); escrow.placeBet(0, PredictEscrow.Outcome.DRAW, 100);
        vm.prank(charlie); escrow.placeBet(0, PredictEscrow.Outcome.LOSE, 50);
        
        vm.warp(block.timestamp + 2 days);
        vm.prank(resolver);
        escrow.resolveRound(0, PredictEscrow.Outcome.WIN); // Nobody bet WIN
        
        // Bob and Charlie should get 0 payout and claim without reverting
        uint256 bobBalBefore = token.balanceOf(bob);
        vm.prank(bob); escrow.claim(0);
        assertEq(token.balanceOf(bob), bobBalBefore);
        
        uint256 charlieBalBefore = token.balanceOf(charlie);
        vm.prank(charlie); escrow.claim(0);
        assertEq(token.balanceOf(charlie), charlieBalBefore);
    }

    function test_PayoutMath_SingleBettorTotal() public {
        vm.prank(admin);
        escrow.launchRound(0, uint64(block.timestamp + 1 days));
        
        vm.prank(alice); escrow.placeBet(0, PredictEscrow.Outcome.WIN, 100);
        
        vm.warp(block.timestamp + 2 days);
        vm.prank(resolver);
        escrow.resolveRound(0, PredictEscrow.Outcome.WIN);
        
        uint256 aliceBalBefore = token.balanceOf(alice);
        vm.prank(alice); escrow.claim(0);
        assertEq(token.balanceOf(alice) - aliceBalBefore, 100);
    }

    function test_DoubleClaimReverts() public {
        vm.prank(admin);
        escrow.launchRound(0, uint64(block.timestamp + 1 days));
        vm.prank(alice); escrow.placeBet(0, PredictEscrow.Outcome.WIN, 100);
        vm.warp(block.timestamp + 2 days);
        vm.prank(resolver);
        escrow.resolveRound(0, PredictEscrow.Outcome.WIN);
        
        vm.startPrank(alice);
        escrow.claim(0);
        vm.expectRevert("already claimed");
        escrow.claim(0);
        vm.stopPrank();
    }
    
    function test_ClaimOnCancelledRound() public {
        vm.prank(admin);
        escrow.launchRound(0, uint64(block.timestamp + 1 days));
        vm.prank(alice); escrow.placeBet(0, PredictEscrow.Outcome.WIN, 100);
        vm.prank(bob); escrow.placeBet(0, PredictEscrow.Outcome.LOSE, 200);
        
        vm.prank(admin);
        escrow.cancelRound(0);
        
        uint256 aliceBalBefore = token.balanceOf(alice);
        vm.prank(alice); escrow.claim(0);
        assertEq(token.balanceOf(alice) - aliceBalBefore, 100);
        
        uint256 bobBalBefore = token.balanceOf(bob);
        vm.prank(bob); escrow.claim(0);
        assertEq(token.balanceOf(bob) - bobBalBefore, 200);
    }

    // --- Fuzz Testing ---

    function testFuzz_PayoutMath(uint128 amount1, uint128 amount2, uint128 amount3, uint8 outcomeChoice) public {
        amount1 = uint128(bound(amount1, 1, 10000 ether));
        amount2 = uint128(bound(amount2, 1, 10000 ether));
        amount3 = uint128(bound(amount3, 1, 10000 ether));
        
        // Convert to Outcome
        PredictEscrow.Outcome result = PredictEscrow.Outcome((outcomeChoice % 3) + 1);
        
        vm.prank(admin);
        escrow.launchRound(0, uint64(block.timestamp + 1 days));
        
        vm.prank(alice); escrow.placeBet(0, PredictEscrow.Outcome.WIN, amount1);
        vm.prank(bob); escrow.placeBet(0, PredictEscrow.Outcome.DRAW, amount2);
        vm.prank(charlie); escrow.placeBet(0, PredictEscrow.Outcome.LOSE, amount3);
        
        uint256 expectedTotalPool = uint256(amount1) + amount2 + amount3;
        (,,,,,,uint256 totalPool,) = escrow.rounds(0);
        assertEq(totalPool, expectedTotalPool);
        
        vm.warp(block.timestamp + 2 days);
        vm.prank(resolver);
        escrow.resolveRound(0, result);
        
        uint256 totalClaimed = 0;
        
        uint256 b1 = token.balanceOf(alice); vm.prank(alice); escrow.claim(0); totalClaimed += token.balanceOf(alice) - b1;
        uint256 b2 = token.balanceOf(bob); vm.prank(bob); escrow.claim(0); totalClaimed += token.balanceOf(bob) - b2;
        uint256 b3 = token.balanceOf(charlie); vm.prank(charlie); escrow.claim(0); totalClaimed += token.balanceOf(charlie) - b3;
        
        assertTrue(totalClaimed <= expectedTotalPool, "totalClaimed exceeds totalPool");
        
        // Assert losers got 0
        if (result != PredictEscrow.Outcome.WIN) assertEq(token.balanceOf(alice) - b1, 0);
        if (result != PredictEscrow.Outcome.DRAW) assertEq(token.balanceOf(bob) - b2, 0);
        if (result != PredictEscrow.Outcome.LOSE) assertEq(token.balanceOf(charlie) - b3, 0);
    }

    // --- Reentrancy ---

    function test_ReentrancyBlocked() public {
        ReentrantMockToken rToken = new ReentrantMockToken();
        
        vm.prank(admin);
        PredictEscrow rEscrow = new PredictEscrow(address(rToken), admin);
        rToken.setEscrow(rEscrow);
        
        rToken.mint(alice, 1000);
        vm.prank(alice);
        rToken.approve(address(rEscrow), type(uint256).max);
        
        vm.prank(admin);
        rEscrow.launchRound(0, uint64(block.timestamp + 1 days));
        
        vm.prank(alice);
        rEscrow.placeBet(0, PredictEscrow.Outcome.WIN, 100);
        
        (uint256 amt, , , ) = rEscrow.bets(0, alice);
        assertEq(amt, 100); // Because inner call reverted, so only outer succeeded
        assertEq(rToken.balanceOf(address(rEscrow)), 100);
    }

    // --- Pause ---

    function test_PauseBlocksPlaceBetButNotWithdrawOrClaim() public {
        vm.prank(admin);
        escrow.launchRound(0, uint64(block.timestamp + 1 days));
        
        vm.prank(alice); escrow.placeBet(0, PredictEscrow.Outcome.WIN, 100);
        vm.prank(bob); escrow.placeBet(0, PredictEscrow.Outcome.LOSE, 200);
        
        vm.prank(admin);
        escrow.pause();
        
        vm.prank(charlie);
        vm.expectRevert();
        escrow.placeBet(0, PredictEscrow.Outcome.DRAW, 100);
        
        // Withdraw should succeed
        vm.prank(alice);
        escrow.withdrawBet(0);
        
        vm.warp(block.timestamp + 2 days);
        vm.prank(resolver);
        escrow.resolveRound(0, PredictEscrow.Outcome.LOSE);
        
        // Claim should succeed
        vm.prank(bob);
        escrow.claim(0);
    }
}
