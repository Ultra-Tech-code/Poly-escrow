// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

contract PredictEscrow is AccessControl, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant RESOLVER_ROLE = keccak256("RESOLVER_ROLE");

    enum Outcome { UNSET, WIN, DRAW, LOSE }
    enum RoundStatus { OPEN, LOCKED, RESOLVED, CANCELLED }

    struct Round {
        uint64 endTime;
        RoundStatus status;
        Outcome result;
        uint256 poolWin;
        uint256 poolDraw;
        uint256 poolLose;
        uint256 totalPool;
        uint256 totalClaimed; // Tracked to safely sweep dust
    }

    struct Bet {
        uint256 amount;
        Outcome outcome;
        bool withdrawn;
        bool claimed;
    }

    mapping(uint256 => Round) public rounds;
    mapping(uint256 => mapping(address => Bet)) public bets;

    IERC20 public immutable bettingToken;

    uint256 public constant MAX_ROUND_DURATION = 30 days;

    event RoundLaunched(uint256 indexed roundId, uint64 endTime);
    event BetPlaced(uint256 indexed roundId, address indexed user, Outcome outcome, uint256 amount);
    event BetWithdrawn(uint256 indexed roundId, address indexed user, uint256 amount);
    event RoundResolved(uint256 indexed roundId, Outcome result);
    event RoundCancelled(uint256 indexed roundId);
    event Claimed(uint256 indexed roundId, address indexed user, uint256 payout);

    constructor(address _bettingToken, address _adminMultisig) {
        require(_bettingToken != address(0), "Zero address");
        require(_adminMultisig != address(0), "Zero address");
        bettingToken = IERC20(_bettingToken);
        _grantRole(DEFAULT_ADMIN_ROLE, _adminMultisig);
        _grantRole(ADMIN_ROLE, _adminMultisig);
    }

    function pause() external onlyRole(ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }

    function launchRound(uint256 roundId, uint64 endTime) external onlyRole(ADMIN_ROLE) {
        require(endTime > block.timestamp, "endTime in past");
        require(endTime <= block.timestamp + MAX_ROUND_DURATION, "endTime exceeds max duration");
        require(rounds[roundId].endTime == 0, "round already exists");

        Round storage r = rounds[roundId];
        r.endTime = endTime;
        r.status = RoundStatus.OPEN;
        // Other fields default to 0/UNSET

        emit RoundLaunched(roundId, endTime);
    }

    function placeBet(uint256 roundId, Outcome outcome, uint256 amount) external nonReentrant whenNotPaused {
        Round storage r = rounds[roundId];
        require(r.endTime != 0, "round does not exist");
        require(block.timestamp < r.endTime, "round closed");
        require(r.status == RoundStatus.OPEN, "round not open");
        require(outcome != Outcome.UNSET, "invalid outcome");
        require(amount > 0, "amount must be > 0");

        Bet storage b = bets[roundId][msg.sender];
        require(b.amount == 0, "already bet this round");

        uint256 balanceBefore = bettingToken.balanceOf(address(this));
        bettingToken.safeTransferFrom(msg.sender, address(this), amount);
        uint256 receivedAmount = bettingToken.balanceOf(address(this)) - balanceBefore;
        require(receivedAmount > 0, "received amount must be > 0");

        b.amount = receivedAmount;
        b.outcome = outcome;
        b.withdrawn = false;
        b.claimed = false;

        if (outcome == Outcome.WIN) {
            r.poolWin += receivedAmount;
        } else if (outcome == Outcome.DRAW) {
            r.poolDraw += receivedAmount;
        } else if (outcome == Outcome.LOSE) {
            r.poolLose += receivedAmount;
        }

        r.totalPool += receivedAmount;

        emit BetPlaced(roundId, msg.sender, outcome, receivedAmount);
    }

    function withdrawBet(uint256 roundId) external nonReentrant {
        Round storage r = rounds[roundId];
        require(block.timestamp < r.endTime, "too late to withdraw");
        require(r.status == RoundStatus.OPEN, "round not open");

        Bet storage b = bets[roundId][msg.sender];
        require(b.amount > 0 && !b.withdrawn, "no active bet");

        uint256 amountToReturn = b.amount;
        
        if (b.outcome == Outcome.WIN) {
            r.poolWin -= amountToReturn;
        } else if (b.outcome == Outcome.DRAW) {
            r.poolDraw -= amountToReturn;
        } else if (b.outcome == Outcome.LOSE) {
            r.poolLose -= amountToReturn;
        }

        r.totalPool -= amountToReturn;
        
        b.withdrawn = true;
        
        bettingToken.safeTransfer(msg.sender, amountToReturn);
        
        emit BetWithdrawn(roundId, msg.sender, amountToReturn);
    }

    function resolveRound(uint256 roundId, Outcome result) external onlyRole(RESOLVER_ROLE) {
        Round storage r = rounds[roundId];
        require(r.endTime != 0, "round does not exist");
        require(block.timestamp >= r.endTime, "round still open");
        require(r.status == RoundStatus.OPEN, "already resolved/cancelled");
        require(result != Outcome.UNSET, "invalid result");

        r.status = RoundStatus.RESOLVED;
        r.result = result;

        emit RoundResolved(roundId, result);
    }

    function cancelRound(uint256 roundId) external onlyRole(ADMIN_ROLE) {
        Round storage r = rounds[roundId];
        require(r.endTime != 0, "round does not exist");
        require(r.status == RoundStatus.OPEN, "round not open");
        
        r.status = RoundStatus.CANCELLED;
        
        emit RoundCancelled(roundId);
    }

    function claim(uint256 roundId) external nonReentrant {
        Round storage r = rounds[roundId];
        require(
            r.status == RoundStatus.RESOLVED || r.status == RoundStatus.CANCELLED,
            "not resolved or cancelled"
        );

        Bet storage b = bets[roundId][msg.sender];
        require(b.amount > 0 && !b.withdrawn, "no claimable bet");
        require(!b.claimed, "already claimed");

        uint256 payout = 0;

        if (r.status == RoundStatus.CANCELLED) {
            payout = b.amount;
        } else {
            // RESOLVED
            Outcome result = r.result;
            uint256 winningPool;

            if (result == Outcome.WIN) {
                winningPool = r.poolWin;
            } else if (result == Outcome.DRAW) {
                winningPool = r.poolDraw;
            } else if (result == Outcome.LOSE) {
                winningPool = r.poolLose;
            }

            uint256 losingPool = r.totalPool - winningPool;

            if (b.outcome != result) {
                payout = 0;
            } else if (winningPool == 0) {
                payout = 0;
            } else {
                payout = b.amount + (b.amount * losingPool) / winningPool;
            }
        }

        b.claimed = true;
        
        if (payout > 0) {
            r.totalClaimed += payout;
            bettingToken.safeTransfer(msg.sender, payout);
        }

        emit Claimed(roundId, msg.sender, payout);
    }

    function sweepDust(uint256 roundId, address to) external onlyRole(ADMIN_ROLE) {
        Round storage r = rounds[roundId];
        require(r.status == RoundStatus.RESOLVED || r.status == RoundStatus.CANCELLED, "not resolved or cancelled");
        require(block.timestamp >= r.endTime + 90 days, "claim window still open");
        
        // This is safe because totalClaimed can only be at most totalPool in RESOLVED/CANCELLED.
        uint256 dust = r.totalPool - r.totalClaimed;
        require(dust > 0, "no dust to sweep");
        
        r.totalClaimed = r.totalPool; // Prevent double sweeping
        
        bettingToken.safeTransfer(to, dust);
    }
}
