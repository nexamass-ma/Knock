# Knock Business: implementation report

Status as of 27 Nov 2026. **Nothing is live.** No Supabase project is deployed, no Breet credentials exist, and no Naira provider (9PSB) is connected. Everything below runs against local Postgres in tests, and in the browser sandbox preview. Nothing moves real money.

Status labels used below:

- **Done, tested**: implemented and covered by automated tests against real Postgres, and exercised in the browser sandbox.
- **Awaiting credentials**: code path exists and is tested against mocks or the sandbox, but has never talked to the real provider.
- **Awaiting approval**: built but switched off by a feature flag until a provider or regulator says yes.
- **Partial**: some of it is missing; the gap is named.
- **Not built**: no code.

## 1. Product architecture

Knock Business is not a second system. A business is an **account holder in the same ledger** as a person:

- `knock.profiles.kind` is `person` or `business`. Each business has a profile row and a `knock.businesses` row with the same id.
- Every existing engine (payment links, Smart Split, Breet deposits and withdrawals, risk, notifications, audit) already keys money by holder id, so they work for businesses with no duplication. There is one wallet system and one journal.
- People act for a business through `knock.business_members` with a role. Every write checks the member's permission in the database (`knock.require_business`, `knock.require_business_money`). Hiding a button is never the only check.
- The business's verification status is synced to its profile (`kyc_tier`, `status`) by a trigger, which is what gates the money engines. An unverified or restricted business cannot collect or pay out, whatever the UI does.

Parts:

| Part | Where |
| --- | --- |
| Schema, engines, permissions, risk rules, admin functions | `backend/supabase/migrations/20261127000500_business.sql`, `…000600_business_admin.sql` |
| Business and admin API (fixed operation catalogue, JWT, MFA for staff, rate limits) | `backend/src/business/` (`ops.ts`, `runner.ts`, `http.ts`, `main.ts`) |
| Breet adapter, webhook worker, reconciliation (from the crypto work) | `backend/src/crypto/` |
| Knock Business web dashboard and public payment page | `dashboard/index.html`, `dashboard/src/business/` |
| Knock Admin (separate app for staff) | `dashboard/admin.html`, `dashboard/src/admin/` |
| Browser sandbox (real migrations in PGlite, seeded through the engine) | `dashboard/src/data/` |

The Flutter customer app is unchanged and still has **no admin screens**. Knock Admin is a separate web app. Breet operations themselves stay in Breet's partner dashboard; Knock Admin only shows Knock's own records about Breet, read-only.

Both dashboards call the **same operation catalogue** (`backend/src/business/ops.ts`). Over HTTP the server binds the signed-in user from the Supabase JWT and the business from `X-Business-Id`; the browser sandbox binds a sandbox user. The client never sends SQL, amounts are minor-unit strings, and the database recomputes every amount.

## 2. Database and migrations

Two new incremental migrations. They add tables and columns; they drop nothing and rewrite no existing data.

`20261127000500_business.sql`:

- `profiles.kind` with an identity trigger (people must exist in `auth.users`; businesses must not).
- Config: `feature_flags` (with `depends_on`), `business_categories`, `business_verification_requirements` (per country and category, NG and GH seeded), `business_settings`.
- `businesses`, `business_role_permissions` (7 roles × 13 permissions), `business_members` (exactly one active owner), `business_member_permissions` (owner-only overrides), `business_documents` (private storage path, MIME, size, SHA-256), `business_representatives`, `business_verification_events` (append-only).
- `business_payout_requests` (maker-checker), and a `created_by_member` column on `payment_links`.
- Views: `holder_transactions` (one list of collections, split shares, deposits and withdrawals with a single state), `business_customers`.
- Staff: `admin_role_permissions`, `admin_action_requests` (dual approval), `watchlist_entries`, `support_tickets` and `support_messages`, `admin_alerts` with triggers; `risk_flags` gains category, reason, evidence, assignee, case status and resolution notes.
- `audit_log.business_id`. RLS is enabled on every new table, with member-scoped read policies.

`20261127000600_business_admin.sql`: link review, feature flag changes, alert acknowledgement, tickets, notification read state.

## 3. Features and status

### Business accounts and onboarding

| Feature | Status |
| --- | --- |
| Create a business from an existing Knock identity (several per person, limit in settings) | Done, tested |
| Profile: legal and trading name, description, category, country, email, phone, website, registration number | Done, tested |
| Legal fields lock once submitted; contact email change on a verified business raises a risk flag | Done, tested |
| Configurable document checklist per country and category | Done, tested |
| Document upload | **Partial.** The record (type, file name, MIME, size, SHA-256) is real. The bytes are not stored yet: production needs a private Supabase Storage bucket and a signed-upload URL step |
| Representatives with ownership | Done, tested |
| Verification statuses: not started, pending, under review, info required, verified, rejected, restricted | Done, tested |
| Logo | **Partial.** `logo_path` is stored; there is no upload UI |
| Notification preferences | Done (saved). Email delivery **awaiting credentials** (no email service) |

### Business dashboard

| Feature | Status |
| --- | --- |
| Overview: available, pending and reserved balance; collected; paid out; fees; success rate; average; counts; customers; daily chart; top links; recent activity; pending approvals; risk | Done, tested. Every figure is a query over the ledger and payment tables |
| Date filters: today, yesterday, 7, 30, 90 days, custom | Done |
| Transactions: filters, search, CSV export, detail with ledger lines and lifecycle | Done, tested |
| Customers and analytics (by type, by link, by weekday) | Done |
| Team: invite by Knock username, 7 roles, owner-only per-person overrides, remove | Done, tested (server-side checks) |
| Settings: profile, verification, notifications, payout approval threshold, support tickets, audit log | Done |
| Notifications in the dashboard | Done (in-app) |
| Landing page, sign-up and login screens | **Not built.** The dashboard expects a Supabase session. The sandbox has a user switcher instead |

### Payment links

| Feature | Status |
| --- | --- |
| Fixed or flexible amount, description, invoice and customer reference, expiry, fee paid by business or customer | Done, tested |
| QR, copy, share, pause, resume, close, payment history, export | Done |
| Hosted checkout (details, pay with crypto: one Breet address per payment, exact amount, network, QR, 30-minute timer, live status from Breet webhooks, receipt, underpay/overpay held for review, late payments still matched) | Done; awaiting Breet credentials. `POST /v1/checkout/:slug` + `pub.checkout`. Sandbox panel plays the wallet and Breet |
| Bank transfer checkout (Naira) | Not started: shown as "coming soon" until 9PSB collections exist |
| Business webhooks (Developers page: HTTPS endpoints, event selection, signing secret shown once and rotatable, signed deliveries with retries, test event, redelivery, delivery log) | Done. Worker `backend/src/business/webhooks-out.ts`; the sandbox cannot send, so deliveries there are marked queued |
| Crypto links | **Awaiting credentials.** The engine and checkout are built; per-payment Breet addresses for link checkout are not wired to a live Breet account |
| Naira links | **Awaiting approval.** Off (`business.ngn_collections`). Needs the 9PSB collections API and contract. Breet is not a Naira gateway |

### Smart Split

| Feature | Status |
| --- | --- |
| Percentage or fixed allocations, verified Knock recipients, live calculator, remainder to creator | Done, tested |
| Settlement modes: each payment, on target, manual | Done, tested |
| Shares only after the payment is confirmed; never twice (idempotent journal keys); failures roll back and retry | Done, tested |
| Rules lock at the first payment; changes create a new version | Done, tested (engine) |
| Split dashboard: expected, collected, remaining, per-recipient received and pending, failed and held distributions, "distribute now" | Done |
| Split templates | **Partial.** Saved recipient groups exist in the engine; there is no template picker in the web dashboard |

### Crypto (Breet)

| Feature | Status |
| --- | --- |
| Assets and networks from Breet (nothing hardcoded) | Awaiting credentials |
| Business deposit addresses (requested, then recorded from Breet's response or webhook), QR, warnings | Awaiting credentials. Sandbox plays Breet's response |
| Deposit lifecycle: pending, below minimum, under review, KYT hold, failed, completed; credit only on verified `completed` | Awaiting credentials. Tested with the Breet mock |
| Business crypto payouts with maker-checker | **Awaiting approval.** Off (`business.crypto_payouts`). Needs Breet credentials, the withdrawal PIN, Knock's transaction-authorisation service, and Breet's answer on paying out a Naira balance in crypto |
| Bank payouts (NGN, GHS) | **Awaiting approval.** Off (`business.bank_payouts`). Needs Breet saved-bank creation confirmed (or 9PSB transfers) |
| Auto-settlement to bank | **Awaiting approval.** Off (`business.auto_settlement`). Per-address settlement is built; Breet's business-wide setting is in their dashboard only and Knock just records it |

### Withdrawals (approvals)

| Feature | Status |
| --- | --- |
| Request, review screen, irreversibility warning, confirmation | Done |
| Second approver above the business's threshold; requester cannot approve their own | Done, tested |
| Reserve in the ledger only on approval; open high-severity risk alert blocks it | Done, tested |
| Provider status tracking on each request | Done (sandbox plays Breet's events) |

### Knock Admin (separate staff app)

23 sections, each gated by a staff permission and MFA (aal2): Overview, Earnings, Transactions, Crypto deposits, Withdrawals, Settlements, Payment links, Smart Split, Users, Businesses, Verification queue, Support, Risk and fraud, Watch and block lists, Approvals, Breet monitoring, Webhooks, Reconciliation, System health, Alerts, Audit log, Staff and roles, Flags and limits. That covers the 21 sections in the brief; Reports is covered by the CSV exports and Earnings.

| Feature | Status |
| --- | --- |
| Staff roles: super admin, finance, operations, risk, KYC, support, analyst | Done, tested |
| MFA required for every admin operation | Done, tested (Supabase `aal2` claim) |
| Business review: start review, ask for info, verify, reject, with notes the business sees | Done, tested |
| Restrict and unrestrict users and businesses with evidence and a second approver | Done, tested |
| Blocklist entries need evidence and a different approver; allowlist only silences one rule's alert | Done, tested |
| Risk cases: assign, status, resolution notes (required to resolve) | Done, tested |
| Earnings: customer funds, business funds, awaiting distribution, provider-held, Knock bank, Knock revenue, provider costs, fee breakdown; customer money never counted as revenue | Done, tested. Operating expenses are not in the ledger, so net is "before operating expenses" |
| Breet monitoring: connection, API calls, webhook status, pending items, unreconciled items, ledger view of the Breet wallet | Done, read-only. No Breet settings or actions in Knock Admin, by your earlier instruction |
| Granting staff roles from the UI | **Not built** on purpose. It is a reviewed database change |

## 4. Breet endpoints integrated

All calls are server-side, in `backend/src/crypto/breet/adapter.ts`, using `x-app-id`, `x-app-secret` and `X-Breet-Env`. None has been called against real Breet (no credentials).

`GET /trades/assets`, `GET /payments/supported-assets-info`, `POST /trades/sell/assets/{id}/generate-address`, `GET /trades/wallets`, `PUT /trades/wallets/{id}/auto-settlement`, `PUT /trades/wallets/{id}/bank`, `GET /trades/transactions`, `GET /trades/transactions/{id}`, `POST /payments/withdraw/address`, `POST /payments/withdraw/bank/{id}`, `GET /payments/withdrawal/{id}`, `GET /payments/withdrawals`, `POST /payments/wallet-addresses/validate`, `POST /payments/estimate-network-fee`, `GET /transactions/webhooks`, `POST /transactions/webhooks/resend/{ref}`, and `POST /trades/sell/mock-trade` (sandbox only; refused in production). Details: `docs/BREET_INTEGRATION.md`.

## 5. Webhook events

`trade.pending`, `trade.completed`, `trade.flagged`, `trade.deleted`, `trade.settlement.failed`, `trade.address.created` (wrong-asset recovery), `withdrawal.pending`, `withdrawal.processing`, `withdrawal.completed`, `withdrawal.reversed`, `withdrawal.rejected`.

Each event: source IP check, constant-time secret check, stored before processing, deduplicated by `eventId`, ordered by `eventTime`, then the trade or withdrawal is **re-fetched from Breet** and only that answer is applied. Terminal states never move back. Failures retry with backoff and raise an admin alert.

### Hosted checkout (Breet e-commerce flow)

1. The payer opens the link, enters name and email (and reference if required) and picks crypto.
2. `knock.checkout_open` prices it (`checkout_quote`), creates the payment intent with a 30-minute quote and a requested address row. The server calls Breet `generate-address` with `label` = the payment's Knock reference and records the address (a lost response is recovered from `trade.address.created` by that label).
3. The page shows the exact amount, network, address and QR, and polls `pub.checkout`.
4. Breet deposit webhooks for a checkout address go to `knock.checkout_deposit_event` instead of a wallet: `trade.pending` shows "detected, confirming"; `trade.flagged` holds it (nothing credited); `trade.deleted` fails it; `trade.completed` confirms it through `confirm_payment` with the crypto amount Breet reports. A different amount is recorded as received and held for review (Breet's FAQ: underpayments still fire the webhook). A second transfer to the same address is flagged for staff, never dropped. Terminal states never go back.
5. Unpaid checkouts expire after 30 minutes; a late transfer is still matched.

Open with Breet: the payment ledger is kept in the crypto received, while Breet credits Knock's wallet in its holding currency (NGN/USD). The Breet amount is stored on the payment (`settlement_amount`) for reconciliation; how Knock settles crypto-link payments from Breet's fiat balance needs Breet's confirmation.

### Business webhooks (Knock to the business)

Events: `payment.pending`, `payment.held`, `payment.succeeded`, `payment.failed`, `payment.expired`, `deposit.completed`, `payout.completed`, `payout.failed`, plus `test.ping`. Body: `{id, type, created_at, livemode, data}`. Headers: `knock-event-id`, `knock-event-type`, `knock-signature: t=<unix>,v1=<hex HMAC-SHA256(secret, "t.body")>`. Retries after 1m, 5m, 30m, 2h, 6h, 12h, 24h (8 attempts), then failed; the business can resend. Endpoints must be HTTPS public hosts; the worker resolves DNS, refuses private, loopback, link-local and metadata addresses, pins the checked address, and does not follow redirects. Up to 5 endpoints per business; managing them needs `settings.manage`.

## 6. Financial ledger

Double-entry, append-only (`knock.journal_entries`, `knock.journal_lines`), amounts in integer minor units (`numeric(38,0)`), no floating point anywhere, including the dashboards (BigInt). `knock.post_entry` refuses an entry whose lines don't sum to zero per currency and refuses a reused idempotency key with different content. Corrections are new entries.

Accounts per holder and purpose: `user_available`, `user_pending`, `user_withdrawal_reserved`, `user_settlement_reserved`, plus `link_collection`, `provider_clearing`, `provider_wallet`, `settlement_bank`, `fee_revenue`, `provider_fee_expense`, `settlement_variance`, `recovery_receivable`. A business's balances are just these accounts with the business as owner. System health shows unbalanced entries and negative liabilities; both must be 0 and are.

## 7. Payment links

Business wrappers (`business_create_link`, `business_link_action`) check the member's permission and the right feature flag, then call the existing engine: quote, payment intent, provider-verified confirmation, settlement from pending to available. The payment page reads only public fields and asks the database for the quote, so the browser never decides an amount.

## 8. Smart Split

Same engine as Knock Personal. Shares use largest-remainder rounding so they always add up. A distribution is one balanced entry with immutable allocations; any failure rolls the whole split back and schedules a retry. The worked example in the brief (₦100,000 at 40/30/20/10) is an automated test.

## 9. Admin dashboard

See section 3. Every admin action goes through `require_staff_perm(user, permission, aal)` in the database, is written to `audit_log` (with the business id where relevant), and the sensitive ones go through `admin_action_requests` so a second staff member applies them.

## 10. Security

- Server-side permission checks for every business and staff operation; fixed operation catalogue, so clients cannot send SQL; parameters typed and validated (UUIDs checked before the database).
- Supabase JWT verification; staff need MFA (`aal2`).
- Rate limits per user and per IP; CORS allowlist; security headers; internal errors are never echoed.
- Maker-checker payouts and dual approval for restrictions and blocklisting.
- No provider secrets or PINs in either dashboard, the API responses, or the logs (tested).
- Audit details shown in the dashboard filter out keys that look like hashes, secrets or tokens.
- Remaining risks: no penetration test, no load test, document bytes not yet stored or virus-scanned, no device binding or transaction PIN service yet (withdrawals are refused until it exists).

## 11. Test results

- **Backend:** `cd backend && TEST_DATABASE_ADMIN_URL=… npm test` gives **99 of 99 passing** against Postgres 16: 16 payment link tests, 47 Breet crypto tests (including 6 hosted checkout tests over the Breet-shaped test server) and 36 Knock Business tests (including signed webhook delivery, retries, the SSRF guard and owner sign-up). The business tests cover onboarding, verification gates, MFA, team permissions, links settling from pending to available, the 40/30/20/10 split, Breet deposits for a business, maker-checker payouts, the overview and earnings figures, ledger balance, blocklist approval, dual-approval restriction, risk rules, and the HTTP API (auth, MFA, business scoping, every read operation).
- **Typecheck:** `tsc --noEmit` clean for backend and dashboard.
- **Browser:** every page of both dashboards loads with no console errors (Chromium). End to end in the sandbox: create a fixed link, open the hosted checkout, get an address, payment detected, confirmed, receipt; an 80% underpayment shown as received and under review; add a webhook endpoint, see the signed request and a 500 answer scheduled for retry; request a payout (correctly blocked by an open AML alert); request a BTC address and record Breet's response; upload verification documents.
- **Not tested:** anything against real Breet or 9PSB; load; the deployed infrastructure.

## 12. Known limitations

- Not deployed. The preview runs Postgres in the browser and resets on reload.
- Document bytes and logos are not stored yet (metadata only).
- Sign-up and login in the preview use an in-browser stand-in for Supabase Auth; in production they call Supabase Auth (email + password), and NIN/BVN checks wait on a KYC partner (directors show "Awaiting check").
- Split templates are not exposed in the web dashboard.
- Crypto payouts of a Naira balance depend on Breet's answer about buying or paying from a USD wallet.
- Operating expenses are not in the ledger, so Knock net earnings are before expenses.
- Email, SMS and push delivery are not connected; notifications are in-app only.

## 13. Provider approvals needed

From Breet, in writing: the pooled multi-customer model (including business funds), permanent addresses per business, customer-specific withdrawals, third-party funds, business-wide auto-settlement and how it interacts with per-address settlement, a balance endpoint, webhook resend access, fees and limits, and the open response field names listed in `docs/BREET_INTEGRATION.md`.

From 9PSB: the collections API (virtual accounts) for Naira links, transfers for bank payouts, and the contract.

Regulatory: a legal opinion on custody and VASP status, CBN cover through 9PSB for Naira wallets, a payment aggregator arrangement for collecting on behalf of businesses, and NFIU registration and STR process.

## 14. Environment variables (server only)

| Variable | Purpose |
| --- | --- |
| `DATABASE_URL` | Service-role Postgres connection |
| `SUPABASE_JWT_SECRET` | Verifies sessions for the business and admin API |
| `DASHBOARD_ORIGINS` | CORS allowlist for the two dashboards |
| `TRUSTED_PROXIES` | Proxies whose `X-Forwarded-For` is trusted |
| `PORT` | Business API port |
| `KNOCK_ENV`, `BREET_SANDBOX_*`, `BREET_PRODUCTION_*`, `BREET_PRODUCTION_CONFIRM`, `BREET_TIMEOUT_MS` | Breet service, see `docs/BREET_INTEGRATION.md` |

The dashboards need only the public Supabase URL and anon key. Never put Breet secrets, PINs or the service-role key in them.

## 15. Production deployment checklist

1. Create the Supabase project; run all migrations; turn on MFA for staff accounts.
2. Create a private Storage bucket for business documents and add the signed-upload step.
3. Deploy `backend/src/business/main.ts` and `backend/src/crypto/main.ts` on a Node host next to Supabase; set the variables above in a secrets manager.
4. Point the two dashboards at the business API instead of the browser sandbox (swap `Sandbox.run` for an HTTP call to `POST /v1/ops/:name`; the operation names are the same) and remove the sandbox controls from the production build.
5. Grant staff roles through a reviewed migration.
6. Run the Breet sandbox test plan with real sandbox credentials; fix any field-name gaps in `adapter.ts` only.
7. Get Breet's and 9PSB's written approvals, then turn on flags one at a time in Knock Admin: crypto deposits, crypto links, then payouts, then Naira links.
8. Register the Breet webhook URL; run small controlled deposits and withdrawals; watch Webhooks, Reconciliation and System health.
9. Rollback: turn the flags off and remove the webhook URL. Funds stay where the ledger says.

## Owner sign-up, login and verification

- **Home page** (`#/`): what Knock Business does, how it works, trust notes, and links to sign up or log in.
- **Sign up** (`#/signup`), strictly for business owners: full name, business name, category, email, phone, password. No CAC or ID documents are asked for here. `register_business_owner` creates the person profile and the business with the signer as owner, and they land straight in the dashboard.
- **Log in** (`#/login`): email and password; accounts that do not own or belong to a business are refused (`business_app_access`).
- **Verify later**: the dashboard shows a "Complete your profile" card until Knock approves. Settings > Verification has four steps: registration (Business name, Limited company or Incorporated trustees, CAC number), documents (CAC certificate, MEMAT for limited companies, address proof, plus optional status report and TIN), one or two directors with NIN and BVN, then submit. Collections and withdrawals stay locked until approval.
- Only the last 4 digits of NIN and BVN are stored; the full numbers go to the KYC partner once it is connected.
- Preview demo logins (password `knockdemo2026`): chanor@mamaput.example (owner, verified), mary@mamaput.example (finance), innocent@ekogadgets.example (owner).
