// Knock Business acceptance tests against a real Postgres with ALL
// migrations applied. They drive the same knock.* functions the API and the
// dashboards call, and check the ledger itself after each money movement.
import { after, before, describe, test } from 'node:test';
import assert from 'node:assert/strict';
import { readdirSync, readFileSync } from 'node:fs';
import pg from 'pg';
import { createSender, deliverDue, isPrivateAddress, type Sender } from '../src/business/webhooks-out.ts';
import { verifyTimestamped } from '../src/webhooks.ts';

const ADMIN = process.env.TEST_DATABASE_ADMIN_URL ?? 'postgresql://postgres@localhost:5433/postgres?host=/tmp';
const DBNAME = 'knock_business_test';
let db: pg.Client;

const q = async <T = any>(sql: string, p: unknown[] = []) => (await db.query(sql, p)).rows as T[];
const one = async <T = any>(sql: string, p: unknown[] = []) => (await q<T>(sql, p))[0];
const fn = async <T = any>(name: string, ...args: unknown[]) =>
  (await one<{ r: T }>(`select knock.${name}(${args.map((_, i) => `$${i + 1}`).join(',')}) as r`, args)).r;
const fails = async (p: Promise<unknown>, code: string) => {
  await assert.rejects(p, (e: any) => {
    assert.match(String(e.message), new RegExp('^' + code + ':'), `expected ${code}, got ${e.message}`);
    return true;
  });
};
const bal = async (owner: string, purpose: string, cur: string) =>
  BigInt((await one(`select coalesce(sum(balance),0)::text b from knock.account_balances where owner_id=$1 and purpose=$2 and currency=$3`, [owner, purpose, cur])).b);

const U: Record<string, string> = {};
let BIZ = '';
const AAL2 = 'aal2';

async function person(username: string, tier = 1) {
  const r = await one(`insert into knock.profiles (username, display_name, kyc_tier) values ($1, $1, $2) returning id`, [username, tier]);
  U[username] = r.id;
  return r.id as string;
}

async function payLink(linkId: string, amountMinor: bigint, email: string, ref: string) {
  const l = await one(`select slug, currency, network from knock.payment_links where id=$1`, [linkId]);
  const intent = await fn('create_payment_intent', l.slug, l.currency === 'NGN' ? null : amountMinor.toString(),
    { provider: 'sandbox', provider_reference: ref, method: l.currency === 'NGN' ? 'bank_transfer' : 'crypto', payer_name: 'Payer ' + ref, payer_email: email });
  const paid = BigInt(intent.amount) + BigInt(intent.payer_fee);
  return fn('confirm_payment', 'sandbox', ref,
    { amount_paid: paid.toString(), currency: l.currency, network: l.network, tx_hash: 'tx-' + ref, confirmations: 30 });
}

before(async () => {
  const admin = new pg.Client({ connectionString: ADMIN });
  await admin.connect();
  await admin.query(`drop database if exists ${DBNAME} with (force)`);
  await admin.query(`create database ${DBNAME}`);
  await admin.end();
  db = new pg.Client({ connectionString: ADMIN.replace('/postgres?', `/${DBNAME}?`) });
  await db.connect();
  const dir = new URL('../supabase/migrations/', import.meta.url);
  for (const f of readdirSync(dir).filter((f) => f.endsWith('.sql')).sort()) await db.query(readFileSync(new URL(f, dir), 'utf8'));
  await db.query(`set search_path = knock, public`);
  for (const u of ['chanor', 'mary', 'innocent', 'favour', 'tolu']) await person(u);
  await person('kyc_amaka'); await person('risk_bola'); await person('risk_dayo'); await person('fin_ese');
  await q(`insert into knock.staff_roles (user_id, role) values ($1,'kyc_officer'),($2,'risk_officer'),($3,'risk_officer'),($4,'finance_manager')`,
    [U.kyc_amaka, U.risk_bola, U.risk_dayo, U.fin_ese]);
  // Provider asset config as a Breet sync would write it.
  await q(`insert into knock.provider_asset_configurations (provider, asset_id, symbol, network, kind, deposit_enabled, withdraw_enabled, raw)
           values ('breet','USDT_TRC20','USDT','TRC20','stablecoin',true,true,'{}')`);
});
after(async () => { await db?.end(); });

describe('onboarding and verification', () => {
  test('a person creates a business; it becomes its own account holder at tier 0', async () => {
    const r = await fn('create_business', U.chanor, {
      handle: 'mamaput', legal_name: 'Mama Put Foods Ltd', trading_name: 'Mama Put', category: 'food', country: 'NG',
      email: 'Hello@MamaPut.ng', phone: '+234 801 234 5678', website: 'https://mamaput.ng' });
    BIZ = r.id;
    const p = await one(`select kind, kyc_tier, status, display_name from knock.profiles where id=$1`, [BIZ]);
    assert.deepEqual(p, { kind: 'business', kyc_tier: 0, status: 'active', display_name: 'Mama Put' });
    const b = await one(`select owner_id, email, verification_status from knock.businesses where id=$1`, [BIZ]);
    assert.equal(b.owner_id, U.chanor);
    assert.equal(b.email, 'hello@mamaput.ng');
    assert.equal(b.verification_status, 'not_started');
    assert.equal((await one(`select role from knock.business_members where business_id=$1 and user_id=$2`, [BIZ, U.chanor])).role, 'owner');
  });

  test('handles are unique across people and businesses, and countries come from config', async () => {
    await fails(fn('create_business', U.mary, { handle: 'chanor', legal_name: 'X Ltd', category: 'food', country: 'NG', email: 'a@b.co' }), 'handle_taken');
    await fails(fn('create_business', U.mary, { handle: 'maryco', legal_name: 'X Ltd', category: 'food', country: 'US', email: 'a@b.co' }), 'unsupported_country');
  });

  test('an unverified business cannot collect or receive money', async () => {
    await fails(fn('business_create_link', U.chanor, BIZ, { link_type: 'crypto', title: 'Jollof', currency: 'USDT', network: 'TRC20', amount_mode: 'flexible' }), 'verification_required');
    await fails(fn('business_request_address', U.chanor, BIZ, 'breet', 'USDT_TRC20', 'USDT', 'TRC20'), 'verification_required');
  });

  test('a whitelist entry never bypasses verification', async () => {
    await fn('staff_add_list_entry', U.risk_bola, AAL2, { list: 'white', subject_kind: 'business', value: BIZ, reason: 'Trusted merchant for large_transaction alerts' });
    await fails(fn('business_create_link', U.chanor, BIZ, { link_type: 'crypto', title: 'Jollof', currency: 'USDT', network: 'TRC20', amount_mode: 'flexible' }), 'verification_required');
  });

  test('submission needs the configured documents and representatives', async () => {
    await fails(fn('submit_business_verification', U.chanor, BIZ), 'incomplete');
    for (const t of ['registration_certificate', 'proof_of_address', 'representative_id'])
      await fn('add_business_document', U.chanor, BIZ, { doc_type: t, file_name: t + '.pdf', storage_path: `biz/${BIZ}/${t}.pdf`, mime_type: 'application/pdf', size_bytes: 120000, sha256: 'a'.repeat(64) });
    await fails(fn('submit_business_verification', U.chanor, BIZ), 'incomplete');
    // A director without valid NIN/BVN is refused; full numbers are never stored.
    await fails(fn('add_business_director', U.chanor, BIZ, { full_name: 'Chanor Odigie', nin: '123', bvn: '22233344455', date_of_birth: '1990-04-02', phone: '+2348012345678' }), 'invalid_nin');
    const dir = await fn('add_business_director', U.chanor, BIZ, { full_name: 'Chanor Odigie', nin: '12345678901', bvn: '22233344455', date_of_birth: '1990-04-02', phone: '+2348012345678', ownership_bps: 10000 });
    const r = await one(`select to_jsonb(r)::text as j, nin_last4, bvn_last4, identity_check from knock.business_representatives r where id = $1`, [dir]);
    assert.deepEqual([r.nin_last4, r.bvn_last4, r.identity_check], ['8901', '4455', 'awaiting_provider']);
    assert.equal(r.j.includes('12345678901') || r.j.includes('22233344455'), false);
    assert.equal((await one(`select count(*)::int n from knock.audit_log where detail::text like '%12345678901%'`)).n, 0);
    // Registration details (entity type and CAC number) are required; MEMAT for a limited company.
    await fails(fn('submit_business_verification', U.chanor, BIZ), 'incomplete');
    await fails(fn('set_business_registration', U.chanor, BIZ, { entity_type: 'limited_company', registration_number: 'hello' }), 'bad_request');
    await fn('set_business_registration', U.chanor, BIZ, { entity_type: 'limited_company', registration_number: 'rc 1234567' });
    const ck = await fn('business_verification_checklist', BIZ);
    assert.ok(ck.documents.some((d: any) => d.doc_type === 'memat' && d.required && !d.provided));
    await fails(fn('submit_business_verification', U.chanor, BIZ), 'incomplete');
    await fn('add_business_document', U.chanor, BIZ, { doc_type: 'memat', file_name: 'memat.pdf', storage_path: `biz/${BIZ}/memat.pdf`, mime_type: 'application/pdf', size_bytes: 220000, sha256: 'b'.repeat(64) });
    assert.equal(await fn('submit_business_verification', U.chanor, BIZ), 'pending');
    await fails(fn('add_business_director', U.chanor, BIZ, { full_name: 'Second Director', nin: '12345678902', bvn: '22233344456', date_of_birth: '1988-01-01', phone: '+2348012345679' }), 'locked');
    const alert = await one(`select kind from knock.admin_alerts where subject_id=$1`, [BIZ]);
    assert.equal(alert.kind, 'kyc');
  });

  test('staff review needs MFA and the KYC permission; verification lifts the tier', async () => {
    await fails(fn('staff_review_business', U.kyc_amaka, 'aal1', BIZ, 'verified', null), 'mfa_required');
    await fails(fn('staff_review_business', U.fin_ese, AAL2, BIZ, 'verified', null), 'forbidden');
    await fails(fn('staff_review_business', U.kyc_amaka, AAL2, BIZ, 'info_required', ''), 'note_required');
    assert.equal(await fn('staff_review_business', U.kyc_amaka, AAL2, BIZ, 'verified', 'Documents match CAC'), 'verified');
    const p = await one(`select kyc_tier, status from knock.profiles where id=$1`, [BIZ]);
    assert.deepEqual(p, { kyc_tier: 2, status: 'active' });
    const hist = await q(`select to_status from knock.business_verification_events where business_id=$1 order by id`, [BIZ]);
    assert.deepEqual(hist.map((h) => h.to_status), ['not_started', 'pending', 'verified']);
    await assert.rejects(q(`update knock.business_verification_events set note='x' where business_id=$1`, [BIZ]), /append_only/);
  });
});

describe('team and permissions (checked in the database)', () => {
  test('owner invites members; roles decide what they can do', async () => {
    await fn('invite_business_member', U.chanor, BIZ, '@tolu', 'read_only');
    await fn('invite_business_member', U.chanor, BIZ, 'mary', 'finance_manager');
    // an invited member has no access until they accept
    assert.equal(await fn('business_can', U.mary, BIZ, 'dashboard.view'), false);
    await fn('respond_business_invite', U.mary, BIZ, true);
    await fn('respond_business_invite', U.tolu, BIZ, true);
    assert.equal(await fn('business_can', U.mary, BIZ, 'withdrawals.approve'), true);
    assert.equal(await fn('business_can', U.tolu, BIZ, 'links.create'), false);
    await fails(fn('business_create_link', U.tolu, BIZ, { link_type: 'crypto', title: 'x', currency: 'USDT', network: 'TRC20', amount_mode: 'flexible' }), 'forbidden');
    await fails(fn('business_overview', U.innocent, BIZ, '2020-01-01', '2100-01-01'), 'forbidden');
  });

  test('only the owner sets per-member overrides; members cannot change themselves', async () => {
    await fails(fn('update_business_member', U.mary, BIZ, U.tolu, { permissions: { 'links.create': true } }), 'forbidden');
    await fn('update_business_member', U.chanor, BIZ, U.tolu, { permissions: { 'reports.view': true, 'transactions.view': false } });
    assert.equal(await fn('business_can', U.tolu, BIZ, 'reports.view'), true);
    assert.equal(await fn('business_can', U.tolu, BIZ, 'transactions.view'), false);
    await fails(fn('update_business_member', U.chanor, BIZ, U.chanor, { role: 'read_only' }), 'forbidden');
  });
});

let LINK = '';
let SPLIT = '';
describe('payment links and smart split on the shared ledger', () => {
  test('Naira links stay disabled until the 9PSB integration exists', async () => {
    await fails(fn('business_create_link', U.chanor, BIZ, { link_type: 'naira', title: 'Catering', currency: 'NGN', network: 'fiat', amount_mode: 'fixed', fixed_amount: '5000000' }), 'feature_disabled');
  });

  test('a crypto link collection credits the BUSINESS, not the owner, net of the Knock fee', async () => {
    LINK = (await fn('business_create_link', U.chanor, BIZ, { link_type: 'crypto', title: 'Party trays', currency: 'USDT', network: 'TRC20', amount_mode: 'flexible' })).id;
    assert.equal((await one(`select created_by_member from knock.payment_links where id=$1`, [LINK])).created_by_member, U.chanor);
    const r = await payLink(LINK, 100_000_000n, 'ada@example.com', 'p1'); // 100 USDT
    assert.equal(r.result, 'confirmed');
    // allocated but not spendable until the provider settles the funds to Knock
    assert.equal(await bal(BIZ, 'user_pending', 'USDT'), 99_000_000n); // 1% fee
    assert.equal(await bal(BIZ, 'user_available', 'USDT'), 0n);
    await fn('settle_payment', 'sandbox', 'p1', '0', 'st-p1');
    assert.equal(await bal(BIZ, 'user_pending', 'USDT'), 0n);
    assert.equal(await bal(BIZ, 'user_available', 'USDT'), 99_000_000n);
    assert.equal(await bal(U.chanor, 'user_available', 'USDT'), 0n);
    // replaying the verified webhook is a no-op
    assert.equal((await fn('confirm_payment', 'sandbox', 'p1', { amount_paid: '100000000', currency: 'USDT', network: 'TRC20', tx_hash: 'tx-p1', confirmations: 30 })).result, 'duplicate');
    assert.equal(await bal(BIZ, 'user_available', 'USDT'), 99_000_000n);
  });

  test('smart split: 40/30/20/10 of a payment, recorded per recipient, never twice', async () => {
    const s = await fn('business_create_link', U.chanor, BIZ, {
      link_type: 'split', title: 'Event crew', currency: 'USDT', network: 'TRC20', amount_mode: 'flexible', split_method: 'percentage',
      recipients: [
        { recipient_id: BIZ, basis_points: 4000 }, { recipient_id: U.mary, basis_points: 3000 },
        { recipient_id: U.innocent, basis_points: 2000 }, { recipient_id: U.favour, basis_points: 1000 }] });
    SPLIT = s.id;
    await payLink(SPLIT, 100_000_000n, 'bayo@example.com', 'p2');
    const rows = await q(`select p.username, a.net_share::text from knock.split_allocations a join knock.profiles p on p.id=a.recipient_id where a.link_id=$1 order by a.net_share desc`, [SPLIT]);
    assert.deepEqual(rows.map((r) => [r.username, r.net_share]), [['mamaput', '39600000'], ['mary', '29700000'], ['innocent', '19800000'], ['favour', '9900000']]);
    await fn('settle_payment', 'sandbox', 'p2', '0', 'st-p2');
    await fn('confirm_payment', 'sandbox', 'p2', { amount_paid: '100000000', currency: 'USDT', network: 'TRC20', tx_hash: 'tx-p2', confirmations: 30 });
    assert.equal((await one(`select count(*)::int n from knock.split_allocations where link_id=$1`, [SPLIT])).n, 4);
  });

  test('pause and resume are permission-checked and scoped to the business', async () => {
    await fails(fn('business_link_action', U.tolu, BIZ, LINK, 'pause'), 'forbidden');
    assert.equal(await fn('business_link_action', U.chanor, BIZ, LINK, 'pause'), 'paused');
    assert.equal(await fn('business_link_action', U.chanor, BIZ, LINK, 'resume'), 'active');
  });
});

describe('Breet crypto deposits to a business', () => {
  test('pending does not credit; completed credits the business once with amountCredited', async () => {
    const a = await fn('business_request_address', U.chanor, BIZ, 'breet', 'USDT_TRC20', 'USDT', 'TRC20');
    assert.equal(a.address.user_id, BIZ);
    assert.equal(a.address.label, BIZ);
    await fn('record_deposit_address', 'breet', { request_id: a.address.id, provider_address_id: 'w1', address: 'TBizAddr1' });
    const before = await bal(BIZ, 'user_available', 'NGN');
    await fn('record_deposit_state', 'breet', 't1', { status: 'pending', destination_address: 'TBizAddr1', event_time: '2026-11-27T10:00:00Z', event_id: 'e1' });
    assert.equal(await bal(BIZ, 'user_available', 'NGN'), before);
    const done = { destination_address: 'TBizAddr1', amount_credited: '156000', currency: 'NGN', amount_in_usd: '999', event_time: '2026-11-27T10:05:00Z', event_id: 'e2' };
    assert.equal((await fn('complete_crypto_deposit', 'breet', 't1', done)).result, 'credited');
    assert.equal(await bal(BIZ, 'user_available', 'NGN'), before + 15_600_000n);
    await fn('complete_crypto_deposit', 'breet', 't1', done);
    assert.equal(await bal(BIZ, 'user_available', 'NGN'), before + 15_600_000n);
  });

  test('a flagged deposit is not credited and becomes a risk alert', async () => {
    await fn('record_deposit_state', 'breet', 't2', { status: 'under_review', destination_address: 'TBizAddr1', sub_status: 'kyt_hold', event_time: '2026-11-27T11:00:00Z', event_id: 'e3' });
    const f = await one(`select severity from knock.risk_flags where subject_kind='crypto_deposit' and user_id=$1`, [BIZ]);
    assert.equal(f.severity, 'high');
    assert.ok(await one(`select 1 from knock.admin_alerts where kind='risk'`));
  });
});

let PAYOUT = '';
describe('business payouts: maker-checker before any ledger reservation', () => {
  test('payouts stay off until the flag (and Breet) is ready', async () => {
    await fails(fn('business_request_payout', U.mary, BIZ, { kind: 'crypto', currency: 'NGN', amount_minor: '1000000', asset: 'USDT', network: 'TRC20', destination_address: 'TDest1' }), 'feature_disabled');
    await q(`update knock.feature_flags set enabled=true where key='business.crypto_payouts'`);
  });

  test('an open high-severity risk alert pauses payouts until staff resolve it', async () => {
    const r0 = await fn('business_request_payout', U.mary, BIZ, { kind: 'crypto', currency: 'NGN', amount_minor: '1000', asset: 'USDT', network: 'TRC20', destination_address: 'TDest1' });
    await fails(fn('business_decide_payout', U.chanor, BIZ, r0.id, true, null), 'account_restricted');
    await fn('business_decide_payout', U.chanor, BIZ, r0.id, false, 'testing');
    const f = await one(`select id from knock.risk_flags where user_id=$1 and severity='high' and status='open'`, [BIZ]);
    await fn('staff_update_risk_case', U.risk_bola, AAL2, f.id, { case_status: 'resolved', resolution_notes: 'KYT hold reviewed; deposit stays uncredited pending Breet' });
  });

  test('the requester cannot approve their own payout; a second member reserves funds', async () => {
    const r = await fn('business_request_payout', U.mary, BIZ, { kind: 'crypto', currency: 'NGN', amount_minor: '5000000', asset: 'USDT', network: 'TRC20', destination_address: 'TDest1' });
    PAYOUT = r.id;
    assert.equal(r.status, 'pending_approval');
    const avail = await bal(BIZ, 'user_available', 'NGN');
    await fails(fn('business_decide_payout', U.mary, BIZ, PAYOUT, true, null), 'second_approver_required');
    await fails(fn('business_decide_payout', U.tolu, BIZ, PAYOUT, true, null), 'forbidden');
    const ok = await fn('business_decide_payout', U.chanor, BIZ, PAYOUT, true, null);
    assert.equal(ok.status, 'approved');
    assert.equal(await bal(BIZ, 'user_available', 'NGN'), avail - 5_000_000n);
    assert.equal(await bal(BIZ, 'user_withdrawal_reserved', 'NGN'), 5_000_000n);
    const w = await one(`select status, user_id, created_by, approved_by from knock.provider_withdrawals where id=$1`, [ok.withdrawal_id]);
    assert.deepEqual(w, { status: 'reserved', user_id: BIZ, created_by: U.mary, approved_by: U.chanor });
    await fails(fn('business_decide_payout', U.chanor, BIZ, PAYOUT, true, null), 'bad_state');
  });

  test('cannot request more than the available balance', async () => {
    await fails(fn('business_request_payout', U.mary, BIZ, { kind: 'crypto', currency: 'NGN', amount_minor: '999999999999', asset: 'USDT', network: 'TRC20', destination_address: 'TDest1' }), 'insufficient_funds');
  });
});

describe('overview, transactions and admin read models come from records', () => {
  test('business overview matches the ledger and the transaction records', async () => {
    const o = await fn('business_overview', U.chanor, BIZ, '2020-01-01', '2100-01-01');
    const ngn = o.balances.find((b: any) => b.currency === 'NGN');
    assert.equal(BigInt(ngn.available), await bal(BIZ, 'user_available', 'NGN'));
    assert.equal(BigInt(ngn.reserved), 5_000_000n);
    const usdt = o.totals.find((t: any) => t.currency === 'USDT');
    assert.equal(usdt.collected, '200000000'); // two link payments, the split is not double counted
    assert.equal(usdt.fees, '2000000');
    assert.ok(o.counts.pending >= 2); // flagged deposit + reserved payout
    assert.equal(o.counts.customers, 2);
    assert.equal(o.pending_payouts, 0);
  });

  test('admin earnings keep customer, business and Knock money apart', async () => {
    const e = await fn('admin_earnings', U.fin_ese, AAL2, '2020-01-01', '2100-01-01');
    const pos = (bucket: string, cur: string) => BigInt(e.positions.find((p: any) => p.bucket === bucket && p.currency === cur)?.amount ?? 0);
    assert.equal(pos('knock_revenue_total', 'USDT'), 2_000_000n);
    assert.equal(pos('business_funds', 'USDT'), 99_000_000n + 39_600_000n);
    assert.equal(pos('customer_funds', 'USDT'), 29_700_000n + 19_800_000n + 9_900_000n);
    await fails(fn('admin_earnings', U.kyc_amaka, AAL2, '2020-01-01', '2100-01-01'), 'forbidden');
  });

  test('admin overview counts users and businesses separately', async () => {
    const o = await fn('admin_overview', U.risk_bola, AAL2, '2020-01-01', '2100-01-01');
    assert.equal(o.businesses, 1);
    assert.equal(o.users, 9);
    assert.equal(o.verified_businesses, 1);
  });

  test('every journal entry balances and history cannot be edited', async () => {
    const bad = await q(`select entry_id, currency from knock.journal_lines group by 1,2 having sum(amount) <> 0`);
    assert.equal(bad.length, 0);
    await assert.rejects(q(`update knock.journal_lines set amount = amount + 1`), /append_only/);
  });
});

describe('risk, lists and dual approval', () => {
  test('a blacklist entry needs evidence and a second staff member', async () => {
    await fails(fn('staff_add_list_entry', U.risk_bola, AAL2, { list: 'black', subject_kind: 'wallet_address', value: 'TBad1', reason: 'Linked to a scam report' }), 'evidence_required');
    const r = await fn('staff_add_list_entry', U.risk_bola, AAL2, { list: 'black', subject_kind: 'wallet_address', value: 'TBad1', reason: 'Linked to a scam report', evidence: [{ type: 'report', ref: 'NFIU-1' }] });
    assert.equal(r.status, 'pending_approval');
    assert.equal(await fn('is_blacklisted', 'wallet_address', 'tbad1'), false);
    await fails(fn('staff_decide_action', U.risk_bola, AAL2, r.approval_request, true, null), 'second_approver_required');
    await fn('staff_decide_action', U.risk_dayo, AAL2, r.approval_request, true, null);
    assert.equal(await fn('is_blacklisted', 'wallet_address', 'TBAD1'), true);
  });

  test('restricting a business needs two staff and stops its money actions', async () => {
    const req = await fn('staff_request_action', U.risk_bola, AAL2, 'business.restrict', BIZ, 'Chargeback pattern under investigation', JSON.stringify([{ type: 'case', ref: 'RISK-9' }]), {});
    await fails(fn('staff_decide_action', U.risk_bola, AAL2, req, true, null), 'second_approver_required');
    await fn('staff_decide_action', U.risk_dayo, AAL2, req, true, 'agreed');
    assert.equal((await one(`select status from knock.profiles where id=$1`, [BIZ])).status, 'frozen');
    await fails(fn('business_create_link', U.chanor, BIZ, { link_type: 'crypto', title: 'x', currency: 'USDT', network: 'TRC20', amount_mode: 'flexible' }), 'verification_required');
    const audit = await q(`select action from knock.audit_log where business_id=$1 and actor_kind='staff' order by id`, [BIZ]);
    assert.ok(audit.some((a) => a.action === 'admin_action.approved'));
  });

  test('risk rules raise each alert once', async () => {
    await q(`insert into knock.provider_withdrawals (user_id, provider, kind, status, currency, amount_minor, asset, destination_address, reserve_account_id)
             select $1, 'breet', 'crypto', s, 'NGN', 100, 'USDT', 'TX', knock.account($1, null, 'user_withdrawal_reserved', 'NGN') from unnest(array['rejected','rejected','not_submitted']) s`, [U.innocent]);
    const n1 = await fn('run_risk_rules');
    const n2 = await fn('run_risk_rules');
    assert.ok(n1 >= 1);
    assert.equal(n2, 0);
    assert.ok(await one(`select 1 from knock.risk_flags where rule='repeated_failed_withdrawals' and user_id=$1`, [U.innocent]));
  });

  test('closing a risk case needs notes', async () => {
    const f = await one(`select id from knock.risk_flags where rule='repeated_failed_withdrawals'`);
    await fails(fn('staff_update_risk_case', U.risk_bola, AAL2, f.id, { case_status: 'resolved' }), 'note_required');
    await fn('staff_update_risk_case', U.risk_bola, AAL2, f.id, { case_status: 'resolved', resolution_notes: 'Customer typo in address; confirmed by phone' });
    assert.equal((await one(`select status from knock.risk_flags where id=$1`, [f.id])).status, 'cleared');
  });

  test('staff roles cannot be given to a business profile', async () => {
    await assert.rejects(q(`insert into knock.staff_roles (user_id, role) values ($1, 'analyst')`, [BIZ]), /only be granted to people/);
  });
});

describe('dashboard API: fixed op catalogue over HTTP', () => {
  const SECRET = 'biz-test-secret';
  let base = '';
  let server: any;
  let apiDb: any;
  before(async () => {
    const { createDb } = await import('../src/db.ts');
    const { createBusinessHttp } = await import('../src/business/http.ts');
    apiDb = createDb(ADMIN.replace('/postgres?', `/${DBNAME}?`));
    server = createBusinessHttp({ db: apiDb, jwtSecret: SECRET, allowedOrigins: ['https://business.knock.test'] });
    await new Promise<void>((r) => server.listen(0, r));
    base = `http://127.0.0.1:${server.address().port}`;
  });
  after(async () => { server?.close(); await apiDb?.close(); });
  const call = async (name: string, input: Record<string, unknown>, opts: { user?: string; aal?: string; biz?: string } = {}) => {
    const { signTestJwt } = await import('../src/crypto/auth.ts');
    const headers: Record<string, string> = { 'content-type': 'application/json' };
    if (opts.user) headers.authorization = 'Bearer ' + signTestJwt(opts.user, SECRET, opts.aal ? { aal: opts.aal } : {});
    if (opts.biz) headers['x-business-id'] = opts.biz;
    const r = await fetch(`${base}/v1/ops/${name}`, { method: 'POST', headers, body: JSON.stringify({ input }) });
    return { status: r.status, body: (await r.json()) as any };
  };

  test('authentication, MFA and business scoping are enforced by the server', async () => {
    assert.equal((await call('me.businesses', {})).status, 401);
    assert.equal((await call('nope.op', {}, { user: U.chanor })).status, 404);
    const mine = await call('me.businesses', {}, { user: U.chanor });
    assert.equal(mine.status, 200);
    assert.equal(mine.body.result[0].id, BIZ);
    assert.equal((await call('biz.overview', { from: '2020-01-01', to: '2100-01-01' }, { user: U.innocent, biz: BIZ })).status, 403);
    assert.equal((await call('adm.overview', { from: '2020-01-01', to: '2100-01-01' }, { user: U.risk_bola })).body.error, 'mfa_required');
    assert.equal((await call('adm.overview', { from: '2020-01-01', to: '2100-01-01' }, { user: U.risk_bola, aal: 'aal2' })).status, 200);
    assert.equal((await call('adm.earnings', { from: '2020-01-01', to: '2100-01-01' }, { user: U.chanor, aal: 'aal2' })).status, 403);
  });

  test('a client cannot pass its own identity or SQL', async () => {
    const r = await call('biz.transactions', { holder_id: U.mary, sql: 'select 1' }, { user: U.chanor, biz: BIZ });
    assert.equal(r.status, 200);
    assert.ok(r.body.result.every((t: any) => t.reference));
    const internal = await call('biz.transaction', { id: 'not-a-uuid' }, { user: U.chanor, biz: BIZ });
    assert.ok(internal.status >= 400);
    assert.doesNotMatch(JSON.stringify(internal.body), /select|syntax|knock\./i);
  });

  test('every catalogue op runs against the real schema', async () => {
    const { OPS } = await import('../src/business/ops.ts');
    const linkSlug = (await one(`select slug from knock.payment_links where id=$1`, [LINK])).slug;
    const sample: Record<string, unknown> = { from: '2020-01-01', to: '2100-01-01', id: null, slug: linkSlug, amount: '1000000', username: 'mary', search: null };
    const reads = Object.entries(OPS).filter(([, op]) => !op.write);
    for (const [name, op] of reads) {
      const input: Record<string, unknown> = {};
      for (const a of op.args ?? []) input[a] = sample[a] ?? null;
      if (op.args?.includes('id')) input.id = name.startsWith('adm.holder') ? U.chanor : name === 'adm.business' ? BIZ : name === 'biz.link' ? LINK : '00000000-0000-0000-0000-000000000000';
      const who = op.scope === 'admin' ? { user: (await one(`select id from knock.profiles where username='root_admin'`))?.id, aal: 'aal2' } : { user: U.chanor, biz: BIZ };
      if (op.scope === 'admin' && !who.user) {
        const r0 = await one(`insert into knock.profiles (username, display_name, kyc_tier) values ('root_admin','Root',1) returning id`);
        await q(`insert into knock.staff_roles (user_id, role) values ($1,'super_admin')`, [r0.id]);
        who.user = r0.id;
      }
      const r = await call(name, input, who);
      assert.equal(r.status, 200, `${name}: ${JSON.stringify(r.body)}`);
    }
  });
});

describe('business webhooks: signed, retried, never to private addresses', () => {
  let EP = '';
  let SECRET = '';
  const wdb = { query: async (sql: string, p: unknown[] = []) => (await db.query(sql, p as any[])).rows } as any;
  const got: Array<{ url: string; headers: Record<string, string>; body: string }> = [];
  let reply = 200;
  const capture: Sender = async (url, headers, body) => { got.push({ url, headers, body }); return { ok: reply < 300, status: reply, error: reply < 300 ? null : 'HTTP ' + reply, ms: 3 }; };

  test('only https public URLs, known events, settings.manage; the secret is shown once and never listed', async () => {
    await fails(fn('business_webhook_create', U.chanor, BIZ, { url: 'http://shop.example.com/hook', events: ['payment.succeeded'] }), 'invalid_url');
    await fails(fn('business_webhook_create', U.chanor, BIZ, { url: 'https://127.0.0.1/hook', events: ['payment.succeeded'] }), 'invalid_url');
    await fails(fn('business_webhook_create', U.chanor, BIZ, { url: 'https://user:pw@shop.example.com/hook', events: ['payment.succeeded'] }), 'invalid_url');
    await fails(fn('business_webhook_create', U.chanor, BIZ, { url: 'https://shop.example.com/hook', events: ['nope'] }), 'invalid_events');
    await fails(fn('business_webhook_create', U.tolu, BIZ, { url: 'https://shop.example.com/hook', events: ['payment.succeeded'] }), 'forbidden');
    const r = await fn('business_webhook_create', U.chanor, BIZ, { url: 'https://shop.example.com/hook', events: ['payment.succeeded', 'payment.failed'], description: 'Shop' });
    EP = r.id; SECRET = r.secret;
    assert.match(SECRET, /^whsec_[0-9a-f]{64}$/);
    const listed = await one(`select to_jsonb(e) - 'secret' as j from knock.business_webhook_endpoints e where id = $1`, [EP]);
    assert.equal(listed.j.secret_hint, SECRET.slice(-4));
  });

  test('a verified payment queues one signed event; the receiver can verify it; duplicates are not re-queued', async () => {
    const l = LINK;
    await q(`update knock.payment_links set status = 'active' where id = $1`, [l]);
    await payLink(l, 5_000_000n, 'hook@example.com', 'wh1');
    await payLink(l, 5_000_000n, 'hook@example.com', 'wh1').catch(() => {}); // duplicate confirm
    const res = await deliverDue(wdb, capture);
    assert.equal(res.length, 1);
    assert.equal(res[0].outcome, 'delivered');
    const h = got[0];
    assert.equal(h.url, 'https://shop.example.com/hook');
    assert.ok(verifyTimestamped(h.body, h.headers['knock-signature'], SECRET));
    assert.equal(verifyTimestamped(h.body, h.headers['knock-signature'], 'whsec_wrong'), false);
    const body = JSON.parse(h.body);
    assert.equal(body.type, 'payment.succeeded');
    assert.equal(h.headers['knock-event-id'], body.id);
    assert.equal(body.data.amount, '5000000');
    assert.equal(body.data.link.title, 'Party trays');
    assert.equal(JSON.stringify(body).includes(SECRET), false);
    assert.equal((await deliverDue(wdb, capture)).length, 0);
  });

  test('failures retry with backoff and stop after 8 attempts; staff-free manual retry by the business', async () => {
    reply = 500;
    await fn('business_webhook_test', U.chanor, BIZ, EP);
    for (let i = 0; i < 8; i++) {
      await q(`update knock.business_webhook_deliveries set next_attempt_at = now() where status = 'retrying'`);
      await deliverDue(wdb, capture);
    }
    const d = await one(`select d.* from knock.business_webhook_deliveries d join knock.business_webhook_events e on e.id = d.event_id where e.type = 'test.ping'`);
    assert.equal(d.status, 'failed');
    assert.equal(d.attempts, 8);
    assert.equal(d.last_status_code, 500);
    reply = 200;
    await fn('business_webhook_retry', U.chanor, BIZ, d.id);
    assert.equal((await deliverDue(wdb, capture))[0].outcome, 'delivered');
  });

  test('rotating the secret changes the signature; disabled endpoints get nothing', async () => {
    const r = await fn('business_webhook_rotate', U.chanor, BIZ, EP);
    assert.notEqual(r.secret, SECRET);
    await fn('business_webhook_test', U.chanor, BIZ, EP);
    await deliverDue(wdb, capture);
    assert.ok(verifyTimestamped(got.at(-1)!.body, got.at(-1)!.headers['knock-signature'], r.secret));
    await fn('business_webhook_update', U.chanor, BIZ, EP, { status: 'disabled' });
    await fails(fn('business_webhook_test', U.chanor, BIZ, EP), 'not_found');
  });

  test('the sender refuses http, private and metadata addresses (SSRF guard)', async () => {
    assert.ok(isPrivateAddress('10.1.2.3') && isPrivateAddress('169.254.169.254') && isPrivateAddress('::1') && isPrivateAddress('100.64.0.1'));
    assert.equal(isPrivateAddress('102.89.1.1'), false);
    const s = createSender({ lookup: async () => [{ address: '10.0.0.5', family: 4 }] });
    assert.match((await s('https://evil.example.com/x', {}, '{}')).error!, /private/);
    assert.match((await createSender()('http://example.com/x', {}, '{}')).error!, /https/);
  });
});

describe('business-owner sign-up (light) and the web-app gate', () => {
  test('sign-up creates the person and an unverified business in one step; money stays locked', async () => {
    const auth = (await one(`select gen_random_uuid() as id`)).id; // the Supabase Auth user id
    await fails(fn('register_business_owner', auth, { full_name: 'A', business_name: 'Ada Bakes', email: 'ada@x.ng', phone: '+2348030000000' }), 'bad_request');
    const r = await fn('register_business_owner', auth, { full_name: 'Ada Obi', business_name: 'Ada Bakes & Co', email: 'Ada@AdaBakes.ng', phone: '+234 803 000 0000' });
    const b = await one(`select b.owner_id, b.verification_status, b.email, p.username, p.kind from knock.businesses b join knock.profiles p on p.id = b.id where b.id = $1`, [r.id]);
    assert.deepEqual(b, { owner_id: auth, verification_status: 'not_started', email: 'ada@adabakes.ng', username: 'ada_bakes_co', kind: 'business' });
    assert.equal((await one(`select kind from knock.profiles where id = $1`, [auth])).kind, 'person');
    assert.deepEqual(await fn('business_app_access', auth), { allowed: true, owner: true, invited: false });
    await fails(fn('register_business_owner', auth, { full_name: 'Ada Obi', business_name: 'Second', email: 'a@b.ng', phone: '+2348030000000' }), 'already_registered');
    await fails(fn('business_create_link', auth, r.id, { link_type: 'crypto', title: 'Cake', currency: 'USDT', network: 'TRC20', amount_mode: 'flexible' }), 'verification_required');
    // Another sign-up with the same business name gets its own handle.
    const r2 = await fn('register_business_owner', (await one(`select gen_random_uuid() as id`)).id, { full_name: 'Ada Obi', business_name: 'Ada Bakes & Co', email: 'ada2@x.ng', phone: '+2348030000001' });
    assert.notEqual(r2.handle, r.handle);
    assert.deepEqual(await fn('business_app_access', U.favour), { allowed: false, owner: false, invited: false });
  });
});

