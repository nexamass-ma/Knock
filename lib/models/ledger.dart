import '../core/money.dart';

/// KNOCK keeps three separate ledgers. Balances are never merged or moved
/// between them on the client; every movement is a backend journal entry.
enum LedgerKind {
  naira('Naira wallet'),
  crypto('Crypto'),
  dollarCard('Dollar card');

  const LedgerKind(this.label);
  final String label;
}

class LedgerBalance {
  const LedgerBalance({required this.kind, required this.available, required this.pending, required this.locked});

  final LedgerKind kind;
  final Money available;
  final Money pending;

  /// True while a ledger exists in the design but is not operational
  /// (the dollar card before an issuing partner is live).
  final bool locked;
}

enum TxCategory {
  crypto('Crypto'),
  giftCard('Gift cards'),
  bills('Bills'),
  wallet('Wallet');

  const TxCategory(this.label);
  final String label;
}

enum TxStatus {
  pending('Pending'),
  inReview('In review'),
  completed('Completed'),
  failed('Failed');

  const TxStatus(this.label);
  final String label;
}

class AuditEvent {
  const AuditEvent(this.label, this.at);
  final String label;
  final DateTime at;
}

class TransactionRecord {
  const TransactionRecord({
    required this.id,
    required this.reference,
    required this.category,
    required this.title,
    required this.subtitle,
    required this.amount,
    required this.isCredit,
    required this.status,
    required this.createdAt,
    required this.ledger,
    this.audit = const [],
    this.secondaryAmount,
  });

  final String id;
  final String reference;
  final TxCategory category;
  final String title;
  final String subtitle;
  final Money amount;
  final bool isCredit;
  final TxStatus status;
  final DateTime createdAt;
  final LedgerKind ledger;
  final List<AuditEvent> audit;

  /// e.g. "+0.0012 BTC" for a crypto purchase.
  final String? secondaryAmount;
}
