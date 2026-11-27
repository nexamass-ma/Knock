// Thin Postgres access. Every money operation is one call to a knock.*
// function inside one transaction. Errors raised as "code: message" by
// knock.fail() become ApiError with that code.
import pg from 'pg';

export class ApiError extends Error {
  code: string;
  status: number;
  constructor(code: string, message: string, status = 400) {
    super(message);
    this.code = code;
    this.status = status;
  }
}

const STATUS: Record<string, number> = { not_found: 404, forbidden: 403, kyc_required: 403, rate_limited: 429 };

export function toApiError(e: unknown): ApiError {
  if (e instanceof ApiError) return e;
  const msg = e instanceof Error ? e.message : String(e);
  const m = /^([a-z_]+): (.*)$/s.exec(msg);
  if (m) return new ApiError(m[1], m[2], STATUS[m[1]] ?? 400);
  return new ApiError('internal', 'Something went wrong', 500);
}

export interface Db {
  query<T = any>(sql: string, params?: unknown[]): Promise<T[]>;
  /** Run fn in one transaction; rolls back on any error. */
  tx<T>(fn: (q: Db['query']) => Promise<T>): Promise<T>;
  close(): Promise<void>;
}

export function createDb(connectionString: string): Db {
  const pool = new pg.Pool({ connectionString, max: 10 });
  pool.on('connect', (c) => void c.query('set search_path = knock, public'));
  return {
    async query(sql, params) {
      try {
        return (await pool.query(sql, params as any[])).rows;
      } catch (e) {
        throw toApiError(e);
      }
    },
    async tx(fn) {
      const c = await pool.connect();
      try {
        await c.query('begin');
        const out = await fn(async (sql, params) => (await c.query(sql, params as any[])).rows);
        await c.query('commit');
        return out;
      } catch (e) {
        await c.query('rollback').catch(() => {});
        throw toApiError(e);
      } finally {
        c.release();
      }
    },
    close: () => pool.end(),
  };
}

/** Call a knock.* function that returns one value. */
export async function call<T = any>(q: Db['query'], fn: string, ...args: unknown[]): Promise<T> {
  const ph = args.map((_, i) => `$${i + 1}`).join(', ');
  const rows = await q<{ r: T }>(`select knock.${fn}(${ph}) as r`, args);
  return rows[0]?.r as T;
}
