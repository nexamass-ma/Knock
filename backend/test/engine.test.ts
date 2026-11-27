// Acceptance tests against a real Postgres running the migrations.
// Needs TEST_DATABASE_ADMIN_URL (default postgres://postgres@localhost:5433/postgres?host=/tmp).
import { after, before, describe, test } from 'node:test';
import assert from 'node:assert/strict';
import { readdirSync, readFileSync } from 'node:fs';
import pg from 'pg';
import { call, createDb, type Db } from '../src/db.ts';
import { SandboxCryptoProvider, SandboxNairaProvider } from '../src/providers/sandbox.ts';
import { PaymentLinksService } from '../src/service.ts';
import { previewPayment, splitAmount, type RecipientRule } from '../src/split.ts';

const ADMIN = process.env.TEST_DATABASE_ADMIN_URL ?? 'postgresql://postgres@localhost:5433/postgres?host=/tmp';
const DBNAME = 'knock_pl_test';
const N = (major: number) => BigInt(major) * 100n; // naira -> kobo

let db: Db;
let svc: PaymentLinksService;
const naira = new SandboxNairaProvider('whsec_naira_test');
const cryptoP = new SandboxCryptoProvider('whsec_crypto_test');
const U: Record<string, string> = {};

async function post(provider: SandboxNairaProvider | SandboxCryptoProvider, e: { body: string; headers: Record<string, string> }) {
  return svc.handleWebhook(provider.name, e.body, new Headers(e.headers));
}

before(async () => {
  const admin = new pg.Client({ connectionString: ADMIN });
  await admin.connect();
  await admin.query(`drop database if exists ${DBNAME}`);
  await admin.query(`create database ${DBNAME}`);
  await admin.end();
  const url = ADMIN.replace('/postgres?', `/${DBNAME}?`);
  const c = new pg.Client({ connectionString: url });
  await c.connect();
  const dir = new URL('../supabase/migrations/', import.meta.url);
  for (const f of readdirSync(dir).filter((f) => f.endsWith('.sql')).sort()) await c.query(readFileSync(new URL(f, dir), 'utf8'));
  for (const [u, tier, status] of [['chanor', 2, 'active'], ['mary', 1, 'active'], ['innocent', 1, 'active'], ['favour', 1, 'active'], ['david', 0, 'active'], ['ops', 3, 'active']] as const) {
    const r = await c.query(`insert into knock.profiles (username, display_name, kyc_tier, status) values ($1, $1, $2, $3) returning id`, [u, tier, status]);
    U[u] = r.rows[0].id;
  }
  await c.query(`insert into knock.staff_roles values ($1, 'finance'), ($1, 'compliance')`, [U.ops]);
  await c.end();
  db = createDb(url);
  svc = new PaymentLinksService({ db, providers: { [naira.name]: naira, [cryptoP.name]: cryptoP }, nairaProvider: naira.name, cryptoProvider: cryptoP.name, publicBaseUrl: 'https://pay.knock.test' });
});

after(async () => db?.close());

const split4 = (extra: Record<string, unknown> = {}) =>
  svc.createLink(U.chanor, {
    link_type: 'split', title: 'Team', currency: 'NGN', network: 'fiat', amount_mode: 'flexible',
    target_amount: N(500000).toString(), split_method: 'percentage',
    recipients: [
      { recipient_id: U.chanor, basis_points: 4000 }, { recipient_id: U.mary, basis_points: 3000 },
      { recipient_id: U.innocent, basis_points: 2000 }, { recipient_id: U.favour, basis_points: 1000 },
    ],
    ...extra,
  });

async function payNaira(slug: string, amount: bigint, opts: { paid?: bigint } = {}) {
  const c = await svc.checkout(slug, { amount: amount.toString(), method: 'bank_transfer', payer_email: 'p@x.com' }, 'ip' + Math.random());
  const r = await post(naira, naira.simulatePayment(c.session.providerReference, { amount: opts.paid }));
  return { ...c, result: r };
}

const allocs = (paymentId: string) =>
  db.query<{ username: string; net_share: string; gross_share: string; state: string }>(
    `select p.username, a.net_share, a.gross_share, a.state from knock.allocation_state a join knock.profiles p on p.id = a.recipient_id where a.payment_id = $1 order by a.gross_share desc`, [paymentId]);

const reconciled = async () => assert.deepEqual(await svc.reconcile(), []);

describe('split maths', () => {
  test('TS and SQL largest remainder agree', async () => {
    for (const [t, w] of [[100001n, [1n, 1n, 1n]], [N(100000), [4000n, 3000n, 2000n, 1000n]], [7n, [3n, 3n, 1n]], [999999n, [1n, 2n, 3n, 4n, 5n]]] as const) {
      const rows = await db.query<{ r: string[] }>('select knock.split_amount($1, $2::numeric[]) as r', [t.toString(), w.map(String)]);
      assert.deepEqual(rows[0].r.map(BigInt), splitAmount(t, [...w]));
    }
  });
});

describe('payment links', () => {
  test('1-2. fixed and flexible Naira links', async () => {
    const fixed = await svc.createLink(U.chanor, { link_type: 'naira', title: 'Tote', currency: 'NGN', amount_mode: 'fixed', fixed_amount: N(15000).toString() });
    const q = await call<any>(db.query, 'checkout_quote', fixed.slug, null);
    assert.equal(q.amount, Number(N(15000)));
    assert.equal(q.knock_fee, Number(N(225)));
    const flex = await svc.createLink(U.chanor, { link_type: 'naira', title: 'Tips', currency: 'NGN', amount_mode: 'flexible' });
    const p = await payNaira(flex.slug, N(2000));
    assert.equal(p.result, 'confirmed');
    const a = await allocs(p.payment_id);
    assert.equal(a[0].net_share, String(N(2000) - N(30)));
    await reconciled();
  });

  test('3. crypto link credits only after confirmations; wrong network rejected', async () => {
    const l = await svc.createLink(U.chanor, { link_type: 'crypto', title: 'Deposit', currency: 'USDT', network: 'TRC20', amount_mode: 'fixed', fixed_amount: '150000000' });
    const c = await svc.checkout(l.slug, { method: 'crypto' }, 'ip2');
    assert.ok(c.session.crypto?.address.startsWith('T'));
    assert.equal(await post(cryptoP, cryptoP.simulateChainTx(c.session.providerReference, { confirmations: 3 })), 'awaiting_confirmations');
    assert.equal((await allocs(c.payment_id)).length, 0);
    await assert.rejects(post(cryptoP, cryptoP.simulateChainTx(c.session.providerReference, { confirmations: 30, network: 'BEP20' })), /network mismatch/);
    assert.equal(await post(cryptoP, cryptoP.simulateChainTx(c.session.providerReference, { confirmations: 20, network: 'TRC20' })), 'confirmed');
    assert.equal((await allocs(c.payment_id))[0].net_share, String(150000000 - 1500000));
    await reconciled();
  });

  test('4-7. recipients by username, fixed and percentage allocation, total validation', async () => {
    const found = await svc.lookupUsername(U.chanor, '@Mary');
    assert.equal(found.username, 'mary');
    assert.equal(found.verified, true);
    await assert.rejects(svc.createLink(U.chanor, { link_type: 'split', title: 'x', currency: 'NGN', amount_mode: 'flexible', target_amount: '1000', split_method: 'fixed', recipients: [{ recipient_id: U.mary, allocated_amount: '900' }] }), /must add up/);
    await assert.rejects(svc.createLink(U.chanor, { link_type: 'split', title: 'x', currency: 'NGN', amount_mode: 'flexible', split_method: 'percentage', recipients: [{ recipient_id: U.mary, basis_points: 6000 }, { recipient_id: U.favour, basis_points: 5000 }] }), /more than 100/);
    await assert.rejects(svc.createLink(U.chanor, { link_type: 'split', title: 'x', currency: 'NGN', amount_mode: 'flexible', split_method: 'percentage', recipients: [{ recipient_id: U.david, basis_points: 10000 }] }), /verify/);
    await assert.rejects(svc.createLink(U.david, { link_type: 'naira', title: 'x', currency: 'NGN', amount_mode: 'flexible' }), /verify your account/);
    const fixed = await svc.createLink(U.chanor, { link_type: 'split', title: 'Fixed', currency: 'NGN', amount_mode: 'flexible', target_amount: N(500000).toString(), split_method: 'fixed', allocation_mode: 'remainder_to_creator', recipients: [{ recipient_id: U.mary, allocated_amount: N(150000).toString() }] });
    const rules = await db.query<{ allocated_amount: string; basis_points: number; is_creator_remainder: boolean }>(`select * from knock.split_recipients where link_id = $1 order by position`, [fixed.id]);
    assert.deepEqual(rules.map((r) => [r.allocated_amount, r.basis_points, r.is_creator_remainder]), [[N(150000).toString(), 3000, false], [N(350000).toString(), 7000, true]]);
  });

  test('8-10. brief example: each payment split independently, partial collection tracked', async () => {
    const l = await split4();
    const p1 = await payNaira(l.slug, N(100000));
    const fee = N(1500);
    const a1 = await allocs(p1.payment_id);
    assert.deepEqual(a1.map((a) => a.gross_share), [N(40000), N(30000), N(20000), N(10000)].map(String));
    assert.equal(a1.reduce((s, a) => s + BigInt(a.net_share), 0n), N(100000) - fee);
    const p2 = await payNaira(l.slug, N(50000));
    assert.deepEqual((await allocs(p2.payment_id)).map((a) => a.gross_share), [N(20000), N(15000), N(10000), N(5000)].map(String));
    const [d] = await svc.linkDetail(l.id);
    assert.equal(BigInt(d.collected), N(150000));
    await assert.rejects(call(db.query, 'checkout_quote', l.slug, N(400000).toString()), /remains/);
    await reconciled();
  });

  test('TS preview matches the SQL engine', async () => {
    const rules: RecipientRule[] = [4000, 3000, 2000, 1000].map((bp, i) => ({ recipientId: String(i), allocatedAmount: 0n, basisPoints: bp, isCreatorRemainder: false }));
    const prev = previewPayment({ method: 'percentage', rules, creatorId: '0', amount: N(100000), knockFee: N(1500), feeBearer: 'deduct' });
    const l = await split4();
    const p = await payNaira(l.slug, N(100000));
    assert.deepEqual((await allocs(p.payment_id)).map((a) => a.net_share), prev.map((s) => s.net.toString()));
  });

  test('11. duplicate and forged webhooks never double-credit', async () => {
    const l = await split4();
    const c = await svc.checkout(l.slug, { amount: N(100000).toString(), method: 'card' }, 'ip3');
    const evt = naira.simulatePayment(c.session.providerReference);
    assert.equal(await post(naira, evt), 'confirmed');
    assert.equal(await post(naira, evt), 'duplicate event ignored');
    assert.equal(await post(naira, naira.simulatePayment(c.session.providerReference)), 'duplicate'); // new event id, same payment
    await assert.rejects(svc.handleWebhook(naira.name, evt.body, new Headers({ 'x-knock-sandbox-signature': 't=1,v1=00' })), /signature/);
    assert.equal((await allocs(c.payment_id)).length, 4);
    await reconciled();
  });

  test('12. a failed recipient credit rolls back the whole split and retries', async () => {
    const l = await split4();
    await db.query(`update knock.profiles set status = 'frozen' where id = $1`, [U.mary]);
    const p = await payNaira(l.slug, N(100000));
    assert.equal((await allocs(p.payment_id)).length, 0);
    const [row] = await db.query(`select distribution_status, last_distribution_error from knock.payments where id = $1`, [p.payment_id]);
    assert.equal(row.distribution_status, 'failed_retrying');
    assert.match(row.last_distribution_error, /@mary/);
    await reconciled();
    await db.query(`update knock.profiles set status = 'active' where id = $1`, [U.mary]);
    await db.query(`update knock.payments set next_retry_at = now() where id = $1`, [p.payment_id]);
    assert.equal(await call(db.query, 'retry_due_distributions'), 1);
    assert.equal((await allocs(p.payment_id)).length, 4);
    await reconciled();
  });

  test('settlement modes: manual and on-target', async () => {
    const m = await split4({ settlement_mode: 'manual' });
    const p = await payNaira(m.slug, N(100000));
    assert.equal((await allocs(p.payment_id)).length, 0);
    await assert.rejects(db.tx((q) => call(q, 'distribute_held', m.id, U.mary)), /only the creator/);
    assert.deepEqual(await db.tx((q) => call(q, 'distribute_held', m.id, U.chanor)), { distributed: 1, failed: 0 });
    const t = await split4({ settlement_mode: 'on_target' });
    const a = await payNaira(t.slug, N(300000));
    assert.equal((await allocs(a.payment_id)).length, 0);
    await payNaira(t.slug, N(200000));
    assert.equal((await allocs(a.payment_id)).length, 4);
    const [l] = await svc.linkDetail(t.id);
    assert.equal(l.status, 'completed');
    await reconciled();
  });

  test('pending -> available on provider settlement', async () => {
    const l = await split4();
    const p = await payNaira(l.slug, N(100000));
    const [pay] = await db.query(`select provider_reference from knock.payments where id = $1`, [p.payment_id]);
    assert.equal(await post(naira, naira.settlementEvent(pay.provider_reference, N(1500))), 'settled');
    assert.ok((await allocs(p.payment_id)).every((a) => a.state === 'available'));
    await reconciled();
  });

  test('13. disputes hold shares; refunds and lost disputes reverse everything', async () => {
    const l = await split4();
    const p = await payNaira(l.slug, N(100000));
    const [pay] = await db.query(`select provider_reference from knock.payments where id = $1`, [p.payment_id]);
    assert.equal(await post(naira, naira.disputeEvent(pay.provider_reference, 'not received')), 'dispute opened');
    assert.ok((await allocs(p.payment_id)).every((a) => a.state === 'held'));
    const [d] = await db.query(`select id from knock.disputes where payment_id = $1`, [p.payment_id]);
    await db.tx((q) => call(q, 'resolve_dispute', d.id, 'lost', U.ops));
    assert.ok((await allocs(p.payment_id)).every((a) => a.state === 'reversed'));
    const p2 = await payNaira(l.slug, N(50000));
    await assert.rejects(db.tx((q) => call(q, 'reverse_payment', p2.payment_id, 'refund', 'x', U.mary)), /finance/);
    await db.tx((q) => call(q, 'reverse_payment', p2.payment_id, 'refund', 'customer refund', U.ops));
    await reconciled();
  });

  test('14. paused and expired links refuse payments; late payments are held, not lost', async () => {
    const l = await split4();
    const c = await svc.checkout(l.slug, { amount: N(1000).toString(), method: 'card' }, 'ip4');
    await db.tx((q) => call(q, 'set_link_status', l.id, U.chanor, 'pause', null));
    await assert.rejects(call(db.query, 'checkout_quote', l.slug, N(1000).toString()), /not accepting/);
    assert.equal(await post(naira, naira.simulatePayment(c.session.providerReference)), 'confirmed');
    const [row] = await db.query(`select distribution_status, last_distribution_error from knock.payments where id = $1`, [c.payment_id]);
    assert.equal(row.distribution_status, 'held');
    await db.tx((q) => call(q, 'set_link_status', l.id, U.chanor, 'resume', null));
    await db.query(`update knock.payment_links set expires_at = now() - interval '1 second' where id = $1`, [l.id]);
    assert.equal(await call(db.query, 'expire_links'), 1);
    await assert.rejects(call(db.query, 'checkout_quote', l.slug, N(1000).toString()), /not accepting/);
    await reconciled();
  });

  test('rules lock after first payment; amendments keep history', async () => {
    const l = await split4();
    const p1 = await payNaira(l.slug, N(100000));
    await assert.rejects(db.query(`delete from knock.split_recipients where link_id = $1`, [l.id]), /immutable/);
    await assert.rejects(db.query(`update knock.payment_links set fee_bearer = 'payer' where id = $1`, [l.id]), /locked/);
    const m = await db.tx((q) => call<any>(q, 'propose_amendment', l.id, U.chanor, 'Favour left', JSON.stringify([
      { recipient_id: U.chanor, basis_points: 5000 }, { recipient_id: U.mary, basis_points: 3000 }, { recipient_id: U.innocent, basis_points: 2000 }])));
    assert.equal(m.approvals_needed, 1);
    assert.equal(await db.tx((q) => call(q, 'decide_amendment', m.amendment_id, U.favour, 'approved')), 'applied');
    const p2 = await payNaira(l.slug, N(100000));
    assert.equal((await allocs(p1.payment_id)).length, 4);
    assert.equal((await allocs(p2.payment_id)).length, 3);
    await assert.rejects(db.query(`update knock.journal_lines set amount = 1`), /append-only/);
    await reconciled();
  });

  test('17. compliance review holds distribution; only staff can review', async () => {
    const l = await split4();
    await assert.rejects(db.tx((q) => call(q, 'set_link_status', l.id, U.chanor, 'review', null)), /compliance/);
    await db.tx((q) => call(q, 'set_link_status', l.id, U.ops, 'review', 'velocity'));
    await assert.rejects(call(db.query, 'checkout_quote', l.slug, N(1000).toString()), /not accepting/);
    await db.tx((q) => call(q, 'set_link_status', l.id, U.ops, 'clear_review', null));
    const [a] = await db.query(`select count(*)::int n from knock.audit_log where link_id = $1 and action like 'link.%review'`, [l.id]);
    assert.equal(a.n, 2);
  });

  test('amount mismatch is credited to the link but held and flagged', async () => {
    const l = await svc.createLink(U.chanor, { link_type: 'naira', title: 'Tote', currency: 'NGN', amount_mode: 'fixed', fixed_amount: N(15000).toString() });
    const p = await payNaira(l.slug, N(15000), { paid: N(14000) });
    const [row] = await db.query(`select status, distribution_status from knock.payments where id = $1`, [p.payment_id]);
    assert.deepEqual([row.status, row.distribution_status], ['succeeded', 'held']);
    const [f] = await db.query(`select rule from knock.risk_flags where payment_id = $1`, [p.payment_id]);
    assert.equal(f.rule, 'amount_mismatch');
    await reconciled();
  });

  test('18. full ledger reconciles and balances', async () => {
    await reconciled();
    const [s] = await db.query(`select coalesce(sum(amount), 0)::text s from knock.journal_lines`);
    assert.equal(s.s, '0');
  });
});
