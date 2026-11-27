import 'dart:math';

import '../../core/money.dart';
import '../../models/asset.dart';
import '../../models/catalog.dart';
import '../../models/ledger.dart';
import '../../models/quote.dart';
import '../contracts.dart';

/// An in-memory stand-in for the KNOCK backend. It plays the role of the
/// pricing engine, ledgers and settlement so the prototype behaves end to
/// end. ALL NUMBERS ARE MOCK. Rates, fees and limits are placeholders.
class MockBackend {
  MockBackend() {
    reset();
  }

  // ---- Mock market data (placeholders) ----
  static const usdNgnBuy = 1580.0; // what users pay per $1 when buying
  static const usdNgnSell = 1530.0; // what users get per $1 when selling
  static const usdNgnMid = 1555.0;
  static const minNaira = 1000.0;
  static const tierOneDailyLimit = 5000000.0;
  static const quoteTtl = Duration(seconds: 60);

  static const _pricesUsd = {'BTC': 96420.0, 'ETH': 3418.5, 'USDT': 1.0, 'SOL': 182.4, 'USDC': 1.0};
  static const _change = {'BTC': 2.85, 'ETH': 1.20, 'USDT': 0.01, 'SOL': -3.42, 'USDC': 0.00};

  bool simulateErrors = false;
  Duration latency = const Duration(milliseconds: 650);

  late int _nairaKobo;
  late Map<String, double> _holdings;
  late List<TransactionRecord> _ledgerEntries;
  final Map<String, Quote> _quotes = {};
  final Map<String, Map<String, String>> _quoteFields = {};
  final Map<String, TransactionReceipt> _idempotency = {};
  final Set<String> _consumedQuotes = {};
  bool waitlisted = false;
  int _refSeq = 4100;

  void reset() {
    _nairaKobo = 48250000; // ₦482,500.00
    _holdings = {'BTC': 0.0425, 'ETH': 0.82, 'USDT': 640.0, 'SOL': 6.5, 'USDC': 120.0};
    _quotes.clear();
    _quoteFields.clear();
    _idempotency.clear();
    _consumedQuotes.clear();
    waitlisted = false;
    _ledgerEntries = _seedActivity();
  }

  Future<void> _tick() async {
    await Future<void>.delayed(latency);
    if (simulateErrors) throw const ServiceUnavailable();
  }

  // ---------------------------------------------------------------- wallet

  double priceUsd(String t) => _pricesUsd[t] ?? 0;
  double priceNgn(String t) => priceUsd(t) * usdNgnMid;

  Future<List<Holding>> holdings() async {
    await _tick();
    return [
      for (final a in SupportedAssets.all)
        Holding(
          asset: a,
          quantity: _holdings[a.ticker] ?? 0,
          priceNgn: priceNgn(a.ticker),
          priceUsd: priceUsd(a.ticker),
          change24h: _change[a.ticker] ?? 0,
          sparkline: _series(a.ticker.hashCode, 24, _change[a.ticker] ?? 0),
        ),
    ];
  }

  double get _cryptoUsd => _holdings.entries.fold(0.0, (sum, e) => sum + e.value * priceUsd(e.key));

  Future<List<LedgerBalance>> balances() async {
    await _tick();
    return [
      LedgerBalance(
        kind: LedgerKind.naira,
        available: Money(_nairaKobo, Currency.ngn),
        pending: const Money(0, Currency.ngn),
        locked: false,
      ),
      LedgerBalance(
        kind: LedgerKind.crypto,
        available: Money.major(_cryptoUsd * usdNgnMid, Currency.ngn),
        pending: const Money(0, Currency.ngn),
        locked: false,
      ),
      const LedgerBalance(
        kind: LedgerKind.dollarCard,
        available: Money(0, Currency.usd),
        pending: Money(0, Currency.usd),
        locked: true,
      ),
    ];
  }

  Future<PortfolioSummary> portfolio(ChartRange range) async {
    await _tick();
    final totalNgn = _nairaKobo / 100 + _cryptoUsd * usdNgnMid;
    final change = switch (range) {
      ChartRange.day => 1.12,
      ChartRange.week => 2.12,
      ChartRange.month => 6.48,
      ChartRange.year => 38.9,
    };
    final points = switch (range) {
      ChartRange.day => 24,
      ChartRange.week => 28,
      ChartRange.month => 30,
      ChartRange.year => 52,
    };
    return PortfolioSummary(
      totalNgn: Money.major(totalNgn, Currency.ngn),
      totalUsd: Money.major(totalNgn / usdNgnMid, Currency.usd),
      changePercent: change,
      history: _series(range.index + 7, points, change),
      range: range,
      source: DataSource.mock,
      asOf: DateTime.now(),
    );
  }

  Future<List<double>> priceHistory(String ticker, ChartRange range) async {
    await _tick();
    final n = [24, 28, 30, 52][range.index];
    final drift = (_change[ticker] ?? 0) * (range.index + 1);
    return _series(ticker.hashCode + range.index, n, drift);
  }

  Future<List<TransactionRecord>> transactions() async {
    await _tick();
    final list = [..._ledgerEntries]..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return list;
  }

  /// Deterministic random walk that ends roughly [driftPercent] above start.
  List<double> _series(int seed, int n, double driftPercent) {
    final r = Random(seed);
    final out = <double>[];
    var v = 100.0;
    final step = driftPercent / n;
    for (var i = 0; i < n; i++) {
      v += step + (r.nextDouble() - 0.5) * 1.6;
      out.add(v);
    }
    return out;
  }

  // ---------------------------------------------------------------- quotes

  String _id(String p) => '$p-${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}';

  Future<Quote> quote(QuoteRequest req) async {
    await _tick();
    final f = req.fields;
    final now = DateTime.now();
    late Quote q;

    double naira(String key) {
      final v = parseNairaAmount(f[key] ?? '');
      if (v == null) throw const QuoteException('That amount does not look right.');
      return v;
    }

    void checkLimits(double amount) {
      if (amount < minNaira) {
        throw QuoteException('The minimum is ${Fmt.money(minNaira, Currency.ngn, showDecimals: false)}.');
      }
      if (amount > tierOneDailyLimit) {
        throw QuoteException(
          'That is above your daily limit of ${Fmt.money(tierOneDailyLimit, Currency.ngn, showDecimals: false)}.',
          suggestion: 'Upgrade your verification level in Profile to raise it.',
        );
      }
    }

    void checkNaira(double total) {
      if (total * 100 > _nairaKobo) {
        throw QuoteException(
          'Your Naira wallet has ${Money(_nairaKobo, Currency.ngn).format()}, which is not enough for this.',
          suggestion: 'Fund your wallet or try a smaller amount.',
        );
      }
    }

    switch (req.flow) {
      case TxFlow.buyCrypto:
        final asset = SupportedAssets.byTicker(f['asset'] ?? '');
        if (asset == null) throw const QuoteException('That asset is not supported yet.');
        final amount = naira('amount');
        checkLimits(amount);
        final rate = priceUsd(asset.ticker) * usdNgnBuy;
        final fee = max(100.0, amount * 0.01);
        final total = amount + fee;
        checkNaira(total);
        final qty = amount / rate;
        q = Quote(
          id: _id('q-bc'),
          flow: req.flow,
          title: 'Buy ${asset.name}',
          lines: [
            QuoteLine('Asset', '${asset.name} (${asset.ticker})'),
            QuoteLine('Amount', Fmt.money(amount, Currency.ngn)),
            QuoteLine('Rate', '1 ${asset.ticker} = ${Fmt.money(rate, Currency.ngn)}'),
            QuoteLine('Fee (1%)', Fmt.money(fee, Currency.ngn)),
            QuoteLine('Pay from', 'Naira wallet'),
          ],
          totalLabel: 'Total payable',
          total: Money.major(total, Currency.ngn),
          receiveLabel: 'You receive (est.)',
          receive: '${Fmt.quantity(qty)} ${asset.ticker}',
          issuedAt: now,
          expiresAt: now.add(quoteTtl),
          isMock: true,
        );
      case TxFlow.sellCrypto:
        final asset = SupportedAssets.byTicker(f['asset'] ?? '');
        if (asset == null) throw const QuoteException('That asset is not supported yet.');
        final amount = naira('amount');
        checkLimits(amount);
        final rate = priceUsd(asset.ticker) * usdNgnSell;
        final qty = amount / rate;
        final held = _holdings[asset.ticker] ?? 0;
        if (qty > held) {
          throw QuoteException(
            'You hold ${Fmt.quantity(held)} ${asset.ticker}, worth about '
            '${Fmt.money(held * rate, Currency.ngn, showDecimals: false)} at the current rate.',
            suggestion: 'Try a smaller amount.',
          );
        }
        final fee = amount * 0.005;
        q = Quote(
          id: _id('q-sc'),
          flow: req.flow,
          title: 'Sell ${asset.name}',
          lines: [
            QuoteLine('Asset', '${asset.name} (${asset.ticker})'),
            QuoteLine('You sell', '${Fmt.quantity(qty)} ${asset.ticker}'),
            QuoteLine('Rate', '1 ${asset.ticker} = ${Fmt.money(rate, Currency.ngn)}'),
            QuoteLine('Fee (0.5%)', Fmt.money(fee, Currency.ngn)),
            const QuoteLine('Pay into', 'Naira wallet'),
          ],
          totalLabel: 'You receive',
          total: Money.major(amount - fee, Currency.ngn),
          receiveLabel: 'Debited from crypto',
          receive: '${Fmt.quantity(qty)} ${asset.ticker}',
          issuedAt: now,
          expiresAt: now.add(quoteTtl),
          isMock: true,
        );
      case TxFlow.sellGiftCard:
        final brand = GiftCardCatalog.byId(f['brand'] ?? '');
        final value = parseUsdAmount(f['value'] ?? '');
        if (brand == null || value == null) {
          throw const QuoteException('I need a verified card before I can price it.');
        }
        final physical = (f['cardType'] ?? 'Physical') == 'Physical';
        final rate = brand.sellRateNgn * (physical ? 1 : 0.94);
        final receive = value * rate;
        q = Quote(
          id: _id('q-sg'),
          flow: req.flow,
          title: 'Sell ${brand.name} gift card',
          lines: [
            QuoteLine('Card', '${brand.name} · ${f['region'] ?? 'US'} · ${f['cardType'] ?? 'Physical'}'),
            QuoteLine('Face value', Fmt.money(value, Currency.usd, showDecimals: false)),
            QuoteLine('Rate', '${Fmt.money(rate, Currency.ngn, showDecimals: false)} per \$1'),
            const QuoteLine('Fee', '₦0.00'),
            const QuoteLine('Pay into', 'Naira wallet'),
          ],
          totalLabel: 'You receive',
          total: Money.major(receive, Currency.ngn),
          receiveLabel: 'Payout',
          receive: 'After partner verification',
          issuedAt: now,
          expiresAt: now.add(const Duration(minutes: 5)),
          isMock: true,
          note: 'Final payout depends on card verification by our partner.',
        );
      case TxFlow.buyGiftCard:
        final brand = GiftCardCatalog.byId(f['brand'] ?? '');
        final value = parseUsdAmount(f['value'] ?? '');
        if (brand == null || value == null) throw const QuoteException('Pick a card and value first.');
        final cost = value * 1600;
        const fee = 500.0;
        checkNaira(cost + fee);
        q = Quote(
          id: _id('q-bg'),
          flow: req.flow,
          title: 'Buy ${brand.name} gift card',
          lines: [
            QuoteLine('Card', '${brand.name} · ${f['region'] ?? 'US'} · E-code'),
            QuoteLine('Value', Fmt.money(value, Currency.usd, showDecimals: false)),
            const QuoteLine('Rate', '₦1,600 per \$1'),
            QuoteLine('Service fee', Fmt.money(fee, Currency.ngn)),
            const QuoteLine('Pay from', 'Naira wallet'),
          ],
          totalLabel: 'Total payable',
          total: Money.major(cost + fee, Currency.ngn),
          receiveLabel: 'Delivery',
          receive: 'E-code in Activity',
          issuedAt: now,
          expiresAt: now.add(quoteTtl),
          isMock: true,
        );
      case TxFlow.airtime || TxFlow.electricity:
        final amount = naira('amount');
        if (amount < 50) throw const QuoteException('The minimum is ₦50.');
        if (amount > 200000) throw const QuoteException('The maximum per payment is ₦200,000.');
        final isPower = req.flow == TxFlow.electricity;
        final fee = isPower ? 100.0 : 0.0;
        checkNaira(amount + fee);
        q = Quote(
          id: _id(isPower ? 'q-el' : 'q-at'),
          flow: req.flow,
          title: isPower ? 'Electricity token' : '${f['network']} airtime',
          lines: [
            if (isPower) QuoteLine('Provider', f['disco'] ?? '-') else QuoteLine('Network', f['network'] ?? '-'),
            if (isPower) QuoteLine('Meter', f['meter'] ?? '-') else QuoteLine('Phone', f['phone'] ?? '-'),
            QuoteLine('Amount', Fmt.money(amount, Currency.ngn)),
            QuoteLine('Fee', Fmt.money(fee, Currency.ngn)),
            const QuoteLine('Pay from', 'Naira wallet'),
          ],
          totalLabel: 'Total payable',
          total: Money.major(amount + fee, Currency.ngn),
          receiveLabel: isPower ? 'Token' : 'Delivery',
          receive: isPower ? 'Shown after payment' : 'Instant',
          issuedAt: now,
          expiresAt: now.add(quoteTtl),
          isMock: true,
        );
      case TxFlow.data || TxFlow.cable:
        final isCable = req.flow == TxFlow.cable;
        final plan = f['plan'] ?? '';
        final cablePlans = BillCatalog.cablePlans[f['provider']] ?? const <String, int>{};
        final price = isCable ? cablePlans[plan] : BillCatalog.dataPlans[plan];
        if (price == null) throw const QuoteException('Pick one of the listed plans.');
        checkNaira(price.toDouble());
        q = Quote(
          id: _id(isCable ? 'q-cb' : 'q-dt'),
          flow: req.flow,
          title: isCable ? '${f['provider']} subscription' : '${f['network']} data',
          lines: [
            if (isCable) QuoteLine('Provider', f['provider'] ?? '-') else QuoteLine('Network', f['network'] ?? '-'),
            if (isCable) QuoteLine('Smartcard', f['smartcard'] ?? '-') else QuoteLine('Phone', f['phone'] ?? '-'),
            QuoteLine('Plan', plan),
            const QuoteLine('Fee', '₦0.00'),
            const QuoteLine('Pay from', 'Naira wallet'),
          ],
          totalLabel: 'Total payable',
          total: Money.major(price.toDouble(), Currency.ngn),
          receiveLabel: 'Delivery',
          receive: 'Instant',
          issuedAt: now,
          expiresAt: now.add(quoteTtl),
          isMock: true,
        );
    }
    _quotes[q.id] = q;
    _quoteFields[q.id] = Map.of(f);
    return q;
  }

  // ------------------------------------------------------------- execution

  Future<TransactionReceipt> execute(Quote quote, AuthorizationProof proof, String key) async {
    // Idempotency: the same key always returns the original result.
    final cached = _idempotency[key];
    if (cached != null) return cached;

    await _tick();
    final stored = _quotes[quote.id];
    if (stored == null) throw const QuoteException('This quote is not recognised. Please request a new one.');
    if (proof.quoteId != quote.id) throw const QuoteException('Authorisation does not match this quote.');
    if (stored.isExpired()) throw const QuoteException('This quote has expired. Refresh it to get a new price.');
    if (_consumedQuotes.contains(quote.id)) {
      throw const QuoteException('This quote has already been used.');
    }

    final f = _quoteFields[quote.id]!;
    final now = DateTime.now();
    final ref = 'KN${_refSeq++}${now.millisecondsSinceEpoch % 10000}';
    final audit = [
      AuditEvent('Quote issued', stored.issuedAt),
      AuditEvent('Authorised with ${proof.method}', proof.at),
      AuditEvent('Ledger entries posted', now),
    ];

    late TransactionRecord rec;
    late String headline;
    late String detail;

    switch (quote.flow) {
      case TxFlow.buyCrypto:
        final asset = SupportedAssets.byTicker(f['asset']!)!;
        final qty = parseNairaAmount(f['amount']!)! / (priceUsd(asset.ticker) * usdNgnBuy);
        if (quote.total.minor > _nairaKobo) throw const QuoteException('Insufficient Naira balance.');
        _nairaKobo -= quote.total.minor;
        _holdings[asset.ticker] = (_holdings[asset.ticker] ?? 0) + qty;
        rec = _record(
          ref,
          TxCategory.crypto,
          'Bought ${asset.ticker}',
          'From Naira wallet',
          quote.total,
          false,
          TxStatus.completed,
          LedgerKind.crypto,
          audit,
          secondary: '+${Fmt.quantity(qty)} ${asset.ticker}',
        );
        headline = 'Purchase complete';
        detail = '${Fmt.quantity(qty)} ${asset.ticker} is now in your crypto balance.';
      case TxFlow.sellCrypto:
        final asset = SupportedAssets.byTicker(f['asset']!)!;
        final qty = parseNairaAmount(f['amount']!)! / (priceUsd(asset.ticker) * usdNgnSell);
        if (qty > (_holdings[asset.ticker] ?? 0)) throw const QuoteException('Insufficient crypto balance.');
        _holdings[asset.ticker] = (_holdings[asset.ticker] ?? 0) - qty;
        _nairaKobo += quote.total.minor;
        rec = _record(
          ref,
          TxCategory.crypto,
          'Sold ${asset.ticker}',
          'To Naira wallet',
          quote.total,
          true,
          TxStatus.completed,
          LedgerKind.naira,
          audit,
          secondary: '-${Fmt.quantity(qty)} ${asset.ticker}',
        );
        headline = 'Sale complete';
        detail = '${quote.total.format()} has been added to your Naira wallet.';
      case TxFlow.sellGiftCard:
        rec = _record(
          ref,
          TxCategory.giftCard,
          'Sold ${quote.title.replaceFirst('Sell ', '')}',
          'Awaiting partner verification',
          quote.total,
          true,
          TxStatus.inReview,
          LedgerKind.naira,
          audit,
        );
        headline = 'Card submitted';
        detail =
            'Our partner is verifying your card. ${quote.total.format()} will be paid into your Naira wallet once it clears. This usually takes 5 to 15 minutes.';
      case TxFlow.buyGiftCard:
        if (quote.total.minor > _nairaKobo) throw const QuoteException('Insufficient Naira balance.');
        _nairaKobo -= quote.total.minor;
        rec = _record(
          ref,
          TxCategory.giftCard,
          quote.title.replaceFirst('Buy ', ''),
          'E-code delivered',
          quote.total,
          false,
          TxStatus.completed,
          LedgerKind.naira,
          audit,
        );
        headline = 'Gift card ready';
        detail = 'Your e-code is in Activity. Mock code: KNCK-XXXX-XXXX-${ref.substring(ref.length - 4)}';
      case TxFlow.airtime || TxFlow.data || TxFlow.electricity || TxFlow.cable:
        if (quote.total.minor > _nairaKobo) throw const QuoteException('Insufficient Naira balance.');
        _nairaKobo -= quote.total.minor;
        rec = _record(
          ref,
          TxCategory.bills,
          quote.title,
          quote.lines[1].value,
          quote.total,
          false,
          TxStatus.completed,
          LedgerKind.naira,
          audit,
        );
        headline = 'Payment successful';
        detail = quote.flow == TxFlow.electricity
            ? 'Token: 4821 0937 5512 8820 6614 (mock)'
            : '${quote.title} delivered to ${quote.lines[1].value}.';
    }

    _consumedQuotes.add(quote.id);
    _ledgerEntries.add(rec);
    final receipt = TransactionReceipt(record: rec, headline: headline, detail: detail, flow: quote.flow);
    _idempotency[key] = receipt;
    return receipt;
  }

  TransactionRecord _record(
    String ref,
    TxCategory cat,
    String title,
    String subtitle,
    Money amount,
    bool credit,
    TxStatus status,
    LedgerKind ledger,
    List<AuditEvent> audit, {
    String? secondary,
  }) {
    final now = DateTime.now();
    return TransactionRecord(
      id: 'tx-$ref',
      reference: ref,
      category: cat,
      title: title,
      subtitle: subtitle,
      amount: amount,
      isCredit: credit,
      status: status,
      createdAt: now,
      ledger: ledger,
      audit: [
        ...audit,
        if (status == TxStatus.completed) AuditEvent('Settled', now),
        if (status == TxStatus.inReview) AuditEvent('Sent for verification', now),
      ],
      secondaryAmount: secondary,
    );
  }

  List<TransactionRecord> _seedActivity() {
    final now = DateTime.now();
    TransactionRecord seed(
      int hoursAgo,
      TxCategory c,
      String t,
      String s,
      double ngn,
      bool credit,
      TxStatus st, {
      String? sec,
      LedgerKind ledger = LedgerKind.naira,
    }) {
      final at = now.subtract(Duration(hours: hoursAgo));
      return TransactionRecord(
        id: 'seed-$hoursAgo',
        reference: 'KN30${hoursAgo.toString().padLeft(2, '0')}77',
        category: c,
        title: t,
        subtitle: s,
        amount: Money.major(ngn, Currency.ngn),
        isCredit: credit,
        status: st,
        createdAt: at,
        ledger: ledger,
        secondaryAmount: sec,
        audit: [
          AuditEvent('Quote issued', at.subtract(const Duration(seconds: 40))),
          AuditEvent('Authorised with biometrics', at.subtract(const Duration(seconds: 12))),
          AuditEvent('Ledger entries posted', at),
          if (st == TxStatus.completed) AuditEvent('Settled', at),
        ],
      );
    }

    return [
      seed(
        2,
        TxCategory.crypto,
        'Bought USDT',
        'From Naira wallet',
        50500,
        false,
        TxStatus.completed,
        sec: '+31.6 USDT',
        ledger: LedgerKind.crypto,
      ),
      seed(5, TxCategory.bills, 'MTN airtime', '0803 *** 4412', 2000, false, TxStatus.completed),
      seed(26, TxCategory.giftCard, 'Sold Apple gift card', '\$100 · US · Physical', 118000, true, TxStatus.completed),
      seed(30, TxCategory.wallet, 'Wallet deposit', 'Bank transfer · GTBank', 250000, true, TxStatus.completed),
      seed(52, TxCategory.bills, 'Ikeja Electric', 'Meter 4500 **** 211', 15100, false, TxStatus.completed),
      seed(75, TxCategory.crypto, 'Sold BTC', 'To Naira wallet', 304200, true, TxStatus.completed, sec: '-0.0021 BTC'),
      seed(98, TxCategory.giftCard, 'Sold Steam gift card', '\$50 · US · E-code', 57500, true, TxStatus.failed),
      seed(140, TxCategory.bills, 'DStv Compact', 'Smartcard 70** **** 18', 19000, false, TxStatus.completed),
    ];
  }
}
