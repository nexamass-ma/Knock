// Provider-independent crypto infrastructure interface. Knock's deposit,
// withdrawal, settlement and reconciliation engines only see these types, so
// a second provider is a new adapter, not a rebuild. All amounts are decimal
// strings in major units exactly as the provider reported them.

export type Env = 'sandbox' | 'production';

export interface ProviderAsset {
  assetId: string; // id used to generate deposit addresses
  symbol: string;
  network: string; // '' for UTXO assets
  kind: 'stablecoin' | 'utxo' | 'crypto';
  depositEnabled: boolean;
  withdrawEnabled: boolean;
  minDeposit?: string | null;
  withdrawalFee?: string | null;
  withdrawalFeeCurrency?: string | null;
  minWithdrawal?: string | null;
  raw: unknown;
}

export interface GeneratedAddress {
  providerAddressId: string;
  address: string;
  memo?: string | null;
  raw: unknown;
}

export type DepositStatus = 'pending' | 'below_minimum' | 'flagged' | 'under_review' | 'completed' | 'failed';

/** A deposit as described by a webhook or by the provider's records. */
export interface ProviderDeposit {
  tradeId: string;
  status: DepositStatus;
  subStatus?: string | null;
  asset?: string | null;
  destinationAddress?: string | null;
  walletId?: string | null;
  cryptoAmount?: string | null;
  amountInUsd?: string | null;
  amountCredited?: string | null;
  currency?: string | null; // upper-case
  txHash?: string | null;
  confirmations?: number | null;
  rate?: string | null;
  conversionRate?: string | null;
  feeAmountUsd?: string | null;
  feePercentage?: string | null;
  balanceRemaining?: string | null;
  isWrongAsset?: boolean;
  settledTrades?: string[] | null;
  reason?: string | null;
  kyt?: unknown;
  markupPercent?: string | null;
  markupAmount?: string | null;
  amountSettled?: string | null;
  raw: unknown;
}

export type WithdrawalStatus = 'pending' | 'processing' | 'completed' | 'reversed' | 'rejected';

export interface ProviderWithdrawal {
  id: string;
  status: WithdrawalStatus;
  amount?: string | null;
  originalAmount?: string | null;
  payoutAmount?: string | null;
  currency?: string | null; // upper-case
  fee?: string | null;
  feeBearer?: 'user' | 'business' | null;
  txHash?: string | null;
  reference?: string | null;
  externalId?: string | null;
  trade?: string | null;
  cryptoAmount?: string | null;
  feeCrypto?: string | null;
  reason?: string | null;
  meta?: Record<string, unknown> | null;
  createdAt?: string | null;
  updatedAt?: string | null;
  raw: unknown;
}

/** One verified, normalized webhook event. */
export type ProviderEvent =
  | { kind: 'address.created'; address: GeneratedAddress & { asset: string; label: string } }
  | { kind: 'deposit'; deposit: ProviderDeposit }
  | { kind: 'settlement.failed'; tradeId: string; amount: string | null; currency: string | null; reason: string | null }
  | { kind: 'withdrawal'; withdrawal: ProviderWithdrawal }
  | { kind: 'unknown'; type: string };

export interface EnvelopeMeta {
  eventId: string;
  eventType: string;
  eventTime: string | null;
  resourceId: string | null;
}

export interface Page<T> {
  items: T[];
  page: number;
  hasNextPage: boolean;
  totalDocs?: number;
}

export interface CryptoWithdrawalRequest {
  externalId: string; // Knock reference, our duplicate guard
  amountUsd: string; // decimal, 2dp
  token: string;
  network?: string | null; // omitted for UTXO
  feeLevel?: 'low' | 'medium' | 'high' | null;
  walletAddress: string;
}

export interface BankWithdrawalRequest {
  externalId: string;
  savedAccountId: string;
  amount: string; // NGN / GHS decimal
  narration?: string | null;
}

/** Outcome of a financial POST. "unknown" means: do not resubmit, resolve from records. */
export type SubmitOutcome =
  | { outcome: 'accepted'; providerId: string; raw: unknown }
  | { outcome: 'rejected'; code: ProviderErrorCode; message: string }
  | { outcome: 'unknown'; code: 'timeout' | 'network_error' | 'server_error'; message: string };

export type ProviderErrorCode =
  | 'bad_request'
  | 'insufficient_provider_balance'
  | 'duplicate_withdrawal'
  | 'auth_failed'
  | 'forbidden'
  | 'not_found'
  | 'conflict'
  | 'validation'
  | 'rate_limited'
  | 'capacity'
  | 'server_error'
  | 'timeout'
  | 'network_error';

export class ProviderError extends Error {
  readonly code: ProviderErrorCode;
  readonly httpStatus: number | null;
  readonly retryAfterS: number | null;
  constructor(code: ProviderErrorCode, message: string, httpStatus: number | null = null, retryAfterS: number | null = null) {
    super(message);
    this.code = code;
    this.httpStatus = httpStatus;
    this.retryAfterS = retryAfterS;
  }
}

export interface NetworkFeeEstimate {
  low: { networkFee: string | null; networkFeeUsd: string | null };
  medium: { networkFee: string | null; networkFeeUsd: string | null };
  high: { networkFee: string | null; networkFeeUsd: string | null };
}

export interface CryptoProvider {
  readonly name: string;
  readonly env: Env;
  health(): Promise<{ ok: boolean; detail: unknown }>;
  listAssets(): Promise<ProviderAsset[]>;
  generateAddress(assetId: string, opts: { label: string; bankId?: string; accountNumber?: string; narration?: string; autoSettlement?: boolean }): Promise<GeneratedAddress>;
  listAddresses(page: number, size: number): Promise<Page<GeneratedAddress & { asset?: string | null; label?: string | null }>>;
  setAutoSettlement(providerAddressId: string, enabled: boolean): Promise<void>;
  setAddressBank(providerAddressId: string, bank: { bankId: string; accountNumber: string; narration?: string }): Promise<void>;
  getDeposit(tradeId: string): Promise<ProviderDeposit>;
  listDeposits(page: number, size: number): Promise<Page<ProviderDeposit>>;
  getWithdrawal(id: string): Promise<ProviderWithdrawal>;
  listWithdrawals(page: number, size: number): Promise<Page<ProviderWithdrawal>>;
  validateAddress(token: string, network: string | null, address: string): Promise<{ valid: boolean; raw: unknown }>;
  estimateNetworkFee(token: string, cryptoAmount: string, walletAddress: string): Promise<NetworkFeeEstimate>;
  withdrawCrypto(req: CryptoWithdrawalRequest): Promise<SubmitOutcome>;
  withdrawBank(req: BankWithdrawalRequest): Promise<SubmitOutcome>;
  /** Authenticate a webhook (source IP + shared secret). */
  authenticateWebhook(rawBody: string, headers: Headers, sourceIp: string | null): { ok: boolean; reason?: string };
  parseWebhook(rawBody: string): { meta: EnvelopeMeta; event: ProviderEvent };
  listWebhookDeliveries?(page: number, size: number, filter?: { status?: 'delivered' | 'failed' }): Promise<Page<unknown>>;
  resendWebhook?(reference: string): Promise<unknown>;
  mockTrade?(body: Record<string, unknown>): Promise<unknown>;
}
