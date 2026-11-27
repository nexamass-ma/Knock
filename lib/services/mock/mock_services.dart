import 'dart:typed_data';

import '../../models/asset.dart';
import '../../models/catalog.dart';
import '../../models/chat.dart';
import '../../models/ledger.dart';
import '../../models/quote.dart';
import '../contracts.dart';
import '../intent_parser.dart';
import 'mock_backend.dart';

/// Mock implementations of every service contract, all backed by one
/// [MockBackend]. Replace each with an HTTP client to the KNOCK backend.

class MockWalletService implements WalletService, ActivityService {
  MockWalletService(this._b);
  final MockBackend _b;

  @override
  Future<PortfolioSummary> portfolio(ChartRange range) => _b.portfolio(range);
  @override
  Future<List<LedgerBalance>> balances() => _b.balances();
  @override
  Future<List<Holding>> holdings() => _b.holdings();
  @override
  Future<List<double>> priceHistory(String ticker, ChartRange range) => _b.priceHistory(ticker, range);
  @override
  Future<List<TransactionRecord>> transactions() => _b.transactions();
}

class MockQuoteService implements QuoteService {
  MockQuoteService(this._b);
  final MockBackend _b;
  @override
  Future<Quote> requestQuote(QuoteRequest request) => _b.quote(request);
}

class MockTransactionService implements TransactionService {
  MockTransactionService(this._b);
  final MockBackend _b;
  @override
  Future<TransactionReceipt> execute({
    required Quote quote,
    required AuthorizationProof proof,
    required String idempotencyKey,
  }) => _b.execute(quote, proof, idempotencyKey);
}

/// Pretends to read a gift card photo. Production: upload to the backend,
/// which runs card recognition and partner verification.
class MockGiftCardRecognition implements GiftCardRecognitionService {
  MockGiftCardRecognition(this._b);
  final MockBackend _b;

  @override
  Future<GiftCardScanResult> recognize(Uint8List image, {String? hintBrandId}) async {
    await Future<void>.delayed(const Duration(milliseconds: 1400));
    if (_b.simulateErrors) throw const ServiceUnavailable('The card scanner is unavailable right now.');
    final brand = GiftCardCatalog.byId(hintBrandId ?? '') ?? GiftCardCatalog.brands.first;
    // Use the image size to vary the mock result a little.
    final values = [50, 100, 100, 200];
    return GiftCardScanResult(
      brandId: brand.id,
      brandName: brand.name,
      faceValueUsd: values[image.length % values.length],
      cardType: 'Physical',
      region: 'US',
      confidence: 0.94,
    );
  }
}

class MockConversationService implements ConversationService {
  const MockConversationService();
  @override
  Future<Interpretation> interpret(String text, {TxFlow? activeFlow, String? pendingField}) async {
    await Future<void>.delayed(const Duration(milliseconds: 350));
    return IntentParser.parse(text, activeFlow: activeFlow, pendingField: pendingField);
  }
}

class MockCardWaitlist implements CardWaitlistService {
  MockCardWaitlist(this._b);
  final MockBackend _b;
  @override
  Future<bool> isOnWaitlist() async => _b.waitlisted;
  @override
  Future<void> joinWaitlist() async {
    await Future<void>.delayed(const Duration(milliseconds: 500));
    _b.waitlisted = true;
  }
}
