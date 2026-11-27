import '../core/money.dart';
import 'ledger.dart';

/// The transaction types KNOCK can quote. The assistant may *request* a
/// quote for one of these; only the backend prices it and only the user can
/// authorise it.
enum TxFlow {
  buyCrypto('Buy crypto'),
  sellCrypto('Sell crypto'),
  buyGiftCard('Buy gift card'),
  sellGiftCard('Sell gift card'),
  airtime('Airtime'),
  data('Mobile data'),
  electricity('Electricity'),
  cable('Cable TV');

  const TxFlow(this.label);
  final String label;

  bool get isBill => this == airtime || this == data || this == electricity || this == cable;
}

/// A request for a price. Values are the raw strings the user supplied; the
/// backend parses and validates them. Never pass AI-derived amounts here
/// without the user having typed or tapped them.
class QuoteRequest {
  const QuoteRequest(this.flow, this.fields);
  final TxFlow flow;
  final Map<String, String> fields;
}

class QuoteLine {
  const QuoteLine(this.label, this.value, {this.emphasis = false});
  final String label;
  final String value;
  final bool emphasis;
}

/// A server-issued, time-limited, signed price. The client renders the
/// lines exactly as received and never recalculates them.
class Quote {
  const Quote({
    required this.id,
    required this.flow,
    required this.title,
    required this.lines,
    required this.totalLabel,
    required this.total,
    required this.receiveLabel,
    required this.receive,
    required this.issuedAt,
    required this.expiresAt,
    required this.isMock,
    this.note,
  });

  final String id;
  final TxFlow flow;
  final String title;
  final List<QuoteLine> lines;
  final String totalLabel;
  final Money total;
  final String receiveLabel;
  final String receive;
  final DateTime issuedAt;
  final DateTime expiresAt;
  final bool isMock;
  final String? note;

  bool isExpired([DateTime? now]) => (now ?? DateTime.now()).isAfter(expiresAt);
}

class QuoteException implements Exception {
  const QuoteException(this.message, {this.suggestion});
  final String message;
  final String? suggestion;
  @override
  String toString() => message;
}

/// Proof that the user, not the assistant, approved a specific quote.
/// In production this is a signature from a device-bound key (Secure
/// Enclave / Android Keystore) over a server challenge, gated by biometrics.
class AuthorizationProof {
  const AuthorizationProof({
    required this.quoteId,
    required this.method,
    required this.signedChallenge,
    required this.at,
  });
  final String quoteId;
  final String method;
  final String signedChallenge;
  final DateTime at;
}

class TransactionReceipt {
  const TransactionReceipt({required this.record, required this.headline, required this.detail, required this.flow});
  final TransactionRecord record;
  final String headline;
  final String detail;
  final TxFlow flow;
}
