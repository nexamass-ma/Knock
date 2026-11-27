import 'package:material_ui/material_ui.dart';

class GiftCardBrand {
  const GiftCardBrand(this.id, this.name, this.glyph, this.tint, {this.sellRateNgn = 0});
  final String id;
  final String name;
  final String glyph;
  final Color tint;

  /// Mock buying rate (₦ per $1) shown only as a guide; the real rate
  /// always comes from a backend quote.
  final double sellRateNgn;
}

abstract final class GiftCardCatalog {
  static const brands = [
    GiftCardBrand('apple', 'Apple', 'A', Color(0xFFE5E5EA), sellRateNgn: 1180),
    GiftCardBrand('amazon', 'Amazon', 'a', Color(0xFFFF9F1C), sellRateNgn: 1120),
    GiftCardBrand('steam', 'Steam', 'S', Color(0xFF66C0F4), sellRateNgn: 1150),
    GiftCardBrand('googleplay', 'Google Play', '▶', Color(0xFF34A853), sellRateNgn: 1010),
    GiftCardBrand('razer', 'Razer Gold', 'R', Color(0xFF44D62C), sellRateNgn: 1090),
    GiftCardBrand('sephora', 'Sephora', 'S', Color(0xFFE8E8E8), sellRateNgn: 980),
  ];

  static GiftCardBrand? byId(String id) {
    for (final b in brands) {
      if (b.id == id) return b;
    }
    return null;
  }

  static const denominations = [25, 50, 100, 200, 500];
}

abstract final class BillCatalog {
  static const networks = ['MTN', 'Airtel', 'Glo', '9mobile'];
  static const discos = ['Ikeja Electric', 'Eko Electric', 'Abuja Electric', 'Ibadan Electric'];
  static const cableProviders = ['DStv', 'GOtv', 'StarTimes'];

  /// Plan label -> price in naira (mock).
  static const dataPlans = {
    '1.5GB · 30 days': 1000,
    '4GB · 30 days': 2500,
    '10GB · 30 days': 5000,
    '25GB · 30 days': 10000,
  };

  static const cablePlans = {
    'DStv': {'Padi': 4400, 'Yanga': 6000, 'Confam': 11000, 'Compact': 19000},
    'GOtv': {'Smallie': 1900, 'Jinja': 3900, 'Jolli': 5800, 'Max': 8500},
    'StarTimes': {'Nova': 1900, 'Basic': 3700, 'Classic': 5500},
  };
}
