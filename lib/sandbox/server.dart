import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

import 'catalog.dart';
import 'db.dart';
import 'util.dart';

part 'server_auth.dart';
part 'server_account.dart';
part 'server_wallet.dart';
part 'server_trade.dart';
part 'server_services.dart';
part 'server_gifts.dart';
part 'server_growth.dart';
part 'server_support.dart';
part 'server_ops.dart';
part 'seed.dart';

typedef Json = Map<String, dynamic>;

/// The Knock sandbox backend.
///
/// This class plays the part of Knock's servers inside the prototype. It owns
/// every authoritative rule: authentication, sessions, verification tiers,
/// the double-entry ledger, pricing and rate locks, trade review, rewards,
/// referrals and support. The app only ever talks to it through
/// [KnockApi](../api/api.dart), exactly as it would talk to HTTPS endpoints.
///
/// Nothing in here touches real money, real banks or real providers.
/// Provider calls (KYC, bills, gift card desks, settlement) are simulated and
/// labelled "sandbox" everywhere they appear.
class KnockServer {
  KnockServer({SandboxDb? db, DateTime Function()? clock, bool seed = true, this.random})
    : db = db ?? SandboxDb(),
      _clock = clock ?? DateTime.now {
    if (seed && this.db.table('meta').isEmpty) seedSandbox(this);
  }

  final SandboxDb db;
  final DateTime Function() _clock;
  final Random? random;

  /// Sandbox-only time travel used by tests and the sandbox console.
  Duration timeOffset = Duration.zero;

  DateTime get now => _clock().add(timeOffset);
  String get nowIso => now.toIso8601String();

  Random get _rng => random ?? _defaultRng;
  static final _defaultRng = Random();

  /// Demo key. Production keys live in a KMS and never ship in the app.
  final _vault = SecretBox('knock-sandbox-vault-key-not-for-production');
  static const _webhookSecret = 'knock-sandbox-webhook-secret';

  /// Request nonces seen recently (replay protection).
  final _seenNonces = <String, DateTime>{};
  final _rateBuckets = <String, List<DateTime>>{};

  // -------------------------------------------------------------------------
  // Sessions and authorisation

  Json _session(String? token) {
    if (token == null || token.isEmpty) throw ApiError('unauthenticated', 'Please log in to continue.');
    final s = db.get('sessions', sha256Hex(token));
    if (s == null || s['revoked'] == true) throw ApiError('unauthenticated', 'Your session has ended. Please log in again.');
    final last = DateTime.parse(s['lastSeenAt'] as String);
    final expires = DateTime.parse(s['expiresAt'] as String);
    if (now.isAfter(expires) || now.difference(last) > const Duration(minutes: 30)) {
      db.update('sessions', s['id'] as String, {'revoked': true, 'revokedReason': 'expired'});
      throw ApiError('session_expired', 'For your security you were logged out after a period of inactivity.');
    }
    s['lastSeenAt'] = nowIso;
    return s;
  }

  /// Resolves the signed-in user. Every customer endpoint goes through this,
  /// and every query is filtered by the returned user's id, so a customer can
  /// only ever read their own records.
  Json _user(String? token, {bool requireVerifiedEmail = true}) {
    final s = _session(token);
    final u = db.get('users', s['userId'] as String);
    if (u == null || u['status'] == 'closed') throw ApiError('unauthenticated', 'This account is no longer active.');
    if (requireVerifiedEmail && u['emailVerified'] != true) {
      throw ApiError('email_unverified', 'Please verify your email address first.');
    }
    u['lastActiveAt'] = nowIso;
    return u;
  }

  void _requireRole(String? token, String role) {
    final s = _session(token);
    final u = db.get('users', s['userId'] as String);
    if (u == null || u['role'] != role) {
      _audit(s['userId'] as String?, 'access.denied', role);
      throw ApiError('forbidden', 'You do not have permission to do that.');
    }
  }

  void _requireTier(Json u, int tier, String service) {
    if ((u['tier'] as int) < tier) {
      throw ApiError(
        'tier_required',
        tier == 1
            ? 'Verify your phone number to use $service.'
            : 'Complete Tier $tier verification to use $service.',
        details: {'tier': tier, 'service': service},
      );
    }
  }

  void _rateLimit(String key, int max, Duration window) {
    final list = _rateBuckets.putIfAbsent(key, () => []);
    list.removeWhere((t) => now.difference(t) > window);
    if (list.length >= max) {
      throw ApiError('rate_limited', 'Too many attempts. Please wait a few minutes and try again.');
    }
    list.add(now);
  }

  /// Rejects a mutating request whose nonce was already used, or whose
  /// timestamp is more than five minutes old (replay protection).
  void _checkReplay(String? nonce, String? sentAt) {
    if (nonce == null || sentAt == null) throw ApiError('bad_request', 'Request is missing its security headers.');
    final ts = DateTime.tryParse(sentAt);
    if (ts == null || now.difference(ts).abs() > const Duration(minutes: 5)) {
      throw ApiError('replay', 'This request has expired. Please try again.');
    }
    _seenNonces.removeWhere((_, t) => now.difference(t) > const Duration(minutes: 10));
    if (_seenNonces.containsKey(nonce)) throw ApiError('replay', 'This request was already received.');
    _seenNonces[nonce] = now;
  }

  // -------------------------------------------------------------------------
  // Ledger

  static String walletAcct(String uid) => 'u:$uid:ngn';
  static String bonusAcct(String uid) => 'u:$uid:bonus';
  static String cryptoAcct(String uid, String sym) => 'u:$uid:crypto:$sym';

  int balanceOf(String account) {
    var sum = 0;
    for (final e in db.table('entries').values) {
      if (e['account'] == account) sum += e['amount'] as int;
    }
    return sum;
  }

  /// Posts a balanced journal. [lines] maps account -> signed amount.
  /// Throws if the journal does not balance or a customer account would go
  /// negative. Always called inside [SandboxDb.transaction].
  void _post(String txnId, String currency, Map<String, int> lines, {String memo = ''}) {
    final total = lines.values.fold<int>(0, (a, b) => a + b);
    if (total != 0) throw StateError('Unbalanced journal for $txnId: $total');
    for (final l in lines.entries) {
      if (l.value == 0) continue;
      db.insert('entries', {
        'id': newId('ent'),
        'txnId': txnId,
        'account': l.key,
        'amount': l.value,
        'currency': currency,
        'memo': memo,
        'at': nowIso,
      });
      if (l.key.startsWith('u:') && balanceOf(l.key) < 0) {
        throw ApiError('insufficient_funds', 'You do not have enough funds for this.');
      }
    }
  }

  // -------------------------------------------------------------------------
  // Transactions, notifications, audit

  Json _newTxn(
    Json u, {
    required String type,
    required String title,
    required int amount,
    int fee = 0,
    String status = 'pending',
    String? idempotencyKey,
    Json details = const {},
    String? subtitle,
    List<Json>? timeline,
    String direction = 'debit',
  }) {
    if (idempotencyKey != null) {
      final existing = db.firstWhere(
        'txns',
        (t) => t['userId'] == u['id'] && t['idempotencyKey'] == idempotencyKey,
      );
      if (existing != null) throw _Replayed(existing);
    }
    final t = <String, dynamic>{
      'id': newId('txn'),
      'reference': newReference(),
      'userId': u['id'],
      'type': type,
      'title': title,
      'subtitle': subtitle,
      'amount': amount,
      'fee': fee,
      'currency': 'NGN',
      'direction': direction,
      'status': status,
      'details': details,
      'timeline': timeline ?? [_step(status == 'successful' ? 'Completed' : 'Submitted')],
      'idempotencyKey': idempotencyKey,
      'createdAt': nowIso,
      'updatedAt': nowIso,
    };
    db.insert('txns', t);
    return t;
  }

  Json _step(String label, {String? note}) => {'label': label, 'at': nowIso, 'note': ?note};

  void _setTxnStatus(Json t, String status, {String? step, String? note}) {
    t['status'] = status;
    t['updatedAt'] = nowIso;
    if (step != null) (t['timeline'] as List).add(_step(step, note: note));
    db.put('txns', t);
  }

  Json _notify(
    String userId,
    String kind,
    String title,
    String body, {
    Json? action,
    bool push = true,
  }) {
    final u = db.get('users', userId);
    final prefs = (u?['prefs'] as Map?) ?? {};
    final mandatory = kind == 'transaction' || kind == 'security' || kind == 'verification' || kind == 'gift';
    if (!mandatory && prefs[kind] == false) return {};
    final n = {
      'id': newId('ntf'),
      'userId': userId,
      'kind': kind,
      'title': title,
      'body': body,
      'action': action,
      'read': false,
      'createdAt': nowIso,
    };
    db.insert('notifications', n);
    if (push && prefs['push'] != false) {
      // Push notifications never contain secrets such as gift codes.
      _outbox(userId, 'push', u?['email'] as String? ?? '', title, body);
    }
    return n;
  }

  void _outbox(String? userId, String channel, String to, String subject, String body) {
    db.insert('outbox', {
      'id': newId('msg'),
      'userId': userId,
      'channel': channel,
      'to': to,
      'subject': subject,
      'body': body,
      'at': nowIso,
      'seq': db.table('outbox').length,
    });
  }

  void _audit(String? actor, String action, String target, [Json meta = const {}]) {
    db.insert('audit', {
      'id': newId('aud'),
      'at': nowIso,
      'actor': actor ?? 'anonymous',
      'action': action,
      'target': target,
      'meta': meta,
    });
  }

  Json _ok([Json data = const {}]) => {'ok': true, ...data};

  /// Runs a mutating endpoint atomically and returns a deep copy, so the
  /// client can never hold a reference to server state.
  Json _mutate(Json Function() body) {
    _sticky.clear();
    try {
      return deepCopy(db.transaction(body));
    } on _Replayed catch (r) {
      return deepCopy({'ok': true, 'replayed': true, 'txn': r.txn});
    } catch (_) {
      // Security counters (wrong PINs, wrong codes) must survive the rollback.
      for (final s in _sticky) {
        final row = db.get(s.$1, s.$2);
        if (row != null) db.update(s.$1, s.$2, s.$3);
      }
      _sticky.clear();
      rethrow;
    }
  }

  final _sticky = <(String, String, Json)>[];

  /// Records a write that must persist even if the surrounding request fails.
  void _keep(String table, String id, Json patch) => _sticky.add((table, id, patch));

  Json _read(Json Function() body) => deepCopy(body());

  // -------------------------------------------------------------------------
  // Pricing helpers used by several modules

  Json _rateRow(String brandId, String currency) {
    final id = '$brandId|$currency';
    final r = db.get('rates', id);
    if (r == null) throw ApiError('not_found', 'That card is not supported right now.');
    return r;
  }

  /// Effective NGN per card unit, in kobo per unit, including card type,
  /// active campaign boosts and VIP bonus.
  ({int rateKobo, int boostKobo, int vipKobo, Json? campaign}) _effectiveRate(
    Json? u,
    String brandId,
    String currency,
    String cardType,
    int faceValue,
  ) {
    final base = _rateRow(brandId, currency)['rate'] as int; // naira per unit
    final factor = cardTypeFactor[cardType] ?? 1.0;
    var rate = (base * factor * 100).round();
    Json? campaign;
    var boost = 0;
    for (final c in db.table('campaigns').values) {
      if (c['kind'] != 'rate_boost' || !_campaignLive(c)) continue;
      if (c['brandId'] == brandId && c['currency'] == currency && faceValue >= (c['minFace'] as int)) {
        boost = (c['boostNgn'] as int) * 100;
        campaign = c;
      }
    }
    var vip = 0;
    if (u != null && currency == 'USD') {
      final level = _vipLevel(u);
      vip = level.rateBonusNgn * 100;
    }
    rate += boost + vip;
    return (rateKobo: rate, boostKobo: boost, vipKobo: vip, campaign: campaign);
  }

  static int tradeFeeKobo(int payoutKobo) => (payoutKobo * 0.005).round().clamp(10000, 500000);

  int _usdCentsFor(String currency, int faceValue) {
    final ngn = currencyByCode(currency == 'AUD' ? 'CAD' : currency).ngnPerUnit;
    final usd = currencyByCode('USD').ngnPerUnit;
    return (faceValue * ngn / usd * 100).round();
  }

  bool _campaignLive(Json c) {
    final s = DateTime.parse(c['startsAt'] as String);
    final e = DateTime.parse(c['endsAt'] as String);
    return !now.isBefore(s) && now.isBefore(e);
  }

  // -------------------------------------------------------------------------
  // Background jobs (run by the API client every couple of seconds in the
  // sandbox; cron/queue workers in production)

  void tick() {
    db.transaction(() {
      _runSettlementJobs();
      _runKycJobs();
      _runGiftJobs();
      _runSupportJobs();
      _runRateFeed();
      _runRewardJobs();
      _runReminderJobs();
      return null;
    });
  }
}

class _Replayed implements Exception {
  _Replayed(this.txn);
  final Json txn;
}

String _hmac(String body) => Hmac(sha256, utf8.encode(KnockServer._webhookSecret)).convert(utf8.encode(body)).toString();
