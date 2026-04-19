// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title MockUSDC
/// @notice Test-only USDC that mimics Circle's 6-decimal ERC-20 interface.
///         Mint is open so test actors can fund themselves without a faucet.
///         DO NOT deploy to any production or public testnet — use Arc's
///         real USDC at 0x3600000000000000000000000000000000000000 instead.
contract MockUSDC is ERC20 {
    constructor() ERC20("Mock USDC", "mUSDC") {}

    /// @dev Circle USDC uses 6 decimals, not the 18 ERC-20 default.
    function decimals() public pure override returns (uint8) {
        return 6;
    }

    /// @notice Unrestricted mint — tests only.
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
