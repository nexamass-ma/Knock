// Breet's limits are per integration and per route, so every instance and
// worker sharing the credentials must share one counter: it lives in Postgres
// (knock.take_rate_slot). A 429 pauses the route for Retry-After.
import type { Db } from '../db.ts';

export const BREET_ROUTE_LIMITS: Record<string, number> = {
  'POST /payments/withdraw/address': 200,
  'POST /payments/estimate-network-fee': 5,
  'POST /payments/wallet-addresses': 5,
};
export const BREET_DEFAULT_LIMIT = 500;

export interface RateGate {
  /** 0 = go; otherwise milliseconds to wait. */
  take(route: string): Promise<number>;
  pause(route: string, seconds: number): Promise<void>;
}

export class PgRateGate implements RateGate {
  private db: Db;
  private provider: string;
  private limits: Record<string, number>;
  private fallback: number;
  constructor(db: Db, provider: string, limits = BREET_ROUTE_LIMITS, fallback = BREET_DEFAULT_LIMIT) {
    this.db = db;
    this.provider = provider;
    this.limits = limits;
    this.fallback = fallback;
  }
  async take(route: string) {
    const limit = this.limits[route] ?? this.fallback;
    // Unlisted routes share the "all other endpoints" bucket per route.
    const rows = await this.db.query<{ w: number }>('select knock.take_rate_slot($1, $2, $3) as w', [this.provider, route, limit]);
    return rows[0].w;
  }
  async pause(route: string, seconds: number) {
    await this.db.query('select knock.pause_rate_route($1, $2, $3)', [this.provider, route, Math.max(1, Math.ceil(seconds))]);
  }
}

export class MemoryRateGate implements RateGate {
  async take() {
    return 0;
  }
  async pause() {}
}
