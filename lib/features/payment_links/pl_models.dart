/// Payment Links data model. Amounts are integers in the asset's minor unit
/// (kobo for NGN, 1e-6 for USDT/USDC, satoshi for BTC). The client formats;
/// the server (backend/supabase) is the authority on every number.
library;

enum LinkType {
  naira('Naira link', 'Collect NGN by bank transfer, card or USSD'),
  crypto('Crypto link', 'Collect USDT, USDC or BTC on a chosen network'),
  split('Split payment', 'One link, paid out to several Knock users automatically');

  const LinkType(this.label, this.blurb);
  final String label;
  final String blurb;
}

enum AmountMode { fixed, flexible }

enum SplitMethod {
  fixed('Fixed split', 'Each person gets the exact amount you set, filled as payments arrive'),
  percentage('Percentage split', 'Each person gets their percentage of every payment');

  const SplitMethod(this.label, this.blurb);
  final String label;
  final String blurb;
}

enum SettlementMode {
  eachPayment('After every payment', 'Every verified payment is split and credited straight away'),
  onTarget('When the target is reached', 'Money is held until the full target is collected, then split'),
  manual('Manually', 'Money is held in your collection balance until you distribute it');

  const SettlementMode(this.label, this.blurb);
  final String label;
  final String blurb;
}

enum FeeBearer {
  deduct('Deduct from the payment', 'The Knock fee comes off each payment before it is split, shared pro rata'),
  payer('Payer pays the fee', 'The fee is added on top at checkout; recipients get their full share');

  const FeeBearer(this.label, this.blurb);
  final String label;
  final String blurb;
}

enum LinkStatus {
  active('Active'),
  paused('Paused'),
  completed('Completed'),
  expired('Expired'),
  underReview('Under review'),
  closed('Closed');

  const LinkStatus(this.label);
  final String label;
}

enum PayStatus {
  initiated('Started'),
  pending('Pending'),
  confirming('Confirming'),
  succeeded('Successful'),
  failed('Failed'),
  reversed('Reversed'),
  disputed('Disputed');

  const PayStatus(this.label);
  final String label;
}

enum DistributionStatus {
  none('Not distributed'),
  held('Held'),
  distributed('Distributed'),
  failedRetrying('Retrying'),
  reversed('Reversed');

  const DistributionStatus(this.label);
  final String label;
}

/// Pending = allocated, provider has not settled yet. Available = spendable
/// in the recipient's Knock wallet. Held = frozen by a dispute.
enum AllocState {
  pending('Pending'),
  available('Available'),
  held('On hold'),
  reversed('Reversed');

  const AllocState(this.label);
  final String label;
}

enum PayMethod {
  bankTransfer('Bank transfer'),
  card('Card'),
  ussd('USSD'),
  crypto('Crypto');

  const PayMethod(this.label);
  final String label;
}

class PlAsset {
  const PlAsset(this.code, this.network, this.decimals, this.confirmations, {this.isFiat = false});
  final String code;
  final String network;
  final int decimals;
  final int confirmations;
  final bool isFiat;

  String get label => isFiat ? 'Naira (NGN)' : '$code · $network';

  static const ngn = PlAsset('NGN', 'fiat', 2, 0, isFiat: true);

  /// [Guess] Launch assets and confirmation depths, to confirm with the provider.
  static const crypto = [
    PlAsset('USDT', 'TRC20', 6, 20),
    PlAsset('USDT', 'BEP20', 6, 15),
    PlAsset('USDC', 'BEP20', 6, 15),
    PlAsset('BTC', 'BITCOIN', 8, 2),
  ];
}

class KnockUser {
  const KnockUser({
    required this.id,
    required this.username,
    required this.displayName,
    required this.initials,
    required this.verified,
    this.frozen = false,
  });
  final String id;
  final String username;
  final String displayName;
  final String initials;
  final bool verified;
  final bool frozen;
}

class RecipientRule {
  const RecipientRule({required this.user, required this.allocated, required this.basisPoints, this.isCreatorRemainder = false});
  final KnockUser user;
  final int allocated;
  final int basisPoints;
  final bool isCreatorRemainder;

  double get percent => basisPoints / 100;
}

class PaymentLink {
  PaymentLink({
    required this.id,
    required this.reference,
    required this.slug,
    required this.creator,
    required this.type,
    required this.title,
    required this.asset,
    required this.amountMode,
    required this.splitMethod,
    required this.settlementMode,
    required this.feeBearer,
    required this.rules,
    required this.createdAt,
    this.description,
    this.fixedAmount,
    this.target,
    this.expiresAt,
    this.requireCustomerReference = false,
    this.invoiceNumber,
    this.instructions,
    this.status = LinkStatus.active,
  });

  final String id;
  final String reference;
  final String slug;
  final KnockUser creator;
  final LinkType type;
  String title;
  String? description;
  final PlAsset asset;
  final AmountMode amountMode;
  final int? fixedAmount;
  final int? target;
  final SplitMethod splitMethod;
  final SettlementMode settlementMode;
  final FeeBearer feeBearer;

  /// Rule versions; index 0 is version 1. Old versions are never edited.
  final List<List<RecipientRule>> rules;
  final DateTime createdAt;
  DateTime? expiresAt;
  bool requireCustomerReference;
  String? invoiceNumber;
  String? instructions;
  LinkStatus status;
  DateTime? firstPaymentAt;

  int get ruleVersion => rules.length;
  List<RecipientRule> get currentRules => rules.last;
  bool get rulesLocked => firstPaymentAt != null;
  String get url => 'https://pay.knock.app/l/$slug';
}

class LinkPayment {
  LinkPayment({
    required this.id,
    required this.reference,
    required this.linkId,
    required this.provider,
    required this.providerReference,
    required this.method,
    required this.amount,
    required this.payerFee,
    required this.knockFee,
    required this.createdAt,
    this.payerName,
    this.payerEmail,
    this.customerReference,
    this.address,
    this.network,
    this.rateNgn,
  });

  final String id;
  final String reference;
  final String linkId;
  final String provider;
  final String providerReference;
  final PayMethod method;
  int amount;
  int payerFee;
  int knockFee;
  int? grossPaid;
  final DateTime createdAt;
  final String? payerName;
  final String? payerEmail;
  final String? customerReference;
  final String? address;
  final String? network;
  final double? rateNgn;
  PayStatus status = PayStatus.initiated;
  DistributionStatus distribution = DistributionStatus.none;
  String? holdReason;
  int attempts = 0;
  int confirmations = 0;
  String? txHash;
  DateTime? verifiedAt;
  DateTime? settledAt;
  int? ruleVersion;

  int get totalToPay => amount + payerFee;
}

class Allocation {
  Allocation({
    required this.id,
    required this.paymentId,
    required this.linkId,
    required this.recipient,
    required this.ruleVersion,
    required this.gross,
    required this.fee,
    required this.overflow,
    required this.entryRef,
    required this.at,
    required this.state,
  });
  final String id;
  final String paymentId;
  final String linkId;
  final KnockUser recipient;
  final int ruleVersion;
  final int gross;
  final int fee;
  final bool overflow;
  final String entryRef;
  final DateTime at;
  AllocState state;
  int get net => gross - fee;
}

class PlNotification {
  PlNotification(this.userId, this.kind, this.title, this.body, this.at, {this.linkId});
  final String userId;
  final String kind;
  final String title;
  final String body;
  final DateTime at;
  final String? linkId;
}

class AuditEntry {
  AuditEntry(this.at, this.actor, this.action, {this.linkId, this.detail});
  final DateTime at;
  final String actor;
  final String action;
  final String? linkId;
  final String? detail;
}

class RiskFlag {
  RiskFlag(this.at, this.rule, this.severity, this.detail, {this.linkId, this.paymentId});
  final DateTime at;
  final String rule;
  final String severity;
  final String detail;
  final String? linkId;
  final String? paymentId;
  bool open = true;
}

class SplitTemplate {
  SplitTemplate(this.id, this.name, this.method, this.members);
  final String id;
  final String name;
  final SplitMethod method;

  /// (user, amount for fixed, basis points for percentage)
  final List<(KnockUser, int, int)> members;
}

class Amendment {
  Amendment({
    required this.id,
    required this.linkId,
    required this.fromVersion,
    required this.reason,
    required this.proposed,
    required this.approvers,
    required this.at,
  });
  final String id;
  final String linkId;
  final int fromVersion;
  final String reason;
  final List<RecipientRule> proposed;
  final Map<String, bool?> approvers; // userId -> decision
  final DateTime at;
  String status = 'proposed';
}

class LinkTotals {
  const LinkTotals({
    required this.collected,
    required this.distributed,
    required this.held,
    required this.succeeded,
    required this.pending,
    required this.failed,
  });
  final int collected;
  final int distributed;
  final int held;
  final int succeeded;
  final int pending;
  final int failed;
}

class PlException implements Exception {
  PlException(this.code, this.message);
  final String code;
  final String message;
  @override
  String toString() => message;
}
