// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import { IServiceRegistry } from "./interfaces/IServiceRegistry.sol";

/// @title PayPerCall
/// @notice Escrow USDC per service call. Provider commits to an SLA by
///         signing a receipt that hashes `(callId, responseHash)`. A valid
///         receipt transfers the escrow to the provider; a timeout without
///         a receipt refunds the caller and slashes the provider's stake.
///
/// @dev    Signing flow — providers MUST sign using the eth_sign / EIP-191
///         "\x19Ethereum Signed Message:\n32" prefix. This matches what
///         `personal_sign` in browser wallets produces by default.
contract PayPerCall is ReentrancyGuard {
    using SafeERC20 for IERC20;
    using MessageHashUtils for bytes32;

    // ---------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------

    error ProviderNotActive();
    error InvalidStatus();
    error DeadlineExceeded();
    error DeadlineNotReached();
    error InvalidSignature();
    error CallIdCollision();

    // ---------------------------------------------------------------------
    // Types
    // ---------------------------------------------------------------------

    enum CallStatus {
        None,
        Pending,
        Completed,
        Slashed
    }

    struct Call {
        uint256 providerId;
        address caller;
        uint256 amount;
        uint32 startedAt;
        uint32 deadline;
        bytes32 requestHash;
        bytes32 responseHash;
        CallStatus status;
    }

    // ---------------------------------------------------------------------
    // State
    // ---------------------------------------------------------------------

    IERC20 public immutable usdc;
    IServiceRegistry public immutable registry;

    mapping(bytes32 => Call) internal _calls;
    uint256 public nonce; // bumped on every call to keep callIds unique

    // ---------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------

    event CallStarted(
        bytes32 indexed callId,
        uint256 indexed providerId,
        address indexed caller,
        uint256 amount,
        bytes32 requestHash,
        uint32 deadline
    );
    event ReceiptSubmitted(bytes32 indexed callId, bytes32 responseHash);
    event CallSlashed(bytes32 indexed callId, uint256 refunded, uint256 slashed);

    // ---------------------------------------------------------------------
    // Constructor
    // ---------------------------------------------------------------------

    constructor(IERC20 _usdc, IServiceRegistry _registry) {
        usdc = _usdc;
        registry = _registry;
    }

    // ---------------------------------------------------------------------
    // Open a call
    // ---------------------------------------------------------------------

    function callService(uint256 providerId, bytes32 requestHash) external nonReentrant returns (bytes32 callId) {
        IServiceRegistry.ProviderView memory p = registry.getProvider(providerId);
        if (!p.active) revert ProviderNotActive();

        uint256 currentNonce = nonce++;
        callId = keccak256(
            abi.encodePacked(providerId, msg.sender, currentNonce, block.timestamp, requestHash, block.chainid)
        );
        if (_calls[callId].status != CallStatus.None) revert CallIdCollision();

        uint32 deadline = uint32(block.timestamp) + p.maxResponseTime;

        _calls[callId] = Call({
            providerId: providerId,
            caller: msg.sender,
            amount: p.pricePerCall,
            startedAt: uint32(block.timestamp),
            deadline: deadline,
            requestHash: requestHash,
            responseHash: bytes32(0),
            status: CallStatus.Pending
        });

        // Pull USDC into escrow BEFORE notifying the registry — if the
        // transfer fails, pendingCalls doesn't drift.
        usdc.safeTransferFrom(msg.sender, address(this), p.pricePerCall);
        registry.markCallStarted(providerId);

        emit CallStarted(callId, providerId, msg.sender, p.pricePerCall, requestHash, deadline);
    }

    // ---------------------------------------------------------------------
    // Close a call — happy path
    // ---------------------------------------------------------------------

    function submitReceipt(bytes32 callId, bytes32 responseHash, bytes calldata signature) external nonReentrant {
        Call storage c = _calls[callId];
        if (c.status != CallStatus.Pending) revert InvalidStatus();
        if (block.timestamp > c.deadline) revert DeadlineExceeded();

        // EIP-191 prefixed digest — matches personal_sign / eth_sign.
        bytes32 digest = keccak256(abi.encodePacked(callId, responseHash)).toEthSignedMessageHash();
        address signer = ECDSA.recover(digest, signature);

        IServiceRegistry.ProviderView memory p = registry.getProvider(c.providerId);
        if (signer != p.signer) revert InvalidSignature();

        // Effects before interactions.
        c.responseHash = responseHash;
        c.status = CallStatus.Completed;

        registry.markCallFinished(c.providerId);
        registry.incCompleted(c.providerId); // bump reputation
        usdc.safeTransfer(p.owner, c.amount);

        emit ReceiptSubmitted(callId, responseHash);
    }

    // ---------------------------------------------------------------------
    // Close a call — timeout path
    // ---------------------------------------------------------------------

    function claimTimeout(bytes32 callId) external nonReentrant {
        Call storage c = _calls[callId];
        if (c.status != CallStatus.Pending) revert InvalidStatus();
        if (block.timestamp <= c.deadline) revert DeadlineNotReached();

        c.status = CallStatus.Slashed;

        IServiceRegistry.ProviderView memory p = registry.getProvider(c.providerId);
        uint256 slashAmount = (p.stake * p.slashBps) / 10_000;

        // Order matters:
        //   1. Mark pending call finished first (so the registry's accounting is clean
        //      before any external transfer).
        //   2. Bump reputation counter.
        //   3. Refund the caller from escrow.
        //   4. Slash stake (registry does its own transfer).
        registry.markCallFinished(c.providerId);
        registry.incSlashed(c.providerId);
        usdc.safeTransfer(c.caller, c.amount);

        if (slashAmount > 0) {
            registry.slash(c.providerId, slashAmount, c.caller);
        }

        emit CallSlashed(callId, c.amount, slashAmount);
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    function getCall(bytes32 callId) external view returns (Call memory) {
        return _calls[callId];
    }
}
