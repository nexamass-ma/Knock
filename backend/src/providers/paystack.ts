// Live Paystack adapter. Written against Paystack's public API
// (https://paystack.com/docs/api/) but NOT exercised against Paystack: it
// needs PAYSTACK_SECRET_KEY from a signed merchant account. Unit tests run
// it against a stubbed fetch.
import { verifyPaystack } from '../webhooks.ts';
import type { CheckoutRequest, CheckoutSession, PaymentProvider, VerifiedTransaction, WebhookEvent } from './types.ts';

type Fetch = typeof fetch;

export class PaystackProvider implements PaymentProvider {
  readonly name = 'paystack';
  readonly kind = 'naira' as const;
  readonly live = true;
  private secretKey: string;
  private fetchImpl: Fetch;
  private base: string;

  constructor(secretKey: string, fetchImpl: Fetch = fetch, base = 'https://api.paystack.co') {
    if (!secretKey) throw new Error('PAYSTACK_SECRET_KEY is required');
    this.secretKey = secretKey;
    this.fetchImpl = fetchImpl;
    this.base = base;
  }

  private async call(path: string, init: RequestInit = {}) {
    const res = await this.fetchImpl(this.base + path, {
      ...init,
      headers: { authorization: `Bearer ${this.secretKey}`, 'content-type': 'application/json', ...(init.headers ?? {}) },
    });
    const json = (await res.json()) as { status: boolean; message: string; data: any };
    if (!res.ok || !json.status) throw new Error(`paystack ${path}: ${json.message}`);
    return json.data;
  }

  async createCheckout(req: CheckoutRequest): Promise<CheckoutSession> {
    if (req.currency !== 'NGN') throw new Error('paystack adapter handles NGN only');
    const channels = req.method === 'card' ? ['card'] : req.method === 'ussd' ? ['ussd'] : ['bank_transfer', 'bank'];
    const data = await this.call('/transaction/initialize', {
      method: 'POST',
      body: JSON.stringify({
        email: req.payerEmail ?? 'payer@knock.invalid',
        amount: req.amount.toString(), // kobo
        currency: 'NGN',
        reference: req.knockReference,
        channels,
        callback_url: req.callbackUrl,
        metadata: { description: req.description },
      }),
    });
    return { provider: this.name, providerReference: data.reference, checkoutUrl: data.authorization_url };
  }

  async verify(ref: string): Promise<VerifiedTransaction> {
    const d = await this.call(`/transaction/verify/${encodeURIComponent(ref)}`);
    const status = d.status === 'success' ? 'success' : d.status === 'failed' || d.status === 'abandoned' ? 'failed' : d.status === 'reversed' ? 'reversed' : 'pending';
    return { providerReference: d.reference, status, amountPaid: BigInt(d.amount), currency: d.currency, paidAt: d.paid_at, channel: d.channel, raw: d };
  }

  parseWebhook(rawBody: string, headers: Headers): WebhookEvent | null {
    if (!verifyPaystack(rawBody, headers.get('x-paystack-signature'), this.secretKey)) return null;
    const body = JSON.parse(rawBody) as { event: string; data: any };
    const ref = body.data?.reference ?? body.data?.transaction?.reference ?? '';
    // Paystack has no event id; the event name + reference + id is unique per delivery.
    return { eventId: `${body.event}:${ref}:${body.data?.id ?? ''}`, type: body.event, providerReference: ref, data: body.data };
  }

  async refund(ref: string, amount: bigint, reason: string) {
    const d = await this.call('/refund', { method: 'POST', body: JSON.stringify({ transaction: ref, amount: amount.toString(), merchant_note: reason }) });
    return { refundReference: String(d.id ?? d.transaction?.id ?? '') };
  }
}
