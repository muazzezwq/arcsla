# SLA Marketplace — Teknik Spec (Faz 1 MVP)

Arc Testnet üzerinde, servis sağlayıcıların USDC stake ederek kaydolduğu, kullanıcıların pay-per-call ödediği, SLA ihlalinde otomatik slash olan bir protokol.

**Chain:** Arc Testnet (chainId 5042002)
**Ödeme token'ı:** USDC (`0x3600000000000000000000000000000000000000`, native gas + ERC-20 interface, 6 decimals)
**Dil:** Solidity ^0.8.24
**Framework:** Foundry

---

## Faz 1 kapsamı

Bu faz iki kontrattan oluşuyor:

1. **`ServiceRegistry.sol`** — sağlayıcı kaydı, stake yönetimi, SLA parametreleri
2. **`PayPerCall.sol`** — çağrı escrow'u, imzalı receipt submit, timeout slash

Reputation ve Agent Wallet Faz 2/3. Tamamen on-chain event'lerden türetilecek, şu an yazılmayacak.

---

## SLA ihlal modeli

**Karışık model:** imzalı receipt (cryptographic commitment) + timeout-based slash.

Akış:

1. Kullanıcı `callService()` çağırır → USDC escrow'a kilitlenir, `CallStarted` event emit edilir
2. Sağlayıcı off-chain API çağrısını yapar, yanıtı üretir
3. Sağlayıcı `keccak256(callId, responseHash)` üzerinde ECDSA imzası oluşturur
4. Sağlayıcı `submitReceipt(callId, responseHash, signature)` çağırır → escrow sağlayıcıya geçer, receipt on-chain saklanır
5. Eğer sağlayıcı `maxResponseTime` (saniye cinsinden, kaydında belirtilmiş) içinde submit etmezse, kullanıcı `claimTimeout(callId)` çağırır → escrow + stake'in `slashAmount`'u kullanıcıya döner

**Bu modelin karşıladığı maddeler:**
- "Cryptographic receipt on-chain olarak oluşturulur" → adım 4, ECDSA imza + responseHash on-chain saklı
- "Zaman damgası, çağrı detayları ve ücret saklanır" → `Call` struct'ı hepsini tutar
- "Servis süresi dolduğunda çağrı başarısızsa stake otomatik olarak kullanıcıya aktarılır" → adım 5
- "İşlemler tamamen on-chain, herhangi bir aracıya gerek yok" → evet, oracle yok, arbiter yok

**Bu modelin ele almadığı (bilinçli olarak):**
- Yanıtın *kalitesi*. Sağlayıcı çöp yanıt verip imzalayabilir. Faz 1 sadece "yanıt verildi mi, zamanında mı" sorularını çözer. Kalite kontrolü Faz 2+ işi (challenge period, reputation düşüşü, optimistic dispute).

---

## ServiceRegistry.sol

### State

```solidity
struct Provider {
    address owner;           // sağlayıcı cüzdanı
    address signer;          // receipt imzalamakta kullanılacak adres (owner'dan farklı olabilir)
    uint256 stake;           // kilitli USDC miktarı (6 decimals)
    uint256 pricePerCall;    // çağrı başına USDC (6 decimals)
    uint32  maxResponseTime; // saniye
    uint32  slashBps;        // ihlalde stake'in yüzde kaçı yakılır, basis points (0-10000)
    string  endpoint;        // off-chain API URL'i, sadece keşif için
    bool    active;          // false = yeni çağrı kabul etmez (unstake hazırlığı)
}

mapping(uint256 => Provider) public providers;
mapping(address => uint256) public providerIdOf; // owner -> providerId, 0 = kayıtsız
uint256 public nextProviderId; // 1'den başlar
uint256 public minStake;       // register için minimum USDC stake
IERC20  public immutable usdc;
address public immutable payPerCall; // yetkili slash çağrıcısı
```

### Fonksiyonlar

```solidity
function register(
    address signer,
    uint256 stakeAmount,
    uint256 pricePerCall,
    uint32  maxResponseTime,
    uint32  slashBps,
    string  calldata endpoint
) external returns (uint256 providerId);
// USDC transferFrom ile stake'i çeker. slashBps <= 10000. maxResponseTime >= 5 sn.

function deactivate(uint256 providerId) external;
// Sadece owner. active = false, yeni çağrı gelmez. Unstake için cooldown başlar.

function unstake(uint256 providerId) external;
// Sadece owner. active = false olmalı ve son `CallCompleted/CallSlashed` event'inden
// beri `unstakeCooldown` (örn. 1 saat) geçmiş olmalı. USDC geri transfer.

function slash(uint256 providerId, uint256 amount, address recipient) external;
// Sadece payPerCall kontratı çağırabilir. stake'ten amount düşer, recipient'a transfer.

function updatePrice(uint256 providerId, uint256 newPrice) external;
function updateSigner(uint256 providerId, address newSigner) external;
// Sadece owner.
```

### Event'ler

```solidity
event ProviderRegistered(uint256 indexed providerId, address indexed owner, address signer, uint256 stake, uint256 pricePerCall, uint32 maxResponseTime, string endpoint);
event ProviderDeactivated(uint256 indexed providerId);
event ProviderUnstaked(uint256 indexed providerId, uint256 amount);
event ProviderSlashed(uint256 indexed providerId, uint256 amount, address recipient);
event PriceUpdated(uint256 indexed providerId, uint256 newPrice);
event SignerUpdated(uint256 indexed providerId, address newSigner);
```

---

## PayPerCall.sol

### State

```solidity
enum CallStatus { None, Pending, Completed, Slashed }

struct Call {
    uint256 providerId;
    address caller;
    uint256 amount;         // escrow'daki USDC
    uint32  startedAt;      // block.timestamp
    uint32  deadline;       // startedAt + maxResponseTime
    bytes32 requestHash;    // istek gövdesinin hash'i (off-chain doğrulama için)
    bytes32 responseHash;   // submitReceipt'te doldurulur
    CallStatus status;
}

mapping(bytes32 => Call) public calls; // callId => Call
ServiceRegistry public immutable registry;
IERC20 public immutable usdc;
```

### Fonksiyonlar

```solidity
function callService(
    uint256 providerId,
    bytes32 requestHash
) external returns (bytes32 callId);
// 1. providers[providerId].active olmalı
// 2. pricePerCall kadar USDC transferFrom
// 3. callId = keccak256(providerId, caller, nonce, block.timestamp, requestHash)
// 4. Call struct'ı kaydet, status = Pending
// 5. CallStarted emit

function submitReceipt(
    bytes32 callId,
    bytes32 responseHash,
    bytes calldata signature
) external;
// 1. calls[callId].status == Pending
// 2. block.timestamp <= deadline
// 3. digest = keccak256("\x19Ethereum Signed Message:\n32", keccak256(callId, responseHash))
// 4. ecrecover(digest, signature) == providers[providerId].signer
// 5. responseHash kaydet, status = Completed
// 6. USDC escrow'u provider owner'a transfer
// 7. ReceiptSubmitted emit

function claimTimeout(bytes32 callId) external;
// 1. calls[callId].status == Pending
// 2. block.timestamp > deadline
// 3. status = Slashed
// 4. escrow'daki USDC caller'a geri transfer
// 5. registry.slash(providerId, stake * slashBps / 10000, caller) çağır
// 6. CallSlashed emit
```

### Event'ler

```solidity
event CallStarted(bytes32 indexed callId, uint256 indexed providerId, address indexed caller, uint256 amount, bytes32 requestHash, uint32 deadline);
event ReceiptSubmitted(bytes32 indexed callId, bytes32 responseHash);
event CallSlashed(bytes32 indexed callId, uint256 refunded, uint256 slashed);
```

---

## Güvenlik noktaları

Bunlara özellikle dikkat edilecek:

1. **Reentrancy.** `callService`, `submitReceipt`, `claimTimeout` — hepsinde USDC transfer var. OpenZeppelin `ReentrancyGuard` kullanılacak.
2. **Checks-effects-interactions.** Önce state güncelle (`status = Completed`), sonra transfer yap.
3. **Signature replay.** `callId` unique (nonce + timestamp + requestHash). Aynı imza başka bir call için kullanılamaz çünkü digest içinde callId var.
4. **Integer overflow.** 0.8.24 SafeMath built-in, ama `slashBps` maks 10000 olarak enforce edilecek.
5. **Unstake front-running.** Sağlayıcı pending call'u varken deactivate edip unstake edemez — cooldown + pending call kontrolü.
6. **USDC approval flow.** Kullanıcı önce `usdc.approve(payPerCall, amount)` çağırmalı. Frontend'de otomatik akışla yönetilecek.

---

## Arc Testnet'e özel notlar

1. **USDC native gas.** Kullanıcı çağrı yaparken hem `pricePerCall` ödüyor hem de gas için USDC harcıyor. UI'da "toplam maliyet" gösterimi iki kalemden oluşmalı.
2. **USDC ERC-20 interface 6 decimals** — native gas 18 decimals. Kontratlarda sadece ERC-20 interface kullanılacak, 6 decimals.
3. **Deterministik sub-saniye finalite.** Bu bize `maxResponseTime` için makul alt sınır vermeyi sağlar — 5 saniye bile Arc için rahat.
4. **Explorer:** `https://testnet.arcscan.app/tx/{hash}` — demo HTML'de her tx için link gösterilecek.

---

## Demo HTML kapsamı

Tek dosya, ethers.js v6, Metamask bağlantısı. Butonlar:

1. **Connect Wallet** — Arc Testnet'e switch (gerekirse add)
2. **Register Provider** — form: stake, pricePerCall, maxResponseTime, slashBps, endpoint
3. **Call Service** — providerId seç, requestHash gir (veya auto-generate), USDC approve + callService
4. **Submit Receipt** — callId + responseHash, wallet ile signMessage, contract'a submit
5. **Claim Timeout** — callId gir, deadline geçmişse slash tetikle
6. **Canlı event feed** — `CallStarted`, `ReceiptSubmitted`, `CallSlashed` event'lerini dinle, listele

Event feed en önemlisi — jüriye/yatırımcıya "bak, tamamen on-chain çalışıyor, aracı yok" demek için.

---

## Test planı (Foundry)

`forge test` ile koşulacak testler:

**Happy path**
- `test_registerProvider_setsState`
- `test_callService_escrowsUSDC`
- `test_submitReceipt_transfersToProvider`
- `test_submitReceipt_withValidSignature`

**Timeout**
- `test_claimTimeout_refundsCaller`
- `test_claimTimeout_slashesProvider`
- `test_claimTimeout_beforeDeadline_reverts`

**Güvenlik**
- `test_submitReceipt_afterDeadline_reverts`
- `test_submitReceipt_invalidSignature_reverts`
- `test_submitReceipt_wrongSigner_reverts`
- `test_submitReceipt_twice_reverts`
- `test_claimTimeout_afterReceipt_reverts`
- `test_unstake_withPendingCall_reverts`
- `test_reentrancy_callService`

**Edge**
- `test_slashBps_zero_onlyRefunds`
- `test_slashBps_max_fullSlash`
- `test_differentProviders_independentState`

---

## Klasör yapısı

```
sla-marketplace/
├── foundry.toml
├── .env.example
├── .gitignore
├── README.md
├── src/
│   ├── ServiceRegistry.sol
│   ├── PayPerCall.sol
│   └── interfaces/
│       └── IServiceRegistry.sol
├── test/
│   ├── ServiceRegistry.t.sol
│   ├── PayPerCall.t.sol
│   └── helpers/
│       └── MockUSDC.sol
├── script/
│   └── Deploy.s.sol
└── demo/
    └── index.html
```

---

## Uygulama sırası

1. Foundry projesi init + OpenZeppelin import + Arc config
2. `MockUSDC` (test için 6 decimals ERC-20)
3. `ServiceRegistry.sol` + testleri
4. `PayPerCall.sol` + testleri
5. `Deploy.s.sol` script'i (Arc Testnet'e deploy)
6. `demo/index.html`
7. Deploy, gerçek USDC ile test, demo'yu canlı göster

Her adımda dur, çalıştır, onay al. Ben direkt 7'ye kadar yazmıyorum — adım adım gideriz.
