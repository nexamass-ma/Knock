// Breet adapter: the ONLY code that talks to https://api.breet.io/v1.
//
// Field names follow docs.breet.io as read on 2026-11-27. Where the docs
// were silent (crypto-withdrawal response key, validate-address body, sell
// asset list shape, the deposit record's credited-amount field) the parser
// accepts the documented candidates and the gaps are listed in
// docs/BREET_INTEGRATION.md for confirmation in sandbox.
import { randomUUID, timingSafeEqual } from 'node:crypto';
import type { BreetConfig } from '../config.ts';
import { dec, int, isoTime, parseExact, str } from '../json.ts';
import type {
  BankWithdrawalRequest, CryptoProvider, CryptoWithdrawalRequest, DepositStatus, EnvelopeMeta, GeneratedAddress,
  NetworkFeeEstimate, Page, ProviderAsset, ProviderDeposit, ProviderErrorCode, ProviderEvent, ProviderWithdrawal,
  SubmitOutcome, WithdrawalStatus,
} from '../provider.ts';
import { ProviderError } from '../provider.ts';
import type { RateGate } from '../ratelimit.ts';

export interface ApiLogRow {
  provider: string;
  environment: string;
  correlationId: string;
  method: string;
  route: string;
  httpStatus: number | null;
  outcome: string;
  durationMs: number;
  rateLimitLimit?: number | null;
  rateLimitRemaining?: number | null;
  rateLimitReset?: string | null;
  retryAfterS?: number | null;
  errorMessage?: string | null;
}
export type ApiLogger = (row: ApiLogRow) => Promise<void> | void;

interface Call {
  method: 'GET' | 'POST' | 'PUT';
  path: string; // concrete path
  route: string; // templated route for limits and logs, e.g. "GET /trades/transactions/:id"
  body?: Record<string, unknown>;
  query?: Record<string, string | number | undefined>;
  financial?: boolean; // never auto-retried
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

// Diagnostics-only message classification. Money handling never depends on
// these: every 4xx on a withdrawal POST means "not accepted, nothing debited",
// and the reservation is released the same way whatever the text says. The
// patterns only choose which customer message to show.
const MESSAGE_PATTERNS: Array<[RegExp, ProviderErrorCode]> = [
  [/duplicate withdrawal/i, 'duplicate_withdrawal'],
  [/insufficient (wallet )?balance/i, 'insufficient_provider_balance'],
  [/(unable|cannot|can't|could not).{0,40}(price|process|fulfil|fill)|liquidity|capacity/i, 'capacity'],
];

function classify(status: number, message: string): ProviderErrorCode {
  for (const [re, code] of MESSAGE_PATTERNS) if (re.test(message)) return code;
  if (status === 400) return 'bad_request';
  if (status === 401) return 'auth_failed';
  if (status === 403) return 'forbidden';
  if (status === 404) return 'not_found';
  if (status === 409) return 'conflict';
  if (status === 422) return 'validation';
  if (status === 429) return 'rate_limited';
  return 'server_error';
}

export class BreetAdapter implements CryptoProvider {
  readonly name = 'breet';
  readonly env;
  private cfg: BreetConfig;
  private gate: RateGate;
  private log: ApiLogger;
  private fetchImpl: typeof fetch;
  private maxRateWaitMs: number;

  constructor(cfg: BreetConfig, gate: RateGate, log: ApiLogger, opts: { fetch?: typeof fetch; maxRateWaitMs?: number } = {}) {
    this.cfg = cfg;
    this.env = cfg.env;
    this.gate = gate;
    this.log = log;
    this.fetchImpl = opts.fetch ?? fetch;
    this.maxRateWaitMs = opts.maxRateWaitMs ?? 65_000;
  }

  // -------------------------------------------------------------------------
  // Transport

  private async request(c: Call): Promise<{ status: number; body: any; headers: Headers }> {
    const attempts = c.financial || c.method !== 'GET' ? 1 : 4;
    let last: ProviderError | null = null;
    for (let attempt = 1; attempt <= attempts; attempt++) {
      // Shared rate limit, waiting when the window is full or the route is paused.
      let waited = 0;
      for (;;) {
        const w = await this.gate.take(c.route);
        if (w === 0) break;
        if (waited + w > this.maxRateWaitMs) throw new ProviderError('rate_limited', `rate limit for ${c.route}`, 429, Math.ceil(w / 1000));
        await sleep(w);
        waited += w;
      }
      const correlationId = randomUUID();
      const url = new URL(this.cfg.baseUrl.replace(/\/$/, '') + c.path);
      for (const [k, v] of Object.entries(c.query ?? {})) if (v !== undefined) url.searchParams.set(k, String(v));
      const started = Date.now();
      let res: Response;
      let text: string;
      try {
        res = await this.fetchImpl(url, {
          method: c.method,
          headers: {
            'content-type': 'application/json',
            accept: 'application/json',
            'x-app-id': this.cfg.appId(),
            'x-app-secret': this.cfg.appSecret(),
            'X-Breet-Env': this.cfg.env, // derived from the same config as the keys
            'x-request-id': correlationId,
          },
          body: c.body ? JSON.stringify(c.body) : undefined,
          signal: AbortSignal.timeout(this.cfg.timeoutMs),
        });
        text = await res.text();
      } catch (e) {
        const timeout = e instanceof Error && (e.name === 'TimeoutError' || e.name === 'AbortError');
        await this.log({ provider: this.name, environment: this.env, correlationId, method: c.method, route: c.route, httpStatus: null,
          outcome: timeout ? 'timeout' : 'network_error', durationMs: Date.now() - started, errorMessage: timeout ? 'timeout' : String((e as Error).message ?? e).slice(0, 200) });
        last = new ProviderError(timeout ? 'timeout' : 'network_error', timeout ? 'provider timed out' : 'provider unreachable');
        if (attempt < attempts) { await sleep(backoff(attempt)); continue; }
        throw last;
      }
      const rl = {
        rateLimitLimit: int(res.headers.get('x-ratelimit-limit')),
        rateLimitRemaining: int(res.headers.get('x-ratelimit-remaining')),
        rateLimitReset: res.headers.get('x-ratelimit-reset'),
        retryAfterS: int(res.headers.get('retry-after')),
      };
      let body: any = null;
      try { body = text ? parseExact(text) : null; } catch { body = null; } // 429/500 may not be JSON
      const ok = res.status >= 200 && res.status < 300 && (body?.success === undefined || body.success === true);
      const message = typeof body?.message === 'string' ? body.message : '';
      const code = ok ? null : classify(res.status, message);
      await this.log({ provider: this.name, environment: this.env, correlationId, method: c.method, route: c.route, httpStatus: res.status,
        outcome: ok ? 'ok' : code === 'capacity' ? 'capacity' : res.status === 429 ? 'rate_limited' : res.status >= 500 ? 'server_error' : 'client_error',
        durationMs: Date.now() - started, ...rl, errorMessage: ok ? null : message.slice(0, 300) || null });
      if (ok) return { status: res.status, body, headers: res.headers };

      if (res.status === 429) {
        const wait = rl.retryAfterS ?? 60;
        await this.gate.pause(c.route, wait);
        last = new ProviderError('rate_limited', 'provider rate limit', 429, wait);
        if (attempt < attempts) continue; // the gate now waits for Retry-After
        throw last;
      }
      last = new ProviderError(code!, message || `HTTP ${res.status}`, res.status, rl.retryAfterS);
      if (res.status >= 500 && attempt < attempts) { await sleep(backoff(attempt)); continue; }
      throw last;
    }
    throw last ?? new ProviderError('server_error', 'request failed');
  }

  private async data(c: Call) {
    const r = await this.request(c);
    return { data: r.body?.data, meta: r.body?.meta, body: r.body };
  }

  // -------------------------------------------------------------------------
  // Health and assets

  async health() {
    try {
      const r = await this.data({ method: 'GET', path: '/payments/supported-assets-info', route: 'GET /payments/supported-assets-info' });
      return { ok: true, detail: { tokens: Array.isArray(r.data?.tokens) ? r.data.tokens.length : null } };
    } catch (e) {
      const pe = e as ProviderError;
      return { ok: false, detail: { code: pe.code, status: pe.httpStatus } };
    }
  }

  async listAssets(): Promise<ProviderAsset[]> {
    const out: ProviderAsset[] = [];
    // Deposit (sell) assets.
    const sell = await this.data({ method: 'GET', path: '/trades/assets', route: 'GET /trades/assets' });
    const sellList: any[] = Array.isArray(sell.data) ? sell.data : Array.isArray(sell.data?.assets) ? sell.data.assets : [];
    for (const a of sellList) {
      const id = str(a.id ?? a._id ?? a.assetId);
      if (!id) continue;
      out.push({
        assetId: id,
        symbol: String(a.symbol ?? a.code ?? a.name ?? id).toUpperCase(),
        network: String(a.network ?? a.chain ?? '').toUpperCase(),
        kind: 'crypto',
        depositEnabled: a.enabled !== false && a.isActive !== false && a.status !== 'disabled',
        withdrawEnabled: false,
        minDeposit: dec(a.minimum ?? a.minDeposit ?? a.min),
        raw: a,
      });
    }
    // Withdrawal assets and fees.
    const wd = await this.data({ method: 'GET', path: '/payments/supported-assets-info', route: 'GET /payments/supported-assets-info' });
    const limits = wd.data?.limits ?? {};
    for (const t of Array.isArray(wd.data?.tokens) ? wd.data.tokens : []) {
      const symbol = String(t.symbol).toUpperCase();
      const nets: any[] = Array.isArray(t.networks) && t.networks.length ? t.networks : [{ network: '', enabled: t.enabled, fee: t.fee }];
      for (const n of nets) {
        out.push({
          assetId: `withdraw:${symbol}`,
          symbol,
          network: String(n.network ?? '').toUpperCase(),
          kind: ['BTC', 'LTC', 'DOGE', 'BCH'].includes(symbol) ? 'utxo' : ['USDT', 'USDC'].includes(symbol) ? 'stablecoin' : 'crypto',
          depositEnabled: false,
          withdrawEnabled: t.enabled === true && n.enabled !== false,
          withdrawalFee: dec(n.fee ?? t.fee),
          withdrawalFeeCurrency: 'USD',
          minWithdrawal: dec(limits.minimum),
          raw: { token: { ...t, networks: undefined }, network: n, limits },
        });
      }
    }
    return out;
  }

  // -------------------------------------------------------------------------
  // Addresses

  async generateAddress(assetId: string, o: { label: string; bankId?: string; accountNumber?: string; narration?: string; autoSettlement?: boolean }) {
    const body: Record<string, unknown> = { label: o.label };
    if (o.bankId && o.accountNumber) {
      body.bankId = o.bankId;
      body.accountNumber = o.accountNumber;
      if (o.narration) body.narration = o.narration.slice(0, 32);
      if (o.autoSettlement !== undefined) body.autoSettlement = o.autoSettlement;
    }
    const r = await this.data({ method: 'POST', path: `/trades/sell/assets/${encodeURIComponent(assetId)}/generate-address`,
      route: 'POST /trades/sell/assets/:id/generate-address', body });
    const id = str(r.data?.id);
    const address = str(r.data?.address);
    if (!id || !address) throw new ProviderError('server_error', 'generate-address response missing id/address');
    return { providerAddressId: id, address, memo: str(r.data?.memo ?? r.data?.tag), raw: r.data };
  }

  async listAddresses(page: number, size: number) {
    const r = await this.data({ method: 'GET', path: '/trades/wallets', route: 'GET /trades/wallets', query: { page, size } });
    const items = (Array.isArray(r.data) ? r.data : []).map((w: any) => ({
      providerAddressId: String(w.id ?? w._id), address: String(w.address), memo: str(w.memo),
      asset: str(w.asset ?? w.assetId), label: str(w.label), raw: w,
    }));
    return pageOf(items, r.meta, page);
  }

  async setAutoSettlement(id: string, enabled: boolean) {
    await this.request({ method: 'PUT', path: `/trades/wallets/${encodeURIComponent(id)}/auto-settlement`, route: 'PUT /trades/wallets/:id/auto-settlement', body: { autoSettlement: enabled } });
  }

  async setAddressBank(id: string, b: { bankId: string; accountNumber: string; narration?: string }) {
    await this.request({ method: 'PUT', path: `/trades/wallets/${encodeURIComponent(id)}/bank`, route: 'PUT /trades/wallets/:id/bank',
      body: { bankId: b.bankId, accountNumber: b.accountNumber, ...(b.narration ? { narration: b.narration.slice(0, 32) } : {}) } });
  }

  // -------------------------------------------------------------------------
  // Deposits

  async getDeposit(tradeId: string) {
    const r = await this.data({ method: 'GET', path: `/trades/transactions/${encodeURIComponent(tradeId)}`, route: 'GET /trades/transactions/:id' });
    if (!r.data) throw new ProviderError('not_found', 'transaction not found', 404);
    return normalizeDeposit(r.data, null);
  }

  async listDeposits(page: number, size: number) {
    const r = await this.data({ method: 'GET', path: '/trades/transactions', route: 'GET /trades/transactions', query: { page, size } });
    return pageOf((Array.isArray(r.data) ? r.data : []).map((d: any) => normalizeDeposit(d, null)), r.meta, page);
  }

  // -------------------------------------------------------------------------
  // Withdrawals

  async getWithdrawal(id: string) {
    const r = await this.data({ method: 'GET', path: `/payments/withdrawal/${encodeURIComponent(id)}`, route: 'GET /payments/withdrawal/:id' });
    if (!r.data) throw new ProviderError('not_found', 'withdrawal not found', 404);
    return normalizeWithdrawal(r.data, null);
  }

  async listWithdrawals(page: number, size: number) {
    const r = await this.data({ method: 'GET', path: '/payments/withdrawals', route: 'GET /payments/withdrawals', query: { page, size } });
    return pageOf((Array.isArray(r.data) ? r.data : []).map((w: any) => normalizeWithdrawal(w, null)), r.meta, page);
  }

  async validateAddress(token: string, network: string | null, address: string) {
    const r = await this.data({ method: 'POST', path: '/payments/wallet-addresses/validate', route: 'POST /payments/wallet-addresses/validate',
      body: { token, ...(network ? { network } : {}), walletAddress: address } });
    const d = r.data ?? {};
    const valid = d.valid ?? d.isValid ?? (d.status !== undefined ? d.status === 'valid' : true);
    return { valid: valid === true, raw: d };
  }

  async estimateNetworkFee(token: string, cryptoAmount: string, walletAddress: string): Promise<NetworkFeeEstimate> {
    const r = await this.request({ method: 'POST', path: '/payments/estimate-network-fee', route: 'POST /payments/estimate-network-fee',
      body: { token, cryptoAmount: numberBody(cryptoAmount), walletAddress } });
    const d = r.body?.data ?? r.body ?? {};
    const lvl = (k: string) => ({ networkFee: dec(d[k]?.networkFee), networkFeeUsd: dec(d[k]?.networkFeeUsd) });
    return { low: lvl('low'), medium: lvl('medium'), high: lvl('high') };
  }

  withdrawCrypto(req: CryptoWithdrawalRequest) {
    const body: Record<string, unknown> = {
      amount: numberBody(req.amountUsd), token: req.token, walletAddress: req.walletAddress,
      pin: this.cfg.withdrawalPin(), externalId: req.externalId,
    };
    if (req.network) body.network = req.network;
    if (req.feeLevel) body.feeLevel = req.feeLevel;
    return this.submit({ method: 'POST', path: '/payments/withdraw/address', route: 'POST /payments/withdraw/address', body, financial: true });
  }

  withdrawBank(req: BankWithdrawalRequest) {
    const body: Record<string, unknown> = { amount: numberBody(req.amount), pin: this.cfg.withdrawalPin(), externalId: req.externalId };
    if (req.narration) body.narration = req.narration.slice(0, 32);
    return this.submit({ method: 'POST', path: `/payments/withdraw/bank/${encodeURIComponent(req.savedAccountId)}`, route: 'POST /payments/withdraw/bank/:id', body, financial: true });
  }

  /** Financial POST: one attempt. Timeouts and 5xx are "unknown", never retried. */
  private async submit(c: Call): Promise<SubmitOutcome> {
    try {
      const r = await this.request(c);
      const d = r.body?.data ?? {};
      const id = str(d.id ?? d._id ?? d.withdrawalId ?? d.reference);
      if (!id) return { outcome: 'unknown', code: 'server_error', message: 'accepted without an id' };
      return { outcome: 'accepted', providerId: id, raw: d };
    } catch (e) {
      const pe = e as ProviderError;
      if (pe.code === 'timeout' || pe.code === 'network_error' || pe.code === 'server_error') {
        return { outcome: 'unknown', code: pe.code, message: pe.message };
      }
      return { outcome: 'rejected', code: pe.code, message: pe.message };
    }
  }

  // -------------------------------------------------------------------------
  // Webhooks

  authenticateWebhook(_raw: string, headers: Headers, sourceIp: string | null) {
    if (!sourceIp || !this.cfg.webhookIps.includes(sourceIp)) return { ok: false, reason: 'source_ip_not_allowed' };
    const got = headers.get('x-webhook-secret');
    if (!got) return { ok: false, reason: 'missing_secret' };
    const g = Buffer.from(got, 'utf8');
    const match = this.cfg.webhookSecrets().some((s) => {
      const b = Buffer.from(s, 'utf8');
      return b.length === g.length && timingSafeEqual(b, g);
    });
    return match ? { ok: true } : { ok: false, reason: 'bad_secret' };
  }

  parseWebhook(raw: string): { meta: EnvelopeMeta; event: ProviderEvent } {
    const b = parseExact(raw);
    if (!b || typeof b !== 'object' || typeof b.event !== 'string' || !b.eventId) throw new ProviderError('validation', 'not a Breet event');
    const meta: EnvelopeMeta = { eventId: String(b.eventId), eventType: b.event, eventTime: isoTime(b.eventTime), resourceId: str(b.id) };
    const type: string = b.event;
    let event: ProviderEvent;
    if (type === 'trade.address.created') {
      event = { kind: 'address.created', address: { providerAddressId: String(b.id), address: String(b.address), memo: str(b.memo), asset: String(b.asset), label: String(b.label ?? ''), raw: b } };
    } else if (type === 'trade.settlement.failed') {
      event = { kind: 'settlement.failed', tradeId: String(b.id), amount: dec(b.amount), currency: str(b.currency)?.toUpperCase() ?? null, reason: str(b.reason) };
    } else if (type.startsWith('trade.')) {
      event = { kind: 'deposit', deposit: normalizeDeposit(b, type) };
    } else if (type.startsWith('withdrawal.')) {
      event = { kind: 'withdrawal', withdrawal: normalizeWithdrawal(b, type) };
    } else {
      event = { kind: 'unknown', type };
    }
    return { meta, event };
  }

  async listWebhookDeliveries(page: number, size: number, filter: { status?: 'delivered' | 'failed' } = {}) {
    const r = await this.data({ method: 'GET', path: '/transactions/webhooks', route: 'GET /transactions/webhooks', query: { page, size: Math.min(size, 200), status: filter.status } });
    return pageOf(Array.isArray(r.data) ? r.data : [], r.meta, page);
  }

  async resendWebhook(reference: string) {
    const r = await this.data({ method: 'POST', path: `/transactions/webhooks/resend/${encodeURIComponent(reference)}`, route: 'POST /transactions/webhooks/resend/:reference' });
    return r.data;
  }

  async mockTrade(body: Record<string, unknown>) {
    if (this.env !== 'sandbox') throw new ProviderError('forbidden', 'mock trades are sandbox-only');
    const r = await this.data({ method: 'POST', path: '/trades/sell/mock-trade', route: 'POST /trades/sell/mock-trade', body });
    return r.body;
  }
}

// ---------------------------------------------------------------------------
// Normalisation

function depositStatus(event: string | null, status: string | null, sub: string | null, balanceRemaining: string | null): DepositStatus {
  const s = (event ? event.replace('trade.', '') : status ?? '').toLowerCase();
  if (s === 'completed') return 'completed';
  if (s === 'deleted' || s === 'failed') return 'failed';
  if (s === 'flagged') {
    if ((sub ?? '').toLowerCase() === 'under_review') return 'under_review';
    if (balanceRemaining !== null && Number(balanceRemaining) > 0) return 'below_minimum';
    return 'flagged';
  }
  return 'pending';
}

export function normalizeDeposit(b: any, event: string | null): ProviderDeposit {
  const balanceRemaining = dec(b.balanceRemaining);
  const settled = Array.isArray(b.settledTrades) ? b.settledTrades.map(String) : null;
  return {
    tradeId: String(b.id ?? b._id),
    status: depositStatus(event, str(b.status), str(b.subStatus), balanceRemaining),
    subStatus: str(b.subStatus),
    asset: str(b.asset),
    destinationAddress: str(b.destinationAddress ?? b.address),
    walletId: str(typeof b.wallet === 'object' ? b.wallet?.id ?? b.wallet?._id : b.wallet),
    cryptoAmount: dec(b.cryptoAmount ?? b.cryptoReceived),
    amountInUsd: dec(b.amountInUSD ?? b.amountInUsd),
    amountCredited: dec(b.amountCredited ?? (typeof b.walletCredited !== 'boolean' ? b.walletCredited : undefined)),
    currency: str(b.currency)?.toUpperCase() ?? null,
    txHash: str(b.txHash),
    confirmations: int(b.confirmations),
    rate: dec(b.rate),
    conversionRate: dec(b.conversionRate),
    feeAmountUsd: dec(b.feeAmountInUsd ?? b.feeAmount),
    feePercentage: dec(b.feePercentage),
    balanceRemaining,
    isWrongAsset: b.isWrongAssetDeposit === true,
    settledTrades: settled,
    reason: str(b.reason),
    kyt: b.kyt ?? null,
    markupPercent: dec(b.markupPercent),
    markupAmount: dec(b.markupAmount),
    amountSettled: dec(b.amountSettled),
    raw: b,
  };
}

export function normalizeWithdrawal(b: any, event: string | null): ProviderWithdrawal {
  const s = (event ? event.replace('withdrawal.', '') : String(b.status ?? 'pending')).toLowerCase() as WithdrawalStatus;
  const meta = b.meta && typeof b.meta === 'object' ? b.meta : null;
  return {
    id: String(b.id ?? b._id),
    status: (['pending', 'processing', 'completed', 'reversed', 'rejected'] as const).includes(s as any) ? s : 'pending',
    amount: dec(b.amount),
    originalAmount: dec(b.originalAmount),
    payoutAmount: dec(b.payoutAmount),
    currency: str(b.currency)?.toUpperCase() ?? null,
    fee: dec(b.fee),
    feeBearer: (meta?.feeBearer === 'business' || meta?.feeBearer === 'user' ? meta.feeBearer : null) as any,
    txHash: str(b.txHash),
    reference: str(b.reference),
    externalId: str(b.externalId),
    trade: str(b.trade),
    cryptoAmount: dec(b.cryptoAmount),
    feeCrypto: dec(b.feeCrypto),
    reason: str(b.reason),
    meta: meta ? redactMeta(meta) : null,
    createdAt: isoTime(b.createdAt),
    updatedAt: isoTime(b.updatedAt),
    raw: b,
  };
}

/** Keep only the last 4 digits of any account number in stored metadata. */
function redactMeta(m: Record<string, unknown>) {
  const out: Record<string, unknown> = { ...m };
  for (const k of ['accountNumber', 'account']) {
    const v = out[k];
    if (typeof v === 'string' && /\d{6,}/.test(v)) out[k] = '******' + v.replace(/\D/g, '').slice(-4);
  }
  return out;
}

function pageOf<T>(items: T[], meta: any, page: number): Page<T> {
  const hasNext = meta?.hasNextPage === true || (meta?.nextPage !== undefined && meta?.nextPage !== null && meta?.nextPage !== false);
  return { items, page: int(meta?.page) ?? page, hasNextPage: hasNext, totalDocs: int(meta?.totalDocs) ?? undefined };
}

const backoff = (attempt: number) => Math.min(8000, 250 * 2 ** attempt) * (0.5 + Math.random());

/** Breet's JSON bodies take numbers; send the exact decimal text as a JSON number. */
function numberBody(decimal: string): unknown {
  if (!/^\d+(\.\d+)?$/.test(decimal)) throw new ProviderError('validation', 'amount must be a positive decimal');
  return (JSON as any).rawJSON(decimal);
}
