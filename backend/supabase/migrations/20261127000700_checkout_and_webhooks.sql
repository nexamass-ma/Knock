-- Hosted checkout for payment links (Breet address per payment) and
-- business webhooks (signed event delivery to a URL the business sets).
--
-- Checkout follows Breet's e-commerce flow (docs.breet.io e-commerce guide):
--   1. a unique address per payment from generate-address, label = the
--      payment's Knock reference (the "order id");
--   2. the page shows address, exact amount, network and QR;
--   3. Breet's trade.pending / trade.completed / trade.flagged / trade.deleted
--      webhooks (verified by the existing CryptoService: x-webhook-secret, IP
--      allowlist, dedupe on eventId, re-fetch of the trade) move the payment;
--   4. trade.completed confirms the payment through confirm_payment, which
--      holds under- or over-payments for review instead of guessing.

-- ---------------------------------------------------------------------------
-- 1. Checkout
-- ---------------------------------------------------------------------------
alter table knock.provider_wallet_addresses add column payment_id uuid references knock.payments(id);
create unique index provider_wallet_addresses_payment on knock.provider_wallet_addresses (payment_id) where payment_id is not null;
-- A business can have many checkout addresses for the same asset (one per
-- payment); the one-live-address rule applies to wallet addresses only.
drop index knock.provider_wallet_addresses_one_live;
create unique index provider_wallet_addresses_one_live on knock.provider_wallet_addresses (provider, user_id, asset_id, network)
  where status in ('requested','active') and not is_wrong_asset_recovery and payment_id is null;

alter table knock.payments
  add column provider_trade_id   text,          -- Breet trade id once a deposit is detected
  add column checkout_state      text,          -- Breet deposit status: pending|below_minimum|flagged|under_review|completed|failed
  add column checkout_event_at   timestamptz,   -- eventTime of the last applied Breet event (ordering)
  add column crypto_received     numeric,       -- as reported by Breet, major units
  add column hold_reason         text,          -- Breet flagged / under review: nothing credited
  add column settlement_amount   numeric,       -- what Breet credited Knock (its holding currency), for reconciliation
  add column settlement_currency text;

-- Open a checkout: quote, payment intent and a REQUESTED address row. The
-- caller then asks Breet for the address (label = knock_reference) and
-- records it with record_deposit_address(request_id). Nothing is credited.
create or replace function knock.checkout_open(p_provider text, p_slug text, p_amount numeric, p jsonb) returns jsonb
language plpgsql as $$
declare v_link knock.payment_links; v_cfg record; v_ref text; r jsonb; v_addr uuid; v_flag boolean;
begin
  select * into v_link from knock.payment_links where slug = p_slug;
  if not found then perform knock.fail('not_found', 'this payment link does not exist'); end if;
  if v_link.currency = 'NGN' then
    perform knock.fail('method_unavailable', 'bank transfer checkout is not available yet');
  end if;
  select enabled into v_flag from knock.feature_flags where key = 'business.crypto_links';
  if not coalesce(v_flag, false) then perform knock.fail('feature_disabled', 'crypto checkout is turned off'); end if;
  select * into v_cfg from knock.provider_asset_configurations
  where provider = p_provider and symbol = v_link.currency and network = v_link.network and deposit_enabled limit 1;
  if not found then perform knock.fail('asset_unavailable', format('%s on %s is not available for payments right now', v_link.currency, v_link.network)); end if;
  v_ref := knock.new_ref('KCO');
  r := knock.create_payment_intent(p_slug, p_amount, jsonb_build_object(
         'provider', p_provider, 'provider_reference', v_ref, 'method', 'crypto',
         'payer_name', p->>'payer_name', 'payer_email', lower(p->>'payer_email'), 'customer_reference', p->>'customer_reference',
         'quote_expires_at', (now() + interval '30 minutes')::text));
  insert into knock.provider_wallet_addresses (user_id, provider, asset_id, symbol, network, label, payment_id)
  values (v_link.creator_id, p_provider, v_cfg.asset_id, v_cfg.symbol, v_cfg.network, v_ref, (r->>'payment_id')::uuid)
  returning id into v_addr;
  perform knock.audit(null, 'system', 'checkout.opened', v_link.id, (r->>'payment_id')::uuid, jsonb_build_object('asset', v_cfg.asset_id));
  return r || jsonb_build_object('label', v_ref, 'asset_id', v_cfg.asset_id, 'address_request_id', v_addr);
end $$;

-- Breet could not create the address: the payment fails, the payer may retry.
create or replace function knock.checkout_address_failed(p_address uuid, p_error text) returns void
language plpgsql as $$
declare a record;
begin
  update knock.provider_wallet_addresses set status = 'failed', last_error = left(p_error, 300), updated_at = now()
  where id = p_address and status = 'requested' returning * into a;
  if a.payment_id is not null then
    update knock.payments set status = 'failed', updated_at = now() where id = a.payment_id and status = 'initiated';
  end if;
end $$;

-- When the address arrives (API response or trade.address.created webhook),
-- put it on the payment and mark it waiting for the customer.
create or replace function knock.checkout_address_sync() returns trigger language plpgsql as $$
begin
  if new.payment_id is not null and new.address is not null and new.status = 'active' then
    update knock.payments set pay_address = new.address,
           status = case when status = 'initiated' then 'pending' else status end, updated_at = now()
    where id = new.payment_id and pay_address is distinct from new.address;
  end if;
  return new;
end $$;
create trigger provider_wallet_addresses_checkout after insert or update of address, status on knock.provider_wallet_addresses
  for each row execute function knock.checkout_address_sync();

-- Same as 20261127000400, plus: a lost generate-address response for a checkout
-- is recovered from the webhook by its label (the payment's Knock reference).
create or replace function knock.record_deposit_address(p_provider text, p jsonb) returns jsonb
language plpgsql as $$
declare a record; v_user uuid; v_req uuid := nullif(p->>'request_id','')::uuid; v_cfg record;
begin
  -- Already known by provider id or by address string: nothing to create.
  select * into a from knock.provider_wallet_addresses
  where provider = p_provider and (provider_address_id = p->>'provider_address_id'
        or (address = p->>'address' and p->>'address' is not null))
  limit 1 for update;
  if found then
    update knock.provider_wallet_addresses set
      provider_address_id = coalesce(provider_address_id, p->>'provider_address_id'),
      address = coalesce(address, p->>'address'),
      status = case when status = 'requested' then 'active' else status end,
      raw = coalesce(raw, '{}'::jsonb) || coalesce(p->'raw', '{}'::jsonb),
      updated_at = now()
    where id = a.id;
    return jsonb_build_object('result', 'existing', 'id', a.id);
  end if;

  -- The response path names the pending request row.
  if v_req is not null then
    update knock.provider_wallet_addresses set provider_address_id = p->>'provider_address_id', address = p->>'address',
      memo = p->>'memo', status = 'active', raw = p->'raw', updated_at = now()
    where id = v_req and provider = p_provider and status = 'requested';
    if found then return jsonb_build_object('result', 'activated', 'id', v_req); end if;
  end if;

  -- Checkout path: the label is a payment's Knock reference.
  select * into a from knock.provider_wallet_addresses
  where provider = p_provider and payment_id is not null and label = p->>'label' and status = 'requested'
  limit 1 for update;
  if found then
    update knock.provider_wallet_addresses set provider_address_id = p->>'provider_address_id', address = p->>'address',
      memo = p->>'memo', status = 'active', raw = p->'raw', updated_at = now()
    where id = a.id;
    return jsonb_build_object('result', 'activated', 'id', a.id);
  end if;

  -- Webhook path: the label is the Knock user id.
  begin v_user := (p->>'label')::uuid; exception when others then v_user := null; end;
  if v_user is null or not exists (select 1 from knock.profiles where id = v_user) then
    perform knock.fail('unknown_label', format('address label %s does not match a Knock user', p->>'label'));
  end if;

  -- A pending request for this user and asset (API response lost): activate it.
  select * into a from knock.provider_wallet_addresses
  where provider = p_provider and user_id = v_user and asset_id = p->>'asset' and status = 'requested'
  order by created_at desc limit 1 for update;
  if found and coalesce((p->>'is_wrong_asset')::boolean, false) = false then
    update knock.provider_wallet_addresses set provider_address_id = p->>'provider_address_id', address = p->>'address',
      memo = p->>'memo', status = 'active', raw = p->'raw', updated_at = now()
    where id = a.id;
    return jsonb_build_object('result', 'activated', 'id', a.id);
  end if;

  -- Otherwise this is a provider-initiated address (wrong-asset recovery or
  -- created outside Knock). Record it, flagged, so staff can see it.
  select * into v_cfg from knock.provider_asset_configurations where provider = p_provider and asset_id = p->>'asset' limit 1;
  insert into knock.provider_wallet_addresses (user_id, provider, provider_address_id, asset_id, symbol, network, address, memo,
                                               label, status, is_wrong_asset_recovery, raw)
  values (v_user, p_provider, p->>'provider_address_id', p->>'asset', coalesce(v_cfg.symbol, p->>'asset'), coalesce(v_cfg.network, ''),
          p->>'address', p->>'memo', p->>'label', 'active', true, p->'raw')
  returning id into v_req;
  perform knock.audit(null, 'provider', 'crypto.address.provider_created', null, null,
                      jsonb_build_object('address_id', v_req, 'asset', p->>'asset'));
  return jsonb_build_object('result', 'created_from_webhook', 'id', v_req);
end $$;

-- ---------------------------------------------------------------------------
-- A Breet deposit to a CHECKOUT address (the CryptoService routes it here
-- instead of crediting a wallet). p is VERIFIED against GET /trades/transactions/{id}:
--   {status: pending|below_minimum|flagged|under_review|completed|failed, event_time, event_id,
--    destination_address, wallet_id, crypto_amount, tx_hash, confirmations, sub_status, reason,
--    amount_credited, currency, settled_trades[]}
-- Only 'completed' can confirm the payment; flagged and under-review deposits
-- are never credited. A terminal state never goes back.
create or replace function knock.checkout_deposit_event(p_provider text, p_trade text, p jsonb) returns jsonb
language plpgsql as $$
declare
  a record; v knock.payments; v_link knock.payment_links; v_asset knock.assets;
  v_new text := p->>'status'; v_t timestamptz := (p->>'event_time')::timestamptz; v_dec text;
  v_paid numeric; r jsonb;
begin
  if v_new not in ('pending','below_minimum','flagged','under_review','completed','failed') then
    perform knock.fail('bad_request', 'unknown deposit status ' || coalesce(v_new, 'null'));
  end if;
  select * into a from knock.provider_wallet_addresses
  where provider = p_provider and payment_id is not null
    and (address = p->>'destination_address' or provider_address_id = p->>'wallet_id') limit 1;
  if not found then perform knock.fail('unknown_address', format('trade %s is not for a checkout address', p_trade)); end if;
  select * into v from knock.payments where id = a.payment_id for update;
  select * into v_link from knock.payment_links where id = v.link_id;

  -- Another trade to an address whose payment already has a live trade
  -- (a second transfer, or an overpayment top-up): never lost, never
  -- auto-credited; staff decide.
  if v.provider_trade_id is not null and v.provider_trade_id <> p_trade
     and not coalesce(p->'settled_trades' ? v.provider_trade_id, false)
     and coalesce(v.checkout_state, '') <> 'failed' then
    if not exists (select 1 from knock.risk_flags where payment_id = v.id and rule = 'checkout_extra_deposit' and detail->>'trade' = p_trade) then
      insert into knock.risk_flags (link_id, payment_id, user_id, rule, severity, detail)
      values (v.link_id, v.id, v_link.creator_id, 'checkout_extra_deposit', 'medium',
              jsonb_build_object('trade', p_trade, 'status', v_new, 'crypto_amount', p->>'crypto_amount', 'tx_hash', p->>'tx_hash'));
    end if;
    return jsonb_build_object('result', 'extra_deposit_flagged', 'payment_id', v.id);
  end if;

  if v.provider_trade_id is distinct from p_trade and coalesce(p->'settled_trades' ? v.provider_trade_id, false) is not true then
    v_dec := 'apply';                                   -- first trade (or a retry after a failed one)
  else
    v_dec := knock.order_check(knock.deposit_rank(v.checkout_state), knock.deposit_rank(v_new), v.checkout_state, v_new, v.checkout_event_at, v_t);
    if v_dec = 'duplicate' and v.checkout_state = v_new and knock.deposit_rank(v_new) < 9 then v_dec := 'apply'; end if;
  end if;
  if v_dec <> 'apply' then return jsonb_build_object('result', v_dec, 'payment_id', v.id, 'status', v.status); end if;

  update knock.payments set provider_trade_id = p_trade, checkout_state = v_new, checkout_event_at = coalesce(v_t, checkout_event_at),
         crypto_received = coalesce((p->>'crypto_amount')::numeric, crypto_received),
         hold_reason = case when v_new in ('below_minimum','flagged','under_review') then coalesce(p->>'reason', p->>'sub_status', v_new)
                            when v_new in ('completed','failed') then null else hold_reason end,
         updated_at = now()
  where id = v.id;

  if v_new = 'pending' then
    perform knock.update_payment_progress(p_provider, v.provider_reference, 'confirming', (p->>'confirmations')::int, p->>'tx_hash');
    return jsonb_build_object('result', 'detected', 'payment_id', v.id);
  end if;
  if v_new in ('below_minimum','flagged','under_review') then
    perform knock.update_payment_progress(p_provider, v.provider_reference, 'confirming', (p->>'confirmations')::int, p->>'tx_hash');
    if not exists (select 1 from knock.risk_flags where payment_id = v.id and rule = 'checkout_held_by_provider' and status = 'open') then
      insert into knock.risk_flags (link_id, payment_id, user_id, rule, severity, detail)
      values (v.link_id, v.id, v_link.creator_id, 'checkout_held_by_provider', case when v_new = 'under_review' then 'high' else 'medium' end,
              jsonb_build_object('trade', p_trade, 'status', v_new, 'sub_status', p->>'sub_status', 'reason', p->>'reason'));
    end if;
    perform knock.notify(v_link.creator_id, 'payment_held', 'Payment on hold',
      format('A crypto payment to "%s" (%s) is on hold with the provider: %s. Nothing is credited until it clears.',
             v_link.title, v.knock_reference, replace(v_new, '_', ' ')), v_link.id, v.id);
    return jsonb_build_object('result', 'held', 'payment_id', v.id, 'state', v_new);
  end if;
  if v_new = 'failed' then
    perform knock.update_payment_progress(p_provider, v.provider_reference, 'failed', null, p->>'tx_hash');
    return jsonb_build_object('result', 'failed', 'payment_id', v.id);
  end if;

  -- completed: Breet reports the crypto actually received. Convert to the
  -- link currency's minor units; confirm_payment compares it with what was
  -- due and holds any difference (underpayment / overpayment) for review.
  select * into v_asset from knock.assets where code = v.currency and network = v.network;
  if (p->>'crypto_amount') is null then perform knock.fail('reconciliation_failed', 'completed deposit has no crypto amount'); end if;
  v_paid := round((p->>'crypto_amount')::numeric * power(10::numeric, v_asset.decimals));
  update knock.payments set settlement_amount = nullif(p->>'amount_credited', '')::numeric, settlement_currency = upper(p->>'currency')
  where id = v.id;
  r := knock.confirm_payment(p_provider, v.provider_reference, jsonb_build_object(
         'amount_paid', v_paid::text, 'currency', v.currency, 'network', v.network, 'tx_hash', p->>'tx_hash',
         -- Breet marks a trade completed only after its own confirmation
         -- threshold; its count is kept as reported.
         'confirmations', greatest(coalesce((p->>'confirmations')::int, 0), v_asset.min_confirmations),
         'provider_confirmations', (p->>'confirmations')::int, 'provider_status', 'completed', 'trade_id', p_trade,
         'crypto_amount', p->>'crypto_amount', 'provider_credited', p->>'amount_credited', 'provider_currency', p->>'currency'));
  return r || jsonb_build_object('result', 'completed:' || (r->>'result'));
end $$;

-- Checkouts nobody paid within the quote window. The address stays known: a
-- late transfer is still matched and confirmed (money is never lost).
create or replace function knock.expire_checkouts() returns int
language plpgsql as $$
declare v record; n int := 0;
begin
  for v in select provider, provider_reference from knock.payments
           where method = 'crypto' and status in ('initiated','pending') and checkout_state is null
             and quote_expires_at is not null and quote_expires_at < now() for update skip locked loop
    perform knock.update_payment_progress(v.provider, v.provider_reference, 'expired');
    n := n + 1;
  end loop;
  return n;
end $$;

-- What the public checkout page may see about one payment (by its id, which
-- only the payer's browser holds). No provider ids, no internal fields.
create or replace function knock.checkout_status(p_payment uuid) returns jsonb
language sql stable as $$
  select jsonb_build_object(
    'payment_id', p.id, 'reference', p.knock_reference, 'status', p.status, 'state', p.checkout_state,
    'currency', p.currency, 'network', p.network, 'decimals', s.decimals,
    'amount', p.amount::text, 'payer_fee', p.payer_fee::text, 'total', (p.amount + p.payer_fee)::text,
    'address', coalesce(a.address, p.pay_address), 'memo', a.memo, 'address_status', a.status,
    'expires_at', p.quote_expires_at, 'confirmations', p.confirmations, 'required_confirmations', s.min_confirmations,
    'received', case when p.crypto_received is not null then round(p.crypto_received * power(10::numeric, s.decimals))::text end,
    'tx_hash', p.tx_hash, 'held', p.hold_reason is not null, 'under_review', (p.status = 'succeeded' and p.distribution_status = 'held' and p.last_distribution_error is not null),
    'payer_name', p.payer_name, 'customer_reference', p.customer_reference, 'paid_at', p.verified_at,
    'link', jsonb_build_object('title', l.title, 'reference', l.reference, 'slug', l.slug),
    'merchant', pr.display_name, 'handle', pr.username)
  from knock.payments p join knock.payment_links l on l.id = p.link_id join knock.profiles pr on pr.id = l.creator_id
  left join knock.assets s on s.code = p.currency and s.network = p.network
  left join knock.provider_wallet_addresses a on a.payment_id = p.id
  where p.id = p_payment and p.method = 'crypto'
$$;

-- ---------------------------------------------------------------------------
-- 2. Business webhooks
-- ---------------------------------------------------------------------------
-- Events a business can subscribe to.
create table knock.business_webhook_event_types (
  type        text primary key,
  description text not null
);
insert into knock.business_webhook_event_types values
  ('payment.pending',      'A payment to one of your links was detected on chain and is confirming.'),
  ('payment.held',         'The provider is holding a payment for review. Nothing is credited yet.'),
  ('payment.succeeded',    'A payment was verified with the provider and recorded in your ledger.'),
  ('payment.failed',       'A payment failed or was rejected. Nothing was credited.'),
  ('payment.expired',      'A checkout was not paid before its quote expired.'),
  ('deposit.completed',    'A crypto deposit to your business wallet was credited.'),
  ('payout.completed',     'A withdrawal from your business account was completed by the provider.'),
  ('payout.failed',        'A withdrawal was rejected or reversed; the funds were returned.');

create table knock.business_webhook_endpoints (
  id           uuid primary key default gen_random_uuid(),
  business_id  uuid not null references knock.businesses(id),
  url          text not null,
  description  text,
  events       text[] not null,
  -- Signing secret. Shown to the business once (on create / rotate) and only
  -- ever read again by the delivery worker. Never returned by a list op.
  secret       text not null,
  secret_hint  text not null,
  status       text not null default 'active' check (status in ('active','disabled','deleted')),
  created_by   uuid references knock.profiles(id),
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  rotated_at   timestamptz
);
create index business_webhook_endpoints_biz on knock.business_webhook_endpoints (business_id) where status <> 'deleted';

create table knock.business_webhook_events (
  id          uuid primary key default gen_random_uuid(),
  event_ref   text not null unique default knock.new_ref('KEV'),   -- the id the business sees and dedupes on
  business_id uuid not null references knock.businesses(id),
  type        text not null,
  payload     jsonb not null,
  dedupe_key  text not null unique,                                 -- one event per state change
  created_at  timestamptz not null default now()
);
create index business_webhook_events_biz on knock.business_webhook_events (business_id, created_at desc);

create table knock.business_webhook_deliveries (
  id               uuid primary key default gen_random_uuid(),
  event_id         uuid not null references knock.business_webhook_events(id),
  endpoint_id      uuid not null references knock.business_webhook_endpoints(id),
  status           text not null default 'pending' check (status in ('pending','sending','retrying','delivered','failed','cancelled')),
  attempts         int not null default 0,
  next_attempt_at  timestamptz not null default now(),
  locked_until     timestamptz,
  last_status_code int,
  last_error       text,
  last_duration_ms int,
  delivered_at     timestamptz,
  created_at       timestamptz not null default now(),
  unique (event_id, endpoint_id)
);
create index business_webhook_deliveries_due on knock.business_webhook_deliveries (next_attempt_at) where status in ('pending','retrying','sending');

create or replace function knock.new_webhook_secret() returns text language sql volatile as $$
  select 'whsec_' || replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '')
$$;

-- Basic URL rules in the database; the worker also resolves DNS and refuses
-- private, loopback and link-local addresses at send time (SSRF guard).
create or replace function knock.check_webhook_url(p_url text) returns text language plpgsql immutable as $$
declare h text;
begin
  if p_url is null or length(p_url) > 500 or p_url !~ '^https://[^/?#@\s]+(/[^\s]*)?$' then
    perform knock.fail('invalid_url', 'use a full https:// address (no username or password in it)');
  end if;
  h := lower(split_part(split_part(substr(p_url, 9), '/', 1), ':', 1));
  if h in ('localhost') or h like '%.localhost' or h like '%.local' or h like '%.internal'
     or h ~ '^(10|127|0)\.' or h ~ '^192\.168\.' or h ~ '^172\.(1[6-9]|2[0-9]|3[01])\.' or h ~ '^169\.254\.' or h ~ '^\[' then
    perform knock.fail('invalid_url', 'the webhook address must be a public internet address');
  end if;
  return p_url;
end $$;

create or replace function knock.check_webhook_events(p_events jsonb) returns text[] language plpgsql stable as $$
declare v text[];
begin
  select array_agg(distinct e order by e) into v from jsonb_array_elements_text(coalesce(p_events, '[]')) e;
  if v is null or cardinality(v) = 0 then perform knock.fail('invalid_events', 'choose at least one event'); end if;
  if exists (select 1 from unnest(v) e where e not in (select type from knock.business_webhook_event_types)) then
    perform knock.fail('invalid_events', 'unknown event type');
  end if;
  return v;
end $$;

create or replace function knock.business_webhook_create(p_user uuid, p_business uuid, p jsonb) returns jsonb
language plpgsql as $$
declare b knock.businesses; v_secret text := knock.new_webhook_secret(); v_id uuid;
begin
  b := knock.require_business(p_user, p_business, 'settings.manage');
  if (select count(*) from knock.business_webhook_endpoints where business_id = p_business and status <> 'deleted') >= 5 then
    perform knock.fail('limit_exceeded', 'a business can have up to 5 webhook endpoints');
  end if;
  insert into knock.business_webhook_endpoints (business_id, url, description, events, secret, secret_hint, created_by)
  values (p_business, knock.check_webhook_url(trim(p->>'url')), nullif(left(trim(p->>'description'), 120), ''),
          knock.check_webhook_events(p->'events'), v_secret, right(v_secret, 4), p_user)
  returning id into v_id;
  perform knock.baudit(p_user, p_business, 'webhook.endpoint_created', jsonb_build_object('endpoint', v_id, 'url', trim(p->>'url')));
  return jsonb_build_object('id', v_id, 'secret', v_secret);
end $$;

create or replace function knock.business_webhook_update(p_user uuid, p_business uuid, p_endpoint uuid, p jsonb) returns void
language plpgsql as $$
declare b knock.businesses;
begin
  b := knock.require_business(p_user, p_business, 'settings.manage');
  update knock.business_webhook_endpoints set
    url = case when p ? 'url' then knock.check_webhook_url(trim(p->>'url')) else url end,
    description = case when p ? 'description' then nullif(left(trim(p->>'description'), 120), '') else description end,
    events = case when p ? 'events' then knock.check_webhook_events(p->'events') else events end,
    status = case when p->>'status' in ('active','disabled') then p->>'status' else status end,
    updated_at = now()
  where id = p_endpoint and business_id = p_business and status <> 'deleted';
  if not found then perform knock.fail('not_found', 'webhook endpoint not found'); end if;
  if p->>'status' = 'disabled' then
    update knock.business_webhook_deliveries set status = 'cancelled', last_error = 'endpoint disabled'
    where endpoint_id = p_endpoint and status in ('pending','retrying');
  end if;
  perform knock.baudit(p_user, p_business, 'webhook.endpoint_updated', jsonb_build_object('endpoint', p_endpoint) || (p - 'secret'));
end $$;

create or replace function knock.business_webhook_rotate(p_user uuid, p_business uuid, p_endpoint uuid) returns jsonb
language plpgsql as $$
declare b knock.businesses; v_secret text := knock.new_webhook_secret();
begin
  b := knock.require_business(p_user, p_business, 'settings.manage');
  update knock.business_webhook_endpoints set secret = v_secret, secret_hint = right(v_secret, 4), rotated_at = now(), updated_at = now()
  where id = p_endpoint and business_id = p_business and status <> 'deleted';
  if not found then perform knock.fail('not_found', 'webhook endpoint not found'); end if;
  perform knock.baudit(p_user, p_business, 'webhook.secret_rotated', jsonb_build_object('endpoint', p_endpoint));
  return jsonb_build_object('secret', v_secret);
end $$;

create or replace function knock.business_webhook_delete(p_user uuid, p_business uuid, p_endpoint uuid) returns void
language plpgsql as $$
declare b knock.businesses;
begin
  b := knock.require_business(p_user, p_business, 'settings.manage');
  update knock.business_webhook_endpoints set status = 'deleted', updated_at = now()
  where id = p_endpoint and business_id = p_business and status <> 'deleted';
  if not found then perform knock.fail('not_found', 'webhook endpoint not found'); end if;
  update knock.business_webhook_deliveries set status = 'cancelled', last_error = 'endpoint deleted'
  where endpoint_id = p_endpoint and status in ('pending','retrying');
  perform knock.baudit(p_user, p_business, 'webhook.endpoint_deleted', jsonb_build_object('endpoint', p_endpoint));
end $$;

-- Queue an event for every active endpoint of the business subscribed to it.
-- Idempotent on dedupe_key (one event per state change).
create or replace function knock.emit_business_event(p_business uuid, p_type text, p_dedupe text, p_data jsonb, p_only_endpoint uuid default null)
returns uuid language plpgsql as $$
declare v_id uuid; v_ref text;
begin
  if not exists (select 1 from knock.businesses where id = p_business) then return null; end if;
  insert into knock.business_webhook_events (business_id, type, payload, dedupe_key)
  values (p_business, p_type, '{}'::jsonb, p_dedupe)
  on conflict (dedupe_key) do nothing
  returning id, event_ref into v_id, v_ref;
  if v_id is null then return null; end if;
  -- The body the business receives (and verifies the signature over).
  update knock.business_webhook_events set payload = jsonb_build_object(
    'id', v_ref, 'type', p_type, 'created_at', to_char(now() at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'),
    'livemode', false, 'data', p_data) where id = v_id;
  insert into knock.business_webhook_deliveries (event_id, endpoint_id)
  select v_id, e.id from knock.business_webhook_endpoints e
  where e.business_id = p_business and e.status = 'active'
    and (p_only_endpoint is null or e.id = p_only_endpoint)
    and (p_type = 'test.ping' or p_type = any(e.events));
  return v_id;
end $$;

create or replace function knock.business_webhook_test(p_user uuid, p_business uuid, p_endpoint uuid) returns jsonb
language plpgsql as $$
declare b knock.businesses; v_id uuid;
begin
  b := knock.require_business(p_user, p_business, 'settings.manage');
  if not exists (select 1 from knock.business_webhook_endpoints where id = p_endpoint and business_id = p_business and status = 'active') then
    perform knock.fail('not_found', 'active webhook endpoint not found');
  end if;
  v_id := knock.emit_business_event(p_business, 'test.ping', 'test:' || gen_random_uuid(),
            jsonb_build_object('message', 'Test event from Knock. Your endpoint is reachable if you received this.'), p_endpoint);
  return jsonb_build_object('event_id', v_id);
end $$;

create or replace function knock.business_webhook_retry(p_user uuid, p_business uuid, p_delivery uuid) returns void
language plpgsql as $$
declare b knock.businesses;
begin
  b := knock.require_business(p_user, p_business, 'settings.manage');
  update knock.business_webhook_deliveries d set status = 'pending', next_attempt_at = now(), last_error = null
  from knock.business_webhook_endpoints e
  where d.id = p_delivery and e.id = d.endpoint_id and e.business_id = p_business and e.status = 'active'
    and d.status in ('failed','cancelled','retrying');
  if not found then perform knock.fail('not_found', 'delivery not found or not retryable'); end if;
  perform knock.baudit(p_user, p_business, 'webhook.redelivery_requested', jsonb_build_object('delivery', p_delivery));
end $$;

-- Worker: claim due deliveries (crash-safe lease), then report each result.
create or replace function knock.claim_webhook_deliveries(p_limit int) returns table (
  delivery_id uuid, url text, secret text, event_ref text, type text, body text, attempts int)
language plpgsql as $$
begin
  return query
  with due as (
    select d.id from knock.business_webhook_deliveries d
    where (d.status in ('pending','retrying') and d.next_attempt_at <= now())
       or (d.status = 'sending' and d.locked_until < now())
    order by d.next_attempt_at limit p_limit for update skip locked
  ), upd as (
    update knock.business_webhook_deliveries d set status = 'sending', locked_until = now() + interval '2 minutes'
    from due where d.id = due.id returning d.id, d.event_id, d.endpoint_id, d.attempts
  )
  select upd.id, e.url, e.secret, ev.event_ref, ev.type, ev.payload::text, upd.attempts
  from upd join knock.business_webhook_endpoints e on e.id = upd.endpoint_id join knock.business_webhook_events ev on ev.id = upd.event_id
  where e.status = 'active';
end $$;

-- Retry schedule after attempt n: 1m, 5m, 30m, 2h, 6h, 12h, 24h; 8 attempts in total.
create or replace function knock.webhook_delivery_result(p_delivery uuid, p_ok boolean, p_status int, p_error text, p_ms int) returns text
language plpgsql as $$
declare d knock.business_webhook_deliveries; v_next interval;
begin
  select * into d from knock.business_webhook_deliveries where id = p_delivery for update;
  if not found or d.status <> 'sending' then return 'ignored'; end if;
  if p_ok then
    update knock.business_webhook_deliveries set status = 'delivered', attempts = attempts + 1, delivered_at = now(),
      last_status_code = p_status, last_error = null, last_duration_ms = p_ms, locked_until = null where id = p_delivery;
    return 'delivered';
  end if;
  v_next := (array['1 minute','5 minutes','30 minutes','2 hours','6 hours','12 hours','24 hours']::interval[])[d.attempts + 1];
  update knock.business_webhook_deliveries set
    status = case when v_next is null then 'failed' else 'retrying' end, attempts = attempts + 1,
    next_attempt_at = now() + coalesce(v_next, interval '0'), last_status_code = p_status,
    last_error = left(p_error, 300), last_duration_ms = p_ms, locked_until = null
  where id = p_delivery;
  return case when v_next is null then 'failed' else 'retrying' end;
end $$;

-- Events from the ledger-side records. Triggers only queue; nothing here
-- talks to the network.
create or replace function knock.payment_webhook_trigger() returns trigger language plpgsql as $$
declare v_link knock.payment_links; v_type text;
begin
  v_type := case
    when new.status = 'succeeded' and old.status is distinct from 'succeeded' then 'payment.succeeded'
    when new.status = 'failed' and old.status is distinct from 'failed' then 'payment.failed'
    when new.status = 'expired' and old.status is distinct from 'expired' then 'payment.expired'
    when new.hold_reason is not null and old.hold_reason is null then 'payment.held'
    when new.status = 'confirming' and old.status in ('initiated','pending') then 'payment.pending'
  end;
  if v_type is null then return new; end if;
  select * into v_link from knock.payment_links where id = new.link_id;
  perform knock.emit_business_event(v_link.creator_id, v_type, 'payment:' || new.id || ':' || v_type, jsonb_build_object(
    'reference', new.knock_reference, 'status', new.status, 'amount', new.amount::text, 'payer_fee', new.payer_fee::text,
    'knock_fee', new.knock_fee::text, 'currency', new.currency, 'network', new.network,
    'decimals', (select decimals from knock.assets where code = new.currency and network = new.network),
    'method', new.method, 'tx_hash', new.tx_hash, 'confirmations', new.confirmations, 'held_reason', new.hold_reason,
    'under_review', (new.status = 'succeeded' and new.last_distribution_error is not null),
    'payer', jsonb_build_object('name', new.payer_name, 'email', new.payer_email), 'customer_reference', new.customer_reference,
    'link', jsonb_build_object('reference', v_link.reference, 'title', v_link.title, 'invoice_number', v_link.invoice_number),
    'created_at', new.created_at, 'paid_at', new.verified_at));
  return new;
end $$;
create trigger payments_business_webhooks after update of status, hold_reason on knock.payments
  for each row execute function knock.payment_webhook_trigger();

create or replace function knock.deposit_webhook_trigger() returns trigger language plpgsql as $$
begin
  if new.status = 'completed' and old.status is distinct from 'completed' then
    perform knock.emit_business_event(new.user_id, 'deposit.completed', 'deposit:' || new.id, jsonb_build_object(
      'reference', new.knock_reference, 'asset', new.symbol, 'network', new.network, 'crypto_amount', new.crypto_amount::text,
      'credited_currency', new.credited_currency, 'credited_amount', new.customer_net_minor::text, 'tx_hash', new.tx_hash));
  end if;
  return new;
end $$;
create trigger crypto_deposits_business_webhooks after update of status on knock.crypto_deposits
  for each row execute function knock.deposit_webhook_trigger();

create or replace function knock.withdrawal_webhook_trigger() returns trigger language plpgsql as $$
declare v_type text;
begin
  v_type := case when new.status = 'completed' then 'payout.completed' when new.status in ('rejected','reversed') then 'payout.failed' end;
  if v_type is not null and old.status is distinct from new.status then
    perform knock.emit_business_event(new.user_id, v_type, 'payout:' || new.id || ':' || new.status, jsonb_build_object(
      'reference', new.knock_reference, 'status', new.status, 'currency', new.currency, 'amount', new.amount_minor::text,
      'tx_hash', new.tx_hash, 'reason', case when new.status <> 'completed' then new.reason end));
  end if;
  return new;
end $$;
create trigger provider_withdrawals_business_webhooks after update of status on knock.provider_withdrawals
  for each row execute function knock.withdrawal_webhook_trigger();
