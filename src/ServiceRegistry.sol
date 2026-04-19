// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import { IServiceRegistry } from "./interfaces/IServiceRegistry.sol";

/// @title ServiceRegistry
/// @notice On-chain catalog of service providers. Providers stake USDC to
///         register and commit to SLA parameters (max response time, slash %).
///         The PayPerCall contract is the only party allowed to slash — it
///         does so when a call times out without a receipt.
///
/// @dev    Arc Testnet's USDC uses 6 decimals via the ERC-20 interface at
///         0x3600000000000000000000000000000000000000. This contract only
///         talks to USDC through that interface.
contract ServiceRegistry is IServiceRegistry, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ---------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------

    error AlreadyRegistered();
    error NotOwner();
    error BelowMinStake();
    error InvalidSlashBps();
    error InvalidResponseTime();
    error InvalidSigner();
    error ProviderInactive();
    error StillActive();
    error PendingCalls();
    error CooldownNotElapsed();
    error OnlyPayPerCall();
    error UnknownProvider();
    error InsufficientStake();

    // ---------------------------------------------------------------------
    // Constants
    // ---------------------------------------------------------------------

    uint32 public constant MIN_RESPONSE_TIME = 5; // seconds
    uint32 public constant MAX_SLASH_BPS = 10_000;
    uint32 public constant UNSTAKE_COOLDOWN = 1 hours;

    // ---------------------------------------------------------------------
    // State
    // ---------------------------------------------------------------------

    struct Provider {
        address owner;
        address signer;
        uint256 stake;
        uint256 pricePerCall;
        uint32 maxResponseTime;
        uint32 slashBps;
        uint32 deactivatedAt; // 0 = active
        uint32 pendingCalls; // open calls not yet finalized
        uint32 completedCalls; // reputation: successful receipts submitted
        uint32 slashedCalls; // reputation: SLA violations enforced
        string endpoint;
        bool active;
    }

    IERC20 public immutable usdc;
    uint256 public immutable minStake;
    address public payPerCall; // set once by owner via `setPayPerCall`
    address public admin;

    mapping(uint256 => Provider) internal _providers;
    mapping(address => uint256) public providerIdOf; // owner => id, 0 = none
    uint256 public nextProviderId = 1;

    // ---------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------

    event ProviderRegistered(
        uint256 indexed providerId,
        address indexed owner,
        address signer,
        uint256 stake,
        uint256 pricePerCall,
        uint32 maxResponseTime,
        uint32 slashBps,
        string endpoint
    );
    event ProviderDeactivated(uint256 indexed providerId, uint32 deactivatedAt);
    event ProviderUnstaked(uint256 indexed providerId, uint256 amount);
    event ProviderSlashed(uint256 indexed providerId, uint256 amount, address recipient);
    event PriceUpdated(uint256 indexed providerId, uint256 newPrice);
    event SignerUpdated(uint256 indexed providerId, address newSigner);
    event PayPerCallSet(address indexed payPerCall);
    event ReputationUpdated(uint256 indexed providerId, uint32 completedCalls, uint32 slashedCalls);

    // ---------------------------------------------------------------------
    // Modifiers
    // ---------------------------------------------------------------------

    modifier onlyPayPerCall() {
        if (msg.sender != payPerCall) revert OnlyPayPerCall();
        _;
    }

    modifier onlyAdmin() {
        if (msg.sender != admin) revert NotOwner();
        _;
    }

    // ---------------------------------------------------------------------
    // Constructor
    // ---------------------------------------------------------------------

    constructor(IERC20 _usdc, uint256 _minStake) {
        usdc = _usdc;
        minStake = _minStake;
        admin = msg.sender;
    }

    /// @notice One-time wire-up of the PayPerCall contract address. Admin
    ///         sets this right after deploying PayPerCall. Cannot be changed
    ///         after first set — prevents rug-pull where admin swaps the
    ///         slasher to a malicious contract.
    function setPayPerCall(address _payPerCall) external onlyAdmin {
        if (payPerCall != address(0)) revert("already set");
        payPerCall = _payPerCall;
        emit PayPerCallSet(_payPerCall);
    }

    // ---------------------------------------------------------------------
    // Provider lifecycle
    // ---------------------------------------------------------------------

    function register(
        address signer,
        uint256 stakeAmount,
        uint256 pricePerCall_,
        uint32 maxResponseTime,
        uint32 slashBps,
        string calldata endpoint
    ) external nonReentrant returns (uint256 providerId) {
        if (providerIdOf[msg.sender] != 0) revert AlreadyRegistered();
        if (stakeAmount < minStake) revert BelowMinStake();
        if (slashBps > MAX_SLASH_BPS) revert InvalidSlashBps();
        if (maxResponseTime < MIN_RESPONSE_TIME) revert InvalidResponseTime();
        if (signer == address(0)) revert InvalidSigner();

        providerId = nextProviderId++;
        _providers[providerId] = Provider({
            owner: msg.sender,
            signer: signer,
            stake: stakeAmount,
            pricePerCall: pricePerCall_,
            maxResponseTime: maxResponseTime,
            slashBps: slashBps,
            deactivatedAt: 0,
            pendingCalls: 0,
            completedCalls: 0,
            slashedCalls: 0,
            endpoint: endpoint,
            active: true
        });
        providerIdOf[msg.sender] = providerId;

        usdc.safeTransferFrom(msg.sender, address(this), stakeAmount);

        emit ProviderRegistered(
            providerId, msg.sender, signer, stakeAmount, pricePerCall_, maxResponseTime, slashBps, endpoint
        );
    }

    function deactivate(uint256 providerId) external {
        Provider storage p = _providers[providerId];
        if (p.owner != msg.sender) revert NotOwner();
        if (!p.active) revert ProviderInactive();

        p.active = false;
        p.deactivatedAt = uint32(block.timestamp);

        emit ProviderDeactivated(providerId, p.deactivatedAt);
    }

    function unstake(uint256 providerId) external nonReentrant {
        Provider storage p = _providers[providerId];
        if (p.owner != msg.sender) revert NotOwner();
        if (p.active) revert StillActive();
        if (p.pendingCalls != 0) revert PendingCalls();
        if (block.timestamp < p.deactivatedAt + UNSTAKE_COOLDOWN) {
            revert CooldownNotElapsed();
        }

        uint256 amount = p.stake;
        p.stake = 0;

        usdc.safeTransfer(msg.sender, amount);
        emit ProviderUnstaked(providerId, amount);
    }

    // ---------------------------------------------------------------------
    // PayPerCall hooks
    // ---------------------------------------------------------------------

    function slash(uint256 providerId, uint256 amount, address recipient) external onlyPayPerCall nonReentrant {
        Provider storage p = _providers[providerId];
        if (p.owner == address(0)) revert UnknownProvider();
        if (p.stake < amount) revert InsufficientStake();

        p.stake -= amount;
        usdc.safeTransfer(recipient, amount);

        emit ProviderSlashed(providerId, amount, recipient);
    }

    /// @notice Called by PayPerCall when a call opens. Blocks unstake until
    ///         the matching `markCallFinished` fires.
    function markCallStarted(uint256 providerId) external onlyPayPerCall {
        Provider storage p = _providers[providerId];
        if (p.owner == address(0)) revert UnknownProvider();
        unchecked {
            p.pendingCalls += 1;
        }
    }

    function markCallFinished(uint256 providerId) external onlyPayPerCall {
        Provider storage p = _providers[providerId];
        // If somehow this is called without a matching start, don't underflow —
        // revert explicitly so the bug is visible.
        if (p.pendingCalls == 0) revert("no pending");
        unchecked {
            p.pendingCalls -= 1;
        }
    }

    /// @notice Called by PayPerCall after a successful receipt submission.
    function incCompleted(uint256 providerId) external onlyPayPerCall {
        Provider storage p = _providers[providerId];
        if (p.owner == address(0)) revert UnknownProvider();
        unchecked {
            p.completedCalls += 1;
        }
        emit ReputationUpdated(providerId, p.completedCalls, p.slashedCalls);
    }

    /// @notice Called by PayPerCall when a call is slashed.
    function incSlashed(uint256 providerId) external onlyPayPerCall {
        Provider storage p = _providers[providerId];
        if (p.owner == address(0)) revert UnknownProvider();
        unchecked {
            p.slashedCalls += 1;
        }
        emit ReputationUpdated(providerId, p.completedCalls, p.slashedCalls);
    }

    // ---------------------------------------------------------------------
    // Owner-configurable fields
    // ---------------------------------------------------------------------

    function updatePrice(uint256 providerId, uint256 newPrice) external {
        Provider storage p = _providers[providerId];
        if (p.owner != msg.sender) revert NotOwner();
        p.pricePerCall = newPrice;
        emit PriceUpdated(providerId, newPrice);
    }

    function updateSigner(uint256 providerId, address newSigner) external {
        if (newSigner == address(0)) revert InvalidSigner();
        Provider storage p = _providers[providerId];
        if (p.owner != msg.sender) revert NotOwner();
        p.signer = newSigner;
        emit SignerUpdated(providerId, newSigner);
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    function getProvider(uint256 providerId) external view returns (ProviderView memory) {
        Provider storage p = _providers[providerId];
        return ProviderView({
            owner: p.owner,
            signer: p.signer,
            stake: p.stake,
            pricePerCall: p.pricePerCall,
            maxResponseTime: p.maxResponseTime,
            slashBps: p.slashBps,
            active: p.active
        });
    }

    function getEndpoint(uint256 providerId) external view returns (string memory) {
        return _providers[providerId].endpoint;
    }

    function pendingCalls(uint256 providerId) external view returns (uint32) {
        return _providers[providerId].pendingCalls;
    }

    // ---------------------------------------------------------------------
    // Reputation
    // ---------------------------------------------------------------------

    /// @notice Bayesian reputation score on a 0-100 scale.
    /// @dev    Uses a prior of (α=2 successes, β=1 failure), so a fresh
    ///         provider starts at ≈66 and the score only stabilizes after
    ///         many calls. This avoids giving spammers a perfect score for a
    ///         single successful call.
    ///
    ///         score = (completed + α) / (completed + slashed + α + β) × 100
    ///
    ///         Examples (α=2, β=1):
    ///           0 completed, 0 slashed  → 66
    ///           1 completed, 0 slashed  → 75
    ///          10 completed, 0 slashed  → 92
    ///           5 completed, 1 slashed  → 78
    ///           0 completed, 1 slashed  → 50
    function getReputationScore(uint256 providerId) external view returns (uint8) {
        Provider storage p = _providers[providerId];
        if (p.owner == address(0)) return 0;
        uint256 alpha = 2;
        uint256 beta = 1;
        uint256 numerator = uint256(p.completedCalls) + alpha;
        uint256 denominator = uint256(p.completedCalls) + uint256(p.slashedCalls) + alpha + beta;
        // denominator is always at least 3 (the prior), so divide is safe.
        return uint8((numerator * 100) / denominator);
    }

    /// @notice Raw completed counter for off-chain UIs.
    function completedCalls(uint256 providerId) external view returns (uint32) {
        return _providers[providerId].completedCalls;
    }

    /// @notice Raw slashed counter for off-chain UIs.
    function slashedCalls(uint256 providerId) external view returns (uint32) {
        return _providers[providerId].slashedCalls;
    }
}
