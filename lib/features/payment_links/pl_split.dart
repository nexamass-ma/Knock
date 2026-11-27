import 'pl_models.dart';

/// Split maths, ported line for line from backend/src/split.ts and the SQL
/// function knock.split_amount. The app uses it for the live calculator and
/// the sandbox; the server recomputes everything when money moves.
abstract final class PlSplit {
  /// Largest-remainder apportionment: integer parts that add up to [total]
  /// exactly. Ties go to the earlier position.
  static List<int> splitAmount(int total, List<int> weights) {
    if (weights.isEmpty) return const [];
    if (total < 0) throw ArgumentError('total must not be negative');
    var wSum = 0;
    for (final w in weights) {
      if (w < 0) throw ArgumentError('negative weight');
      wSum += w;
    }
    if (wSum == 0) throw ArgumentError('weights sum to zero');
    final big = BigInt.from(total);
    final bw = BigInt.from(wSum);
    final parts = [for (final w in weights) (big * BigInt.from(w) ~/ bw).toInt()];
    final rems = [for (final w in weights) (big * BigInt.from(w) % bw).toInt()];
    var leftover = total - parts.fold<int>(0, (a, b) => a + b);
    while (leftover > 0) {
      var best = -1;
      for (var i = 0; i < weights.length; i++) {
        if (weights[i] > 0 && (best == -1 || rems[i] > rems[best])) best = i;
      }
      parts[best] += 1;
      rems[best] = -1;
      leftover--;
    }
    return parts;
  }

  /// [Guess] Knock fee schedule: NGN 1.5% capped at ₦2,000; crypto 1%.
  static int fee(PlAsset asset, int amount) {
    final bps = asset.isFiat ? 150 : 100;
    var v = (amount * bps + 5000) ~/ 10000;
    if (asset.isFiat && v > 200000) v = 200000;
    return v > amount ? amount : v;
  }

  /// Validates recipients the same way knock.build_recipients does.
  /// [input] entries are (user, amount for fixed split, basis points for percentage split).
  static List<RecipientRule> buildRules({
    required KnockUser creator,
    required SplitMethod method,
    required int? target,
    required bool remainderToCreator,
    required List<(KnockUser, int, int)> input,
  }) {
    if (input.isEmpty) throw PlException('invalid_recipients', 'Add at least one recipient.');
    final users = <KnockUser>[];
    for (final (u, _, _) in input) {
      if (users.any((x) => x.id == u.id)) throw PlException('invalid_recipients', '@${u.username} is listed twice.');
      if (!u.verified) throw PlException('recipient_unverified', '@${u.username} must verify their account first.');
      users.add(u);
    }
    var creatorIdx = -1;
    if (method == SplitMethod.fixed) {
      if (target == null || target <= 0) throw PlException('invalid_target', 'A fixed split needs a total amount.');
      final amts = [for (final (_, a, _) in input) a];
      if (amts.any((a) => a <= 0)) throw PlException('invalid_recipients', 'Each recipient needs an amount above zero.');
      final sum = amts.fold<int>(0, (a, b) => a + b);
      if (sum > target) throw PlException('allocation_mismatch', 'Allocations are more than the total.');
      if (sum < target) {
        if (!remainderToCreator) throw PlException('allocation_mismatch', 'Allocations must add up to the total.');
        creatorIdx = users.indexWhere((u) => u.id == creator.id);
        if (creatorIdx == -1) {
          users.add(creator);
          amts.add(target - sum);
          creatorIdx = users.length - 1;
        } else {
          amts[creatorIdx] += target - sum;
        }
      }
      final bps = splitAmount(10000, amts);
      return [
        for (var i = 0; i < users.length; i++)
          RecipientRule(user: users[i], allocated: amts[i], basisPoints: bps[i], isCreatorRemainder: i == creatorIdx),
      ];
    }
    final bps = [for (final (_, _, b) in input) b];
    if (bps.any((b) => b <= 0)) throw PlException('invalid_recipients', 'Each recipient needs a percentage above zero.');
    final sum = bps.fold<int>(0, (a, b) => a + b);
    if (sum > 10000) throw PlException('allocation_mismatch', 'Percentages add up to more than 100%.');
    if (sum < 10000) {
      if (!remainderToCreator) throw PlException('allocation_mismatch', 'Percentages must add up to 100%.');
      creatorIdx = users.indexWhere((u) => u.id == creator.id);
      if (creatorIdx == -1) {
        users.add(creator);
        bps.add(10000 - sum);
        creatorIdx = users.length - 1;
      } else {
        bps[creatorIdx] += 10000 - sum;
      }
    }
    final amts = target == null ? List.filled(users.length, 0) : splitAmount(target, bps);
    return [
      for (var i = 0; i < users.length; i++)
        RecipientRule(user: users[i], allocated: amts[i], basisPoints: bps[i], isCreatorRemainder: i == creatorIdx),
    ];
  }

  /// What each recipient gets from one payment. Mirrors knock.distribute_payment.
  static List<({KnockUser user, int gross, int fee, bool overflow})> previewPayment({
    required SplitMethod method,
    required List<RecipientRule> rules,
    required KnockUser creator,
    required int amount,
    required int knockFee,
    required FeeBearer feeBearer,
    Map<String, int> received = const {},
  }) {
    final feeDeduct = feeBearer == FeeBearer.deduct ? knockFee : 0;
    var users = [for (final r in rules) r.user];
    var overflow = List.filled(users.length, false);
    List<int> g;
    if (method == SplitMethod.fixed) {
      final rem = [for (final r in rules) (r.allocated - (received[r.user.id] ?? 0)).clamp(0, 1 << 62)];
      final remTotal = rem.fold<int>(0, (a, b) => a + b);
      if (remTotal == 0) {
        users = [creator];
        overflow = [true];
        g = [amount];
      } else if (amount <= remTotal) {
        g = splitAmount(amount, rem);
      } else {
        g = [...rem, amount - remTotal];
        users = [...users, creator];
        overflow = [...overflow, true];
      }
    } else {
      g = splitAmount(amount, [for (final r in rules) r.basisPoints]);
    }
    final f = feeDeduct > 0 ? splitAmount(feeDeduct, g) : List.filled(g.length, 0);
    return [
      for (var i = 0; i < users.length; i++)
        if (g[i] > 0) (user: users[i], gross: g[i], fee: f[i], overflow: overflow[i]),
    ];
  }
}

/// Formatting for minor units in any supported asset.
abstract final class PlFmt {
  static String money(int minor, PlAsset asset, {bool decimals = true}) {
    final neg = minor < 0;
    final abs = minor.abs();
    final base = _pow10(asset.decimals);
    final whole = _group((abs ~/ base).toString());
    if (asset.isFiat) {
      final frac = (abs % base).toString().padLeft(asset.decimals, '0');
      return '${neg ? '-' : ''}₦$whole${decimals ? '.$frac' : ''}';
    }
    var frac = (abs % base).toString().padLeft(asset.decimals, '0').replaceFirst(RegExp(r'0+$'), '');
    if (frac.length < 2) frac = frac.padRight(2, '0');
    return '${neg ? '-' : ''}$whole.$frac ${asset.code}';
  }

  static String percent(int bps) {
    final s = (bps / 100).toStringAsFixed(2).replaceFirst(RegExp(r'\.?0+$'), '');
    return '$s%';
  }

  /// "500000", "500,000.50", "500k" in major units -> minor units.
  static int? parse(String input, PlAsset asset) {
    final s = input.toLowerCase().replaceAll(RegExp(r'[₦,\s]'), '');
    final m = RegExp(r'^(\d+)(?:\.(\d+))?([km])?$').firstMatch(s);
    if (m == null) return null;
    final mult = switch (m.group(3)) {
      'k' => 1000,
      'm' => 1000000,
      _ => 1,
    };
    final fracStr = (m.group(2) ?? '');
    if (fracStr.length > asset.decimals) return null;
    final base = _pow10(asset.decimals);
    final whole = int.parse(m.group(1)!) * base;
    final frac = fracStr.isEmpty ? 0 : int.parse(fracStr.padRight(asset.decimals, '0'));
    return (whole + frac) * mult;
  }

  static String major(int minor, PlAsset asset) {
    final base = _pow10(asset.decimals);
    final frac = minor % base;
    if (frac == 0) return (minor ~/ base).toString();
    return '${minor ~/ base}.${frac.toString().padLeft(asset.decimals, '0').replaceFirst(RegExp(r'0+$'), '')}';
  }

  static int _pow10(int n) {
    var v = 1;
    for (var i = 0; i < n; i++) {
      v *= 10;
    }
    return v;
  }

  static String _group(String digits) {
    final b = StringBuffer();
    for (var i = 0; i < digits.length; i++) {
      final fromEnd = digits.length - i;
      b.write(digits[i]);
      if (fromEnd > 1 && fromEnd % 3 == 1) b.write(',');
    }
    return b.toString();
  }

  static const _m = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  static String date(DateTime d) => '${d.day} ${_m[d.month - 1]} ${d.year}';
  static String dateTime(DateTime d) {
    final h = d.hour % 12 == 0 ? 12 : d.hour % 12;
    return '${d.day} ${_m[d.month - 1]}, $h:${d.minute.toString().padLeft(2, '0')} ${d.hour < 12 ? 'AM' : 'PM'}';
  }

  /// Privacy: show payers as "Ada O." and "a***@gmail.com".
  static String maskName(String? name) {
    if (name == null || name.trim().isEmpty) return 'Anonymous payer';
    final parts = name.trim().split(RegExp(r'\s+'));
    return parts.length == 1 ? parts.first : '${parts.first} ${parts.last[0]}.';
  }

  static String maskEmail(String? email) {
    if (email == null || !email.contains('@')) return '';
    final i = email.indexOf('@');
    return '${email[0]}***${email.substring(i)}';
  }
}
