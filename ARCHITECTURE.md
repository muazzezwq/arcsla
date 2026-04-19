# Architecture

Design decisions, trade-offs, and the reasoning behind each in ArcSLA.

---

## 1. SLA enforcement model

The central question for any pay-per-call protocol is: **how does the contract know whether the provider delivered?** A smart contract lives on-chain; an API call happens off-chain. The two worlds don't intersect unless you build a bridge.

### Options considered

**Option A — Pure optimistic (provider claims, caller disputes).**
Provider submits "I delivered" on-chain. Caller has N minutes to dispute; if they don't, payment is released. If they do, funds are frozen pending arbitration. This is the Kleros / UMA pattern.

*Rejected because:* it requires an arbiter. Arbitration is slow, expensive, and partisan. For sub-dollar API calls, the overhead of a dispute is larger than the value of the call itself.

**Option B — Pure timeout (caller claims slash).**
Caller opens a call, money goes into escrow. Provider has N seconds to deliver (off-chain). If the caller doesn't ack delivery, they can trigger slash after the deadline.

*Rejected because:* the caller can always lie. They received a perfectly good response, refuse to ack, then slash the provider. Adverse.

**Option C — Signed receipts (provider proves delivery).**
Provider delivers the response off-chain, then submits a signed receipt on-chain. The receipt is a signature over `(callId, responseHash)`. If the signature is valid, payment is released.

*Adopted, because* the signature is a cryptographic commitment by the provider that they delivered *some* response tied to that specific call. The contract can verify the signature came from the provider's registered signer key without knowing anything about the response content.

### The actual design

We use **C with a timeout fallback**:

```
1. Caller opens a call. USDC locked in escrow.
2. Provider has `maxResponseTime` seconds to submit a signed receipt.
3a. If the receipt is submitted and the signature checks out:
    - Escrow released to provider
    - Reputation counter incremented
3b. If the deadline passes:
    - Anyone (usually the caller) can call claimTimeout
    - Escrow refunded to caller
    - Stake slashed by slashBps (transferred to caller)
    - Reputation counter incremented (slashed side)
```

This is trust-minimized: the provider cannot be slashed if they submitted a valid signature on time, and the caller cannot drain the provider without the provider legitimately missing the deadline.

### What this model doesn't do

It enforces "a response arrived on time." It does not enforce "the response was correct."

If the provider signs `responseHash = keccak256("garbage")`, the contract happily releases escrow. The caller receives garbage but has no on-chain recourse.

This is an intentional Faz 1 scope decision. Handling response quality requires:

- Either a challenge period with an arbiter (Option A)
- Or a TEE-based attestation that the response was computed by an approved model
- Or a ZK proof of correct computation

Each is a research project on its own. Faz 1 solves the simpler half of the problem — timeliness — and leaves quality to future iterations with an optimistic-challenge extension.

---

## 2. Provider registry design

### Provider struct

```solidity
struct Provider {
    address owner;            // receives payouts, controls the provider
    address signer;           // distinct key used for receipt signing
    uint256 stake;            // USDC held by the registry on behalf of this provider
    uint256 pricePerCall;     // amount caller pays per call, in USDC (6 decimals)
    uint32  maxResponseTime;  // SLA — seconds between call open and receipt deadline
    uint32  slashBps;         // 0-10000 — stake percentage taken on each violation
    uint32  deactivatedAt;    // 0 if active; set to block.timestamp on deactivate()
    uint32  pendingCalls;     // open calls not yet finalized
    uint32  completedCalls;   // reputation counter
    uint32  slashedCalls;     // reputation counter
    string  endpoint;         // discovery URL (not validated on-chain)
    bool    active;
}
```

### Why `owner` and `signer` are separate

In production the `owner` is typically a cold wallet (or multisig) that receives payouts and governs the provider. The `signer` is a hot key that signs receipts in real time, embedded in the provider's backend service.

Separation means a compromised hot key exposes only the revenue stream of a single provider, not the entire treasury. The owner can rotate the signer with `updateSigner()` — the next signature will be expected from the new key.

### Why `pendingCalls` is tracked

A provider cannot `unstake()` while calls are open. If they could, a provider could open a call, deactivate, unstake, then fail to deliver — leaving the caller with a slash claim against zero stake.

`pendingCalls` is incremented by PayPerCall when a call opens and decremented on any final state transition (completed or slashed). Unstake requires `pendingCalls == 0`.

### Why `setPayPerCall` is one-time

The admin sets the PayPerCall contract address exactly once, immediately after deploying it. This prevents a rug-pull vector where an admin later swaps in a malicious PayPerCall that drains all stakes via `slash(all, attacker)`.

Immutability via `require(payPerCall == address(0))` is simpler than a full governance upgrade pattern and is appropriate for a testnet deployment. For mainnet, this would be replaced with a timelocked multisig upgrade.

---

## 3. Call ID construction

```solidity
callId = keccak256(abi.encodePacked(
    providerId,
    msg.sender,      // caller
    nonce++,         // contract-wide counter
    block.timestamp,
    requestHash,
    block.chainid    // prevents cross-chain replay
));
```

The nonce and timestamp ensure two identical requests from the same caller produce distinct `callId`s. `block.chainid` prevents a signed receipt from being replayed on a different chain if the same contract were deployed elsewhere.

---

## 4. Receipt signing scheme

### EIP-191 prefixed message

```solidity
bytes32 inner = keccak256(abi.encodePacked(callId, responseHash));
bytes32 digest = keccak256(
    abi.encodePacked("\x19Ethereum Signed Message:\n32", inner)
);
```

This is the format produced by `wallet.signMessage()` (personal_sign) in MetaMask and ethers.js. Matching the wallet default means providers can sign receipts from a browser extension, a Node.js backend, or any other standard Ethereum signer without protocol-specific tooling.

EIP-712 would have been more principled (structured data, no manual `abi.encodePacked` coupling). It was rejected for Faz 1 because personal_sign is universally supported and the signed payload is simple enough that EIP-712's benefits (human-readable signing UI for complex structures) don't apply.

### Why `(callId, responseHash)` and not just `callId`

If the signature only covered `callId`, a provider could sign once and replay the same receipt for any response. The hash binds the signature to a specific delivered payload — if the provider cheats by signing first and delivering later with different content, the caller has off-chain proof (the hash doesn't match their received response) to not use that provider again, even though the contract accepts the receipt.

---

## 5. Reputation — Bayesian score

### The formula

```solidity
function getReputationScore(uint256 providerId) external view returns (uint8) {
    Provider storage p = _providers[providerId];
    if (p.owner == address(0)) return 0;
    uint256 α = 2;  // prior successes
    uint256 β = 1;  // prior failures
    uint256 numerator = p.completedCalls + α;
    uint256 denominator = p.completedCalls + p.slashedCalls + α + β;
    return uint8((numerator * 100) / denominator);
}
```

This is a Beta-Binomial posterior mean with a `Beta(α=2, β=1)` prior. In plain language: before observing any calls, the system treats every provider as if they had already completed 2 calls and been slashed on 1, giving a baseline score of `2 / (2+1) × 100 = 66`.

### Why not simpler?

Four formulas were considered:

| Approach | 0 calls | 1 success | 1 slash | 5/1 ratio | 100/0 | Comment |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| `100 − slashed/total × 100` | 100 | 100 | 0 | 80 | 100 | Trivial to game; new providers look perfect |
| Weighted punishment `100 − slashed×200/total` | 100 | 100 | -100→0 | 60 | 100 | Harsh, still game-able by fresh spam |
| Ladder (+1 success, -20 slash) | 100 | 100 | 80 | 95 | ≥100 | Rewards starting fresh; punishes long-term providers |
| **Bayesian (α=2, β=1)** | **66** | **75** | **50** | **78** | **98** | **No spam loophole; scales with evidence** |

The Bayesian version has three properties the others lack:

1. **New providers start at 66, not 100.** A fresh provider is treated as "unknown" rather than "perfect." This prevents a spam attack where someone registers, lands a single lucky call, looks perfect, steals trust.
2. **Single failures aren't catastrophic.** A provider with 0 successes and 1 slash scores 50 — bad, but not zero. Recovery is possible by accumulating successes.
3. **Evidence accumulates.** A provider with 100 successes and 5 slashes (94) outscores a provider with 2 successes and 0 slashes (80), because the former has a larger sample size. This incentivizes long-running, occasionally-imperfect providers over brand-new allegedly-perfect ones.

### Why counter-based and not event-log-based

The score could have been computed off-chain by indexing `ReceiptSubmitted` and `CallSlashed` events. Two reasons we chose to track it on-chain instead:

1. **Other contracts can read it.** A router contract that picks the best provider for a task needs the score as a view call (`getReputationScore`), not as an off-chain database query. On-chain counters are the only way.
2. **Indexer dependency is external risk.** If the indexer is down, every consumer of the reputation is blind. On-chain counters are always available as long as Arc is.

The gas cost is one `SSTORE` per call outcome — about 5,000 gas post-EIP-2929 for a warm storage slot. On Arc that's a fraction of a cent.

---

## 6. Gas budget

Measured in the Foundry test suite (averages):

| Operation | Gas | USDC cost at 40 gwei |
| --- | ---: | ---: |
| `register(...)` | ~240k | ≈ 0.01 USDC |
| `callService(...)` | ~200k | ≈ 0.008 USDC |
| `submitReceipt(...)` | ~100k | ≈ 0.004 USDC |
| `claimTimeout(...)` | ~120k | ≈ 0.005 USDC |
| Full call lifecycle | ~420k | ≈ **0.017 USDC** |

A full call lifecycle — open, pay, submit receipt, update reputation — costs less than 2 cents at current Arc testnet gas prices. For a 1 USDC call this is 1.7% overhead, comparable to a credit card merchant fee and substantially less than standard payment processors charge for similar transaction sizes.

---

## 7. What's explicitly out of scope for Faz 1

These were deliberately omitted to keep the first iteration shippable:

- **Response quality disputes** — see §1
- **Variable pricing** — provider sets a single `pricePerCall` at register time; no auction, no tiered pricing, no surge pricing
- **Refunds and partial payments** — either the call succeeds and the provider is paid in full, or it fails and the caller is refunded in full
- **Multi-hop routing** — no `router.callBestProvider(task)` yet; the caller picks the provider
- **Privacy** — request and response hashes are on-chain; callers who care about privacy should hash salted payloads
- **Subscription billing** — only pay-per-call is supported; subscriptions would require a separate `Subscription.sol`

Each of these is a follow-up Faz.
