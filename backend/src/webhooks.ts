// Provider webhook signature verification. A webhook only tells us to go
// and look: money moves only after the provider's verify API confirms the
// transaction (see service.ts). Unsigned or badly signed events are stored
// for investigation and never processed.
import { createHmac, timingSafeEqual } from 'node:crypto';

function safeEqualHex(a: string, b: string): boolean {
  const ab = Buffer.from(a, 'utf8');
  const bb = Buffer.from(b, 'utf8');
  return ab.length === bb.length && timingSafeEqual(ab, bb);
}

/** Paystack: x-paystack-signature = HMAC-SHA512(raw body, secret key), hex. */
export function verifyPaystack(rawBody: string, signature: string | null, secretKey: string): boolean {
  if (!signature || !secretKey) return false;
  const expected = createHmac('sha512', secretKey).update(rawBody, 'utf8').digest('hex');
  return safeEqualHex(expected, signature.trim().toLowerCase());
}

/** Flutterwave v3: verif-hash header equals the secret hash set in the dashboard. */
export function verifyFlutterwave(signature: string | null, secretHash: string): boolean {
  if (!signature || !secretHash) return false;
  return safeEqualHex(signature, secretHash);
}

/**
 * Generic HMAC-SHA256 scheme used by most crypto payment providers and by
 * Knock's sandbox: header "t=<unix>,v1=<hex>", signed payload "<t>.<body>".
 * Rejects events older than `toleranceSec` to stop replays.
 */
export function signTimestamped(rawBody: string, secret: string, t = Math.floor(Date.now() / 1000)): string {
  const v1 = createHmac('sha256', secret).update(`${t}.${rawBody}`, 'utf8').digest('hex');
  return `t=${t},v1=${v1}`;
}

export function verifyTimestamped(rawBody: string, header: string | null, secret: string, toleranceSec = 300, now = Date.now()): boolean {
  if (!header || !secret) return false;
  const parts = Object.fromEntries(header.split(',').map((p) => p.trim().split('=') as [string, string]));
  const t = Number(parts.t);
  if (!Number.isFinite(t) || !parts.v1) return false;
  if (Math.abs(now / 1000 - t) > toleranceSec) return false;
  const expected = createHmac('sha256', secret).update(`${t}.${rawBody}`, 'utf8').digest('hex');
  return safeEqualHex(expected, parts.v1);
}
