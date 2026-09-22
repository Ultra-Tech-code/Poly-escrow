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

    IERC20 public sachetMarketToken;

    error AlreadyBetThisPool();
    error AlreadyClaimed();
    error AlreadyResolvedOrCancelled();
    error AmountMustBeGreaterThan0();
    error ClaimWindowStillOpen();
    error ExpiresatExceedsMaxDuration();
    error ExpiresatInPast();
    error InvalidOutcome();
    error InvalidResult();
    error NoActiveBet();
    error NoClaimableBet();
    error NoDustToSweep();
    error NotResolvedOrCancelled();
    error PoolAlreadyExists();
    error PoolClosed();
    error PoolDoesNotExist();
    error PoolNotOpen();
    error PoolStillOpen();
    error ReceivedAmountMustBeGreaterThan0();
    error TooLateToWithdraw();
    error ZeroAddress();
    error AmountExceedsBalance();

    uint256 public constant MAX_POOL_DURATION = 30 days;

    event PoolLaunched(bytes32 indexed poolId, uint64 expiresAt);
    event BetPlaced(bytes32 indexed poolId, address indexed user, Outcome outcome, uint256 amount);
    event BetWithdrawn(bytes32 indexed poolId, address indexed user, uint256 amount);
    event PoolResolved(bytes32 indexed poolId, Outcome result);
    event PoolCancelled(bytes32 indexed poolId);
    event Claimed(bytes32 indexed poolId, address indexed user, uint256 payout);
    event TokenUpdated(address indexed oldToken, address indexed newToken);
    event TreasuryWithdrawn(address indexed token, address indexed to, uint256 amount);

    constructor(address _sachetMarketToken, address _adminMultisig) {
        if (!(_sachetMarketToken != address(0))) revert ZeroAddress();
        if (!(_adminMultisig != address(0))) revert ZeroAddress();
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
        if (!(expiresAt > block.timestamp)) revert ExpiresatInPast();
        if (!(expiresAt <= block.timestamp + MAX_POOL_DURATION)) revert ExpiresatExceedsMaxDuration();
        if (!(pools[poolId].expiresAt == 0)) revert PoolAlreadyExists();

        Pool storage r = pools[poolId];
        r.expiresAt = expiresAt;
        r.status = PoolStatus.OPEN;
        // Other fields default to 0/UNSET

        emit PoolLaunched(poolId, expiresAt);
    }

    function placeBet(bytes32 poolId, Outcome outcome, uint256 amount) external nonReentrant whenNotPaused {
        Pool storage r = pools[poolId];
        if (!(r.expiresAt != 0)) revert PoolDoesNotExist();
        if (!(block.timestamp < r.expiresAt)) revert PoolClosed();
        if (!(r.status == PoolStatus.OPEN)) revert PoolNotOpen();
        if (!(outcome != Outcome.UNSET && outcome != Outcome.VOID)) revert InvalidOutcome();
        if (!(amount > 0)) revert AmountMustBeGreaterThan0();

        Bet storage b = bets[poolId][msg.sender];
        if (!(b.amount == 0)) revert AlreadyBetThisPool();

        uint256 balanceBefore = sachetMarketToken.balanceOf(address(this));
        sachetMarketToken.safeTransferFrom(msg.sender, address(this), amount);
        uint256 receivedAmount = sachetMarketToken.balanceOf(address(this)) - balanceBefore;
        if (!(receivedAmount > 0)) revert ReceivedAmountMustBeGreaterThan0();

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
        if (!(block.timestamp < r.expiresAt)) revert TooLateToWithdraw();
        if (!(r.status == PoolStatus.OPEN)) revert PoolNotOpen();

        Bet storage b = bets[poolId][msg.sender];
        if (!(b.amount > 0 && !b.withdrawn)) revert NoActiveBet();

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
        if (!(r.expiresAt != 0)) revert PoolDoesNotExist();
        if (!(block.timestamp >= r.expiresAt)) revert PoolStillOpen();
        if (!(r.status == PoolStatus.OPEN)) revert AlreadyResolvedOrCancelled();
        if (!(result != Outcome.UNSET)) revert InvalidResult();

        r.status = PoolStatus.RESOLVED;
        r.result = result;

        emit PoolResolved(poolId, result);
    }

    function cancelPool(bytes32 poolId) external onlyRole(ADMIN_ROLE) {
        Pool storage r = pools[poolId];
        if (!(r.expiresAt != 0)) revert PoolDoesNotExist();
        if (!(r.status == PoolStatus.OPEN)) revert PoolNotOpen();
        
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
        if (!(b.amount > 0 && !b.withdrawn)) revert NoClaimableBet();
        if (!(!b.claimed)) revert AlreadyClaimed();

        uint256 payout = 0;

        if (r.status == PoolStatus.CANCELLED || r.result == Outcome.VOID) {
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

    function updateToken(address newToken) external onlyRole(ADMIN_ROLE) whenPaused {
        if (!(newToken != address(0))) revert ZeroAddress();
        address oldToken = address(sachetMarketToken);
        sachetMarketToken = IERC20(newToken);
        emit TokenUpdated(oldToken, newToken);
    }

    function withdrawTreasury(address token, address to, uint256 amount) external onlyRole(ADMIN_ROLE) {
        if (!(to != address(0))) revert ZeroAddress();
        
        uint256 bal = IERC20(token).balanceOf(address(this));
        if (amount == type(uint256).max) {
            amount = bal;
        } else if (amount > bal) {
            revert AmountExceedsBalance();
        }
        
        if (amount > 0) {
            IERC20(token).safeTransfer(to, amount);
            emit TreasuryWithdrawn(token, to, amount);
        }
    }

    function getPool(bytes32 poolId) external view returns (Pool memory) {
        return pools[poolId];
    }

    function getUserStake(bytes32 poolId, address user) external view returns (Bet memory) {
        return bets[poolId][user];
    }
}
