-- KNOCK Payment Links & Smart Split
-- ---------------------------------------------------------------------------
-- Everything that moves money lives in this file as Postgres functions so
-- that each money movement is a single database transaction: either every
-- ledger line, allocation and status change is written, or none is.
--
-- Conventions
--   * Amounts are integers in the asset's minor unit (kobo for NGN, 1e-6 for
--     USDT, satoshi for BTC ...), stored as numeric(38,0) so 18-decimal
--     tokens fit. Never floats.
--   * The ledger is double-entry. A journal line amount is signed:
--     positive = debit, negative = credit. Every entry must sum to zero per
--     currency (checked by a deferred constraint trigger).
--   * Journal, allocations and audit rows are append-only (triggers block
--     UPDATE/DELETE). Corrections are new, reversing entries.
--   * Each posting carries a unique idempotency key, so replaying a webhook
--     or retrying a job can never credit anyone twice.
--   * The schema is `knock`. Only the service role (Edge Functions / API
--     server) calls these functions. Clients never write tables directly;
--     RLS read policies exist as defence in depth.
-- ---------------------------------------------------------------------------

create schema if not exists knock;
set search_path = knock, public;

-- ---------------------------------------------------------------------------
-- Users, staff roles, assets, fees, limits
-- ---------------------------------------------------------------------------

create table knock.profiles (
  id            uuid primary key default gen_random_uuid(),
  username      text not null check (username ~ '^[a-z0-9_]{3,20}$'),
  display_name  text not null,
  avatar_url    text,
  kyc_tier      smallint not null default 0 check (kyc_tier between 0 and 3),
  status        text not null default 'active' check (status in ('active','frozen','closed')),
  created_at    timestamptz not null default now()
);
create unique index profiles_username_key on knock.profiles (lower(username));

-- On Supabase, tie profiles to auth.users when that schema exists.
do $$
begin
  if exists (select 1 from information_schema.tables where table_schema = 'auth' and table_name = 'users') then
    execute 'alter table knock.profiles add constraint profiles_auth_fk foreign key (id) references auth.users(id) on delete restrict';
  end if;
end $$;

create table knock.staff_roles (
  user_id   uuid not null references knock.profiles(id),
  role      text not null check (role in ('support','compliance','finance','admin')),
  granted_at timestamptz not null default now(),
  primary key (user_id, role)
);

create table knock.assets (
  code              text not null,             -- NGN, USDT, BTC ...
  network           text not null,             -- 'fiat' for NGN, TRC20, BEP20, BITCOIN ...
  kind              text not null check (kind in ('fiat','crypto')),
  decimals          smallint not null check (decimals between 0 and 18),
  min_confirmations int not null default 0,
  enabled           boolean not null default true,
  primary key (code, network)
);

-- [Guess] Launch assets and confirmation depths; confirm with the crypto
-- provider and compliance before launch.
insert into knock.assets (code, network, kind, decimals, min_confirmations) values
  ('NGN',  'fiat',    'fiat',   2, 0),
  ('USDT', 'TRC20',   'crypto', 6, 20),
  ('USDT', 'BEP20',   'crypto', 18, 15),
  ('USDC', 'BEP20',   'crypto', 18, 15),
  ('BTC',  'BITCOIN', 'crypto', 8, 2);

-- Knock's fee per successful payment, per currency.
-- [Guess] 1.5% capped at NGN 2,000; crypto 1%, no cap. Commercial decision.
create table knock.fee_schedule (
  currency   text primary key,
  bps        int not null check (bps between 0 and 10000),
  min_fee    numeric(38,0) not null default 0,
  cap_fee    numeric(38,0)
);
insert into knock.fee_schedule (currency, bps, min_fee, cap_fee) values
  ('NGN', 150, 0, 200000),
  ('USDT', 100, 0, null),
  ('USDC', 100, 0, null),
  ('BTC', 100, 0, null);

-- [Guess] Limits per KYC tier, in NGN kobo. Crypto links are checked
-- against their NGN equivalent by the API layer.
create table knock.tier_limits (
  kyc_tier          smallint primary key,
  max_link_target   numeric(38,0) not null,
  max_single_payment numeric(38,0) not null,
  max_recipients    int not null
);
insert into knock.tier_limits values
  (0, 0, 0, 0),                         -- tier 0 cannot create links
  (1, 50000000, 10000000, 5),           -- NGN 500k target, NGN 100k per payment
  (2, 1000000000, 500000000, 20),       -- NGN 10M target, NGN 5M per payment
  (3, 10000000000, 2000000000, 50);     -- NGN 100M target, NGN 20M per payment

-- ---------------------------------------------------------------------------
-- Ledger
-- ---------------------------------------------------------------------------

create table knock.ledger_accounts (
  id          uuid primary key default gen_random_uuid(),
  code        text not null unique,
  owner_id    uuid references knock.profiles(id),
  link_id     uuid,
  purpose     text not null check (purpose in (
                'user_available',      -- spendable wallet balance (liability)
                'user_pending',        -- allocated, awaiting provider settlement (liability)
                'user_held',           -- frozen by a dispute (liability)
                'link_collection',     -- money held for a link before distribution (liability)
                'provider_clearing',   -- owed to Knock by a payment provider (asset)
                'settlement_bank',     -- Knock's settlement bank / custody (asset)
                'recovery_receivable', -- owed to Knock by a user after a reversal (asset)
                'fee_revenue',         -- Knock fee income (income)
                'provider_fee_expense' -- provider processing cost (expense)
              )),
  currency    text not null,
  normal_side text not null check (normal_side in ('debit','credit')),
  allow_negative boolean not null default false,
  created_at  timestamptz not null default now()
);

create table knock.journal_entries (
  id              uuid primary key default gen_random_uuid(),
  idempotency_key text not null unique,
  kind            text not null,
  link_id         uuid,
  payment_id      uuid,
  memo            text,
  created_by      uuid,
  created_at      timestamptz not null default now()
);

create table knock.journal_lines (
  id         bigserial primary key,
  entry_id   uuid not null references knock.journal_entries(id),
  account_id uuid not null references knock.ledger_accounts(id),
  currency   text not null,
  amount     numeric(38,0) not null check (amount <> 0)  -- + debit, - credit
);
create index journal_lines_account_idx on knock.journal_lines (account_id);
create index journal_lines_entry_idx on knock.journal_lines (entry_id);

create or replace view knock.account_balances as
select a.id as account_id, a.code, a.owner_id, a.link_id, a.purpose, a.currency,
       case when a.normal_side = 'debit' then coalesce(sum(l.amount), 0)
            else -coalesce(sum(l.amount), 0) end as balance
from knock.ledger_accounts a
left join knock.journal_lines l on l.account_id = a.id
group by a.id;

-- Every journal entry must balance per currency. Deferred, so all lines of
-- an entry are inserted before the check runs at commit.
create or replace function knock.check_entry_balanced() returns trigger
language plpgsql as $$
declare bad record;
begin
  select currency, sum(amount) s into bad
  from knock.journal_lines where entry_id = new.entry_id
  group by currency having sum(amount) <> 0 limit 1;
  if found then
    raise exception 'journal entry % unbalanced in % by %', new.entry_id, bad.currency, bad.s
      using errcode = 'P0001';
  end if;
  return null;
end $$;

create constraint trigger journal_lines_balanced
  after insert on knock.journal_lines
  deferrable initially deferred
  for each row execute function knock.check_entry_balanced();

-- Append-only guard reused by every history table.
create or replace function knock.forbid_change() returns trigger
language plpgsql as $$
begin
  raise exception 'append_only: % is append-only; post a correcting record instead', tg_table_name
    using errcode = 'P0001';
end $$;

create trigger journal_entries_immutable before update or delete on knock.journal_entries
  for each row execute function knock.forbid_change();
create trigger journal_lines_immutable before update or delete on knock.journal_lines
  for each row execute function knock.forbid_change();

create or replace function knock.account(p_owner uuid, p_link uuid, p_purpose text, p_currency text)
returns uuid language plpgsql as $$
declare
  v_code text := p_purpose || ':' || coalesce(p_owner::text, p_link::text, 'system') || ':' || p_currency;
  v_id uuid;
  v_side text := case when p_purpose in ('provider_clearing','settlement_bank','recovery_receivable','provider_fee_expense')
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

create or replace function knock.balance(p_account uuid) returns numeric
language sql stable as $$
  select balance from knock.account_balances where account_id = p_account
$$;

-- Post a balanced entry. p_lines: [{"account": uuid, "amount": "123"}] with
-- signed amounts. Returns the entry id. Replaying the same idempotency key
-- returns the original entry and posts nothing.
create or replace function knock.post_entry(
  p_idem text, p_kind text, p_currency text, p_lines jsonb,
  p_link uuid default null, p_payment uuid default null, p_memo text default null, p_actor uuid default null)
returns uuid language plpgsql as $$
declare
  v_id uuid;
  v_line jsonb;
  v_acct uuid;
  v_sum numeric := 0;
begin
  select id into v_id from knock.journal_entries where idempotency_key = p_idem;
  if v_id is not null then
    return v_id;
  end if;

  insert into knock.journal_entries (idempotency_key, kind, link_id, payment_id, memo, created_by)
  values (p_idem, p_kind, p_link, p_payment, p_memo, p_actor) returning id into v_id;

  for v_line in select * from jsonb_array_elements(p_lines) loop
    if (v_line->>'amount')::numeric = 0 then continue; end if;
    insert into knock.journal_lines (entry_id, account_id, currency, amount)
    values (v_id, (v_line->>'account')::uuid, p_currency, (v_line->>'amount')::numeric);
    v_sum := v_sum + (v_line->>'amount')::numeric;
  end loop;

  if v_sum <> 0 then
    raise exception 'entry % does not balance (%)', p_idem, v_sum using errcode = 'P0001';
  end if;

  -- No liability account may go below zero unless explicitly allowed.
  for v_acct in
    select distinct l.account_id from knock.journal_lines l
    join knock.ledger_accounts a on a.id = l.account_id
    where l.entry_id = v_id and not a.allow_negative
  loop
    if knock.balance(v_acct) < 0 then
      raise exception 'account % would go negative', v_acct using errcode = 'P0001';
    end if;
  end loop;
  return v_id;
end $$;

-- ---------------------------------------------------------------------------
-- Payment links, split rules, amendments
-- ---------------------------------------------------------------------------

create table knock.payment_links (
  id               uuid primary key default gen_random_uuid(),
  reference        text not null unique,     -- KPL-7Q2M9X, shown to users
  slug             text not null unique,     -- unguessable public token in the URL
  creator_id       uuid not null references knock.profiles(id),
  link_type        text not null check (link_type in ('naira','crypto','split')),
  title            text not null check (length(title) between 1 and 80),
  description      text check (length(description) <= 500),
  currency         text not null,
  network          text not null,
  amount_mode      text not null check (amount_mode in ('fixed','flexible')),
  fixed_amount     numeric(38,0) check (fixed_amount > 0),
  min_amount       numeric(38,0) check (min_amount > 0),
  max_amount       numeric(38,0) check (max_amount > 0),
  target_amount    numeric(38,0) check (target_amount > 0),
  split_method     text check (split_method in ('fixed','percentage')),
  allocation_mode  text not null default 'exact' check (allocation_mode in ('exact','remainder_to_creator')),
  settlement_mode  text not null default 'each_payment' check (settlement_mode in ('each_payment','on_target','manual')),
  fee_bearer       text not null default 'deduct' check (fee_bearer in ('deduct','payer')),
  status           text not null default 'active' check (status in ('active','paused','completed','expired','under_review','closed')),
  expires_at       timestamptz,
  require_customer_reference boolean not null default false,
  invoice_number   text,
  payment_instructions text check (length(payment_instructions) <= 500),
  current_rule_version int not null default 1,
  first_payment_at timestamptz,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  foreign key (currency, network) references knock.assets(code, network),
  check (amount_mode <> 'fixed' or fixed_amount is not null),
  check (link_type <> 'split' or split_method is not null),
  check (settlement_mode <> 'on_target' or target_amount is not null),
  check (min_amount is null or max_amount is null or min_amount <= max_amount)
);
create index payment_links_creator_idx on knock.payment_links (creator_id, created_at desc);

create table knock.split_recipients (
  id              uuid primary key default gen_random_uuid(),
  link_id         uuid not null references knock.payment_links(id),
  rule_version    int not null,
  position        int not null,
  recipient_id    uuid not null references knock.profiles(id),
  allocated_amount numeric(38,0) not null check (allocated_amount >= 0),
  basis_points    int not null check (basis_points between 0 and 10000),
  is_creator_remainder boolean not null default false,
  unique (link_id, rule_version, recipient_id),
  unique (link_id, rule_version, position)
);

-- Split rules are frozen once a link has taken a payment. Changes after
-- that go through knock.split_amendments, which writes a new rule version
-- and leaves every historical allocation pointing at the version it used.
create or replace function knock.guard_split_rules() returns trigger
language plpgsql as $$
declare v_first timestamptz;
begin
  select first_payment_at into v_first from knock.payment_links where id = old.link_id;
  if v_first is not null then
    raise exception 'rules_locked: split rules for link % are immutable after the first payment; use an amendment', old.link_id
      using errcode = 'P0001';
  end if;
  return case when tg_op = 'DELETE' then old else new end;
end $$;
create trigger split_recipients_guard before update or delete on knock.split_recipients
  for each row execute function knock.guard_split_rules();

-- Link fields that define the money rules cannot change after the first payment.
create or replace function knock.guard_link_rules() returns trigger
language plpgsql as $$
begin
  if old.first_payment_at is not null and (
       new.link_type is distinct from old.link_type or new.currency is distinct from old.currency
    or new.network is distinct from old.network or new.split_method is distinct from old.split_method
    or new.allocation_mode is distinct from old.allocation_mode or new.settlement_mode is distinct from old.settlement_mode
    or new.fee_bearer is distinct from old.fee_bearer or new.target_amount is distinct from old.target_amount
    or new.creator_id is distinct from old.creator_id
    or (new.current_rule_version is distinct from old.current_rule_version
        and coalesce(current_setting('knock.amendment', true), '') <> 'on')) then
    raise exception 'rules_locked: payment rules for link % are locked after the first payment', old.id using errcode = 'P0001';
  end if;
  new.updated_at := now();
  return new;
end $$;
create trigger payment_links_guard before update on knock.payment_links
  for each row execute function knock.guard_link_rules();

create table knock.split_amendments (
  id            uuid primary key default gen_random_uuid(),
  link_id       uuid not null references knock.payment_links(id),
  from_version  int not null,
  to_version    int not null,
  proposed_by   uuid not null references knock.profiles(id),
  reason        text not null check (length(reason) between 3 and 500),
  recipients    jsonb not null,       -- [{recipient_id, allocated_amount, basis_points}]
  status        text not null default 'proposed' check (status in ('proposed','applied','rejected','cancelled')),
  created_at    timestamptz not null default now(),
  decided_at    timestamptz
);
create table knock.amendment_approvals (
  amendment_id uuid not null references knock.split_amendments(id),
  user_id      uuid not null references knock.profiles(id),
  decision     text check (decision in ('approved','rejected')),
  decided_at   timestamptz,
  primary key (amendment_id, user_id)
);

create table knock.recipient_groups (
  id          uuid primary key default gen_random_uuid(),
  owner_id    uuid not null references knock.profiles(id),
  name        text not null check (length(name) between 1 and 60),
  split_method text not null check (split_method in ('fixed','percentage')),
  members     jsonb not null,  -- [{recipient_id, allocated_amount, basis_points}]
  created_at  timestamptz not null default now(),
  unique (owner_id, name)
);

-- ---------------------------------------------------------------------------
-- Payments, allocations, webhooks, disputes, risk, notifications, audit
-- ---------------------------------------------------------------------------

create table knock.payments (
  id                  uuid primary key default gen_random_uuid(),
  link_id             uuid not null references knock.payment_links(id),
  knock_reference     text not null unique,          -- KPY-...
  provider            text not null,
  provider_reference  text not null,                 -- provider's transaction / session reference
  method              text not null check (method in ('bank_transfer','card','ussd','crypto')),
  currency            text not null,
  network             text not null,
  amount              numeric(38,0) not null check (amount > 0),  -- amount credited to the link (before Knock fee if deducted)
  payer_fee           numeric(38,0) not null default 0,           -- fee the payer paid on top (fee_bearer = payer)
  knock_fee           numeric(38,0) not null default 0,
  gross_paid          numeric(38,0),                              -- what the provider says the payer paid
  payer_name          text,
  payer_email         text,
  payer_phone         text,
  customer_reference  text,
  status              text not null default 'initiated' check (status in
                        ('initiated','pending','confirming','succeeded','failed','reversed','disputed','expired')),
  pay_address         text,
  tx_hash             text,
  confirmations       int not null default 0,
  quote_rate_ngn      numeric(30,8),
  quote_expires_at    timestamptz,
  verification        jsonb,
  verified_at         timestamptz,
  settled_at          timestamptz,                    -- provider settled funds to Knock
  distribution_status text not null default 'none' check (distribution_status in
                        ('none','held','distributed','failed_retrying','reversed')),
  distribution_attempts int not null default 0,
  last_distribution_error text,
  next_retry_at       timestamptz,
  rule_version        int,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  unique (provider, provider_reference)
);
create unique index payments_tx_hash_key on knock.payments (network, lower(tx_hash)) where tx_hash is not null;
create index payments_link_idx on knock.payments (link_id, created_at desc);

create table knock.split_allocations (
  id            uuid primary key default gen_random_uuid(),
  payment_id    uuid not null references knock.payments(id),
  link_id       uuid not null references knock.payment_links(id),
  recipient_id  uuid not null references knock.profiles(id),
  rule_version  int not null,
  currency      text not null,
  gross_share   numeric(38,0) not null check (gross_share >= 0),
  fee_share     numeric(38,0) not null check (fee_share >= 0),
  net_share     numeric(38,0) not null check (net_share >= 0),
  is_overflow   boolean not null default false,
  journal_entry_id uuid not null references knock.journal_entries(id),
  created_at    timestamptz not null default now(),
  unique (payment_id, recipient_id)
);
create trigger split_allocations_immutable before update or delete on knock.split_allocations
  for each row execute function knock.forbid_change();

-- Allocation state changes are appended here; current state = latest row.
create table knock.allocation_events (
  id            bigserial primary key,
  allocation_id uuid not null references knock.split_allocations(id),
  state         text not null check (state in ('pending','available','held','reversed')),
  amount        numeric(38,0) not null default 0,   -- money this allocation has sitting in that state
  journal_entry_id uuid references knock.journal_entries(id),
  at            timestamptz not null default now()
);
create trigger allocation_events_immutable before update or delete on knock.allocation_events
  for each row execute function knock.forbid_change();

create or replace view knock.allocation_state as
select a.*, e.state, e.amount as amount_in_state, e.at as state_at
from knock.split_allocations a
join lateral (select state, amount, at from knock.allocation_events ev where ev.allocation_id = a.id order by ev.id desc limit 1) e on true;

create table knock.distribution_attempts (
  id         bigserial primary key,
  payment_id uuid not null references knock.payments(id),
  attempt    int not null,
  ok         boolean not null,
  error      text,
  at         timestamptz not null default now()
);

create table knock.webhook_events (
  id             uuid primary key default gen_random_uuid(),
  provider       text not null,
  event_id       text not null,
  event_type     text,
  signature_valid boolean not null,
  payload        jsonb not null,
  received_at    timestamptz not null default now(),
  processed_at   timestamptz,
  result         text,
  unique (provider, event_id)
);

create table knock.disputes (
  id                  uuid primary key default gen_random_uuid(),
  payment_id          uuid not null references knock.payments(id),
  provider_dispute_id text,
  reason              text,
  status              text not null default 'open' check (status in ('open','won','lost')),
  opened_at           timestamptz not null default now(),
  resolved_at         timestamptz
);

create table knock.risk_flags (
  id         uuid primary key default gen_random_uuid(),
  link_id    uuid references knock.payment_links(id),
  payment_id uuid references knock.payments(id),
  user_id    uuid references knock.profiles(id),
  rule       text not null,
  severity   text not null check (severity in ('low','medium','high')),
  detail     jsonb,
  status     text not null default 'open' check (status in ('open','cleared','actioned')),
  created_at timestamptz not null default now()
);

create table knock.notifications (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references knock.profiles(id),
  kind       text not null,
  title      text not null,
  body       text not null,
  link_id    uuid,
  payment_id uuid,
  data       jsonb,
  created_at timestamptz not null default now(),
  delivered_at timestamptz,   -- set by the push/email worker
  read_at    timestamptz
);
create index notifications_user_idx on knock.notifications (user_id, created_at desc);

create table knock.audit_log (
  id         bigserial primary key,
  actor_id   uuid,
  actor_kind text not null check (actor_kind in ('user','staff','system','provider')),
  action     text not null,
  link_id    uuid,
  payment_id uuid,
  detail     jsonb,
  at         timestamptz not null default now()
);
create trigger audit_log_immutable before update or delete on knock.audit_log
  for each row execute function knock.forbid_change();

create or replace function knock.audit(p_actor uuid, p_kind text, p_action text, p_link uuid, p_payment uuid, p_detail jsonb)
returns void language sql as $$
  insert into knock.audit_log (actor_id, actor_kind, action, link_id, payment_id, detail)
  values (p_actor, p_kind, p_action, p_link, p_payment, p_detail)
$$;

create or replace function knock.notify(p_user uuid, p_kind text, p_title text, p_body text, p_link uuid, p_payment uuid, p_data jsonb default null)
returns void language sql as $$
  insert into knock.notifications (user_id, kind, title, body, link_id, payment_id, data)
  values (p_user, p_kind, p_title, p_body, p_link, p_payment, p_data)
$$;

-- ---------------------------------------------------------------------------
-- Money helpers
-- ---------------------------------------------------------------------------

-- Knock fee for an amount, from the fee schedule. Rounds half up.
create or replace function knock.quote_fee(p_currency text, p_amount numeric) returns numeric
language plpgsql stable as $$
declare f record; v numeric;
begin
  select * into f from knock.fee_schedule where currency = p_currency;
  if not found then return 0; end if;
  v := floor((p_amount * f.bps + 5000) / 10000);
  v := greatest(v, f.min_fee);
  if f.cap_fee is not null then v := least(v, f.cap_fee); end if;
  return least(v, p_amount);
end $$;

-- Split p_total into integer parts proportional to p_weights using the
-- largest-remainder method. Parts always sum exactly to p_total. Ties go to
-- the earlier position, so results are deterministic.
create or replace function knock.split_amount(p_total numeric, p_weights numeric[]) returns numeric[]
language plpgsql immutable as $$
declare
  n int := coalesce(array_length(p_weights, 1), 0);
  w_sum numeric := 0;
  parts numeric[] := '{}';
  rems numeric[] := '{}';
  assigned numeric := 0;
  leftover numeric;
  i int;
  best int;
begin
  if n = 0 then return parts; end if;
  for i in 1..n loop
    if p_weights[i] < 0 then raise exception 'negative weight'; end if;
    w_sum := w_sum + p_weights[i];
  end loop;
  if w_sum = 0 then raise exception 'weights sum to zero'; end if;
  for i in 1..n loop
    parts := parts || floor(p_total * p_weights[i] / w_sum);
    rems := rems || ((p_total * p_weights[i]) % w_sum);
    assigned := assigned + parts[i];
  end loop;
  leftover := p_total - assigned;
  while leftover > 0 loop
    best := null;
    for i in 1..n loop
      if p_weights[i] > 0 and (best is null or rems[i] > rems[best]) then best := i; end if;
    end loop;
    parts[best] := parts[best] + 1;
    rems[best] := -1;
    leftover := leftover - 1;
  end loop;
  return parts;
end $$;

-- Human-readable reference (not secret). Alphabet avoids 0/O/1/I/L.
create or replace function knock.new_ref(p_prefix text) returns text
language plpgsql volatile as $$
declare
  alphabet text := '23456789ABCDEFGHJKMNPQRSTUVWXYZ';
  hex text := replace(gen_random_uuid()::text, '-', '');
  out text := '';
  i int;
begin
  for i in 0..7 loop
    out := out || substr(alphabet, 1 + (('x' || substr(hex, i*2 + 1, 2))::bit(8)::int % length(alphabet)), 1);
  end loop;
  return p_prefix || '-' || out;
end $$;

-- Unguessable public slug for the payment URL (from gen_random_uuid, 122 random bits).
create or replace function knock.new_slug() returns text
language sql volatile as $$
  select substr(replace(gen_random_uuid()::text, '-', ''), 1, 12) || substr(replace(gen_random_uuid()::text, '-', ''), 1, 8)
$$;
