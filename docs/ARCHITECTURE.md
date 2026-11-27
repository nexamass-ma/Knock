# KNOCK architecture (prototype → production)

## The rule that shapes everything

The assistant never prices and never moves money. It turns what the user says into an **intent** plus the values the user typed or tapped. The **backend** prices it, validates it, and only executes it with a **user authorisation** produced natively on the device.

```
User text ──► ConversationService ──► Interpretation {flow, fields}      (no prices)
                                              │
                    AssistantController asks for any missing fields
                                              │
                                              ▼
                          QuoteService.requestQuote(QuoteRequest)  ──► backend prices,
                                              │                        checks limits/KYC,
                                              ▼                        returns signed quote
                                   Quote card (expires)
                                              │ user taps Confirm
                                              ▼
                     Native authorise sheet (biometrics or PIN) ──► AuthorizationProof
                                              │
                                              ▼
     TransactionService.execute(quote, proof, idempotencyKey) ──► backend verifies proof,
                                                                   posts ledger entries,
                                                                   settles with provider
```

`AssistantController.confirm` requires an `AuthorizationProof`, and only `showAuthorizeSheet` creates one, after the user verifies. Nothing in the conversation path can produce it.

## Service contracts (`lib/services/contracts.dart`)

| Contract | Production backing (via KNOCK backend) |
| --- | --- |
| `WalletService`, `ActivityService` | Ledger service: Naira wallet, crypto and card ledgers |
| `QuoteService` | Pricing engine over liquidity providers (crypto), gift card trading partners, bill aggregators |
| `TransactionService` | Execution + settlement, idempotent on key |
| `GiftCardRecognitionService` | Server-side card recognition + partner verification |
| `ConversationService` | LLM intent extraction returning structured JSON |
| `CardWaitlistService` | Early-access list for the dollar card |

The app talks only to the KNOCK backend. Providers are swapped behind it without an app release. Replace the mocks in `AppServices.mock()` with HTTP implementations.

## Ledgers

Three separate ledgers: **Naira**, **Crypto**, **Dollar card** (locked). The client never merges or adjusts balances; after every transaction it re-fetches. Production uses double-entry, append-only journal entries; corrections are new entries. Daily reconciliation against provider statements.

## Security checklist

| Area | Prototype | Production |
| --- | --- | --- |
| Authentication | PIN lock screen (mock verify), session token in secure storage | Phone + OTP onboarding, device binding, short-lived access token, rotating refresh token |
| Biometrics | `local_auth` with PIN fallback | Biometrics unlock a device-bound key (Secure Enclave / Android Keystore) that signs a server challenge per quote |
| Local secrets | `flutter_secure_storage` (Keychain this-device-only, Keystore) | Same. No private keys, PINs, card numbers or CVVs on device |
| Transport | n/a (mock) | HTTPS with public-key pinning (`ApiConfig.pinnedKeyHashes`) |
| Session | Auto-lock after 2 min in background | Same, plus server-side session revocation and device list |
| Device integrity | n/a | Play Integrity / App Attest at login and before high-risk actions |
| Transaction integrity | Quote IDs, expiry, single use, idempotency keys, proof must match quote | Same, enforced server-side; signed quotes |
| Limits & KYC | Tier 1 limit enforced in mock pricing | KYC tiers from KYC partner (BVN, ID, liveness); limits per tier server-side |
| Fraud & AML | n/a | Fraud scoring on every quote/execution; sanctions and AML screening; gift card fraud checks |
| Audit | Audit trail shown per transaction | Immutable audit log of every quote, authorisation and ledger posting |

Rules the production client must follow are written out in `lib/services/security/api_client.dart`.

## Not done in the prototype

- No real backend, KYC, payments, custody or card issuing.
- iOS was not compiled or run in this environment (no Xcode). Android APK is built by GitHub Actions.
- `android:allowBackup` is off; a release signing key, ProGuard/R8 rules review, and screenshot protection on sensitive screens are still to do.
