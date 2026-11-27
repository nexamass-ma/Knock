// HTTP API for the Knock Business and Knock Admin dashboards.
//   POST /v1/ops/<name>   body: {"input": {...}}   header X-Business-Id for business ops
// One narrow endpoint over a FIXED catalogue (ops.ts). The server binds the
// user id from the verified Supabase JWT and, for admin ops, the JWT's MFA
// level (aal); the database refuses admin ops below aal2. No cookies are
// used (bearer tokens only), so there is no CSRF surface.
import { createServer, type IncomingMessage, type Server, type ServerResponse } from 'node:http';
import { toApiError, type Db } from '../db.ts';
import { clientIp, verifySupabaseJwt } from '../crypto/auth.ts';
import { RateLimiter } from '../ratelimit.ts';
import { getOp, OpError, runOp } from './runner.ts';

export interface BusinessHttpDeps {
  db: Db;
  jwtSecret: string;
  allowedOrigins: string[];        // dashboard origins, exact match
  trustedProxies?: string[];
  maxBodyBytes?: number;
}

const STATUS: Record<string, number> = {
  unauthenticated: 401, mfa_required: 401, forbidden: 403, verification_required: 403, account_restricted: 403, kyc_required: 403,
  feature_disabled: 409, not_found: 404, rate_limited: 429, too_large: 413, insufficient_funds: 422, limit_exceeded: 422,
  second_approver_required: 409, bad_state: 409, invalid_state: 409, internal: 500,
};

function headers(origin: string | undefined, allowed: string[]) {
  const h: Record<string, string> = {
    'content-type': 'application/json', 'cache-control': 'no-store', 'x-content-type-options': 'nosniff',
    'referrer-policy': 'no-referrer', 'x-frame-options': 'DENY',
  };
  if (origin && allowed.includes(origin)) {
    h['access-control-allow-origin'] = origin;
    h['access-control-allow-headers'] = 'authorization, content-type, x-business-id';
    h['access-control-allow-methods'] = 'POST, OPTIONS';
    h['vary'] = 'origin';
  }
  return h;
}

async function readBody(req: IncomingMessage, max: number) {
  const chunks: Buffer[] = [];
  let n = 0;
  for await (const c of req) {
    n += (c as Buffer).length;
    if (n > max) throw new OpError('too_large', 'request too large');
    chunks.push(c as Buffer);
  }
  return Buffer.concat(chunks).toString('utf8');
}

export function createBusinessHttp(d: BusinessHttpDeps): Server {
  const max = d.maxBodyBytes ?? 32 * 1024;
  const perUser = new RateLimiter(120, 60_000);   // reads + writes per user per minute
  const perUserWrites = new RateLimiter(30, 60_000);
  const perIp = new RateLimiter(60, 60_000);      // public payment page

  return createServer(async (req, res) => {
    const h = headers(req.headers.origin, d.allowedOrigins);
    const send = (status: number, body: unknown) => { res.writeHead(status, h); res.end(JSON.stringify(body)); };
    try {
      if (req.method === 'OPTIONS') { res.writeHead(204, h); return res.end(); }
      const m = /^\/v1\/ops\/([a-z_.]+)$/.exec(new URL(req.url ?? '/', 'http://x').pathname);
      if (req.method !== 'POST' || !m) return send(404, { error: 'not_found' });
      const op = getOp(m[1]);
      const ip = clientIp(req.socket.remoteAddress, (req.headers['x-forwarded-for'] as string) ?? null, d.trustedProxies ?? []) ?? 'unknown';
      let userId = '';
      let context: string | null = null;
      if (op.scope === 'public') {
        if (!perIp.take(ip)) throw new OpError('rate_limited', 'too many requests');
      } else {
        const a = req.headers.authorization;
        const p = verifySupabaseJwt(a?.startsWith('Bearer ') ? a.slice(7) : null, d.jwtSecret);
        if (!p) throw new OpError('unauthenticated', 'sign in first');
        userId = p.userId;
        if (!perUser.take(userId) || (op.write && !perUserWrites.take(userId))) throw new OpError('rate_limited', 'too many requests');
        if (op.scope === 'business') context = (req.headers['x-business-id'] as string) ?? null;
        if (op.scope === 'admin') context = p.aal; // the DB requires 'aal2'
      }
      const raw = await readBody(req, max);
      const body = raw ? JSON.parse(raw) : {};
      const input = body && typeof body.input === 'object' && body.input !== null ? body.input : {};
      const result = await d.db.tx((q) => runOp(q, m[1], { userId, context }, input));
      send(200, { result });
    } catch (e: any) {
      if (e instanceof SyntaxError) return send(400, { error: 'bad_request', message: 'invalid JSON' });
      const err = e instanceof OpError ? e : toApiError(e);
      const status = STATUS[err.code] ?? 400;
      // Internal errors are never echoed (no SQL or stack text leaves the server).
      send(status, { error: err.code, message: status >= 500 ? 'Something went wrong. Please try again.' : err.message });
    }
  });
}
