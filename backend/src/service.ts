// Payment Links service: the only code path that moves money.
// Rule: never credit on a client claim or an unverified notification.
// A webhook is (1) signature-checked, (2) stored once by event id, (3)
// re-verified against the provider's API, and only then (4) handed to
// knock.confirm_payment, which is itself idempotent.
import { ApiError, call, type Db } from './db.ts';
import type { PaymentMethod, PaymentProvider } from './providers/types.ts';
import { RateLimiter } from './ratelimit.ts';

export interface ServiceDeps {
  db: Db;
  providers: Record<string, PaymentProvider>; // by provider name
  nairaProvider: string;
  cryptoProvider: string;
  publicBaseUrl: string;
}

const json = (v: unknown) => JSON.stringify(v, (_, x) => (typeof x === 'bigint' ? x.toString() : x));

export class PaymentLinksService {
  private d: ServiceDeps;
  readonly lookupLimiter = new RateLimiter(30, 60_000); // 30 username lookups / minute / user
  readonly checkoutLimiter = new RateLimiter(10, 60_000); // 10 checkouts / minute / IP

  constructor(deps: ServiceDeps) {
    this.d = deps;
  }

  async lookupUsername(actor: string, username: string) {
    if (!this.lookupLimiter.take(actor)) throw new ApiError('rate_limited', 'Too many lookups, try again shortly', 429);
    const rows = await this.d.db.query('select * from knock.lookup_username($1)', [username]);
    return rows[0] ?? null;
  }

  createLink(creator: string, body: Record<string, unknown>) {
    return this.d.db.tx((q) => call(q, 'create_payment_link', creator, json(body)));
  }

  async checkout(slug: string, body: { amount?: string; method: PaymentMethod; payer_name?: string; payer_email?: string; customer_reference?: string }, clientKey: string) {
    if (!this.checkoutLimiter.take(clientKey)) throw new ApiError('rate_limited', 'Too many attempts, try again shortly', 429);
    const quote = await call<any>(this.d.db.query, 'checkout_quote', slug, body.amount ?? null);
    const crypto = quote.network !== 'fiat';
    const provider = this.d.providers[crypto ? this.d.cryptoProvider : this.d.nairaProvider];
    const session = await provider.createCheckout({
      knockReference: `KPS-${crypto ? 'C' : 'N'}-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 8)}`,
      amount: BigInt(quote.total_to_pay),
      currency: quote.currency,
      network: quote.network,
      method: crypto ? 'crypto' : body.method,
      payerEmail: body.payer_email,
      description: slug,
      callbackUrl: `${this.d.publicBaseUrl}/pay/${slug}`,
    });
    const intent = await this.d.db.tx((q) =>
      call(q, 'create_payment_intent', slug, body.amount ?? null, json({
        provider: session.provider,
        provider_reference: session.providerReference,
        method: crypto ? 'crypto' : body.method,
        payer_name: body.payer_name,
        payer_email: body.payer_email,
        customer_reference: body.customer_reference,
        pay_address: session.crypto?.address,
        quote_expires_at: session.crypto?.quoteExpiresAt,
      })),
    );
    return { ...intent, session };
  }

  /** Handle one provider webhook. Returns a short result string for logs. */
  async handleWebhook(providerName: string, rawBody: string, headers: Headers): Promise<string> {
    const provider = this.d.providers[providerName];
    if (!provider) throw new ApiError('not_found', 'unknown provider', 404);
    const evt = provider.parseWebhook(rawBody, headers);
    if (!evt) {
      let payload: unknown;
      try { payload = JSON.parse(rawBody); } catch { payload = { raw: rawBody.slice(0, 2000) }; }
      await this.d.db.query(
        `insert into knock.webhook_events (provider, event_id, signature_valid, payload, result) values ($1, $2, false, $3, 'rejected: bad signature')`,
        [providerName, `invalid:${Date.now()}:${Math.random()}`, json(payload)],
      );
      throw new ApiError('invalid_signature', 'webhook signature invalid', 401);
    }
    const inserted = await this.d.db.query(
      `insert into knock.webhook_events (provider, event_id, event_type, signature_valid, payload) values ($1, $2, $3, true, $4)
       on conflict (provider, event_id) do nothing returning id`,
      [providerName, evt.eventId, evt.type, json(evt)],
    );
    if (inserted.length === 0) return 'duplicate event ignored';

    let result: string;
    if (evt.type === 'settlement.completed') {
      await this.d.db.tx((q) => call(q, 'settle_payment', providerName, evt.providerReference, String(evt.data.providerFee ?? '0'), String(evt.data.settlementRef ?? '')));
      result = 'settled';
    } else if (evt.type === 'charge.dispute.create') {
      await this.d.db.tx((q) => call(q, 'open_dispute', providerName, evt.providerReference, String(evt.data.disputeId), String(evt.data.reason ?? '')));
      result = 'dispute opened';
    } else {
      // Source of truth is the provider's verify API, never the webhook body.
      const v = await provider.verify(evt.providerReference);
      if (v.status === 'success') {
        const r = await this.d.db.tx((q) =>
          call<any>(q, 'confirm_payment', providerName, evt.providerReference, json({
            amount_paid: v.amountPaid.toString(), currency: v.currency, network: v.network ?? 'fiat',
            tx_hash: v.txHash, confirmations: v.confirmations ?? 0, paid_at: v.paidAt, channel: v.channel,
          })),
        );
        result = r.result;
      } else if (v.status === 'failed') {
        await this.d.db.tx((q) => call(q, 'update_payment_progress', providerName, evt.providerReference, 'failed', null, null));
        result = 'failed';
      } else {
        result = 'still pending';
      }
    }
    await this.d.db.query(`update knock.webhook_events set processed_at = now(), result = $3 where provider = $1 and event_id = $2`, [providerName, evt.eventId, result]);
    return result;
  }

  linkDetail(linkId: string) {
    return this.d.db.query(`select l.*, knock.link_collected(l.id) as collected from knock.payment_links l where id = $1`, [linkId]);
  }

  reconcile(linkId: string | null = null) {
    return this.d.db.query('select * from knock.reconcile($1)', [linkId]);
  }
}
