// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IServiceRegistry
/// @notice Minimal surface that PayPerCall depends on. Keeping this as an
///         interface means PayPerCall doesn't need the full ServiceRegistry
///         implementation at compile time.
interface IServiceRegistry {
    struct ProviderView {
        address owner;
        address signer;
        uint256 stake;
        uint256 pricePerCall;
        uint32 maxResponseTime;
        uint32 slashBps;
        bool active;
    }

    function getProvider(uint256 providerId) external view returns (ProviderView memory);

    function slash(uint256 providerId, uint256 amount, address recipient) external;

    function markCallStarted(uint256 providerId) external;

    function markCallFinished(uint256 providerId) external;

    /// @notice Called by PayPerCall on successful receipt submission.
    function incCompleted(uint256 providerId) external;

    /// @notice Called by PayPerCall when a call is slashed due to timeout.
    function incSlashed(uint256 providerId) external;
}
