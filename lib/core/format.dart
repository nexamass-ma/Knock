import '../sandbox/catalog.dart';
import 'money.dart';

/// Formatting for values the backend sends (kobo integers, ISO dates).
abstract final class F {
  static String ngn(num kobo, {bool decimals = false}) {
    final v = kobo / 100;
    final whole = decimals || v != v.roundToDouble();
    return '${v < 0 ? '-' : ''}₦${Fmt.grouped(v.abs(), decimals: whole && decimals ? 2 : 0)}';
  }

  static String ngnExact(num kobo) => '${kobo < 0 ? '-' : ''}₦${Fmt.grouped(kobo.abs() / 100, decimals: 2)}';

  /// Shows a NGN amount in the customer's display currency.
  static String display(num kobo, String currency) {
    if (currency == 'NGN') return ngnExact(kobo);
    final c = currencyByCode(currency);
    final v = kobo / 100 / c.ngnPerUnit;
    return '${v < 0 ? '-' : ''}${c.symbol}${Fmt.grouped(v.abs(), decimals: 2)}';
  }

  static String signed(num kobo, {required bool credit}) => '${credit ? '+' : '−'}${ngnExact(kobo.abs())}';

  static String face(String currency, num value) => '${currencySymbols[currency] ?? ''}${Fmt.grouped(value.toDouble(), decimals: 0)}';

  static String usdCents(num cents) => '\$${Fmt.grouped(cents / 100, decimals: cents % 100 == 0 ? 0 : 2)}';

  static String rate(num kobo, String currency) => '₦${Fmt.grouped(kobo / 100, decimals: kobo % 100 == 0 ? 0 : 2)}/${currencySymbols[currency] ?? currency}';

  static DateTime d(String iso) => DateTime.parse(iso);

  static String dateTime(String iso) {
    final x = d(iso);
    return '${Fmt.date(x)}, ${Fmt.time(x)}';
  }

  static String date(String iso) => Fmt.date(d(iso));

  static String ago(String iso, {DateTime? now}) {
    final diff = (now ?? DateTime.now()).difference(d(iso));
    if (diff.inSeconds < 45) return 'Just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes} min ago';
    if (diff.inHours < 24) return '${diff.inHours} h ago';
    if (diff.inDays < 7) return '${diff.inDays} d ago';
    return Fmt.date(d(iso));
  }

  static String countdown(int seconds) {
    if (seconds <= 0) return '0:00';
    final d = seconds ~/ 86400;
    final h = (seconds % 86400) ~/ 3600;
    final m = (seconds % 3600) ~/ 60;
    final s = seconds % 60;
    if (d > 0) return '${d}d ${h}h ${m}m';
    if (h > 0) return '${h}h ${m.toString().padLeft(2, '0')}m';
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  static String txnType(String type) => switch (type) {
        'giftcard_sell' => 'Gift card sale',
        'crypto_buy' => 'Crypto purchase',
        'crypto_sell' => 'Crypto sale',
        'crypto_deposit' => 'Crypto received',
        'deposit' => 'Deposit',
        'withdrawal' => 'Withdrawal',
        'airtime' => 'Airtime',
        'data' => 'Data',
        'electricity' => 'Electricity',
        'cable' => 'Cable TV',
        'betting' => 'Betting funding',
        'epin' => 'E-pin purchase',
        'esim' => 'eSIM purchase',
        'gift_send' => 'Gift sent',
        'reward' => 'Reward',
        'referral_payout' => 'Referral payout',
        _ => 'Transaction',
      };

  static String status(String s) => switch (s) {
        'successful' => 'Successful',
        'pending' => 'Pending',
        'failed' => 'Failed',
        'reversed' => 'Reversed',
        'cancelled' => 'Cancelled',
        _ => s,
      };
}
