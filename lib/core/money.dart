/// Money is held in integer minor units (kobo, cents) to avoid floating
/// point drift. The client only formats values; every amount that matters
/// is calculated and validated by the backend.
enum Currency {
  ngn('NGN', '₦', 100),
  usd('USD', r'$', 100);

  const Currency(this.code, this.symbol, this.minorPerMajor);
  final String code;
  final String symbol;
  final int minorPerMajor;
}

class Money {
  const Money(this.minor, this.currency);

  factory Money.major(num value, Currency currency) => Money((value * currency.minorPerMajor).round(), currency);

  final int minor;
  final Currency currency;

  double get major => minor / currency.minorPerMajor;

  Money operator +(Money other) {
    assert(other.currency == currency, 'Cannot add different currencies');
    return Money(minor + other.minor, currency);
  }

  Money operator -(Money other) {
    assert(other.currency == currency, 'Cannot subtract different currencies');
    return Money(minor - other.minor, currency);
  }

  bool get isNegative => minor < 0;

  String format({bool showDecimals = true, bool compact = false}) =>
      Fmt.money(major, currency, showDecimals: showDecimals, compact: compact);

  @override
  bool operator ==(Object other) => other is Money && other.minor == minor && other.currency == currency;

  @override
  int get hashCode => Object.hash(minor, currency);

  @override
  String toString() => format();
}

abstract final class Fmt {
  static String grouped(double value, {int decimals = 2}) {
    final negative = value < 0;
    final fixed = value.abs().toStringAsFixed(decimals);
    final parts = fixed.split('.');
    final whole = parts[0];
    final buf = StringBuffer();
    for (var i = 0; i < whole.length; i++) {
      final fromEnd = whole.length - i;
      buf.write(whole[i]);
      if (fromEnd > 1 && fromEnd % 3 == 1) buf.write(',');
    }
    final result = parts.length > 1 ? '$buf.${parts[1]}' : buf.toString();
    return negative ? '-$result' : result;
  }

  static String money(double value, Currency currency, {bool showDecimals = true, bool compact = false}) {
    if (compact && value.abs() >= 1000000) {
      return '${currency.symbol}${(value / 1000000).toStringAsFixed(2)}M';
    }
    final sign = value < 0 ? '-' : '';
    return '$sign${currency.symbol}${grouped(value.abs(), decimals: showDecimals ? 2 : 0)}';
  }

  static String quantity(double value, {int maxDecimals = 6}) {
    if (value == 0) return '0';
    final decimals = value >= 1000
        ? 2
        : value >= 1
        ? 4
        : maxDecimals;
    var s = grouped(value, decimals: decimals);
    if (s.contains('.')) {
      s = s.replaceFirst(RegExp(r'0+$'), '');
      s = s.replaceFirst(RegExp(r'\.$'), '');
    }
    return s;
  }

  static String percent(double value) {
    final sign = value > 0 ? '+' : '';
    return '$sign${value.toStringAsFixed(2)}%';
  }

  static const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

  static String time(DateTime d) {
    final h = d.hour % 12 == 0 ? 12 : d.hour % 12;
    final m = d.minute.toString().padLeft(2, '0');
    return '$h:$m ${d.hour < 12 ? 'AM' : 'PM'}';
  }

  static String date(DateTime d) => '${d.day} ${_months[d.month - 1]} ${d.year}';

  static String dayLabel(DateTime d, {DateTime? now}) {
    final today = now ?? DateTime.now();
    final a = DateTime(d.year, d.month, d.day);
    final b = DateTime(today.year, today.month, today.day);
    final diff = b.difference(a).inDays;
    if (diff == 0) return 'Today';
    if (diff == 1) return 'Yesterday';
    return '${d.day} ${_months[d.month - 1]}';
  }

  static String greeting(DateTime now) {
    if (now.hour < 12) return 'Good morning';
    if (now.hour < 17) return 'Good afternoon';
    return 'Good evening';
  }
}

/// Parses amounts the way Nigerians type them: "100k", "₦100,000",
/// "1.5m", "N50000". Returns major units. The backend re-validates.
double? parseNairaAmount(String input) {
  final s = input.toLowerCase().replaceAll(RegExp(r'[₦,\s]|naira|ngn'), '');
  final m = RegExp(r'^n?(\d+(?:\.\d+)?)([km])?$').firstMatch(s);
  if (m == null) return null;
  var v = double.parse(m.group(1)!);
  if (m.group(2) == 'k') v *= 1000;
  if (m.group(2) == 'm') v *= 1000000;
  return v;
}

double? parseUsdAmount(String input) {
  final s = input.toLowerCase().replaceAll(RegExp(r'[\$,\s]|usd|dollars?'), '');
  final m = RegExp(r'^(\d+(?:\.\d+)?)$').firstMatch(s);
  return m == null ? null : double.parse(m.group(1)!);
}
