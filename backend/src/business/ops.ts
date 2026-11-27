// The fixed catalogue of operations behind the Knock Business and Knock Admin
// dashboards. Used by BOTH the HTTP API (backend/src/business/http.ts) and the
// in-browser sandbox, so there is one definition of every query.
//
// Security model
//   * The client sends only an op name and named params. It never sends SQL,
//     a user id, a business role or an MFA level.
//   * The runner binds $1 = the authenticated user (from the verified JWT) and
//     $2 = the business id (business ops) or the session's MFA level `aal`
//     (admin ops). Client params follow from $3, always as bound parameters.
//   * Before the SQL runs, the runner checks `perm` in the database
//     (knock.require_business / knock.require_staff_perm) in the same
//     transaction. Write functions check again themselves.
// This file must stay free of Node imports: the browser bundles it.

export type Scope = 'me' | 'business' | 'admin' | 'public';

export interface Op {
  scope: Scope;
  /** Permission checked before the SQL runs. */
  perm?: string;
  sql: string;
  /** Client params, bound in order from $3 (me/public: from $2). */
  args?: string[];
  /** Params that must be JSON objects; they are bound as text and cast in SQL. */
  json?: string[];
  /** Return the first row only. */
  one?: boolean;
  /** Writes: audit and rate-limit more strictly. */
  write?: boolean;
}

const tx = `knock.holder_transactions`;

export const OPS: Record<string, Op> = {
  // ---------------------------------------------------------------- me
  'me.profile': { scope: 'me', one: true,
    sql: `select id, username, display_name, kyc_tier, status, kind from knock.profiles where id = $1` },
  'me.businesses': { scope: 'me',
    sql: `select b.id, p.username as handle, coalesce(b.trading_name, b.legal_name) as name, m.role, b.verification_status, b.account_status,
                 knock.business_permissions($1, b.id) as permissions, b.country
          from knock.business_members m join knock.businesses b on b.id = m.business_id join knock.profiles p on p.id = b.id
          where m.user_id = $1 and m.status = 'active' order by b.created_at` },
  'me.invites': { scope: 'me',
    sql: `select b.id as business_id, coalesce(b.trading_name, b.legal_name) as name, m.role, ip.username as invited_by, m.created_at
          from knock.business_members m join knock.businesses b on b.id = m.business_id left join knock.profiles ip on ip.id = m.invited_by
          where m.user_id = $1 and m.status = 'invited'` },
  'me.respond_invite': { scope: 'me', write: true, args: ['business_id', 'accept'], one: true,
    sql: `select knock.respond_business_invite($1, $2::uuid, $3::boolean) as status` },
  'me.create_business': { scope: 'me', write: true, args: ['business'], json: ['business'], one: true,
    sql: `select knock.create_business($1, $2::jsonb) as r` },
  // Business-owner sign-up: called once after Supabase Auth sign-up, with the new user's JWT.
  'me.register_business': { scope: 'me', write: true, args: ['signup'], json: ['signup'], one: true,
    sql: `select knock.register_business_owner($1, $2::jsonb) as r` },
  // The web app is for business owners and their team only.
  'me.app_access': { scope: 'me', one: true, sql: `select knock.business_app_access($1) as r` },
  'me.categories': { scope: 'me', sql: `select code, label from knock.business_categories where enabled order by label` },

  // ---------------------------------------------------------------- business
  'biz.overview': { scope: 'business', perm: 'dashboard.view', args: ['from', 'to'], one: true,
    sql: `select knock.business_overview($1, $2, $3::timestamptz, $4::timestamptz) as r` },
  'biz.flags': { scope: 'business', perm: 'dashboard.view', sql: `select key, enabled, label, depends_on from knock.feature_flags order by key` },
  'biz.transactions': { scope: 'business', perm: 'transactions.view', args: ['category', 'state', 'currency', 'search', 'from', 'to', 'limit'],
    sql: `select id, category, direction, reference, occurred_at, counterparty, currency, amount::text, fees::text, net::text, provider,
                 provider_reference, provider_status, state, link_title, method, knock.holder_risk_status(holder_id) as risk_status
          from ${tx}
          where holder_id = $2 and ($3::text is null or category = $3) and ($4::text is null or state = $4) and ($5::text is null or currency = $5)
            and ($6::text is null or reference ilike '%' || $6 || '%' or counterparty ilike '%' || $6 || '%' or provider_reference ilike '%' || $6 || '%')
            and ($7::timestamptz is null or occurred_at >= $7) and ($8::timestamptz is null or occurred_at < $8)
          order by occurred_at desc limit least(coalesce($9::int, 200), 500)` },
  'biz.transaction': { scope: 'business', perm: 'transactions.view', args: ['id'], one: true,
    sql: `select to_jsonb(t) || jsonb_build_object(
            'ledger', coalesce((select jsonb_agg(jsonb_build_object('at', e.created_at, 'kind', e.kind, 'memo', e.memo, 'account', a.purpose, 'currency', l.currency,
                        'amount', (case when a.normal_side = 'credit' then -l.amount else l.amount end)::text) order by e.created_at, l.id)
                      from knock.journal_entries e join knock.journal_lines l on l.entry_id = e.id join knock.ledger_accounts a on a.id = l.account_id
                      where a.owner_id = $2 and (e.payment_id = t.id
                        or e.idempotency_key like 'crypto:%:deposit:' || coalesce(t.provider_reference, '-') || ':%'
                        or e.idempotency_key like 'crypto:withdrawal:' || t.id || ':%'
                        or e.id = (select journal_entry_id from knock.split_allocations where id = t.id))), '[]'),
            'history', coalesce((select jsonb_agg(jsonb_build_object('at', at, 'action', action, 'actor_kind', actor_kind) order by at, id)
                      from knock.audit_log where payment_id = t.id or detail->>'deposit_id' = t.id::text or detail->>'withdrawal_id' = t.id::text), '[]'))
          as r from ${tx} t where t.id = $3::uuid and t.holder_id = $2` },
  'biz.links': { scope: 'business', perm: 'dashboard.view', args: ['type', 'status', 'search'],
    sql: `select l.id, l.reference, l.slug, l.title, l.link_type, l.currency, l.network, l.amount_mode, l.fixed_amount::text, l.target_amount::text,
                 l.status, l.expires_at, l.created_at, l.settlement_mode, l.split_method,
                 count(p.id) filter (where p.status = 'succeeded') as payments,
                 coalesce(sum(p.amount) filter (where p.status = 'succeeded'), 0)::text as collected,
                 count(p.id) filter (where p.distribution_status = 'failed_retrying') as failed_distributions
          from knock.payment_links l left join knock.payments p on p.link_id = l.id
          where l.creator_id = $2 and ($3::text is null or l.link_type = $3) and ($4::text is null or l.status = $4)
            and ($5::text is null or l.title ilike '%' || $5 || '%' or l.reference ilike '%' || $5 || '%')
          group by l.id order by l.created_at desc` },
  'biz.link': { scope: 'business', perm: 'dashboard.view', args: ['id'], one: true,
    sql: `select to_jsonb(l) - 'slug' || jsonb_build_object('slug', l.slug,
            'collected', knock.link_collected(l.id)::text,
            'recipients', coalesce((select jsonb_agg(jsonb_build_object('position', r.position, 'user_id', r.recipient_id, 'username', pr.username,
                 'display_name', pr.display_name, 'basis_points', r.basis_points, 'allocated', r.allocated_amount::text, 'is_creator_remainder', r.is_creator_remainder,
                 'received', coalesce((select sum(s.amount_in_state) from knock.allocation_state s where s.link_id = l.id and s.recipient_id = r.recipient_id and s.state = 'available'), 0)::text,
                 'pending', coalesce((select sum(s.amount_in_state) from knock.allocation_state s where s.link_id = l.id and s.recipient_id = r.recipient_id and s.state in ('pending','held')), 0)::text
               ) order by r.position) from knock.split_recipients r join knock.profiles pr on pr.id = r.recipient_id
               where r.link_id = l.id and r.rule_version = l.current_rule_version), '[]'),
            'versions', (select count(distinct rule_version) from knock.split_recipients where link_id = l.id),
            'payments', coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'reference', p.knock_reference, 'amount', p.amount::text, 'fee', p.knock_fee::text,
                 'status', p.status, 'distribution', p.distribution_status, 'payer', coalesce(p.payer_name, p.payer_email), 'at', p.created_at,
                 'error', p.last_distribution_error) order by p.created_at desc) from knock.payments p where p.link_id = l.id), '[]'))
          as r from knock.payment_links l where l.id = $3::uuid and l.creator_id = $2` },
  'biz.create_link': { scope: 'business', write: true, args: ['link'], json: ['link'], one: true,
    sql: `select knock.business_create_link($1, $2, $3::jsonb) as r` },
  'biz.link_action': { scope: 'business', write: true, args: ['id', 'action'], one: true,
    sql: `select knock.business_link_action($1, $2, $3::uuid, $4) as status` },
  'biz.distribute_held': { scope: 'business', perm: 'splits.manage', write: true, args: ['id'], one: true,
    sql: `select knock.distribute_held($3::uuid, $2) as r from knock.payment_links where id = $3::uuid and creator_id = $2` },
  'biz.link_assets': { scope: 'business', perm: 'dashboard.view', sql: `select code, network, kind, decimals from knock.assets where enabled order by kind desc, code, network` },
  'biz.lookup_user': { scope: 'business', perm: 'dashboard.view', args: ['username'], one: true,
    sql: `select id, username, display_name, verified from knock.lookup_username($3)` },
  'biz.assets': { scope: 'business', perm: 'dashboard.view',
    sql: `select provider, asset_id, symbol, network, kind, deposit_enabled, withdraw_enabled, min_deposit::text, withdrawal_fee::text, min_withdrawal::text
          from knock.provider_asset_configurations order by symbol, network` },
  'biz.addresses': { scope: 'business', perm: 'crypto.receive',
    sql: `select id, provider, asset_id, symbol, network, address, memo, status, auto_settlement, is_wrong_asset_recovery, created_at
          from knock.provider_wallet_addresses where user_id = $2 order by created_at desc` },
  'biz.request_address': { scope: 'business', write: true, args: ['asset_id'], one: true,
    sql: `select knock.business_request_address($1, $2, c.provider, c.asset_id, c.symbol, c.network) as r
          from knock.provider_asset_configurations c where c.asset_id = $3 and c.deposit_enabled limit 1` },
  'biz.deposits': { scope: 'business', perm: 'transactions.view',
    sql: `select d.id, d.knock_reference, d.symbol, d.network, d.crypto_amount::text, d.status, d.sub_status, d.flag_reason, d.is_wrong_asset,
                 d.credited_currency, d.credited_minor::text, d.knock_fee_minor::text, d.customer_net_minor::text, d.tx_hash, d.confirmations,
                 d.required_confirmations, d.created_at, d.completed_at, s.status as settlement_status
          from knock.crypto_deposits d left join knock.settlements s on s.deposit_id = d.id where d.user_id = $2 order by d.created_at desc limit 200` },
  'biz.payouts': { scope: 'business', perm: 'transactions.view',
    sql: `select r.id, r.reference, r.kind, r.currency, r.amount_minor::text, r.status, r.needs_second_approver, r.note, r.error, r.created_at, r.decided_at,
                 rq.username as requested_by, ap.username as approved_by, r.requested_by = $1 as mine,
                 r.payload->>'asset' as asset, r.payload->>'network' as network, r.payload->>'destination_address' as destination,
                 r.withdrawal_id, w.status as withdrawal_status, w.knock_reference as withdrawal_reference, w.tx_hash, case when w.status in ('failed','rejected','refunded') then w.reason end as withdrawal_error
          from knock.business_payout_requests r join knock.profiles rq on rq.id = r.requested_by left join knock.profiles ap on ap.id = r.approved_by
          left join knock.provider_withdrawals w on w.id = r.withdrawal_id where r.business_id = $2 order by r.created_at desc` },
  'biz.request_payout': { scope: 'business', write: true, args: ['payout'], json: ['payout'], one: true,
    sql: `select knock.business_request_payout($1, $2, $3::jsonb) as r` },
  'biz.decide_payout': { scope: 'business', write: true, args: ['id', 'approve', 'note'], one: true,
    sql: `select knock.business_decide_payout($1, $2, $3::uuid, $4::boolean, $5) as r` },
  'biz.customers': { scope: 'business', perm: 'customers.view',
    sql: `select email, name, currency, payments, total::text, first_paid_at, last_paid_at from knock.business_customers
          where business_id = $2 order by last_paid_at desc limit 500` },
  'biz.analytics': { scope: 'business', perm: 'reports.view', args: ['from', 'to'], one: true,
    sql: `select jsonb_build_object(
            'by_category', coalesce((select jsonb_agg(x) from (select category, currency, state, count(*) as n, sum(amount)::text as amount from ${tx}
                where holder_id = $2 and occurred_at >= $3::timestamptz and occurred_at < $4::timestamptz group by 1,2,3 order by 1,2,3) x), '[]'),
            'by_link', coalesce((select jsonb_agg(x) from (select l.reference, l.title, l.currency, count(p.id) as attempts,
                count(p.id) filter (where p.status = 'succeeded') as succeeded, coalesce(sum(p.amount) filter (where p.status = 'succeeded'), 0)::text as collected
                from knock.payment_links l left join knock.payments p on p.link_id = l.id and p.created_at >= $3::timestamptz and p.created_at < $4::timestamptz
                where l.creator_id = $2 group by l.id order by 6 desc) x), '[]'),
            'by_weekday', coalesce((select jsonb_agg(x) from (select extract(isodow from occurred_at)::int as dow, currency, count(*) as n, sum(amount)::text as amount
                from ${tx} where holder_id = $2 and state = 'succeeded' and direction = 'in' and category <> 'split_distribution'
                and occurred_at >= $3::timestamptz and occurred_at < $4::timestamptz group by 1,2 order by 1) x), '[]')) as r` },
  'biz.team': { scope: 'business', perm: 'dashboard.view',
    sql: `select m.user_id, p.username, p.display_name, m.role, m.status, m.joined_at, m.created_at, ip.username as invited_by,
                 knock.business_permissions(m.user_id, m.business_id) as permissions,
                 coalesce((select jsonb_object_agg(permission, allowed) from knock.business_member_permissions o where o.business_id = m.business_id and o.user_id = m.user_id), '{}') as overrides
          from knock.business_members m join knock.profiles p on p.id = m.user_id left join knock.profiles ip on ip.id = m.invited_by
          where m.business_id = $2 and m.status in ('active','invited') order by m.role = 'owner' desc, m.created_at` },
  'biz.role_permissions': { scope: 'business', perm: 'dashboard.view', sql: `select role, array_agg(permission order by permission) as permissions from knock.business_role_permissions group by role` },
  'biz.invite': { scope: 'business', write: true, args: ['username', 'role'], one: true,
    sql: `select knock.invite_business_member($1, $2, $3, $4) as r` },
  'biz.update_member': { scope: 'business', write: true, args: ['user_id', 'change'], json: ['change'], one: true,
    sql: `select knock.update_business_member($1, $2, $3::uuid, $4::jsonb) as r` },
  'biz.settings': { scope: 'business', perm: 'dashboard.view', one: true,
    sql: `select to_jsonb(b) || jsonb_build_object('handle', p.username, 'kyc_tier', p.kyc_tier, 'profile_status', p.status,
            'checklist', knock.business_verification_checklist(b.id),
            'documents', coalesce((select jsonb_agg(jsonb_build_object('id', d.id, 'doc_type', d.doc_type, 'file_name', d.file_name, 'status', d.status,
                 'size_bytes', d.size_bytes, 'created_at', d.created_at) order by d.created_at desc) from knock.business_documents d where d.business_id = b.id and d.status <> 'superseded'), '[]'),
            'representatives', coalesce((select jsonb_agg(to_jsonb(r) - 'user_id') from knock.business_representatives r where r.business_id = b.id and r.status = 'active'), '[]'),
            'history', coalesce((select jsonb_agg(jsonb_build_object('to', to_status, 'at', at, 'note', case when actor_kind = 'staff' then note end) order by id)
                 from knock.business_verification_events where business_id = b.id), '[]'))
          as r from knock.businesses b join knock.profiles p on p.id = b.id where b.id = $2` },
  'biz.update_profile': { scope: 'business', write: true, args: ['changes'], json: ['changes'], one: true,
    sql: `select knock.update_business_profile($1, $2, $3::jsonb) as r` },
  'biz.add_document': { scope: 'business', write: true, args: ['doc'], json: ['doc'], one: true,
    sql: `select knock.add_business_document($1, $2, $3::jsonb) as id` },
  'biz.add_representative': { scope: 'business', write: true, args: ['rep'], json: ['rep'], one: true,
    sql: `select knock.add_business_representative($1, $2, $3::jsonb) as id` },
  'biz.add_director': { scope: 'business', write: true, args: ['director'], json: ['director'], one: true,
    sql: `select knock.add_business_director($1, $2, $3::jsonb) as id` },
  'biz.remove_representative': { scope: 'business', write: true, args: ['representative_id'], one: true,
    sql: `select knock.remove_business_representative($1, $2, $3::uuid) as r` },
  'biz.set_registration': { scope: 'business', write: true, args: ['registration'], json: ['registration'], one: true,
    sql: `select knock.set_business_registration($1, $2, $3::jsonb) as r` },
  'biz.submit_verification': { scope: 'business', write: true, one: true,
    sql: `select knock.submit_business_verification($1, $2) as status` },
  'biz.notifications': { scope: 'business', perm: 'dashboard.view',
    sql: `select id, kind, title, body, created_at, read_at from knock.notifications where user_id = $2 order by created_at desc limit 100` },
  'biz.mark_read': { scope: 'business', write: true, one: true, sql: `select knock.business_mark_notifications_read($1, $2) as n` },
  'biz.audit': { scope: 'business', perm: 'team.manage',
    sql: `select a.at, a.action, p.username as actor, a.detail from knock.audit_log a left join knock.profiles p on p.id = a.actor_id
          where a.business_id = $2 and a.actor_kind = 'user' order by a.at desc limit 200` },
  'biz.open_ticket': { scope: 'business', write: true, args: ['ticket'], json: ['ticket'], one: true,
    sql: `select knock.business_open_ticket($1, $2, $3::jsonb) as r` },
  'biz.tickets': { scope: 'business', perm: 'dashboard.view',
    sql: `select t.id, t.reference, t.subject, t.status, t.priority, t.created_at, t.updated_at,
                 (select jsonb_agg(jsonb_build_object('at', m.at, 'author_kind', m.author_kind, 'body', m.body) order by m.id) from knock.support_messages m where m.ticket_id = t.id and not m.internal) as messages
          from knock.support_tickets t where t.holder_id = $2 order by t.updated_at desc` },

  // ---------------------------------------------------------------- public (payment page)
  'pub.link': { scope: 'public', args: ['slug'], one: true,
    sql: `select l.title, l.description, l.link_type, l.currency, l.network, l.amount_mode, l.fixed_amount::text, l.min_amount::text, l.max_amount::text,
                 l.target_amount::text, l.status, l.expires_at, l.require_customer_reference, l.invoice_number, l.payment_instructions, l.reference,
                 pr.display_name as merchant, pr.username as handle, pr.kind as merchant_kind, (b.verification_status = 'verified') as verified,
                 case when l.target_amount is not null then knock.link_collected(l.id)::text end as collected
          from knock.payment_links l join knock.profiles pr on pr.id = l.creator_id left join knock.businesses b on b.id = l.creator_id
          where l.slug = $1` },
  'pub.categories': { scope: 'public', sql: `select code, label from knock.business_categories where enabled order by label` },
  'pub.quote': { scope: 'public', args: ['slug', 'amount'], one: true, sql: `select knock.checkout_quote($1, $2::numeric) as r` },
  // Hosted checkout status, polled by the payer's page (by payment id, which only that browser holds).
  'pub.checkout': { scope: 'public', args: ['payment_id'], one: true, sql: `select knock.checkout_status($1::uuid) as r` },

  // ---------------------------------------------------------------- business: developers / webhooks
  'biz.webhook_event_types': { scope: 'business', perm: 'settings.manage', sql: `select type, description from knock.business_webhook_event_types order by type` },
  'biz.webhooks': { scope: 'business', perm: 'settings.manage',
    sql: `select e.id, e.url, e.description, e.events, e.status, e.secret_hint, e.created_at, e.rotated_at,
                 (select count(*) from knock.business_webhook_deliveries d where d.endpoint_id = e.id and d.status = 'delivered') as delivered,
                 (select count(*) from knock.business_webhook_deliveries d where d.endpoint_id = e.id and d.status in ('retrying','failed')) as failing,
                 (select count(*) from knock.business_webhook_deliveries d where d.endpoint_id = e.id and d.status in ('pending','sending')) as queued,
                 (select max(d.delivered_at) from knock.business_webhook_deliveries d where d.endpoint_id = e.id) as last_delivered_at
          from knock.business_webhook_endpoints e where e.business_id = $2 and e.status <> 'deleted' order by e.created_at` },
  'biz.webhook_deliveries': { scope: 'business', perm: 'settings.manage', args: ['endpoint_id'],
    sql: `select d.id, ev.event_ref, ev.type, ev.payload, ev.created_at, d.status, d.attempts, d.next_attempt_at, d.last_status_code,
                 d.last_error, d.last_duration_ms, d.delivered_at, e.url, e.id as endpoint_id
          from knock.business_webhook_deliveries d join knock.business_webhook_events ev on ev.id = d.event_id
          join knock.business_webhook_endpoints e on e.id = d.endpoint_id
          where e.business_id = $2 and ($3::uuid is null or e.id = $3::uuid) order by ev.created_at desc, d.created_at desc limit 100` },
  'biz.webhook_create': { scope: 'business', write: true, args: ['endpoint'], json: ['endpoint'], one: true,
    sql: `select knock.business_webhook_create($1, $2, $3::jsonb) as r` },
  'biz.webhook_update': { scope: 'business', write: true, args: ['endpoint_id', 'endpoint'], json: ['endpoint'], one: true,
    sql: `select knock.business_webhook_update($1, $2, $3::uuid, $4::jsonb) as r` },
  'biz.webhook_rotate': { scope: 'business', write: true, args: ['endpoint_id'], one: true, sql: `select knock.business_webhook_rotate($1, $2, $3::uuid) as r` },
  'biz.webhook_delete': { scope: 'business', write: true, args: ['endpoint_id'], one: true, sql: `select knock.business_webhook_delete($1, $2, $3::uuid) as r` },
  'biz.webhook_test': { scope: 'business', write: true, args: ['endpoint_id'], one: true, sql: `select knock.business_webhook_test($1, $2, $3::uuid) as r` },
  'biz.webhook_retry': { scope: 'business', write: true, args: ['delivery_id'], one: true, sql: `select knock.business_webhook_retry($1, $2, $3::uuid) as r` },

  // ---------------------------------------------------------------- admin (Knock staff, MFA required)
  'adm.me': { scope: 'admin', perm: 'overview.view', one: true,
    sql: `select p.id, p.username, p.display_name, (select array_agg(role) from knock.staff_roles where user_id = $1) as roles,
                 knock.staff_permissions($1) as permissions, $2 as aal from knock.profiles p where p.id = $1` },
  'adm.overview': { scope: 'admin', perm: 'overview.view', args: ['from', 'to'], one: true,
    sql: `select knock.admin_overview($1, $2, $3::timestamptz, $4::timestamptz) as r` },
  'adm.earnings': { scope: 'admin', perm: 'earnings.view', args: ['from', 'to'], one: true,
    sql: `select knock.admin_earnings($1, $2, $3::timestamptz, $4::timestamptz) as r` },
  'adm.transactions': { scope: 'admin', perm: 'transactions.view', args: ['category', 'state', 'currency', 'search', 'provider', 'kind'],
    sql: `select t.id, t.category, t.direction, t.reference, t.occurred_at, t.counterparty, t.currency, t.amount::text, t.fees::text, t.net::text,
                 t.provider, t.provider_reference, t.provider_status, t.state, h.display_name as holder, h.username as holder_handle, h.kind as holder_kind,
                 knock.holder_risk_status(t.holder_id) as risk_status
          from ${tx} t join knock.profiles h on h.id = t.holder_id
          where ($3::text is null or t.category = $3) and ($4::text is null or t.state = $4) and ($5::text is null or t.currency = $5)
            and ($6::text is null or t.reference ilike '%' || $6 || '%' or h.username ilike '%' || $6 || '%' or t.provider_reference ilike '%' || $6 || '%')
            and ($7::text is null or t.provider = $7) and ($8::text is null or h.kind = $8)
          order by t.occurred_at desc limit 300` },
  'adm.users': { scope: 'admin', perm: 'users.view', args: ['search'],
    sql: `select p.id, p.username, p.display_name, p.kyc_tier, p.status, p.created_at,
                 (select count(*) from knock.risk_flags f where f.user_id = p.id and f.status = 'open') as open_flags,
                 (select count(*) from knock.business_members m where m.user_id = p.id and m.status = 'active') as businesses,
                 coalesce((select jsonb_agg(jsonb_build_object('currency', currency, 'amount', s::text)) from (select currency, sum(balance) s from knock.account_balances
                   where owner_id = p.id and purpose like 'user_%' group by currency having sum(balance) <> 0) b), '[]') as balances
          from knock.profiles p where p.kind = 'person' and ($3::text is null or p.username ilike '%' || $3 || '%' or p.display_name ilike '%' || $3 || '%')
          order by p.created_at desc limit 300` },
  'adm.holder': { scope: 'admin', perm: 'users.view', args: ['id'], one: true,
    sql: `select to_jsonb(p) || jsonb_build_object(
            'staff_roles', (select array_agg(role) from knock.staff_roles where user_id = p.id),
            'balances', coalesce((select jsonb_agg(jsonb_build_object('purpose', purpose, 'currency', currency, 'amount', balance::text)) from knock.account_balances where owner_id = p.id and balance <> 0), '[]'),
            'transactions', coalesce((select jsonb_agg(x) from (select category, reference, occurred_at, currency, amount::text, state from ${tx} where holder_id = p.id order by occurred_at desc limit 25) x), '[]'),
            'flags', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'rule', rule, 'severity', severity, 'status', status, 'case_status', case_status, 'created_at', created_at)) from knock.risk_flags where user_id = p.id), '[]'),
            'memberships', coalesce((select jsonb_agg(jsonb_build_object('business', coalesce(b.trading_name, b.legal_name), 'role', m.role, 'status', m.status)) from knock.business_members m join knock.businesses b on b.id = m.business_id where m.user_id = p.id), '[]'),
            'tickets', coalesce((select jsonb_agg(jsonb_build_object('reference', reference, 'subject', subject, 'status', status)) from knock.support_tickets where holder_id = p.id or opened_by = p.id), '[]'),
            'referrals', null)
          as r from knock.profiles p where p.id = $3::uuid` },
  'adm.businesses': { scope: 'admin', perm: 'businesses.view', args: ['search', 'status'],
    sql: `select b.id, coalesce(b.trading_name, b.legal_name) as name, b.legal_name, p.username as handle, o.username as owner, b.country, b.category,
                 b.verification_status, b.account_status, b.created_at, knock.holder_risk_status(b.id) as risk_status,
                 (select count(*) from knock.payment_links where creator_id = b.id) as links,
                 coalesce((select jsonb_agg(jsonb_build_object('currency', currency, 'amount', s::text)) from (select currency, sum(amount) s from ${tx}
                   where holder_id = b.id and state = 'succeeded' and direction = 'in' and category <> 'split_distribution' group by currency) v), '[]') as volume
          from knock.businesses b join knock.profiles p on p.id = b.id join knock.profiles o on o.id = b.owner_id
          where ($3::text is null or b.legal_name ilike '%' || $3 || '%' or p.username ilike '%' || $3 || '%' or coalesce(b.trading_name,'') ilike '%' || $3 || '%')
            and ($4::text is null or b.verification_status = $4)
          order by b.created_at desc` },
  'adm.business': { scope: 'admin', perm: 'businesses.view', args: ['id'], one: true,
    sql: `select to_jsonb(b) || jsonb_build_object('handle', p.username, 'owner', o.username, 'kyc_tier', p.kyc_tier, 'profile_status', p.status,
            'checklist', knock.business_verification_checklist(b.id),
            'documents', coalesce((select jsonb_agg(to_jsonb(d) - 'storage_path' order by d.created_at desc) from knock.business_documents d where d.business_id = b.id), '[]'),
            'representatives', coalesce((select jsonb_agg(to_jsonb(r)) from knock.business_representatives r where r.business_id = b.id), '[]'),
            'history', coalesce((select jsonb_agg(to_jsonb(e) order by e.id) from knock.business_verification_events e where e.business_id = b.id), '[]'),
            'members', coalesce((select jsonb_agg(jsonb_build_object('username', mp.username, 'role', m.role, 'status', m.status)) from knock.business_members m join knock.profiles mp on mp.id = m.user_id where m.business_id = b.id), '[]'),
            'balances', coalesce((select jsonb_agg(jsonb_build_object('purpose', purpose, 'currency', currency, 'amount', balance::text)) from knock.account_balances where owner_id = b.id and balance <> 0), '[]'),
            'transactions', coalesce((select jsonb_agg(x) from (select category, reference, occurred_at, currency, amount::text, fees::text, state from ${tx} where holder_id = b.id order by occurred_at desc limit 30) x), '[]'),
            'payouts', coalesce((select jsonb_agg(jsonb_build_object('reference', reference, 'amount', amount_minor::text, 'currency', currency, 'status', status, 'at', created_at)) from knock.business_payout_requests where business_id = b.id), '[]'),
            'flags', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'rule', rule, 'severity', severity, 'status', status, 'case_status', case_status)) from knock.risk_flags where user_id = b.id), '[]'),
            'fees', coalesce((select jsonb_agg(jsonb_build_object('currency', currency, 'amount', s::text)) from (select currency, sum(fees) s from ${tx} where holder_id = b.id and state = 'succeeded' and category <> 'split_distribution' group by currency) f), '[]'),
            'pending_action', (select jsonb_build_object('id', id, 'action', action, 'requested_by', requested_by, 'reason', reason) from knock.admin_action_requests where subject_id = b.id and status = 'pending' limit 1))
          as r from knock.businesses b join knock.profiles p on p.id = b.id join knock.profiles o on o.id = b.owner_id where b.id = $3::uuid` },
  'adm.review_business': { scope: 'admin', write: true, args: ['id', 'decision', 'note'], one: true,
    sql: `select knock.staff_review_business($1, $2, $3::uuid, $4, $5) as status` },
  'adm.request_action': { scope: 'admin', write: true, args: ['action', 'subject_id', 'reason', 'evidence', 'payload'], json: ['evidence', 'payload'], one: true,
    sql: `select knock.staff_request_action($1, $2, $3, $4::uuid, $5, $6::jsonb, $7::jsonb) as id` },
  'adm.decide_action': { scope: 'admin', write: true, args: ['id', 'approve', 'note'], one: true,
    sql: `select knock.staff_decide_action($1, $2, $3::uuid, $4::boolean, $5) as status` },
  'adm.action_requests': { scope: 'admin', perm: 'overview.view',
    sql: `select r.id, r.action, r.subject_id, r.reason, r.evidence, r.status, r.created_at, r.decided_at, rq.username as requested_by, d.username as decided_by,
                 r.requested_by = $1 as mine, coalesce(sp.display_name, r.payload->>'entry_id') as subject
          from knock.admin_action_requests r join knock.profiles rq on rq.id = r.requested_by left join knock.profiles d on d.id = r.decided_by
          left join knock.profiles sp on sp.id = r.subject_id order by r.status = 'pending' desc, r.created_at desc limit 200` },
  'adm.links': { scope: 'admin', perm: 'links.view', args: ['type', 'status', 'search'],
    sql: `select l.id, l.reference, l.title, l.link_type, l.currency, l.status, l.created_at, l.target_amount::text, l.settlement_mode, cp.username as creator, cp.kind as creator_kind,
                 count(p.id) filter (where p.status = 'succeeded') as payments, coalesce(sum(p.amount) filter (where p.status = 'succeeded'), 0)::text as collected,
                 count(p.id) filter (where p.distribution_status = 'failed_retrying') as failed_distributions,
                 count(p.id) filter (where p.distribution_status = 'held') as held
          from knock.payment_links l join knock.profiles cp on cp.id = l.creator_id left join knock.payments p on p.link_id = l.id
          where ($3::text is null or l.link_type = $3) and ($4::text is null or l.status = $4)
            and ($5::text is null or l.title ilike '%' || $5 || '%' or l.reference ilike '%' || $5 || '%' or cp.username ilike '%' || $5 || '%')
          group by l.id, cp.username, cp.kind order by l.created_at desc limit 300` },
  'adm.link_review': { scope: 'admin', write: true, args: ['id', 'action', 'note'], one: true,
    sql: `select knock.staff_link_review($1, $2, $3::uuid, $4, $5) as status` },
  'adm.deposits': { scope: 'admin', perm: 'transactions.view', args: ['status'],
    sql: `select d.id, d.knock_reference, h.username as holder, h.kind as holder_kind, d.provider, d.provider_trade_id, d.symbol, d.network, d.crypto_amount::text,
                 d.amount_in_usd::text, d.status, d.sub_status, d.flag_reason, d.is_wrong_asset, d.credited_currency, d.credited_minor::text, d.knock_fee_minor::text,
                 d.balance_remaining::text, d.settled_trades, d.tx_hash, d.created_at, d.completed_at
          from knock.crypto_deposits d join knock.profiles h on h.id = d.user_id where ($3::text is null or d.status = $3) order by d.created_at desc limit 300` },
  'adm.withdrawals': { scope: 'admin', perm: 'transactions.view', args: ['status'],
    sql: `select w.id, w.knock_reference, h.username as holder, h.kind as holder_kind, w.kind, w.purpose, w.status, w.currency, w.amount_minor::text,
                 w.knock_fee_minor::text, w.provider_fee::text, w.asset, w.network, w.destination_address, w.bank_name, w.account_number_masked,
                 w.provider, w.provider_withdrawal_id, w.tx_hash, w.last_error_code, w.created_at, w.completed_at, cb.username as created_by, ab.username as approved_by
          from knock.provider_withdrawals w join knock.profiles h on h.id = w.user_id left join knock.profiles cb on cb.id = w.created_by left join knock.profiles ab on ab.id = w.approved_by
          where ($3::text is null or w.status = $3) order by w.created_at desc limit 300` },
  'adm.settlements': { scope: 'admin', perm: 'transactions.view', one: true,
    sql: `select jsonb_build_object(
            'settlements', coalesce((select jsonb_agg(x) from (select s.id, s.trade_id, h.username as holder, s.mode, s.status, s.currency, s.reserved_minor::text, s.amount_settled::text,
                 s.markup_percent::text, s.markup_amount::text, s.rate::text, s.fee_amount_usd::text, s.destination, s.created_at
                 from knock.settlements s join knock.profiles h on h.id = s.user_id order by s.created_at desc limit 200) x), '[]'),
            'exceptions', coalesce((select jsonb_agg(x) from (select e.id, e.trade_id, e.status, e.reason, e.amount::text, e.currency, e.resolution, e.created_at, a.username as assigned_to
                 from knock.settlement_exceptions e left join knock.profiles a on a.id = e.assigned_to order by e.created_at desc limit 200) x), '[]'),
            'provider_settings', (select jsonb_agg(jsonb_build_object('provider', provider, 'business_auto_settlement', business_auto_settlement,
                 'destination', business_settlement_destination)) from knock.provider_accounts)) as r` },
  'adm.risk': { scope: 'admin', perm: 'risk.view', args: ['status', 'severity'],
    sql: `select f.id, f.rule, f.category, f.severity, f.reason, f.evidence, f.detail, f.status, f.case_status, f.resolution_notes, f.created_at, f.updated_at,
                 h.username as holder, h.kind as holder_kind, f.user_id as holder_id, a.username as assigned_to, f.subject_kind, f.subject_id
          from knock.risk_flags f left join knock.profiles h on h.id = f.user_id left join knock.profiles a on a.id = f.assigned_to
          where ($3::text is null or f.case_status = $3) and ($4::text is null or f.severity = $4)
          order by f.status = 'open' desc, case f.severity when 'high' then 0 when 'medium' then 1 else 2 end, f.created_at desc limit 300` },
  'adm.update_risk': { scope: 'admin', write: true, args: ['id', 'change'], json: ['change'], one: true,
    sql: `select knock.staff_update_risk_case($1, $2, $3::uuid, $4::jsonb) as r` },
  'adm.run_risk_rules': { scope: 'admin', perm: 'risk.manage', write: true, one: true, sql: `select knock.run_risk_rules() as n` },
  'adm.lists': { scope: 'admin', perm: 'risk.view',
    sql: `select w.id, w.list, w.subject_kind, w.value, w.reason, w.evidence, w.status, w.created_at, w.expires_at, r.username as requested_by, a.username as approved_by
          from knock.watchlist_entries w join knock.profiles r on r.id = w.requested_by left join knock.profiles a on a.id = w.approved_by
          where w.status <> 'removed' order by w.created_at desc` },
  'adm.add_list_entry': { scope: 'admin', write: true, args: ['entry'], json: ['entry'], one: true,
    sql: `select knock.staff_add_list_entry($1, $2, $3::jsonb) as r` },
  'adm.kyc_queue': { scope: 'admin', perm: 'kyc.view',
    sql: `select b.id, coalesce(b.trading_name, b.legal_name) as name, b.legal_name, b.country, b.category, b.verification_status, b.submitted_at,
                 (select count(*) from knock.business_documents d where d.business_id = b.id and d.status in ('uploaded','accepted')) as documents,
                 (select count(*) from knock.business_representatives r where r.business_id = b.id and r.status = 'active') as representatives,
                 (select high_risk from knock.business_categories where code = b.category) as high_risk_category
          from knock.businesses b where b.verification_status in ('pending','under_review','info_required')
          order by b.submitted_at nulls last` },
  'adm.tickets': { scope: 'admin', perm: 'support.view',
    sql: `select t.id, t.reference, t.subject, t.category, t.priority, t.status, t.created_at, t.updated_at, h.username as holder, a.username as assigned_to,
                 (select jsonb_agg(jsonb_build_object('at', m.at, 'author_kind', m.author_kind, 'body', m.body, 'internal', m.internal) order by m.id) from knock.support_messages m where m.ticket_id = t.id) as messages
          from knock.support_tickets t join knock.profiles h on h.id = t.holder_id left join knock.profiles a on a.id = t.assigned_to
          order by t.status in ('resolved','closed'), t.updated_at desc` },
  'adm.ticket_reply': { scope: 'admin', write: true, args: ['id', 'reply'], json: ['reply'], one: true,
    sql: `select knock.staff_ticket_reply($1, $2, $3::uuid, $4::jsonb) as r` },
  'adm.alerts': { scope: 'admin', perm: 'notifications.view',
    sql: `select a.id, a.kind, a.severity, a.title, a.body, a.subject_kind, a.created_at, a.acknowledged_at, s.username as acknowledged_by
          from knock.admin_alerts a left join knock.profiles s on s.id = a.acknowledged_by order by a.acknowledged_at is null desc, a.created_at desc limit 300` },
  'adm.ack_alert': { scope: 'admin', write: true, args: ['id'], one: true, sql: `select knock.staff_ack_alert($1, $2, $3::uuid) as r` },
  'adm.providers': { scope: 'admin', perm: 'providers.view', one: true,
    sql: `select jsonb_build_object(
            'accounts', coalesce((select jsonb_agg(jsonb_build_object('provider', provider, 'environment', environment, 'status', status, 'last_health_at', last_health_at,
                'last_health_ok', last_health_ok, 'webhook_last_received_at', webhook_last_received_at, 'business_auto_settlement', business_auto_settlement)) from knock.provider_accounts), '[]'),
            'api', coalesce((select jsonb_agg(x) from (select provider, route, count(*) as requests, count(*) filter (where outcome = 'ok') as ok,
                count(*) filter (where outcome <> 'ok') as failed, max(at) as last_at from knock.provider_api_logs where at > now() - interval '24 hours' group by 1, 2 order by 3 desc) x), '[]'),
            'webhooks', coalesce((select jsonb_agg(x) from (select provider, status, count(*) as n, max(received_at) as last_at from knock.webhook_events group by 1, 2) x), '[]'),
            'last_webhook', (select max(received_at) from knock.webhook_events where status = 'processed'),
            'recent_webhooks', coalesce((select jsonb_agg(x) from (select provider, event_id, event_type, status, attempts, last_error, received_at, delivery_count
                from knock.webhook_events order by received_at desc limit 50) x), '[]'),
            'pending_deposits', (select count(*) from knock.crypto_deposits where status in ('pending','under_review','flagged','below_minimum')),
            'pending_withdrawals', (select count(*) from knock.provider_withdrawals where status in ('reserved','submitting','submission_unknown','pending','processing')),
            'unreconciled', (select count(*) from knock.provider_reconciliation_records where status <> 'resolved'),
            'failed_settlements', (select count(*) from knock.settlement_exceptions where status <> 'resolved'),
            'wallet_ledger', coalesce((select jsonb_agg(jsonb_build_object('code', code, 'currency', currency, 'balance', balance::text)) from knock.account_balances where purpose = 'provider_wallet'), '[]'),
            'reconciliation', coalesce((select jsonb_agg(x) from (select r.id, r.check_name, r.subject_kind, r.subject_ref, r.expected, r.actual, r.status, r.created_at
                from knock.provider_reconciliation_records r order by r.status = 'resolved', r.created_at desc limit 100) x), '[]'),
            'runs', coalesce((select jsonb_agg(x) from (select scope, trigger, status, discrepancies, started_at, finished_at from knock.provider_reconciliation_runs order by started_at desc limit 10) x), '[]')) as r` },
  'adm.health': { scope: 'admin', perm: 'providers.view', one: true,
    sql: `select jsonb_build_object(
            'webhook_queue', (select count(*) from knock.webhook_events where status in ('queued','retrying')),
            'webhook_failed', (select count(*) from knock.webhook_events where status = 'failed'),
            'oldest_queued', (select min(received_at) from knock.webhook_events where status in ('queued','retrying')),
            'distribution_retrying', (select count(*) from knock.payments where distribution_status = 'failed_retrying'),
            'submission_unknown', (select count(*) from knock.provider_withdrawals where status = 'submission_unknown'),
            'rate_limits', coalesce((select jsonb_agg(to_jsonb(r)) from knock.provider_rate_limits r), '[]'),
            'unbalanced_entries', (select count(*) from (select entry_id from knock.journal_lines group by entry_id, currency having sum(amount) <> 0) x),
            'negative_liabilities', (select count(*) from knock.account_balances b join knock.ledger_accounts a on a.id = b.account_id where not a.allow_negative and b.balance < 0),
            'db_time', now()) as r` },
  'adm.staff': { scope: 'admin', perm: 'overview.view',
    sql: `select p.username, p.display_name, p.status, array_agg(s.role order by s.role) as roles, min(s.granted_at) as since
          from knock.staff_roles s join knock.profiles p on p.id = s.user_id group by p.id order by p.username` },
  'adm.role_permissions': { scope: 'admin', perm: 'overview.view',
    sql: `select role, array_agg(permission order by permission) as permissions from knock.admin_role_permissions
          where role in ('super_admin','finance_manager','operations_manager','risk_officer','kyc_officer','support_agent','analyst') group by role` },
  'adm.audit': { scope: 'admin', perm: 'audit.view', args: ['search', 'kind'],
    sql: `select a.id, a.at, a.actor_kind, p.username as actor, a.action, b.username as business, a.detail
          from knock.audit_log a left join knock.profiles p on p.id = a.actor_id left join knock.profiles b on b.id = a.business_id
          where ($3::text is null or a.action ilike '%' || $3 || '%' or p.username ilike '%' || $3 || '%' or b.username ilike '%' || $3 || '%')
            and ($4::text is null or a.actor_kind = $4)
          order by a.id desc limit 300` },
  'adm.flags': { scope: 'admin', perm: 'overview.view',
    sql: `select f.key, f.enabled, f.label, f.depends_on, f.updated_at, p.username as updated_by from knock.feature_flags f left join knock.profiles p on p.id = f.updated_by order by f.key` },
  'adm.set_flag': { scope: 'admin', write: true, args: ['key', 'enabled'], one: true, sql: `select knock.staff_set_flag($1, $2, $3, $4::boolean) as r` },
  'adm.thresholds': { scope: 'admin', perm: 'overview.view', one: true,
    sql: `select jsonb_build_object(
            'fees', (select jsonb_agg(to_jsonb(f)) from knock.fee_schedule f),
            'crypto_fees', (select jsonb_agg(to_jsonb(f)) from knock.crypto_fee_schedule f),
            'tiers', (select jsonb_agg(to_jsonb(t) order by kyc_tier) from knock.tier_limits t),
            'approvals', (select jsonb_agg(to_jsonb(a)) from knock.approval_thresholds a),
            'business', (select jsonb_object_agg(key, value) from knock.business_settings)) as r` },
};

/** Build the bound parameter list. Identity values come from the caller, never from `input`. */
export function bindParams(op: Op, identity: { userId: string; context?: string | null }, input: Record<string, unknown>): unknown[] {
  const head: unknown[] = op.scope === 'public' ? [] : op.scope === 'me' ? [identity.userId] : [identity.userId, identity.context ?? null];
  const rest = (op.args ?? []).map((name) => {
    const v = input[name];
    if (v === undefined || v === null || v === '') return null;
    if (op.json?.includes(name)) {
      if (typeof v !== 'object') throw new Error(`bad_request: ${name} must be an object`);
      return JSON.stringify(v);
    }
    if (typeof v === 'object') throw new Error(`bad_request: ${name} must be a value`);
    if ((name === 'id' || name.endsWith('_id')) && !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(String(v)) && name !== 'asset_id') {
      throw new Error(`bad_request: ${name} is not a valid id`);
    }
    return String(v);
  });
  return [...head, ...rest];
}

/** SQL for the permission check that runs first, in the same transaction. */
export function guardSql(op: Op): { sql: string; params: (identity: { userId: string; context?: string | null }) => unknown[] } | null {
  if (!op.perm) return null;
  if (op.scope === 'business') return { sql: `select knock.require_business($1, $2::uuid, $3)`, params: (i) => [i.userId, i.context, op.perm] };
  if (op.scope === 'admin') return { sql: `select knock.require_staff_perm($1, $3, $2)`, params: (i) => [i.userId, i.context, op.perm] };
  return null;
}

/** Normalise one op result. */
export function shapeResult(op: Op, rows: any[]): unknown {
  if (!op.one) return rows;
  const row = rows[0];
  if (!row) return null;
  const keys = Object.keys(row);
  return keys.length === 1 ? row[keys[0]] : row;
}
