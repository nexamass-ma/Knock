# KNOCK Payment Links & Smart Split

Status as of 27 Nov 2026: **demo in the app runs on an in-app sandbox; the Supabase backend is built and tested locally but not deployed; no payment provider is connected.** Nothing in this feature moves real money yet.

## What is where

| Part | Location | State |
| --- | --- | --- |
| App screens (dashboard, create flow, live split calculator, link detail tabs, payer page, share + QR, notifications, admin) | `lib/features/payment_links/` | Working in the APK, on the sandbox engine |
| In-app sandbox engine (same split maths, double-entry postings, idempotency keys and states as the server) | `lib/features/payment_links/pl_sandbox.dart` | 19 acceptance tests in `test/payment_links_test.dart` |
| Postgres schema, double-entry ledger, split engine, disputes, reversals, amendments, reconciliation, RLS | `backend/supabase/migrations/` | 16 tests pass against real Postgres 16 (`backend/test/engine.test.ts`) |
| Webhook verification (Paystack HMAC-SHA512, Flutterwave hash, timestamped HMAC-SHA256), provider interfaces, sandbox providers, Paystack adapter, service layer, rate limits | `backend/src/` | Tested against sandbox providers; Paystack adapter untested against Paystack |

Run backend tests: `cd backend && npm install && npm test` (needs a Postgres; set `TEST_DATABASE_ADMIN_URL`).

## How money moves (server)

1. Payer opens the link. `knock.checkout_quote` checks status, expiry, limits and remaining target, and prices the fee.
2. The provider opens a session (virtual account, card checkout or unique crypto address). `knock.create_payment_intent` records it. Nothing is credited.
3. Provider webhook: signature checked, stored once by event id, then the transaction is **re-fetched from the provider's verify API**. Only that answer is passed to `knock.confirm_payment`.
4. `confirm_payment` reconciles currency, network, tx hash, confirmations and amount, then posts `provider_clearing → link_collection` and the Knock fee, in one transaction.
5. Depending on the settlement mode the payment is split straight away, held until the target, or held for manual distribution. `knock.distribute_payment` computes every share with largest-remainder rounding (shares always add up exactly), posts one balanced entry and writes immutable allocations. If any recipient cannot be credited, the whole split rolls back, the money stays in the link's collection account and a retry is scheduled with back-off.
6. Recipient shares are **pending** until the provider settles to Knock, then **available**. Disputes move shares to **held**; lost disputes and refunds reverse every line, and any amount a recipient already spent becomes a recovery receivable.

Rules: journals, allocations and audit are append-only; split rules lock at the first payment and change only through an amendment that recipients whose share drops must approve; past allocations keep their rule version. `knock.reconcile()` returns every mismatch between ledger, payments and allocations (empty = clean).

## Live / sandboxed / needs credentials / needs approval

**Live:** nothing. No backend is deployed and no provider is connected.

**Sandboxed (works end to end in the demo or local tests):** link creation (Naira fixed/flexible, crypto, split), username lookup, fixed and percentage splits, partial-allocation mode, live calculator, all three settlement modes, fees deducted or paid by payer, partial and multiple payments, crypto confirmations and wrong-network rejection, duplicate and forged webhook handling, failed-credit rollback and retry, provider settlement, disputes, refunds, chargebacks, pause/resume/expire/close, amendments, saved recipient groups, notifications (in-app list only), QR and share, receipts, admin views with role checks, risk flags, reconciliation.

**Needs accounts / credentials:**
- Supabase project (URL, service role key) to deploy the migrations and API.
- Naira collections: Paystack or Flutterwave merchant account (secret key, webhook secret), plus dedicated virtual accounts for bank transfer.
- Crypto: a licensed crypto payment provider for deposit addresses and confirmations, and a rate feed from the liquidity partner.
- Push, SMS and email delivery (e.g. FCM, Termii, Postmark) for notifications outside the app.
- Payouts from Knock wallets to bank accounts (transfer API) if recipients will withdraw.

**Needs regulatory or commercial approval:**
- Holding customer money in Naira wallets and splitting it to other users needs a CBN licence (PSSP / MMO) or a sponsor bank / MFB arrangement. Collecting for third parties may also need a payment aggregator arrangement with the provider.
- Crypto collection and crediting falls under SEC (ISA 2025) and the CBN virtual asset rules; it should run only through a registered partner.
- AML/CFT: NFIU registration, KYC thresholds, transaction monitoring and STR process for links and splits.
- Commercial: Knock fee (placeholder 1.5% capped at ₦2,000, crypto 1%), tier limits, confirmation depths, refund and chargeback liability between creator and recipients.

All numbers marked [Guess] in code are placeholders.
