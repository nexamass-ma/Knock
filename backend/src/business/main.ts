// Entry point for the Knock Business + Admin dashboard API.
//   DATABASE_URL, SUPABASE_JWT_SECRET, DASHBOARD_ORIGINS (comma separated), TRUSTED_PROXIES, PORT
// Not deployed. See docs/KNOCK_BUSINESS.md.
import { createDb } from '../db.ts';
import { createBusinessHttp } from './http.ts';

const list = (v?: string) => (v ?? '').split(',').map((s) => s.trim()).filter(Boolean);
const db = createDb(process.env.DATABASE_URL ?? '');
const secret = process.env.SUPABASE_JWT_SECRET ?? '';
if (!secret) throw new Error('SUPABASE_JWT_SECRET is required');
createBusinessHttp({ db, jwtSecret: secret, allowedOrigins: list(process.env.DASHBOARD_ORIGINS), trustedProxies: list(process.env.TRUSTED_PROXIES) })
  .listen(Number(process.env.PORT ?? 8081));
// Risk rules over Knock's own records, every 10 minutes.
setInterval(() => db.query('select knock.run_risk_rules()').catch((e) => console.error(JSON.stringify({ level: 'error', msg: String(e?.message ?? e) }))), 600_000);
