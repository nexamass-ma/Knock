import 'package:material_ui/material_ui.dart';

import '../core/money.dart';

/// Where a value came from. Every screen that shows financial data shows
/// a "Mock" label while [DataSource.mock] is in use.
enum DataSource { mock, live }

class CryptoAsset {
  const CryptoAsset({
    required this.ticker,
    required this.name,
    required this.glyph,
    required this.tint,
    required this.network,
  });

  final String ticker;
  final String name;
  final String glyph;
  final Color tint;
  final String network;

  @override
  bool operator ==(Object other) => other is CryptoAsset && other.ticker == ticker;

  @override
  int get hashCode => ticker.hashCode;
}

abstract final class SupportedAssets {
  static const btc = CryptoAsset(
    ticker: 'BTC',
    name: 'Bitcoin',
    glyph: '₿',
    tint: Color(0xFFF2A33A),
    network: 'Bitcoin',
  );
  static const eth = CryptoAsset(
    ticker: 'ETH',
    name: 'Ethereum',
    glyph: 'Ξ',
    tint: Color(0xFF8C9EFF),
    network: 'Ethereum',
  );
  static const usdt = CryptoAsset(
    ticker: 'USDT',
    name: 'Tether',
    glyph: '₮',
    tint: Color(0xFF3DBE9A),
    network: 'TRON (TRC-20)',
  );
  static const sol = CryptoAsset(ticker: 'SOL', name: 'Solana', glyph: '◎', tint: Color(0xFFB38CFF), network: 'Solana');
  static const usdc = CryptoAsset(
    ticker: 'USDC',
    name: 'USD Coin',
    glyph: r'$',
    tint: Color(0xFF5B9BFF),
    network: 'Ethereum',
  );

  static const all = [btc, eth, usdt, sol, usdc];

  static CryptoAsset? byTicker(String t) {
    for (final a in all) {
      if (a.ticker == t.toUpperCase()) return a;
    }
    return null;
  }
}

class Holding {
  const Holding({
    required this.asset,
    required this.quantity,
    required this.priceNgn,
    required this.priceUsd,
    required this.change24h,
    required this.sparkline,
  });

  final CryptoAsset asset;

  /// Display-only quantity sent by the backend.
  final double quantity;
  final double priceNgn;
  final double priceUsd;
  final double change24h;
  final List<double> sparkline;

  Money get valueNgn => Money.major(quantity * priceNgn, Currency.ngn);
  Money get valueUsd => Money.major(quantity * priceUsd, Currency.usd);
}

enum ChartRange {
  day('1D'),
  week('1W'),
  month('1M'),
  year('1Y');

  const ChartRange(this.label);
  final String label;
}

class PortfolioSummary {
  const PortfolioSummary({
    required this.totalNgn,
    required this.totalUsd,
    required this.changePercent,
    required this.history,
    required this.range,
    required this.source,
    required this.asOf,
  });

  final Money totalNgn;
  final Money totalUsd;
  final double changePercent;
  final List<double> history;
  final ChartRange range;
  final DataSource source;
  final DateTime asOf;
}
