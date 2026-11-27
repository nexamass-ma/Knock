-- KNOCK crypto provider integration (Breet first, provider-independent).
-- ---------------------------------------------------------------------------
-- Additive only. Reuses the existing knock schema:
--   ledger_accounts / journal_entries / journal_lines / post_entry  (the one ledger)
--   profiles, staff_roles, webhook_events, risk_flags, notifications, audit_log
-- Nothing is dropped and no existing row changes meaning. Two CHECK
-- constraints are widened (ledger purposes, staff roles); webhook_events and
-- risk_flags gain nullable columns.
--
-- Money conventions (same as Payment Links):
--   * Ledger amounts are integers in minor units (kobo, cents, pesewas).
--   * Provider-reported figures are kept verbatim as exact `numeric` in major
--     units (Breet reports "156000" NGN, "0.0023" BTC), never floats.
--   * Every money movement is one knock.post_entry call with an idempotency
--     key derived from the provider's id, so replays cannot double-post.
-- ---------------------------------------------------------------------------
set search_path = knock, public;

-- ---------------------------------------------------------------------------
-- 0. Widen existing constraints
-- ---------------------------------------------------------------------------

alter table knock.ledger_accounts drop constraint if exists ledger_accounts_purpose_check;
alter table knock.ledger_accounts add constraint ledger_accounts_purpose_check check (purpose in (
  -- existing (Payment Links)
  'user_available','user_pending','user_held','link_collection','provider_clearing','settlement_bank',
  'recovery_receivable','fee_revenue','provider_fee_expense',
  -- crypto provider
  'user_withdrawal_reserved',  -- customer funds reserved for an in-flight withdrawal (liability)
  'user_settlement_reserved',  -- customer funds owed to their bank by auto-settlement (liability)
  'provider_wallet',           -- Knock's balance held at a crypto provider (asset)
  'settlement_variance'        -- difference between reserved and provider-debited settlement amounts (finance review)
));
alter table knock.ledger_accounts add column if not exists provider text;

-- Staff roles from the Breet brief, alongside the existing ones.
alter table knock.staff_roles drop constraint if exists staff_roles_role_check;
alter table knock.staff_roles add constraint staff_roles_role_check check (role in (
  'support','compliance','finance','admin',
  'super_admin','finance_manager','operations_manager','risk_officer','support_agent','analyst','technical'
));

-- knock.account(): add the new debit-normal (asset/expense) purposes.
create or replace function knock.account(p_owner uuid, p_link uuid, p_purpose text, p_currency text)
returns uuid language plpgsql as $$
declare
  v_code text := p_purpose || ':' || coalesce(p_owner::text, p_link::text, 'system') || ':' || p_currency;
  v_id uuid;
  v_side text := case when p_purpose in ('provider_clearing','settlement_bank','recovery_receivable','provider_fee_expense',
                                         'provider_wallet','settlement_variance')
                      then 'debit' else 'credit' end;
begin
  select id into v_id from knock.ledger_accounts where code = v_code;
  if v_id is null then
    insert into knock.ledger_accounts (code, owner_id, link_id, purpose, currency, normal_side)
    values (v_code, p_owner, p_link, p_purpose, p_currency, v_side)
    on conflict (code) do nothing
    returning id into v_id;
    if v_id is null then
      select id into v_id from knock.ledger_accounts where code = v_code;
    end if;
  end if;
  return v_id;
end $$;

-- System account per provider (provider wallet, fee expense, variance).
create or replace function knock.provider_account(p_provider text, p_purpose text, p_currency text)
returns uuid language plpgsql as $$
declare
  v_code text := p_purpose || ':' || p_provider || ':' || p_currency;
  v_id uuid;
begin
  select id into v_id from knock.ledger_accounts where code = v_code;
  if v_id is null then
    insert into knock.ledger_accounts (code, purpose, currency, normal_side, allow_negative, provider)
    values (v_code, p_purpose, p_currency,
            case when p_purpose in ('provider_wallet','provider_fee_expense','settlement_variance','provider_clearing') then 'debit' else 'credit' end,
            p_purpose = 'settlement_variance', p_provider)
    on conflict (code) do nothing returning id into v_id;
    if v_id is null then select id into v_id from knock.ledger_accounts where code = v_code; end if;
  end if;
  return v_id;
end $$;

-- Fiat wallet currencies Breet reports in.
insert into knock.assets (code, network, kind, decimals) values
  ('USD', 'fiat', 'fiat', 2), ('GHS', 'fiat', 'fiat', 2)
on conflict do nothing;

create or replace function knock.currency_decimals(p_currency text) returns int
language sql stable as $$
  select coalesce((select decimals from knock.assets where code = upper(p_currency) and network = 'fiat'), 2)
$$;

-- Major-unit decimal -> integer minor units. Refuses anything that would
-- lose precision (Breet NGN "156000.50" -> 15600050; "1.005" USD -> error).
create or replace function knock.to_minor(p_amount numeric, p_currency text) returns numeric
language plpgsql stable as $$
declare d int := knock.currency_decimals(p_currency); v numeric;
begin
  if p_amount is null then return null; end if;
  v := p_amount * power(10::numeric, d);
  if v <> trunc(v) then
    perform knock.fail('precision', format('%s %s has more than %s decimals', p_amount, p_currency, d));
  end if;
  return trunc(v);
end $$;

-- ---------------------------------------------------------------------------
-- 1. Provider accounts and configuration
-- ---------------------------------------------------------------------------

-- One row per provider integration and environment. The service checks at
-- start-up that the database's environment matches its credentials, so a
-- sandbox database can never be driven with production keys (or vice versa).
create table knock.provider_accounts (
  provider         text not null,
  environment      text not null check (environment in ('sandbox','production')),
  app_id_fingerprint text,               -- sha256 prefix of the App ID, never the ID or secret
  status           text not null default 'configured' check (status in ('configured','active','suspended')),
  last_health_at   timestamptz,
  last_health_ok   boolean,
  last_health_detail jsonb,
  webhook_last_received_at timestamptz,
  -- Set by Finance once Settings > Automatic Settlement is configured in the
  -- provider's dashboard. Confirm with Breet how it interacts with
  -- per-address settings before enabling both.
  business_auto_settlement boolean not null default false,
  business_settlement_destination jsonb,   -- masked description only
  created_at       timestamptz not null default now(),
  primary key (provider)
);

-- Current asset / network / fee information as reported by the provider.
-- Synced from the provider; nothing here is hardcoded.
create table knock.provider_asset_configurations (
  provider        text not null,
  asset_id        text not null,           -- provider's asset id (used in generate-address)
  symbol          text not null,           -- USDT, BTC ...
  network         text not null default '', -- '' for UTXO assets
  kind            text not null default 'crypto' check (kind in ('stablecoin','utxo','crypto')),
  deposit_enabled  boolean not null default false,
  withdraw_enabled boolean not null default false,
  min_deposit      numeric,
  withdrawal_fee   numeric,
  withdrawal_fee_currency text,
  min_withdrawal   numeric,
  raw             jsonb not null,
  synced_at       timestamptz not null default now(),
  primary key (provider, asset_id, network)
);

-- Knock's own service fees per operation and currency, separate from every
-- provider fee. [Guess] All zero until commercial terms are agreed.
create table knock.crypto_fee_schedule (
  operation  text not null check (operation in ('deposit','crypto_withdrawal','bank_withdrawal')),
  currency   text not null,
  bps        int not null default 0 check (bps between 0 and 10000),
  flat_minor numeric(38,0) not null default 0 check (flat_minor >= 0),
  cap_minor  numeric(38,0),
  primary key (operation, currency)
);
insert into knock.crypto_fee_schedule (operation, currency) values
  ('deposit','NGN'),('deposit','USD'),('deposit','GHS'),
  ('crypto_withdrawal','USD'),('crypto_withdrawal','NGN'),
  ('bank_withdrawal','NGN'),('bank_withdrawal','GHS'),('bank_withdrawal','USD');

create or replace function knock.crypto_fee(p_operation text, p_currency text, p_amount numeric) returns numeric
language plpgsql stable as $$
declare f record; v numeric;
begin
  select * into f from knock.crypto_fee_schedule where operation = p_operation and currency = upper(p_currency);
  if not found then return 0; end if;
  v := floor((p_amount * f.bps + 5000) / 10000) + f.flat_minor;
  if f.cap_minor is not null then v := least(v, f.cap_minor); end if;
  return greatest(least(v, p_amount), 0);
end $$;

-- Thresholds that require a second approver. [Guess] values, in minor units.
create table knock.approval_thresholds (
  action    text not null,
  currency  text not null,
  dual_approval_above numeric(38,0) not null,
  primary key (action, currency)
);
insert into knock.approval_thresholds values
  ('settlement_replacement','NGN', 50000000),  -- NGN 500,000
  ('settlement_replacement','GHS', 500000),
  ('settlement_replacement','USD', 50000),
  ('settlement_release','NGN', 50000000),
  ('settlement_release','GHS', 500000),
  ('settlement_release','USD', 50000);

-- ---------------------------------------------------------------------------
-- 2. Customer bank accounts (payout destinations)
-- ---------------------------------------------------------------------------

-- The full account number is stored encrypted by the API layer (AES-256-GCM
-- with a key from the secrets manager); only the last 4 digits are in clear.
create table knock.bank_accounts (
  id              uuid primary key default gen_random_uuid(),
  user_id         uuid not null references knock.profiles(id),
  country         text not null check (country in ('NG','GH')),
  currency        text not null check (currency in ('NGN','GHS')),
  provider_bank_id text not null,          -- provider's bank identifier (Breet GET /payments/banks)
  provider_saved_account_id text,          -- provider's saved-account id used by POST /payments/withdraw/bank/{id}
  bank_name       text not null,
  account_name    text not null,           -- verified name from name enquiry
  account_last4   text not null check (account_last4 ~ '^[0-9]{4}$'),
  account_number_enc text not null,
  account_number_hash text not null,       -- HMAC for duplicate detection without decrypting
  verified_at     timestamptz,
  status          text not null default 'active' check (status in ('active','removed')),
  created_at      timestamptz not null default now(),
  unique (user_id, account_number_hash, provider_bank_id)
);

-- ---------------------------------------------------------------------------
-- 3. Deposit addresses
-- ---------------------------------------------------------------------------

create table knock.provider_wallet_addresses (
  id                 uuid primary key default gen_random_uuid(),
  user_id            uuid not null references knock.profiles(id),
  provider           text not null,
  provider_address_id text,                -- provider's wallet/address id
  asset_id           text not null,
  symbol             text not null,
  network            text not null default '',
  address            text,
  memo               text,
  label              text not null,        -- Knock user id (never email/phone)
  bank_account_id    uuid references knock.bank_accounts(id),
  auto_settlement    boolean not null default false,
  status             text not null default 'requested' check (status in ('requested','active','failed','retired')),
  is_wrong_asset_recovery boolean not null default false,
  recovered_from_address_id uuid references knock.provider_wallet_addresses(id),
  last_error         text,
  raw                jsonb,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now()
);
-- The API response and the trade.address.created fallback webhook describe
-- the same address: both upsert on these keys, so neither can duplicate it.
create unique index provider_wallet_addresses_pid on knock.provider_wallet_addresses (provider, provider_address_id) where provider_address_id is not null;
create unique index provider_wallet_addresses_addr on knock.provider_wallet_addresses (provider, network, address) where address is not null;
-- One live address per customer, asset and network.
create unique index provider_wallet_addresses_one_live on knock.provider_wallet_addresses (provider, user_id, asset_id, network)
  where status in ('requested','active') and not is_wrong_asset_recovery;
create index provider_wallet_addresses_user on knock.provider_wallet_addresses (user_id);

-- ---------------------------------------------------------------------------
-- 4. Deposits
-- ---------------------------------------------------------------------------

create table knock.crypto_deposits (
  id                  uuid primary key default gen_random_uuid(),
  knock_reference     text not null unique default knock.new_ref('KCD'),
  user_id             uuid not null references knock.profiles(id),
  address_id          uuid references knock.provider_wallet_addresses(id),
  provider            text not null,
  provider_trade_id   text not null,
  asset_id            text,
  symbol              text,
  network             text,
  crypto_amount       numeric,              -- as reported
  amount_in_usd       numeric,              -- informational only, never credited
  tx_hash             text,
  confirmations       int,
  required_confirmations int,
  status              text not null default 'pending' check (status in
                        ('pending','under_review','below_minimum','flagged','completed','failed')),
  sub_status          text,
  flag_reason         text,
  balance_remaining   numeric,              -- below-minimum: amount still needed
  is_wrong_asset      boolean not null default false,
  -- completion (provider is authoritative)
  credited_currency   text,
  amount_credited     numeric,              -- provider's amountCredited, major units
  credited_minor      numeric(38,0),        -- what Knock's ledger received
  knock_fee_minor     numeric(38,0) not null default 0,
  customer_net_minor  numeric(38,0),
  rate                numeric,
  conversion_rate     numeric,
  journal_entry_id    uuid references knock.journal_entries(id),
  settled_via_deposit_id uuid references knock.crypto_deposits(id), -- below-minimum deposits credited as part of a later batch
  settled_trades      text[],
  failure_reason      text,
  last_event_time     timestamptz,
  last_event_id       text,
  provider_snapshot   jsonb,                -- last verified provider record
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  completed_at        timestamptz,
  unique (provider, provider_trade_id),
  check (status <> 'completed' or (credited_minor is not null and journal_entry_id is not null))
);
create index crypto_deposits_user on knock.crypto_deposits (user_id, created_at desc);
create index crypto_deposits_status on knock.crypto_deposits (status);
create index crypto_deposits_tx on knock.crypto_deposits (lower(tx_hash)) where tx_hash is not null;

-- ---------------------------------------------------------------------------
-- 5. Withdrawals (crypto and bank in one table; views below split them)
-- ---------------------------------------------------------------------------

create table knock.provider_withdrawals (
  id                    uuid primary key default gen_random_uuid(),
  knock_reference       text not null unique default knock.new_ref('KWD'),  -- sent to the provider as our reference
  idempotency_key       text unique,           -- customer/staff request key
  user_id               uuid not null references knock.profiles(id),
  provider              text not null,
  provider_withdrawal_id text,
  kind                  text not null check (kind in ('crypto','bank')),
  purpose               text not null default 'customer' check (purpose in ('customer','auto_settlement','settlement_replacement')),
  status                text not null check (status in (
                          'reserved',            -- funds reserved, not yet sent
                          'submitting',          -- request in flight
                          'submission_unknown',  -- timeout/network error: must be resolved from provider records, never re-sent blindly
                          'pending','processing',
                          'completed','reversed','rejected',
                          'not_submitted',       -- provider refused before accepting (4xx); reservation released
                          'capacity_unavailable' -- provider cannot price/process this size now; reservation released
                        )),
  currency              text not null,           -- wallet currency debited
  amount_minor          numeric(38,0) not null check (amount_minor > 0),
  knock_fee_minor       numeric(38,0) not null default 0 check (knock_fee_minor >= 0),
  -- provider figures (major units, as reported)
  provider_amount       numeric,
  original_amount       numeric,
  payout_amount         numeric,
  provider_fee          numeric,
  crypto_amount         numeric,
  fee_crypto            numeric,
  fee_bearer            text check (fee_bearer in ('user','business')),
  quoted_fee            numeric,
  -- destination
  asset                 text,
  network               text,
  destination_address   text,
  fee_level             text check (fee_level in ('low','medium','high')),
  bank_account_id       uuid references knock.bank_accounts(id),
  provider_bank_id      text,
  bank_name             text,
  account_name          text,
  account_number_masked text,
  narration             text,
  tx_hash               text,
  explorer_url          text,
  -- links
  trade_id              text,                    -- provider trade id (auto-settlement / replacement)
  deposit_id            uuid references knock.crypto_deposits(id),
  settlement_exception_id uuid,
  reason                text,
  last_error_code       text,
  meta                  jsonb,
  provider_snapshot     jsonb,
  reserve_account_id    uuid not null references knock.ledger_accounts(id),
  reserve_entry_id      uuid references knock.journal_entries(id),
  final_entry_id        uuid references knock.journal_entries(id),
  last_event_time       timestamptz,
  last_event_id         text,
  created_by            uuid references knock.profiles(id),
  approved_by           uuid references knock.profiles(id),
  submitted_at          timestamptz,
  completed_at          timestamptz,
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now(),
  check (kind <> 'crypto' or (asset is not null and destination_address is not null)),
  check (kind <> 'bank' or provider_bank_id is not null)
);
create unique index provider_withdrawals_pid on knock.provider_withdrawals (provider, provider_withdrawal_id) where provider_withdrawal_id is not null;
create index provider_withdrawals_user on knock.provider_withdrawals (user_id, created_at desc);
create index provider_withdrawals_status on knock.provider_withdrawals (status);
create index provider_withdrawals_trade on knock.provider_withdrawals (provider, trade_id) where trade_id is not null;

create view knock.crypto_withdrawals as select * from knock.provider_withdrawals where kind = 'crypto';
create view knock.bank_withdrawals as select * from knock.provider_withdrawals where kind = 'bank';

-- ---------------------------------------------------------------------------
-- 6. Settlements and exceptions
-- ---------------------------------------------------------------------------

create table knock.settlements (
  id                uuid primary key default gen_random_uuid(),
  deposit_id        uuid not null unique references knock.crypto_deposits(id),
  user_id           uuid not null references knock.profiles(id),
  provider          text not null,
  trade_id          text not null,
  mode              text not null check (mode in ('per_address','business_wide')),
  destination       jsonb,               -- masked bank details only
  reserved_minor    numeric(38,0) not null,
  currency          text not null,
  status            text not null default 'awaiting_payout' check (status in
                      ('awaiting_payout','processing','completed','failed_to_start','reversed','replaced','released_to_wallet','needs_review')),
  amount_settled    numeric,
  settled_currency  text,
  rate              numeric,
  conversion_rate   numeric,
  markup_percent    numeric,
  markup_amount     numeric,
  fee_amount_usd    numeric,
  withdrawal_id     uuid references knock.provider_withdrawals(id),
  final_entry_id    uuid references knock.journal_entries(id),
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  unique (provider, trade_id)
);

create table knock.settlement_exceptions (
  id                uuid primary key default gen_random_uuid(),
  settlement_id     uuid not null references knock.settlements(id),
  deposit_id        uuid not null references knock.crypto_deposits(id),
  provider          text not null,
  trade_id          text not null,
  event_id          text not null unique,
  amount            numeric,
  currency          text,
  reason            text,
  status            text not null default 'open' check (status in ('open','investigating','awaiting_provider','resolved','escalated')),
  resolution        text check (resolution in ('replacement_payout','released_to_wallet','provider_settled','other')),
  replacement_withdrawal_id uuid references knock.provider_withdrawals(id),
  assigned_to       uuid references knock.profiles(id),
  notes             jsonb not null default '[]',
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  resolved_at       timestamptz
);
alter table knock.provider_withdrawals add constraint provider_withdrawals_exception_fk
  foreign key (settlement_exception_id) references knock.settlement_exceptions(id);
-- At most one live replacement payout per exception: blocks duplicate payouts.
create unique index provider_withdrawals_one_replacement on knock.provider_withdrawals (settlement_exception_id)
  where settlement_exception_id is not null and status not in ('not_submitted','capacity_unavailable','reversed','rejected');

-- ---------------------------------------------------------------------------
-- 7. Fees, API logs, rate limits, webhooks, processing logs
-- ---------------------------------------------------------------------------

-- Every fee as its own row, never merged into one field.
create table knock.provider_fee_records (
  id           bigserial primary key,
  provider     text not null,
  subject_kind text not null check (subject_kind in ('deposit','withdrawal','settlement')),
  subject_id   uuid not null,
  fee_type     text not null check (fee_type in
                 ('deposit_processing','conversion_spread','settlement_markup','provider_withdrawal_fee','network_fee','knock_service_fee')),
  amount       numeric not null,
  currency     text not null,
  source       text not null check (source in ('provider_reported','knock_schedule')),
  detail       jsonb,
  created_at   timestamptz not null default now(),
  unique (subject_kind, subject_id, fee_type, source)
);
create trigger provider_fee_records_immutable before update or delete on knock.provider_fee_records
  for each row execute function knock.forbid_change();

create table knock.provider_api_logs (
  id             bigserial primary key,
  provider       text not null,
  environment    text not null,
  correlation_id text not null,
  method         text not null,
  route          text not null,        -- templated path, no ids or query values
  http_status    int,
  outcome        text not null,        -- ok, client_error, rate_limited, server_error, timeout, network_error, capacity
  duration_ms    int,
  rate_limit_limit int,
  rate_limit_remaining int,
  rate_limit_reset text,
  retry_after_s  int,
  error_message  text,                 -- provider message, for diagnostics only
  at             timestamptz not null default now()
);
create index provider_api_logs_at on knock.provider_api_logs (provider, at desc);

-- Distributed rate limiter shared by every instance using the same credentials.
create table knock.provider_rate_limits (
  provider     text not null,
  route_key    text not null,
  window_start timestamptz not null,
  used         int not null default 0,
  paused_until timestamptz,
  primary key (provider, route_key)
);

-- Atomically take one request slot for a route. Returns 0 when granted, or
-- the number of milliseconds to wait.
create or replace function knock.take_rate_slot(p_provider text, p_route text, p_limit int, p_window_ms int default 60000)
returns int language plpgsql as $$
declare r record; v_now timestamptz := clock_timestamp();
begin
  insert into knock.provider_rate_limits (provider, route_key, window_start, used)
  values (p_provider, p_route, v_now, 0) on conflict do nothing;
  select * into r from knock.provider_rate_limits where provider = p_provider and route_key = p_route for update;
  if r.paused_until is not null and r.paused_until > v_now then
    return ceil(extract(epoch from (r.paused_until - v_now)) * 1000)::int;
  end if;
  if v_now >= r.window_start + make_interval(secs => p_window_ms / 1000.0) then
    update knock.provider_rate_limits set window_start = v_now, used = 1, paused_until = null
      where provider = p_provider and route_key = p_route;
    return 0;
  end if;
  if r.used >= p_limit then
    return greatest(1, ceil(extract(epoch from (r.window_start + make_interval(secs => p_window_ms / 1000.0) - v_now)) * 1000)::int);
  end if;
  update knock.provider_rate_limits set used = used + 1 where provider = p_provider and route_key = p_route;
  return 0;
end $$;

-- Pause a route after a 429 for the provider's Retry-After.
create or replace function knock.pause_rate_route(p_provider text, p_route text, p_seconds int) returns void
language sql as $$
  insert into knock.provider_rate_limits (provider, route_key, window_start, used, paused_until)
  values (p_provider, p_route, now(), 0, clock_timestamp() + make_interval(secs => p_seconds))
  on conflict (provider, route_key) do update set paused_until = excluded.paused_until
$$;

-- Webhook events: reuse knock.webhook_events (unique provider + event_id)
-- and add what a durable, at-least-once, out-of-order queue needs.
alter table knock.webhook_events
  add column if not exists source_ip       text,
  add column if not exists verification    jsonb,
  add column if not exists event_time      timestamptz,
  add column if not exists resource_id     text,
  add column if not exists status          text not null default 'processed',
  add column if not exists attempts        int not null default 0,
  add column if not exists next_attempt_at timestamptz,
  add column if not exists last_error      text,
  add column if not exists delivery_count  int not null default 1,
  add column if not exists last_delivery_at timestamptz;
alter table knock.webhook_events drop constraint if exists webhook_events_status_check;
alter table knock.webhook_events add constraint webhook_events_status_check check (status in
  ('queued','processing','processed','ignored_stale','ignored_terminal','retrying','failed','rejected'));
create index if not exists webhook_events_queue on knock.webhook_events (provider, status, next_attempt_at)
  where status in ('queued','retrying');
create index if not exists webhook_events_resource on knock.webhook_events (provider, resource_id, event_time);

create table knock.provider_event_processing_logs (
  id               bigserial primary key,
  webhook_event_id uuid not null references knock.webhook_events(id),
  attempt          int not null,
  outcome          text not null,
  detail           text,
  duration_ms      int,
  at               timestamptz not null default now()
);

-- Claim queued events for one worker (safe with many workers).
create or replace function knock.claim_webhook_events(p_provider text, p_limit int, p_worker text)
returns setof knock.webhook_events language plpgsql as $$
begin
  -- Claimed rows come back oldest event first (UPDATE ... RETURNING has no order).
  return query
  with claimed as (
    update knock.webhook_events w set status = 'processing', attempts = w.attempts + 1,
           verification = coalesce(w.verification, '{}'::jsonb) || jsonb_build_object('worker', p_worker)
    where w.id in (
      select id from knock.webhook_events
      where provider = p_provider and status in ('queued','retrying') and coalesce(next_attempt_at, now()) <= now()
      order by event_time nulls last, received_at
      limit p_limit for update skip locked)
    returning w.*)
  select * from claimed order by event_time nulls last, received_at;
end $$;

-- Risk flags gain a generic subject.
alter table knock.risk_flags add column if not exists subject_kind text, add column if not exists subject_id uuid;

-- ---------------------------------------------------------------------------
-- 8. Reconciliation
-- ---------------------------------------------------------------------------

create table knock.provider_reconciliation_runs (
  id            uuid primary key default gen_random_uuid(),
  provider      text not null,
  scope         text not null,          -- full, deposits, withdrawals, addresses, balances
  trigger       text not null check (trigger in ('scheduled','manual')),
  requested_by  uuid references knock.profiles(id),
  status        text not null default 'running' check (status in ('running','completed','failed')),
  pages_read    int not null default 0,
  provider_records int not null default 0,
  discrepancies int not null default 0,
  error         text,
  started_at    timestamptz not null default now(),
  finished_at   timestamptz
);

create table knock.provider_reconciliation_records (
  id            uuid primary key default gen_random_uuid(),
  run_id        uuid not null references knock.provider_reconciliation_runs(id),
  provider      text not null,
  check_name    text not null,
  subject_kind  text,
  subject_ref   text,                   -- provider id or knock id
  expected      jsonb,
  actual        jsonb,
  fingerprint   text not null,          -- same discrepancy across runs = same open record
  status        text not null default 'open' check (status in ('open','investigating','awaiting_provider','resolved','escalated')),
  notes         jsonb not null default '[]',
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  resolved_by   uuid references knock.profiles(id),
  resolved_at   timestamptz
);
create unique index provider_reconciliation_open on knock.provider_reconciliation_records (fingerprint)
  where status <> 'resolved';

-- ---------------------------------------------------------------------------
-- 9. Staff actions needing a second approver
-- ---------------------------------------------------------------------------

create table knock.staff_action_requests (
  id           uuid primary key default gen_random_uuid(),
  action       text not null,
  subject_id   uuid not null,
  payload      jsonb not null,
  amount_minor numeric(38,0),
  currency     text,
  requested_by uuid not null references knock.profiles(id),
  approved_by  uuid references knock.profiles(id),
  status       text not null default 'pending' check (status in ('pending','approved','rejected','executed','failed')),
  result       jsonb,
  created_at   timestamptz not null default now(),
  decided_at   timestamptz,
  check (approved_by is null or approved_by <> requested_by)
);
create unique index staff_action_one_pending on knock.staff_action_requests (action, subject_id) where status = 'pending';
