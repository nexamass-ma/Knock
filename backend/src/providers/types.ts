// Provider-agnostic interfaces. Swap the sandbox implementations for live
// adapters (Paystack, Flutterwave, a licensed crypto payment provider) once
// contracts and credentials exist. The service layer only sees these.

export type PaymentMethod = 'bank_transfer' | 'card' | 'ussd' | 'crypto';

export interface CheckoutRequest {
  knockReference: string; // our idempotency reference, sent to the provider
  amount: bigint; // minor units the payer must pay
  currency: string;
  network: string;
  method: PaymentMethod;
  payerEmail?: string;
  description: string;
  callbackUrl: string;
}

export interface CheckoutSession {
  provider: string;
  providerReference: string;
  /** Card / hosted checkout URL, when the provider has one. */
  checkoutUrl?: string;
  /** Bank transfer: virtual account to pay into. */
  bankTransfer?: { bankName: string; accountNumber: string; accountName: string; expiresAt: string };
  /** Crypto: unique deposit address for this payment. */
  crypto?: { address: string; network: string; asset: string; memo?: string; quoteRateNgn?: string; quoteExpiresAt: string };
}

/** What the provider's verify API says about a transaction. */
export interface VerifiedTransaction {
  providerReference: string;
  status: 'success' | 'pending' | 'failed' | 'reversed';
  amountPaid: bigint; // minor units
  currency: string;
  network?: string;
  txHash?: string;
  confirmations?: number;
  paidAt?: string;
  channel?: string;
  raw: unknown;
}

export interface WebhookEvent {
  eventId: string;
  type: string; // charge.success, charge.failed, crypto.confirmation, transfer.settled, charge.dispute.create, refund.processed ...
  providerReference: string;
  data: Record<string, unknown>;
}

export interface PaymentProvider {
  readonly name: string;
  readonly kind: 'naira' | 'crypto';
  readonly live: boolean;
  createCheckout(req: CheckoutRequest): Promise<CheckoutSession>;
  verify(providerReference: string): Promise<VerifiedTransaction>;
  /** Check the signature and parse. Returns null when the signature is invalid. */
  parseWebhook(rawBody: string, headers: Headers): WebhookEvent | null;
  refund?(providerReference: string, amount: bigint, reason: string): Promise<{ refundReference: string }>;
}

export interface RateProvider {
  /** NGN per 1 unit of the asset, as a decimal string, with expiry. */
  quote(asset: string): Promise<{ rateNgn: string; expiresAt: string; source: string; live: boolean }>;
}
