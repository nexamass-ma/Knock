// SANDBOX MODE: the real Knock Postgres migrations running in the browser
// (PGlite = Postgres compiled to WebAssembly). Every number on screen is
// computed by the same SQL functions and views as production, over sandbox
// records created through the same engine functions. Nothing here talks to
// Breet, 9PSB or any bank. Sandbox-only helpers (simulate a customer
// payment, simulate a Breet webhook) are clearly separated in `sim`.
import { PGlite } from '@electric-sql/pglite';
import { runOp, type Identity } from '../../../backend/src/business/runner.ts';


export class ApiError extends Error {
  code: string;
  constructor(code: string, message: string) { super(message); this.code = code; }
}
export function toApiError(e: any): ApiError {
  if (e instanceof ApiError) return e;
  if (e?.code && typeof e.code === 'string' && /^[a-z_]+$/.test(e.code)) return new ApiError(e.code, e.message);
  const m = /^([a-z_]+): (.*)$/s.exec(String(e?.message ?? e));
  if (m) return new ApiError(m[1], m[2]);
  console.error('[sandbox internal]', e);
  return new ApiError('internal', 'Something went wrong. Please try again.');
}

export interface Person { id: string; username: string; name: string; note: string }

export class Sandbox {
  db: PGlite;
  people: Record<string, Person> = {};
  constructor(db: PGlite) { this.db = db; }

  async q<T = any>(sql: string, params: unknown[] = []): Promise<T[]> {
    return (await this.db.query<T>(sql, params as any[])).rows;
  }

  async run(name: string, identity: Identity, input: Record<string, unknown> = {}) {
    try {
      return await this.db.transaction(async (tx) => runOp(async (sql, params) => (await tx.query(sql, params as any[])).rows, name, identity, input));
    } catch (e) {
      throw toApiError(e);
    }
  }

  /** Sandbox-only stand-ins for the outside world (customers, Breet). */
  sim = {
    // A customer pays a link. Production: the payment page opens a provider
    // checkout; the provider's verified webhook calls confirm_payment.
    pay: async (slug: string, amountMinor: string | null, payer: { name: string; email: string; reference?: string }, outcome: 'succeeded' | 'failed' = 'succeeded') => {
      try {
        return await this.db.transaction(async (tx) => {
          const ref = 'sbx-' + crypto.randomUUID().slice(0, 12);
          const link = (await tx.query<any>(`select currency, network from knock.payment_links where slug = $1`, [slug])).rows[0];
          if (!link) throw new ApiError('not_found', 'link not found');
          const intent = (await tx.query<any>(`select knock.create_payment_intent($1, $2::numeric, $3::jsonb) as r`, [slug, amountMinor,
            JSON.stringify({ provider: 'sandbox', provider_reference: ref, method: link.currency === 'NGN' ? 'bank_transfer' : 'crypto', payer_name: payer.name, payer_email: payer.email, customer_reference: payer.reference ?? null })])).rows[0].r;
          if (outcome === 'failed') {
            await tx.query(`select knock.update_payment_progress('sandbox', $1, 'failed')`, [ref]);
            return { reference: intent.knock_reference, status: 'failed' };
          }
          const paid = (BigInt(intent.amount) + BigInt(intent.payer_fee)).toString();
          const r = (await tx.query<any>(`select knock.confirm_payment('sandbox', $1, $2::jsonb) as r`, [ref,
            JSON.stringify({ amount_paid: paid, currency: link.currency, network: link.network, tx_hash: 'sandbox-' + ref, confirmations: 99 })])).rows[0].r;
          await tx.query(`select knock.settle_payment('sandbox', $1, 0, $2)`, [ref, 'sbx-settle-' + ref]);
          return { reference: intent.knock_reference, status: 'succeeded', result: r };
        });
      } catch (e) { throw toApiError(e); }
    },

    // Breet's generate-address response (production: CryptoService calls
    // Breet after the address row is requested, then records the result).
    address: async (addressId: string) => {
      try {
        return await this.db.transaction(async (tx) => {
          const a = (await tx.query<any>(`select symbol, network from knock.provider_wallet_addresses where id = $1`, [addressId])).rows[0];
          if (!a) throw new ApiError('not_found', 'address request not found');
          const chars = '123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz';
          const rnd = Array.from(crypto.getRandomValues(new Uint8Array(30)), (b) => chars[b % chars.length]).join('');
          const address = a.network === 'TRC20' ? 'T' + rnd.slice(0, 33) : a.network === 'BEP20' || a.network === 'ERC20' ? '0x' + Array.from(crypto.getRandomValues(new Uint8Array(20)), (b) => b.toString(16).padStart(2, '0')).join('') : 'sbx' + rnd;
          await this.webhook(tx, 'trade.address.created', 'sbx-wallet-' + addressId.slice(0, 8));
          await tx.query(`select knock.record_deposit_address('breet', $1::jsonb)`, [JSON.stringify({ request_id: addressId, provider_address_id: 'sbx-wallet-' + addressId.slice(0, 8), address, asset: a.symbol })]);
          return { address: (await tx.query<any>(`select to_jsonb(x) as r from knock.provider_wallet_addresses x where id = $1`, [addressId])).rows[0].r };
        });
      } catch (e) { throw toApiError(e); }
    },

    // A Breet deposit webhook, already "verified" (production verifies the
    // signature and re-fetches GET /trades/transactions/{id} first).
    deposit: async (addressId: string, scenario: 'completed' | 'confirming' | 'under_review' | 'below_minimum' | 'failed', ngnMajor: number) => {
      try {
        return await this.db.transaction(async (tx) => {
          const a = (await tx.query<any>(`select address from knock.provider_wallet_addresses where id = $1`, [addressId])).rows[0];
          const trade = 'sbx-trade-' + crypto.randomUUID().slice(0, 10);
          const t0 = new Date().toISOString();
          const base = { destination_address: a.address, crypto_amount: (ngnMajor / 1550).toFixed(6), amount_in_usd: (ngnMajor / 1550).toFixed(2), tx_hash: 'sandbox-tx-' + trade };
          await this.webhook(tx, 'trade.pending', trade);
          await tx.query(`select knock.record_deposit_state('breet', $1, $2::jsonb)`, [trade, JSON.stringify({ ...base, status: 'pending', confirmations: 3, event_time: t0, event_id: trade + ':p' })]);
          if (scenario === 'confirming') return { trade, status: 'pending' };
          if (scenario !== 'completed') {
            const st = scenario === 'failed' ? 'failed' : scenario;
            await this.webhook(tx, scenario === 'failed' ? 'trade.deleted' : 'trade.flagged', trade);
            await tx.query(`select knock.record_deposit_state('breet', $1, $2::jsonb)`, [trade, JSON.stringify({ ...base, status: st,
              sub_status: scenario === 'under_review' ? 'kyt_hold' : scenario, reason: scenario === 'below_minimum' ? 'Below minimum deposit' : scenario === 'under_review' ? 'KYT review: medium exposure' : 'Failed on chain',
              balance_remaining: scenario === 'below_minimum' ? '3.50' : null, event_time: new Date(Date.now() + 1000).toISOString(), event_id: trade + ':f' })]);
            return { trade, status: st };
          }
          await this.webhook(tx, 'trade.completed', trade);
          const r = (await tx.query<any>(`select knock.complete_crypto_deposit('breet', $1, $2::jsonb) as r`, [trade, JSON.stringify({ ...base,
            amount_credited: ngnMajor.toFixed(2), currency: 'NGN', rate: '1550', conversion_rate: '1550', confirmations: 20,
            event_time: new Date(Date.now() + 2000).toISOString(), event_id: trade + ':c' })])).rows[0].r;
          return { trade, status: 'completed', result: r };
        });
      } catch (e) { throw toApiError(e); }
    },

    // Breet withdrawal lifecycle for an approved payout (production: the
    // CryptoService submits once, then follows verified webhooks).
    withdrawal: async (withdrawalId: string, outcome: 'completed' | 'rejected' | 'processing') => {
      try {
        return await this.db.transaction(async (tx) => {
          const w = (await tx.query<any>(`select status, provider_withdrawal_id from knock.provider_withdrawals where id = $1`, [withdrawalId])).rows[0];
          let pid = w.provider_withdrawal_id;
          if (w.status === 'reserved') {
            await tx.query(`select knock.begin_withdrawal_submission($1)`, [withdrawalId]);
            pid = 'sbx-wd-' + crypto.randomUUID().slice(0, 10);
            await tx.query(`select knock.withdrawal_accepted($1, $2, '{}'::jsonb)`, [withdrawalId, pid]);
          }
          const t = new Date().toISOString();
          if (outcome === 'rejected') {
            await this.webhook(tx, 'withdrawal.rejected', pid);
            await tx.query(`select knock.release_withdrawal($1, 'rejected', 'Rejected by provider (sandbox)', 'rejected', $2::jsonb)`, [withdrawalId, JSON.stringify({ event_time: t })]);
          } else {
            await this.webhook(tx, 'withdrawal.' + outcome, pid);
            await tx.query(`select knock.apply_withdrawal_status('breet', $1, $2, $3::jsonb)`, [pid, outcome,
              JSON.stringify({ event_time: t, event_id: pid + ':' + outcome, tx_hash: outcome === 'completed' ? 'sandbox-tx-' + pid : null, fee: '1', amount: null })]);
          }
          return { status: outcome };
        });
      } catch (e) { throw toApiError(e); }
    },
  };

  // Production records every provider event in webhook_events before
  // processing; the sandbox does the same so monitoring pages are real.
  async webhook(tx: { query: PGlite['query'] }, type: string, resource: string) {
    await tx.query(`insert into knock.webhook_events (provider, event_id, event_type, signature_valid, payload, status, resource_id, event_time, processed_at, result, source_ip)
                    values ('breet', $1, $2, true, $3::jsonb, 'processed', $4, now(), now(), 'applied', 'sandbox')`,
      ['sbx-evt-' + crypto.randomUUID(), type, JSON.stringify({ event: type, sandbox: true }), resource]);
  }
}

