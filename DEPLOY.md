# Deploy — Adım 4 kılavuzu

Arc Testnet'e kontratları deploy ediyoruz. Hibrit yaklaşım:

- **Ana cüzdan** → deploy eden (kontrat sahibi), şifreli keystore'da
- **Throwaway cüzdan** → sonraki test/dev için, `.env`'de

---

## 1. Ana cüzdana USDC al

Deploy işlemi gas için USDC tüketir (Arc'ta USDC = native gas).

Ana cüzdan adresini [faucet.circle.com](https://faucet.circle.com)'a git, **Arc Testnet** seç, adresi yapıştır, 20 USDC al.

Gerekli: ~1 USDC (gas). 20 USDC fazlasıyla yeter.

---

## 2. Ana cüzdanı Foundry keystore'a import et (tek seferlik)

Bu işlem ana cüzdan private key'ini **şifreli** olarak `~/.foundry/keystores/main` dosyasına kaydeder. `.env`'de plain text olarak asla bulunmaz.

```bash
cast wallet import main --interactive
```

Sorduğu şeyler:
1. **Private key** — Metamask'tan ana cüzdanın private key'ini al, yapıştır (görünmez, terminal echo etmiyor)
2. **Password** — güçlü bir parola belirle. Her deploy'da bunu soracak. Unutma, geri alınamaz.

Çıktı:

```
`main` keystore was saved successfully. Address: 0x...
```

Görünen adres ana cüzdanının adresi olmalı. Kontrol et.

**Şifreli key konumu:** `~/.foundry/keystores/main` (WSL'de). Bu dosyayı asla kimseyle paylaşma, ama plain key'den çok daha güvenli.

**İptal etmek istersen:** `rm ~/.foundry/keystores/main`

---

## 3. `.env`'yi deploy için güncelle

`.env` dosyasını aç, şu satırların olduğundan emin ol:

```bash
# Deploy için gerekli
USDC_ADDRESS=0x3600000000000000000000000000000000000000
ARC_TESTNET_RPC_URL=https://rpc.testnet.arc.network

# Sonraki adımlar için throwaway key (Adım 2'de eklemiştin)
PRIVATE_KEY=0x...throwaway...

# Deploy sonrası doldurulacak
SERVICE_REGISTRY_ADDRESS=
PAY_PER_CALL_ADDRESS=
```

`USDC_ADDRESS` Arc'ın native USDC sistem kontratı. `.env.example`'da zaten default değeriyle geliyor.

---

## 4. Dry-run (zorunlu değil ama önerim)

Deploy'u gerçekten yapmadan önce simüle et — ne olacağını gör, gas tahminini al:

```bash
source .env

forge script script/Deploy.s.sol:Deploy \
  --account main \
  --sender <ANA_CÜZDAN_ADRESİN> \
  --rpc-url arc_testnet
```

`<ANA_CÜZDAN_ADRESİN>` yerine adresini yaz (`0x` ile başlayan). `cast wallet import` çıktısında göstermişti.

`--broadcast` bayrağı olmadığı için gerçek tx yollanmaz. Parola sorar (simülasyon için gerekli), sonra konsola şunu yazar:

```
== Logs ==
  Deployer       : 0xYOUR_ADDRESS
  USDC           : 0x3600000000000000000000000000000000000000
  Min stake      : 10000000 (6 decimals)
  ServiceRegistry: 0x... (preview)
  PayPerCall     : 0x... (preview)
  Wired PayPerCall -> ServiceRegistry
```

**Yeşil ışık kriterleri:**

- Deployer adresi doğru mu? (ana cüzdan)
- USDC adresi doğru mu? (`0x3600...0000`)
- "Wired..." satırını görüyor musun?

Her şey iyiyse bir sonraki adıma geç.

---

## 5. Gerçek deploy

`--broadcast` ekleyerek gerçek tx'leri yolla:

```bash
forge script script/Deploy.s.sol:Deploy \
  --account main \
  --sender <ANA_CÜZDAN_ADRESİN> \
  --rpc-url arc_testnet \
  --broadcast
```

Parola sorar. 3 tx yollanır:

1. `ServiceRegistry` deploy
2. `PayPerCall` deploy
3. `registry.setPayPerCall(payPerCall)` çağrısı

Arc'ın sub-saniye finalitesi sayesinde 3-5 saniyede biter. Çıktıdaki kontrat adreslerini **kopyala** ve `.env`'ye yaz:

```bash
SERVICE_REGISTRY_ADDRESS=0x...
PAY_PER_CALL_ADDRESS=0x...
```

Ayrıca `broadcast/` klasörünün altında tx hash'leri otomatik kaydedilir — hepsini Arcscan'de görebilirsin:

```
https://testnet.arcscan.app/tx/<TX_HASH>
https://testnet.arcscan.app/address/<CONTRACT_ADDRESS>
```

---

## 6. Deploy sonrası doğrulama

WSL'de hızlı bir `cast` komutu ile kontratın düzgün çalıştığını doğrula:

```bash
source .env

# ServiceRegistry'nin admin'i ana cüzdanın mı?
cast call $SERVICE_REGISTRY_ADDRESS "admin()(address)" --rpc-url arc_testnet

# payPerCall doğru set edilmiş mi?
cast call $SERVICE_REGISTRY_ADDRESS "payPerCall()(address)" --rpc-url arc_testnet

# PayPerCall'ın registry'si doğru mu?
cast call $PAY_PER_CALL_ADDRESS "registry()(address)" --rpc-url arc_testnet
```

Beklenen sonuçlar:
- İlk çıktı = ana cüzdan adresin
- İkinci çıktı = `PAY_PER_CALL_ADDRESS`
- Üçüncü çıktı = `SERVICE_REGISTRY_ADDRESS`

Üçü de doğruysa **deploy başarılı**.

---

## Sorun giderme

**`Error: signer is not authorized`** → `--sender` adresi `main` keystore'daki adresle eşleşmiyor. `cast wallet list` ile kontrol et.

**`Error: insufficient funds`** → Ana cüzdanda yeterli USDC yok. Faucet'ten daha fazla al.

**`Error: no such keystore`** → Adım 2'yi atladın, `cast wallet import main --interactive` ile ekle.

**`EvmError: InvalidFEOpcode`** → Solidity 0.8.24 Arc tarafından desteklenmiyor olabilir. `foundry.toml`'da `solc_version = "0.8.20"` olarak değiştir, `forge clean && forge build` ile yeniden derle.

**Dry-run başarılı ama `--broadcast` ile takılıyor** → RPC endpoint yavaş olabilir. 30 saniye bekle, Ctrl+C ile kapat, tekrar dene.

---

Deploy başarılı olduğunda bana **kontrat adreslerini** yaz, **Adım 5**'e geçeriz: demo HTML + ilk canlı test (provider register → callService → submitReceipt akışı).
