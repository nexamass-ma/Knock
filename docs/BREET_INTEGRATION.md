# Breet crypto integration: status report

Status on 2026-11-27. **Nothing is deployed or live.** No Breet credentials have been used. All results below come from local Postgres 16 and a Breet-shaped test server (`backend/test/breet-mock.ts`) built from docs.breet.io. Anything that real Breet sandbox testing still has to confirm is marked **[confirm in sandbox]**.

Instructions from Chanor on 2026-11-27:
- **No admin in the customer app.**
- **No Knock-built Breet admin.** Operations use the Breet Partner Dashboard.
- Knock keeps its own ledger, safety checks, exception records and reconciliation in the backend, without a UI.

## A. Technical audit (before changes)

| Area | Found | Reused? |
| --- | --- | --- |
| Backend | Supabase Postgres schema `knock` plus a small TypeScript service in `backend/`, at the time for Payment Links only | Yes |
| Ledger | Double-entry, append-only, idempotent `knock.post_entry`, balance checks | Yes, the only ledger |
| Customers / roles | `knock.profiles` (KYC tier, status), `knock.staff_roles` | Yes (roles widened) |
| Webhooks | `knock.webhook_events`, unique `(provider, event_id)` | Yes (columns added) |
| Risk, notifications, audit | `risk_flags`, `notifications`, `audit_log` | Yes |
| App | Flutter app on an in-app sandbox backend (`lib/sandbox`). Crypto receive was a fake address with instant credit | Replaced with the real lifecycle |
| Missing | Deployed Supabase project, HTTP server, job queue, KYC provider, secrets manager, any crypto provider | HTTP server and worker built. The rest is still to do |

## B. Database changes

Two new migrations (additive). Nothing is dropped and existing rows keep their meaning.

- `20261127000300_crypto_provider.sql`: tables, constraints and indexes.
  - New tables: `provider_accounts`, `provider_asset_configurations`, `crypto_fee_schedule`, `approval_thresholds`, `bank_accounts`, `provider_wallet_addresses`, `crypto_deposits`, `provider_withdrawals` (with views `crypto_withdrawals` and `bank_withdrawals`), `settlements`, `settlement_exceptions`, `provider_fee_records`, `provider_api_logs`, `provider_rate_limits`, `provider_event_processing_logs`, `provider_reconciliation_runs`, `provider_reconciliation_records`, `staff_action_requests`.
  - Widened: the `ledger_accounts.purpose` check, which now includes `user_withdrawal_reserved`, `user_settlement_reserved`, `provider_wallet` and `settlement_variance`. Also widened: the `staff_roles.role` check, which now includes `super_admin`, `finance_manager`, `operations_manager`, `risk_officer`, `support_agent`, `analyst` and `technical`.
  - Columns added: `webhook_events` gains the status, attempts, `event_time`, `resource_id`, source IP and delivery count columns. `risk_flags` gains a subject.
  - `knock.account()` is redefined so the new asset accounts are debit-normal.
- `20261127000400_crypto_engine.sql`: every money movement as a single-transaction plpgsql function.
  - Functions: `request_deposit_address`, `record_deposit_address`, `record_deposit_state`, `complete_crypto_deposit`, `reserve_withdrawal`, `begin_withdrawal_submission`, `withdrawal_accepted`, `withdrawal_unknown`, `release_withdrawal`, `apply_withdrawal_status`, `settlement_failed`, `request_settlement_recovery`, `approve_staff_action`, `execute_settlement_release`, `create_settlement_replacement`.
  - Also adds the `customer_crypto_activity` view and RLS.

**Constraints and indexes**
- Unique keys: event id, provider trade id, provider withdrawal id, and provider address id. Address strings are also unique.
- One live address per customer, asset and network.
- One live replacement payout per settlement exception.
- The idempotency key is unique.
- A completed deposit must have a ledger entry.
- Fee records are append-only.

**Money:** ledger values are integer minor units. Provider figures are stored as exact `numeric`, never floats. The JSON parser keeps each number's source text.

**RLS:** enabled on every new table, and `public` access is revoked. Customers can only read their own addresses, deposits, withdrawals and bank accounts. Only the service role writes.

**Rollback:** the migrations only add things. To roll back, deploy the previous app version. The new tables can stay, or be dropped if they hold no rows. Financial rows are never deleted.

## C. Breet API integration

**Adapter:** `backend/src/crypto/breet/adapter.ts`. It implements the provider-independent interface `CryptoProvider` (`backend/src/crypto/provider.ts`). No other code calls Breet.

| Endpoint | Used for |
| --- | --- |
| `GET /trades/assets`, `GET /payments/supported-assets-info` | Asset, network and fee sync (`syncAssets`). Nothing hardcoded |
| `POST /trades/sell/assets/{id}/generate-address` | Address with `label` = Knock user id. Also `bankId`, `accountNumber`, `narration` and `autoSettlement` |
| `GET /trades/wallets`, `PUT /trades/wallets/{id}/auto-settlement`, `PUT /trades/wallets/{id}/bank` | Address reconciliation and per-address settlement |
| `GET /trades/transactions[/{id}]` | Verification before every deposit change, and reconciliation |
| `POST /payments/withdraw/address`, `POST /payments/withdraw/bank/{id}` | Withdrawals, sent once with `pin` and `externalId` (the Knock reference) |
| `GET /payments/withdrawal/{id}`, `GET /payments/withdrawals` | Verification, unknown-outcome resolution, reconciliation |
| `POST /payments/wallet-addresses/validate`, `POST /payments/estimate-network-fee` | Destination format check, UTXO fee levels |
| `GET /transactions/webhooks`, `POST /transactions/webhooks/resend/{ref}` | Recovery. A 403 is reported as "Knock does not have resend access yet" |
| `POST /trades/sell/mock-trade` | Sandbox only. The adapter refuses it in production |

**Authentication:** the `x-app-id`, `x-app-secret` and `X-Breet-Env` headers are built from one config object (`backend/src/crypto/config.ts`).
- **Separate variables:** sandbox and production use different names (`BREET_SANDBOX_*` and `BREET_PRODUCTION_*`).
- **Production guards:** production needs `BREET_PRODUCTION_CONFIRM=i-understand-real-funds`, and the service refuses identical sandbox and production App IDs.
- **Start-up check:** the service checks the database environment (`provider_accounts.environment`) and refuses to run against the other environment.
- **Rotation:** secrets are read on every call. A previous webhook secret is accepted during a rotation window, and an App ID change is audited.

**Logging:** `provider_api_logs` records route template, status, outcome, duration, rate-limit headers, correlation id and the provider message. It never stores headers, bodies, secrets or PINs, and a test checks this.

**Rate limits:** a Postgres-backed limiter is shared by all instances, with limits of 200, 5 and 5 per minute on the three listed routes and 500 elsewhere. A 429 pauses that route for `Retry-After`.

**Retries:**
- GET requests retry 429 and 5xx with backoff and jitter.
- Financial POSTs are sent once. A timeout, network error or 5xx becomes `submission_unknown`, and is resolved by finding our `externalId` in `GET /payments/withdrawals`. If it isn't found after 15 minutes, the reservation is released. It is never re-sent blindly.
- A 429 on a withdrawal re-queues it, which is safe because a 429 means it was not processed.

**Errors:** HTTP status and `success` decide the outcome. Message text is only used to pick the customer wording for capacity, duplicate and insufficient-balance errors. Any 4xx on a withdrawal releases the reservation the same way.

## D. Financial system

**Deposit**
- `pending`, `below_minimum` and `flagged` never credit. `under_review` opens a high-severity risk flag, and an open high flag pauses withdrawals.
- `completed` is the only credit. It debits `provider_wallet`, credits the customer `amountCredited` minus the Knock fee (zero by default), and credits Knock fee revenue. The journal key is derived from the trade id, so it can never be posted twice.
- `settledTrades` marks earlier below-minimum deposits as completed with no second credit.
- `deleted` marks the deposit `failed` with its reason.
- Wrong-asset deposits are flagged, and addresses the provider creates are recorded as recovery addresses.

**Withdrawal**
1. Checks: account status, KYC tier, risk flags, tier limit, asset or bank, and balance.
2. Reserve the amount plus the Knock fee into `user_withdrawal_reserved`.
3. Submit once, and store the provider id.
4. On a verified `completed`: clear the reserve, credit `provider_wallet` and record fee revenue. When the fee bearer is `business`, the Breet fee is posted to `provider_fee_expense`.
5. On a verified `reversed` or `rejected`, release the reserve back to the customer. This happens only after the provider record shows it.
6. The capacity, duplicate and insufficient-provider-balance errors release the reserve and tell the customer their funds were not debited.

**Settlement**
- An auto-settled deposit moves the customer's net amount to `user_settlement_reserved`, so the same money is never both spendable and owed to the bank.
- The `withdrawal.*` events carrying `trade` close the reserve. Any difference from what Breet debited goes to `settlement_variance` for Finance.
- `trade.settlement.failed` keeps the deposit completed, opens a `settlement_exception` and tells the customer.
- Recovery needs a finance manager. Above the threshold it needs a second, different finance manager.
- A replacement payout first re-verifies the trade with Breet and requires the approver to confirm the Breet balance. No balance endpoint is documented. Only one live replacement can exist per exception.
- The alternative recovery is releasing the money to the customer's wallet.
- The `withdrawal.*` events carrying `trade` (automatic settlement payouts) close the reserve as above.

**Fees** are stored one row per fee in `provider_fee_records`: deposit processing, conversion spread, settlement markup, provider withdrawal fee, network fee and Knock service fee. They are never merged.

**Reconciliation** (`backend/src/crypto/reconcile.ts`) reads every page of deposits, withdrawals and addresses. It reports:
- deposits completed but not credited
- deposits credited but not completed
- amount and currency mismatches
- deposits missing at Breet, and withdrawals unknown to Knock
- withdrawal state mismatches, duplicate payouts and unresolved unknown submissions
- ledger checks: credit once, nothing credited before completion, reserves matching in-flight withdrawals and open settlements, variance, and balanced entries

Each finding becomes a `provider_reconciliation_records` row with status open, investigating, awaiting provider, resolved or escalated. The same finding is not duplicated across runs, and reconciliation never changes balances.

## E. Webhook system

- **Endpoint:** `POST /webhooks/breet` (`backend/src/crypto/http.ts`).
  - The source IP must be one of Breet's five IPs. `X-Forwarded-For` is ignored unless the direct peer is a configured trusted proxy, and then the right-most untrusted hop is used.
  - `x-webhook-secret` is compared in constant time.
  - Each event is stored durably and acknowledged with a 2xx. If storage fails, the endpoint returns 503 so Breet retries.
- **Dedup:** a unique `eventId`. Repeats are acknowledged and counted in `delivery_count`, and never re-applied.
- **Ordering:** the worker claims events oldest first. Terminal states never move, and older events are ignored as stale.
- **Verification:** before applying any event, the worker fetches the trade or withdrawal from Breet.
  - If Breet hasn't caught up yet, the event is retried with backoff (30s up to 12h, 8 attempts).
  - On a conflict (amount, currency or terminal state), the event is marked failed for manual review and never applied.
- **Monitoring data:** `webhook_events` (status, attempts, last error), `provider_event_processing_logs`, `provider_accounts.webhook_last_received_at` and `provider_api_logs`. There is no UI, by your instruction.
- **Recovery:** `requeueEvent` re-queues a failed event, and `resendFromProvider` asks Breet to resend, if Knock has that permission.

## F. Admin dashboard

Not built, by instruction. Breet's dashboard covers provider operations. The Finance actions on settlement exceptions exist as backend service calls with role checks, dual approval and an audit trail. If you later want a UI for them, it has to be a separate staff tool, not part of the customer app.

## G. Test results

**Backend:** `cd backend && TEST_DATABASE_ADMIN_URL=... npm test` gives **57 of 57 passing**: 16 existing Payment Links tests and 41 new crypto tests.
- **Configuration:** environment separation, header and secret hygiene, asset sync with disabled tokens and networks.
- **Addresses:** response and webhook create one record; the API response is lost but the webhook recovers it; KYC gate.
- **Deposits:** pending never credits; completed credits once under duplicate delivery; out of order; below minimum plus top-up; failed on chain; under review leading to a risk flag; KYT hold then completion; wrong asset; a forged or unconfirmed completed event is retried and not credited; an amount mismatch is held for review.
- **Webhook security:** bad secret, bad IP, proxy header spoofing, requeue, resend with and without permission.
- **Withdrawals:**
  - crypto: PIN and `externalId` sent once, completion; reversed applied only after the provider confirms; processing; stale pending ignored; rejected
  - bank: NGN sandbox amounts, masked account, fee bearer user and business
  - refusals: insufficient provider balance, duplicate within 5 minutes, invalid address, disabled token, unsupported network, KYC, limit, capacity error
  - failures: timeout resolved by `externalId` with no resubmission; 500 after acceptance; 429 pause and resubmit; GET 5xx and 429 retry; the 5/min limit enforced across callers
- **Settlement:** auto settlement; failed settlement leading to dual approval, a balance-confirmation gate, a replacement payout and the exception resolved; release to wallet.
- **Reconciliation:** pagination with page size 2, a missed webhook detected, no duplicate records, balances untouched.
- **Customer API:** auth, transaction authorisation, idempotency key, no provider ids in responses.
- **Ledger:** entries balance, append-only.

**App:** `flutter test` gives **56 of 56 passing**, including 5 new ones. They cover the address lifecycle, confirmation progress, credit once, below-minimum aggregation, review, KYT and on-chain failure never crediting, the provider name never shown, and the deposit screen end to end.

**Not tested:** anything against real Breet sandbox (no credentials, and Breet hosts are blocked from this build environment); load tests; the deployed infrastructure.

## H. Production readiness

**Environment variables:** these are server-side only.

| Variable | Purpose |
| --- | --- |
| `KNOCK_ENV` | Selects sandbox or production |
| `DATABASE_URL` | Service-role Postgres connection |
| `SUPABASE_JWT_SECRET` | Verifies customer sessions |
| `TRUSTED_PROXIES` | Proxies whose `X-Forwarded-For` header is trusted |
| `BREET_SANDBOX_APP_ID` / `_APP_SECRET` / `_WEBHOOK_SECRET` / `_WITHDRAWAL_PIN` | Sandbox credentials. Production uses the same names with `BREET_PRODUCTION_` |
| `BREET_*_WEBHOOK_SECRET_PREVIOUS` | Old webhook secret, accepted during rotation |
| `BREET_PRODUCTION_CONFIRM` | Production only |
| `BREET_TIMEOUT_MS` | Request timeout |
| `BREET_SANDBOX_EXTRA_WEBHOOK_IPS` | Sandbox only |

**Run:** `node src/crypto/main.ts` starts the HTTP server and the worker loops: webhook queue, withdrawal sweep, health, asset sync and hourly reconciliation. It needs a Node host next to Supabase, because Edge Functions run on Deno.

**Still needed from Breet** [confirm in sandbox]:
1. Written confirmation of the pooled-funds model: many Knock customers' balances held in one Knock partner wallet.
2. Whether Breet supports buying crypto. Only the sell, deposit and withdrawal side is documented, so the app has **no "buy via Breet"** flow.
3. Response field names the docs leave open:
   - the crypto withdrawal response id key
   - the validate-address body and response
   - the shape of the `/trades/assets` list
   - the credited-amount field on `GET /trades/transactions/{id}`
   - how saved bank accounts are created (the `{id}` used by `/payments/withdraw/bank/{id}`)
4. A wallet balance endpoint. Without one, replacement payouts need a manual balance confirmation.
5. Webhook resend (VIP) access, and how business-wide and per-address settlement interact.
6. Limits, commercial fees, markup and the fee bearer.

**Still needed at Knock:**
- a Supabase project, and a Node host or worker
- a secrets manager and the AES key for bank account numbers
- transaction authorisation (device-bound signature or PIN check), wired to `verifyTransactionAuth`. Withdrawals are refused until it exists.
- a KYC provider
- Finance runbooks
- a legal opinion on custody, pooled funds and VASP status (see the licensing doc)

**Launch steps:**
1. Run the sandbox test plan against real Breet sandbox.
2. Fix any field-name gaps in `adapter.ts`, which is the only file that should change.
3. Get Breet's written approvals.
4. Set the production secrets.
5. Register the webhook URL.
6. Run small controlled production deposits and withdrawals.
7. Watch the webhook failure and reconciliation records.

**Rollback:** stop the worker and remove the webhook URL in the Breet dashboard. Funds stay where the ledger says they are.

**Customer app (in-app sandbox):** Crypto → Receive opens **Deposit crypto**.
- Customers pick the asset and network and get a permanent address with QR, copy and share.
- They see the minimum, the required confirmations and the warnings.
- Their deposit history shows customer statuses and confirmation progress.
- A clearly labelled sandbox panel sends test deposits for each documented scenario.
- Crypto withdrawals to external wallets are not in the app. Breet pays them from a USD wallet, and Knock customers hold Naira, so it needs the buy-side and USD-balance answers above. Naira bank withdrawals stay with 9PSB.
