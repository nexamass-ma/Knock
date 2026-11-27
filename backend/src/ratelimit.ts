// Fixed-window rate limiter. In-memory is fine for one instance; on Supabase
// Edge Functions (many instances) back it with Postgres or Upstash Redis.
export class RateLimiter {
  private hits = new Map<string, { n: number; reset: number }>();
  private limit: number;
  private windowMs: number;
  constructor(limit: number, windowMs: number) {
    this.limit = limit;
    this.windowMs = windowMs;
  }
  take(key: string, now = Date.now()): boolean {
    const h = this.hits.get(key);
    if (!h || h.reset <= now) {
      this.hits.set(key, { n: 1, reset: now + this.windowMs });
      return true;
    }
    if (h.n >= this.limit) return false;
    h.n++;
    return true;
  }
}
