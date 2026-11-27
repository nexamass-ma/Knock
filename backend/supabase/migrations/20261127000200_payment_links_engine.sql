-- KNOCK Payment Links: split engine and money movement.
-- Every function here runs inside the caller's transaction. The API layer
-- calls one function per request, so each request is atomic.
set search_path = knock, public;

create or replace function knock.fail(p_code text, p_msg text) returns void
language plpgsql as $$
begin
  -- Error text is "code: message" so the API can map it to a 4xx response.
  raise exception '%: %', p_code, p_msg using errcode = 'P0001';
end $$;

create or replace function knock.is_staff(p_user uuid, p_roles text[]) returns boolean
language sql stable as $$
  select exists (select 1 from knock.staff_roles where user_id = p_user and role = any(p_roles))
$$;

-- Public recipient lookup: exact username match, minimum profile fields only.
create or replace function knock.lookup_username(p_username text)
returns table (id uuid, username text, display_name text, avatar_url text, verified boolean)
language sql stable as $$
  select id, username, display_name, avatar_url, kyc_tier >= 1
  from knock.profiles
  where lower(username) = lower(ltrim(p_username, '@')) and status = 'active'
$$;

-- ---------------------------------------------------------------------------
-- Recipient rules
-- ---------------------------------------------------------------------------

-- Validates and normalises recipients into
-- [{recipient_id, allocated_amount, basis_points, is_creator_remainder}].
--  fixed:      allocated_amount per recipient; must sum to the target
--              (or less, with remainder_to_creator). Basis points derived.
--  percentage: basis_points per recipient; must sum to 10,000 (or less, with
--              remainder_to_creator). Amounts derived from the target if any.
create or replace function knock.build_recipients(
  p_creator uuid, p_method text, p_target numeric, p_alloc_mode text, p_recipients jsonb, p_max int)
returns jsonb language plpgsql as $$
declare
  r jsonb;
  ids uuid[] := '{}';
  amts numeric[] := '{}';
  bps numeric[] := '{}';
  v_prof knock.profiles;
  v_sum numeric := 0;
  v_creator_idx int;
  i int;
  derived numeric[];
  out jsonb := '[]';
  n int;
begin
  n := coalesce(jsonb_array_length(p_recipients), 0);
  if n = 0 then perform knock.fail('invalid_recipients', 'add at least one recipient'); end if;
  if n > p_max then perform knock.fail('limit_exceeded', format('your verification tier allows up to %s recipients', p_max)); end if;

  for r in select * from jsonb_array_elements(p_recipients) loop
    select * into v_prof from knock.profiles where id = (r->>'recipient_id')::uuid;
    if not found then perform knock.fail('recipient_not_found', 'a recipient does not exist'); end if;
    if v_prof.status <> 'active' then perform knock.fail('recipient_unavailable', '@' || v_prof.username || ' cannot receive payments right now'); end if;
    if v_prof.kyc_tier < 1 then perform knock.fail('recipient_unverified', '@' || v_prof.username || ' must verify their account first'); end if;
    if v_prof.id = any(ids) then perform knock.fail('invalid_recipients', '@' || v_prof.username || ' is listed twice'); end if;
    ids := ids || v_prof.id;
    if p_method = 'fixed' then
      if coalesce((r->>'allocated_amount')::numeric, 0) <= 0 then
        perform knock.fail('invalid_recipients', 'each recipient needs an amount above zero');
      end if;
      amts := amts || (r->>'allocated_amount')::numeric;
      v_sum := v_sum + (r->>'allocated_amount')::numeric;
    else
      if coalesce((r->>'basis_points')::int, 0) <= 0 then
        perform knock.fail('invalid_recipients', 'each recipient needs a percentage above zero');
      end if;
      bps := bps || (r->>'basis_points')::numeric;
      v_sum := v_sum + (r->>'basis_points')::numeric;
    end if;
  end loop;

  if p_method = 'fixed' then
    if p_target is null then perform knock.fail('invalid_target', 'a fixed split needs a total amount'); end if;
    if v_sum > p_target then
      perform knock.fail('allocation_mismatch', format('allocations (%s) exceed the total (%s)', v_sum, p_target));
    elsif v_sum < p_target then
      if p_alloc_mode <> 'remainder_to_creator' then
        perform knock.fail('allocation_mismatch', format('allocations (%s) must add up to the total (%s)', v_sum, p_target));
      end if;
      v_creator_idx := array_position(ids, p_creator);
      if v_creator_idx is null then
        ids := ids || p_creator; amts := amts || (p_target - v_sum); v_creator_idx := array_length(ids, 1);
      else
        amts[v_creator_idx] := amts[v_creator_idx] + (p_target - v_sum);
      end if;
    end if;
    derived := knock.split_amount(10000, amts);
    for i in 1..array_length(ids, 1) loop
      out := out || jsonb_build_object('recipient_id', ids[i], 'allocated_amount', amts[i], 'basis_points', derived[i],
                                       'is_creator_remainder', i = v_creator_idx);
    end loop;
  else
    if v_sum > 10000 then
      perform knock.fail('allocation_mismatch', 'percentages add up to more than 100%');
    elsif v_sum < 10000 then
      if p_alloc_mode <> 'remainder_to_creator' then
        perform knock.fail('allocation_mismatch', 'percentages must add up to 100%');
      end if;
      v_creator_idx := array_position(ids, p_creator);
      if v_creator_idx is null then
        ids := ids || p_creator; bps := bps || (10000 - v_sum); v_creator_idx := array_length(ids, 1);
      else
        bps[v_creator_idx] := bps[v_creator_idx] + (10000 - v_sum);
      end if;
    end if;
    if p_target is not null then derived := knock.split_amount(p_target, bps); end if;
    for i in 1..array_length(ids, 1) loop
      out := out || jsonb_build_object('recipient_id', ids[i],
                                       'allocated_amount', coalesce(derived[i], 0), 'basis_points', bps[i],
                                       'is_creator_remainder', i = v_creator_idx);
    end loop;
  end if;
  return out;
end $$;

create or replace function knock.insert_recipients(p_link uuid, p_version int, p_rows jsonb) returns void
language plpgsql as $$
declare r jsonb; pos int := 0;
begin
  for r in select * from jsonb_array_elements(p_rows) loop
    pos := pos + 1;
    insert into knock.split_recipients (link_id, rule_version, position, recipient_id, allocated_amount, basis_points, is_creator_remainder)
    values (p_link, p_version, pos, (r->>'recipient_id')::uuid, (r->>'allocated_amount')::numeric,
            (r->>'basis_points')::int, coalesce((r->>'is_creator_remainder')::boolean, false));
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- Create and manage links
-- ---------------------------------------------------------------------------

create or replace function knock.create_payment_link(p_creator uuid, p jsonb) returns jsonb
language plpgsql as $$
declare
  v_creator knock.profiles;
  v_limits knock.tier_limits;
  v_asset knock.assets;
  v_type text := p->>'link_type';
  v_method text;
  v_target numeric := nullif(p->>'target_amount', '')::numeric;
  v_fixed numeric := nullif(p->>'fixed_amount', '')::numeric;
  v_rows jsonb;
  v_link knock.payment_links;
begin
  select * into v_creator from knock.profiles where id = p_creator;
  if not found or v_creator.status <> 'active' then perform knock.fail('forbidden', 'account cannot create payment links'); end if;
  select * into v_limits from knock.tier_limits where kyc_tier = v_creator.kyc_tier;
  if v_creator.kyc_tier < 1 then perform knock.fail('kyc_required', 'verify your account to create payment links'); end if;

  select * into v_asset from knock.assets where code = p->>'currency' and network = coalesce(p->>'network', 'fiat');
  if not found or not v_asset.enabled then perform knock.fail('unsupported_asset', 'that currency or network is not supported'); end if;
  if v_type = 'naira' and v_asset.kind <> 'fiat' then perform knock.fail('invalid_link', 'a Naira link must use NGN'); end if;
  if v_type = 'crypto' and v_asset.kind <> 'crypto' then perform knock.fail('invalid_link', 'a crypto link needs a supported coin and network'); end if;

  if p->>'amount_mode' = 'fixed' and v_fixed is null then perform knock.fail('invalid_amount', 'enter the amount each payer pays'); end if;
  if v_asset.code = 'NGN' then
    if v_target > v_limits.max_link_target then perform knock.fail('limit_exceeded', 'the total is above your tier limit'); end if;
    if v_fixed > v_limits.max_single_payment then perform knock.fail('limit_exceeded', 'the amount is above your per-payment limit'); end if;
  end if;
  if (p->>'expires_at') is not null and (p->>'expires_at')::timestamptz <= now() then
    perform knock.fail('invalid_expiry', 'the expiry must be in the future');
  end if;
  if coalesce(p->>'settlement_mode', 'each_payment') = 'on_target' and v_target is null then
    perform knock.fail('invalid_settlement', 'collect-then-distribute needs a total target');
  end if;

  if v_type = 'split' then
    v_method := p->>'split_method';
    v_rows := knock.build_recipients(p_creator, v_method, v_target, coalesce(p->>'allocation_mode', 'exact'),
                                     p->'recipients', v_limits.max_recipients);
  else
    -- Single-recipient links use the same engine: 100% to the creator.
    v_method := 'percentage';
    v_rows := jsonb_build_array(jsonb_build_object('recipient_id', p_creator,
                'allocated_amount', coalesce(v_target, 0), 'basis_points', 10000, 'is_creator_remainder', false));
  end if;

  insert into knock.payment_links (reference, slug, creator_id, link_type, title, description, currency, network,
    amount_mode, fixed_amount, min_amount, max_amount, target_amount, split_method, allocation_mode, settlement_mode,
    fee_bearer, expires_at, require_customer_reference, invoice_number, payment_instructions)
  values (knock.new_ref('KPL'), knock.new_slug(), p_creator, v_type, p->>'title', p->>'description', v_asset.code, v_asset.network,
    p->>'amount_mode', v_fixed, nullif(p->>'min_amount', '')::numeric, nullif(p->>'max_amount', '')::numeric, v_target,
    v_method, coalesce(p->>'allocation_mode', 'exact'), coalesce(p->>'settlement_mode', 'each_payment'),
    coalesce(p->>'fee_bearer', 'deduct'), (p->>'expires_at')::timestamptz,
    coalesce((p->>'require_customer_reference')::boolean, false), p->>'invoice_number', p->>'payment_instructions')
  returning * into v_link;

  perform knock.insert_recipients(v_link.id, 1, v_rows);
  perform knock.audit(p_creator, 'user', 'link.created', v_link.id, null, p - 'recipients' || jsonb_build_object('recipients', v_rows));
  perform knock.notify(p_creator, 'link_created', 'Payment link created',
    format('"%s" (%s) is live and ready to share.', v_link.title, v_link.reference), v_link.id, null);
  return jsonb_build_object('id', v_link.id, 'reference', v_link.reference, 'slug', v_link.slug);
end $$;

create or replace function knock.update_link_details(p_link uuid, p_actor uuid, p jsonb) returns void
language plpgsql as $$
declare v_link knock.payment_links;
begin
  select * into v_link from knock.payment_links where id = p_link for update;
  if not found then perform knock.fail('not_found', 'link not found'); end if;
  if v_link.creator_id <> p_actor then perform knock.fail('forbidden', 'only the creator can edit this link'); end if;
  if (p->>'expires_at') is not null and (p->>'expires_at')::timestamptz <= now() then
    perform knock.fail('invalid_expiry', 'the expiry must be in the future');
  end if;
  update knock.payment_links set
    title = coalesce(p->>'title', title),
    description = case when p ? 'description' then p->>'description' else description end,
    payment_instructions = case when p ? 'payment_instructions' then p->>'payment_instructions' else payment_instructions end,
    invoice_number = case when p ? 'invoice_number' then p->>'invoice_number' else invoice_number end,
    expires_at = case when p ? 'expires_at' then (p->>'expires_at')::timestamptz else expires_at end,
    status = case when status = 'expired' and p ? 'expires_at' and (p->>'expires_at') is not null then 'active' else status end
  where id = p_link;
  perform knock.audit(p_actor, 'user', 'link.updated', p_link, null, p);
end $$;

-- pause | resume | close (creator); review | clear_review (compliance/admin)
create or replace function knock.set_link_status(p_link uuid, p_actor uuid, p_action text, p_note text default null)
returns text language plpgsql as $$
declare v_link knock.payment_links; v_new text; v_pay uuid;
begin
  select * into v_link from knock.payment_links where id = p_link for update;
  if not found then perform knock.fail('not_found', 'link not found'); end if;
  if p_action in ('pause','resume','close') and v_link.creator_id <> p_actor and not knock.is_staff(p_actor, array['admin']) then
    perform knock.fail('forbidden', 'only the creator can do that');
  end if;
  if p_action in ('review','clear_review') and not knock.is_staff(p_actor, array['compliance','admin']) then
    perform knock.fail('forbidden', 'compliance role required');
  end if;
  v_new := case p_action
    when 'pause' then case when v_link.status = 'active' then 'paused' end
    when 'resume' then case when v_link.status = 'paused' and (v_link.expires_at is null or v_link.expires_at > now()) then 'active' end
    when 'close' then case when v_link.status not in ('closed','under_review') then 'closed' end
    when 'review' then 'under_review'
    when 'clear_review' then case when v_link.status = 'under_review' then 'active' end
  end;
  if v_new is null then perform knock.fail('invalid_state', format('cannot %s a link that is %s', p_action, v_link.status)); end if;
  update knock.payment_links set status = v_new where id = p_link;
  perform knock.audit(p_actor, case when p_action in ('review','clear_review') then 'staff' else 'user' end,
                      'link.' || p_action, p_link, null, jsonb_build_object('note', p_note, 'from', v_link.status, 'to', v_new));
  if p_action = 'clear_review' and v_link.settlement_mode = 'each_payment' then
    for v_pay in select id from knock.payments where link_id = p_link and status = 'succeeded' and distribution_status = 'held' loop
      perform knock.try_distribute(v_pay, p_actor);
    end loop;
  end if;
  return v_new;
end $$;

create or replace function knock.expire_links() returns int
language plpgsql as $$
declare v record; n int := 0;
begin
  for v in update knock.payment_links set status = 'expired'
           where status in ('active','paused') and expires_at is not null and expires_at <= now()
           returning id, creator_id, title, reference loop
    n := n + 1;
    perform knock.audit(null, 'system', 'link.expired', v.id, null, null);
    perform knock.notify(v.creator_id, 'link_expired', 'Payment link expired', format('"%s" (%s) no longer accepts payments.', v.title, v.reference), v.id, null);
  end loop;
  -- Warn creators 24 hours before expiry, once.
  for v in select l.id, l.creator_id, l.title, l.reference from knock.payment_links l
           where l.status = 'active' and l.expires_at between now() and now() + interval '24 hours'
             and not exists (select 1 from knock.notifications nn where nn.link_id = l.id and nn.kind = 'link_expiring') loop
    perform knock.notify(v.creator_id, 'link_expiring', 'Payment link expires soon', format('"%s" (%s) expires within 24 hours.', v.title, v.reference), v.id, null);
  end loop;
  return n;
end $$;

-- ---------------------------------------------------------------------------
-- Checkout
-- ---------------------------------------------------------------------------

create or replace function knock.link_collected(p_link uuid) returns numeric
language sql stable as $$
  select coalesce(sum(amount), 0) from knock.payments where link_id = p_link and status in ('succeeded','disputed')
$$;

-- Price a payment before the provider session is created. Raises if the
-- link cannot take this payment.
create or replace function knock.checkout_quote(p_slug text, p_amount numeric) returns jsonb
language plpgsql as $$
declare v_link knock.payment_links; v_amount numeric; v_fee numeric; v_remaining numeric; v_limits knock.tier_limits;
begin
  select * into v_link from knock.payment_links where slug = p_slug;
  if not found then perform knock.fail('not_found', 'this payment link does not exist'); end if;
  if v_link.status = 'active' and v_link.expires_at is not null and v_link.expires_at <= now() then
    perform knock.fail('link_expired', 'this payment link has expired');
  end if;
  if v_link.status <> 'active' then
    perform knock.fail('link_' || v_link.status, 'this payment link is not accepting payments');
  end if;
  v_amount := case when v_link.amount_mode = 'fixed' then v_link.fixed_amount else p_amount end;
  if v_amount is null or v_amount <= 0 then perform knock.fail('invalid_amount', 'enter an amount'); end if;
  if v_link.min_amount is not null and v_amount < v_link.min_amount then perform knock.fail('invalid_amount', 'amount is below the minimum'); end if;
  if v_link.max_amount is not null and v_amount > v_link.max_amount then perform knock.fail('invalid_amount', 'amount is above the maximum'); end if;
  select t.* into v_limits from knock.tier_limits t join knock.profiles pr on pr.kyc_tier = t.kyc_tier where pr.id = v_link.creator_id;
  if v_link.currency = 'NGN' and v_amount > v_limits.max_single_payment then
    perform knock.fail('limit_exceeded', 'amount is above this link''s per-payment limit');
  end if;
  if v_link.target_amount is not null then
    v_remaining := v_link.target_amount - knock.link_collected(v_link.id);
    if v_amount > v_remaining then
      perform knock.fail('over_target', format('only %s remains to be collected', greatest(v_remaining, 0)));
    end if;
  end if;
  v_fee := knock.quote_fee(v_link.currency, v_amount);
  return jsonb_build_object(
    'link_id', v_link.id, 'currency', v_link.currency, 'network', v_link.network,
    'amount', v_amount, 'knock_fee', v_fee,
    'payer_fee', case when v_link.fee_bearer = 'payer' then v_fee else 0 end,
    'total_to_pay', v_amount + case when v_link.fee_bearer = 'payer' then v_fee else 0 end,
    'remaining', v_remaining);
end $$;

-- Record a checkout the provider has opened (bank transfer account, card
-- session or crypto address). Nothing is credited here.
create or replace function knock.create_payment_intent(p_slug text, p_amount numeric, p jsonb) returns jsonb
language plpgsql as $$
declare q jsonb; v_link knock.payment_links; v_id uuid; v_ref text;
begin
  q := knock.checkout_quote(p_slug, p_amount);
  select * into v_link from knock.payment_links where slug = p_slug;
  if v_link.require_customer_reference and coalesce(p->>'customer_reference', '') = '' then
    perform knock.fail('reference_required', 'enter your customer reference');
  end if;
  v_ref := knock.new_ref('KPY');
  insert into knock.payments (link_id, knock_reference, provider, provider_reference, method, currency, network,
     amount, payer_fee, knock_fee, payer_name, payer_email, payer_phone, customer_reference, status,
     pay_address, quote_rate_ngn, quote_expires_at)
  values (v_link.id, v_ref, p->>'provider', p->>'provider_reference', p->>'method', v_link.currency, v_link.network,
     (q->>'amount')::numeric, (q->>'payer_fee')::numeric, (q->>'knock_fee')::numeric,
     p->>'payer_name', p->>'payer_email', p->>'payer_phone', p->>'customer_reference', 'initiated',
     p->>'pay_address', nullif(p->>'quote_rate_ngn', '')::numeric, nullif(p->>'quote_expires_at', '')::timestamptz)
  returning id into v_id;
  return q || jsonb_build_object('payment_id', v_id, 'knock_reference', v_ref);
end $$;

-- Non-money status updates from the provider (pending, confirming, failed).
create or replace function knock.update_payment_progress(p_provider text, p_ref text, p_status text, p_confirmations int default null, p_tx_hash text default null)
returns text language plpgsql as $$
declare v knock.payments; v_link knock.payment_links;
begin
  select * into v from knock.payments where provider = p_provider and provider_reference = p_ref for update;
  if not found then perform knock.fail('not_found', 'unknown payment'); end if;
  if v.status in ('succeeded','reversed','disputed') then return v.status; end if;   -- never downgrade
  if p_status not in ('pending','confirming','failed','expired') then perform knock.fail('invalid_state', 'bad progress status'); end if;
  update knock.payments set status = p_status, confirmations = coalesce(p_confirmations, confirmations),
         tx_hash = coalesce(p_tx_hash, tx_hash), updated_at = now() where id = v.id;
  if p_status = 'failed' and v.status <> 'failed' then
    select * into v_link from knock.payment_links where id = v.link_id;
    perform knock.notify(v_link.creator_id, 'payment_failed', 'A payment failed',
      format('A payment to "%s" did not go through (%s).', v_link.title, v.knock_reference), v.link_id, v.id);
  end if;
  return p_status;
end $$;

-- ---------------------------------------------------------------------------
-- Verified payment -> ledger -> split
-- ---------------------------------------------------------------------------

-- Called only after the API layer has (a) verified the webhook signature and
-- (b) re-fetched the transaction from the provider's verify API. p_verified
-- holds the provider's answer: amount_paid, currency, network, tx_hash,
-- confirmations, raw. Safe to call many times for the same payment.
create or replace function knock.confirm_payment(p_provider text, p_ref text, p_verified jsonb) returns jsonb
language plpgsql as $$
declare
  v knock.payments;
  v_link knock.payment_links;
  v_asset knock.assets;
  v_paid numeric := (p_verified->>'amount_paid')::numeric;
  v_expected numeric;
  v_hold_reason text;
  v_collection uuid;
  v_clearing uuid;
  v_fee_acct uuid;
  v_pay uuid;
  v_collected numeric;
  v_distributed boolean := false;
begin
  select * into v from knock.payments where provider = p_provider and provider_reference = p_ref for update;
  if not found then perform knock.fail('not_found', 'unknown payment reference'); end if;
  if v.status in ('succeeded','disputed','reversed') then
    return jsonb_build_object('result', 'duplicate', 'payment_id', v.id, 'status', v.status);
  end if;
  select * into v_link from knock.payment_links where id = v.link_id for update;
  select * into v_asset from knock.assets where code = v.currency and network = v.network;

  -- Reconcile what the provider says against what we expected.
  if p_verified->>'currency' is distinct from v.currency then
    perform knock.fail('reconciliation_failed', 'currency mismatch');
  end if;
  if v_asset.kind = 'crypto' then
    if p_verified->>'network' is distinct from v.network then perform knock.fail('reconciliation_failed', 'network mismatch'); end if;
    if coalesce(p_verified->>'tx_hash', '') = '' then perform knock.fail('reconciliation_failed', 'missing transaction hash'); end if;
    if coalesce((p_verified->>'confirmations')::int, 0) < v_asset.min_confirmations then
      update knock.payments set status = 'confirming', confirmations = coalesce((p_verified->>'confirmations')::int, 0),
             tx_hash = p_verified->>'tx_hash', updated_at = now() where id = v.id;
      return jsonb_build_object('result', 'awaiting_confirmations', 'payment_id', v.id,
                                'confirmations', coalesce((p_verified->>'confirmations')::int, 0), 'required', v_asset.min_confirmations);
    end if;
  end if;
  if v_paid is null or v_paid <= 0 then perform knock.fail('reconciliation_failed', 'no amount paid'); end if;

  v_expected := v.amount + v.payer_fee;
  if v_paid <> v_expected then
    -- Money arrived, so it must be accounted for, but the amount differs
    -- (common with bank transfers). Re-price as a fee-deducted payment of
    -- the real amount and hold it for review.
    v.amount := v_paid; v.payer_fee := 0; v.knock_fee := knock.quote_fee(v.currency, v_paid);
    v_hold_reason := format('amount mismatch: expected %s, received %s', v_expected, v_paid);
    insert into knock.risk_flags (link_id, payment_id, rule, severity, detail)
    values (v.link_id, v.id, 'amount_mismatch', 'medium', jsonb_build_object('expected', v_expected, 'received', v_paid));
  end if;
  if v_link.status <> 'active' then
    v_hold_reason := coalesce(v_hold_reason, 'payment arrived while link was ' || v_link.status);
  end if;

  update knock.payments set
    status = 'succeeded', amount = v.amount, payer_fee = v.payer_fee, knock_fee = v.knock_fee, gross_paid = v_paid,
    tx_hash = coalesce(p_verified->>'tx_hash', tx_hash), confirmations = coalesce((p_verified->>'confirmations')::int, confirmations),
    verification = p_verified, verified_at = now(), updated_at = now(),
    distribution_status = 'held', last_distribution_error = v_hold_reason
  where id = v.id;
  if v_link.first_payment_at is null then
    update knock.payment_links set first_payment_at = now() where id = v_link.id;
  end if;

  v_collection := knock.account(null, v_link.id, 'link_collection', v.currency);
  v_clearing := knock.account(null, null, 'provider_clearing', v.currency);
  v_fee_acct := knock.account(null, null, 'fee_revenue', v.currency);

  perform knock.post_entry('pay:' || v.id || ':received', 'payment_received', v.currency,
    jsonb_build_array(jsonb_build_object('account', v_clearing, 'amount', v_paid),
                      jsonb_build_object('account', v_collection, 'amount', -v_paid)),
    v_link.id, v.id, 'verified payment ' || v.knock_reference);
  if v.knock_fee > 0 then
    perform knock.post_entry('pay:' || v.id || ':fee', 'knock_fee', v.currency,
      jsonb_build_array(jsonb_build_object('account', v_collection, 'amount', v.knock_fee),
                        jsonb_build_object('account', v_fee_acct, 'amount', -v.knock_fee)),
      v_link.id, v.id, 'Knock fee ' || v.knock_reference);
  end if;

  perform knock.audit(null, 'provider', 'payment.verified', v_link.id, v.id, p_verified - 'raw');
  perform knock.notify(v_link.creator_id, 'payment_received', 'Payment received',
    format('%s %s paid to "%s" (%s).', v.amount, v.currency, v_link.title, v.knock_reference), v_link.id, v.id,
    jsonb_build_object('amount', v.amount, 'currency', v.currency));

  -- Distribution according to the link's settlement mode.
  if v_hold_reason is null and v_link.settlement_mode = 'each_payment' then
    v_distributed := knock.try_distribute(v.id, null);
  end if;
  v_collected := knock.link_collected(v_link.id);
  if v_link.target_amount is not null and v_collected >= v_link.target_amount and v_link.status = 'active' then
    update knock.payment_links set status = 'completed' where id = v_link.id;
    perform knock.notify(v_link.creator_id, 'target_reached', 'Collection target reached',
      format('"%s" has collected its full target.', v_link.title), v_link.id, null);
    if v_link.settlement_mode = 'on_target' then
      for v_pay in select id from knock.payments where link_id = v_link.id and status = 'succeeded'
                   and distribution_status = 'held' and last_distribution_error is null order by verified_at loop
        perform knock.try_distribute(v_pay, null);
      end loop;
    end if;
  end if;
  return jsonb_build_object('result', 'confirmed', 'payment_id', v.id, 'distributed', v_distributed,
                            'held_reason', v_hold_reason, 'collected', v_collected);
end $$;

-- Distribute one verified payment to its recipients. Raises on any problem,
-- so the caller's savepoint rolls back every line of the distribution.
create or replace function knock.distribute_payment(p_payment uuid, p_actor uuid) returns void
language plpgsql as $$
declare
  v knock.payments;
  v_link knock.payment_links;
  v_creator uuid;
  rec record;
  ids uuid[] := '{}';
  weights numeric[] := '{}';
  overflow boolean[] := '{}';
  basis numeric;
  fee_deduct numeric;
  remaining_total numeric := 0;
  g numeric[];
  f numeric[];
  v_excess numeric := 0;
  v_state text;
  v_collection uuid;
  v_lines jsonb := '[]';
  v_net numeric;
  v_total_net numeric := 0;
  v_entry uuid;
  v_alloc uuid;
  i int;
begin
  select * into v from knock.payments where id = p_payment for update;
  if v.status <> 'succeeded' then perform knock.fail('invalid_state', 'payment is not in a distributable state'); end if;
  if v.distribution_status = 'distributed' then return; end if;
  select * into v_link from knock.payment_links where id = v.link_id;
  if v_link.status = 'under_review' then perform knock.fail('under_review', 'link is under compliance review'); end if;
  v_creator := v_link.creator_id;

  basis := v.amount;
  fee_deduct := case when v_link.fee_bearer = 'deduct' then v.knock_fee else 0 end;

  for rec in select r.*, p.username, p.status as pstatus,
               (select coalesce(sum(a.gross_share), 0) from knock.split_allocations a
                  join knock.allocation_state s on s.id = a.id
                where a.link_id = v_link.id and a.recipient_id = r.recipient_id and not a.is_overflow and s.state <> 'reversed') as received
             from knock.split_recipients r join knock.profiles p on p.id = r.recipient_id
             where r.link_id = v_link.id and r.rule_version = v_link.current_rule_version order by r.position loop
    if rec.pstatus <> 'active' then
      perform knock.fail('recipient_unavailable', '@' || rec.username || ' cannot be credited (account ' || rec.pstatus || ')');
    end if;
    ids := ids || rec.recipient_id;
    overflow := overflow || false;
    if v_link.split_method = 'fixed' then
      weights := weights || greatest(rec.allocated_amount - rec.received, 0);
      remaining_total := remaining_total + greatest(rec.allocated_amount - rec.received, 0);
    else
      weights := weights || rec.basis_points::numeric;
    end if;
  end loop;

  if v_link.split_method = 'fixed' then
    if remaining_total = 0 then
      -- Every fixed allocation is already met: the whole payment overflows to the creator.
      ids := array[v_creator]; weights := array[1::numeric]; overflow := array[true];
      g := array[basis];
    elsif basis <= remaining_total then
      g := knock.split_amount(basis, weights);
    else
      g := weights;                       -- each recipient gets exactly what remains
      v_excess := basis - remaining_total;
    end if;
  else
    g := knock.split_amount(basis, weights);
  end if;
  if v_excess > 0 then
    ids := ids || v_creator; g := g || v_excess; overflow := overflow || true;
  end if;
  f := case when fee_deduct > 0 then knock.split_amount(fee_deduct, g) else array_fill(0::numeric, array[array_length(g, 1)]) end;

  v_state := case when v.settled_at is null then 'pending' else 'available' end;
  v_collection := knock.account(null, v_link.id, 'link_collection', v.currency);
  for i in 1..array_length(ids, 1) loop
    v_net := g[i] - f[i];
    if v_net > 0 then
      v_lines := v_lines || jsonb_build_object('account', knock.account(ids[i], null, 'user_' || v_state, v.currency), 'amount', -v_net);
      v_total_net := v_total_net + v_net;
    end if;
  end loop;
  v_lines := v_lines || jsonb_build_object('account', v_collection, 'amount', v_total_net);
  v_entry := knock.post_entry('pay:' || v.id || ':split', 'split_distribution', v.currency, v_lines, v_link.id, v.id,
                              'split of ' || v.knock_reference, p_actor);

  for i in 1..array_length(ids, 1) loop
    if g[i] = 0 then continue; end if;
    insert into knock.split_allocations (payment_id, link_id, recipient_id, rule_version, currency, gross_share, fee_share, net_share, is_overflow, journal_entry_id)
    values (v.id, v_link.id, ids[i], v_link.current_rule_version, v.currency, g[i], f[i], g[i] - f[i], overflow[i], v_entry)
    on conflict (payment_id, recipient_id) do nothing
    returning id into v_alloc;
    if v_alloc is null then
      -- Same recipient twice (creator is also the overflow target): fold into one row is not allowed
      -- by the immutable table, so the split was computed wrongly. Abort.
      perform knock.fail('engine_error', 'duplicate allocation for a recipient');
    end if;
    insert into knock.allocation_events (allocation_id, state, journal_entry_id, amount)
    values (v_alloc, v_state, v_entry, g[i] - f[i]);
    perform knock.notify(ids[i], 'split_credited',
      case when v_state = 'pending' then 'Incoming split (pending)' else 'Split credited' end,
      format('%s %s from "%s" (%s).', g[i] - f[i], v.currency, v_link.title, v.knock_reference), v_link.id, v.id,
      jsonb_build_object('amount', g[i] - f[i], 'currency', v.currency, 'state', v_state));
  end loop;

  update knock.payments set distribution_status = 'distributed', rule_version = v_link.current_rule_version,
         last_distribution_error = null, next_retry_at = null, updated_at = now() where id = v.id;
  perform knock.audit(p_actor, case when p_actor is null then 'system' else 'user' end, 'payment.distributed', v_link.id, v.id,
                      jsonb_build_object('rule_version', v_link.current_rule_version, 'entry', v_entry));
end $$;

-- Distribute inside a savepoint. On failure nothing of the distribution is
-- kept; the money stays in the link's collection account and the attempt is
-- logged with an exponential back-off for the retry job.
create or replace function knock.try_distribute(p_payment uuid, p_actor uuid) returns boolean
language plpgsql as $$
declare v_err text; v_attempts int; v_link knock.payment_links;
begin
  begin
    perform knock.distribute_payment(p_payment, p_actor);
    update knock.payments set distribution_attempts = distribution_attempts + 1 where id = p_payment
      returning distribution_attempts into v_attempts;
    insert into knock.distribution_attempts (payment_id, attempt, ok) values (p_payment, v_attempts, true);
    return true;
  exception when others then
    v_err := sqlerrm;
  end;
  update knock.payments set
    distribution_status = 'failed_retrying', distribution_attempts = distribution_attempts + 1,
    last_distribution_error = v_err,
    next_retry_at = now() + make_interval(mins => least(power(2, distribution_attempts)::int, 720)),
    updated_at = now()
  where id = p_payment returning distribution_attempts into v_attempts;
  insert into knock.distribution_attempts (payment_id, attempt, ok, error) values (p_payment, v_attempts, false, v_err);
  select l.* into v_link from knock.payment_links l join knock.payments p on p.link_id = l.id where p.id = p_payment;
  if v_attempts = 1 then
    perform knock.notify(v_link.creator_id, 'allocation_pending', 'Split distribution pending',
      format('A payment to "%s" is safely held and will be distributed when the issue clears: %s', v_link.title, v_err), v_link.id, p_payment);
  end if;
  return false;
end $$;

create or replace function knock.retry_due_distributions() returns int
language plpgsql as $$
declare v uuid; n int := 0;
begin
  for v in select id from knock.payments where distribution_status = 'failed_retrying' and next_retry_at <= now()
           order by next_retry_at limit 200 loop
    if knock.try_distribute(v, null) then n := n + 1; end if;
  end loop;
  return n;
end $$;

-- Manual distribution of held payments (settlement_mode manual, or after a
-- review). Creator, or finance/admin staff.
create or replace function knock.distribute_held(p_link uuid, p_actor uuid) returns jsonb
language plpgsql as $$
declare v_link knock.payment_links; v uuid; ok int := 0; failed int := 0;
begin
  select * into v_link from knock.payment_links where id = p_link;
  if not found then perform knock.fail('not_found', 'link not found'); end if;
  if v_link.creator_id <> p_actor and not knock.is_staff(p_actor, array['finance','admin']) then
    perform knock.fail('forbidden', 'only the creator or finance can distribute');
  end if;
  for v in select id from knock.payments where link_id = p_link and status = 'succeeded'
           and distribution_status in ('held','failed_retrying') order by verified_at loop
    if knock.try_distribute(v, p_actor) then ok := ok + 1; else failed := failed + 1; end if;
  end loop;
  perform knock.audit(p_actor, 'user', 'link.distribute_held', p_link, null, jsonb_build_object('ok', ok, 'failed', failed));
  return jsonb_build_object('distributed', ok, 'failed', failed);
end $$;

-- Provider has paid the money out to Knock's settlement account. Moves
-- recipients' pending shares to available.
create or replace function knock.settle_payment(p_provider text, p_ref text, p_provider_fee numeric, p_settlement_ref text)
returns void language plpgsql as $$
declare v knock.payments; a record; v_entry uuid; v_net numeric;
begin
  select * into v from knock.payments where provider = p_provider and provider_reference = p_ref for update;
  if not found then perform knock.fail('not_found', 'unknown payment'); end if;
  if v.settled_at is not null then return; end if;
  if v.status not in ('succeeded','disputed') then perform knock.fail('invalid_state', 'only verified payments settle'); end if;
  if p_provider_fee < 0 or p_provider_fee > v.gross_paid then perform knock.fail('invalid_amount', 'bad provider fee'); end if;
  perform knock.post_entry('pay:' || v.id || ':settled', 'provider_settlement', v.currency,
    jsonb_build_array(
      jsonb_build_object('account', knock.account(null, null, 'settlement_bank', v.currency), 'amount', v.gross_paid - p_provider_fee),
      jsonb_build_object('account', knock.account(null, null, 'provider_fee_expense', v.currency), 'amount', p_provider_fee),
      jsonb_build_object('account', knock.account(null, null, 'provider_clearing', v.currency), 'amount', -v.gross_paid)),
    v.link_id, v.id, 'settlement ' || coalesce(p_settlement_ref, ''));
  update knock.payments set settled_at = now(), updated_at = now() where id = v.id;
  for a in select * from knock.allocation_state where payment_id = v.id and state = 'pending' loop
    v_net := a.net_share;
    v_entry := knock.post_entry('alloc:' || a.id || ':available', 'split_release', a.currency,
      jsonb_build_array(jsonb_build_object('account', knock.account(a.recipient_id, null, 'user_pending', a.currency), 'amount', v_net),
                        jsonb_build_object('account', knock.account(a.recipient_id, null, 'user_available', a.currency), 'amount', -v_net)),
      a.link_id, v.id, 'funds available');
    insert into knock.allocation_events (allocation_id, state, journal_entry_id, amount) values (a.id, 'available', v_entry, v_net);
  end loop;
  perform knock.audit(null, 'provider', 'payment.settled', v.link_id, v.id, jsonb_build_object('provider_fee', p_provider_fee, 'ref', p_settlement_ref));
end $$;

-- ---------------------------------------------------------------------------
-- Disputes and reversals
-- ---------------------------------------------------------------------------

-- Move one allocation's money out of its current state account. Takes what
-- the account still holds; any shortfall (already spent) becomes a
-- receivable from that user.
create or replace function knock.unwind_allocation(p_alloc uuid, p_to_state text, p_idem text, p_actor uuid)
returns numeric language plpgsql as $$
declare a record; v_from uuid; v_take numeric; v_short numeric; v_lines jsonb; v_entry uuid; v_to uuid;
begin
  select * into a from knock.allocation_state where id = p_alloc;
  if a.state = 'reversed' then return 0; end if;
  v_from := knock.account(a.recipient_id, null, 'user_' || a.state, a.currency);
  v_take := least(a.amount_in_state, greatest(knock.balance(v_from), 0));
  if p_to_state = 'held' then
    if v_take = 0 then return 0; end if;
    v_to := knock.account(a.recipient_id, null, 'user_held', a.currency);
    v_lines := jsonb_build_array(jsonb_build_object('account', v_from, 'amount', v_take),
                                 jsonb_build_object('account', v_to, 'amount', -v_take));
  else -- reversed: back into the link's collection account
    v_short := a.net_share - v_take;
    v_lines := jsonb_build_array(jsonb_build_object('account', v_from, 'amount', v_take),
                 jsonb_build_object('account', knock.account(a.recipient_id, null, 'recovery_receivable', a.currency), 'amount', v_short),
                 jsonb_build_object('account', knock.account(null, a.link_id, 'link_collection', a.currency), 'amount', -a.net_share));
  end if;
  v_entry := knock.post_entry(p_idem, 'allocation_' || p_to_state, a.currency, v_lines, a.link_id, a.payment_id, null, p_actor);
  insert into knock.allocation_events (allocation_id, state, journal_entry_id, amount)
  values (a.id, p_to_state, v_entry, case when p_to_state = 'held' then v_take else 0 end);
  if p_to_state = 'reversed' and v_short > 0 then
    insert into knock.risk_flags (link_id, payment_id, user_id, rule, severity, detail)
    values (a.link_id, a.payment_id, a.recipient_id, 'recovery_receivable', 'high', jsonb_build_object('shortfall', v_short));
  end if;
  return v_take;
end $$;

create or replace function knock.reverse_payment(p_payment uuid, p_kind text, p_reason text, p_actor uuid) returns void
language plpgsql as $$
declare v knock.payments; v_link knock.payment_links; a record; v_out uuid;
begin
  select * into v from knock.payments where id = p_payment for update;
  if not found then perform knock.fail('not_found', 'payment not found'); end if;
  if v.status = 'reversed' then return; end if;
  if v.status not in ('succeeded','disputed') then perform knock.fail('invalid_state', 'only verified payments can be reversed'); end if;
  if p_kind not in ('refund','chargeback') then perform knock.fail('invalid_request', 'kind must be refund or chargeback'); end if;
  if p_actor is not null and not knock.is_staff(p_actor, array['finance','admin']) then
    perform knock.fail('forbidden', 'finance role required');
  end if;
  select * into v_link from knock.payment_links where id = v.link_id;

  for a in select id, recipient_id from knock.allocation_state where payment_id = v.id and state <> 'reversed' loop
    perform knock.unwind_allocation(a.id, 'reversed', 'alloc:' || a.id || ':reversed', p_actor);
    perform knock.notify(a.recipient_id, 'payment_reversed', 'Split reversed',
      format('A %s on "%s" (%s) was reversed: %s', p_kind, v_link.title, v.knock_reference, p_reason), v.link_id, v.id);
  end loop;
  if v.knock_fee > 0 then
    perform knock.post_entry('pay:' || v.id || ':fee_reversed', 'knock_fee_reversal', v.currency,
      jsonb_build_array(jsonb_build_object('account', knock.account(null, null, 'fee_revenue', v.currency), 'amount', v.knock_fee),
                        jsonb_build_object('account', knock.account(null, v.link_id, 'link_collection', v.currency), 'amount', -v.knock_fee)),
      v.link_id, v.id, p_kind, p_actor);
  end if;
  v_out := knock.account(null, null, case when v.settled_at is null then 'provider_clearing' else 'settlement_bank' end, v.currency);
  perform knock.post_entry('pay:' || v.id || ':reversed', 'payment_' || p_kind, v.currency,
    jsonb_build_array(jsonb_build_object('account', knock.account(null, v.link_id, 'link_collection', v.currency), 'amount', v.gross_paid),
                      jsonb_build_object('account', v_out, 'amount', -v.gross_paid)),
    v.link_id, v.id, p_reason, p_actor);
  update knock.payments set status = 'reversed', distribution_status = 'reversed', updated_at = now() where id = v.id;
  -- A completed link reopens if a reversal takes it back under target.
  if v_link.status = 'completed' and v_link.target_amount is not null and knock.link_collected(v_link.id) < v_link.target_amount then
    update knock.payment_links set status = case when expires_at is not null and expires_at <= now() then 'expired' else 'active' end where id = v_link.id;
  end if;
  perform knock.audit(p_actor, case when p_actor is null then 'provider' else 'staff' end, 'payment.' || p_kind, v.link_id, v.id, jsonb_build_object('reason', p_reason));
  perform knock.notify(v_link.creator_id, 'payment_reversed', 'Payment reversed',
    format('%s on "%s" (%s): %s', initcap(p_kind), v_link.title, v.knock_reference, p_reason), v.link_id, v.id);
end $$;

create or replace function knock.open_dispute(p_provider text, p_ref text, p_dispute_ref text, p_reason text) returns uuid
language plpgsql as $$
declare v knock.payments; v_link knock.payment_links; a record; v_id uuid;
begin
  select * into v from knock.payments where provider = p_provider and provider_reference = p_ref for update;
  if not found then perform knock.fail('not_found', 'payment not found'); end if;
  select id into v_id from knock.disputes where payment_id = v.id and provider_dispute_id = p_dispute_ref;
  if v_id is not null then return v_id; end if;
  if v.status <> 'succeeded' then perform knock.fail('invalid_state', 'only verified payments can be disputed'); end if;
  insert into knock.disputes (payment_id, provider_dispute_id, reason) values (v.id, p_dispute_ref, p_reason) returning id into v_id;
  update knock.payments set status = 'disputed', updated_at = now() where id = v.id;
  for a in select id, recipient_id from knock.allocation_state where payment_id = v.id and state in ('pending','available') loop
    perform knock.unwind_allocation(a.id, 'held', 'alloc:' || a.id || ':held:' || v_id, null);
    perform knock.notify(a.recipient_id, 'payment_disputed', 'Split on hold',
      'A payer disputed a payment you received a share of. Your share is on hold while it is reviewed.', v.link_id, v.id);
  end loop;
  select * into v_link from knock.payment_links where id = v.link_id;
  perform knock.notify(v_link.creator_id, 'payment_disputed', 'Payment disputed',
    format('A payer disputed %s on "%s". Shares are on hold.', v.knock_reference, v_link.title), v.link_id, v.id);
  perform knock.audit(null, 'provider', 'payment.disputed', v.link_id, v.id, jsonb_build_object('dispute', p_dispute_ref, 'reason', p_reason));
  return v_id;
end $$;

create or replace function knock.resolve_dispute(p_dispute uuid, p_outcome text, p_actor uuid) returns void
language plpgsql as $$
declare d knock.disputes; a record; v_entry uuid;
begin
  select * into d from knock.disputes where id = p_dispute for update;
  if not found then perform knock.fail('not_found', 'dispute not found'); end if;
  if d.status <> 'open' then return; end if;
  if p_actor is not null and not knock.is_staff(p_actor, array['finance','compliance','admin']) then
    perform knock.fail('forbidden', 'staff role required');
  end if;
  update knock.disputes set status = p_outcome, resolved_at = now() where id = d.id;
  if p_outcome = 'won' then
    update knock.payments set status = 'succeeded', updated_at = now() where id = d.payment_id;
    for a in select * from knock.allocation_state where payment_id = d.payment_id and state = 'held' loop
      if a.amount_in_state > 0 then
        v_entry := knock.post_entry('alloc:' || a.id || ':released:' || d.id, 'allocation_released', a.currency,
          jsonb_build_array(jsonb_build_object('account', knock.account(a.recipient_id, null, 'user_held', a.currency), 'amount', a.amount_in_state),
                            jsonb_build_object('account', knock.account(a.recipient_id, null, 'user_available', a.currency), 'amount', -a.amount_in_state)),
          a.link_id, a.payment_id, 'dispute won', p_actor);
      end if;
      insert into knock.allocation_events (allocation_id, state, journal_entry_id, amount) values (a.id, 'available', v_entry, a.amount_in_state);
    end loop;
  elsif p_outcome = 'lost' then
    perform knock.reverse_payment(d.payment_id, 'chargeback', coalesce(d.reason, 'dispute lost'), null);
  else
    perform knock.fail('invalid_request', 'outcome must be won or lost');
  end if;
  perform knock.audit(p_actor, 'staff', 'dispute.' || p_outcome, null, d.payment_id, jsonb_build_object('dispute', d.id));
end $$;

-- ---------------------------------------------------------------------------
-- Controlled amendment of split rules after payments have started
-- ---------------------------------------------------------------------------

create or replace function knock.apply_amendment(p_amendment uuid) returns void
language plpgsql as $$
declare m knock.split_amendments; v_link knock.payment_links; r record;
begin
  select * into m from knock.split_amendments where id = p_amendment for update;
  select * into v_link from knock.payment_links where id = m.link_id for update;
  if v_link.current_rule_version <> m.from_version then
    update knock.split_amendments set status = 'cancelled', decided_at = now() where id = m.id;
    perform knock.fail('stale_amendment', 'the split rules changed since this amendment was proposed');
  end if;
  perform knock.insert_recipients(v_link.id, m.to_version, m.recipients);
  perform set_config('knock.amendment', 'on', true);
  update knock.payment_links set current_rule_version = m.to_version where id = v_link.id;
  perform set_config('knock.amendment', 'off', true);
  update knock.split_amendments set status = 'applied', decided_at = now() where id = m.id;
  perform knock.audit(m.proposed_by, 'user', 'split.amended', v_link.id, null,
                      jsonb_build_object('amendment', m.id, 'from', m.from_version, 'to', m.to_version, 'reason', m.reason));
  for r in select distinct recipient_id from knock.split_recipients where link_id = v_link.id and rule_version in (m.from_version, m.to_version) loop
    perform knock.notify(r.recipient_id, 'split_amended', 'Split rules updated',
      format('The split for "%s" changed for future payments. Past payments keep their original split.', v_link.title), v_link.id, null);
  end loop;
end $$;

-- Recipients whose share goes down (or who are removed) must approve.
-- Everyone else is notified. Past allocations never change.
create or replace function knock.propose_amendment(p_link uuid, p_actor uuid, p_reason text, p_recipients jsonb) returns jsonb
language plpgsql as $$
declare v_link knock.payment_links; v_rows jsonb; v_id uuid; v_limits knock.tier_limits; r record; n int := 0;
begin
  select * into v_link from knock.payment_links where id = p_link for update;
  if not found then perform knock.fail('not_found', 'link not found'); end if;
  if v_link.creator_id <> p_actor then perform knock.fail('forbidden', 'only the creator can amend the split'); end if;
  if v_link.link_type <> 'split' then perform knock.fail('invalid_request', 'only split links have split rules'); end if;
  if v_link.status in ('closed','under_review') then perform knock.fail('invalid_state', 'this link cannot be amended now'); end if;
  if exists (select 1 from knock.split_amendments where link_id = p_link and status = 'proposed') then
    perform knock.fail('amendment_pending', 'another amendment is waiting for approval');
  end if;
  select t.* into v_limits from knock.tier_limits t join knock.profiles p on p.kyc_tier = t.kyc_tier where p.id = p_actor;
  v_rows := knock.build_recipients(v_link.creator_id, v_link.split_method, v_link.target_amount, v_link.allocation_mode,
                                   p_recipients, v_limits.max_recipients);
  insert into knock.split_amendments (link_id, from_version, to_version, proposed_by, reason, recipients)
  values (p_link, v_link.current_rule_version, v_link.current_rule_version + 1, p_actor, p_reason, v_rows) returning id into v_id;

  for r in select old.recipient_id from knock.split_recipients old
           left join lateral (select (x->>'basis_points')::int bp from jsonb_array_elements(v_rows) x
                              where (x->>'recipient_id')::uuid = old.recipient_id) nw on true
           where old.link_id = p_link and old.rule_version = v_link.current_rule_version
             and old.recipient_id <> p_actor and coalesce(nw.bp, 0) < old.basis_points loop
    insert into knock.amendment_approvals (amendment_id, user_id) values (v_id, r.recipient_id);
    perform knock.notify(r.recipient_id, 'amendment_approval', 'Approve a split change',
      format('The creator of "%s" wants to change the split: %s', v_link.title, p_reason), p_link, null, jsonb_build_object('amendment', v_id));
    n := n + 1;
  end loop;
  perform knock.audit(p_actor, 'user', 'split.amendment_proposed', p_link, null, jsonb_build_object('amendment', v_id, 'recipients', v_rows, 'reason', p_reason));
  if n = 0 then perform knock.apply_amendment(v_id); end if;
  return jsonb_build_object('amendment_id', v_id, 'approvals_needed', n, 'status', case when n = 0 then 'applied' else 'proposed' end);
end $$;

create or replace function knock.decide_amendment(p_amendment uuid, p_user uuid, p_decision text) returns text
language plpgsql as $$
declare m knock.split_amendments;
begin
  select * into m from knock.split_amendments where id = p_amendment for update;
  if not found or m.status <> 'proposed' then perform knock.fail('invalid_state', 'amendment is not open'); end if;
  update knock.amendment_approvals set decision = p_decision, decided_at = now()
   where amendment_id = p_amendment and user_id = p_user and decision is null;
  if not found then perform knock.fail('forbidden', 'your approval is not needed for this amendment'); end if;
  perform knock.audit(p_user, 'user', 'split.amendment_' || p_decision, m.link_id, null, jsonb_build_object('amendment', m.id));
  if p_decision = 'rejected' then
    update knock.split_amendments set status = 'rejected', decided_at = now() where id = m.id;
    return 'rejected';
  end if;
  if not exists (select 1 from knock.amendment_approvals where amendment_id = m.id and decision is distinct from 'approved') then
    perform knock.apply_amendment(m.id);
    return 'applied';
  end if;
  return 'proposed';
end $$;

-- ---------------------------------------------------------------------------
-- Reconciliation
-- ---------------------------------------------------------------------------

-- Returns one row per failed check. An empty result means the ledger,
-- payments and allocations agree.
create or replace function knock.reconcile(p_link uuid default null)
returns table (check_name text, link_id uuid, payment_id uuid, expected numeric, actual numeric)
language sql stable as $$
  -- 1. Every journal entry balances per currency.
  select 'entry_balanced', e.link_id, e.payment_id, 0::numeric, sum(l.amount)
  from knock.journal_entries e join knock.journal_lines l on l.entry_id = e.id
  where p_link is null or e.link_id = p_link
  group by e.id, l.currency having sum(l.amount) <> 0
  union all
  -- 2. Each verified payment has exactly one receipt posting of what the provider reported.
  select 'payment_received_posted', p.link_id, p.id, p.gross_paid,
         coalesce((select sum(l.amount) from knock.journal_entries e join knock.journal_lines l on l.entry_id = e.id
                   join knock.ledger_accounts a on a.id = l.account_id
                   where e.idempotency_key = 'pay:' || p.id || ':received' and a.purpose = 'provider_clearing'), 0)
  from knock.payments p
  where p.status in ('succeeded','disputed','reversed') and (p_link is null or p.link_id = p_link)
    and p.gross_paid is distinct from coalesce((select sum(l.amount) from knock.journal_entries e join knock.journal_lines l on l.entry_id = e.id
                   join knock.ledger_accounts a on a.id = l.account_id
                   where e.idempotency_key = 'pay:' || p.id || ':received' and a.purpose = 'provider_clearing'), 0)
  union all
  -- 3. Distributed payments: allocations add up to the distributable amount.
  select 'allocations_sum', p.link_id, p.id,
         p.amount - case when l.fee_bearer = 'deduct' then p.knock_fee else 0 end,
         coalesce((select sum(net_share) from knock.split_allocations a where a.payment_id = p.id), 0)
  from knock.payments p join knock.payment_links l on l.id = p.link_id
  where p.distribution_status in ('distributed','reversed') and (p_link is null or p.link_id = p_link)
    and p.amount - case when l.fee_bearer = 'deduct' then p.knock_fee else 0 end
        <> coalesce((select sum(net_share) from knock.split_allocations a where a.payment_id = p.id), 0)
  union all
  -- 4. A link's collection account holds exactly its undistributed money.
  select 'collection_balance', l.id, null::uuid,
         coalesce((select sum(p.gross_paid - p.knock_fee) from knock.payments p
                   where p.link_id = l.id and p.status in ('succeeded','disputed') and p.distribution_status <> 'distributed'), 0),
         coalesce((select b.balance from knock.account_balances b where b.link_id = l.id and b.purpose = 'link_collection'), 0)
  from knock.payment_links l
  where (p_link is null or l.id = p_link)
    and coalesce((select sum(p.gross_paid - p.knock_fee) from knock.payments p
                  where p.link_id = l.id and p.status in ('succeeded','disputed') and p.distribution_status <> 'distributed'), 0)
     <> coalesce((select b.balance from knock.account_balances b where b.link_id = l.id and b.purpose = 'link_collection'), 0)
  union all
  -- 5. Provider clearing equals verified, unsettled, unreversed payments.
  select 'provider_clearing', null::uuid, null::uuid,
         coalesce((select sum(gross_paid) from knock.payments p where p.status in ('succeeded','disputed') and p.settled_at is null and p.currency = b.currency), 0),
         b.balance
  from knock.account_balances b
  where p_link is null and b.purpose = 'provider_clearing'
    and b.balance <> coalesce((select sum(gross_paid) from knock.payments p where p.status in ('succeeded','disputed') and p.settled_at is null and p.currency = b.currency), 0)
  union all
  -- 6. No liability account is negative.
  select 'negative_balance', b.link_id, null::uuid, 0::numeric, b.balance
  from knock.account_balances b join knock.ledger_accounts a on a.id = b.account_id
  where not a.allow_negative and b.balance < 0 and (p_link is null or b.link_id = p_link)
$$;

-- ---------------------------------------------------------------------------
-- Row level security (defence in depth; the API uses the service role)
-- ---------------------------------------------------------------------------

do $$
declare t text;
begin
  foreach t in array array['profiles','staff_roles','ledger_accounts','journal_entries','journal_lines','payment_links',
    'split_recipients','split_amendments','amendment_approvals','recipient_groups','payments','split_allocations',
    'allocation_events','distribution_attempts','webhook_events','disputes','risk_flags','notifications','audit_log'] loop
    execute format('alter table knock.%I enable row level security', t);
  end loop;
  if exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'auth' and p.proname = 'uid') then
    execute $p$create policy own_links on knock.payment_links for select using (creator_id = auth.uid())$p$;
    execute $p$create policy own_allocations on knock.split_allocations for select using (recipient_id = auth.uid())$p$;
    execute $p$create policy own_notifications on knock.notifications for select using (user_id = auth.uid())$p$;
    execute $p$create policy own_groups on knock.recipient_groups for all using (owner_id = auth.uid())$p$;
  end if;
end $$;
