// Crypto engine: deposits, withdrawals, settlements and webhook processing
// for any CryptoProvider. Rules (from the Breet brief, enforced here and in
// the 0400 migration):
//   * A webhook is authenticated, stored durably, acknowledged, and processed
//     later by a worker. It never moves money by itself.
//   * Before any ledger change the worker re-fetches the provider's record and
//     only applies a state the provider confirms.
//   * Financial POSTs are sent once. An uncertain outcome is resolved from the
//     provider's records by our externalId, never by sending again.
import { randomUUID } from 'node:crypto';
import { ApiError, call, type Db } from '../db.ts';
import { dec, toJson } from './json.ts';
import type { CryptoProvider, ProviderDeposit, ProviderEvent, ProviderWithdrawal, SubmitOutcome } from './provider.ts';
import { ProviderError } from './provider.ts';

export interface CryptoServiceDeps {
  db: Db;
  provider: CryptoProvider;
  /** Decrypts a stored bank account number (AES-GCM, key from the secrets manager). */
  decryptAccountNumber?: (enc: string) => string;
  now?: () => Date;
}

/** Backoff for webhook processing retries: 30s, 2m, 10m, 30m, 1h, 3h, 6h, 12h. */
const EVENT_RETRY_S = [30, 120, 600, 1800, 3600, 10800, 21600, 43200];
const RETRYABLE = new Set(['not_ready', 'unknown_address', 'unknown_withdrawal', 'provider_unavailable', 'provider_not_confirmed']);

class Retry extends Error {
  code: string;
  constructor(code: string, message: string) {
    super(message);
    this.code = code;
  }
}
class Manual extends Error {
  code: string;
  constructor(code: string, message: string) {
    super(message);
    this.code = code;
  }
}

const DEPOSIT_ORDER: Record<string, number> = { pending: 1, below_minimum: 2, flagged: 2, under_review: 3, completed: 9, failed: 9 };
const WITHDRAWAL_ORDER: Record<string, number> = { pending: 1, processing: 2, completed: 9, reversed: 9, rejected: 9 };

export class CryptoService {
  readonly db: Db;
  readonly provider: CryptoProvider;
  private decrypt?: (enc: string) => string;

  constructor(d: CryptoServiceDeps) {
    this.db = d.db;
    this.provider = d.provider;
    this.decrypt = d.decryptAccountNumber;
  }

  private get p() {
    return this.provider.name;
  }

  // -------------------------------------------------------------------------
  // Start-up safety and health

  /** Refuse to run if the database was set up for the other environment. */
  async assertEnvironment(appIdFingerprint: string | null) {
    await this.db.query(
      `insert into knock.provider_accounts (provider, environment, app_id_fingerprint) values ($1, $2, $3) on conflict (provider) do nothing`,
      [this.p, this.provider.env, appIdFingerprint],
    );
    const [row] = await this.db.query<{ environment: string; app_id_fingerprint: string | null }>(
      'select environment, app_id_fingerprint from knock.provider_accounts where provider = $1', [this.p]);
    if (row.environment !== this.provider.env) {
      throw new Error(`database is configured for ${row.environment} ${this.p}, service is ${this.provider.env}; refusing to start`);
    }
    if (appIdFingerprint && row.app_id_fingerprint && row.app_id_fingerprint !== appIdFingerprint) {
      // Credential rotation: record it so it shows in the audit trail.
      await this.db.query('update knock.provider_accounts set app_id_fingerprint = $2 where provider = $1', [this.p, appIdFingerprint]);
      await this.db.query(`select knock.audit(null, 'system', 'provider.credentials_rotated', null, null, $1::jsonb)`, [toJson({ provider: this.p })]);
    }
  }

  async health() {
    const h = await this.provider.health();
    await this.db.query('update knock.provider_accounts set last_health_at = now(), last_health_ok = $2, last_health_detail = $3 where provider = $1',
      [this.p, h.ok, toJson(h.detail)]);
    return h;
  }

  async syncAssets() {
    const assets = await this.provider.listAssets();
    await this.db.tx(async (q) => {
      for (const a of assets) {
        await q(
          `insert into knock.provider_asset_configurations (provider, asset_id, symbol, network, kind, deposit_enabled, withdraw_enabled,
             min_deposit, withdrawal_fee, withdrawal_fee_currency, min_withdrawal, raw, synced_at)
           values ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12, now())
           on conflict (provider, asset_id, network) do update set symbol = excluded.symbol, kind = excluded.kind,
             deposit_enabled = excluded.deposit_enabled, withdraw_enabled = excluded.withdraw_enabled, min_deposit = excluded.min_deposit,
             withdrawal_fee = excluded.withdrawal_fee, withdrawal_fee_currency = excluded.withdrawal_fee_currency,
             min_withdrawal = excluded.min_withdrawal, raw = excluded.raw, synced_at = now()`,
          [this.p, a.assetId, a.symbol, a.network, a.kind, a.depositEnabled, a.withdrawEnabled, a.minDeposit ?? null,
           a.withdrawalFee ?? null, a.withdrawalFeeCurrency ?? null, a.minWithdrawal ?? null, toJson(a.raw)],
        );
      }
      // Anything the provider no longer lists is disabled, not deleted.
      await q(`update knock.provider_asset_configurations set deposit_enabled = false, withdraw_enabled = false
               where provider = $1 and synced_at < now() - interval '1 second' and not (asset_id || '|' || network = any($2))`,
        [this.p, assets.map((a) => `${a.assetId}|${a.network}`)]);
    });
    return assets.length;
  }

  // -------------------------------------------------------------------------
  // Deposit addresses

  async requestAddress(userId: string, body: { asset_id: string; network?: string; bank_account_id?: string; auto_settlement?: boolean }) {
    const [cfg] = await this.db.query<{ symbol: string; network: string }>(
      `select symbol, network from knock.provider_asset_configurations where provider = $1 and asset_id = $2 and network = coalesce($3, network) and deposit_enabled limit 1`,
      [this.p, body.asset_id, body.network ?? null]);
    if (!cfg) throw new ApiError('asset_unavailable', 'This asset is not currently available for deposits.');
    const r = await this.db.tx((q) => call<any>(q, 'request_deposit_address', userId, this.p, body.asset_id, cfg.symbol, cfg.network,
      body.bank_account_id ?? null, body.auto_settlement ?? false));
    const row = r.address;
    if (!r.created && row.status === 'active') return publicAddress(row);
    if (!r.created && row.status === 'requested' && Date.now() - new Date(row.created_at).getTime() < 60_000) {
      return publicAddress(row); // another request is generating it right now
    }

    let bank: { bankId: string; accountNumber: string } | undefined;
    if (row.bank_account_id) {
      const [b] = await this.db.query<any>('select provider_bank_id, account_number_enc from knock.bank_accounts where id = $1', [row.bank_account_id]);
      if (!this.decrypt) throw new ApiError('not_configured', 'bank account decryption is not configured', 500);
      bank = { bankId: b.provider_bank_id, accountNumber: this.decrypt(b.account_number_enc) };
    }
    try {
      const g = await this.provider.generateAddress(body.asset_id, { label: userId, ...(bank ?? {}), narration: 'Knock payout', autoSettlement: row.auto_settlement });
      await this.db.tx((q) => call(q, 'record_deposit_address', this.p, toJson({
        provider_address_id: g.providerAddressId, address: g.address, memo: g.memo, asset: body.asset_id, label: userId, raw: g.raw, request_id: row.id })));
    } catch (e) {
      if (e instanceof ProviderError) {
        // Label already exists at the provider: the fallback webhook or
        // address reconciliation will attach it. Keep the request open.
        await this.db.query(`update knock.provider_wallet_addresses set last_error = $2, status = case when $3 then 'failed' else status end, updated_at = now() where id = $1`,
          [row.id, `${e.code}: ${e.message}`.slice(0, 300), e.code === 'validation' || e.code === 'forbidden']);
        if (e.code === 'rate_limited') throw new ApiError('try_later', 'We are generating addresses for many customers. Please try again in a minute.', 503);
        throw new ApiError('address_unavailable', 'We could not create your deposit address right now. Please try again shortly.', 502);
      }
      throw e;
    }
    const [fresh] = await this.db.query('select * from knock.provider_wallet_addresses where id = $1', [row.id]);
    return publicAddress(fresh);
  }

  // -------------------------------------------------------------------------
  // Webhook ingress: verify, store, acknowledge. No processing here.

  async ingestWebhook(rawBody: string, headers: Headers, sourceIp: string | null): Promise<{ status: number; body: string }> {
    const auth = this.provider.authenticateWebhook(rawBody, headers, sourceIp);
    if (!auth.ok) {
      await this.db.query(
        `insert into knock.webhook_events (provider, event_id, signature_valid, payload, result, status, source_ip, verification)
         values ($1, $2, false, $3, $4, 'rejected', $5, $6)`,
        [this.p, `rejected:${randomUUID()}`, toJson({ length: rawBody.length }), 'rejected: ' + auth.reason, sourceIp, toJson({ reason: auth.reason })],
      ).catch(() => {});
      return { status: 401, body: 'unauthorized' };
    }
    let parsed;
    try {
      parsed = this.provider.parseWebhook(rawBody);
    } catch {
      return { status: 400, body: 'invalid event' };
    }
    const { meta } = parsed;
    try {
      await this.db.query(
        `insert into knock.webhook_events (provider, event_id, event_type, signature_valid, payload, status, source_ip, verification,
           event_time, resource_id, next_attempt_at, last_delivery_at)
         values ($1, $2, $3, true, $4::jsonb, 'queued', $5, $6, $7, $8, now(), now())
         on conflict (provider, event_id) do update set delivery_count = knock.webhook_events.delivery_count + 1, last_delivery_at = now()`,
        [this.p, meta.eventId, meta.eventType, rawBody, sourceIp, toJson({ ip: true, secret: true }), meta.eventTime, meta.resourceId],
      );
      await this.db.query('update knock.provider_accounts set webhook_last_received_at = now() where provider = $1', [this.p]);
    } catch {
      return { status: 503, body: 'retry' }; // not durably stored: let the provider retry
    }
    return { status: 200, body: 'ok' };
  }

  // -------------------------------------------------------------------------
  // Webhook worker

  /** Process up to `limit` queued events. Returns the outcomes for logging. */
  async processQueue(limit = 20, worker = 'worker-' + process.pid) {
    const rows = await this.db.query<any>('select * from knock.claim_webhook_events($1, $2, $3)', [this.p, limit, worker]);
    const out: Array<{ eventId: string; outcome: string }> = [];
    for (const row of rows) out.push({ eventId: row.event_id, outcome: await this.processRow(row) });
    return out;
  }

  /** Drain the queue (tests / manual recovery). */
  async drain(max = 1000) {
    const all: Array<{ eventId: string; outcome: string }> = [];
    for (let i = 0; i < max; i++) {
      const r = await this.processQueue(50);
      if (r.length === 0) break;
      all.push(...r);
    }
    return all;
  }

  private async processRow(row: any): Promise<string> {
    const started = Date.now();
    let outcome: string;
    let status: string;
    let detail: string | null = null;
    try {
      const { meta, event } = this.provider.parseWebhook(JSON.stringify(row.payload));
      // Re-parse from the stored text to keep exact decimals.
      const exact = this.provider.parseWebhook(typeof row.payload === 'string' ? row.payload : JSON.stringify(row.payload));
      outcome = await this.applyEvent(exact.meta.eventId ? exact.meta : meta, exact.event ?? event);
      status = outcome.startsWith('ignored_terminal') ? 'ignored_terminal' : outcome.startsWith('ignored_stale') ? 'ignored_stale' : 'processed';
    } catch (e) {
      const code = e instanceof Retry || e instanceof Manual ? e.code : e instanceof ApiError ? e.code : e instanceof ProviderError ? 'provider_unavailable' : 'internal';
      detail = (e as Error).message?.slice(0, 500) ?? String(e);
      const retryable = e instanceof Retry || RETRYABLE.has(code) || (e instanceof ProviderError && ['timeout', 'network_error', 'server_error', 'rate_limited'].includes(e.code));
      if (retryable && row.attempts < EVENT_RETRY_S.length) {
        status = 'retrying';
        outcome = `retry: ${code}`;
        await this.db.query(`update knock.webhook_events set status = 'retrying', last_error = $3, next_attempt_at = now() + make_interval(secs => $4) where provider = $1 and event_id = $2`,
          [this.p, row.event_id, `${code}: ${detail}`, EVENT_RETRY_S[row.attempts - 1] ?? 3600]);
      } else {
        status = 'failed';
        outcome = `failed: ${code}`;
        await this.db.query(`update knock.webhook_events set status = 'failed', last_error = $3 where provider = $1 and event_id = $2`, [this.p, row.event_id, `${code}: ${detail}`]);
      }
      await this.logProcessing(row, outcome, detail, started);
      return outcome;
    }
    await this.db.query(`update knock.webhook_events set status = $3, processed_at = now(), result = $4 where provider = $1 and event_id = $2`,
      [this.p, row.event_id, status, outcome]);
    await this.logProcessing(row, outcome, detail, started);
    return outcome;
  }

  private logProcessing(row: any, outcome: string, detail: string | null, started: number) {
    return this.db.query(`insert into knock.provider_event_processing_logs (webhook_event_id, attempt, outcome, detail, duration_ms) values ($1,$2,$3,$4,$5)`,
      [row.id, row.attempts, outcome, detail, Date.now() - started]);
  }

  private async applyEvent(meta: { eventId: string; eventTime: string | null }, event: ProviderEvent): Promise<string> {
    switch (event.kind) {
      case 'address.created': {
        const a = event.address;
        const r = await this.db.tx((q) => call<any>(q, 'record_deposit_address', this.p, toJson({
          provider_address_id: a.providerAddressId, address: a.address, memo: a.memo, asset: a.asset, label: a.label, raw: a.raw })));
        return `address ${r.result}`;
      }
      case 'deposit':
        return this.applyDeposit(meta, event.deposit);
      case 'settlement.failed': {
        const v = await this.verifiedDeposit(event.tradeId);
        if (v.status !== 'completed') throw new Manual('provider_conflict', `settlement failed for trade ${event.tradeId} but provider status is ${v.status}`);
        const r = await this.db.tx((q) => call<any>(q, 'settlement_failed', this.p, event.tradeId, meta.eventId,
          toJson({ amount: event.amount, currency: event.currency, reason: event.reason, event_time: meta.eventTime })));
        return `settlement ${r.result}`;
      }
      case 'withdrawal':
        return this.applyWithdrawal(meta, event.withdrawal);
      default:
        return `ignored unknown event ${event.type}`;
    }
  }

  private async verifiedDeposit(tradeId: string): Promise<ProviderDeposit> {
    try {
      return await this.provider.getDeposit(tradeId);
    } catch (e) {
      if (e instanceof ProviderError && e.code === 'not_found') throw new Manual('provider_not_found', `provider has no trade ${tradeId}`);
      throw e;
    }
  }

  private async applyDeposit(meta: { eventId: string; eventTime: string | null }, ev: ProviderDeposit): Promise<string> {
    // Provider verification before any state change.
    const v = await this.verifiedDeposit(ev.tradeId);
    if ((DEPOSIT_ORDER[v.status] ?? 0) < (DEPOSIT_ORDER[ev.status] ?? 0)) {
      throw new Retry('provider_not_confirmed', `event says ${ev.status}, provider still ${v.status}`);
    }
    if (v.status === 'completed' && ev.status === 'failed') throw new Manual('provider_conflict', 'deleted event for a trade the provider shows as completed');
    if (v.status === 'failed' && ev.status === 'completed') throw new Manual('provider_conflict', 'completed event for a trade the provider shows as deleted');

    const common = {
      event_time: meta.eventTime, event_id: meta.eventId, destination_address: ev.destinationAddress ?? v.destinationAddress,
      wallet_id: ev.walletId ?? v.walletId, asset: ev.asset ?? v.asset, crypto_amount: ev.cryptoAmount ?? v.cryptoAmount,
      amount_in_usd: ev.amountInUsd ?? v.amountInUsd, tx_hash: ev.txHash ?? v.txHash, confirmations: ev.confirmations ?? v.confirmations,
      sub_status: ev.subStatus ?? v.subStatus, is_wrong_asset: ev.isWrongAsset || v.isWrongAsset, snapshot: v.raw,
    };

    if (ev.status === 'completed') {
      const amount = ev.amountCredited ?? v.amountCredited;
      const currency = ev.currency ?? v.currency;
      if (!amount || !currency) throw new Manual('missing_amount', 'completed deposit has no amountCredited/currency');
      if (v.amountCredited && ev.amountCredited && Number(v.amountCredited) !== Number(ev.amountCredited)) {
        throw new Manual('amount_mismatch', `event amountCredited ${ev.amountCredited} != provider ${v.amountCredited}`);
      }
      if (v.currency && ev.currency && v.currency !== ev.currency) throw new Manual('currency_mismatch', `event ${ev.currency} != provider ${v.currency}`);
      const r = await this.db.tx((q) => call<any>(q, 'complete_crypto_deposit', this.p, ev.tradeId, toJson({
        ...common, amount_credited: amount, currency, rate: ev.rate ?? v.rate, conversion_rate: ev.conversionRate ?? v.conversionRate,
        fee_amount_usd: ev.feeAmountUsd ?? v.feeAmountUsd, fee_percentage: ev.feePercentage ?? v.feePercentage,
        settled_trades: ev.settledTrades ?? v.settledTrades,
      })));
      return `deposit ${r.result}`;
    }
    const r = await this.db.tx((q) => call<any>(q, 'record_deposit_state', this.p, ev.tradeId, toJson({
      ...common, status: ev.status, reason: ev.reason ?? v.reason, balance_remaining: ev.balanceRemaining ?? v.balanceRemaining, kyt: ev.kyt ?? v.kyt,
    })));
    return `deposit ${r.result}`;
  }

  private async applyWithdrawal(meta: { eventId: string; eventTime: string | null }, ev: ProviderWithdrawal): Promise<string> {
    let v: ProviderWithdrawal;
    try {
      v = await this.provider.getWithdrawal(ev.id);
    } catch (e) {
      if (e instanceof ProviderError && e.code === 'not_found') throw new Manual('provider_not_found', `provider has no withdrawal ${ev.id}`);
      throw e;
    }
    const evRank = WITHDRAWAL_ORDER[ev.status] ?? 0;
    const vRank = WITHDRAWAL_ORDER[v.status] ?? 0;
    if (vRank < evRank) throw new Retry('provider_not_confirmed', `event says ${ev.status}, provider still ${v.status}`);
    if (vRank === 9 && evRank === 9 && v.status !== ev.status) {
      throw new Manual('provider_conflict', `event says ${ev.status} but provider says ${v.status}`);
    }
    const p = {
      event_time: meta.eventTime, event_id: meta.eventId,
      amount: v.amount ?? ev.amount, original_amount: v.originalAmount ?? ev.originalAmount, payout_amount: v.payoutAmount ?? ev.payoutAmount,
      currency: v.currency ?? ev.currency, fee: v.fee ?? ev.fee, fee_bearer: v.feeBearer ?? ev.feeBearer, tx_hash: v.txHash ?? ev.txHash,
      reference: v.reference ?? ev.reference, external_id: v.externalId ?? ev.externalId, trade: v.trade ?? ev.trade,
      crypto_amount: v.cryptoAmount ?? ev.cryptoAmount, fee_crypto: v.feeCrypto ?? ev.feeCrypto, meta: v.meta ?? ev.meta,
      reason: v.reason ?? ev.reason, snapshot: { ...(v.raw as object), meta: v.meta },
    };
    if (ev.status === 'reversed' || ev.status === 'rejected') {
      // Refund confirmed by the provider's own record (status checked above).
      const [{ id }] = await this.db.query<{ id: string | null }>('select knock.find_withdrawal($1,$2,$3,$4) as id', [this.p, ev.id, p.external_id, p.trade]);
      if (!id) throw new Retry('unknown_withdrawal', `withdrawal ${ev.id} not known yet`);
      const r = await this.db.tx((q) => call<any>(q, 'release_withdrawal', id, ev.status, p.reason ?? ev.status, null, toJson(p)));
      return `withdrawal ${r.result}`;
    }
    const r = await this.db.tx((q) => call<any>(q, 'apply_withdrawal_status', this.p, ev.id, ev.status, toJson(p)));
    return `withdrawal ${r.result}`;
  }

  // -------------------------------------------------------------------------
  // Customer withdrawals

  /** Fee and payout preview shown before the customer confirms. */
  async quoteWithdrawal(userId: string, b: WithdrawalBody) {
    const cur = b.currency.toUpperCase();
    const amount = BigInt(b.amount_minor);
    const [{ fee }] = await this.db.query<{ fee: string }>('select knock.crypto_fee($1, $2, $3) as fee',
      [b.kind === 'crypto' ? 'crypto_withdrawal' : 'bank_withdrawal', cur, amount.toString()]);
    const out: Record<string, unknown> = { currency: cur, amount_minor: amount.toString(), knock_fee_minor: fee, total_debit_minor: (amount + BigInt(fee)).toString() };
    if (b.kind === 'crypto') {
      const [cfg] = await this.db.query<any>(`select * from knock.provider_asset_configurations where provider = $1 and symbol = $2 and network = $3 and withdraw_enabled`,
        [this.p, b.asset!.toUpperCase(), (b.network ?? '').toUpperCase()]);
      if (!cfg) throw new ApiError('asset_unavailable', 'Withdrawals for this asset and network are not available right now.');
      const v = await this.provider.validateAddress(b.asset!.toUpperCase(), b.network ? b.network.toUpperCase() : null, b.destination_address!);
      if (!v.valid) throw new ApiError('invalid_destination', 'That wallet address is not valid for this asset and network.');
      out.provider_fee = cfg.withdrawal_fee;
      out.provider_fee_currency = cfg.withdrawal_fee_currency;
      if (cfg.kind === 'utxo') {
        if (!b.fee_level) throw new ApiError('bad_request', 'Choose a network fee level (low, medium or high).');
        if (b.crypto_amount) out.network_fee = (await this.provider.estimateNetworkFee(cfg.symbol, b.crypto_amount, b.destination_address!))[b.fee_level];
      }
      out.note = 'Address validation checks the format only. Make sure you own or trust this address.';
    } else {
      const [bank] = await this.db.query<any>(`select bank_name, account_name, account_last4 from knock.bank_accounts where id = $1 and user_id = $2 and status = 'active'`,
        [b.bank_account_id, userId]);
      if (!bank) throw new ApiError('bank_required', 'Choose a verified bank account.');
      out.destination = { bank_name: bank.bank_name, account_name: bank.account_name, account: '******' + bank.account_last4 };
      // Breet's bank withdrawal fee comes from the integration settings
      // (GET /users/fetch-integration withdrawalFee) and is shown by the app.
      out.provider_fee = null;
    }
    return out;
  }

  /**
   * Reserve funds and submit. Call only after the API layer has verified the
   * customer's session and transaction authorisation (PIN / biometric proof).
   */
  async createWithdrawal(userId: string, idempotencyKey: string, b: WithdrawalBody) {
    if (!idempotencyKey || idempotencyKey.length < 16) throw new ApiError('bad_request', 'Idempotency-Key header is required');
    if (b.kind === 'crypto') {
      const v = await this.provider.validateAddress(b.asset!.toUpperCase(), b.network ? b.network.toUpperCase() : null, b.destination_address!);
      if (!v.valid) throw new ApiError('invalid_destination', 'That wallet address is not valid for this asset and network.');
    }
    const r = await this.db.tx((q) => call<any>(q, 'reserve_withdrawal', userId, this.p, toJson({ ...b, idempotency_key: idempotencyKey })));
    if (r.result === 'existing') return customerWithdrawal(r.withdrawal);
    const w = await this.submitWithdrawal(r.withdrawal.id);
    return customerWithdrawal(w);
  }

  /** Send a reserved withdrawal to the provider exactly once. */
  async submitWithdrawal(id: string) {
    const won = await this.db.query<{ r: boolean }>('select knock.begin_withdrawal_submission($1) as r', [id]);
    const [w] = await this.db.query<any>('select * from knock.provider_withdrawals where id = $1', [id]);
    if (!won[0].r) return w; // someone else is submitting or already did
    let res: SubmitOutcome;
    try {
      res = w.kind === 'crypto'
        ? await this.provider.withdrawCrypto({
            externalId: w.knock_reference, amountUsd: minorToMajor(w.amount_minor, 2), token: w.asset, network: w.network,
            feeLevel: w.fee_level, walletAddress: w.destination_address })
        : await this.provider.withdrawBank({ externalId: w.knock_reference, savedAccountId: w.provider_bank_id, amount: minorToMajor(w.amount_minor, 2), narration: w.narration });
    } catch (e) {
      // Raised before the request went out (e.g. our rate gate): safe to retry later.
      if (e instanceof ProviderError && e.code === 'rate_limited') {
        await this.db.query(`update knock.provider_withdrawals set status = 'reserved', last_error_code = 'rate_limited' where id = $1 and status = 'submitting'`, [id]);
      } else {
        await this.db.query('select knock.withdrawal_unknown($1, $2)', [id, 'client_error']);
      }
      return (await this.db.query<any>('select * from knock.provider_withdrawals where id = $1', [id]))[0];
    }
    if (res.outcome === 'accepted') {
      await this.db.tx((q) => call(q, 'withdrawal_accepted', id, res.providerId, toJson(res.raw)));
    } else if (res.outcome === 'unknown') {
      await this.db.query('select knock.withdrawal_unknown($1, $2)', [id, res.code]);
    } else if (res.code === 'rate_limited') {
      // 429: not processed by the provider. Re-queue; the worker resubmits after Retry-After.
      await this.db.query(`update knock.provider_withdrawals set status = 'reserved', last_error_code = 'rate_limited' where id = $1`, [id]);
    } else {
      const status = res.code === 'capacity' ? 'capacity_unavailable' : 'not_submitted';
      await this.db.tx((q) => call(q, 'release_withdrawal', id, status, res.message.slice(0, 200), res.code, '{}'));
    }
    return (await this.db.query<any>('select * from knock.provider_withdrawals where id = $1', [id]))[0];
  }

  /** Worker: resubmit rate-limited reservations, resolve unknown submissions. */
  async withdrawalSweep() {
    const reserved = await this.db.query<{ id: string }>(
      `select id from knock.provider_withdrawals where provider = $1 and status = 'reserved' and purpose <> 'settlement_replacement' order by created_at limit 50`, [this.p]);
    for (const r of reserved) await this.submitWithdrawal(r.id);
    return this.resolveUnknownSubmissions();
  }

  /**
   * A financial POST timed out. Look for our externalId in the provider's
   * withdrawal list. Found: adopt the provider id. Not found after the
   * provider's 5-minute duplicate window: it was never accepted, release.
   */
  async resolveUnknownSubmissions(maxPages = 10) {
    const unknown = await this.db.query<any>(`select * from knock.provider_withdrawals where provider = $1 and status = 'submission_unknown'`, [this.p]);
    if (unknown.length === 0) return { resolved: 0, open: 0 };
    const byRef = new Map(unknown.map((w) => [w.knock_reference, w]));
    let resolved = 0;
    for (let page = 1; page <= maxPages && byRef.size; page++) {
      const pg = await this.provider.listWithdrawals(page, 100);
      for (const pw of pg.items) {
        const w = byRef.get(pw.externalId ?? '') ?? byRef.get(pw.reference ?? '');
        if (!w) continue;
        await this.db.tx((q) => call(q, 'withdrawal_accepted', w.id, pw.id, toJson(pw.raw)));
        byRef.delete(w.knock_reference);
        resolved++;
      }
      if (!pg.hasNextPage) break;
    }
    for (const w of byRef.values()) {
      const ageMin = (Date.now() - new Date(w.submitted_at).getTime()) / 60000;
      if (ageMin >= 15) {
        await this.db.tx((q) => call(q, 'release_withdrawal', w.id, 'not_submitted', 'not found at provider after timeout', 'timeout_unconfirmed', '{}'));
        resolved++;
        byRef.delete(w.knock_reference);
      }
    }
    return { resolved, open: byRef.size };
  }

  // -------------------------------------------------------------------------
  // Settlement recovery (Finance)

  requestRecovery(staffId: string, exceptionId: string, action: 'settlement_replacement' | 'settlement_release', note: string) {
    return this.db.tx((q) => call<any>(q, 'request_settlement_recovery', exceptionId, staffId, action, note));
  }

  async approveRecovery(staffId: string, requestId: string, opts: { bank_account_id?: string; balance_confirmed?: boolean } = {}) {
    const [req] = await this.db.query<any>('select * from knock.staff_action_requests where id = $1', [requestId]);
    if (!req) throw new ApiError('not_found', 'request not found', 404);
    if (req.payload?.dual && req.requested_by === staffId) {
      throw new ApiError('second_approver_required', 'A different finance manager must approve this action.', 403);
    }
    if (req.action === 'settlement_replacement') {
      // Checks before anything is approved: provider trade and balance.
      const [ex] = await this.db.query<any>('select * from knock.settlement_exceptions where id = $1', [req.subject_id]);
      const v = await this.verifiedDeposit(ex.trade_id);
      if (v.status !== 'completed') throw new ApiError('provider_conflict', `provider shows trade as ${v.status}`, 409);
      if (!opts.balance_confirmed) {
        // The Breet API documentation available to us has no balance
        // endpoint, so the approver confirms the provider wallet balance
        // from the Breet Partner Dashboard; that confirmation is audited.
        throw new ApiError('balance_check_required', 'Confirm the provider wallet balance covers this payout before approving.', 409);
      }
    }
    const a = await this.db.tx((q) => call<any>(q, 'approve_staff_action', requestId, staffId));
    if (a.action === 'settlement_release') {
      return this.db.tx((q) => call<any>(q, 'execute_settlement_release', requestId, staffId));
    }
    const [ex] = await this.db.query<any>('select * from knock.settlement_exceptions where id = $1', [a.subject_id]);
    const [s] = await this.db.query<any>('select * from knock.settlements where id = $1', [ex.settlement_id]);
    const bank = opts.bank_account_id ?? (await this.db.query<any>(`select a.bank_account_id from knock.crypto_deposits d join knock.provider_wallet_addresses a on a.id = d.address_id where d.id = $1`, [s.deposit_id]))[0]?.bank_account_id;
    const r = await this.db.tx((q) => call<any>(q, 'create_settlement_replacement', requestId, staffId, bank));
    await this.db.query(`select knock.audit($1, 'staff', 'settlement.replacement.balance_confirmed', null, null, $2::jsonb)`, [staffId, toJson({ request_id: requestId })]);
    const w = await this.submitWithdrawal(r.withdrawal_id);
    return { withdrawal_id: r.withdrawal_id, status: w.status };
  }

  // -------------------------------------------------------------------------
  // Webhook recovery

  /** Re-queue a failed event for another attempt (technical staff). */
  async requeueEvent(staffId: string, eventId: string) {
    const r = await this.db.query(`update knock.webhook_events set status = 'queued', next_attempt_at = now(), attempts = 0 where provider = $1 and event_id = $2 and status in ('failed','retrying') returning id`, [this.p, eventId]);
    if (r.length === 0) throw new ApiError('bad_state', 'event is not failed');
    await this.db.query(`select knock.audit($1, 'staff', 'webhook.requeued', null, null, $2::jsonb)`, [staffId, toJson({ event_id: eventId })]);
  }

  /** Ask the provider to resend (only if Knock's account has that permission). */
  async resendFromProvider(staffId: string, reference: string) {
    if (!this.provider.resendWebhook) throw new ApiError('not_supported', 'provider has no resend API', 400);
    try {
      const r = await this.provider.resendWebhook(reference);
      await this.db.query(`select knock.audit($1, 'staff', 'webhook.resend_requested', null, null, $2::jsonb)`, [staffId, toJson({ reference })]);
      return r;
    } catch (e) {
      if (e instanceof ProviderError && e.code === 'forbidden') throw new ApiError('not_permitted', 'Knock does not have webhook resend access with the provider yet.', 403);
      throw e;
    }
  }
}

export interface WithdrawalBody {
  kind: 'crypto' | 'bank';
  currency: string;
  amount_minor: string;
  asset?: string;
  network?: string;
  destination_address?: string;
  fee_level?: 'low' | 'medium' | 'high';
  crypto_amount?: string;
  bank_account_id?: string;
  narration?: string;
}

export function minorToMajor(minor: string | bigint, decimals: number) {
  const v = BigInt(minor);
  const s = v.toString().padStart(decimals + 1, '0');
  return decimals ? `${s.slice(0, -decimals)}.${s.slice(-decimals)}` : s;
}

const CUSTOMER_STATUS: Record<string, string> = {
  reserved: 'Withdrawal Submitted', submitting: 'Withdrawal Submitted', submission_unknown: 'Withdrawal Submitted', pending: 'Withdrawal Submitted',
  processing: 'Withdrawal Processing', completed: 'Withdrawal Completed', reversed: 'Withdrawal Reversed', rejected: 'Withdrawal Rejected',
  capacity_unavailable: 'Payout Temporarily Unavailable', not_submitted: 'Withdrawal Not Sent',
};

/** What a customer may see: no provider ids, raw payloads or messages. */
export function customerWithdrawal(w: any) {
  return {
    id: w.id, reference: w.knock_reference, kind: w.kind, status: CUSTOMER_STATUS[w.status] ?? 'Withdrawal Submitted',
    currency: w.currency, amount_minor: String(w.amount_minor), knock_fee_minor: String(w.knock_fee_minor),
    asset: w.asset, network: w.network, destination: w.kind === 'crypto' ? w.destination_address : { bank_name: w.bank_name, account_name: w.account_name, account: w.account_number_masked },
    tx_hash: w.status === 'completed' ? w.tx_hash : null, created_at: w.created_at,
    message: w.status === 'capacity_unavailable'
      ? 'We\'re temporarily unable to process a payout of this size for this asset. Try a smaller amount or try again later. Your funds have not been debited.'
      : w.status === 'processing' ? 'Your withdrawal is being processed.' : w.status === 'completed' ? 'Your withdrawal has been completed.' : null,
  };
}

function publicAddress(a: any) {
  return {
    id: a.id, asset_id: a.asset_id, symbol: a.symbol, network: a.network, address: a.address, memo: a.memo,
    status: a.status === 'active' ? 'Awaiting Deposit' : a.status === 'requested' ? 'Generating Address' : 'Unavailable',
    auto_settlement: a.auto_settlement,
  };
}

export { dec };
