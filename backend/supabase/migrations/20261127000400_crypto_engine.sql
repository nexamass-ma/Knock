-- KNOCK crypto provider engine: every money movement for provider deposits,
-- withdrawals and settlements, as single-transaction Postgres functions.
--
-- The TypeScript layer (backend/src/crypto/*) verifies webhooks, re-fetches
-- the provider's record, and then calls exactly one of these functions with
-- the VERIFIED provider figures. These functions enforce:
--   * idempotency (journal idempotency keys derived from provider ids),
--   * state ordering (terminal states never move; stale events are ignored),
--   * the ledger lifecycle (reserve -> complete | release),
--   * separate fee records,
--   * notifications and audit rows in the same transaction.
set search_path = knock, public;

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

create or replace function knock.deposit_rank(p_status text) returns int language sql immutable as $$
  select case p_status when 'pending' then 1 when 'below_minimum' then 2 when 'flagged' then 2
                       when 'under_review' then 3 when 'completed' then 9 when 'failed' then 9 else 0 end
$$;

create or replace function knock.withdrawal_rank(p_status text) returns int language sql immutable as $$
  select case p_status when 'reserved' then 0 when 'submitting' then 0 when 'submission_unknown' then 0
                       when 'pending' then 1 when 'processing' then 2
                       when 'completed' then 9 when 'reversed' then 9 when 'rejected' then 9
                       when 'not_submitted' then 9 when 'capacity_unavailable' then 9 else 0 end
$$;

create or replace function knock.is_terminal_withdrawal(p_status text) returns boolean language sql immutable as $$
  select knock.withdrawal_rank(p_status) = 9
$$;

-- Decide whether an incoming state may be applied. Returns 'apply',
-- 'duplicate', 'ignored_terminal' or 'ignored_stale'.
create or replace function knock.order_check(p_cur_rank int, p_new_rank int, p_cur_status text, p_new_status text,
                                             p_last timestamptz, p_event timestamptz)
returns text language sql immutable as $$
  select case
    when p_cur_status = p_new_status and p_cur_rank = 9 then 'duplicate'
    when p_cur_rank = 9 then 'ignored_terminal'
    when p_new_rank = 9 then 'apply'                                  -- terminal always wins over non-terminal
    when p_last is not null and p_event is not null and p_event < p_last then 'ignored_stale'
    when p_last is not null and p_event is not null and p_event = p_last and p_new_rank <= p_cur_rank then 'duplicate'
    else 'apply' end
$$;

create or replace function knock.mask_account(p_last4 text) returns text language sql immutable as $$
  select '******' || coalesce(p_last4, '????')
$$;

-- ---------------------------------------------------------------------------
-- Deposit addresses
-- ---------------------------------------------------------------------------

-- Reserve the address row before calling the provider so concurrent taps
-- cannot create two addresses. Returns the existing live row when present.
create or replace function knock.request_deposit_address(p_user uuid, p_provider text, p_asset_id text, p_symbol text,
                                                        p_network text, p_bank uuid, p_auto boolean)
returns jsonb language plpgsql as $$
declare u record; a record; v_id uuid;
begin
  select * into u from knock.profiles where id = p_user for update;
  if not found then perform knock.fail('not_found', 'user not found'); end if;
  if u.status <> 'active' then perform knock.fail('account_restricted', 'account is not active'); end if;
  if u.kyc_tier < 1 then perform knock.fail('kyc_required', 'verify your identity to receive crypto'); end if;
  if not exists (select 1 from knock.provider_asset_configurations
                 where provider = p_provider and asset_id = p_asset_id and network = coalesce(p_network,'') and deposit_enabled) then
    perform knock.fail('asset_unavailable', 'this asset is not currently available for deposits');
  end if;
  if p_auto and p_bank is null then perform knock.fail('bank_required', 'auto-settlement needs a verified bank account'); end if;
  if p_bank is not null and not exists (select 1 from knock.bank_accounts where id = p_bank and user_id = p_user and status = 'active' and verified_at is not null) then
    perform knock.fail('bank_required', 'bank account not found or not verified');
  end if;

  select * into a from knock.provider_wallet_addresses
  where provider = p_provider and user_id = p_user and asset_id = p_asset_id and network = coalesce(p_network,'')
    and status in ('requested','active') and not is_wrong_asset_recovery;
  if found then
    return jsonb_build_object('created', false, 'address', to_jsonb(a));
  end if;
  insert into knock.provider_wallet_addresses (user_id, provider, asset_id, symbol, network, label, bank_account_id, auto_settlement)
  values (p_user, p_provider, p_asset_id, p_symbol, coalesce(p_network,''), p_user::text, p_bank, coalesce(p_auto,false))
  returning id into v_id;
  perform knock.audit(p_user, 'user', 'crypto.address.requested', null, null, jsonb_build_object('address_id', v_id, 'asset', p_asset_id));
  return jsonb_build_object('created', true, 'address', (select to_jsonb(x) from knock.provider_wallet_addresses x where id = v_id));
end $$;

-- Record a provider address from EITHER the generate-address response or the
-- trade.address.created webhook. Idempotent on provider id and on address.
-- p: {provider_address_id, address, asset, label, memo, raw, is_wrong_asset, request_id}
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
-- Deposits
-- ---------------------------------------------------------------------------

-- Find (or create) the deposit row for a provider trade. The address is
-- matched on the provider's destination address.
create or replace function knock.deposit_row(p_provider text, p_trade text, p jsonb) returns knock.crypto_deposits
language plpgsql as $$
declare d knock.crypto_deposits; a record;
begin
  select * into d from knock.crypto_deposits where provider = p_provider and provider_trade_id = p_trade for update;
  if found then return d; end if;
  select * into a from knock.provider_wallet_addresses
  where provider = p_provider and (address = p->>'destination_address' or provider_address_id = p->>'wallet_id')
  limit 1;
  if not found then
    perform knock.fail('unknown_address', format('trade %s is for an address Knock does not know', p_trade));
  end if;
  insert into knock.crypto_deposits (user_id, address_id, provider, provider_trade_id, asset_id, symbol, network)
  values (a.user_id, a.id, p_provider, p_trade, coalesce(p->>'asset', a.asset_id), a.symbol, a.network)
  on conflict (provider, provider_trade_id) do nothing;
  select * into d from knock.crypto_deposits where provider = p_provider and provider_trade_id = p_trade for update;
  return d;
end $$;

-- Non-crediting deposit states: pending, flagged (below minimum / review), deleted.
-- p: {status: pending|below_minimum|flagged|under_review|failed, event_time, event_id,
--     destination_address, asset, crypto_amount, amount_in_usd, tx_hash, confirmations,
--     sub_status, reason, balance_remaining, is_wrong_asset, kyt, snapshot}
create or replace function knock.record_deposit_state(p_provider text, p_trade text, p jsonb) returns jsonb
language plpgsql as $$
declare d knock.crypto_deposits; v_new text := p->>'status'; v_t timestamptz := (p->>'event_time')::timestamptz; v_dec text;
begin
  if v_new not in ('pending','below_minimum','flagged','under_review','failed') then
    perform knock.fail('bad_request', 'record_deposit_state cannot set ' || v_new);
  end if;
  d := knock.deposit_row(p_provider, p_trade, p);
  v_dec := knock.order_check(knock.deposit_rank(d.status), knock.deposit_rank(v_new), d.status, v_new, d.last_event_time, v_t);
  -- Re-recording the same non-terminal status with new confirmations is progress, not a duplicate.
  if v_dec = 'duplicate' and d.status = v_new and knock.deposit_rank(v_new) < 9 then v_dec := 'apply'; end if;
  if v_dec <> 'apply' then return jsonb_build_object('result', v_dec, 'deposit_id', d.id, 'status', d.status); end if;

  update knock.crypto_deposits set
    status = v_new,
    sub_status = coalesce(p->>'sub_status', sub_status),
    crypto_amount = coalesce((p->>'crypto_amount')::numeric, crypto_amount),
    amount_in_usd = coalesce((p->>'amount_in_usd')::numeric, amount_in_usd),
    tx_hash = coalesce(p->>'tx_hash', tx_hash),
    confirmations = coalesce((p->>'confirmations')::int, confirmations),
    balance_remaining = case when v_new = 'below_minimum' then (p->>'balance_remaining')::numeric else balance_remaining end,
    flag_reason = case when v_new in ('below_minimum','flagged','under_review') then coalesce(p->>'reason', p->>'sub_status', flag_reason) else flag_reason end,
    failure_reason = case when v_new = 'failed' then coalesce(p->>'reason', 'failed') else failure_reason end,
    is_wrong_asset = is_wrong_asset or coalesce((p->>'is_wrong_asset')::boolean, false),
    last_event_time = coalesce(v_t, last_event_time),
    last_event_id = coalesce(p->>'event_id', last_event_id),
    provider_snapshot = coalesce(p->'snapshot', provider_snapshot),
    updated_at = now()
  where id = d.id;

  if v_new = 'under_review' and d.status <> 'under_review' then
    insert into knock.risk_flags (user_id, rule, severity, detail, subject_kind, subject_id)
    values (d.user_id, 'provider_compliance_review', 'high',
            jsonb_build_object('provider', p_provider, 'trade_id', p_trade, 'sub_status', p->>'sub_status', 'kyt', p->'kyt'),
            'crypto_deposit', d.id);
  end if;

  if d.status is distinct from v_new then
    perform knock.notify(d.user_id, 'crypto_deposit',
      case v_new when 'pending' then 'Deposit detected' when 'below_minimum' then 'Deposit below minimum'
                 when 'flagged' then 'Deposit on hold' when 'under_review' then 'Deposit under review' else 'Deposit failed' end,
      case v_new
        when 'pending' then 'We''ve detected your crypto deposit. We''re waiting for the required blockchain confirmations.'
        when 'below_minimum' then 'Your deposit is below the minimum. Send a top-up to the same address and we''ll credit the total once the minimum is reached.'
        when 'flagged' then 'Your deposit is on hold. We''ll update you as soon as it is resolved.'
        when 'under_review' then 'Your deposit is undergoing additional verification. We''ll update you when the review is complete.'
        else 'Your deposit could not be completed and has not been credited.' end,
      null, null, jsonb_build_object('deposit_id', d.id));
  end if;
  perform knock.audit(null, 'provider', 'crypto.deposit.' || v_new, null, null, jsonb_build_object('deposit_id', d.id, 'trade', p_trade, 'event', p->>'event_id'));
  return jsonb_build_object('result', 'applied', 'deposit_id', d.id, 'status', v_new);
end $$;

-- The only function that credits a customer for a crypto deposit.
-- p (VERIFIED against the provider's record): {event_time, event_id, destination_address, asset,
--   amount_credited, currency, crypto_amount, amount_in_usd, tx_hash, confirmations, rate,
--   conversion_rate, fee_amount_usd, fee_percentage, settled_trades[], is_wrong_asset, snapshot}
create or replace function knock.complete_crypto_deposit(p_provider text, p_trade text, p jsonb) returns jsonb
language plpgsql as $$
declare
  d knock.crypto_deposits; a record; pa record;
  v_cur text := upper(p->>'currency');
  v_amt numeric := (p->>'amount_credited')::numeric;
  v_minor numeric; v_fee numeric; v_net numeric; v_entry uuid; v_dec text;
  v_wallet uuid; v_user_acct uuid; v_auto boolean; v_settle_acct uuid; t text;
begin
  if v_cur is null or v_amt is null or v_amt <= 0 then
    perform knock.fail('bad_request', 'completed deposit needs a positive amount_credited and currency');
  end if;
  d := knock.deposit_row(p_provider, p_trade, p);
  v_dec := knock.order_check(knock.deposit_rank(d.status), 9, d.status, 'completed', d.last_event_time, (p->>'event_time')::timestamptz);
  if v_dec <> 'apply' then return jsonb_build_object('result', v_dec, 'deposit_id', d.id, 'status', d.status); end if;

  select * into a from knock.provider_wallet_addresses where id = d.address_id;
  v_minor := knock.to_minor(v_amt, v_cur);
  v_fee := knock.crypto_fee('deposit', v_cur, v_minor);
  v_net := v_minor - v_fee;
  v_wallet := knock.provider_account(p_provider, 'provider_wallet', v_cur);
  v_user_acct := knock.account(d.user_id, null, 'user_available', v_cur);

  v_entry := knock.post_entry('crypto:' || p_provider || ':deposit:' || p_trade || ':credit', 'crypto_deposit', v_cur,
    jsonb_build_array(
      jsonb_build_object('account', v_wallet, 'amount', v_minor::text),
      jsonb_build_object('account', v_user_acct, 'amount', (-v_net)::text),
      jsonb_build_object('account', knock.account(null, null, 'fee_revenue', v_cur), 'amount', (-v_fee)::text)),
    null, null, format('Crypto deposit %s (%s)', p_trade, d.knock_reference));

  update knock.crypto_deposits set
    status = 'completed', sub_status = coalesce(p->>'sub_status', 'completed'),
    credited_currency = v_cur, amount_credited = v_amt, credited_minor = v_minor, knock_fee_minor = v_fee, customer_net_minor = v_net,
    crypto_amount = coalesce((p->>'crypto_amount')::numeric, crypto_amount),
    amount_in_usd = coalesce((p->>'amount_in_usd')::numeric, amount_in_usd),
    tx_hash = coalesce(p->>'tx_hash', tx_hash), confirmations = coalesce((p->>'confirmations')::int, confirmations),
    rate = (p->>'rate')::numeric, conversion_rate = (p->>'conversion_rate')::numeric,
    is_wrong_asset = is_wrong_asset or coalesce((p->>'is_wrong_asset')::boolean, false),
    settled_trades = case when jsonb_typeof(p->'settled_trades') = 'array' then array(select jsonb_array_elements_text(p->'settled_trades')) else null end,
    balance_remaining = null,
    journal_entry_id = v_entry, last_event_time = coalesce((p->>'event_time')::timestamptz, last_event_time),
    last_event_id = coalesce(p->>'event_id', last_event_id), provider_snapshot = p->'snapshot',
    completed_at = now(), updated_at = now()
  where id = d.id;

  -- Below-minimum deposits that this completion settles as a batch: mark them
  -- completed WITHOUT crediting again (the credit above already covers them).
  if jsonb_typeof(p->'settled_trades') = 'array' then
    for t in select jsonb_array_elements_text(p->'settled_trades') loop
      continue when t = p_trade;
      update knock.crypto_deposits set status = 'completed', sub_status = 'settled_in_batch', credited_currency = v_cur,
        credited_minor = 0, customer_net_minor = 0, journal_entry_id = v_entry, settled_via_deposit_id = d.id,
        balance_remaining = null, completed_at = now(), updated_at = now()
      where provider = p_provider and provider_trade_id = t and status <> 'completed';
    end loop;
  end if;

  -- Separate fee records: provider processing fee and Knock's own fee.
  if p->>'fee_amount_usd' is not null then
    insert into knock.provider_fee_records (provider, subject_kind, subject_id, fee_type, amount, currency, source, detail)
    values (p_provider, 'deposit', d.id, 'deposit_processing', (p->>'fee_amount_usd')::numeric, 'USD', 'provider_reported',
            jsonb_build_object('fee_percentage', p->'fee_percentage')) on conflict do nothing;
  end if;
  if v_fee > 0 then
    insert into knock.provider_fee_records (provider, subject_kind, subject_id, fee_type, amount, currency, source)
    values (p_provider, 'deposit', d.id, 'knock_service_fee', v_fee, v_cur, 'knock_schedule') on conflict do nothing;
  end if;

  -- Auto-settlement: the money is owed to the customer's bank, so move it out
  -- of spendable balance into settlement-reserved until the payout resolves.
  select * into pa from knock.provider_accounts where provider = p_provider;
  v_auto := coalesce(a.auto_settlement, false) or coalesce(pa.business_auto_settlement, false);
  if v_auto and v_net > 0 then
    v_settle_acct := knock.account(d.user_id, null, 'user_settlement_reserved', v_cur);
    perform knock.post_entry('crypto:' || p_provider || ':deposit:' || p_trade || ':settle_reserve', 'settlement_reserve', v_cur,
      jsonb_build_array(jsonb_build_object('account', v_user_acct, 'amount', v_net::text),
                        jsonb_build_object('account', v_settle_acct, 'amount', (-v_net)::text)),
      null, null, 'Reserved for automatic bank settlement');
    insert into knock.settlements (deposit_id, user_id, provider, trade_id, mode, destination, reserved_minor, currency)
    select d.id, d.user_id, p_provider, p_trade, case when a.auto_settlement then 'per_address' else 'business_wide' end,
           case when b.id is not null then jsonb_build_object('bank_name', b.bank_name, 'account_name', b.account_name, 'account', knock.mask_account(b.account_last4))
                else pa.business_settlement_destination end,
           v_net, v_cur
    from (select 1) one left join knock.bank_accounts b on b.id = a.bank_account_id
    on conflict (deposit_id) do nothing;
  end if;

  perform knock.notify(d.user_id, 'crypto_deposit', 'Deposit completed',
    case when v_auto then 'Your deposit has been confirmed. We''re sending the payout to your bank account.'
         else 'Your deposit has been confirmed and your account has been updated.' end,
    null, null, jsonb_build_object('deposit_id', d.id, 'amount_minor', v_net::text, 'currency', v_cur));
  perform knock.audit(null, 'provider', 'crypto.deposit.completed', null, null,
    jsonb_build_object('deposit_id', d.id, 'trade', p_trade, 'credited_minor', v_minor::text, 'knock_fee_minor', v_fee::text, 'event', p->>'event_id'));
  return jsonb_build_object('result', 'credited', 'deposit_id', d.id, 'credited_minor', v_minor::text, 'net_minor', v_net::text,
                            'auto_settlement', v_auto, 'entry_id', v_entry);
end $$;

-- ---------------------------------------------------------------------------
-- Withdrawals (customer)
-- ---------------------------------------------------------------------------

-- Step 1: validate and reserve funds. Called by the backend after it has
-- checked authentication, the customer's transaction PIN/biometric proof,
-- the destination (provider validation) and the provider's current fee.
-- p: {idempotency_key, kind, currency, amount_minor, asset, network, destination_address, fee_level,
--     bank_account_id, narration, quoted_fee, fee_bearer}
create or replace function knock.reserve_withdrawal(p_user uuid, p_provider text, p jsonb) returns jsonb
language plpgsql as $$
declare
  u record; w record; b record; tl record; v_id uuid;
  v_cur text := upper(p->>'currency'); v_amt numeric := (p->>'amount_minor')::numeric;
  v_kind text := p->>'kind'; v_fee numeric; v_reserve uuid; v_entry uuid; v_avail numeric;
begin
  select * into w from knock.provider_withdrawals where idempotency_key = p->>'idempotency_key';
  if found then return jsonb_build_object('result', 'existing', 'withdrawal', to_jsonb(w)); end if;

  select * into u from knock.profiles where id = p_user for update;
  if not found then perform knock.fail('not_found', 'user not found'); end if;
  if u.status <> 'active' then perform knock.fail('account_restricted', 'your account cannot make withdrawals right now'); end if;
  if u.kyc_tier < 1 then perform knock.fail('kyc_required', 'verify your identity to withdraw'); end if;
  if exists (select 1 from knock.risk_flags where user_id = p_user and status = 'open' and severity = 'high') then
    perform knock.fail('account_restricted', 'withdrawals are paused on your account while we complete a review');
  end if;
  if v_amt is null or v_amt <= 0 then perform knock.fail('bad_request', 'amount must be positive'); end if;
  if v_kind not in ('crypto','bank') then perform knock.fail('bad_request', 'kind must be crypto or bank'); end if;

  -- Per-tier single withdrawal limit (NGN-equivalent checks for other
  -- currencies are done by the API layer with the provider's rate).
  select * into tl from knock.tier_limits where kyc_tier = u.kyc_tier;
  if v_cur = 'NGN' and tl.max_single_payment is not null and v_amt > tl.max_single_payment then
    perform knock.fail('limit_exceeded', 'this amount is above your verification tier''s limit');
  end if;

  if v_kind = 'crypto' then
    select * into b from knock.bank_accounts where false;  -- no bank for crypto payouts
    if not exists (select 1 from knock.provider_asset_configurations where provider = p_provider and symbol = upper(p->>'asset')
                   and network = coalesce(upper(p->>'network'), '') and withdraw_enabled) then
      perform knock.fail('asset_unavailable', 'withdrawals for this asset and network are not available right now');
    end if;
  else
    select * into b from knock.bank_accounts where id = (p->>'bank_account_id')::uuid and user_id = p_user and status = 'active';
    if not found or b.verified_at is null then perform knock.fail('bank_required', 'choose a verified bank account'); end if;
    if b.currency <> v_cur then perform knock.fail('bad_request', 'bank account currency does not match'); end if;
    if b.provider_saved_account_id is null then perform knock.fail('bank_not_linked', 'this bank account is not yet linked for payouts'); end if;
  end if;

  v_fee := knock.crypto_fee(case when v_kind = 'crypto' then 'crypto_withdrawal' else 'bank_withdrawal' end, v_cur, v_amt);
  v_avail := knock.balance(knock.account(p_user, null, 'user_available', v_cur));
  if coalesce(v_avail, 0) < v_amt + v_fee then perform knock.fail('insufficient_funds', 'you do not have enough balance for this withdrawal'); end if;

  v_reserve := knock.account(p_user, null, 'user_withdrawal_reserved', v_cur);
  insert into knock.provider_withdrawals (idempotency_key, user_id, provider, kind, purpose, status, currency, amount_minor, knock_fee_minor,
    asset, network, destination_address, fee_level, bank_account_id, provider_bank_id, bank_name, account_name, account_number_masked,
    narration, quoted_fee, fee_bearer, reserve_account_id, created_by)
  values (p->>'idempotency_key', p_user, p_provider, v_kind, 'customer', 'reserved', v_cur, v_amt, v_fee,
    upper(p->>'asset'), nullif(upper(p->>'network'), ''), p->>'destination_address', p->>'fee_level', b.id, b.provider_saved_account_id,
    b.bank_name, b.account_name, case when b.id is not null then knock.mask_account(b.account_last4) end,
    left(p->>'narration', 32), (p->>'quoted_fee')::numeric, p->>'fee_bearer', v_reserve, p_user)
  returning id into v_id;

  v_entry := knock.post_entry('crypto:withdrawal:' || v_id || ':reserve', 'withdrawal_reserve', v_cur,
    jsonb_build_array(jsonb_build_object('account', knock.account(p_user, null, 'user_available', v_cur), 'amount', (v_amt + v_fee)::text),
                      jsonb_build_object('account', v_reserve, 'amount', (-(v_amt + v_fee))::text)),
    null, null, 'Withdrawal reserved', p_user);
  update knock.provider_withdrawals set reserve_entry_id = v_entry where id = v_id;
  perform knock.audit(p_user, 'user', 'crypto.withdrawal.reserved', null, null, jsonb_build_object('withdrawal_id', v_id, 'amount_minor', v_amt::text, 'currency', v_cur));
  return jsonb_build_object('result', 'reserved', 'withdrawal', (select to_jsonb(x) from knock.provider_withdrawals x where id = v_id));
end $$;

-- Step 2: the backend is about to call the provider. Only one caller wins.
create or replace function knock.begin_withdrawal_submission(p_id uuid) returns boolean
language sql as $$
  with u as (update knock.provider_withdrawals set status = 'submitting', submitted_at = now(), updated_at = now()
             where id = p_id and status = 'reserved' returning 1)
  select exists (select 1 from u)
$$;

-- Step 3a: provider accepted. Store its id; status follows webhooks.
create or replace function knock.withdrawal_accepted(p_id uuid, p_provider_id text, p_snapshot jsonb) returns void
language plpgsql as $$
begin
  update knock.provider_withdrawals set provider_withdrawal_id = p_provider_id,
    status = case when status in ('submitting','submission_unknown') then 'pending' else status end,
    provider_snapshot = coalesce(p_snapshot, provider_snapshot), updated_at = now()
  where id = p_id;
  perform knock.audit(null, 'system', 'crypto.withdrawal.accepted', null, null, jsonb_build_object('withdrawal_id', p_id, 'provider_id', p_provider_id));
end $$;

-- Step 3b: outcome unknown (timeout / connection lost). NEVER resubmit:
-- the resolver looks the withdrawal up by externalId in provider records.
create or replace function knock.withdrawal_unknown(p_id uuid, p_error text) returns void
language sql as $$
  update knock.provider_withdrawals set status = 'submission_unknown', last_error_code = p_error, updated_at = now()
  where id = p_id and status = 'submitting'
$$;

-- Release reserved funds back to the customer. Used when the provider
-- refused before accepting (4xx, capacity) or after a VERIFIED reversal or
-- rejection. Idempotent.
create or replace function knock.release_withdrawal(p_id uuid, p_status text, p_reason text, p_code text, p jsonb default '{}')
returns jsonb language plpgsql as $$
declare w knock.provider_withdrawals; v_entry uuid;
begin
  if p_status not in ('not_submitted','capacity_unavailable','reversed','rejected') then
    perform knock.fail('bad_request', 'cannot release into ' || p_status);
  end if;
  select * into w from knock.provider_withdrawals where id = p_id for update;
  if not found then perform knock.fail('not_found', 'withdrawal not found'); end if;
  if w.status = p_status then return jsonb_build_object('result', 'duplicate'); end if;
  if knock.is_terminal_withdrawal(w.status) then return jsonb_build_object('result', 'ignored_terminal', 'status', w.status); end if;
  if p_status in ('not_submitted','capacity_unavailable') and w.status not in ('submitting','reserved','submission_unknown') then
    perform knock.fail('bad_state', 'withdrawal was already accepted by the provider');
  end if;

  if w.purpose = 'customer' then
    v_entry := knock.post_entry('crypto:withdrawal:' || w.id || ':release', 'withdrawal_release', w.currency,
      jsonb_build_array(jsonb_build_object('account', w.reserve_account_id, 'amount', (w.amount_minor + w.knock_fee_minor)::text),
                        jsonb_build_object('account', knock.account(w.user_id, null, 'user_available', w.currency), 'amount', (-(w.amount_minor + w.knock_fee_minor))::text)),
      null, null, 'Withdrawal released: ' || p_status);
  else
    -- Settlement payouts: funds stay in settlement-reserved; the exception reopens.
    update knock.settlements set status = 'failed_to_start', updated_at = now() where id = (select settlement_id from knock.settlement_exceptions where id = w.settlement_exception_id);
    update knock.settlement_exceptions set status = 'open', updated_at = now(),
      notes = notes || jsonb_build_array(jsonb_build_object('at', now(), 'note', 'Replacement payout ' || p_status || ': ' || coalesce(p_reason, '')))
    where id = w.settlement_exception_id;
    update knock.settlements set status = 'failed_to_start', updated_at = now() where withdrawal_id = w.id and w.purpose = 'auto_settlement';
  end if;

  update knock.provider_withdrawals set status = p_status, reason = coalesce(p_reason, reason), last_error_code = coalesce(p_code, last_error_code),
    final_entry_id = coalesce(v_entry, final_entry_id), provider_snapshot = coalesce(p->'snapshot', provider_snapshot),
    last_event_time = coalesce((p->>'event_time')::timestamptz, last_event_time), last_event_id = coalesce(p->>'event_id', last_event_id),
    completed_at = now(), updated_at = now()
  where id = w.id;

  if w.purpose = 'customer' then
    perform knock.notify(w.user_id, 'withdrawal',
      case p_status when 'capacity_unavailable' then 'Payout temporarily unavailable' when 'not_submitted' then 'Withdrawal not sent'
                    when 'reversed' then 'Withdrawal reversed' else 'Withdrawal rejected' end,
      case p_status
        when 'capacity_unavailable' then 'We''re temporarily unable to process a payout of this size for this asset. Try a smaller amount or try again later. Your funds have not been debited.'
        when 'not_submitted' then 'We could not send this withdrawal. Your funds have not been debited.'
        when 'reversed' then 'Your withdrawal could not be completed by the receiving side. The amount has been returned to your Knock balance.'
        else 'Your withdrawal was not approved. The amount has been returned to your Knock balance.' end,
      null, null, jsonb_build_object('withdrawal_id', w.id));
  end if;
  perform knock.audit(null, 'system', 'crypto.withdrawal.' || p_status, null, null, jsonb_build_object('withdrawal_id', w.id, 'reason', p_reason));
  return jsonb_build_object('result', 'released', 'status', p_status);
end $$;

-- Apply a VERIFIED provider withdrawal status (pending/processing/completed).
-- Reversed/rejected go through release_withdrawal. Settlement payouts that
-- Knock did not initiate (auto-settlement) are created here on first sight.
-- p: {event_time, event_id, amount, original_amount, payout_amount, currency, fee, fee_bearer, tx_hash,
--     reference, external_id, trade, crypto_amount, fee_crypto, meta, reason, snapshot}
create or replace function knock.apply_withdrawal_status(p_provider text, p_provider_id text, p_status text, p jsonb)
returns jsonb language plpgsql as $$
declare
  w knock.provider_withdrawals; s knock.settlements; v_dec text; v_entry uuid; v_debit numeric; v_fee_minor numeric := 0;
  v_cur text; v_wallet uuid;
begin
  if p_status not in ('pending','processing','completed') then perform knock.fail('bad_request', 'use release_withdrawal for ' || p_status); end if;

  select * into w from knock.provider_withdrawals
  where provider = p_provider and (provider_withdrawal_id = p_provider_id or knock_reference = p->>'external_id')
  order by (provider_withdrawal_id = p_provider_id) desc limit 1 for update;

  if not found then
    -- Auto-settlement payout: linked to a trade Knock credited.
    select * into s from knock.settlements where provider = p_provider and trade_id = p->>'trade' for update;
    if not found then perform knock.fail('unknown_withdrawal', format('withdrawal %s is not known to Knock', p_provider_id)); end if;
    insert into knock.provider_withdrawals (user_id, provider, provider_withdrawal_id, kind, purpose, status, currency, amount_minor,
      trade_id, deposit_id, reserve_account_id, provider_bank_id, bank_name, account_name, account_number_masked, meta)
    values (s.user_id, p_provider, p_provider_id, 'bank', 'auto_settlement', 'pending', s.currency, s.reserved_minor,
      s.trade_id, s.deposit_id, knock.account(s.user_id, null, 'user_settlement_reserved', s.currency),
      coalesce(p->'meta'->>'bankId', 'auto'), p->'meta'->>'bankName', p->'meta'->>'accountName',
      case when p->'meta'->>'accountNumber' is not null then knock.mask_account(right(p->'meta'->>'accountNumber', 4)) end, p->'meta')
    returning * into w;
    update knock.settlements set withdrawal_id = w.id, status = 'processing', updated_at = now() where id = s.id;
  end if;

  v_dec := knock.order_check(knock.withdrawal_rank(w.status), knock.withdrawal_rank(p_status), w.status, p_status,
                             w.last_event_time, (p->>'event_time')::timestamptz);
  if v_dec <> 'apply' then return jsonb_build_object('result', v_dec, 'withdrawal_id', w.id, 'status', w.status); end if;

  update knock.provider_withdrawals set
    status = p_status, provider_withdrawal_id = coalesce(provider_withdrawal_id, p_provider_id),
    provider_amount = coalesce((p->>'amount')::numeric, provider_amount),
    original_amount = coalesce((p->>'original_amount')::numeric, original_amount),
    payout_amount = coalesce((p->>'payout_amount')::numeric, payout_amount),
    provider_fee = coalesce((p->>'fee')::numeric, provider_fee),
    fee_bearer = coalesce(p->>'fee_bearer', fee_bearer),
    crypto_amount = coalesce((p->>'crypto_amount')::numeric, crypto_amount),
    fee_crypto = coalesce((p->>'fee_crypto')::numeric, fee_crypto),
    tx_hash = coalesce(p->>'tx_hash', tx_hash), explorer_url = coalesce(p->'meta'->>'txLink', explorer_url),
    trade_id = coalesce(p->>'trade', trade_id), meta = coalesce(meta, '{}'::jsonb) || coalesce(p->'meta', '{}'::jsonb),
    provider_snapshot = coalesce(p->'snapshot', provider_snapshot),
    last_event_time = coalesce((p->>'event_time')::timestamptz, last_event_time), last_event_id = coalesce(p->>'event_id', last_event_id),
    updated_at = now()
  where id = w.id returning * into w;

  if p_status = 'completed' then
    v_cur := w.currency;
    v_wallet := knock.provider_account(p_provider, 'provider_wallet', v_cur);
    if w.purpose = 'customer' then
      -- Provider debits the requested amount; if the business bears the
      -- provider fee, that fee is also debited and is Knock's expense.
      if coalesce(w.fee_bearer, 'user') = 'business' and w.provider_fee is not null then
        v_fee_minor := knock.to_minor(w.provider_fee, v_cur);
      end if;
      v_debit := w.amount_minor + v_fee_minor;
      v_entry := knock.post_entry('crypto:withdrawal:' || w.id || ':complete', 'withdrawal_complete', v_cur,
        jsonb_build_array(
          jsonb_build_object('account', w.reserve_account_id, 'amount', (w.amount_minor + w.knock_fee_minor)::text),
          jsonb_build_object('account', v_wallet, 'amount', (-v_debit)::text),
          jsonb_build_object('account', knock.account(null, null, 'fee_revenue', v_cur), 'amount', (-w.knock_fee_minor)::text),
          jsonb_build_object('account', knock.provider_account(p_provider, 'provider_fee_expense', v_cur), 'amount', v_fee_minor::text)),
        null, null, 'Withdrawal completed ' || w.knock_reference);
      if w.knock_fee_minor > 0 then
        insert into knock.provider_fee_records (provider, subject_kind, subject_id, fee_type, amount, currency, source)
        values (p_provider, 'withdrawal', w.id, 'knock_service_fee', w.knock_fee_minor, v_cur, 'knock_schedule') on conflict do nothing;
      end if;
      perform knock.notify(w.user_id, 'withdrawal', 'Withdrawal completed', 'Your withdrawal has been completed.', null, null, jsonb_build_object('withdrawal_id', w.id));
    else
      -- Settlement payout (automatic or replacement). Close the reserved
      -- amount; any gap to what the provider debited goes to variance for review.
      select * into s from knock.settlements where deposit_id = w.deposit_id for update;
      if s.currency <> upper(coalesce(p->>'currency', s.currency)) then
        update knock.settlements set status = 'needs_review', updated_at = now() where id = s.id;
        return jsonb_build_object('result', 'needs_review', 'reason', 'settlement currency differs from credited currency');
      end if;
      v_debit := coalesce(knock.to_minor((p->>'amount')::numeric, s.currency), s.reserved_minor);
      v_entry := knock.post_entry('crypto:settlement:' || s.id || ':complete', 'settlement_complete', s.currency,
        jsonb_build_array(
          jsonb_build_object('account', w.reserve_account_id, 'amount', s.reserved_minor::text),
          jsonb_build_object('account', v_wallet, 'amount', (-v_debit)::text),
          jsonb_build_object('account', knock.provider_account(p_provider, 'settlement_variance', s.currency), 'amount', (v_debit - s.reserved_minor)::text)),
        null, null, 'Settlement completed for trade ' || s.trade_id);
      update knock.settlements set status = case when w.purpose = 'settlement_replacement' then 'replaced' else 'completed' end,
        amount_settled = coalesce((p->>'payout_amount')::numeric, (p->>'amount_settled')::numeric, amount_settled),
        settled_currency = s.currency, withdrawal_id = w.id, final_entry_id = v_entry, updated_at = now()
      where id = s.id;
      if w.settlement_exception_id is not null then
        update knock.settlement_exceptions set status = 'resolved', resolution = 'replacement_payout', resolved_at = now(), updated_at = now()
        where id = w.settlement_exception_id;
      end if;
      if p->>'fee' is not null then
        insert into knock.provider_fee_records (provider, subject_kind, subject_id, fee_type, amount, currency, source)
        values (p_provider, 'settlement', s.id, 'provider_withdrawal_fee', (p->>'fee')::numeric, s.currency, 'provider_reported') on conflict do nothing;
      end if;
      perform knock.notify(w.user_id, 'settlement', 'Bank payout completed', 'The payout from your crypto deposit has been sent to your bank account.', null, null, jsonb_build_object('withdrawal_id', w.id));
    end if;
    update knock.provider_withdrawals set final_entry_id = v_entry, completed_at = now() where id = w.id;
  elsif p_status = 'processing' and w.purpose = 'customer' then
    perform knock.notify(w.user_id, 'withdrawal', 'Withdrawal processing', 'Your withdrawal is being processed.', null, null, jsonb_build_object('withdrawal_id', w.id));
  end if;
  perform knock.audit(null, 'provider', 'crypto.withdrawal.' || p_status, null, null, jsonb_build_object('withdrawal_id', w.id, 'event', p->>'event_id'));
  return jsonb_build_object('result', 'applied', 'withdrawal_id', w.id, 'status', p_status, 'entry_id', v_entry);
end $$;

-- Find a Knock withdrawal for a provider event (for reversed/rejected).
create or replace function knock.find_withdrawal(p_provider text, p_provider_id text, p_external text, p_trade text) returns uuid
language sql stable as $$
  select coalesce(
    (select id from knock.provider_withdrawals where provider = p_provider and provider_withdrawal_id = p_provider_id),
    (select id from knock.provider_withdrawals where provider = p_provider and knock_reference = p_external),
    (select withdrawal_id from knock.settlements where provider = p_provider and trade_id = p_trade))
$$;

-- ---------------------------------------------------------------------------
-- Settlement failure and recovery
-- ---------------------------------------------------------------------------

-- trade.settlement.failed: the deposit stays completed and credited (into
-- settlement-reserved); the payout did not start. Open an exception.
create or replace function knock.settlement_failed(p_provider text, p_trade text, p_event text, p jsonb) returns jsonb
language plpgsql as $$
declare d record; s knock.settlements; v_id uuid;
begin
  select * into d from knock.crypto_deposits where provider = p_provider and provider_trade_id = p_trade;
  if not found or d.status <> 'completed' then
    -- trade.completed has not been applied yet (out of order): retry later.
    perform knock.fail('not_ready', 'deposit for this trade is not completed in Knock yet');
  end if;
  select * into s from knock.settlements where deposit_id = d.id for update;
  if not found then
    -- Breet tried to settle a deposit Knock did not mark for auto-settlement
    -- (e.g. business-wide setting not mirrored). Reserve now so the same
    -- money is never both spendable and owed to the bank.
    perform knock.post_entry('crypto:' || p_provider || ':deposit:' || p_trade || ':settle_reserve', 'settlement_reserve', d.credited_currency,
      jsonb_build_array(jsonb_build_object('account', knock.account(d.user_id, null, 'user_available', d.credited_currency), 'amount', d.customer_net_minor::text),
                        jsonb_build_object('account', knock.account(d.user_id, null, 'user_settlement_reserved', d.credited_currency), 'amount', (-d.customer_net_minor)::text)),
      null, null, 'Reserved after provider settlement attempt');
    insert into knock.settlements (deposit_id, user_id, provider, trade_id, mode, reserved_minor, currency)
    values (d.id, d.user_id, p_provider, p_trade, 'business_wide', d.customer_net_minor, d.credited_currency) returning * into s;
  end if;
  if s.status in ('completed','replaced','released_to_wallet') then
    return jsonb_build_object('result', 'ignored_terminal', 'settlement_status', s.status);
  end if;
  update knock.settlements set status = 'failed_to_start', updated_at = now() where id = s.id;
  insert into knock.settlement_exceptions (settlement_id, deposit_id, provider, trade_id, event_id, amount, currency, reason)
  values (s.id, d.id, p_provider, p_trade, p_event, (p->>'amount')::numeric, upper(p->>'currency'), p->>'reason')
  on conflict (event_id) do nothing returning id into v_id;
  if v_id is null then return jsonb_build_object('result', 'duplicate'); end if;
  perform knock.notify(d.user_id, 'settlement', 'Bank payout delayed',
    'Your deposit was received, but the bank payout could not be initiated. Our team is working to complete the settlement.',
    null, null, jsonb_build_object('deposit_id', d.id));
  perform knock.audit(null, 'provider', 'crypto.settlement.failed', null, null, jsonb_build_object('exception_id', v_id, 'trade', p_trade, 'reason', p->>'reason'));
  return jsonb_build_object('result', 'exception_opened', 'exception_id', v_id);
end $$;

create or replace function knock.require_staff(p_user uuid, p_roles text[]) returns void language plpgsql as $$
begin
  if not knock.is_staff(p_user, p_roles || array['super_admin']) then
    perform knock.fail('forbidden', 'you do not have permission for this action');
  end if;
end $$;

-- Staff request a recovery action. Above the threshold it needs a second
-- Finance Manager; below it, the requester's approval is enough.
-- p_action: settlement_replacement | settlement_release
create or replace function knock.request_settlement_recovery(p_exception uuid, p_actor uuid, p_action text, p_note text)
returns jsonb language plpgsql as $$
declare e record; s record; v_th numeric; v_req uuid; v_dual boolean;
begin
  perform knock.require_staff(p_actor, array['finance_manager']);
  if p_action not in ('settlement_replacement','settlement_release') then perform knock.fail('bad_request', 'unknown action'); end if;
  select * into e from knock.settlement_exceptions where id = p_exception for update;
  if not found then perform knock.fail('not_found', 'exception not found'); end if;
  if e.status = 'resolved' then perform knock.fail('bad_state', 'exception already resolved'); end if;
  select * into s from knock.settlements where id = e.settlement_id;
  select dual_approval_above into v_th from knock.approval_thresholds where action = p_action and currency = s.currency;
  v_dual := v_th is null or s.reserved_minor > v_th;
  insert into knock.staff_action_requests (action, subject_id, payload, amount_minor, currency, requested_by)
  values (p_action, p_exception, jsonb_build_object('note', p_note, 'dual', v_dual), s.reserved_minor, s.currency, p_actor)
  returning id into v_req;
  update knock.settlement_exceptions set status = 'investigating', assigned_to = coalesce(assigned_to, p_actor), updated_at = now(),
    notes = notes || jsonb_build_array(jsonb_build_object('at', now(), 'by', p_actor, 'note', p_action || ' requested: ' || coalesce(p_note, '')))
  where id = p_exception;
  perform knock.audit(p_actor, 'staff', 'settlement.recovery.requested', null, null, jsonb_build_object('request_id', v_req, 'action', p_action, 'dual', v_dual));
  return jsonb_build_object('request_id', v_req, 'needs_second_approver', v_dual);
end $$;

-- Approve a pending request (second Finance Manager when dual is needed).
-- Returns what the API must do next.
create or replace function knock.approve_staff_action(p_request uuid, p_actor uuid) returns jsonb
language plpgsql as $$
declare r record;
begin
  perform knock.require_staff(p_actor, array['finance_manager']);
  select * into r from knock.staff_action_requests where id = p_request for update;
  if not found or r.status <> 'pending' then perform knock.fail('bad_state', 'request is not pending'); end if;
  if (r.payload->>'dual')::boolean and r.requested_by = p_actor then
    perform knock.fail('second_approver_required', 'a different finance manager must approve this action');
  end if;
  update knock.staff_action_requests set status = 'approved', approved_by = case when r.requested_by = p_actor then null else p_actor end, decided_at = now()
  where id = p_request;
  perform knock.audit(p_actor, 'staff', 'staff_action.approved', null, null, jsonb_build_object('request_id', p_request));
  return jsonb_build_object('action', r.action, 'subject_id', r.subject_id);
end $$;

-- Release a failed settlement to the customer's spendable balance.
create or replace function knock.execute_settlement_release(p_request uuid, p_actor uuid) returns jsonb
language plpgsql as $$
declare r record; e record; s record;
begin
  select * into r from knock.staff_action_requests where id = p_request and action = 'settlement_release' for update;
  if not found or r.status <> 'approved' then perform knock.fail('bad_state', 'request is not approved'); end if;
  select * into e from knock.settlement_exceptions where id = r.subject_id for update;
  select * into s from knock.settlements where id = e.settlement_id for update;
  if s.status <> 'failed_to_start' then perform knock.fail('bad_state', 'settlement is ' || s.status); end if;
  if exists (select 1 from knock.provider_withdrawals where settlement_exception_id = e.id
             and status not in ('not_submitted','capacity_unavailable','reversed','rejected')) then
    perform knock.fail('bad_state', 'a replacement payout is in progress');
  end if;
  perform knock.post_entry('crypto:settlement:' || s.id || ':release', 'settlement_release', s.currency,
    jsonb_build_array(jsonb_build_object('account', knock.account(s.user_id, null, 'user_settlement_reserved', s.currency), 'amount', s.reserved_minor::text),
                      jsonb_build_object('account', knock.account(s.user_id, null, 'user_available', s.currency), 'amount', (-s.reserved_minor)::text)),
    null, null, 'Failed settlement released to wallet', p_actor);
  update knock.settlements set status = 'released_to_wallet', updated_at = now() where id = s.id;
  update knock.settlement_exceptions set status = 'resolved', resolution = 'released_to_wallet', resolved_at = now(), updated_at = now() where id = e.id;
  update knock.staff_action_requests set status = 'executed', result = jsonb_build_object('ok', true) where id = p_request;
  perform knock.notify(s.user_id, 'settlement', 'Payout added to your balance', 'We could not pay this deposit to your bank, so the amount has been added to your Knock balance.', null, null, jsonb_build_object('deposit_id', s.deposit_id));
  perform knock.audit(p_actor, 'staff', 'settlement.released_to_wallet', null, null, jsonb_build_object('exception_id', e.id, 'request_id', p_request));
  return jsonb_build_object('result', 'released');
end $$;

-- Create the replacement bank payout (funds are already in settlement-
-- reserved, so no new reservation). The API then submits it to the provider
-- after checking the provider trade and balance.
create or replace function knock.create_settlement_replacement(p_request uuid, p_actor uuid, p_bank uuid) returns jsonb
language plpgsql as $$
declare r record; e record; s record; b record; v_id uuid;
begin
  select * into r from knock.staff_action_requests where id = p_request and action = 'settlement_replacement' for update;
  if not found or r.status <> 'approved' then perform knock.fail('bad_state', 'request is not approved'); end if;
  select * into e from knock.settlement_exceptions where id = r.subject_id for update;
  select * into s from knock.settlements where id = e.settlement_id for update;
  if s.status <> 'failed_to_start' then perform knock.fail('bad_state', 'settlement is ' || s.status); end if;
  select * into b from knock.bank_accounts where id = p_bank and user_id = s.user_id and status = 'active' and verified_at is not null;
  if not found or b.provider_saved_account_id is null then perform knock.fail('bank_required', 'customer bank account is not verified and linked'); end if;
  if b.currency <> s.currency then perform knock.fail('bad_request', 'bank currency does not match settlement'); end if;
  insert into knock.provider_withdrawals (idempotency_key, user_id, provider, kind, purpose, status, currency, amount_minor,
    bank_account_id, provider_bank_id, bank_name, account_name, account_number_masked, trade_id, deposit_id, settlement_exception_id,
    reserve_account_id, created_by, approved_by, narration)
  values ('settlement-replacement:' || p_request, s.user_id, s.provider, 'bank', 'settlement_replacement', 'reserved', s.currency, s.reserved_minor,
    b.id, b.provider_saved_account_id, b.bank_name, b.account_name, knock.mask_account(b.account_last4), s.trade_id, s.deposit_id, e.id,
    knock.account(s.user_id, null, 'user_settlement_reserved', s.currency), r.requested_by, coalesce(r.approved_by, p_actor), 'Knock settlement')
  returning id into v_id;
  update knock.settlement_exceptions set replacement_withdrawal_id = v_id, status = 'awaiting_provider', updated_at = now() where id = e.id;
  update knock.staff_action_requests set status = 'executed', result = jsonb_build_object('withdrawal_id', v_id) where id = p_request;
  perform knock.audit(p_actor, 'staff', 'settlement.replacement.created', null, null, jsonb_build_object('exception_id', e.id, 'withdrawal_id', v_id));
  return jsonb_build_object('withdrawal_id', v_id);
end $$;

-- ---------------------------------------------------------------------------
-- Customer-facing status (never shows provider wording or ids)
-- ---------------------------------------------------------------------------

create or replace view knock.customer_crypto_activity as
select d.id, d.user_id, 'deposit'::text as kind, d.knock_reference as reference, d.symbol as asset, d.network,
       d.crypto_amount, d.credited_currency as currency, d.customer_net_minor as amount_minor, d.confirmations, d.required_confirmations,
       case d.status
         when 'pending' then case when coalesce(d.confirmations,0) = 0 then 'Deposit Detected' else 'Confirming on Blockchain' end
         when 'below_minimum' then 'Awaiting Top-up'
         when 'flagged' then 'Deposit Under Review'
         when 'under_review' then 'Deposit Under Review'
         when 'completed' then case when s.status = 'failed_to_start' then 'Bank Payout Delayed' else 'Deposit Completed' end
         else 'Deposit Failed' end as customer_status,
       d.created_at, d.updated_at
from knock.crypto_deposits d left join knock.settlements s on s.deposit_id = d.id
union all
select w.id, w.user_id, 'withdrawal', w.knock_reference, w.asset, w.network, w.crypto_amount, w.currency, w.amount_minor, null, null,
       case w.status
         when 'reserved' then 'Withdrawal Submitted' when 'submitting' then 'Withdrawal Submitted'
         when 'submission_unknown' then 'Withdrawal Submitted' when 'pending' then 'Withdrawal Submitted'
         when 'processing' then 'Withdrawal Processing' when 'completed' then 'Withdrawal Completed'
         when 'reversed' then 'Withdrawal Reversed' when 'rejected' then 'Withdrawal Rejected'
         when 'capacity_unavailable' then 'Payout Temporarily Unavailable' else 'Withdrawal Not Sent' end,
       w.created_at, w.updated_at
from knock.provider_withdrawals w where w.purpose = 'customer';

-- ---------------------------------------------------------------------------
-- RLS: clients never write these tables; customers read only their own rows.
-- ---------------------------------------------------------------------------
do $$
declare t text;
begin
  foreach t in array array['provider_accounts','provider_asset_configurations','crypto_fee_schedule','approval_thresholds','bank_accounts',
    'provider_wallet_addresses','crypto_deposits','provider_withdrawals','settlements','settlement_exceptions','provider_fee_records',
    'provider_api_logs','provider_rate_limits','provider_event_processing_logs','provider_reconciliation_runs',
    'provider_reconciliation_records','staff_action_requests'] loop
    execute format('alter table knock.%I enable row level security', t);
    execute format('revoke all on knock.%I from public', t);
  end loop;
  if exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'auth' and p.proname = 'uid') then
    execute $p$create policy own_addresses on knock.provider_wallet_addresses for select using (user_id = auth.uid())$p$;
    execute $p$create policy own_deposits on knock.crypto_deposits for select using (user_id = auth.uid())$p$;
    execute $p$create policy own_withdrawals on knock.provider_withdrawals for select using (user_id = auth.uid() and purpose = 'customer')$p$;
    execute $p$create policy own_banks on knock.bank_accounts for select using (user_id = auth.uid())$p$;
    execute $p$create policy read_assets on knock.provider_asset_configurations for select using (true)$p$;
  end if;
end $$;
