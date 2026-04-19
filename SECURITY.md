# Security

Honest disclosure of ArcSLA's known risks, intentional trade-offs, and the invariants the contracts rely on.

This is a testnet project built for the Arc Architects community. **Do not deploy this code to mainnet without a professional audit.** The sections below describe what the code does correctly, what it deliberately doesn't do, and what an attacker could attempt.

---

## Invariants the code relies on

If any of these are false, the contracts have a vulnerability.

1. **`block.timestamp` is monotonically non-decreasing and reflects real wall-clock time within a small tolerance.** The SLA deadline check (`block.timestamp > deadline`) depends on this. On Arc's PoS consensus with sub-second finality, timestamp manipulation is bounded and negligible.
2. **`ecrecover` correctly identifies the signer of a 65-byte ECDSA signature.** Standard EVM precompile behavior.
3. **OpenZeppelin `ReentrancyGuard` actually prevents reentrancy.** Battle-tested, widely audited.
4. **USDC on Arc implements the ERC-20 interface faithfully at 6 decimals.** Arc's docs explicitly confirm this.
5. **The admin's private key is not compromised.** The admin can set PayPerCall once at deploy time; after that, they have no privileged access to user funds.

---

## Attack surface

### 1. Provider attacks on callers

**Attack: Provider takes payment, never delivers.**
Mitigated by: timeout + slash. After `maxResponseTime`, the caller can `claimTimeout` to get the escrow back plus `slashBps` percent of the provider's stake.

**Attack: Provider delivers garbage, still signs a receipt.**
*Not mitigated.* The contract only checks that *a* response was signed, not that the response is useful. See [`ARCHITECTURE.md §1`](./ARCHITECTURE.md#1-sla-enforcement-model) for the rationale. Callers who care about response quality must evaluate off-chain and route future calls accordingly (the reputation score helps here over time).

**Attack: Provider front-runs their own slash by unstaking.**
Mitigated by: `pendingCalls` counter. `unstake()` reverts while any call is open. The provider also has a 1-hour cooldown after deactivating before they can unstake, giving callers a window to claim any timeouts on calls that had already opened.

**Attack: Provider front-runs their own slash by rotating signer to a burn address.**
*Not prevented.* A provider about to be slashed could call `updateSigner(0)`... except the contract checks `newSigner != address(0)` and reverts. They *could* rotate to a throwaway address. However, this doesn't help them — the signer change doesn't invalidate pending calls, and the timeout path doesn't rely on any signer behavior. The caller still gets their refund and slash.

### 2. Caller attacks on providers

**Attack: Caller refuses to acknowledge a delivered response and claims timeout.**
*Not possible.* `claimTimeout` reverts if `submitReceipt` was called first (`status != Pending`). The provider controls the state transition, not the caller. As long as the provider submitted a valid signature before the deadline, the timeout path is closed.

**Attack: Caller spams pending calls to lock up the provider's capacity.**
*Not prevented in Faz 1.* A caller could open 1,000 calls simultaneously, paying `pricePerCall × 1,000` USDC. The provider must now submit 1,000 receipts within `maxResponseTime` or be slashed on each. The spam costs the caller `N × pricePerCall` up-front, which is a real economic cost — but a motivated attacker with funds could grief a provider.

*Mitigation the provider can deploy today:* set `pricePerCall` high enough that spam is uneconomical. For a provider expecting 1 call per second with `maxResponseTime=30`, pricing each call at `0.10 USDC` means 1,000-call spam costs the attacker `100 USDC` up-front for at most `20 USDC` slash potential. Unfavorable arithmetic.

*Future mitigation:* per-provider rate limiting on `callService`, or a minimum per-caller reputation check.

### 3. Signature replay

**Attack: Use a valid receipt signature from one call to close a different call.**
*Mitigated.* The digest is `keccak256(callId, responseHash)`, and `callId` itself includes `(providerId, caller, nonce, block.timestamp, requestHash, block.chainid)`. No two calls share a `callId`, so no signature can be replayed.

**Attack: Use a receipt signature across chains.**
*Mitigated.* `block.chainid` is in the `callId` preimage. A signature valid on Arc Testnet (chainId 5042002) is invalid on Ethereum Sepolia (chainId 11155111).

### 4. Reentrancy

**Attack: USDC transfer re-enters PayPerCall mid-function.**
*Mitigated.* Every function that moves USDC is decorated with `nonReentrant`. State updates are applied before external calls (checks-effects-interactions). We also use `SafeERC20.safeTransfer` which is strict about return-value handling.

USDC itself is not a reentrancy vector (it's a standard ERC-20), but the pattern is applied defensively in case of future token swaps.

### 5. Admin / deployer risk

**Attack: Admin changes PayPerCall to a malicious contract that slashes all providers.**
*Mitigated.* `setPayPerCall` can only be called once. After the initial wiring, no address in the system has privileged access to slash or mint stake.

**Attack: Admin forgets to call `setPayPerCall` and PayPerCall can never call slash.**
This is a deployment-time bug, not a vulnerability. The deployment script handles wiring automatically; a manual deployment that skipped this step would produce a contract where calls open but receipts and slashes both revert. Providers would observe that no one can use them and stop registering. Funds already staked can still be recovered via `deactivate()` + cooldown + `unstake()`.

### 6. Price oracle manipulation

*Not applicable.* The protocol does not use any price oracles. All amounts are denominated in USDC, and USDC is assumed to be worth USDC.

### 7. Arithmetic

**Attack: Slash calculation overflows.**
*Not possible in 0.8.24.* Solidity's built-in overflow checks make arithmetic errors revert rather than silently wrap. The one place we use `unchecked` is `completedCalls += 1`, which can only overflow after `2^32 ≈ 4B` calls for a single provider.

**Attack: Reputation formula `(numerator * 100) / denominator` overflows.**
*Not possible.* `numerator = completedCalls + 2` and `completedCalls` is `uint32`, so `numerator * 100 ≤ 2^32 × 100 ≈ 4 × 10^11`, well within `uint256` range.

**Attack: Reputation score truncation from `uint256` to `uint8`.**
Bound by construction. `numerator ≤ denominator` always (because `completedCalls ≤ completedCalls + slashedCalls + 3`), so `(numerator * 100) / denominator ≤ 100`, which fits in `uint8`. The `unsafe-typecast` lint warning is acceptable here; a comment in the source notes the proof.

---

## What is NOT guaranteed

These are known limitations, not bugs.

1. **Response content integrity.** The contract does not verify that the response delivered off-chain matches the hash signed on-chain. A provider can sign `responseHash = keccak256("")` while delivering any payload; the caller must verify the hash themselves.

2. **Provider liveness.** The contract does not guarantee providers stay online. A registered provider can simply stop responding, and callers must switch to another provider (the reputation score will fall due to timeouts).

3. **Caller availability of funds for timeout claims.** The timeout function requires gas. In Arc's case, gas is USDC, so a caller whose balance is exhausted by spam calls cannot claim timeouts. However, *any* address can call `claimTimeout` on behalf of the rightful caller — the refund always goes to the original caller, not the transaction sender. This means a monitoring service could claim timeouts for users who paid to open calls but ran out of gas.

4. **Reputation score gameability across identities.** A provider with a bad reputation can register a new identity from a different address with a fresh score of 66. This is unavoidable without sybil resistance (which is a protocol-wide problem, not a contract-level one). Callers who care about long-term reputation must evaluate identity claims off-chain.

---

## What was not tested

57 unit tests cover the happy paths, the timeout path, and the revert cases that the code explicitly rejects. Not covered:

- **Fork tests against real USDC on Arc.** Tests use a `MockUSDC` for determinism and speed.
- **Fuzzing.** `forge test` can run fuzz tests, but we don't have property-based tests against invariants yet.
- **Gas bounds.** No assertions that a function stays under a gas ceiling.
- **Adversarial test harness.** No "attacker contract" trying to reenter, front-run, or griefing test cases.

These are appropriate for a hobby testnet project. A mainnet audit would require all four.

---

## Recommended use

This code is:

- ✅ Fine to read, learn from, and fork for testnet experimentation
- ✅ Fine to deploy to Arc Testnet and test with real testnet USDC
- ✅ A reasonable reference implementation for a pay-per-call SLA primitive

This code is NOT:

- ❌ Audited by a professional firm
- ❌ Ready for mainnet deployment with real funds
- ❌ A substitute for a production API payment system

---

## Reporting issues

If you find a vulnerability, please open a GitHub issue with details. If the issue is severe (funds at risk on Arc Testnet), reach out by private channel first. For a testnet project, there's no bounty program — but credit is given in the README.
