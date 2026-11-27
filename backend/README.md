# KNOCK Payment Links backend (Supabase)

- `supabase/migrations/`: schema `knock`: double-entry ledger, split engine, disputes, reversals, amendments, reconciliation, RLS. Apply with `supabase db push`.
- `src/`: service layer (checkout, verified webhooks), webhook signature checks, provider interfaces, sandbox providers, Paystack adapter, rate limiter.
- `test/engine.test.ts`: acceptance tests against a real Postgres.

```bash
npm install
TEST_DATABASE_ADMIN_URL=postgresql://postgres@localhost:5432/postgres npm test
npm run typecheck
```

Not deployed. See ../docs/PAYMENT_LINKS.md for what is live, sandboxed, and what needs credentials or approval.
