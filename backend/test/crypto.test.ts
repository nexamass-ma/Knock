// Breet integration acceptance tests: real Postgres (all migrations), the
// real BreetAdapter over HTTP, Knock's real webhook HTTP endpoint, and a
// Breet-shaped test server (test/breet-mock.ts). No real provider is used.
import { after, before, describe, test } from 'node:test';
import assert from 'node:assert/strict';
import { readdirSync, readFileSync } from 'node:fs';
import type { AddressInfo } from 'node:net';
import pg from 'pg';
import { createDb, type Db } from '../src/db.ts';
import { signTestJwt } from '../src/crypto/auth.ts';
import { BreetAdapter } from '../src/crypto/breet/adapter.ts';
import { ConfigError, loadBreetConfig } from '../src/crypto/config.ts';
import { createCryptoHttp } from '../src/crypto/http.ts';
import { pgApiLogger } from '../src/crypto/apilog.ts';
import { PgRateGate } from '../src/crypto/ratelimit.ts';
import { Reconciler } from '../src/crypto/reconcile.ts';
import { CryptoService } from '../src/crypto/service.ts';
import { BreetMock } from './breet-mock.ts';

const ADMIN = process.env.TEST_DATABASE_ADMIN_URL ?? 'postgresql://postgres@localhost:5433/postgres?host=/tmp';
const DBNAME = 'knock_crypto_test';
const JWT = 'test-jwt-secret';
const ENV = {
  KNOCK_ENV: 'sandbox', BREET_SANDBOX_APP_ID: 'app_test', BREET_SANDBOX_APP_SECRET: 'sec_test', BREET_SANDBOX_WEBHOOK_SECRET: 'whsec_test',
  BREET_SANDBOX_WITHDRAWAL_PIN: '2468', BREET_SANDBOX_EXTRA_WEBHOOK_IPS: '127.0.0.1', BREET_TIMEOUT_MS: '400',
};

let db: Db;
let svc: CryptoService;
let mock: BreetMock;
let http: ReturnType<typeof createCryptoHttp>;
let base = '';
const U: Record<string, string> = {};
let bankAda = '';
let txAuthOk = true;

const q1 = async <T = any>(sql: string, p: unknown[] = []) => (await db.query<T>(sql, p))[0];
const bal = async (user: string, purpose: string, cur: string) =>
  BigInt((await q1<{ b: string }>(`select coalesce((select balance from knock.account_balances where owner_id = $1 and purpose = $2 and currency = $3), 0) as b`, [user, purpose, cur])).b);
const walletBal = async (cur: string) =>
  BigInt((await q1<{ b: string }>(`select coalesce((select balance from knock.account_balances b join knock.ledger_accounts a on a.id = b.account_id where a.code = $1), 0) as b`, ['provider_wallet:breet:' + cur])).b);
const deposit = (trade: string) => q1(`select * from knock.crypto_deposits where provider_trade_id = $1`, [trade]);
const N = (naira: number) => BigInt(Math.round(naira * 100));

async function deliverAndProcess(order?: number[]) {
  const s = await mock.deliver(order);
  await svc.drain();
  return s;
}
async function addressFor(user: string, asset = 'USDT_TRC20_TEST', extra: Record<string, unknown> = {}) {
  return svc.requestAddress(user, { asset_id: asset, ...extra });
}
let ref = 0;
async function trade(user: string, scenario: string, usd: number, opts: { asset?: string; currency?: string; addr?: any } = {}) {
  const a = opts.addr ?? (await addressFor(user, opts.asset));
  return mock.mockTrade({ walletAddress: a.address, asset: a.asset_id, amountInUSD: usd, cryptoReceived: '0.00025406', reference: 'r' + ++ref, txHash: 'tx' + ref, scenario, currency: opts.currency });
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
  for (const [u, tier] of [['ada', 2], ['bola', 2], ['chidi', 0], ['fin1', 3], ['fin2', 3], ['sup', 3]] as const) {
    U[u] = (await c.query(`insert into knock.profiles (username, display_name, kyc_tier) values ($1, $1, $2) returning id`, [u, tier])).rows[0].id;
  }
  await c.query(`insert into knock.staff_roles values ($1, 'finance_manager'), ($2, 'finance_manager'), ($3, 'support_agent')`, [U.fin1, U.fin2, U.sup]);
  bankAda = (await c.query(`insert into knock.bank_accounts (user_id, country, currency, provider_bank_id, provider_saved_account_id, bank_name, account_name, account_last4,
      account_number_enc, account_number_hash, verified_at) values ($1,'NG','NGN','39','6973aa8036d3c2b38fbaf3d9','Test Bank','ADA OBI','6789','enc:0123456789','h1', now()) returning id`, [U.ada])).rows[0].id;
  await c.end();

  db = createDb(url);
  const cfg = loadBreetConfig(ENV);
  mock = new BreetMock({ appId: 'app_test', appSecret: 'sec_test', pin: '2468', webhookSecret: 'whsec_test', webhookUrl: '' });
  await mock.start();
  cfg.baseUrl = mock.url;
  const provider = new BreetAdapter(cfg, new PgRateGate(db, 'breet'), pgApiLogger(db), { maxRateWaitMs: 3000 });
  svc = new CryptoService({ db, provider, decryptAccountNumber: (e) => e.replace(/^enc:/, '') });
  await svc.assertEnvironment(cfg.appIdFingerprint);
  http = createCryptoHttp({ svc, jwtSecret: JWT, trustedProxies: [], verifyTransactionAuth: async () => txAuthOk });
  await new Promise<void>((r) => http.listen(0, '127.0.0.1', r));
  base = `http://127.0.0.1:${(http.address() as AddressInfo).port}`;
  mock.o.webhookUrl = `${base}/webhooks/breet`;
  await svc.syncAssets();
});

after(async () => {
  await mock?.stop();
  await new Promise((r) => http?.close(r));
  await db?.close();
});

describe('configuration and environment safety', () => {
  test('production needs explicit confirmation and distinct keys', () => {
    assert.throws(() => loadBreetConfig({ ...ENV, KNOCK_ENV: 'production' }), ConfigError);
    assert.throws(() => loadBreetConfig({ KNOCK_ENV: 'production', BREET_PRODUCTION_CONFIRM: 'i-understand-real-funds', BREET_PRODUCTION_APP_ID: 'app_test',
      BREET_PRODUCTION_APP_SECRET: 'x', BREET_PRODUCTION_WEBHOOK_SECRET: 'y', BREET_SANDBOX_APP_ID: 'app_test' }), /identical/);
    // Sandbox never reads production variables.
    assert.throws(() => loadBreetConfig({ KNOCK_ENV: 'sandbox', BREET_PRODUCTION_APP_ID: 'a', BREET_PRODUCTION_APP_SECRET: 'b', BREET_PRODUCTION_WEBHOOK_SECRET: 'c' }), /BREET_SANDBOX_APP_ID/);
    assert.equal(loadBreetConfig({ ...ENV, BREET_SANDBOX_EXTRA_WEBHOOK_IPS: '10.0.0.1' }).webhookIps.includes('10.0.0.1'), true);
    assert.equal(loadBreetConfig({ KNOCK_ENV: 'production', BREET_PRODUCTION_CONFIRM: 'i-understand-real-funds', BREET_PRODUCTION_APP_ID: 'p',
      BREET_PRODUCTION_APP_SECRET: 'x', BREET_PRODUCTION_WEBHOOK_SECRET: 'y', BREET_SANDBOX_EXTRA_WEBHOOK_IPS: '10.0.0.1' }).webhookIps.includes('10.0.0.1'), false);
  });

  test('a sandbox database refuses a production service', async () => {
    const prodLike = { ...svc.provider, env: 'production', name: 'breet', health: svc.provider.health } as any;
    const other = new CryptoService({ db, provider: prodLike });
    await assert.rejects(other.assertEnvironment(null), /refusing to start/);
  });

  test('every request carries auth headers and the sandbox environment header; secrets are never logged', async () => {
    const r = mock.requests.at(-1)!;
    assert.equal(r.headers['x-app-id'], 'app_test');
    assert.equal(r.headers['x-breet-env'], 'sandbox');
    const logs = JSON.stringify(await db.query('select * from knock.provider_api_logs'));
    assert.ok(!logs.includes('sec_test') && !logs.includes('2468') && !logs.includes('whsec_test'));
  });
});

describe('assets', () => {
  test('synced from the provider, not hardcoded; disabled tokens and networks stay disabled', async () => {
    const rows = await db.query<any>('select asset_id, symbol, network, deposit_enabled, withdraw_enabled, kind from knock.provider_asset_configurations order by 1,3');
    const find = (s: string, n: string, w = true) => rows.find((r) => r.symbol === s && r.network === n && (w ? r.asset_id.startsWith('withdraw:') : !r.asset_id.startsWith('withdraw:')));
    assert.equal(find('USDT', 'TRC20', false).deposit_enabled, true);
    assert.equal(find('USDT', 'TRC20').withdraw_enabled, true);
    assert.equal(find('USDT', 'TON').withdraw_enabled, false);
    assert.equal(find('USDC', 'BASE').withdraw_enabled, false);
    assert.equal(find('BTC', '').kind, 'utxo');
  });
});

describe('deposit addresses', () => {
  test('response and fallback webhook describe one address; label is the Knock user id', async () => {
    const a = await addressFor(U.ada);
    assert.equal(a.status, 'Awaiting Deposit');
    await deliverAndProcess(); // trade.address.created fallback
    const rows = await db.query<any>('select * from knock.provider_wallet_addresses where user_id = $1', [U.ada]);
    assert.equal(rows.length, 1);
    assert.equal(rows[0].label, U.ada);
    assert.equal(mock.requests.find((r) => r.path.includes('generate-address'))!.body.label, U.ada);
    const again = await addressFor(U.ada);
    assert.equal(again.address, a.address);
    assert.equal(mock.requests.filter((r) => r.path.includes('generate-address')).length, 1);
  });

  test('if the API response is lost, the webhook activates the pending request (no duplicate)', async () => {
    mock.fault('POST /trades/sell/assets/:id/generate-address', { acceptThenFail: true });
    await assert.rejects(addressFor(U.bola), /could not create your deposit address/);
    const pending = await q1(`select * from knock.provider_wallet_addresses where user_id = $1`, [U.bola]);
    assert.equal(pending.status, 'requested');
    await deliverAndProcess();
    const rows = await db.query<any>('select * from knock.provider_wallet_addresses where user_id = $1', [U.bola]);
    assert.equal(rows.length, 1);
    assert.equal(rows[0].status, 'active');
    assert.ok(rows[0].address);
  });

  test('unverified customers cannot get an address', async () => {
    await assert.rejects(addressFor(U.chidi), /verify your identity/);
  });
});

describe('deposits', () => {
  test('pending never credits; completed credits amountCredited exactly once, even with duplicate webhooks', async () => {
    const before = await bal(U.ada, 'user_available', 'NGN');
    const t = await trade(U.ada, 'confirming', 20);
    await deliverAndProcess();
    assert.equal((await deposit(t.tradeId)).status, 'pending');
    assert.equal(await bal(U.ada, 'user_available', 'NGN'), before);

    const t2 = await trade(U.ada, 'completed', 20);
    const events = mock.outbox.length;
    await deliverAndProcess([...Array(events).keys(), ...Array(events).keys()]); // every event twice
    mock.outbox = [];
    const d = await deposit(t2.tradeId);
    assert.equal(d.status, 'completed');
    assert.equal(d.amount_credited, '31520'); // 20 USD * 1600 * 0.985, provider's figure
    assert.equal(await bal(U.ada, 'user_available', 'NGN'), before + N(31520));
    assert.equal(d.crypto_amount, '0.00025406');
    const dupes = await q1<{ n: string }>(`select count(*) n from knock.webhook_events where delivery_count > 1`);
    assert.ok(Number(dupes.n) >= events);
  });

  test('out-of-order: an older pending event never moves a completed deposit back', async () => {
    const t = await trade(U.ada, 'completed', 10);
    const n = mock.outbox.length;
    await deliverAndProcess([n - 1]); // completed arrives and is applied first
    await deliverAndProcess([0, 1]); // then the older pendings
    mock.outbox = [];
    const d = await deposit(t.tradeId);
    assert.equal(d.status, 'completed');
    const outcomes = await db.query<any>(`select result from knock.webhook_events where resource_id = $1 order by received_at`, [t.tradeId]);
    assert.match(outcomes[1].result, /ignored_terminal/);
  });

  test('below-minimum deposits aggregate: each deposit is processed once and credited once in total', async () => {
    const addr = await addressFor(U.ada);
    const before = await bal(U.ada, 'user_available', 'NGN');
    const small = await trade(U.ada, 'below_minimum', 4, { addr });
    await deliverAndProcess();
    const s = await deposit(small.tradeId);
    assert.equal(s.status, 'below_minimum');
    assert.equal(s.balance_remaining, '6');
    assert.equal(await bal(U.ada, 'user_available', 'NGN'), before);
    const top = await trade(U.ada, 'completed', 7, { addr });
    await deliverAndProcess();
    const t = await deposit(top.tradeId);
    assert.equal(t.status, 'completed');
    assert.equal((await deposit(small.tradeId)).status, 'completed');
    assert.equal((await deposit(small.tradeId)).sub_status, 'settled_in_batch');
    assert.equal(await bal(U.ada, 'user_available', 'NGN'), before + N(17336)); // (4+7) * 1600 * 0.985
  });

  test('failed on chain: never credited, customer told', async () => {
    const before = await bal(U.ada, 'user_available', 'NGN');
    const t = await trade(U.ada, 'failed_on_chain', 30);
    await deliverAndProcess();
    const d = await deposit(t.tradeId);
    assert.equal(d.status, 'failed');
    assert.equal(d.failure_reason, 'failed_on_chain');
    assert.equal(await bal(U.ada, 'user_available', 'NGN'), before);
    assert.ok(await q1(`select 1 from knock.notifications where user_id = $1 and title = 'Deposit failed'`, [U.ada]));
  });

  test('under review creates a risk record and is not spendable; rejection after review is terminal', async () => {
    const before = await bal(U.ada, 'user_available', 'NGN');
    const t = await trade(U.ada, 'under_review', 30);
    await deliverAndProcess();
    const d = await deposit(t.tradeId);
    assert.equal(d.status, 'failed');
    assert.equal(d.failure_reason, 'rejected_after_review');
    assert.ok(await q1(`select 1 from knock.risk_flags where subject_id = $1 and rule = 'provider_compliance_review'`, [d.id]));
    assert.equal(await bal(U.ada, 'user_available', 'NGN'), before);
    // Compliance reviews and clears the flag (otherwise withdrawals stay paused).
    await db.query(`update knock.risk_flags set status = 'cleared' where user_id = $1`, [U.ada]);
  });

  test('KYT hold stays under review until the provider completes it, then credits once', async () => {
    const before = await bal(U.bola, 'user_available', 'NGN');
    const t = await trade(U.bola, 'kyt_hold', 10);
    await deliverAndProcess();
    assert.equal((await deposit(t.tradeId)).status, 'under_review');
    assert.equal(await bal(U.bola, 'user_available', 'NGN'), before);
    mock.completeHeld(t.tradeId, 10);
    await deliverAndProcess();
    assert.equal((await deposit(t.tradeId)).status, 'completed');
    assert.equal(await bal(U.bola, 'user_available', 'NGN'), before + N(15760));
    // The open high-risk flag blocks withdrawals until compliance clears it.
    await assert.rejects(svc.createWithdrawal(U.bola, 'k-bola-blocked-000001', { kind: 'bank', currency: 'NGN', amount_minor: '100000', bank_account_id: bankAda }), /paused/);
    await db.query(`update knock.risk_flags set status = 'cleared' where user_id = $1`, [U.bola]);
  });

  test('wrong-asset deposits are marked', async () => {
    const t = await trade(U.ada, 'wrong_asset', 10);
    await deliverAndProcess();
    assert.equal((await deposit(t.tradeId)).is_wrong_asset, true);
  });

  test('a completed webhook the provider does not confirm is retried, not credited', async () => {
    const before = await bal(U.ada, 'user_available', 'NGN');
    const t = await trade(U.ada, 'confirming', 10);
    const real = mock.trades.get(t.tradeId)!;
    mock.outbox.push({ event: 'trade.completed', eventId: 'forged-1', eventTime: new Date().toISOString(), ...real, status: 'completed', amountCredited: 999999, currency: 'NGN' });
    await deliverAndProcess();
    assert.equal((await deposit(t.tradeId)).status, 'pending');
    assert.equal(await bal(U.ada, 'user_available', 'NGN'), before);
    const ev = await q1(`select status, last_error from knock.webhook_events where event_id = 'forged-1'`);
    assert.equal(ev.status, 'retrying');
    assert.match(ev.last_error, /provider still pending/);
  });

  test('a completed event whose amount differs from the provider record is held for manual review', async () => {
    const t = await trade(U.ada, 'completed', 10);
    const ev = mock.outbox.find((e) => e.event === 'trade.completed' && e.id === t.tradeId)!;
    ev.amountCredited = 1; // tampered amount
    await deliverAndProcess();
    assert.notEqual((await deposit(t.tradeId)).status, 'completed');
    assert.equal((await q1(`select status from knock.webhook_events where event_id = $1`, [ev.eventId])).status, 'failed');
  });
});

describe('webhook security', () => {
  test('wrong secret or unknown source IP is rejected and never processed', async () => {
    const t = await trade(U.ada, 'confirming', 10);
    const statuses = await mock.deliver(undefined, 'wrong-secret');
    assert.ok(statuses.every((s) => s === 401));
    const r = svc.provider.authenticateWebhook('{}', new Headers({ 'x-webhook-secret': 'whsec_test' }), '8.8.8.8');
    assert.deepEqual(r, { ok: false, reason: 'source_ip_not_allowed' });
    assert.equal(await deposit(t.tradeId), undefined);
    assert.ok(await q1(`select 1 from knock.webhook_events where status = 'rejected' and result like '%bad_secret%'`));
  });

  test('a client-supplied X-Forwarded-For is ignored unless the peer is a trusted proxy', async () => {
    const { clientIp } = await import('../src/crypto/auth.ts');
    assert.equal(clientIp('203.0.113.9', '46.101.201.155', []), '203.0.113.9');
    assert.equal(clientIp('10.0.0.2', '46.101.201.155, 10.0.0.2', ['10.0.0.2']), '46.101.201.155');
    assert.equal(clientIp('10.0.0.2', '46.101.201.155, 203.0.113.9', ['10.0.0.2']), '203.0.113.9');
  });

  test('requeue a failed event; resend needs provider permission', async () => {
    const failed = await q1<any>(`select event_id from knock.webhook_events where status = 'failed' limit 1`);
    await svc.requeueEvent(U.sup, failed.event_id);
    assert.equal((await q1(`select status from knock.webhook_events where event_id = $1`, [failed.event_id])).status, 'queued');
    await svc.drain();
    await assert.rejects(svc.resendFromProvider(U.sup, 'x'), /does not have webhook resend access/);
    mock.resendAllowed = true;
    const known = mock.delivered.find((e) => e.event === 'trade.completed')!;
    await svc.resendFromProvider(U.sup, known.id);
    assert.equal(mock.outbox.length, 1);
    await deliverAndProcess(); // duplicate of an applied event: acknowledged, no effect
  });
});

describe('withdrawals', () => {
  const usdBalance = async () => bal(U.ada, 'user_available', 'USD');
  before(async () => {
    await trade(U.ada, 'completed', 500, { currency: 'usd' }); // ADA now holds USD at Breet
    await deliverAndProcess();
  });

  test('crypto withdrawal: reserve, submit once with PIN and externalId, complete from verified webhook', async () => {
    const start = await usdBalance();
    const w = await svc.createWithdrawal(U.ada, 'k-ada-crypto-0000001', { kind: 'crypto', currency: 'USD', amount_minor: '2000', asset: 'USDT', network: 'TRC20', destination_address: 'TRecipientTronAddressHere0000000001' });
    assert.equal(w.status, 'Withdrawal Submitted');
    assert.equal(await usdBalance(), start - 2000n); // reserved
    const sent = mock.requests.filter((r) => r.path === '/payments/withdraw/address');
    assert.equal(sent.length, 1);
    assert.equal(sent[0].body.pin, '2468');
    assert.equal(sent[0].body.amount, 20);
    assert.ok(sent[0].body.externalId.startsWith('KWD-'));
    const walletBefore = await walletBal('USD');
    await deliverAndProcess();
    const row = await q1(`select * from knock.provider_withdrawals where id = $1`, [w.id]);
    assert.equal(row.status, 'completed');
    assert.equal(await bal(U.ada, 'user_withdrawal_reserved', 'USD'), 0n);
    assert.equal(await walletBal('USD'), walletBefore - 2000n);
    assert.equal(await usdBalance(), start - 2000n);
    // Replay of the same request returns the same withdrawal, no second POST.
    const again = await svc.createWithdrawal(U.ada, 'k-ada-crypto-0000001', { kind: 'crypto', currency: 'USD', amount_minor: '2000', asset: 'USDT', network: 'TRC20', destination_address: 'TRecipientTronAddressHere0000000001' });
    assert.equal(again.id, w.id);
    assert.equal(mock.requests.filter((r) => r.path === '/payments/withdraw/address').length, 1);
  });

  test('reversed only after the provider record confirms it; funds released then', async () => {
    const start = await usdBalance();
    const w = await svc.createWithdrawal(U.ada, 'k-ada-crypto-0000002', { kind: 'crypto', currency: 'USD', amount_minor: '1200', asset: 'USDT', network: 'TRC20', destination_address: 'TRecipientTronAddressHere0000000002' });
    const pid = (await q1(`select provider_withdrawal_id from knock.provider_withdrawals where id = $1`, [w.id])).provider_withdrawal_id;
    // Pretend the provider record is still processing when the reversed event arrives.
    const real = mock.withdrawals.get(pid)!;
    real.status = 'processing';
    await deliverAndProcess();
    assert.equal((await q1(`select status from knock.provider_withdrawals where id = $1`, [w.id])).status, 'processing');
    assert.equal(await usdBalance(), start - 1200n);
    real.status = 'reversed';
    await db.query(`update knock.webhook_events set next_attempt_at = now() where status = 'retrying'`);
    await svc.drain();
    assert.equal((await q1(`select status from knock.provider_withdrawals where id = $1`, [w.id])).status, 'reversed');
    assert.equal(await usdBalance(), start);
  });

  test('processing stays processing; a stale pending after completion is ignored', async () => {
    const w = await svc.createWithdrawal(U.ada, 'k-ada-crypto-0000003', { kind: 'crypto', currency: 'USD', amount_minor: '5000', asset: 'USDT', network: 'TRC20', destination_address: 'TRecipientTronAddressHere0000000003' });
    await deliverAndProcess();
    const row = await q1(`select * from knock.provider_withdrawals where id = $1`, [w.id]);
    assert.equal(row.status, 'processing');
    mock.advance(row.provider_withdrawal_id, 'completed');
    const stale = { ...mock.delivered.find((e) => e.id === row.provider_withdrawal_id && e.event === 'withdrawal.pending')!, eventId: 'stale-pending-1' };
    mock.outbox.push(stale);
    await deliverAndProcess();
    assert.equal((await q1(`select status from knock.provider_withdrawals where id = $1`, [w.id])).status, 'completed');
    assert.match((await q1(`select result from knock.webhook_events where event_id = 'stale-pending-1'`)).result, /ignored_(terminal|stale)/);
  });

  test('rejected: funds returned after verification', async () => {
    const start = await usdBalance();
    const w = await svc.createWithdrawal(U.ada, 'k-ada-crypto-0000004', { kind: 'crypto', currency: 'USD', amount_minor: '4321', asset: 'USDT', network: 'TRC20', destination_address: 'TRecipientTronAddressHere0000000004' });
    await deliverAndProcess();
    assert.equal((await q1(`select status from knock.provider_withdrawals where id = $1`, [w.id])).status, 'rejected');
    assert.equal(await usdBalance(), start);
  });

  test('bank withdrawal: masked destination, NGN sandbox outcomes, fee bearer user', async () => {
    const start = await bal(U.ada, 'user_available', 'NGN');
    const quote = await svc.quoteWithdrawal(U.ada, { kind: 'bank', currency: 'NGN', amount_minor: '2000000', bank_account_id: bankAda });
    assert.deepEqual(quote.destination, { bank_name: 'Test Bank', account_name: 'ADA OBI', account: '******6789' });
    const w = await svc.createWithdrawal(U.ada, 'k-ada-bank-000000001', { kind: 'bank', currency: 'NGN', amount_minor: '2000000', bank_account_id: bankAda });
    assert.equal(mock.requests.at(-1)!.path, '/payments/withdraw/bank/6973aa8036d3c2b38fbaf3d9');
    await deliverAndProcess();
    const row = await q1(`select * from knock.provider_withdrawals where id = $1`, [w.id]);
    assert.equal(row.status, 'completed');
    assert.equal(row.payout_amount, '19950');
    assert.equal(JSON.stringify(row.meta).includes('0123456789'), false); // account number never stored in clear
    assert.equal(await bal(U.ada, 'user_available', 'NGN'), start - 2000000n);
    // NGN <= 5,000 reverses in sandbox: released.
    const r = await svc.createWithdrawal(U.ada, 'k-ada-bank-000000002', { kind: 'bank', currency: 'NGN', amount_minor: '400000', bank_account_id: bankAda });
    await deliverAndProcess();
    assert.equal((await q1(`select status from knock.provider_withdrawals where id = $1`, [r.id])).status, 'reversed');
    assert.equal(await bal(U.ada, 'user_available', 'NGN'), start - 2000000n);
  });

  test('fee bearer business: the provider fee is Knock expense, recorded separately', async () => {
    const w = await svc.createWithdrawal(U.ada, 'k-ada-bank-000000003', { kind: 'bank', currency: 'NGN', amount_minor: '2100000', bank_account_id: bankAda });
    const row = await q1(`select provider_withdrawal_id from knock.provider_withdrawals where id = $1`, [w.id]);
    mock.withdrawals.get(row.provider_withdrawal_id)!.meta.feeBearer = 'business';
    for (const e of mock.outbox) if (e.id === row.provider_withdrawal_id) e.meta = { ...e.meta, feeBearer: 'business' };
    const exp0 = BigInt((await q1<{ b: string }>(`select coalesce((select balance from knock.account_balances b join knock.ledger_accounts a on a.id=b.account_id where a.code='provider_fee_expense:breet:NGN'),0) b`)).b);
    await deliverAndProcess();
    const exp1 = BigInt((await q1<{ b: string }>(`select coalesce((select balance from knock.account_balances b join knock.ledger_accounts a on a.id=b.account_id where a.code='provider_fee_expense:breet:NGN'),0) b`)).b);
    assert.equal(exp1 - exp0, 5000n); // NGN 50
  });

  test('provider refusals release the reservation: insufficient provider balance, duplicate, invalid destination, disabled token, no balance', async () => {
    const start = await bal(U.ada, 'user_available', 'NGN');
    const a = await svc.createWithdrawal(U.ada, 'k-ada-bank-000000004', { kind: 'bank', currency: 'NGN', amount_minor: '777700', bank_account_id: bankAda });
    assert.equal(a.status, 'Withdrawal Not Sent');
    assert.equal((await q1(`select last_error_code from knock.provider_withdrawals where id = $1`, [a.id])).last_error_code, 'insufficient_provider_balance');
    const dup = await svc.createWithdrawal(U.ada, 'k-ada-bank-000000005', { kind: 'bank', currency: 'NGN', amount_minor: '2000000', bank_account_id: bankAda });
    assert.equal(dup.status, 'Withdrawal Not Sent'); // same amount within 5 minutes
    assert.equal((await q1(`select last_error_code from knock.provider_withdrawals where id = $1`, [dup.id])).last_error_code, 'duplicate_withdrawal');
    assert.equal(await bal(U.ada, 'user_available', 'NGN'), start);
    await assert.rejects(svc.createWithdrawal(U.ada, 'k-ada-crypto-0000009', { kind: 'crypto', currency: 'USD', amount_minor: '1500', asset: 'USDT', network: 'TRC20', destination_address: 'short' }), /not valid/);
    await assert.rejects(svc.createWithdrawal(U.ada, 'k-ada-crypto-0000010', { kind: 'crypto', currency: 'USD', amount_minor: '1500', asset: 'USDC', network: 'BASE', destination_address: 'TRecipientTronAddressHere0000000010' }), /not available/);
    await assert.rejects(svc.createWithdrawal(U.ada, 'k-ada-crypto-0000011', { kind: 'crypto', currency: 'USD', amount_minor: '1500', asset: 'USDT', network: 'TON', destination_address: 'TRecipientTronAddressHere0000000011' }), /not available/);
    await assert.rejects(svc.createWithdrawal(U.chidi, 'k-chidi-bank-0000001', { kind: 'bank', currency: 'NGN', amount_minor: '1500', bank_account_id: bankAda }), /verify your identity/);
    await assert.rejects(svc.createWithdrawal(U.ada, 'k-ada-bank-000000006', { kind: 'bank', currency: 'NGN', amount_minor: '999999999', bank_account_id: bankAda }), /limit|enough/);
  });

  test('capacity error from the provider on a bank payout', async () => {
    const start = await bal(U.ada, 'user_available', 'NGN');
    const w = await svc.createWithdrawal(U.ada, 'k-ada-bank-000000007', { kind: 'bank', currency: 'NGN', amount_minor: '999900', bank_account_id: bankAda });
    assert.equal(w.status, 'Payout Temporarily Unavailable');
    assert.match(w.message!, /Your funds have not been debited/);
    assert.equal(await bal(U.ada, 'user_available', 'NGN'), start);
  });

  test('timeout: marked unknown, never resubmitted, resolved from provider records by externalId', async () => {
    mock.fault('POST /payments/withdraw/address', { delayMs: 800 });
    const w = await svc.createWithdrawal(U.ada, 'k-ada-crypto-0000006', { kind: 'crypto', currency: 'USD', amount_minor: '2100', asset: 'USDT', network: 'TRC20', destination_address: 'TRecipientTronAddressHere0000000006' });
    assert.equal((await q1(`select status from knock.provider_withdrawals where id = $1`, [w.id])).status, 'submission_unknown');
    await new Promise((r) => setTimeout(r, 600)); // provider finishes processing
    const posts = mock.requests.filter((r) => r.path === '/payments/withdraw/address').length;
    await svc.withdrawalSweep();
    assert.equal(mock.requests.filter((r) => r.path === '/payments/withdraw/address').length, posts); // no resubmission
    const row = await q1(`select * from knock.provider_withdrawals where id = $1`, [w.id]);
    assert.equal(row.status, 'pending');
    assert.ok(row.provider_withdrawal_id);
    await deliverAndProcess();
    assert.equal((await q1(`select status from knock.provider_withdrawals where id = $1`, [w.id])).status, 'completed');
  });

  test('HTTP 500 after acceptance is treated as unknown, not as failure', async () => {
    mock.fault('POST /payments/withdraw/address', { acceptThenFail: true });
    const w = await svc.createWithdrawal(U.ada, 'k-ada-crypto-0000007', { kind: 'crypto', currency: 'USD', amount_minor: '2200', asset: 'USDT', network: 'TRC20', destination_address: 'TRecipientTronAddressHere0000000007' });
    assert.equal((await q1(`select status from knock.provider_withdrawals where id = $1`, [w.id])).status, 'submission_unknown');
    await svc.resolveUnknownSubmissions();
    assert.equal((await q1(`select status from knock.provider_withdrawals where id = $1`, [w.id])).status, 'pending');
    await deliverAndProcess();
  });

  test('429: route paused for Retry-After, request re-queued and sent later', async () => {
    mock.fault('POST /payments/withdraw/address', { status: 429, body: 'Too Many Requests', headers: { 'retry-after': '1' } });
    const w = await svc.createWithdrawal(U.ada, 'k-ada-crypto-0000008', { kind: 'crypto', currency: 'USD', amount_minor: '2300', asset: 'USDT', network: 'TRC20', destination_address: 'TRecipientTronAddressHere0000000008' });
    assert.equal((await q1(`select status from knock.provider_withdrawals where id = $1`, [w.id])).status, 'reserved');
    assert.ok((await q1(`select paused_until from knock.provider_rate_limits where route_key = 'POST /payments/withdraw/address'`)).paused_until);
    await svc.withdrawalSweep(); // waits out the pause via the shared gate, then submits once
    assert.equal((await q1(`select status from knock.provider_withdrawals where id = $1`, [w.id])).status, 'pending');
    await deliverAndProcess();
  });

  test('GET 5xx and 429 are retried with backoff; 500 bodies without data are handled', async () => {
    mock.fault('GET /payments/supported-assets-info', { status: 500, body: '{"success":false,"message":"oops"}' }, { status: 429, body: '', headers: { 'retry-after': '1' } });
    assert.ok((await svc.health()).ok);
  });

  test('distributed rate gate enforces the 5/min network-fee limit across callers', async () => {
    const gate = new PgRateGate(db, 'breet-limit-test');
    const waits = [];
    for (let i = 0; i < 6; i++) waits.push(await gate.take('POST /payments/estimate-network-fee'));
    assert.deepEqual(waits.slice(0, 5), [0, 0, 0, 0, 0]);
    assert.ok(waits[5] > 0);
  });
});

describe('automatic settlement', () => {
  let addr: any;
  before(async () => {
    addr = await svc.requestAddress(U.ada, { asset_id: 'BTC_TEST', bank_account_id: bankAda, auto_settlement: true });
    await deliverAndProcess();
    const gen = mock.requests.filter((r) => r.path.includes('BTC_TEST/generate-address')).at(-1)!;
    assert.equal(gen.body.bankId, '39');
    assert.equal(gen.body.accountNumber, '0123456789');
    assert.equal(gen.body.autoSettlement, true);
  });

  test('settled deposit: never spendable, closed by the provider payout', async () => {
    const before = await bal(U.ada, 'user_available', 'NGN');
    const t = await trade(U.ada, 'completed', 10, { addr });
    await deliverAndProcess();
    const s = await q1(`select * from knock.settlements where trade_id = $1`, [t.tradeId]);
    assert.equal(s.status, 'completed');
    assert.equal(await bal(U.ada, 'user_available', 'NGN'), before);
    assert.equal(await bal(U.ada, 'user_settlement_reserved', 'NGN'), 0n);
  });

  test('settlement failed: deposit stays completed, exception opened, recovery needs two finance managers and a balance check', async () => {
    mock.autoSettleFails = true;
    const before = await bal(U.ada, 'user_available', 'NGN');
    const t = await trade(U.ada, 'completed', 400, { addr }); // NGN 630,400: above the dual-approval threshold
    await deliverAndProcess();
    mock.autoSettleFails = false;
    const d = await deposit(t.tradeId);
    assert.equal(d.status, 'completed');
    const ex = await q1(`select * from knock.settlement_exceptions where trade_id = $1`, [t.tradeId]);
    assert.equal(ex.status, 'open');
    assert.equal(ex.reason, 'settlement_not_started');
    assert.equal(await bal(U.ada, 'user_available', 'NGN'), before); // not spendable
    assert.equal(await bal(U.ada, 'user_settlement_reserved', 'NGN'), N(630400));
    const act = await q1(`select * from knock.customer_crypto_activity where id = $1`, [d.id]);
    assert.equal(act.customer_status, 'Bank Payout Delayed');

    await assert.rejects(svc.requestRecovery(U.sup, ex.id, 'settlement_replacement', 'retry'), /permission/);
    const req = await svc.requestRecovery(U.fin1, ex.id, 'settlement_replacement', 'retry payout');
    assert.equal(req.needs_second_approver, true);
    await assert.rejects(svc.approveRecovery(U.fin1, req.request_id), /different finance manager/);
    await assert.rejects(svc.approveRecovery(U.fin2, req.request_id), /balance/);
    const r = await svc.approveRecovery(U.fin2, req.request_id, { balance_confirmed: true });
    assert.equal(r.status, 'pending');
    const w = await q1(`select * from knock.provider_withdrawals where id = $1`, [r.withdrawal_id]);
    assert.equal(w.purpose, 'settlement_replacement');
    assert.equal(w.trade_id, t.tradeId);
    await deliverAndProcess();
    assert.equal((await q1(`select status from knock.settlement_exceptions where id = $1`, [ex.id])).status, 'resolved');
    assert.equal((await q1(`select status from knock.settlements where trade_id = $1`, [t.tradeId])).status, 'replaced');
    assert.equal(await bal(U.ada, 'user_settlement_reserved', 'NGN'), 0n);
    assert.equal(await bal(U.ada, 'user_available', 'NGN'), before); // never counted twice
    await assert.rejects(svc.requestRecovery(U.fin1, ex.id, 'settlement_replacement', 'again'), /already resolved/);
  });

  test('a failed settlement can instead be released to the customer wallet (below threshold: one approver)', async () => {
    mock.autoSettleFails = true;
    const before = await bal(U.ada, 'user_available', 'NGN');
    const t = await trade(U.ada, 'completed', 10, { addr });
    await deliverAndProcess();
    mock.autoSettleFails = false;
    const ex = await q1(`select * from knock.settlement_exceptions where trade_id = $1`, [t.tradeId]);
    const req = await svc.requestRecovery(U.fin1, ex.id, 'settlement_release', 'customer asked for wallet credit');
    assert.equal(req.needs_second_approver, false);
    await svc.approveRecovery(U.fin1, req.request_id);
    assert.equal(await bal(U.ada, 'user_available', 'NGN'), before + N(15760));
    assert.equal((await q1(`select status from knock.settlements where trade_id = $1`, [t.tradeId])).status, 'released_to_wallet');
  });
});

describe('reconciliation', () => {
  test('finds a completed provider deposit that Knock never received, across pages, without changing balances', async () => {
    const t = await trade(U.ada, 'completed', 10);
    mock.outbox = []; // webhooks lost
    const before = await bal(U.ada, 'user_available', 'NGN');
    const rec = new Reconciler(db, svc.provider, { pageSize: 2 });
    const r1 = await rec.run('manual', U.fin1);
    assert.ok(r1.pages > 3);
    assert.ok(r1.discrepancies.some((f) => f.check === 'deposit_completed_not_credited' && f.ref === t.tradeId));
    assert.equal(await bal(U.ada, 'user_available', 'NGN'), before);
    const r2 = await rec.run('scheduled');
    assert.equal(r2.newRecords, 0); // same open records, not duplicated
    const open = await db.query(`select * from knock.provider_reconciliation_records where subject_ref = $1 and status = 'open'`, [t.tradeId]);
    assert.equal(open.length, 1);
    // The ledger itself stays balanced.
    assert.deepEqual(r1.discrepancies.filter((f) => f.check.startsWith('ledger_') || f.check.endsWith('_mismatch') && f.kind === 'ledger'), []);
  });
});

describe('customer API', () => {
  const call = (path: string, init: RequestInit = {}, user = U.ada) =>
    fetch(base + path, { ...init, headers: { authorization: `Bearer ${signTestJwt(user, JWT)}`, 'content-type': 'application/json', ...(init.headers ?? {}) } });

  test('requires a valid session', async () => {
    assert.equal((await fetch(base + '/v1/crypto/activity')).status, 401);
    assert.equal((await fetch(base + '/v1/crypto/activity', { headers: { authorization: `Bearer ${signTestJwt(U.ada, 'wrong')}` } })).status, 401);
  });

  test('activity shows customer statuses only, never provider ids or payloads', async () => {
    const r = await (await call('/v1/crypto/activity')).json();
    assert.ok(r.items.length > 0);
    const text = JSON.stringify(r);
    for (const t of mock.trades.keys()) assert.ok(!text.includes(t));
    assert.ok(r.items.some((i: any) => i.customer_status === 'Deposit Completed'));
    assert.ok(r.items.some((i: any) => i.customer_status === 'Withdrawal Reversed'));
  });

  test('withdrawal needs transaction authorisation and an idempotency key', async () => {
    txAuthOk = false;
    const body = JSON.stringify({ kind: 'crypto', currency: 'USD', amount_minor: '1600', asset: 'USDT', network: 'TRC20', destination_address: 'TRecipientTronAddressHere0000000020' });
    assert.equal((await call('/v1/withdrawals', { method: 'POST', body, headers: { 'idempotency-key': 'k-http-000000000001' } })).status, 403);
    txAuthOk = true;
    assert.equal((await call('/v1/withdrawals', { method: 'POST', body })).status, 400);
    const ok = await call('/v1/withdrawals', { method: 'POST', body, headers: { 'idempotency-key': 'k-http-000000000001' } });
    assert.equal(ok.status, 200);
    const j = await ok.json();
    assert.equal(j.withdrawal.status, 'Withdrawal Submitted');
    assert.equal(JSON.stringify(j).includes('provider'), false);
    await deliverAndProcess();
  });
});

describe('hosted checkout (payment links, one Breet address per payment)', () => {
  let slug = '';
  const open = async (body: Record<string, unknown>) => {
    const r = await fetch(`${base}/v1/checkout/${slug}`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(body) });
    return { status: r.status, body: await r.json() as any };
  };
  const status = async (id: string) => (await q1<{ r: any }>(`select knock.checkout_status($1) as r`, [id])).r;
  const payTo = (addr: string, scenario: string, crypto: string) =>
    mock.mockTrade({ walletAddress: addr, asset: 'USDT_TRC20_TEST', amountInUSD: Number(crypto), cryptoReceived: crypto, reference: 'ck' + ++ref, txHash: 'cktx' + ref, scenario });

  before(async () => {
    const l = await q1<{ r: any }>(`select knock.create_payment_link($1, $2::jsonb) as r`, [U.ada, JSON.stringify({
      link_type: 'crypto', title: 'Ankara dress', currency: 'USDT', network: 'TRC20', amount_mode: 'fixed', fixed_amount: '25000000' })]);
    slug = (await q1<{ slug: string }>(`select slug from knock.payment_links where id = $1`, [l.r.id ?? l.r.link_id])).slug;
    mock.outbox = [];
  });

  test('opening a checkout asks Breet for an address labelled with the payment reference; the page sees only public fields', async () => {
    const bad = await open({ payer_name: 'F', payer_email: 'nope' });
    assert.equal(bad.status, 400);
    const r = await open({ payer_name: 'Fatima Bello', payer_email: 'Fatima@Example.com' });
    assert.equal(r.status, 200, JSON.stringify(r.body));
    const s = await status(r.body.payment_id);
    assert.equal(s.status, 'pending');
    assert.equal(s.total, '25000000');
    assert.match(s.address, /^T/);
    assert.ok(new Date(s.expires_at) > new Date());
    const call = mock.requests.filter((x) => x.path.includes('generate-address')).at(-1)!;
    assert.equal(call.body.label, s.reference.replace('KPY', 'KPY') && (await q1<any>(`select provider_reference from knock.payments where id = $1`, [r.body.payment_id])).provider_reference);
    assert.equal(s.payer_name, 'Fatima Bello');
    assert.equal(JSON.stringify(s).includes('provider_reference'), false);
    await deliverAndProcess(); // trade.address.created for the same address: no duplicate row
    assert.equal(Number((await q1<any>(`select count(*) n from knock.provider_wallet_addresses where payment_id = $1`, [r.body.payment_id])).n), 1);
  });

  test('pending shows as confirming and credits nothing; completed confirms the payment once, even with duplicate webhooks', async () => {
    const r = await open({ payer_name: 'Fatima Bello', payer_email: 'f@example.com' });
    const s0 = await status(r.body.payment_id);
    const before = await bal(U.ada, 'user_pending', 'USDT') + await bal(U.ada, 'user_available', 'USDT');
    payTo(s0.address, 'confirming', '25');
    await deliverAndProcess();
    const s1 = await status(r.body.payment_id);
    assert.equal(s1.status, 'confirming');
    assert.equal(s1.received, '25000000');
    assert.equal(await bal(U.ada, 'user_pending', 'USDT') + await bal(U.ada, 'user_available', 'USDT'), before);

    const r2 = await open({ payer_name: 'Fatima Bello', payer_email: 'f@example.com' });
    const a2 = (await status(r2.body.payment_id)).address;
    payTo(a2, 'completed', '25');
    const n = mock.outbox.length;
    await deliverAndProcess([...Array(n).keys(), ...Array(n).keys()]);
    mock.outbox = [];
    const s2 = await status(r2.body.payment_id);
    assert.equal(s2.status, 'succeeded');
    assert.equal(s2.under_review, false);
    // No wallet deposit was created: the money belongs to the payment.
    assert.equal(Number((await q1<any>(`select count(*) n from knock.crypto_deposits d join knock.provider_wallet_addresses a on a.id = d.address_id where a.payment_id is not null`)).n), 0);
    const p = await q1<any>(`select gross_paid, settlement_currency, settlement_amount from knock.payments where id = $1`, [r2.body.payment_id]);
    assert.equal(p.gross_paid, '25000000');
    assert.equal(p.settlement_currency, 'NGN');
    const credited = await bal(U.ada, 'user_pending', 'USDT') + await bal(U.ada, 'user_available', 'USDT');
    assert.equal(credited - before, 24_750_000n); // 25 USDT less Knock's 1% fee, once
  });

  test('an underpayment is recorded at the amount received and held for review, never at the amount due', async () => {
    const r = await open({ payer_name: 'Tunde', payer_email: 't@example.com' });
    payTo((await status(r.body.payment_id)).address, 'completed', '20');
    await deliverAndProcess();
    const s = await status(r.body.payment_id);
    assert.equal(s.status, 'succeeded');
    assert.equal(s.under_review, true);
    const f = await q1<any>(`select detail from knock.risk_flags where payment_id = $1 and rule = 'amount_mismatch'`, [r.body.payment_id]);
    assert.deepEqual([f.detail.expected, f.detail.received], [25000000, 20000000]);
  });

  test('flagged by Breet: held, nothing credited; deleted after review: failed and terminal', async () => {
    const r = await open({ payer_name: 'Kemi', payer_email: 'k@example.com' });
    payTo((await status(r.body.payment_id)).address, 'under_review', '25');
    const idx = (t: string) => mock.outbox.findIndex((e: any) => e.event === t);
    await deliverAndProcess([idx('trade.address.created'), idx('trade.flagged')]);
    let s = await status(r.body.payment_id);
    assert.equal(s.held, true);
    assert.notEqual(s.status, 'succeeded');
    await deliverAndProcess([idx('trade.deleted')]);
    mock.outbox = [];
    s = await status(r.body.payment_id);
    assert.equal(s.status, 'failed');
    assert.equal(s.held, false);
  });

  test('expired checkouts expire; a late transfer is still matched and confirmed', async () => {
    const r = await open({ payer_name: 'Late Payer', payer_email: 'l@example.com' });
    await db.query(`update knock.payments set quote_expires_at = now() - interval '1 minute' where id = $1`, [r.body.payment_id]);
    await db.query(`select knock.expire_checkouts()`);
    assert.equal((await status(r.body.payment_id)).status, 'expired');
    payTo((await status(r.body.payment_id)).address, 'completed', '25');
    await deliverAndProcess();
    assert.equal((await status(r.body.payment_id)).status, 'succeeded');
  });

  test('Naira links have no checkout yet, and a paused link refuses new checkouts', async () => {
    await db.query(`update knock.payment_links set status = 'paused' where slug = $1`, [slug]);
    const r = await open({ payer_name: 'Ngozi', payer_email: 'n@example.com' });
    assert.equal(r.status, 400);
    assert.equal(r.body.error, 'link_paused');
    await db.query(`update knock.payment_links set status = 'active' where slug = $1`, [slug]);
  });
});

describe('ledger integrity', () => {
  test('every journal entry balances and no customer account is negative', async () => {
    const bad = await db.query(`select * from knock.reconcile(null) where check_name in ('entry_balanced','negative_balance')`);
    assert.deepEqual(bad, []);
  });
  test('journal and fee records are append-only', async () => {
    await assert.rejects(db.query(`update knock.journal_lines set amount = amount + 1 where id = (select min(id) from knock.journal_lines)`), /append-only/);
    await assert.rejects(db.query(`delete from knock.provider_fee_records where id = (select min(id) from knock.provider_fee_records)`), /append-only/);
  });
});
