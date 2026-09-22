// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

contract SachetMarket is AccessControl, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant RESOLVER_ROLE = keccak256("RESOLVER_ROLE");

    enum Outcome { UNSET, HOME, DRAW, AWAY, VOID }
    enum PoolStatus { OPEN, LOCKED, RESOLVED, CANCELLED }

    struct Pool {
        uint64 expiresAt;
        PoolStatus status;
        Outcome result;
        uint256 poolHome;
        uint256 poolDraw;
        uint256 poolAway;
        uint256 totalPool;
        uint256 totalClaimed; // Tracked to safely sweep dust
    }

    struct Bet {
        uint256 amount;
        Outcome outcome;
        bool withdrawn;
        bool claimed;
    }

    mapping(bytes32 => Pool) public pools;
    mapping(bytes32 => mapping(address => Bet)) public bets;

    IERC20 public immutable sachetMarketToken;

    uint256 public constant MAX_POOL_DURATION = 30 days;

    event PoolLaunched(bytes32 indexed poolId, uint64 expiresAt);
    event BetPlaced(bytes32 indexed poolId, address indexed user, Outcome outcome, uint256 amount);
    event BetWithdrawn(bytes32 indexed poolId, address indexed user, uint256 amount);
    event PoolResolved(bytes32 indexed poolId, Outcome result);
    event PoolCancelled(bytes32 indexed poolId);
    event Claimed(bytes32 indexed poolId, address indexed user, uint256 payout);

    constructor(address _sachetMarketToken, address _adminMultisig) {
        require(_sachetMarketToken != address(0), "SachetMarket: Zero address");
        require(_adminMultisig != address(0), "SachetMarket: Zero address");
        sachetMarketToken = IERC20(_sachetMarketToken);
        _grantRole(DEFAULT_ADMIN_ROLE, _adminMultisig);
        _grantRole(ADMIN_ROLE, _adminMultisig);
    }

    function pause() external onlyRole(ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }

    function launchPool(bytes32 poolId, uint64 expiresAt) external onlyRole(ADMIN_ROLE) {
        require(expiresAt > block.timestamp, "SachetMarket: expiresAt in past");
        require(expiresAt <= block.timestamp + MAX_POOL_DURATION, "SachetMarket: expiresAt exceeds max duration");
        require(pools[poolId].expiresAt == 0, "SachetMarket: pool already exists");

        Pool storage r = pools[poolId];
        r.expiresAt = expiresAt;
        r.status = PoolStatus.OPEN;
        // Other fields default to 0/UNSET

        emit PoolLaunched(poolId, expiresAt);
    }

    function placeBet(bytes32 poolId, Outcome outcome, uint256 amount) external nonReentrant whenNotPaused {
        Pool storage r = pools[poolId];
        require(r.expiresAt != 0, "SachetMarket: pool does not exist");
        require(block.timestamp < r.expiresAt, "SachetMarket: pool closed");
        require(r.status == PoolStatus.OPEN, "SachetMarket: pool not open");
        require(outcome != Outcome.UNSET, "SachetMarket: invalid outcome");
        require(amount > 0, "SachetMarket: amount must be > 0");

        Bet storage b = bets[poolId][msg.sender];
        require(b.amount == 0, "SachetMarket: already bet this pool");

        uint256 balanceBefore = sachetMarketToken.balanceOf(address(this));
        sachetMarketToken.safeTransferFrom(msg.sender, address(this), amount);
        uint256 receivedAmount = sachetMarketToken.balanceOf(address(this)) - balanceBefore;
        require(receivedAmount > 0, "SachetMarket: received amount must be > 0");

        b.amount = receivedAmount;
        b.outcome = outcome;
        b.withdrawn = false;
        b.claimed = false;

        if (outcome == Outcome.HOME) {
            r.poolHome += receivedAmount;
        } else if (outcome == Outcome.DRAW) {
            r.poolDraw += receivedAmount;
        } else if (outcome == Outcome.AWAY) {
            r.poolAway += receivedAmount;
        }

        r.totalPool += receivedAmount;

        emit BetPlaced(poolId, msg.sender, outcome, receivedAmount);
    }

    function withdrawBet(bytes32 poolId) external nonReentrant {
        Pool storage r = pools[poolId];
        require(block.timestamp < r.expiresAt, "SachetMarket: too late to withdraw");
        require(r.status == PoolStatus.OPEN, "SachetMarket: pool not open");

        Bet storage b = bets[poolId][msg.sender];
        require(b.amount > 0 && !b.withdrawn, "SachetMarket: no active bet");

        uint256 amountToReturn = b.amount;
        
        if (b.outcome == Outcome.HOME) {
            r.poolHome -= amountToReturn;
        } else if (b.outcome == Outcome.DRAW) {
            r.poolDraw -= amountToReturn;
        } else if (b.outcome == Outcome.AWAY) {
            r.poolAway -= amountToReturn;
        }

        r.totalPool -= amountToReturn;
        
        b.withdrawn = true;
        
        sachetMarketToken.safeTransfer(msg.sender, amountToReturn);
        
        emit BetWithdrawn(poolId, msg.sender, amountToReturn);
    }

    function resolvePool(bytes32 poolId, Outcome result) external onlyRole(RESOLVER_ROLE) {
        Pool storage r = pools[poolId];
        require(r.expiresAt != 0, "SachetMarket: pool does not exist");
        require(block.timestamp >= r.expiresAt, "SachetMarket: pool still open");
        require(r.status == PoolStatus.OPEN, "SachetMarket: already resolved/cancelled");
        require(result != Outcome.UNSET, "SachetMarket: invalid result");

        r.status = PoolStatus.RESOLVED;
        r.result = result;

        emit PoolResolved(poolId, result);
    }

    function cancelPool(bytes32 poolId) external onlyRole(ADMIN_ROLE) {
        Pool storage r = pools[poolId];
        require(r.expiresAt != 0, "SachetMarket: pool does not exist");
        require(r.status == PoolStatus.OPEN, "SachetMarket: pool not open");
        
        r.status = PoolStatus.CANCELLED;
        
        emit PoolCancelled(poolId);
    }

    function claim(bytes32 poolId) external nonReentrant {
        Pool storage r = pools[poolId];
        require(
            r.status == PoolStatus.RESOLVED || r.status == PoolStatus.CANCELLED,
            "not resolved or cancelled"
        );

        Bet storage b = bets[poolId][msg.sender];
        require(b.amount > 0 && !b.withdrawn, "SachetMarket: no claimable bet");
        require(!b.claimed, "SachetMarket: already claimed");

        uint256 payout = 0;

        if (r.status == PoolStatus.CANCELLED) {
            payout = b.amount;
        } else {
            // RESOLVED
            Outcome result = r.result;
            uint256 winningPool;

            if (result == Outcome.HOME) {
                winningPool = r.poolHome;
            } else if (result == Outcome.DRAW) {
                winningPool = r.poolDraw;
            } else if (result == Outcome.AWAY) {
                winningPool = r.poolAway;
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
            sachetMarketToken.safeTransfer(msg.sender, payout);
        }

        emit Claimed(poolId, msg.sender, payout);
    }

    function sweepDust(bytes32 poolId, address to) external onlyRole(ADMIN_ROLE) {
        Pool storage r = pools[poolId];
        require(r.status == PoolStatus.RESOLVED || r.status == PoolStatus.CANCELLED, "SachetMarket: not resolved or cancelled");
        require(block.timestamp >= r.expiresAt + 90 days, "SachetMarket: claim window still open");
        
        // This is safe because totalClaimed can only be at most totalPool in RESOLVED/CANCELLED.
        uint256 dust = r.totalPool - r.totalClaimed;
        require(dust > 0, "SachetMarket: no dust to sweep");
        
        r.totalClaimed = r.totalPool; // Prevent double sweeping
        
        sachetMarketToken.safeTransfer(to, dust);
    }

    function getPool(bytes32 poolId) external view returns (Pool memory) {
        return pools[poolId];
    }

    function getUserStake(bytes32 poolId, address user) external view returns (Bet memory) {
        return bets[poolId][user];
    }
}
