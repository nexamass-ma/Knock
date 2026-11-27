import type { Db } from '../db.ts';
import type { ApiLogger } from './breet/adapter.ts';

/** Request metadata only: no headers, bodies, credentials or PINs. */
export const pgApiLogger = (db: Db): ApiLogger => async (r) => {
  await db.query(
    `insert into knock.provider_api_logs (provider, environment, correlation_id, method, route, http_status, outcome, duration_ms,
       rate_limit_limit, rate_limit_remaining, rate_limit_reset, retry_after_s, error_message)
     values ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13)`,
    [r.provider, r.environment, r.correlationId, r.method, r.route, r.httpStatus, r.outcome, r.durationMs,
     r.rateLimitLimit ?? null, r.rateLimitRemaining ?? null, r.rateLimitReset ?? null, r.retryAfterS ?? null, r.errorMessage ?? null],
  ).catch(() => {}); // logging must never break a financial call
};
