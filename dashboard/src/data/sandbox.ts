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

function sandboxAddress(network: string) {
  const chars = '123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz';
  const rnd = Array.from(crypto.getRandomValues(new Uint8Array(33)), (b) => chars[b % chars.length]).join('');
  if (network === 'TRC20') return 'T' + rnd.slice(0, 33);
  if (['BEP20', 'BSC', 'ERC20'].includes(network)) return '0x' + Array.from(crypto.getRandomValues(new Uint8Array(20)), (b) => b.toString(16).padStart(2, '0')).join('');
  return 'sbx' + rnd;
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

  /**
   * Stand-in for Supabase Auth (email + password). Production: the web app
   * calls supabase.auth.signUp / signInWithPassword; Supabase stores the
   * password hash, sends the confirmation email and issues the JWT the API
   * verifies. Here accounts live in memory for this tab only.
   */
  auth = (() => {
    const users = new Map<string, { id: string; salt: string; hash: string }>();
    const fails = new Map<string, { n: number; until: number }>();
    const norm = (e: string) => e.trim().toLowerCase();
    const digest = async (salt: string, pw: string) =>
      Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(salt + ':' + pw))), (b) => b.toString(16).padStart(2, '0')).join('');
    return {
      add: async (email: string, password: string, id: string) => {
        const salt = crypto.randomUUID();
        users.set(norm(email), { id, salt, hash: await digest(salt, password) });
      },
      exists: (email: string) => users.has(norm(email)),
      signUp: async (email: string, password: string) => {
        if (users.has(norm(email))) throw new ApiError('email_taken', 'An account with this email already exists. Log in instead.');
        if (password.length < 8 || !/[a-z]/i.test(password) || !/[0-9]/.test(password)) throw new ApiError('weak_password', 'Use at least 8 characters with letters and numbers.');
        const id = crypto.randomUUID();
        const salt = crypto.randomUUID();
        users.set(norm(email), { id, salt, hash: await digest(salt, password) });
        return id;
      },
      signIn: async (email: string, password: string) => {
        const k = norm(email);
        const f = fails.get(k);
        if (f && f.until > Date.now()) throw new ApiError('rate_limited', `Too many attempts. Try again in ${Math.ceil((f.until - Date.now()) / 1000)} seconds.`);
        const u = users.get(k);
        if (!u || (await digest(u.salt, password)) !== u.hash) {
          const n = (f?.n ?? 0) + 1;
          fails.set(k, { n, until: n >= 5 ? Date.now() + 30_000 : 0 });
          throw new ApiError('invalid_credentials', 'Wrong email or password.');
        }
        fails.delete(k);
        return u.id;
      },
    };
  })();

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

    // Hosted checkout. Production: POST /v1/checkout/:slug runs checkout_open,
    // calls Breet generate-address (label = payment reference) and records
    // the address. Here the Breet response is simulated; the SQL is the same.
    checkout: async (slug: string, amountMinor: string | null, payer: { name: string; email: string; reference?: string }) => {
      try {
        return await this.db.transaction(async (tx) => {
          const r = (await tx.query<any>(`select knock.checkout_open('breet', $1, $2::numeric, $3::jsonb) as r`, [slug, amountMinor,
            JSON.stringify({ payer_name: payer.name.trim(), payer_email: payer.email.trim(), customer_reference: payer.reference?.trim() || null })])).rows[0].r;
          const a = (await tx.query<any>(`select network from knock.provider_wallet_addresses where id = $1`, [r.address_request_id])).rows[0];
          const address = sandboxAddress(a.network);
          const pid = 'sbx-wallet-' + crypto.randomUUID().slice(0, 8);
          await this.webhook(tx, 'trade.address.created', pid);
          await tx.query(`select knock.record_deposit_address('breet', $1::jsonb)`, [JSON.stringify({ request_id: r.address_request_id, provider_address_id: pid, address, asset: r.asset_id, label: r.label })]);
          return { payment_id: r.payment_id as string };
        });
      } catch (e) { throw toApiError(e); }
    },

    // The customer's wallet and Breet's webhooks for a checkout address.
    // Production: Breet's trade.* webhooks, verified and re-fetched, call
    // knock.checkout_deposit_event exactly like this.
    checkoutEvent: async (paymentId: string, scenario: 'detected' | 'completed' | 'underpaid' | 'held' | 'failed' | 'expire') => {
      try {
        return await this.db.transaction(async (tx) => {
          const p = (await tx.query<any>(`select p.*, a.address, s.decimals, s.min_confirmations from knock.payments p
              join knock.provider_wallet_addresses a on a.payment_id = p.id join knock.assets s on s.code = p.currency and s.network = p.network where p.id = $1`, [paymentId])).rows[0];
          if (!p) throw new ApiError('not_found', 'checkout not found');
          if (scenario === 'expire') {
            await tx.query(`update knock.payments set quote_expires_at = now() - interval '1 second' where id = $1`, [paymentId]);
            await tx.query(`select knock.expire_checkouts()`);
            return { result: 'expired' };
          }
          const trade = p.provider_trade_id ?? 'sbx-trade-' + crypto.randomUUID().slice(0, 10);
          const due = BigInt(p.amount) + BigInt(p.payer_fee);
          const sent = scenario === 'underpaid' ? (due * 8n) / 10n : due;
          const major = (Number(sent) / 10 ** p.decimals).toFixed(p.decimals);
          const t = new Date(Math.max(Date.now(), p.checkout_event_at ? new Date(p.checkout_event_at).getTime() + 1000 : 0)).toISOString();
          const base = { destination_address: p.address, crypto_amount: major, tx_hash: p.tx_hash ?? 'sandbox-tx-' + trade, event_time: t };
          const ev = async (type: string, body: Record<string, unknown>) => {
            await this.webhook(tx, type, trade);
            return (await tx.query<any>(`select knock.checkout_deposit_event('breet', $1, $2::jsonb) as r`, [trade, JSON.stringify({ ...base, ...body, event_id: trade + ':' + body.status + ':' + t })])).rows[0].r;
          };
          if (scenario === 'detected') return ev('trade.pending', { status: 'pending', confirmations: 1 });
          if (scenario === 'held') return ev('trade.flagged', { status: 'under_review', sub_status: 'under_review', reason: 'Compliance review by the provider' });
          if (scenario === 'failed') return ev('trade.deleted', { status: 'failed', reason: 'failed_on_chain' });
          const r = await ev('trade.completed', { status: 'completed', confirmations: p.min_confirmations, amount_credited: (Number(major) * 1550).toFixed(2), currency: 'NGN' });
          await tx.query(`select knock.settle_payment('breet', $1, 0, $2)`, [p.provider_reference, 'sbx-settle-' + trade]);
          return r;
        });
      } catch (e) { throw toApiError(e); }
    },

    // The delivery worker's result for queued business webhooks. The preview
    // cannot make network calls, so the receiver's answer is chosen here; the
    // retry schedule and status changes are the real SQL.
    deliver: async (answer: 200 | 500) => {
      try {
        return await this.db.transaction(async (tx) => {
          const rows = (await tx.query<any>(`select delivery_id from knock.claim_webhook_deliveries(50)`)).rows;
          for (const r of rows) await tx.query(`select knock.webhook_delivery_result($1, $2, $3, $4, $5)`, [r.delivery_id, answer === 200, answer, answer === 200 ? null : 'HTTP 500 (sandbox)', 42]);
          return { count: rows.length };
        });
      } catch (e) { throw toApiError(e); }
    },

    // The exact request the worker would send for one delivery, signed with
    // the endpoint's secret (same scheme as backend signTimestamped).
    signedRequest: async (deliveryId: string) => {
      const r = (await this.q<any>(`select e.url, e.secret, ev.event_ref, ev.type, ev.payload::text as body from knock.business_webhook_deliveries d
          join knock.business_webhook_endpoints e on e.id = d.endpoint_id join knock.business_webhook_events ev on ev.id = d.event_id where d.id = $1`, [deliveryId]))[0];
      if (!r) throw new ApiError('not_found', 'delivery not found');
      const t = Math.floor(Date.now() / 1000);
      const key = await crypto.subtle.importKey('raw', new TextEncoder().encode(r.secret), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
      const mac = new Uint8Array(await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(`${t}.${r.body}`)));
      const hex = Array.from(mac, (b) => b.toString(16).padStart(2, '0')).join('');
      return { url: r.url, headers: { 'content-type': 'application/json', 'user-agent': 'Knock-Webhooks/1.0', 'knock-event-id': r.event_ref, 'knock-event-type': r.type, 'knock-signature': `t=${t},v1=${hex}` }, body: r.body };
    },

    // Breet's generate-address response (production: CryptoService calls
    // Breet after the address row is requested, then records the result).
    address: async (addressId: string) => {
      try {
        return await this.db.transaction(async (tx) => {
          const a = (await tx.query<any>(`select symbol, network from knock.provider_wallet_addresses where id = $1`, [addressId])).rows[0];
          if (!a) throw new ApiError('not_found', 'address request not found');
          const address = sandboxAddress(a.network);
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

