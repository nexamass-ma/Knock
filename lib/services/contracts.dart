import 'dart:typed_data';

import '../models/asset.dart';
import '../models/chat.dart';
import '../models/ledger.dart';
import '../models/quote.dart';

/// Provider-agnostic service contracts. The UI depends only on these, so a
/// liquidity, gift-card, bills, wallet, card-issuing or AI provider can be
/// swapped behind the KNOCK backend without touching screens.
///
/// Every implementation in production talks to the KNOCK backend, never to
/// third-party providers directly from the device.

abstract interface class WalletService {
  Future<PortfolioSummary> portfolio(ChartRange range);
  Future<List<LedgerBalance>> balances();
  Future<List<Holding>> holdings();
  Future<List<double>> priceHistory(String ticker, ChartRange range);
}

abstract interface class ActivityService {
  Future<List<TransactionRecord>> transactions();
}

/// Prices transactions. Backed by liquidity providers (crypto), gift card
/// trading partners and bill aggregators on the server.
abstract interface class QuoteService {
  Future<Quote> requestQuote(QuoteRequest request);
}

/// Executes a quote the user has authorised. Idempotent on [idempotencyKey]:
/// retrying the same key never creates a second transaction.
abstract interface class TransactionService {
  Future<TransactionReceipt> execute({
    required Quote quote,
    required AuthorizationProof proof,
    required String idempotencyKey,
  });
}

/// Identifies a gift card from a photo. Production: server-side vision model
/// plus partner verification. The client only uploads the image.
abstract interface class GiftCardRecognitionService {
  Future<GiftCardScanResult> recognize(Uint8List image, {String? hintBrandId});
}

/// Turns free text into a structured *intent* (what the user wants and the
/// values they typed). It never returns prices and never executes anything.
abstract interface class ConversationService {
  Future<Interpretation> interpret(String text, {TxFlow? activeFlow, String? pendingField});
}

class Interpretation {
  const Interpretation({this.flow, this.fields = const {}, this.smallTalk});
  final TxFlow? flow;
  final Map<String, String> fields;
  final SmallTalk? smallTalk;
}

enum SmallTalk { greeting, balance, help, thanks, cancel, decline }

abstract interface class CardWaitlistService {
  Future<bool> isOnWaitlist();
  Future<void> joinWaitlist();
}

class ServiceUnavailable implements Exception {
  const ServiceUnavailable([this.message = 'We could not reach KNOCK. Check your connection and try again.']);
  final String message;
  @override
  String toString() => message;
}
