// Outgoing business webhooks: delivers queued events to the URLs businesses
// set in Knock Business > Developers. Each request is signed:
//
//   POST <endpoint url>
//   content-type: application/json
//   knock-event-id: KEV-...            (dedupe on this)
//   knock-event-type: payment.succeeded
//   knock-signature: t=<unix seconds>,v1=<hex HMAC-SHA256(secret, "<t>.<raw body>")>
//
// The receiver verifies with verifyTimestamped() (backend/src/webhooks.ts) or
// the snippet in docs/KNOCK_BUSINESS.md, rejects timestamps older than 5
// minutes, answers 2xx quickly and processes asynchronously.
//
// Safety: https only; the host is resolved and every address must be public
// (no loopback, private, link-local, CGNAT or metadata ranges), and the
// request is pinned to the checked address so DNS cannot change between the
// check and the send. Redirects are not followed. Secrets are never logged.
import { lookup as dnsLookup } from 'node:dns/promises';
import { request as httpsRequest } from 'node:https';
import { request as httpRequest } from 'node:http';
import { isIP } from 'node:net';
import type { Db } from '../db.ts';
import { signTimestamped } from '../webhooks.ts';

export interface Claimed { delivery_id: string; url: string; secret: string; event_ref: string; type: string; body: string; attempts: number }
export interface SendResult { ok: boolean; status: number | null; error: string | null; ms: number }
export type Sender = (url: string, headers: Record<string, string>, body: string) => Promise<SendResult>;

const TIMEOUT_MS = 10_000;

/** True for addresses a webhook must never reach. */
export function isPrivateAddress(ip: string): boolean {
  const v = isIP(ip);
  if (v === 4) {
    const [a, b] = ip.split('.').map(Number);
    return a === 0 || a === 10 || a === 127 || (a === 100 && b >= 64 && b <= 127) || (a === 169 && b === 254) ||
      (a === 172 && b >= 16 && b <= 31) || (a === 192 && b === 168) || (a === 192 && b === 0) || (a === 198 && (b === 18 || b === 19)) || a >= 224;
  }
  if (v === 6) {
    const s = ip.toLowerCase();
    if (s === '::' || s === '::1') return true;
    if (s.startsWith('::ffff:')) return isPrivateAddress(s.slice(7));
    return /^(fc|fd|fe8|fe9|fea|feb|ff)/.test(s);
  }
  return true;
}

export interface SenderOptions {
  lookup?: (host: string) => Promise<{ address: string; family: number }[]>;
  /** Tests only: allow http:// and private addresses (a local receiver). */
  allowInsecureForTests?: boolean;
}

/** Real HTTP sender with the SSRF guard. */
export function createSender(o: SenderOptions = {}): Sender {
  const lookup = o.lookup ?? ((h: string) => dnsLookup(h, { all: true, verbatim: true }));
  return async (url, headers, body) => {
    const started = Date.now();
    const done = (ok: boolean, status: number | null, error: string | null): SendResult => ({ ok, status, error, ms: Date.now() - started });
    let u: URL;
    try { u = new URL(url); } catch { return done(false, null, 'invalid url'); }
    if (u.username || u.password) return done(false, null, 'credentials in url are not allowed');
    if (u.protocol !== 'https:' && !(o.allowInsecureForTests && u.protocol === 'http:')) return done(false, null, 'https is required');
    const host = u.hostname.replace(/^\[|\]$/g, '');
    let addrs: { address: string; family: number }[];
    try { addrs = isIP(host) ? [{ address: host, family: isIP(host) }] : await lookup(host); } catch { return done(false, null, 'could not resolve host'); }
    if (!addrs.length) return done(false, null, 'could not resolve host');
    if (!o.allowInsecureForTests && addrs.some((a) => isPrivateAddress(a.address))) return done(false, null, 'host resolves to a private address');
    const pinned = addrs[0];
    return new Promise<SendResult>((resolve) => {
      const req = (u.protocol === 'https:' ? httpsRequest : httpRequest)({
        protocol: u.protocol, hostname: host, port: u.port || undefined, path: u.pathname + u.search, method: 'POST',
        headers: { ...headers, 'content-length': Buffer.byteLength(body).toString() },
        servername: isIP(host) ? undefined : host,
        lookup: (_h: string, _o: unknown, cb: (e: Error | null, a: string, f: number) => void) => cb(null, pinned.address, pinned.family),
        timeout: TIMEOUT_MS,
      } as any, (res) => {
        res.resume(); // the response body is not read or stored
        const s = res.statusCode ?? 0;
        resolve(done(s >= 200 && s < 300, s, s >= 200 && s < 300 ? null : s >= 300 && s < 400 ? `redirect (${s}) not followed` : `HTTP ${s}`));
      });
      req.on('timeout', () => { req.destroy(new Error('timed out after 10s')); });
      req.on('error', (e) => resolve(done(false, null, e.message.slice(0, 200))));
      req.end(body);
    });
  };
}

export function signedHeaders(c: Pick<Claimed, 'secret' | 'event_ref' | 'type' | 'body'>, t = Math.floor(Date.now() / 1000)): Record<string, string> {
  return {
    'content-type': 'application/json',
    'user-agent': 'Knock-Webhooks/1.0',
    'knock-event-id': c.event_ref,
    'knock-event-type': c.type,
    'knock-signature': signTimestamped(c.body, c.secret, t),
  };
}

/** One worker pass: claim due deliveries, send, record each result. */
export async function deliverDue(db: Db, send: Sender, limit = 20): Promise<Array<{ id: string; outcome: string }>> {
  const rows = await db.query<Claimed>('select * from knock.claim_webhook_deliveries($1)', [limit]);
  const out: Array<{ id: string; outcome: string }> = [];
  await Promise.all(rows.map(async (c) => {
    const r = await send(c.url, signedHeaders(c), c.body);
    const [x] = await db.query<{ r: string }>('select knock.webhook_delivery_result($1, $2, $3, $4, $5) as r', [c.delivery_id, r.ok, r.status, r.error, r.ms]);
    out.push({ id: c.delivery_id, outcome: x.r });
  }));
  return out;
}
