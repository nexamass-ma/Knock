// A Breet-shaped test server, built from docs.breet.io (2026-11-27). It is a
// TEST DOUBLE ONLY: it exists so the adapter, webhook engine and ledger can
// be exercised end to end without credentials. It is never used by the
// running service and never stands in for real provider evidence.
import { createServer, type Server } from 'node:http';
import { randomUUID } from 'node:crypto';

type Json = Record<string, any>;

export interface MockOptions {
  appId: string;
  appSecret: string;
  pin: string;
  webhookSecret: string;
  webhookUrl: string;
}

export class BreetMock {
  server!: Server;
  url = '';
  o: MockOptions;
  wallets = new Map<string, Json>();
  trades = new Map<string, Json>();
  withdrawals = new Map<string, Json>();
  /** Events waiting to be delivered (tests choose order and duplication). */
  outbox: Json[] = [];
  delivered: Json[] = [];
  /** Fault injection per route: next N responses. */
  faults = new Map<string, Array<{ status?: number; body?: unknown; delayMs?: number; headers?: Record<string, string>; acceptThenFail?: boolean }>>();
  requests: Array<{ method: string; path: string; body: any; headers: Record<string, string | string[] | undefined> }> = [];
  resendAllowed = false;
  autoSettleFails = false;
  assets = [
    { id: 'USDT_TRC20_TEST', symbol: 'USDT', network: 'TRC20', enabled: true, minimum: 10 },
    { id: 'BTC_TEST', symbol: 'BTC', network: '', enabled: true, minimum: 10 },
  ];

  constructor(o: MockOptions) {
    this.o = o;
  }

  async start() {
    this.server = createServer(async (req, res) => {
      const chunks: Buffer[] = [];
      for await (const c of req) chunks.push(c as Buffer);
      const raw = Buffer.concat(chunks).toString('utf8');
      const url = new URL(req.url!, 'http://x');
      const path = url.pathname.replace(/^\/v1/, '');
      const body = raw ? JSON.parse(raw) : {};
      this.requests.push({ method: req.method!, path, body, headers: req.headers });
      const send = (status: number, b: unknown, headers: Record<string, string> = {}) => {
        res.writeHead(status, { 'content-type': 'application/json', ...headers });
        res.end(typeof b === 'string' ? b : JSON.stringify(b));
      };
      const ok = (data: unknown, meta: Json = {}, status = 200) => send(status, { success: true, message: 'ok', data, meta, summary: {}, stats: {} });
      const err = (status: number, message: string) => send(status, { success: false, message, meta: {}, errors: [], data: null });

      if (req.headers['x-app-id'] !== this.o.appId || req.headers['x-app-secret'] !== this.o.appSecret) return err(401, 'invalid credentials');
      if (req.headers['x-breet-env'] !== 'sandbox') return err(403, 'this test server is sandbox only');

      const route = `${req.method} ${path.replace(/\/[0-9a-f]{24}$/, '/:id').replace(/assets\/[^/]+\/generate/, 'assets/:id/generate').replace(/bank\/[^/]+$/, 'bank/:id')}`;
      const f = this.faults.get(route)?.shift();
      if (f?.delayMs) await new Promise((r) => setTimeout(r, f.delayMs));
      if (f && !f.acceptThenFail) {
        if (f.status) return send(f.status, f.body ?? '', f.headers ?? {});
        if (f.delayMs) { /* fall through after delay */ }
      }
      const fail = () => f?.acceptThenFail;
      try {
        await this.route(req.method!, path, url, body, ok, err, fail);
      } catch (e) {
        err(500, String(e));
      }
    });
    await new Promise<void>((r) => this.server.listen(0, '127.0.0.1', r));
    const a = this.server.address() as any;
    this.url = `http://127.0.0.1:${a.port}/v1`;
  }

  stop() {
    return new Promise<void>((r) => this.server.close(() => r()));
  }

  fault(route: string, ...f: Array<{ status?: number; body?: unknown; delayMs?: number; headers?: Record<string, string>; acceptThenFail?: boolean }>) {
    this.faults.set(route, [...(this.faults.get(route) ?? []), ...f]);
  }

  private id() {
    return randomUUID().replace(/-/g, '').slice(0, 24);
  }

  private emit(e: Json) {
    this.outbox.push({ eventId: randomUUID(), eventTime: new Date(Date.now() + this.outbox.length).toISOString(), ...e });
  }

  /** Deliver queued webhooks (optionally a chosen order, with duplicates). */
  async deliver(order?: number[], secret = this.o.webhookSecret) {
    const events = order ? order.map((i) => this.outbox[i]) : [...this.outbox];
    if (!order) this.outbox = [];
    const statuses: number[] = [];
    for (const e of events) {
      const r = await fetch(this.o.webhookUrl, { method: 'POST', headers: { 'content-type': 'application/json', 'x-webhook-secret': secret }, body: JSON.stringify(e) });
      statuses.push(r.status);
      this.delivered.push(e);
    }
    return statuses;
  }

  private page(list: Json[], url: URL, ok: (d: unknown, m?: Json) => void) {
    const page = Number(url.searchParams.get('page') ?? 1);
    const size = Number(url.searchParams.get('size') ?? 10);
    const items = list.slice((page - 1) * size, page * size);
    const pages = Math.max(1, Math.ceil(list.length / size));
    ok(items, { page, pages, totalDocs: list.length, hasNextPage: page < pages, hasPrevPage: page > 1, nextPage: page < pages ? page + 1 : null, prevPage: page > 1 ? page - 1 : null });
  }

  private async route(method: string, path: string, url: URL, body: Json, ok: any, err: any, acceptThenFail: () => boolean | undefined) {
    let m: RegExpExecArray | null;
    if (method === 'GET' && path === '/trades/assets') return ok(this.assets);
    if (method === 'GET' && path === '/payments/supported-assets-info') {
      return ok({
        tokens: [
          { symbol: 'USDT', enabled: true, networks: [{ network: 'TRC20', enabled: true, fee: 1 }, { network: 'TON', enabled: false, fee: 1 }], fee: 1, isTestnet: true },
          { symbol: 'USDC', enabled: false, networks: [{ network: 'BASE', enabled: true, fee: 1 }], fee: 1, isTestnet: true },
          { symbol: 'BTC', enabled: true, networks: [], fee: null, isTestnet: true },
        ],
        limits: { minimum: 10, maximum: 10000 },
        rate: 1390,
      });
    }
    if (method === 'POST' && (m = /^\/trades\/sell\/assets\/([^/]+)\/generate-address$/.exec(path))) {
      if (!body.label) return err(422, 'label is required');
      for (const w of this.wallets.values()) if (w.label === body.label && w.asset === m[1]) return err(400, `${m[1]} for ${body.label} already exists in your wallets`);
      const w = { id: this.id(), address: 'T' + randomUUID().replace(/-/g, '').slice(0, 33), asset: m[1], label: body.label, bankId: body.bankId, autoSettlement: !!body.autoSettlement };
      this.wallets.set(w.id, w);
      this.emit({ event: 'trade.address.created', id: w.id, address: w.address, asset: w.asset, label: w.label });
      if (acceptThenFail()) return err(500, 'upstream error');
      return ok({ id: w.id, address: w.address }, {}, 201);
    }
    if (method === 'GET' && path === '/trades/wallets') return this.page([...this.wallets.values()], url, ok);
    if (method === 'PUT' && (m = /^\/trades\/wallets\/([^/]+)\/auto-settlement$/.exec(path))) {
      const w = this.wallets.get(m[1]);
      if (!w) return err(404, 'wallet not found');
      if (!w.bankId) return err(422, 'link a bank first');
      w.autoSettlement = !!body.autoSettlement;
      return ok({});
    }
    if (method === 'GET' && (m = /^\/trades\/transactions\/([^/]+)$/.exec(path))) {
      const t = this.trades.get(m[1]);
      return t ? ok(t) : err(404, 'transaction not found');
    }
    if (method === 'GET' && path === '/trades/transactions') return this.page([...this.trades.values()], url, ok);
    if (method === 'POST' && path === '/trades/sell/mock-trade') return ok(this.mockTrade(body));
    if (method === 'POST' && path === '/payments/wallet-addresses/validate') {
      return ok({ valid: typeof body.walletAddress === 'string' && body.walletAddress.length >= 26 });
    }
    if (method === 'POST' && path === '/payments/estimate-network-fee') {
      return ok({ low: { networkFee: 0.00001, networkFeeUsd: 0.5 }, medium: { networkFee: 0.00002, networkFeeUsd: 1 }, high: { networkFee: 0.00004, networkFeeUsd: 2 } });
    }
    if (method === 'POST' && (path === '/payments/withdraw/address' || /^\/payments\/withdraw\/bank\/[^/]+$/.test(path))) {
      if (body.pin !== this.o.pin) return err(403, 'invalid pin');
      const bank = path.startsWith('/payments/withdraw/bank/');
      const currency = bank ? 'ngn' : 'usd';
      const amount = Number(body.amount);
      if (!bank && amount < 10) return err(400, 'the minimum withdrawal amount is $10');
      if (amount === 9999) return err(400, 'We are unable to price a payout of this size in this coin right now');
      if (amount === 7777) return err(400, 'insufficient balance');
      const dup = [...this.withdrawals.values()].find((w) => Number(w.amount) === amount && w.currency === currency && Date.now() - w._t < 5 * 60_000);
      if (dup) return err(400, 'Duplicate withdrawal detected. Enter a different amount.');
      const w: Json = {
        id: this.id(), amount, originalAmount: amount, currency, status: 'pending', reference: '', externalId: body.externalId ?? null,
        fee: bank ? 50 : 1, trade: null, reason: '', _t: Date.now(),
        meta: bank ? { type: 'bank', bankId: '39', bankName: 'Test Bank', accountName: 'ADA OBI', accountNumber: '0123456789', feeBearer: 'user' }
                   : { walletAddress: body.walletAddress, network: body.network ?? null, token: body.token, txLink: 'https://explorer.test/tx/', feeBearer: 'user' },
        createdAt: new Date().toISOString(), updatedAt: new Date().toISOString(),
      };
      w.reference = w.id;
      this.withdrawals.set(w.id, w);
      this.advanceWithdrawal(w, currency, amount);
      if (acceptThenFail()) return err(500, 'upstream error'); // accepted, but the caller sees a 500
      return ok({ id: w.id });
    }
    if (method === 'GET' && (m = /^\/payments\/withdrawal\/([^/]+)$/.exec(path))) {
      const w = this.withdrawals.get(m[1]);
      return w ? ok(strip(w)) : err(404, 'withdrawal not found');
    }
    if (method === 'GET' && path === '/payments/withdrawals') return this.page([...this.withdrawals.values()].map(strip), url, ok);
    if (method === 'GET' && path === '/transactions/webhooks') return this.page(this.delivered.map((e) => ({ id: e.eventId, reference: e.id, eventType: e.event, status: 'delivered' })), url, ok);
    if (method === 'POST' && (m = /^\/transactions\/webhooks\/resend\/(.+)$/.exec(path))) {
      if (!this.resendAllowed) return err(403, 'access denied');
      const e = this.delivered.find((d) => d.id === m![1]);
      if (e) this.outbox.push(e);
      return ok([{ id: e?.eventId, status: e ? 'queued' : 'not_found' }]);
    }
    return err(404, 'route not found');
  }

  /** Documented sandbox outcomes: NGN <=5,000 reversed, 10,000 processing; USD <=15 reversed, 50 processing. */
  private advanceWithdrawal(w: Json, currency: string, amount: number) {
    const ev = (status: string, extra: Json = {}) => {
      w.status = status;
      w.updatedAt = new Date().toISOString();
      Object.assign(w, extra);
      this.emit({ event: `withdrawal.${status}`, ...strip(w) });
    };
    ev('pending');
    const reverseAt = currency === 'ngn' ? 5000 : currency === 'ghs' ? 10 : 15;
    const procAt = currency === 'ngn' ? 10000 : currency === 'ghs' ? 100 : 50;
    if (amount <= reverseAt) { ev('processing'); ev('reversed', { reason: 'payout failed' }); return; }
    if (amount === procAt) { ev('processing'); return; }
    if (amount === 43.21) { ev('rejected', { reason: 'rejected by review' }); return; }
    ev('processing');
    ev('completed', { txHash: '0xsandbox' + w.id, payoutAmount: currency === 'ngn' ? amount - 50 : undefined });
  }

  /** POST /trades/sell/mock-trade scenarios from docs.breet.io/testing. */
  mockTrade(b: Json) {
    const wallet = [...this.wallets.values()].find((w) => w.address === b.walletAddress && w.asset === b.asset);
    if (!wallet) throw new Error('no wallet for walletAddress+asset');
    const scenario = b.scenario ?? 'completed';
    const t: Json = {
      id: this.id(), asset: b.asset, cryptoAmount: b.cryptoReceived, amountInUSD: b.amountInUSD, txHash: b.txHash, destinationAddress: wallet.address,
      wallet: wallet.id, status: 'pending', subStatus: 'pending', confirmations: 0, currency: b.currency ?? 'ngn', rate: 1600, conversionRate: 1,
      feePercentage: 1.5, feeAmountInUsd: 0.25, createdAt: Date.now(), updatedAt: Date.now(),
    };
    this.trades.set(t.id, t);
    const ev = (status: string, extra: Json = {}) => {
      Object.assign(t, { status, subStatus: extra.subStatus ?? status, updatedAt: Date.now() }, extra);
      this.emit({ event: `trade.${status}`, ...t, currency: String(t.currency).toUpperCase() });
    };
    // Credited NGN: amountInUSD * rate, less a 1.5% fee, rounded to kobo.
    const credited = (usd: number) => Math.round(usd * (t.currency === 'usd' ? 1 : 1600) * 0.985 * 100) / 100;
    switch (scenario) {
      case 'completed': {
        ev('pending');
        ev('pending', { confirmations: 2 });
        const below = [...this.trades.values()].filter((x) => x.destinationAddress === wallet.address && x.status === 'flagged' && x.balanceRemaining);
        const totalUsd = Number(b.amountInUSD) + below.reduce((s, x) => s + Number(x.amountInUSD), 0);
        ev('completed', { confirmations: 3, amountCredited: credited(totalUsd), walletCredited: credited(totalUsd),
          settledTrades: below.length ? [...below.map((x) => x.id), t.id] : undefined });
        for (const x of below) Object.assign(x, { status: 'completed', subStatus: 'completed', balanceRemaining: undefined });
        if (wallet.autoSettlement) {
          if (this.autoSettleFails) {
            this.emit({ event: 'trade.settlement.failed', id: t.id, amount: t.amountCredited, currency: 'NGN', reason: 'settlement_not_started' });
          } else {
            const w: Json = { id: this.id(), amount: t.amountCredited, originalAmount: t.amountCredited, currency: 'ngn', status: 'pending', trade: t.id, fee: 50,
              reference: '', externalId: null, reason: '', meta: { type: 'bank', bankId: wallet.bankId, bankName: 'Test Bank', accountName: 'ADA OBI', accountNumber: '0123456789', autoSettlement: true, feeBearer: 'user' },
              createdAt: new Date().toISOString(), updatedAt: new Date().toISOString(), _t: 0 };
            w.reference = w.id;
            this.withdrawals.set(w.id, w);
            const wev = (s: string, x: Json = {}) => { Object.assign(w, { status: s }, x); this.emit({ event: `withdrawal.${s}`, ...strip(w) }); };
            wev('pending');
            wev('completed', { payoutAmount: Number(t.amountCredited) - 50 });
          }
        }
        break;
      }
      case 'confirming':
        ev('pending', { confirmations: 1 });
        break;
      case 'below_minimum':
        ev('pending');
        ev('flagged', { balanceRemaining: 10 - Number(b.amountInUSD), flagFeeUSD: 0 });
        break;
      case 'failed_on_chain':
        ev('pending');
        ev('deleted', { reason: 'failed_on_chain' });
        break;
      case 'under_review':
        ev('flagged', { subStatus: 'under_review' });
        ev('deleted', { reason: 'rejected_after_review' });
        break;
      case 'kyt_hold':
        ev('pending');
        ev('flagged', { subStatus: 'under_review', kyt: { rule: 'sanctions', severity: 'high', exposure: 'direct', service: 'test' } });
        break;
      case 'wrong_asset':
        ev('pending', { isWrongAssetDeposit: true });
        break;
    }
    return { reference: b.reference, tradeId: t.id };
  }

  /** Test helper: complete a trade that is currently held (e.g. after review). */
  completeHeld(tradeId: string, usd: number) {
    const t = this.trades.get(tradeId)!;
    Object.assign(t, { status: 'completed', subStatus: 'completed', amountCredited: Math.round(usd * 1600 * 0.985 * 100) / 100, updatedAt: Date.now() });
    this.emit({ event: 'trade.completed', ...t, currency: 'NGN' });
  }

  /** Test helper: move a withdrawal to a later state (e.g. processing -> completed). */
  advance(id: string, status: string) {
    const w = this.withdrawals.get(id)!;
    Object.assign(w, { status, updatedAt: new Date().toISOString() });
    this.emit({ event: `withdrawal.${status}`, ...strip(w) });
  }
}

function strip(w: Json) {
  const { _t, ...rest } = w;
  return rest;
}
