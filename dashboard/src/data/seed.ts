// Sandbox records, created through the real engine functions (onboarding,
// staff verification, link creation, payment confirmation, Breet deposit
// processing, payout approval). Only timestamps are moved into the past
// afterwards, so the dashboards have history to show. Sandbox only.
import type { Sandbox } from './sandbox.ts';

const PEOPLE: [string, string, string][] = [
  ['chanor', 'Chanor Odigie', 'Owner of Mama Put Foods and Lagos Creative Studio'],
  ['mary', 'Mary Okafor', 'Finance manager at Mama Put Foods'],
  ['tolu', 'Tolu Adeyemi', 'Support staff at Mama Put Foods'],
  ['innocent', 'Innocent Eze', 'Owner of Eko Gadgets; Smart Split recipient'],
  ['favour', 'Favour Bello', 'Smart Split recipient'],
  ['amaka', 'Amaka Nwosu', 'Knock staff: KYC officer'],
  ['bola', 'Bola Martins', 'Knock staff: Fraud & risk officer'],
  ['dayo', 'Dayo Akin', 'Knock staff: Fraud & risk officer'],
  ['ese', 'Ese Obi', 'Knock staff: Finance manager'],
  ['root', 'Kemi Lawal', 'Knock staff: Super admin'],
];

function rng(seed: number) {
  return () => { seed = (seed * 1664525 + 1013904223) % 4294967296; return seed / 4294967296; };
}

export const DEMO_PASSWORD = 'knockdemo2026';
export const DEMO_ACCOUNTS = [
  { email: 'chanor@mamaput.example', who: 'Owner, Mama Put Foods (verified) and Lagos Creative Studio (not verified)' },
  { email: 'mary@mamaput.example', who: 'Finance manager on the Mama Put Foods team' },
  { email: 'innocent@ekogadgets.example', who: 'Owner, Eko Gadgets (verification pending)' },
];

export async function seed(sb: Sandbox) {
  const q = sb.q.bind(sb);
  const call = async (sql: string, params: unknown[] = []) => (await q<{ r: any }>(sql, params))[0]?.r;
  const U: Record<string, string> = {};
  for (const [u, name, note] of PEOPLE) {
    const r = (await q<{ id: string }>(`insert into knock.profiles (username, display_name, kyc_tier) values ($1, $2, 2) returning id`, [u, name]))[0];
    U[u] = r.id;
    sb.people[u] = { id: r.id, username: u, name, note };
  }
  await q(`insert into knock.staff_roles (user_id, role) values ($1,'kyc_officer'),($2,'risk_officer'),($3,'risk_officer'),($4,'finance_manager'),($5,'super_admin')`,
    [U.amaka, U.bola, U.dayo, U.ese, U.root]);
  await q(`insert into knock.provider_accounts (provider, environment, status, last_health_at, last_health_ok, webhook_last_received_at)
           values ('breet','sandbox','configured', now() - interval '4 minutes', true, now() - interval '12 minutes')`);
  // What a Breet asset sync (GET /trades/assets + /payments/supported-assets-info) writes. Sandbox values.
  await q(`insert into knock.provider_asset_configurations (provider, asset_id, symbol, network, kind, deposit_enabled, withdraw_enabled, min_deposit, withdrawal_fee, withdrawal_fee_currency, min_withdrawal, raw) values
    ('breet','usdt-trc20','USDT','TRC20','stablecoin',true,true,5,1,'USDT',10,'{"sandbox":true}'),
    ('breet','usdt-bsc','USDT','BSC','stablecoin',true,true,5,0.5,'USDT',10,'{"sandbox":true}'),
    ('breet','usdc-sol','USDC','SOL','stablecoin',true,false,5,null,null,null,'{"sandbox":true}'),
    ('breet','btc','BTC','',  'utxo',true,true,0.0002,null,null,0.0005,'{"sandbox":true}')`);
  // Sandbox demo: crypto payouts switched on so the approval flow can be tried.
  await q(`update knock.feature_flags set enabled = true where key = 'business.crypto_payouts'`);

  const AAL = 'aal2';
  const mk = async (owner: string, p: Record<string, unknown>) => (await call(`select knock.create_business($1, $2::jsonb) as r`, [U[owner], JSON.stringify(p)])).id as string;
  const docs = async (owner: string, biz: string, types: string[]) => {
    for (const t of types) await call(`select knock.add_business_document($1, $2, $3::jsonb) as r`, [U[owner], biz, JSON.stringify({
      doc_type: t, file_name: t.replace(/_/g, '-') + '.pdf', storage_path: `sandbox/${biz}/${t}.pdf`, mime_type: 'application/pdf', size_bytes: 184_000, sha256: 'b'.repeat(64) })]);
  };

  const MAMA = await mk('chanor', { handle: 'mamaput', legal_name: 'Mama Put Foods Limited', trading_name: 'Mama Put Foods', category: 'food', country: 'NG',
    email: 'hello@mamaput.example', phone: '+234 803 555 0101', website: 'https://mamaput.example', registration_number: 'RC 1827364',
    description: 'Party trays, small chops and event catering across Lagos.' });
  await call(`select knock.set_business_registration($1, $2, $3::jsonb) as r`, [U.chanor, MAMA, JSON.stringify({ entity_type: 'limited_company', registration_number: 'RC1827364' })]);
  await docs('chanor', MAMA, ['registration_certificate', 'memat', 'proof_of_address', 'representative_id', 'tin']);
  // Sandbox test identity numbers (not real people).
  await call(`select knock.add_business_director($1, $2, $3::jsonb) as r`, [U.chanor, MAMA, JSON.stringify({ full_name: 'Chanor Odigie', role_title: 'Managing Director', ownership_bps: 7000,
    nin: '10000000001', bvn: '20000000001', date_of_birth: '1988-03-14', phone: '+234 803 555 0101', email: 'chanor@mamaput.example' })]);
  await call(`select knock.submit_business_verification($1, $2) as r`, [U.chanor, MAMA]);
  await call(`select knock.staff_review_business($1, $2, $3, 'verified', 'CAC record matches; address verified') as r`, [U.amaka, AAL, MAMA]);
  await call(`update knock.businesses set payout_dual_approval_above = 5000000 where id = $1 returning 1 as r`, [MAMA]); // NGN 50,000

  for (const [u, role] of [['mary', 'finance_manager'], ['tolu', 'support']] as const) {
    await call(`select knock.invite_business_member($1, $2, $3, $4) as r`, [U.chanor, MAMA, u, role]);
    await call(`select knock.respond_business_invite($1, $2, true) as r`, [U[u], MAMA]);
  }
  await call(`select knock.invite_business_member($1, $2, 'favour', 'read_only') as r`, [U.chanor, MAMA]); // pending invite

  const STUDIO = await mk('chanor', { handle: 'lagoscreative', legal_name: 'Lagos Creative Studio Ltd', category: 'agency', country: 'NG', email: 'studio@lagoscreative.example' });
  await docs('chanor', STUDIO, ['registration_certificate']);
  const EKO = await mk('innocent', { handle: 'ekogadgets', legal_name: 'Eko Gadgets Enterprises', category: 'online_retail', country: 'NG', email: 'sales@ekogadgets.example' });
  await call(`select knock.set_business_registration($1, $2, $3::jsonb) as r`, [U.innocent, EKO, JSON.stringify({ entity_type: 'business_name', registration_number: 'BN3349120' })]);
  await docs('innocent', EKO, ['registration_certificate', 'proof_of_address', 'representative_id']);
  await call(`select knock.add_business_director($1, $2, $3::jsonb) as r`, [U.innocent, EKO, JSON.stringify({ full_name: 'Innocent Eze', role_title: 'Proprietor', ownership_bps: 10000,
    nin: '10000000002', bvn: '20000000002', date_of_birth: '1991-09-02', phone: '+234 805 000 2211' })]);
  await call(`select knock.submit_business_verification($1, $2) as r`, [U.innocent, EKO]);

  // Sandbox log-ins (Supabase Auth in production). Shown on the login page.
  for (const [u, email] of [['chanor', 'chanor@mamaput.example'], ['mary', 'mary@mamaput.example'], ['innocent', 'innocent@ekogadgets.example']] as const) {
    await sb.auth.add(email, DEMO_PASSWORD, U[u]);
  }

  // ---- links
  const link = async (p: Record<string, unknown>) => (await call(`select knock.business_create_link($1, $2, $3::jsonb) as r`, [U.chanor, MAMA, JSON.stringify(p)])) as { id: string; slug: string };
  const trays = await link({ link_type: 'crypto', title: 'Party trays order', description: 'Pay for your party tray order. Include your order number.', currency: 'USDT', network: 'TRC20', amount_mode: 'flexible', min_amount: '5000000' });
  const catering = await link({ link_type: 'crypto', title: 'Wedding catering deposit', description: '50% deposit to confirm your catering date.', currency: 'USDT', network: 'TRC20', amount_mode: 'fixed', fixed_amount: '250000000', invoice_number: 'INV-2026-114' });
  const split = await link({ link_type: 'split', title: 'Owambe event crew', description: 'One link for the whole crew. Each payment is shared automatically.', currency: 'USDT', network: 'TRC20',
    amount_mode: 'flexible', split_method: 'percentage', target_amount: '2000000000', settlement_mode: 'each_payment',
    recipients: [{ recipient_id: MAMA, basis_points: 4000 }, { recipient_id: U.mary, basis_points: 3000 }, { recipient_id: U.innocent, basis_points: 2000 }, { recipient_id: U.favour, basis_points: 1000 }] });
  const old = await link({ link_type: 'crypto', title: 'Christmas hampers 2025', currency: 'USDT', network: 'TRC20', amount_mode: 'fixed', fixed_amount: '40000000' });

  const slugOf = async (id: string) => (await q<{ slug: string }>(`select slug from knock.payment_links where id = $1`, [id]))[0].slug;
  const r = rng(42);
  const customers = [['Ada Lovelace-Obi', 'ada@example.com'], ['Bayo Kareem', 'bayo@example.com'], ['Chioma Udeh', 'chioma@example.com'], ['Dami Alade', 'dami@example.com'],
    ['Efe Oghene', 'efe@example.com'], ['Funke Ade', 'funke@example.com'], ['Gbenga Shola', 'gbenga@example.com'], ['Halima Musa', 'halima@example.com'], ['Ifeanyi Nnaji', 'ifeanyi@example.com']];
  const backdatePayment = async (ref: string, days: number) => {
    const at = new Date(Date.now() - days * 86400_000 - Math.floor(r() * 36000_000)).toISOString();
    await q(`set session_replication_role = replica`);
    const pid = (await q<{ id: string }>(`update knock.payments set created_at = $2, updated_at = $2, verified_at = case when verified_at is null then null else $2::timestamptz end,
                  settled_at = case when settled_at is null then null else $2::timestamptz end where knock_reference = $1 returning id`, [ref, at]))[0].id;
    await q(`update knock.journal_entries set created_at = $2 where payment_id = $1`, [pid, at]);
    await q(`update knock.split_allocations set created_at = $2 where payment_id = $1`, [pid, at]);
    await q(`update knock.allocation_events set at = $2 where allocation_id in (select id from knock.split_allocations where payment_id = $1)`, [pid, at]);
    await q(`update knock.notifications set created_at = $2 where payment_id = $1`, [pid, at]);
    await q(`update knock.audit_log set at = $2 where payment_id = $1`, [pid, at]);
    await q(`set session_replication_role = default`);
  };
  const traysSlug = await slugOf(trays.id);
  for (let i = 0; i < 34; i++) {
    const c = customers[Math.floor(r() * customers.length)];
    const usdt = 15 + Math.floor(r() * 220);
    const failed = r() < 0.12;
    const res = await sb.sim.pay(traysSlug, String(usdt * 1_000_000), { name: c[0], email: c[1] }, failed ? 'failed' : 'succeeded');
    await backdatePayment(res.reference, 2 + Math.floor(r() * 85));
  }
  const cateringSlug = await slugOf(catering.id);
  for (const [d, c] of [[40, 0], [21, 3], [9, 7], [1, 1]] as const) {
    const res = await sb.sim.pay(cateringSlug, null, { name: customers[c][0], email: customers[c][1] });
    await backdatePayment(res.reference, d);
  }
  const splitSlug = await slugOf(split.id);
  for (const [d, amt, c] of [[12, 300, 4], [6, 450, 5], [2, 180, 6]] as const) {
    const res = await sb.sim.pay(splitSlug, String(amt * 1_000_000), { name: customers[c][0], email: customers[c][1] });
    await backdatePayment(res.reference, d);
  }
  const oldSlug = await slugOf(old.id);
  for (const d of [80, 78, 74]) { const res = await sb.sim.pay(oldSlug, null, { name: customers[2][0], email: customers[2][1] }); await backdatePayment(res.reference, d); }
  await call(`select knock.business_link_action($1, $2, $3, 'close') as r`, [U.chanor, MAMA, old.id]);
  // Today's activity
  await sb.sim.pay(traysSlug, '64000000', { name: customers[0][0], email: customers[0][1] });
  await sb.sim.pay(traysSlug, '22000000', { name: customers[8][0], email: customers[8][1] });

  // ---- Breet deposits to the business address
  const addr = await call(`select knock.business_request_address($1, $2, 'breet', 'usdt-trc20', 'USDT', 'TRC20') as r`, [U.chanor, MAMA]);
  await q(`select knock.record_deposit_address('breet', $1::jsonb)`, [JSON.stringify({ request_id: addr.address.id, provider_address_id: 'sbx-wallet-1', address: 'TQ7sbxKnockMamaPutTRC20a91F' })]);
  const backdateDeposit = async (trade: string, days: number) => {
    const at = new Date(Date.now() - days * 86400_000).toISOString();
    await q(`set session_replication_role = replica`);
    await q(`update knock.crypto_deposits set created_at = $2, updated_at = $2, completed_at = case when completed_at is null then null else $2::timestamptz end where provider_trade_id = $1`, [trade, at]);
    await q(`update knock.journal_entries set created_at = $2 where idempotency_key like 'crypto:breet:deposit:' || $1 || ':%'`, [trade, at]);
    await q(`update knock.webhook_events set received_at = $2, processed_at = $2, event_time = $2 where resource_id = $1`, [trade, at]);
    await q(`set session_replication_role = default`);
  };
  for (const [days, ngn, sc] of [[50, 420000, 'completed'], [33, 1250000, 'completed'], [15, 780000, 'completed'], [8, 2100000, 'completed'], [3, 655000, 'completed'], [1, 9000, 'below_minimum'], [0, 515000, 'confirming']] as const) {
    const d = await sb.sim.deposit(addr.address.id, sc, ngn);
    if (days) await backdateDeposit(d.trade, days);
  }

  // ---- payouts (maker-checker)
  const payout = async (who: string, amountNgn: number, note: string) =>
    call(`select knock.business_request_payout($1, $2, $3::jsonb) as r`, [U[who], MAMA, JSON.stringify({ kind: 'crypto', currency: 'NGN', amount_minor: String(amountNgn * 100), asset: 'USDT', network: 'TRC20', destination_address: 'TXsbxSupplierWallet77Qm2', note })]);
  const p1 = await payout('mary', 1_200_000, 'Supplier: Ikorodu farms (rice, oil)');
  const a1 = await call(`select knock.business_decide_payout($1, $2, $3, true, null) as r`, [U.chanor, MAMA, p1.id]);
  await sb.sim.withdrawal(a1.withdrawal_id, 'completed');
  const p2 = await payout('mary', 40_000, 'Gas refill');            // below the NGN 50,000 threshold: one approver
  await sb.sim.withdrawal(p2.withdrawal_id, 'processing');
  await payout('mary', 850_000, 'Event staff wages, December');      // waits for a second approver

  // A KYT hold arrives after the payouts above; while it is open, new payouts are paused.
  await sb.sim.deposit(addr.address.id, 'under_review', 3400000);

  // ---- risk, lists, alerts, support, reconciliation
  await q(`select knock.run_risk_rules(now() - interval '120 days')`);
  await call(`select knock.staff_add_list_entry($1, $2, $3::jsonb) as r`, [U.bola, AAL, JSON.stringify({ list: 'watch', subject_kind: 'email', value: 'gbenga@example.com', reason: 'Three card disputes reported by another merchant' })]);
  await call(`select knock.staff_add_list_entry($1, $2, $3::jsonb) as r`, [U.bola, AAL, JSON.stringify({ list: 'black', subject_kind: 'wallet_address', value: 'TXscamWalletReported0001', reason: 'Wallet named in a police fraud report', evidence: [{ type: 'report', ref: 'NPF/LAG/2026/0912' }] })]);
  await call(`select knock.business_open_ticket($1, $2, $3::jsonb) as r`, [U.mary, MAMA, JSON.stringify({ subject: 'Deposit under review: when will it clear?', category: 'crypto', priority: 'high', body: 'Our NGN 3.4m deposit shows under review. A customer is waiting on confirmation.' })]);
  const run = (await q<{ id: string }>(`insert into knock.provider_reconciliation_runs (provider, scope, trigger, status, pages_read, provider_records, discrepancies, finished_at)
                     values ('breet','full','scheduled','completed', 3, 14, 1, now()) returning id`))[0].id;
  await q(`insert into knock.provider_reconciliation_records (run_id, provider, check_name, subject_kind, subject_ref, expected, actual, fingerprint)
           values ($1, 'breet', 'missing_webhook', 'deposit', 'sbx-trade-recon01', '{"status":"completed","amountCredited":"210000"}', '{"knock_status":"not found"}', 'recon:sandbox:1')`, [run]);
  return { U, MAMA, STUDIO, EKO };
}
