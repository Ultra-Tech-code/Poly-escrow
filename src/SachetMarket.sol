// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

/**
 * @title SachetMarket
 * @notice A decentralized pari-mutuel betting protocol.
 * @dev Inherits from AccessControl, ReentrancyGuard, and Pausable.
 */
contract SachetMarket is AccessControl, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    /// @notice Role designated for platform administration
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    /// @notice Role designated for providing the real-world outcome of a pool
    bytes32 public constant RESOLVER_ROLE = keccak256("RESOLVER_ROLE");

    /**
     * @notice Possible outcomes for a bet or a pool result
     * @dev UNSET is default, VOID results in a full refund.
     */
    enum Outcome { UNSET, HOME, DRAW, AWAY, VOID }

    /**
     * @notice The current status of a betting pool
     */
    enum PoolStatus { OPEN, LOCKED, RESOLVED, CANCELLED }

    /**
     * @notice Data structure defining a betting pool
     * @param expiresAt The timestamp when betting locks and the event is presumed to start
     * @param status The current operational status of the pool
     * @param result The final outcome of the pool, set by a resolver
     * @param poolHome Total tokens wagered on the HOME outcome
     * @param poolDraw Total tokens wagered on the DRAW outcome
     * @param poolAway Total tokens wagered on the AWAY outcome
     * @param totalPool The total aggregated tokens wagered across all outcomes
     * @param totalClaimed Tracks total payouts to securely sweep unclaimed dust
     */
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

    /**
     * @notice Data structure representing a user's bet in a specific pool
     * @param amount The number of tokens wagered
     * @param outcome The outcome the user bet on
     * @param withdrawn True if the user withdrew their bet before the pool locked
     * @param claimed True if the user successfully claimed their winnings or refund
     */
    struct Bet {
        uint256 amount;
        Outcome outcome;
        bool withdrawn;
        bool claimed;
    }

    /// @notice Mapping of pool IDs to their respective Pool configurations
    mapping(bytes32 => Pool) public pools;
    /// @notice Mapping of pool IDs to user addresses to their respective Bets
    mapping(bytes32 => mapping(address => Bet)) public bets;

    /// @notice The ERC20 token currently configured for wagering
    IERC20 public sachetMarketToken;

    // Custom Errors
    /// @notice Thrown when a user attempts to place a bet in a pool they have already bet on
    error AlreadyBetThisPool();
    /// @notice Thrown when a user attempts to claim a payout more than once
    error AlreadyClaimed();
    /// @notice Thrown when an admin/resolver attempts an action on a pool that is already finalized
    error AlreadyResolvedOrCancelled();
    /// @notice Thrown when a bet is attempted with an amount of 0
    error AmountMustBeGreaterThan0();
    /// @notice Thrown when an admin attempts to sweep dust before the 90-day claim window closes
    error ClaimWindowStillOpen();
    /// @notice Thrown when launching a pool with an expiry too far into the future
    error ExpiresatExceedsMaxDuration();
    /// @notice Thrown when launching a pool with a past expiry
    error ExpiresatInPast();
    /// @notice Thrown when an invalid outcome is selected (e.g., betting on UNSET or VOID)
    error InvalidOutcome();
    /// @notice Thrown when a resolver attempts to resolve a pool with an invalid result
    error InvalidResult();
    /// @notice Thrown when a user attempts to withdraw a bet they haven't placed
    error NoActiveBet();
    /// @notice Thrown when a user attempts to claim but has no winning or refundable bet
    error NoClaimableBet();
    /// @notice Thrown when there is no dust left to sweep from a pool
    error NoDustToSweep();
    /// @notice Thrown when attempting an action that requires the pool to be RESOLVED or CANCELLED
    error NotResolvedOrCancelled();
    /// @notice Thrown when an admin attempts to launch a pool ID that is already in use
    error PoolAlreadyExists();
    /// @notice Thrown when a user attempts to bet on a pool that has passed its expiry
    error PoolClosed();
    /// @notice Thrown when attempting to interact with a pool that does not exist
    error PoolDoesNotExist();
    /// @notice Thrown when attempting an action that requires the pool to be OPEN
    error PoolNotOpen();
    /// @notice Thrown when attempting to resolve a pool before its expiry time
    error PoolStillOpen();
    /// @notice Thrown when the tokens received by the contract for a bet are 0 (e.g., due to fees)
    error ReceivedAmountMustBeGreaterThan0();
    /// @notice Thrown when a user attempts to withdraw a bet after the pool has locked
    error TooLateToWithdraw();
    /// @notice Thrown when a zero address is provided for critical roles or tokens
    error ZeroAddress();
    /// @notice Thrown when an admin attempts to withdraw more treasury tokens than available
    error AmountExceedsBalance();

    /// @notice Maximum allowed duration between pool creation and expiry
    uint256 public constant MAX_POOL_DURATION = 30 days;

    // Events
    /// @notice Emitted when a new betting pool is created
    event PoolLaunched(bytes32 indexed poolId, uint64 expiresAt);
    /// @notice Emitted when a user places a valid bet
    event BetPlaced(bytes32 indexed poolId, address indexed user, Outcome outcome, uint256 amount);
    /// @notice Emitted when a user successfully withdraws a bet before the lock time
    event BetWithdrawn(bytes32 indexed poolId, address indexed user, uint256 amount);
    /// @notice Emitted when a pool is finalized by a resolver
    event PoolResolved(bytes32 indexed poolId, Outcome result);
    /// @notice Emitted when a pool is emergency cancelled by an admin
    event PoolCancelled(bytes32 indexed poolId);
    /// @notice Emitted when a user claims their winnings or refund
    event Claimed(bytes32 indexed poolId, address indexed user, uint256 payout);
    /// @notice Emitted when the betting token is updated by an admin
    event TokenUpdated(address indexed oldToken, address indexed newToken);
    /// @notice Emitted when the treasury withdraws funds from the contract
    event TreasuryWithdrawn(address indexed token, address indexed to, uint256 amount);


    /**
     * @notice Initializes the SachetMarket contract.
     * @param _sachetMarketToken The address of the ERC20 token used for betting.
     * @param _adminMultisig The address to be granted DEFAULT_ADMIN_ROLE and ADMIN_ROLE.
     */
    constructor(address _sachetMarketToken, address _adminMultisig) {
        if (!(_sachetMarketToken != address(0))) revert ZeroAddress();
        if (!(_adminMultisig != address(0))) revert ZeroAddress();
        sachetMarketToken = IERC20(_sachetMarketToken);
        _grantRole(DEFAULT_ADMIN_ROLE, _adminMultisig);
        _grantRole(ADMIN_ROLE, _adminMultisig);
    }


    /**
     * @notice Pauses the contract, disabling new bets.
     * @dev Only callable by accounts with the ADMIN_ROLE.
     */
    function pause() external onlyRole(ADMIN_ROLE) {
        _pause();
    }


    /**
     * @notice Unpauses the contract, enabling new bets.
     * @dev Only callable by accounts with the ADMIN_ROLE.
     */
    function unpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }


    /**
     * @notice Creates a new betting pool.
     * @param poolId The unique identifier for the pool.
     * @param expiresAt The timestamp after which no more bets can be placed.
     * @dev Only callable by accounts with the ADMIN_ROLE.
     */
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


    /**
     * @notice Places a bet on a specific outcome in a pool.
     * @param poolId The unique identifier for the pool.
     * @param outcome The predicted outcome (HOME, DRAW, or AWAY).
     * @param amount The amount of tokens to bet.
     */
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


    /**
     * @notice Withdraws a previously placed bet before the pool expires.
     * @param poolId The unique identifier for the pool.
     */
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


    /**
     * @notice Resolves a pool with the final outcome.
     * @param poolId The unique identifier for the pool.
     * @param result The actual real-world outcome of the event.
     * @dev Only callable by accounts with the RESOLVER_ROLE.
     */
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


    /**
     * @notice Cancels a pool, allowing all users to claim a full refund. Emergency Switch
     * @param poolId The unique identifier for the pool.
     * @dev Only callable by accounts with the ADMIN_ROLE.
     */
    function cancelPool(bytes32 poolId) external onlyRole(ADMIN_ROLE) {
        Pool storage r = pools[poolId];
        if (!(r.expiresAt != 0)) revert PoolDoesNotExist();
        if (!(r.status == PoolStatus.OPEN)) revert PoolNotOpen();
        
        r.status = PoolStatus.CANCELLED;
        
        emit PoolCancelled(poolId);
    }


    /**
     * @notice Claims the payout or refund for a resolved or cancelled pool.
     * @param poolId The unique identifier for the pool.
     */
    function claim(bytes32 poolId) external nonReentrant {
        Pool storage r = pools[poolId];
        if (!(r.status == PoolStatus.RESOLVED || r.status == PoolStatus.CANCELLED)) revert NotResolvedOrCancelled();

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


    /**
     * @notice Updates the ERC20 token used for the market.
     * @param newToken The address of the new ERC20 token.
     * @dev Only callable by accounts with the ADMIN_ROLE when the contract is paused.
     */
    function updateToken(address newToken) external onlyRole(ADMIN_ROLE) whenPaused {
        if (!(newToken != address(0))) revert ZeroAddress();
        address oldToken = address(sachetMarketToken);
        sachetMarketToken = IERC20(newToken);
        emit TokenUpdated(oldToken, newToken);
    }


    /**
     * @notice Withdraws tokens held in the contract to a specified address.
     * @param token The address of the ERC20 token to withdraw.
     * @param to The destination address for the tokens.
     * @param amount The amount of tokens to withdraw (use type(uint256).max for full balance).
     * @dev Only callable by accounts with the ADMIN_ROLE.
     */
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


    /**
     * @notice Retrieves the full state of a specific pool.
     * @param poolId The unique identifier for the pool.
     * @return The Pool struct containing all pool details.
     */
    function getPool(bytes32 poolId) external view returns (Pool memory) {
        return pools[poolId];
    }

    
    /**
     * @notice Retrieves the bet details for a specific user in a pool.
     * @param poolId The unique identifier for the pool.
     * @param user The address of the user.
     * @return The Bet struct containing the user's bet details.
     */
    function getUserStake(bytes32 poolId, address user) external view returns (Bet memory) {
        return bets[poolId][user];
    }
}
