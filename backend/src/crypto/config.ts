// Breet configuration. Server-side only: these values come from the
// environment / secrets manager and never reach the app or the browser.
//
// Environment separation: sandbox and production use DIFFERENT variable
// names, and the provider environment is derived from KNOCK_ENV. A sandbox
// deployment cannot read production keys, and production refuses to start
// unless explicitly confirmed and pointed at a production database (checked
// against knock.provider_accounts at start-up, see assertEnvironment()).
import { createHash } from 'node:crypto';
import type { Env } from './provider.ts';

export const BREET_WEBHOOK_IPS = ['46.101.201.155', '46.101.225.109', '46.101.225.97', '46.101.225.251', '159.89.20.62'];

export interface BreetConfig {
  env: Env;
  baseUrl: string;
  appId: () => string;
  appSecret: () => string; // functions so rotated secrets are read on every call
  withdrawalPin: () => string;
  webhookSecrets: () => string[]; // current first, then previous (rotation window)
  webhookIps: string[];
  timeoutMs: number;
  appIdFingerprint: string;
}

export class ConfigError extends Error {}

export function loadBreetConfig(env: Record<string, string | undefined> = process.env): BreetConfig {
  const knockEnv = env.KNOCK_ENV ?? 'sandbox';
  if (knockEnv !== 'sandbox' && knockEnv !== 'production') throw new ConfigError('KNOCK_ENV must be sandbox or production');
  const P = knockEnv === 'production' ? 'BREET_PRODUCTION_' : 'BREET_SANDBOX_';
  const other = knockEnv === 'production' ? 'BREET_SANDBOX_' : 'BREET_PRODUCTION_';

  if (knockEnv === 'production' && env.BREET_PRODUCTION_CONFIRM !== 'i-understand-real-funds') {
    throw new ConfigError('production Breet access needs BREET_PRODUCTION_CONFIRM=i-understand-real-funds');
  }
  const need = (k: string) => {
    const v = env[P + k];
    if (!v) throw new ConfigError(`missing ${P + k}`);
    return v;
  };
  const appId = need('APP_ID');
  need('APP_SECRET');
  need('WEBHOOK_SECRET');
  if (env[other + 'APP_ID'] && env[other + 'APP_ID'] === appId) {
    throw new ConfigError('sandbox and production App IDs are identical; refusing to start');
  }
  const extraIps = knockEnv === 'sandbox' ? (env.BREET_SANDBOX_EXTRA_WEBHOOK_IPS ?? '').split(',').map((s) => s.trim()).filter(Boolean) : [];
  return {
    env: knockEnv,
    baseUrl: (knockEnv === 'sandbox' ? env.BREET_SANDBOX_BASE_URL : undefined) ?? 'https://api.breet.io/v1',
    appId: () => need('APP_ID'),
    appSecret: () => need('APP_SECRET'),
    withdrawalPin: () => need('WITHDRAWAL_PIN'),
    webhookSecrets: () => [env[P + 'WEBHOOK_SECRET'], env[P + 'WEBHOOK_SECRET_PREVIOUS']].filter((s): s is string => !!s),
    webhookIps: [...BREET_WEBHOOK_IPS, ...extraIps],
    timeoutMs: Number(env.BREET_TIMEOUT_MS ?? 15000),
    appIdFingerprint: fingerprint(appId),
  };
}

export const fingerprint = (s: string) => createHash('sha256').update(s).digest('hex').slice(0, 12);
