// Customer authentication for the crypto API: Supabase Auth access tokens
// (HS256 JWT signed with the project's JWT secret). The app never sees any
// provider credential; it only proves who the customer is.
import { createHmac, timingSafeEqual } from 'node:crypto';

export interface Principal {
  userId: string;
  aal: string | null; // 'aal2' when MFA was used
}

export function verifySupabaseJwt(token: string | null, secret: string, now = Date.now()): Principal | null {
  if (!token || !secret) return null;
  const parts = token.split('.');
  if (parts.length !== 3) return null;
  const [h, p, s] = parts;
  let header: any;
  let payload: any;
  try {
    header = JSON.parse(Buffer.from(h, 'base64url').toString('utf8'));
    payload = JSON.parse(Buffer.from(p, 'base64url').toString('utf8'));
  } catch {
    return null;
  }
  if (header.alg !== 'HS256') return null;
  const expected = createHmac('sha256', secret).update(`${h}.${p}`).digest();
  const got = Buffer.from(s, 'base64url');
  if (got.length !== expected.length || !timingSafeEqual(got, expected)) return null;
  if (typeof payload.exp !== 'number' || payload.exp * 1000 < now) return null;
  if (payload.role !== 'authenticated' || typeof payload.sub !== 'string') return null;
  return { userId: payload.sub, aal: payload.aal ?? null };
}

export function signTestJwt(sub: string, secret: string, extra: Record<string, unknown> = {}) {
  const h = Buffer.from(JSON.stringify({ alg: 'HS256', typ: 'JWT' })).toString('base64url');
  const p = Buffer.from(JSON.stringify({ sub, role: 'authenticated', exp: Math.floor(Date.now() / 1000) + 3600, ...extra })).toString('base64url');
  const s = createHmac('sha256', secret).update(`${h}.${p}`).digest('base64url');
  return `${h}.${p}.${s}`;
}

/**
 * Resolve the webhook source IP. Only trust X-Forwarded-For when the direct
 * peer is one of our own proxies, and then take the right-most address that
 * is not a trusted proxy (the client-supplied left part is ignored).
 */
export function clientIp(peer: string | undefined, xff: string | null, trustedProxies: string[]): string | null {
  const p = normalizeIp(peer);
  if (!p) return null;
  if (!trustedProxies.includes(p) || !xff) return p;
  const hops = xff.split(',').map((s) => normalizeIp(s.trim())).filter((s): s is string => !!s);
  for (let i = hops.length - 1; i >= 0; i--) if (!trustedProxies.includes(hops[i])) return hops[i];
  return p;
}

function normalizeIp(ip: string | undefined | null) {
  if (!ip) return null;
  return ip.startsWith('::ffff:') ? ip.slice(7) : ip;
}
