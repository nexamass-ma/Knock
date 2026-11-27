// Sandbox providers. They behave like real providers from the service's
// point of view (sessions, signed webhooks, a verify API that is the source
// of truth) but no real money or chain is involved. Every response is
// marked live: false and the UI labels it SANDBOX.
import { randomBytes, randomUUID } from 'node:crypto';
import { signTimestamped, verifyTimestamped } from '../webhooks.ts';
import type { CheckoutRequest, CheckoutSession, PaymentProvider, RateProvider, VerifiedTransaction, WebhookEvent } from './types.ts';

interface SandboxTx {
  ref: string;
  expected: bigint;
  currency: string;
  network: string;
  status: VerifiedTransaction['status'];
  paid: bigint;
  txHash?: string;
  confirmations: number;
  channel: string;
}

abstract class SandboxBase implements PaymentProvider {
  abstract readonly name: string;
  abstract readonly kind: 'naira' | 'crypto';
  readonly live = false;
  protected txs = new Map<string, SandboxTx>();
  readonly webhookSecret: string;

  constructor(webhookSecret: string) {
    this.webhookSecret = webhookSecret;
  }

  abstract createCheckout(req: CheckoutRequest): Promise<CheckoutSession>;

  async verify(ref: string): Promise<VerifiedTransaction> {
    const t = this.txs.get(ref);
    if (!t) throw new Error(`sandbox: unknown reference ${ref}`);
    return {
      providerReference: ref,
      status: t.status,
      amountPaid: t.paid,
      currency: t.currency,
      network: t.network,
      txHash: t.txHash,
      confirmations: t.confirmations,
      paidAt: new Date().toISOString(),
      channel: t.channel,
      raw: { sandbox: true, ...t, expected: t.expected.toString(), paid: t.paid.toString() },
    };
  }

  parseWebhook(rawBody: string, headers: Headers): WebhookEvent | null {
    if (!verifyTimestamped(rawBody, headers.get('x-knock-sandbox-signature'), this.webhookSecret)) return null;
    const body = JSON.parse(rawBody) as WebhookEvent;
    return body;
  }

  async refund(ref: string): Promise<{ refundReference: string }> {
    const t = this.txs.get(ref);
    if (!t) throw new Error('sandbox: unknown reference');
    t.status = 'reversed';
    return { refundReference: 'SBX-RF-' + randomBytes(4).toString('hex') };
  }

  /** Build a signed webhook exactly as the provider would send it. */
  signedEvent(type: string, ref: string, data: Record<string, unknown> = {}): { body: string; headers: Record<string, string> } {
    const evt: WebhookEvent = { eventId: randomUUID(), type, providerReference: ref, data };
    const body = JSON.stringify(evt);
    return { body, headers: { 'content-type': 'application/json', 'x-knock-sandbox-signature': signTimestamped(body, this.webhookSecret) } };
  }

  /** The payer "pays". Default: exactly the expected amount. */
  simulatePayment(ref: string, opts: { amount?: bigint; fail?: boolean; channel?: string } = {}) {
    const t = this.txs.get(ref);
    if (!t) throw new Error('sandbox: unknown reference');
    if (opts.fail) {
      t.status = 'failed';
      return this.signedEvent('charge.failed', ref);
    }
    t.paid = opts.amount ?? t.expected;
    t.channel = opts.channel ?? t.channel;
    t.status = 'success';
    return this.signedEvent('charge.success', ref);
  }

  settlementEvent(ref: string, providerFee: bigint) {
    return this.signedEvent('settlement.completed', ref, { providerFee: providerFee.toString(), settlementRef: 'SBX-ST-' + randomBytes(4).toString('hex') });
  }

  disputeEvent(ref: string, reason: string) {
    return this.signedEvent('charge.dispute.create', ref, { disputeId: 'SBX-DP-' + randomBytes(4).toString('hex'), reason });
  }

  /** Test hook: tamper with what verify() reports. */
  setVerified(ref: string, patch: Partial<SandboxTx>) {
    const t = this.txs.get(ref);
    if (t) Object.assign(t, patch);
  }
}

/** Behaves like Paystack/Flutterwave: card, bank transfer and USSD in NGN. */
export class SandboxNairaProvider extends SandboxBase {
  readonly name = 'sandbox_naira';
  readonly kind = 'naira' as const;

  async createCheckout(req: CheckoutRequest): Promise<CheckoutSession> {
    const ref = 'SBX-NG-' + randomBytes(6).toString('hex').toUpperCase();
    this.txs.set(ref, { ref, expected: req.amount, currency: req.currency, network: 'fiat', status: 'pending', paid: 0n, confirmations: 0, channel: req.method });
    const session: CheckoutSession = { provider: this.name, providerReference: ref, checkoutUrl: `${req.callbackUrl}?sandbox_ref=${ref}` };
    if (req.method === 'bank_transfer') {
      session.bankTransfer = {
        bankName: 'Sandbox Bank (not real)',
        accountNumber: '99' + String(Math.floor(Math.random() * 1e8)).padStart(8, '0'),
        accountName: 'KNOCK / ' + req.description.slice(0, 20),
        expiresAt: new Date(Date.now() + 30 * 60_000).toISOString(),
      };
    }
    return session;
  }
}

/** Behaves like a crypto payment gateway: unique deposit address + confirmations. */
export class SandboxCryptoProvider extends SandboxBase {
  readonly name = 'sandbox_crypto';
  readonly kind = 'crypto' as const;

  async createCheckout(req: CheckoutRequest): Promise<CheckoutSession> {
    const ref = 'SBX-CX-' + randomBytes(6).toString('hex').toUpperCase();
    this.txs.set(ref, { ref, expected: req.amount, currency: req.currency, network: req.network, status: 'pending', paid: 0n, confirmations: 0, channel: 'crypto' });
    const address = req.network === 'TRC20' ? 'T' + randomBytes(16).toString('hex').slice(0, 33) : '0x' + randomBytes(20).toString('hex');
    return {
      provider: this.name,
      providerReference: ref,
      crypto: { address, network: req.network, asset: req.currency, quoteExpiresAt: new Date(Date.now() + 15 * 60_000).toISOString() },
    };
  }

  /** A transaction lands on chain with `confirmations` so far. */
  simulateChainTx(ref: string, opts: { amount?: bigint; confirmations: number; network?: string; txHash?: string }) {
    const t = this.txs.get(ref);
    if (!t) throw new Error('sandbox: unknown reference');
    t.paid = opts.amount ?? t.expected;
    t.confirmations = opts.confirmations;
    t.txHash = opts.txHash ?? t.txHash ?? '0x' + randomBytes(32).toString('hex');
    if (opts.network) t.network = opts.network;
    t.status = 'success';
    return this.signedEvent('crypto.confirmation', ref, { confirmations: opts.confirmations, txHash: t.txHash });
  }
}

/** [Guess] Fixed sandbox rates. A live rate feed comes from the liquidity partner. */
export class SandboxRates implements RateProvider {
  rates: Record<string, string> = { USDT: '1650.00', USDC: '1650.00', BTC: '158000000.00' };
  async quote(asset: string) {
    return { rateNgn: this.rates[asset] ?? '0', expiresAt: new Date(Date.now() + 15 * 60_000).toISOString(), source: 'sandbox', live: false };
  }
}
