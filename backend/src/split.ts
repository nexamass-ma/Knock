// Pure split maths, shared by the API (previews, validation) and tests.
// The database (knock.split_amount / knock.distribute_payment) is the
// authority when money moves; tests assert both give identical results.

export type SplitMethod = 'fixed' | 'percentage';
export type AllocationMode = 'exact' | 'remainder_to_creator';

/** Asset decimals for minor-unit conversion. */
export const DECIMALS: Record<string, number> = { NGN: 2, USDT: 6, USDC: 6, BTC: 8 };

/**
 * Largest-remainder apportionment. Parts are integers that always add up to
 * `total` exactly. Ties go to the earlier position (deterministic), matching
 * knock.split_amount in SQL.
 */
export function splitAmount(total: bigint, weights: bigint[]): bigint[] {
  if (weights.length === 0) return [];
  if (total < 0n) throw new Error('total must not be negative');
  let wSum = 0n;
  for (const w of weights) {
    if (w < 0n) throw new Error('negative weight');
    wSum += w;
  }
  if (wSum === 0n) throw new Error('weights sum to zero');
  const parts = weights.map((w) => (total * w) / wSum);
  const rems = weights.map((w) => (total * w) % wSum);
  let leftover = total - parts.reduce((a, b) => a + b, 0n);
  while (leftover > 0n) {
    let best = -1;
    for (let i = 0; i < weights.length; i++) {
      if (weights[i] > 0n && (best === -1 || rems[i] > rems[best])) best = i;
    }
    parts[best] += 1n;
    rems[best] = -1n;
    leftover -= 1n;
  }
  return parts;
}

/** Knock fee, half-up rounding, matching knock.quote_fee. */
export function quoteFee(amount: bigint, bps: number, minFee = 0n, capFee: bigint | null = null): bigint {
  let v = (amount * BigInt(bps) + 5000n) / 10000n;
  if (v < minFee) v = minFee;
  if (capFee !== null && v > capFee) v = capFee;
  return v > amount ? amount : v;
}

export interface RecipientInput {
  recipientId: string;
  username?: string;
  allocatedAmount?: bigint; // fixed
  basisPoints?: number; // percentage, 10000 = 100%
}

export interface RecipientRule {
  recipientId: string;
  username?: string;
  allocatedAmount: bigint;
  basisPoints: number;
  isCreatorRemainder: boolean;
}

export class SplitValidationError extends Error {
  code: string;
  constructor(code: string, message: string) {
    super(message);
    this.code = code;
  }
}

/** Mirrors knock.build_recipients so the app can show errors before submit. */
export function buildRecipients(
  creatorId: string,
  method: SplitMethod,
  target: bigint | null,
  mode: AllocationMode,
  input: RecipientInput[],
): RecipientRule[] {
  if (input.length === 0) throw new SplitValidationError('invalid_recipients', 'add at least one recipient');
  const seen = new Set<string>();
  for (const r of input) {
    if (seen.has(r.recipientId)) throw new SplitValidationError('invalid_recipients', `@${r.username ?? r.recipientId} is listed twice`);
    seen.add(r.recipientId);
  }
  const ids = input.map((r) => r.recipientId);
  const names = input.map((r) => r.username);
  let creatorIdx = -1;
  if (method === 'fixed') {
    if (target === null) throw new SplitValidationError('invalid_target', 'a fixed split needs a total amount');
    const amts = input.map((r) => {
      if (!r.allocatedAmount || r.allocatedAmount <= 0n) throw new SplitValidationError('invalid_recipients', 'each recipient needs an amount above zero');
      return r.allocatedAmount;
    });
    const sum = amts.reduce((a, b) => a + b, 0n);
    if (sum > target) throw new SplitValidationError('allocation_mismatch', `allocations (${sum}) exceed the total (${target})`);
    if (sum < target) {
      if (mode !== 'remainder_to_creator') throw new SplitValidationError('allocation_mismatch', `allocations (${sum}) must add up to the total (${target})`);
      creatorIdx = ids.indexOf(creatorId);
      if (creatorIdx === -1) {
        ids.push(creatorId);
        names.push(undefined);
        amts.push(target - sum);
        creatorIdx = ids.length - 1;
      } else amts[creatorIdx] += target - sum;
    }
    const bps = splitAmount(10000n, amts);
    return ids.map((id, i) => ({ recipientId: id, username: names[i], allocatedAmount: amts[i], basisPoints: Number(bps[i]), isCreatorRemainder: i === creatorIdx }));
  }
  const bps = input.map((r) => {
    if (!r.basisPoints || r.basisPoints <= 0) throw new SplitValidationError('invalid_recipients', 'each recipient needs a percentage above zero');
    return BigInt(r.basisPoints);
  });
  const sum = bps.reduce((a, b) => a + b, 0n);
  if (sum > 10000n) throw new SplitValidationError('allocation_mismatch', 'percentages add up to more than 100%');
  if (sum < 10000n) {
    if (mode !== 'remainder_to_creator') throw new SplitValidationError('allocation_mismatch', 'percentages must add up to 100%');
    creatorIdx = ids.indexOf(creatorId);
    if (creatorIdx === -1) {
      ids.push(creatorId);
      names.push(undefined);
      bps.push(10000n - sum);
      creatorIdx = ids.length - 1;
    } else bps[creatorIdx] += 10000n - sum;
  }
  const amts = target === null ? bps.map(() => 0n) : splitAmount(target, bps);
  return ids.map((id, i) => ({ recipientId: id, username: names[i], allocatedAmount: amts[i], basisPoints: Number(bps[i]), isCreatorRemainder: i === creatorIdx }));
}

export interface PreviewShare {
  recipientId: string;
  gross: bigint;
  fee: bigint;
  net: bigint;
  overflow: boolean;
}

/**
 * What each recipient gets from one payment. `received` holds gross already
 * credited per recipient on this link (fixed splits fill toward targets).
 * Mirrors knock.distribute_payment.
 */
export function previewPayment(opts: {
  method: SplitMethod;
  rules: RecipientRule[];
  creatorId: string;
  amount: bigint; // amount credited to the link
  knockFee: bigint;
  feeBearer: 'deduct' | 'payer';
  received?: Map<string, bigint>;
}): PreviewShare[] {
  const { method, rules, creatorId, amount } = opts;
  const feeDeduct = opts.feeBearer === 'deduct' ? opts.knockFee : 0n;
  let ids = rules.map((r) => r.recipientId);
  let overflow = ids.map(() => false);
  let g: bigint[];
  if (method === 'fixed') {
    const rem = rules.map((r) => {
      const left = r.allocatedAmount - (opts.received?.get(r.recipientId) ?? 0n);
      return left > 0n ? left : 0n;
    });
    const remTotal = rem.reduce((a, b) => a + b, 0n);
    if (remTotal === 0n) {
      ids = [creatorId];
      overflow = [true];
      g = [amount];
    } else if (amount <= remTotal) {
      g = splitAmount(amount, rem);
    } else {
      g = [...rem, amount - remTotal];
      ids = [...ids, creatorId];
      overflow = [...overflow, true];
    }
  } else {
    g = splitAmount(amount, rules.map((r) => BigInt(r.basisPoints)));
  }
  const f = feeDeduct > 0n ? splitAmount(feeDeduct, g) : g.map(() => 0n);
  return ids
    .map((id, i) => ({ recipientId: id, gross: g[i], fee: f[i], net: g[i] - f[i], overflow: overflow[i] }))
    .filter((s) => s.gross > 0n);
}

/** "₦500,000.00" style display for minor units. */
export function formatMinor(amount: bigint, currency: string): string {
  const d = DECIMALS[currency] ?? 2;
  const neg = amount < 0n;
  const abs = neg ? -amount : amount;
  const base = 10n ** BigInt(d);
  const whole = (abs / base).toString().replace(/\B(?=(\d{3})+(?!\d))/g, ',');
  let frac = (abs % base).toString().padStart(d, '0');
  if (currency !== 'NGN') frac = frac.replace(/0+$/, '').padEnd(2, '0');
  const sym = currency === 'NGN' ? '₦' : '';
  const suffix = currency === 'NGN' ? '' : ` ${currency}`;
  return `${neg ? '-' : ''}${sym}${whole}${d > 0 ? '.' + frac : ''}${suffix}`;
}

/** Parse "500000", "500,000.50" (major units) into minor units. */
export function parseMajor(input: string, currency: string): bigint {
  const d = DECIMALS[currency] ?? 2;
  const s = input.replace(/[₦,\s]/g, '');
  const m = /^(\d+)(?:\.(\d+))?$/.exec(s);
  if (!m) throw new SplitValidationError('invalid_amount', `"${input}" is not an amount`);
  const frac = (m[2] ?? '').padEnd(d, '0');
  if (frac.length > d) throw new SplitValidationError('invalid_amount', `${currency} has at most ${d} decimals`);
  return BigInt(m[1]) * 10n ** BigInt(d) + BigInt(frac || '0');
}
