/// Product catalogue served by the sandbox backend. In production every list
/// here comes from the pricing engine, the provider aggregators and the
/// admin console, never from the app.
library;

class DisplayCurrency {
  const DisplayCurrency(this.code, this.symbol, this.name, this.ngnPerUnit);
  final String code;
  final String symbol;
  final String name;

  /// Sandbox mid-market rate used only to *display* balances in this
  /// currency. Settlement always happens in the ledger currency.
  final double ngnPerUnit;
}

const displayCurrencies = <DisplayCurrency>[
  DisplayCurrency('NGN', '₦', 'Nigerian naira', 1),
  DisplayCurrency('USD', r'$', 'US dollar', 1560),
  DisplayCurrency('GBP', '£', 'British pound', 1985),
  DisplayCurrency('EUR', '€', 'Euro', 1690),
  DisplayCurrency('CAD', r'CA$', 'Canadian dollar', 1130),
  DisplayCurrency('GHS', 'GH₵', 'Ghanaian cedi', 104),
  DisplayCurrency('KES', 'KSh', 'Kenyan shilling', 12.1),
];

DisplayCurrency currencyByCode(String code) =>
    displayCurrencies.firstWhere((c) => c.code == code, orElse: () => displayCurrencies.first);

class Country {
  const Country(this.code, this.name, this.dial, this.flag, this.currency);
  final String code;
  final String name;
  final String dial;
  final String flag;
  final String currency;
}

const countries = <Country>[
  Country('NG', 'Nigeria', '+234', '🇳🇬', 'NGN'),
  Country('GB', 'United Kingdom', '+44', '🇬🇧', 'GBP'),
  Country('US', 'United States', '+1', '🇺🇸', 'USD'),
  Country('CA', 'Canada', '+1', '🇨🇦', 'CAD'),
  Country('GH', 'Ghana', '+233', '🇬🇭', 'GHS'),
  Country('KE', 'Kenya', '+254', '🇰🇪', 'KES'),
  Country('IE', 'Ireland', '+353', '🇮🇪', 'EUR'),
  Country('DE', 'Germany', '+49', '🇩🇪', 'EUR'),
];

Country countryByCode(String code) => countries.firstWhere((c) => c.code == code, orElse: () => countries.first);

// ---------------------------------------------------------------------------
// Gift cards

class GiftBrand {
  const GiftBrand({
    required this.id,
    required this.name,
    required this.category,
    required this.glyph,
    required this.color,
    required this.rates,
    this.lockMinutes = 0,
    this.sendable = true,
    this.forwardable = false,
    this.minValue = 10,
    this.maxValue = 5000,
  });
  final String id;
  final String name;
  final String category;
  final String glyph;
  final int color;

  /// Base NGN paid per 1 unit of card currency, physical card, by currency.
  final Map<String, int> rates;

  /// Minutes a quoted rate is locked for. 0 means the rate is indicative.
  final int lockMinutes;
  final bool sendable;
  final bool forwardable;
  final int minValue;
  final int maxValue;
}

const giftCategories = ['Shopping', 'Gaming', 'Entertainment', 'Prepaid cards'];

const giftBrands = <GiftBrand>[
  GiftBrand(
    id: 'apple',
    name: 'Apple',
    category: 'Entertainment',
    glyph: 'A',
    color: 0xFFE8E8ED,
    rates: {'USD': 1500, 'GBP': 1780, 'CAD': 1010, 'AUD': 900, 'EUR': 1520},
    lockMinutes: 10,
  ),
  GiftBrand(
    id: 'amazon',
    name: 'Amazon',
    category: 'Shopping',
    glyph: 'a',
    color: 0xFFFF9900,
    rates: {'USD': 1420, 'GBP': 1700, 'EUR': 1450, 'CAD': 960},
    lockMinutes: 10,
    forwardable: true,
  ),
  GiftBrand(
    id: 'steam',
    name: 'Steam',
    category: 'Gaming',
    glyph: 'S',
    color: 0xFF66C0F4,
    rates: {'USD': 1460, 'GBP': 1720, 'EUR': 1480, 'CAD': 990},
    lockMinutes: 10,
  ),
  GiftBrand(
    id: 'google_play',
    name: 'Google Play',
    category: 'Entertainment',
    glyph: 'G',
    color: 0xFF34A853,
    rates: {'USD': 1180, 'GBP': 1420},
    forwardable: true,
  ),
  GiftBrand(
    id: 'razer',
    name: 'Razer Gold',
    category: 'Gaming',
    glyph: 'R',
    color: 0xFF44D62C,
    rates: {'USD': 1350},
  ),
  GiftBrand(
    id: 'sephora',
    name: 'Sephora',
    category: 'Shopping',
    glyph: 'S',
    color: 0xFFFFFFFF,
    rates: {'USD': 1240, 'CAD': 860},
  ),
  GiftBrand(
    id: 'nordstrom',
    name: 'Nordstrom',
    category: 'Shopping',
    glyph: 'N',
    color: 0xFFB0B0B8,
    rates: {'USD': 1220},
  ),
  GiftBrand(
    id: 'ebay',
    name: 'eBay',
    category: 'Shopping',
    glyph: 'e',
    color: 0xFFE53238,
    rates: {'USD': 1260, 'GBP': 1500},
  ),
  GiftBrand(
    id: 'xbox',
    name: 'Xbox',
    category: 'Gaming',
    glyph: 'X',
    color: 0xFF107C10,
    rates: {'USD': 1280, 'GBP': 1520},
  ),
  GiftBrand(
    id: 'playstation',
    name: 'PlayStation',
    category: 'Gaming',
    glyph: 'P',
    color: 0xFF2E6DB4,
    rates: {'USD': 1300, 'GBP': 1540},
  ),
  GiftBrand(
    id: 'vanilla',
    name: 'Vanilla Visa',
    category: 'Prepaid cards',
    glyph: 'V',
    color: 0xFFF2C14E,
    rates: {'USD': 1150},
    sendable: false,
  ),
  GiftBrand(
    id: 'amex',
    name: 'American Express',
    category: 'Prepaid cards',
    glyph: 'AX',
    color: 0xFF2E77BC,
    rates: {'USD': 1180},
    sendable: false,
  ),
];

GiftBrand brandById(String id) => giftBrands.firstWhere((b) => b.id == id);

/// e-code cards trade a little lower than physical cards.
const cardTypeFactor = {'physical': 1.0, 'ecode': 0.97};

/// Denominations offered when *buying* a gift card to send.
const sendDenominations = [10, 25, 50, 100, 200, 500];

const currencySymbols = {'USD': r'$', 'GBP': '£', 'EUR': '€', 'CAD': r'CA$', 'AUD': r'A$', 'NGN': '₦'};

// ---------------------------------------------------------------------------
// Crypto

class CryptoAsset {
  const CryptoAsset(this.symbol, this.name, this.usdPrice, this.decimals, this.color);
  final String symbol;
  final String name;
  final double usdPrice;
  final int decimals;
  final int color;
}

const cryptoAssets = <CryptoAsset>[
  CryptoAsset('BTC', 'Bitcoin', 96420, 8, 0xFFF7931A),
  CryptoAsset('ETH', 'Ethereum', 3380, 8, 0xFF8C8CF0),
  CryptoAsset('USDT', 'Tether', 1.0, 6, 0xFF26A17B),
  CryptoAsset('USDC', 'USD Coin', 1.0, 6, 0xFF2775CA),
  CryptoAsset('SOL', 'Solana', 182, 8, 0xFF14F195),
];

CryptoAsset cryptoBySymbol(String s) => cryptoAssets.firstWhere((a) => a.symbol == s);

/// NGN per USD for crypto trades (sandbox). Spread is the platform margin.
const cryptoBuyNgnPerUsd = 1585;
const cryptoSellNgnPerUsd = 1535;

// ---------------------------------------------------------------------------
// Bills, betting, e-pins, eSIM

class Biller {
  const Biller(this.id, this.name, this.kind, {this.plans = const [], this.color = 0xFF9B9BA7});
  final String id;
  final String name;

  /// airtime | data | electricity | cable | betting
  final String kind;
  final List<Plan> plans;
  final int color;
}

class Plan {
  const Plan(this.id, this.name, this.priceNgn, {this.detail = ''});
  final String id;
  final String name;
  final int priceNgn;
  final String detail;
}

const networks = <Biller>[
  Biller('mtn', 'MTN', 'airtime', color: 0xFFFFCC00),
  Biller('airtel', 'Airtel', 'airtime', color: 0xFFE40000),
  Biller('glo', 'Glo', 'airtime', color: 0xFF50B848),
  Biller('9mobile', '9mobile', 'airtime', color: 0xFF006B3F),
];

const dataPlans = <Plan>[
  Plan('d1', '1GB', 500, detail: '1 day'),
  Plan('d2', '2GB', 1200, detail: '7 days'),
  Plan('d3', '5GB', 2500, detail: '30 days'),
  Plan('d4', '10GB', 4500, detail: '30 days'),
  Plan('d5', '25GB', 9000, detail: '30 days'),
];

const discos = <Biller>[
  Biller('ikeja', 'Ikeja Electric', 'electricity'),
  Biller('eko', 'Eko Electricity', 'electricity'),
  Biller('abuja', 'Abuja Electricity', 'electricity'),
  Biller('ibadan', 'Ibadan Electricity', 'electricity'),
  Biller('enugu', 'Enugu Electricity', 'electricity'),
];

const cableProviders = <Biller>[
  Biller(
    'dstv',
    'DStv',
    'cable',
    plans: [
      Plan('padi', 'Padi', 4400),
      Plan('yanga', 'Yanga', 6000),
      Plan('confam', 'Confam', 11000),
      Plan('compact', 'Compact', 19000),
      Plan('premium', 'Premium', 44500),
    ],
  ),
  Biller(
    'gotv',
    'GOtv',
    'cable',
    plans: [Plan('smallie', 'Smallie', 1900), Plan('jolli', 'Jolli', 5800), Plan('supa', 'Supa', 9600)],
  ),
  Biller('startimes', 'StarTimes', 'cable', plans: [Plan('nova', 'Nova', 2100), Plan('basic', 'Basic', 4000)]),
];

const bettingProviders = <Biller>[
  Biller('sportybet', 'SportyBet', 'betting', color: 0xFFE41827),
  Biller('bet9ja', 'Bet9ja', 'betting', color: 0xFF0B8B3E),
  Biller('betking', 'BetKing', 'betting', color: 0xFF1C3D8F),
  Biller('1xbet', '1xBet', 'betting', color: 0xFF1A5DA8),
];

class EpinProduct {
  const EpinProduct(this.id, this.name, this.group, this.priceNgn, this.detail);
  final String id;
  final String name;
  final String group;
  final int priceNgn;
  final String detail;
}

const epinProducts = <EpinProduct>[
  EpinProduct('waec', 'WAEC result checker', 'Exams', 4500, 'One PIN, five checks'),
  EpinProduct('neco', 'NECO result token', 'Exams', 1500, 'Single use'),
  EpinProduct('jamb', 'JAMB UTME e-PIN', 'Exams', 7700, 'Registration PIN'),
  EpinProduct('mtn100', 'MTN recharge PIN ₦100', 'Recharge PINs', 100, 'Printable voucher'),
  EpinProduct('mtn500', 'MTN recharge PIN ₦500', 'Recharge PINs', 500, 'Printable voucher'),
  EpinProduct('airtel500', 'Airtel recharge PIN ₦500', 'Recharge PINs', 500, 'Printable voucher'),
  EpinProduct('glo1000', 'Glo recharge PIN ₦1,000', 'Recharge PINs', 1000, 'Printable voucher'),
];

class EsimPackage {
  const EsimPackage(this.id, this.region, this.flag, this.dataGb, this.days, this.usd);
  final String id;
  final String region;
  final String flag;

  /// 0 means unlimited.
  final int dataGb;
  final int days;
  final double usd;
}

const esimPackages = <EsimPackage>[
  EsimPackage('uk1', 'United Kingdom', '🇬🇧', 1, 7, 4.5),
  EsimPackage('uk5', 'United Kingdom', '🇬🇧', 5, 30, 13),
  EsimPackage('uk20', 'United Kingdom', '🇬🇧', 20, 30, 29),
  EsimPackage('us3', 'United States', '🇺🇸', 3, 15, 9),
  EsimPackage('us10', 'United States', '🇺🇸', 10, 30, 22),
  EsimPackage('eu5', 'Europe (39 countries)', '🇪🇺', 5, 30, 15),
  EsimPackage('eu10', 'Europe (39 countries)', '🇪🇺', 10, 30, 25),
  EsimPackage('ae3', 'United Arab Emirates', '🇦🇪', 3, 15, 12),
  EsimPackage('gh5', 'Ghana', '🇬🇭', 5, 30, 11),
  EsimPackage('ke5', 'Kenya', '🇰🇪', 5, 30, 10),
  EsimPackage('ca5', 'Canada', '🇨🇦', 5, 30, 16),
  EsimPackage('za3', 'South Africa', '🇿🇦', 3, 15, 9),
  EsimPackage('gl3', 'Global (120+ countries)', '🌍', 3, 30, 25),
];

const banks = [
  ('044', 'Access Bank'),
  ('058', 'GTBank'),
  ('057', 'Zenith Bank'),
  ('011', 'First Bank'),
  ('033', 'UBA'),
  ('090267', 'Kuda'),
  ('999992', 'OPay'),
  ('50515', 'Moniepoint'),
  ('035', 'Wema Bank'),
  ('232', 'Sterling Bank'),
  ('070', 'Fidelity Bank'),
  ('221', 'Stanbic IBTC'),
];

String bankName(String code) => banks.firstWhere((b) => b.$1 == code, orElse: () => (code, 'Bank')).$2;

// ---------------------------------------------------------------------------
// Tiers, VIP and rewards rules (server-side constants)

class TierRule {
  const TierRule(this.tier, this.name, this.dailyLimitNgn, this.singleLimitNgn, this.canWithdraw);
  final int tier;
  final String name;
  final int dailyLimitNgn;
  final int singleLimitNgn;
  final bool canWithdraw;
}

/// [Guess] Limits are placeholders until the compliance team sets them.
const tierRules = <TierRule>[
  TierRule(0, 'Unverified', 0, 0, false),
  TierRule(1, 'Basic', 500000, 250000, false),
  TierRule(2, 'Verified', 10000000, 5000000, true),
  TierRule(3, 'Advanced', 50000000, 20000000, true),
];

class VipLevel {
  const VipLevel(this.id, this.name, this.minUsd90d, this.rateBonusNgn, this.benefits);
  final String id;
  final String name;
  final int minUsd90d;
  final int rateBonusNgn;
  final List<String> benefits;
}

const vipLevels = <VipLevel>[
  VipLevel('silver', 'Silver', 0, 0, ['Standard rates', 'Help centre and ticket support', 'Member promotions']),
  VipLevel('gold', 'Gold', 2000, 5, [
    '+₦5 per \$1 on eligible gift card trades',
    'Priority support queue',
    'Exclusive promotions',
    'Higher Knockout rewards',
  ]),
  VipLevel('black', 'Black', 10000, 12, [
    '+₦12 per \$1 on eligible gift card trades',
    'Dedicated account manager',
    'Fastest support response',
    'Invitation-only campaigns',
  ]),
];

const welcomeBonusNgn = 100;
const referralRewardNgn = 5000;
const referralQualifyUsd = 500;
