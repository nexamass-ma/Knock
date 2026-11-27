// Entry point: webhook + customer API server and background worker.
//   KNOCK_ENV, DATABASE_URL, SUPABASE_JWT_SECRET, TRUSTED_PROXIES,
//   BREET_<ENV>_APP_ID / _APP_SECRET / _WEBHOOK_SECRET / _WITHDRAWAL_PIN
// See docs/BREET_INTEGRATION.md. Nothing here is deployed.
import { createDb } from '../db.ts';
import { BreetAdapter } from './breet/adapter.ts';
import { loadBreetConfig } from './config.ts';
import { createCryptoHttp } from './http.ts';
import { PgRateGate } from './ratelimit.ts';
import { Reconciler } from './reconcile.ts';
import { CryptoService } from './service.ts';
import { pgApiLogger } from './apilog.ts';

const cfg = loadBreetConfig();
const db = createDb(process.env.DATABASE_URL ?? '');
const provider = new BreetAdapter(cfg, new PgRateGate(db, 'breet'), pgApiLogger(db));
const svc = new CryptoService({ db, provider });
await svc.assertEnvironment(cfg.appIdFingerprint);

const server = createCryptoHttp({
  svc,
  jwtSecret: process.env.SUPABASE_JWT_SECRET ?? '',
  trustedProxies: (process.env.TRUSTED_PROXIES ?? '').split(',').map((s) => s.trim()).filter(Boolean),
  // Transaction authorisation is enforced by Knock's auth service (device-bound
  // key signature). Until it exists, withdrawals are refused.
  verifyTransactionAuth: async () => false,
});
server.listen(Number(process.env.PORT ?? 8080));

const every = (ms: number, fn: () => Promise<unknown>) => {
  const run = () => fn().catch((e) => console.error(JSON.stringify({ level: 'error', msg: String(e?.message ?? e) })));
  run();
  return setInterval(run, ms);
};
const reconciler = new Reconciler(db, provider);
every(2_000, () => svc.processQueue(20));
every(60_000, () => svc.withdrawalSweep());
every(5 * 60_000, () => svc.health());
every(15 * 60_000, () => svc.syncAssets());
every(60 * 60_000, () => reconciler.run('scheduled'));
