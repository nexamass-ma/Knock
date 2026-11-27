// JSON parsing that never turns money into floats. Numbers keep their exact
// source text (Node >= 21 passes it to the reviver), so "0.00025406" and
// "156000.5" reach Postgres numeric unchanged.
export type Exact = string;

export function parseExact(text: string): any {
  return (JSON.parse as any)(text, (_k: string, v: unknown, ctx?: { source?: string }) =>
    typeof v === 'number' && ctx?.source !== undefined ? new ExactNumber(ctx.source) : v,
  );
}

/** A JSON number kept as its decimal text. */
export class ExactNumber {
  readonly text: string;
  constructor(text: string) {
    this.text = text;
  }
  toString() {
    return this.text;
  }
  toJSON() {
    return this.text;
  }
}

/** Decimal text for a provider value (number, ExactNumber or numeric string), else null. */
export function dec(v: unknown): string | null {
  if (v === null || v === undefined || v === '') return null;
  if (v instanceof ExactNumber) return normalizeDecimal(v.text);
  if (typeof v === 'string' && /^-?\d+(\.\d+)?([eE][-+]?\d+)?$/.test(v.trim())) return normalizeDecimal(v.trim());
  if (typeof v === 'number' && Number.isFinite(v)) return normalizeDecimal(String(v));
  return null;
}

function normalizeDecimal(s: string): string {
  if (!/[eE]/.test(s)) return s;
  // Expand exponent form without floating point.
  const m = /^(-?)(\d+)(?:\.(\d+))?[eE]([-+]?\d+)$/.exec(s)!;
  const [, sign, int, frac = '', expS] = m;
  const exp = Number(expS);
  let digits = int + frac;
  let point = int.length + exp;
  if (point <= 0) return `${sign}0.${'0'.repeat(-point)}${digits}`.replace(/\.?0+$/, '') || '0';
  if (point >= digits.length) return sign + digits + '0'.repeat(point - digits.length);
  return `${sign}${digits.slice(0, point)}.${digits.slice(point)}`;
}

export const str = (v: unknown): string | null => (v === null || v === undefined || v === '' ? null : String(v));
export const int = (v: unknown): number | null => {
  const d = dec(v);
  return d === null ? null : Number.parseInt(d, 10);
};

/** eventTime / createdAt may be ISO strings or epoch milliseconds. */
export function isoTime(v: unknown): string | null {
  if (v === null || v === undefined || v === '') return null;
  const d = dec(v);
  if (d !== null && !String(v).includes('-')) return new Date(Number(d)).toISOString();
  const t = new Date(String(v));
  return Number.isNaN(t.getTime()) ? null : t.toISOString();
}

/** Serialize for Postgres jsonb, keeping bigint and exact numbers as strings. */
export const toJson = (v: unknown) => JSON.stringify(v, (_, x) => (typeof x === 'bigint' ? x.toString() : x));
