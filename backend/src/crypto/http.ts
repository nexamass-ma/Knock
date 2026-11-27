// HTTP surface for the crypto integration: the provider webhook and the
// customer API the Knock app calls. No admin routes (Knock staff use the
// provider's own dashboard). All provider calls happen server-side.
import { createServer, type IncomingMessage, type Server, type ServerResponse } from 'node:http';
import { ApiError } from '../db.ts';
import { clientIp, verifySupabaseJwt, type Principal } from './auth.ts';
import { toJson } from './json.ts';
import { RateLimiter } from '../ratelimit.ts';
import { customerWithdrawal, type CryptoService, type WithdrawalBody } from './service.ts';

export interface HttpDeps {
  svc: CryptoService;
  jwtSecret: string;
  trustedProxies: string[];
  /**
   * Verifies the customer's transaction authorisation for a withdrawal (PIN
   * or device-bound biometric signature over the request). Must return true
   * only for a valid, unused proof for exactly this request.
   */
  verifyTransactionAuth: (user: Principal, proof: string | null, body: WithdrawalBody) => Promise<boolean>;
  maxBodyBytes?: number;
}

const send = (res: ServerResponse, status: number, body: unknown) => {
  res.writeHead(status, { 'content-type': 'application/json', 'cache-control': 'no-store', 'x-content-type-options': 'nosniff' });
  res.end(typeof body === 'string' ? JSON.stringify({ result: body }) : toJson(body));
};

async function readBody(req: IncomingMessage, max: number): Promise<string> {
  const chunks: Buffer[] = [];
  let n = 0;
  for await (const c of req) {
    n += (c as Buffer).length;
    if (n > max) throw new ApiError('too_large', 'request body too large', 413);
    chunks.push(c as Buffer);
  }
  return Buffer.concat(chunks).toString('utf8');
}

const STATUS: Record<string, number> = {
  unauthenticated: 401, forbidden: 403, kyc_required: 403, account_restricted: 403, not_found: 404, insufficient_funds: 422,
  limit_exceeded: 422, link_expired: 410, over_target: 422, invalid_amount: 422, reference_required: 422, method_unavailable: 422, feature_disabled: 409, address_unavailable: 502, invalid_destination: 422, asset_unavailable: 422, bank_required: 422, bank_not_linked: 422, try_later: 503,
};

/** Customer-safe error: code + plain message, never provider wording. */
function fail(res: ServerResponse, e: unknown) {
  const err = e instanceof ApiError ? e : new ApiError('internal', 'Something went wrong. Please try again.', 500);
  const status = STATUS[err.code] ?? (err.status || 400);
  send(res, status, { error: err.code, message: status >= 500 && err.code === 'internal' ? 'Something went wrong. Please try again.' : err.message });
}

export function createCryptoHttp(d: HttpDeps): Server {
  const max = d.maxBodyBytes ?? 64 * 1024;
  const svc = d.svc;
  const auth = (req: IncomingMessage) => {
    const h = req.headers.authorization;
    const p = verifySupabaseJwt(h?.startsWith('Bearer ') ? h.slice(7) : null, d.jwtSecret);
    if (!p) throw new ApiError('unauthenticated', 'Please log in to continue.', 401);
    return p;
  };

  const checkoutLimit = new RateLimiter(10, 60_000);
  return createServer(async (req, res) => {
    const url = new URL(req.url ?? '/', 'http://localhost');
    const path = url.pathname;
    try {
      if (req.method === 'POST' && path === `/webhooks/${svc.provider.name}`) {
        const raw = await readBody(req, max);
        const ip = clientIp(req.socket.remoteAddress, (req.headers['x-forwarded-for'] as string) ?? null, d.trustedProxies);
        const headers = new Headers();
        for (const [k, v] of Object.entries(req.headers)) if (typeof v === 'string') headers.set(k, v);
        const r = await svc.ingestWebhook(raw, headers, ip);
        res.writeHead(r.status, { 'content-type': 'text/plain' });
        return res.end(r.body);
      }
      if (req.method === 'GET' && path === '/health') return send(res, 200, { ok: true });

      // ---- public hosted checkout (payment links) ---------------------------
      // The payer is not signed in. Rate-limited per IP; the page then polls
      // the public op pub.checkout with the returned payment id.
      const ck = /^\/v1\/checkout\/([A-Za-z0-9_-]{4,64})$/.exec(path);
      if (req.method === 'POST' && ck) {
        const ip = clientIp(req.socket.remoteAddress, (req.headers['x-forwarded-for'] as string) ?? null, d.trustedProxies) ?? 'unknown';
        if (!checkoutLimit.take(ip)) throw new ApiError('try_later', 'Too many attempts. Please wait a minute and try again.', 429);
        const body = JSON.parse((await readBody(req, max)) || '{}');
        const amount = body.amount == null ? null : String(body.amount);
        if (amount !== null && !/^[0-9]{1,30}$/.test(amount)) throw new ApiError('bad_request', 'Invalid amount.');
        return send(res, 200, await svc.openCheckout(ck[1], amount, { name: body.payer_name, email: body.payer_email, reference: body.customer_reference }));
      }

      // ---- customer API --------------------------------------------------
      if (req.method === 'GET' && path === '/v1/crypto/assets') {
        auth(req);
        const rows = await svc.db.query(
          `select asset_id, symbol, network, kind, deposit_enabled, withdraw_enabled, min_deposit, withdrawal_fee, withdrawal_fee_currency, min_withdrawal
           from knock.provider_asset_configurations where provider = $1 and (deposit_enabled or withdraw_enabled) order by symbol, network`, [svc.provider.name]);
        return send(res, 200, { assets: rows });
      }
      if (req.method === 'POST' && path === '/v1/crypto/addresses') {
        const u = auth(req);
        const body = JSON.parse((await readBody(req, max)) || '{}');
        if (typeof body.asset_id !== 'string') throw new ApiError('bad_request', 'asset_id is required');
        return send(res, 200, { address: await svc.requestAddress(u.userId, body) });
      }
      if (req.method === 'GET' && path === '/v1/crypto/addresses') {
        const u = auth(req);
        const rows = await svc.db.query(`select id, asset_id, symbol, network, address, memo, auto_settlement,
            case status when 'active' then 'Awaiting Deposit' when 'requested' then 'Generating Address' else 'Unavailable' end as status
          from knock.provider_wallet_addresses where user_id = $1 and status <> 'retired' order by created_at desc`, [u.userId]);
        return send(res, 200, { addresses: rows });
      }
      if (req.method === 'GET' && path === '/v1/crypto/activity') {
        const u = auth(req);
        const rows = await svc.db.query(`select * from knock.customer_crypto_activity where user_id = $1 order by created_at desc limit 100`, [u.userId]);
        return send(res, 200, { items: rows.map(({ user_id, ...r }: any) => r) });
      }
      if (req.method === 'POST' && path === '/v1/withdrawals/quote') {
        const u = auth(req);
        return send(res, 200, { quote: await svc.quoteWithdrawal(u.userId, JSON.parse(await readBody(req, max))) });
      }
      if (req.method === 'POST' && path === '/v1/withdrawals') {
        const u = auth(req);
        const body = JSON.parse(await readBody(req, max)) as WithdrawalBody;
        if (!(await d.verifyTransactionAuth(u, (req.headers['x-knock-authorization'] as string) ?? null, body))) {
          throw new ApiError('forbidden', 'Please confirm this withdrawal with your PIN or biometrics.', 403);
        }
        const key = (req.headers['idempotency-key'] as string) ?? '';
        return send(res, 200, { withdrawal: await svc.createWithdrawal(u.userId, key, body) });
      }
      const m = /^\/v1\/withdrawals\/([0-9a-f-]{36})$/.exec(path);
      if (req.method === 'GET' && m) {
        const u = auth(req);
        const [w] = await svc.db.query(`select * from knock.provider_withdrawals where id = $1 and user_id = $2 and purpose = 'customer'`, [m[1], u.userId]);
        if (!w) throw new ApiError('not_found', 'Withdrawal not found.', 404);
        return send(res, 200, { withdrawal: customerWithdrawal(w) });
      }
      send(res, 404, { error: 'not_found' });
    } catch (e) {
      if (e instanceof SyntaxError) return send(res, 400, { error: 'bad_request', message: 'Invalid JSON.' });
      fail(res, e);
    }
  });
}
