# ArcSLA

**On-chain SLA marketplace for autonomous services, on Arc.**

Providers stake USDC to commit to Service-Level Agreements. Callers pay per request. Stake is automatically slashed when SLAs are violated — no arbiter, no oracle, no off-chain dispute system.

ArcSLA is designed for the machine-to-machine economy: AI agents buying API calls, autonomous services transacting with each other, and any pay-per-call use case where trust must be encoded in the contract rather than assumed.

Built on [Arc Testnet](https://www.arc.network), Circle's stablecoin-native L1 where USDC is the native gas token.

---

## Why this exists

**AI agents are becoming economic actors.** A planning agent calls a retrieval agent. A research agent calls a summarization agent. A trading agent calls a price-feed agent. Each of these interactions is a paid API call between two autonomous programs that have never met and have no reason to trust each other.

Today those calls happen through three bad options:

1. **Trust the provider.** Agent pays up-front, hopes for a response. Breaks at scale.
2. **Trust a custodian.** Both parties deposit into an escrow run by a third party. Adds latency, adds a new point of failure, adds a fee.
3. **Trust a DAO.** Disputes go to human arbitration. Too slow for machine-speed transactions.

ArcSLA is the fourth option: **trust the code**.

A provider stakes USDC, commits to a max response time and slash percentage, and signs a cryptographic receipt when they fulfill a call. If they miss the deadline, anyone can trigger the slash. The contract transfers the escrow back to the caller plus a penalty from the provider's stake. All of this takes seconds on Arc.

The result is a permissionless marketplace where AI agents — or any program holding USDC — can buy API calls with automatic SLA enforcement and an on-chain reputation score.

---

## Built for AI agents

Here is a concrete scenario. Agent A is a research assistant running on a user's laptop. It needs to summarize a 200-page PDF. It doesn't have a summarization model locally, but there are dozens of providers offering this as a paid API.

**Without ArcSLA:**

```
Agent A → "send me your best summarization provider"
        → tries provider X, sends document, waits
        → provider X keeps the money, ignores the request
        → Agent A has no recourse except blacklisting
```

**With ArcSLA:**

```
Agent A → reads on-chain registry, picks provider by reputation + price
        → calls provider #42, escrows 0.10 USDC
        → provider has 30 seconds to return a signed receipt
        → if receipt arrives → provider gets paid, reputation up
        → if not → Agent A gets refund + 20% of provider's stake
```

Every step is a contract call. The agent needs no human supervision. The provider needs no billing system. The reputation score is a live `uint8` view on-chain, readable by any other contract — including a router that automatically picks the best provider for the next call.

### Why Arc specifically

AI-agent transactions have properties that traditional chains handle poorly:

- **They're frequent.** A single agent may make thousands of calls per hour. High fees kill the use case.
- **They're small.** A typical API call is worth 0.001–1 USDC. On Ethereum mainnet, the gas alone would exceed the call price.
- **They're USDC-denominated.** Agents carry USDC as working capital, not ETH. A chain that charges gas in a volatile token adds a second asset to manage.

Arc solves all three: [USDC is native gas](https://docs.arc.network/arc/concepts/welcome-to-arc), finality is sub-second, and fees are priced predictably in the same token the protocol charges in. A full call-and-receipt round trip costs ~0.017 USDC — less than a credit-card merchant fee.

---

## Live on Arc Testnet

**Try the live demo:** [**arcsla.vercel.app**](https://arcsla.vercel.app) — open in any modern browser with MetaMask.

| Contract | Address |
| --- | --- |
| ServiceRegistry | [`0x74635245CfF23a7F261CD5ECF72693cbc75481e4`](https://testnet.arcscan.app/address/0x74635245CfF23a7F261CD5ECF72693cbc75481e4) |
| PayPerCall | [`0x28aa00Af89483218E6Bc036a72C4bAe8A1514BFE`](https://testnet.arcscan.app/address/0x28aa00Af89483218E6Bc036a72C4bAe8A1514BFE) |
| USDC (native gas) | [`0x3600000000000000000000000000000000000000`](https://testnet.arcscan.app/address/0x3600000000000000000000000000000000000000) |

---

## What's in the demo

The demo at [arcsla.vercel.app](https://arcsla.vercel.app) is a single-file dapp (ethers.js v6, no build step) that exposes every part of the protocol through a polished interface:

### On the landing page (no wallet required)

- **Live network stats** — registered providers, calls on chain, slashes enforced, all read directly from the contracts
- **"How to try this" walkthrough** — three-step guide that tells a first-time visitor exactly what to do
- **Live activity feed** — streams the 10 most recent `CallStarted`, `ReceiptSubmitted`, `CallSlashed`, and `ProviderRegistered` events from Arc Testnet. Every row links to the exact transaction on ArcScan. Updates in real time as new events happen.
- **Contract address bar** — all three contract addresses with one-click links to ArcScan
- **Tab title counter** — if you switch to another tab, the title shows `(3) ArcSLA · New activity` when new events arrive so you don't miss anything

### Inside the app (after connecting a wallet)

- **Network stats bar** — providers count, total calls, receipts submitted, USDC slashed, with honor-rate percentage
- **Actions panel** — register as provider, call a service, submit a receipt, or claim a timeout, each with inline tooltips explaining every field (stake, slash%, signer, etc.)
- **Live calculator** — inside the register form, shows in real time: stake locked, loss per SLA violation, max slashes before stake is drained, revenue per 10 calls, break-even point. Adjust the inputs and watch the numbers update.
- **Your provider panel** — full details of your registered provider: stake, price, SLA terms, pending calls, endpoint
- **Your calls panel** — every call you've opened with live status (pending/completed/slashed) and countdown to SLA deadline
- **All providers table** — public directory of every registered provider, sortable, clickable. Your own provider is highlighted.
- **Leaderboard** — top 10 providers by reputation with medal emojis for the top 3, progress bars scaled to each score, and a "you" badge on your own row
- **24-hour activity chart** — hourly bars of call volume, with slashed calls highlighted in red. Hover any bar for exact numbers.
- **Provider detail modal** — click any provider to see their on-chain reputation score (Bayesian), honor rate, total calls, slashed count, full terms, and recent call history. Includes a "Call this provider" shortcut.
- **Live event feed** — same feed as the landing page but full-width and higher-volume once connected
- **Human-readable errors** — every contract revert is decoded to a plain-English message (e.g. `Already registered (one provider per address)` instead of `execution reverted`)
- **Input validation** — client-side checks prevent you from sending obviously invalid transactions and wasting gas

### Resources footer

Every page includes a footer with links to Arc, Circle, testnet tools (faucet, ArcScan, thirdweb), and every piece of project documentation.

---

## How it works

```
┌─────────┐  1. callService(providerId, requestHash)    ┌──────────────┐
│ Caller  ├────────────────────────────────────────────▶│  PayPerCall  │
│ (agent) │  2. USDC escrowed, CallStarted event        │              │
└─────────┘                                             │   contract   │
                                                        │              │
┌──────────┐  3. provider fulfills request off-chain    │              │
│ Provider ├────────────────────────────────────────────┤              │
│ (API)    │  4. submitReceipt(callId, hash, signature) │              │
└──────────┘                                            │              │
                                                        │              │
      on SLA honor:                                     │              │
        ├─ escrow released to provider                  │              │
        └─ ServiceRegistry.incCompleted(id) — rep ↑    │              │
                                                        │              │
      on timeout (anyone can call):                     │              │
        ├─ escrow refunded to caller                    │              │
        ├─ stake slashed and sent to caller             │              │
        └─ ServiceRegistry.incSlashed(id) — rep ↓      │              │
                                                        └──────────────┘
```

Every transfer of value is contract-enforced. There is no custodian, no arbiter, no dispute committee.

---

## Reputation

ArcSLA tracks two counters per provider — `completedCalls` and `slashedCalls` — and computes a Bayesian reputation score on-chain:

```
score = (completed + 2) / (completed + slashed + 3) × 100
```

- Fresh provider → 66 (neither trusted nor distrusted)
- 1 successful call → 75
- 10 successful calls → 92
- 0 successes, 1 slash → 50
- 100 successes, 5 slashes → 94

This formula prevents the "single lucky call = perfect score" spam vector, rewards long-term providers who occasionally slip, and is readable as a view function (`getReputationScore(id)`) by any other contract — for example a routing contract that picks the best provider for each call.

See [`ARCHITECTURE.md`](./ARCHITECTURE.md) for the full rationale.

---

## Quick start

**Prerequisites:** [Foundry](https://getfoundry.sh), a browser with [MetaMask](https://metamask.io), and a wallet funded from [faucet.circle.com](https://faucet.circle.com) for Arc Testnet.

### Clone and install

```bash
git clone https://github.com/<you>/arcsla.git
cd arcsla
forge install foundry-rs/forge-std
forge install OpenZeppelin/openzeppelin-contracts
```

### Run tests

```bash
forge test -vv
```

Expected: **57 tests passed, 0 failed.**

### Try the demo

```bash
cd demo
python3 -m http.server 8080
```

Open `http://localhost:8080`, connect MetaMask (Arc Testnet will be added automatically), and use the pre-deployed contracts above.

### Deploy your own copy

```bash
cp .env.example .env
# Fill USDC_ADDRESS (0x3600...0000 on Arc Testnet)

# Import your deployer wallet as an encrypted keystore
cast wallet import main --interactive

# Deploy
forge script script/Deploy.s.sol:Deploy \
  --account main \
  --sender 0xYOUR_DEPLOYER \
  --rpc-url arc_testnet \
  --broadcast
```

See [`DEPLOY.md`](./DEPLOY.md) for the full walkthrough.

---

## Solidity example

```solidity
// 1. Agent approves USDC
usdc.approve(payPerCall, 1e6);

// 2. Agent opens the call
bytes32 requestHash = keccak256(abi.encode("summarize this document"));
bytes32 callId = payPerCall.callService(1, requestHash);

// 3. Provider delivers the response off-chain, signs the response hash
bytes32 responseHash = keccak256(responseBytes);
bytes32 digest = keccak256(abi.encodePacked(callId, responseHash))
    .toEthSignedMessageHash();
bytes memory signature = providerSigner.sign(digest);

// 4. Provider submits the receipt on-chain — escrow released, reputation bumped
payPerCall.submitReceipt(callId, responseHash, signature);

// 5. Or, if 30 seconds passed without a receipt:
payPerCall.claimTimeout(callId);
// → escrow refunded + stake slashed + reputation decreased
```

---

## Project layout

```
arcsla/
├── src/
│   ├── ServiceRegistry.sol          # provider registry, stake, slashing, Bayesian reputation
│   ├── PayPerCall.sol               # call escrow, ECDSA receipt verification, timeout enforcement
│   └── interfaces/
│       └── IServiceRegistry.sol
├── test/
│   ├── ServiceRegistry.t.sol        # 36 unit tests
│   ├── PayPerCall.t.sol             # 21 unit tests
│   └── helpers/
│       └── MockUSDC.sol             # 6-decimal ERC-20 for tests
├── script/
│   └── Deploy.s.sol                 # deterministic deployment + wiring
├── demo/
│   └── index.html                   # single-file dapp UI (ethers.js v6)
├── SPEC.md                          # technical specification
├── ARCHITECTURE.md                  # design deep-dive
├── SECURITY.md                      # trade-offs and attack surface
├── DEPLOY.md                        # step-by-step deployment guide
└── README.md                        # this file
```

---

## Known limitations

- **Receipt signing shows raw bytes in the wallet.** The current implementation uses EIP-191 `signMessage` over `keccak256(callId, responseHash)`. MetaMask (and most wallets) attempt to render those raw bytes as a string, which comes out as unreadable characters. The signature is correct and the protocol works, but the UX is not ideal — v2 will switch to EIP-712 typed data so wallets can show a human-readable receipt preview.
- **USDC decimals fetched at runtime.** Standard USDC uses 6 decimals, but Arc's testnet USDC uses 18. The demo reads `decimals()` from the token contract at boot, so any deployment works, but amounts displayed before wallet connection assume the detected value.
- **Event scan window is 50,000 blocks.** For historical `CallStarted`/`ReceiptSubmitted`/`CallSlashed` counts, the demo scans the last ~27 hours of blocks only. Provider count comes from contract state (`nextProviderId`) so it's always accurate, but very old calls won't appear in the "Calls" stat. A proper indexer (subgraph or similar) is planned for v2.

## Roadmap

- **EIP-712 typed data for receipts.** Replace the current raw-bytes EIP-191 signature with EIP-712 typed data so wallets can display a human-readable receipt preview (callId, responseHash, chain, contract) instead of binary gibberish. Requires a contract redeploy.
- **Reputation-weighted routing.** An on-chain router that picks the best provider for a given task using the Bayesian score.
- **Agent wallets.** A wrapper contract that lets AI agents hold bounded USDC budgets and spend autonomously, with spending caps and revocable signers.
- **Optimistic quality challenges.** The current SLA only enforces "a response arrived on time." A future challenge period would let callers dispute junk responses.
- **Off-chain endpoint monitoring.** An optional aggregator that pings provider endpoints and publishes uptime/latency metrics as a convenience layer — complementary to the on-chain slashing, which already provides cryptoeconomic monitoring through unclaimed timeouts.
- **Multi-chain via CCTP.** Let providers accept calls on Arc but settle to the chain of their choice using Circle's Cross-Chain Transfer Protocol.
- **Mainnet.** Once Arc Mainnet is live and audited, ArcSLA moves there.

---

## Resources

### Arc & Circle

- [Arc Network](https://www.arc.network/) — project homepage
- [Arc documentation](https://docs.arc.network/arc/concepts/welcome-to-arc) — concepts, architecture, guides
- [Circle Developers](https://developers.circle.com/) — SDKs, CCTP, Gateway, Paymaster
- [Circle Console](https://console.circle.com/signin) — API keys, testnet dashboards
- [Circle](https://www.circle.com/) — the company behind USDC and Arc

### Testnet tools

- [Arc Testnet Faucet](https://faucet.circle.com/) — free testnet USDC (also serves as gas)
- [ArcScan Testnet](https://testnet.arcscan.app/) — block explorer, contract verification, transaction details
- [thirdweb Arc Testnet](https://thirdweb.com/arc-testnet) — chain config, contract explorer, developer dashboard

### Project documents

- [`ARCHITECTURE.md`](./ARCHITECTURE.md) — design decisions and rationale
- [`SECURITY.md`](./SECURITY.md) — threat model and known trade-offs
- [`DEPLOY.md`](./DEPLOY.md) — step-by-step deployment guide
- [`SPEC.md`](./SPEC.md) — original technical specification

---

## License

MIT. Not affiliated with Circle, Arc, or any project mentioned above. Built independently for the Arc Architects community.
