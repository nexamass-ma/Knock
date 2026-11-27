import 'package:flutter_test/flutter_test.dart';
import 'package:knock/sandbox/server.dart';
import 'package:knock/sandbox/util.dart';

/// Backend acceptance tests. They drive the sandbox server exactly the way
/// the app does, with a controllable clock.
class Harness {
  Harness() {
    server = KnockServer(clock: () => t);
  }
  DateTime t = DateTime(2026, 11, 27, 10);
  late final KnockServer server;
  int _n = 0;

  void advance(Duration d) {
    // Tick every second so background jobs see each stage.
    final end = t.add(d);
    while (t.isBefore(end)) {
      t = t.add(const Duration(seconds: 1));
      server.tick();
    }
  }

  String code(String token) {
    final inbox = server.sandboxInbox(token)['items'] as List;
    final body = (inbox.first as Map)['body'] as String;
    return RegExp(r'\d{6}').firstMatch(body)!.group(0)!;
  }

  ({String nonce, String sentAt, String key}) sec() {
    _n++;
    return (nonce: 'n$_n-${t.microsecondsSinceEpoch}', sentAt: t.toIso8601String(), key: 'idem-$_n');
  }

  /// Registers and fully onboards a customer to Tier 1 with a PIN.
  String onboard({String name = 'Chanor Test', String? email, String device = 'dev-1', String? referral, String phone = '8031234567'}) {
    final r = server.register(
      fullName: name,
      email: email ?? '${name.split(' ').first.toLowerCase()}${t.microsecond}${_n++}@example.com',
      password: 'Secret123!',
      acceptedTerms: true,
      deviceId: device,
      referralCode: referral,
    );
    final token = r['token'] as String;
    server.verifyEmail(token, code(token));
    server.startPhoneVerification(token, 'NG', phone);
    server.verifyPhone(token, code(token));
    server.personalise(token, country: 'NG', currency: 'NGN');
    server.setPin(token, '2580');
    return token;
  }

  void tier2(String token, {String bvn = '22212345678', String nin = '12345678901'}) {
    server.submitTier2(token, bankCode: '058', accountNumber: '0123456789', bvn: bvn, nin: nin);
    advance(const Duration(seconds: 6));
  }

  /// Sells a gift card through to completion; returns the txn.
  Map<String, dynamic> sellCard(String token, {String brand = 'google_play', int face = 100}) {
    final q = server.quoteGiftCard(token, brandId: brand, currency: 'USD', cardType: 'physical', faceValue: face)['quote'] as Map;
    final s = sec();
    final t = server.submitGiftCardTrade(token, quoteId: q['id'] as String, attachments: ['front.jpg'], idempotencyKey: s.key, nonce: s.nonce, sentAt: s.sentAt)['txn'] as Map<String, dynamic>;
    advance(const Duration(seconds: 25));
    return server.transaction(token, t['id'] as String)['txn'] as Map<String, dynamic>;
  }

  String get ops => _ops ??= server.sandboxOpsToken();
  String? _ops;
}

void main() {
  group('Registration, login, recovery', () {
    test('sign up, verify email and phone, personalise reaches Tier 1', () {
      final h = Harness();
      final token = h.onboard();
      final me = h.server.me(token)['user'] as Map;
      expect(me['tier'], 1);
      expect(me['emailVerified'], true);
      expect(me['phoneVerified'], true);
      expect(me['onboarding'], 'done');
      expect(h.server.wallet(token)['available'], 0, reason: 'new accounts start empty');
      expect((h.server.transactions(token)['items'] as List), isEmpty);
    });

    test('validation errors', () {
      final h = Harness();
      expect(() => h.server.register(fullName: 'Ada', email: 'a@b.co', password: 'Secret123', acceptedTerms: true, deviceId: 'd'), throwsA(isA<ApiError>()));
      expect(() => h.server.register(fullName: 'Ada Obi', email: 'nope', password: 'Secret123', acceptedTerms: true, deviceId: 'd'), throwsA(isA<ApiError>()));
      expect(() => h.server.register(fullName: 'Ada Obi', email: 'a@b.co', password: 'short', acceptedTerms: true, deviceId: 'd'), throwsA(isA<ApiError>()));
      expect(() => h.server.register(fullName: 'Ada Obi', email: 'a@b.co', password: 'Secret123', acceptedTerms: false, deviceId: 'd'), throwsA(isA<ApiError>()));
    });

    test('wrong email code is counted and the right one works', () {
      final h = Harness();
      final r = h.server.register(fullName: 'Ada Obi', email: 'ada@x.com', password: 'Secret123', acceptedTerms: true, deviceId: 'd');
      final token = r['token'] as String;
      expect(() => h.server.verifyEmail(token, '000000'), throwsA(isA<ApiError>()));
      h.server.verifyEmail(token, h.code(token));
      expect((h.server.me(token)['user'] as Map)['emailVerified'], true);
    });

    test('login, lockout after 5 failures, and password reset', () {
      final h = Harness();
      final token = h.onboard(name: 'Ada Obi', email: 'ada@x.com');
      h.server.logout(token);
      expect(() => h.server.me(token), throwsA(isA<ApiError>()));
      final ok = h.server.login(email: 'ada@x.com', password: 'Secret123!', deviceId: 'dev-1');
      expect(ok['token'], isNotNull);
      for (var i = 0; i < 5; i++) {
        expect(() => h.server.login(email: 'ada@x.com', password: 'wrong', deviceId: 'dev-1'), throwsA(isA<ApiError>()));
      }
      expect(
        () => h.server.login(email: 'ada@x.com', password: 'Secret123!', deviceId: 'dev-1'),
        throwsA(predicate((e) => e is ApiError && e.code == 'locked')),
      );
      h.server.forgotPassword('ada@x.com');
      final mail = (h.server.sandboxInboxFor('ada@x.com')['items'] as List).first as Map;
      final code = RegExp(r'\d{6}').firstMatch(mail['body'] as String)!.group(0)!;
      h.server.resetPassword(email: 'ada@x.com', code: code, newPassword: 'NewSecret456');
      expect(() => h.server.me(ok['token'] as String), throwsA(isA<ApiError>()), reason: 'reset signs out every device');
      final again = h.server.login(email: 'ada@x.com', password: 'NewSecret456', deviceId: 'dev-1');
      expect(again['token'], isNotNull);
    });

    test('sessions expire after 30 minutes idle', () {
      final h = Harness();
      final token = h.onboard();
      h.t = h.t.add(const Duration(minutes: 31));
      expect(() => h.server.me(token), throwsA(predicate((e) => e is ApiError && e.code == 'session_expired')));
    });
  });

  group('Gift card live rate change', () {
    test('locked rate is honoured, indicative rate change needs consent; accept is recorded', () {
      final h = Harness();
      final token = h.onboard();
      h.tier2(token);
      // Google Play is indicative.
      final q = h.server.quoteGiftCard(token, brandId: 'google_play', currency: 'USD', cardType: 'physical', faceValue: 100)['quote'] as Map;
      expect(q['mode'], 'indicative');
      expect(h.server.checkQuote(token, q['id'] as String)['changed'], false);

      h.server.opsMoveRate(h.ops, 'google_play', 'USD', 20);
      final cmp = h.server.checkQuote(token, q['id'] as String);
      expect(cmp['changed'], true);
      expect(cmp['direction'], 'up');
      expect(cmp['newNetKobo'] as int, greaterThan(cmp['oldNetKobo'] as int));

      // Submitting without consent is refused by the server.
      final s = h.sec();
      expect(
        () => h.server.submitGiftCardTrade(token, quoteId: q['id'] as String, attachments: ['a.jpg'], idempotencyKey: s.key, nonce: s.nonce, sentAt: s.sentAt),
        throwsA(predicate((e) => e is ApiError && e.code == 'rate_changed')),
      );
      final accepted = h.server.acceptNewRate(token, q['id'] as String, cmp['newRateKobo'] as int)['quote'] as Map;
      expect((accepted['acceptances'] as List).length, 1);
      expect(accepted['rateKobo'], cmp['newRateKobo']);
      final s2 = h.sec();
      final t = h.server.submitGiftCardTrade(token, quoteId: q['id'] as String, attachments: ['a.jpg'], idempotencyKey: s2.key, nonce: s2.nonce, sentAt: s2.sentAt)['txn'] as Map;
      expect(((t['details'] as Map)['acceptances'] as List).length, 1);
      h.advance(const Duration(seconds: 25));
      final done = h.server.transaction(token, t['id'] as String)['txn'] as Map;
      expect(done['status'], 'successful');
      expect(h.server.wallet(token)['available'], done['amount']);
    });

    test('Apple rate is locked and not changed while the lock is valid', () {
      final h = Harness();
      final token = h.onboard();
      final q = h.server.quoteGiftCard(token, brandId: 'apple', currency: 'USD', cardType: 'physical', faceValue: 100)['quote'] as Map;
      expect(q['mode'], 'locked');
      h.server.opsMoveRate(h.ops, 'apple', 'USD', -30);
      expect(h.server.checkQuote(token, q['id'] as String)['changed'], false);
      h.t = h.t.add(const Duration(minutes: 11));
      // Keep the session alive (idle limit is 30 min) and see the lock expire.
      final c = h.server.checkQuote(token, q['id'] as String);
      expect(c['changed'], true);
      expect(c['reason'], 'lock_expired');
    });

    test('rate decrease then cancel: nothing submitted, history shows cancelled', () {
      final h = Harness();
      final token = h.onboard();
      final q = h.server.quoteGiftCard(token, brandId: 'google_play', currency: 'USD', cardType: 'physical', faceValue: 100)['quote'] as Map;
      h.server.opsMoveRate(h.ops, 'google_play', 'USD', -20);
      expect(h.server.checkQuote(token, q['id'] as String)['direction'], 'down');
      h.server.cancelQuote(token, q['id'] as String, reason: 'rate_change_declined');
      final items = h.server.transactions(token)['items'] as List;
      expect(items.length, 1);
      expect((items.first as Map)['status'], 'cancelled');
      expect(h.server.wallet(token)['available'], 0);
      final s = h.sec();
      expect(
        () => h.server.submitGiftCardTrade(token, quoteId: q['id'] as String, attachments: ['a.jpg'], idempotencyKey: s.key, nonce: s.nonce, sentAt: s.sentAt),
        throwsA(isA<ApiError>()),
      );
    });

    test('spec example: \$4,999 at ₦1,500 is ₦7,498,500 before fees', () {
      final h = Harness();
      final token = h.onboard();
      h.tier2(token);
      // Campaign boost applies to Apple USD; measure the base by e-code-free physical without boost.
      final q = h.server.quoteGiftCard(token, brandId: 'apple', currency: 'USD', cardType: 'physical', faceValue: 4999)['quote'] as Map;
      final boost = q['boostKobo'] as int;
      expect((q['rateKobo'] as int) - boost, 150000);
      expect(4999 * ((q['rateKobo'] as int) - boost), 749850000);
    });
  });

  group('Rewards and referrals', () {
    test('welcome bonus after first settled trade, once, reversed with the trade', () {
      final h = Harness();
      final token = h.onboard();
      expect(h.server.welcomeBonus(token)['status'], 'eligible');
      final t = h.sellCard(token);
      expect(t['status'], 'successful');
      final w = h.server.welcomeBonus(token);
      expect(w['status'], 'credited');
      expect(w['reference'], isNotNull);
      expect(h.server.wallet(token)['bonus'], 10000);
      h.sellCard(token);
      expect(h.server.wallet(token)['bonus'], 10000, reason: 'one bonus per account');
      h.server.opsReverse(h.ops, t['id'] as String);
      expect(h.server.welcomeBonus(token)['status'], 'reversed');
      expect(h.server.wallet(token)['bonus'], 0);
    });

    test('failed trades do not earn the bonus', () {
      final h = Harness();
      final token = h.onboard();
      final q = h.server.quoteGiftCard(token, brandId: 'google_play', currency: 'USD', cardType: 'physical', faceValue: 100)['quote'] as Map;
      final s = h.sec();
      final t = h.server.submitGiftCardTrade(token, quoteId: q['id'] as String, attachments: ['a.jpg'], idempotencyKey: s.key, nonce: s.nonce, sentAt: s.sentAt)['txn'] as Map;
      h.server.opsTrade(h.ops, t['id'] as String, 'fail');
      h.advance(const Duration(seconds: 25));
      expect(h.server.welcomeBonus(token)['status'], 'eligible');
    });

    test('referral qualifies only above \$500 settled volume, then pays ₦5,000', () {
      final h = Harness();
      final referrer = h.onboard(name: 'Ref Errer', device: 'dev-A', phone: '8030000001');
      final code = (h.server.me(referrer)['user'] as Map)['referralCode'] as String;
      final friend = h.onboard(name: 'New Friend', device: 'dev-B', referral: code, phone: '8030000002');
      h.tier2(friend, bvn: '22233344455', nin: '11122233344');
      var r = h.server.referrals(referrer);
      expect((r['stats'] as Map)['registered'], 1);
      h.sellCard(friend, face: 300);
      r = h.server.referrals(referrer);
      expect((r['stats'] as Map)['qualified'], 0, reason: '\$300 is below \$500');
      h.sellCard(friend, face: 250);
      r = h.server.referrals(referrer);
      expect((r['stats'] as Map)['qualified'], 1);
      expect((r['stats'] as Map)['pendingRewards'], 500000);
      h.advance(const Duration(minutes: 1, seconds: 5));
      r = h.server.referrals(referrer);
      expect((r['stats'] as Map)['availableRewards'], 500000);
      expect(h.server.wallet(referrer)['available'], 500000);
      final item = (r['items'] as List).first as Map;
      expect(item['email'], contains('*'), reason: 'referred email is masked');
    });

    test('self-referral on the same device is rejected', () {
      final h = Harness();
      final referrer = h.onboard(name: 'Ref Errer', device: 'same', phone: '8030000001');
      final code = (h.server.me(referrer)['user'] as Map)['referralCode'] as String;
      h.onboard(name: 'Alt Account', device: 'same', referral: code, phone: '8030000002');
      final r = h.server.referrals(referrer);
      expect((r['items'] as List).first['status'], 'rejected');
    });

    test('Knockout first-trade challenge can be claimed once', () {
      final h = Harness();
      final token = h.onboard();
      h.sellCard(token);
      h.server.claimChallenge(token, 'first_trade');
      expect(() => h.server.claimChallenge(token, 'first_trade'), throwsA(isA<ApiError>()));
      expect(h.server.knockout(token)['points'], 25);
    });
  });

  group('Money movement and security', () {
    test('withdrawal needs Tier 2, the right PIN, and is idempotent', () {
      final h = Harness();
      final token = h.onboard();
      final s = h.sec();
      h.server.simulateDeposit(token, 5000000);
      h.advance(const Duration(seconds: 5));
      expect(h.server.wallet(token)['available'], 5000000);
      expect(
        () => h.server.withdraw(token, amountKobo: 1000000, pin: '2580', idempotencyKey: s.key, nonce: s.nonce, sentAt: s.sentAt),
        throwsA(predicate((e) => e is ApiError && e.code == 'tier_required')),
      );
      h.tier2(token);
      final s2 = h.sec();
      expect(
        () => h.server.withdraw(token, amountKobo: 1000000, pin: '1111', idempotencyKey: s2.key, nonce: s2.nonce, sentAt: s2.sentAt),
        throwsA(predicate((e) => e is ApiError && e.code == 'bad_pin')),
      );
      final s3 = h.sec();
      h.server.withdraw(token, amountKobo: 1000000, pin: '2580', idempotencyKey: 'same-key', nonce: s3.nonce, sentAt: s3.sentAt);
      final s4 = h.sec();
      final again = h.server.withdraw(token, amountKobo: 1000000, pin: '2580', idempotencyKey: 'same-key', nonce: s4.nonce, sentAt: s4.sentAt);
      expect(again['replayed'], true);
      expect(h.server.wallet(token)['available'], 5000000 - 1000000 - 5000);
    });

    test('replayed nonces are rejected', () {
      final h = Harness();
      final token = h.onboard();
      h.tier2(token);
      final s = h.sec();
      h.server.simulateDeposit(token, 5000000);
      h.advance(const Duration(seconds: 5));
      h.server.withdraw(token, amountKobo: 100000, pin: '2580', idempotencyKey: 'a', nonce: s.nonce, sentAt: s.sentAt);
      expect(
        () => h.server.withdraw(token, amountKobo: 100000, pin: '2580', idempotencyKey: 'b', nonce: s.nonce, sentAt: s.sentAt),
        throwsA(predicate((e) => e is ApiError && e.code == 'replay')),
      );
    });

    test('customers only see their own data; ops endpoints need the ops role', () {
      final h = Harness();
      final a = h.onboard(name: 'Alice One', phone: '8030000001', device: 'a');
      final b = h.onboard(name: 'Bob Two', phone: '8030000002', device: 'b');
      final t = h.sellCard(a);
      expect(() => h.server.transaction(b, t['id'] as String), throwsA(predicate((e) => e is ApiError && e.code == 'not_found')));
      expect(() => h.server.opsMoveRate(b, 'apple', 'USD', 10), throwsA(predicate((e) => e is ApiError && e.code == 'forbidden')));
    });

    test('ledger reconciles after a mix of activity', () {
      final h = Harness();
      final token = h.onboard();
      h.tier2(token);
      h.server.simulateDeposit(token, 2000000);
      h.advance(const Duration(seconds: 5));
      h.sellCard(token);
      final s = h.sec();
      h.server.purchaseService(token, kind: 'airtime', billerId: 'mtn', amountKobo: 50000, customer: '08031234567', pin: '2580', idempotencyKey: s.key, nonce: s.nonce, sentAt: s.sentAt);
      final rec = h.server.reconcile(h.ops);
      expect(rec['ok'], true, reason: rec.toString());
    });

    test('webhooks with a bad signature are rejected', () {
      final h = Harness();
      expect(() => h.server.providerWebhook('{"id":"x"}', 'bad'), throwsA(predicate((e) => e is ApiError && e.code == 'bad_signature')));
    });

    test('BVN and NIN are never stored in full', () {
      final h = Harness();
      final token = h.onboard();
      h.tier2(token);
      final raw = h.server.db.encode();
      expect(raw.contains('22212345678'), false);
      expect(raw.contains('12345678901'), false);
      expect((h.server.me(token)['user'] as Map)['tier'], 2);
    });
  });

  group('Gift Send', () {
    test('send to a Knock user, deliver, open, reveal after PIN, redeem', () {
      final h = Harness();
      final sender = h.onboard(name: 'Uncle Sam', phone: '8030000001', device: 'a');
      final recipient = h.onboard(name: 'Nephew Ade', phone: '8030000002', device: 'b');
      final username = (h.server.me(recipient)['user'] as Map)['username'] as String;
      h.server.simulateDeposit(sender, 50000000);
      h.advance(const Duration(seconds: 5));
      final s = h.sec();
      final res = h.server.sendGift(sender, brandId: 'apple', currency: 'USD', value: 100, recipientType: 'username', recipient: username, message: 'Enjoy!', pin: '2580', idempotencyKey: s.key, nonce: s.nonce, sentAt: s.sentAt);
      expect((res['gift'] as Map)['status'], 'payment_pending');
      h.advance(const Duration(seconds: 8));
      final gifts = h.server.myGifts(recipient)['items'] as List;
      expect(gifts.length, 1);
      final g = gifts.first as Map;
      expect(g['status'], 'delivered');
      final n = (h.server.notifications(recipient)['items'] as List).firstWhere((n) => n['kind'] == 'gift') as Map;
      expect(n['title'], contains('received a gift'));
      expect(n['body'], isNot(contains('-')), reason: 'no code in notifications');
      h.server.openGift(recipient, g['id'] as String);
      expect(() => h.server.revealGiftCode(recipient, g['id'] as String, '0000'), throwsA(isA<ApiError>()));
      final code = h.server.revealGiftCode(recipient, g['id'] as String, '2580')['code'] as String;
      expect(code, isNotEmpty);
      expect(h.server.db.encode().contains(code), false, reason: 'codes are encrypted at rest');
      h.server.markGiftRedeemed(recipient, g['id'] as String);
      expect(() => h.server.markGiftRedeemed(recipient, g['id'] as String), throwsA(isA<ApiError>()));
      final senderView = (h.server.myGifts(sender)['items'] as List).first as Map;
      expect(senderView['status'], 'redeemed');
    });

    test('gift link for a non-user can be claimed once', () {
      final h = Harness();
      final sender = h.onboard(name: 'Uncle Sam', phone: '8030000001', device: 'a');
      h.server.simulateDeposit(sender, 50000000);
      h.advance(const Duration(seconds: 5));
      final s = h.sec();
      final res = h.server.sendGift(sender, brandId: 'amazon', currency: 'USD', value: 50, recipientType: 'link', pin: '2580', idempotencyKey: s.key, nonce: s.nonce, sentAt: s.sentAt);
      final link = res['claimLink'] as String;
      h.advance(const Duration(seconds: 8));
      final newbie = h.onboard(name: 'New Person', phone: '8030000009', device: 'z');
      h.server.claimGift(newbie, link);
      expect((h.server.myGifts(newbie)['items'] as List).length, 1);
      final other = h.onboard(name: 'Other Person', phone: '8030000008', device: 'y');
      expect(() => h.server.claimGift(other, link), throwsA(isA<ApiError>()));
    });
  });

  group('Support and account deletion', () {
    test('dispute from a transaction is prefilled and tracked', () {
      final h = Harness();
      final token = h.onboard();
      final t = h.sellCard(token);
      final tk = h.server.createTicket(token, category: 'Payout issue', subject: '', description: 'My payout looks wrong to me.', txnId: t['id'] as String, dispute: true)['ticket'] as Map;
      expect(tk['txnRef'], t['reference']);
      h.advance(const Duration(seconds: 7));
      final after = h.server.ticket(token, tk['id'] as String)['ticket'] as Map;
      expect(after['status'], 'in_progress');
      expect((after['messages'] as List).length, 2);
    });

    test('deletion blocked by a balance, then scheduled, then completed with records retained', () {
      final h = Harness();
      final token = h.onboard(name: 'Del Ete', email: 'del@x.com');
      h.server.simulateDeposit(token, 200000);
      h.advance(const Duration(seconds: 5));
      expect(() => h.server.requestDeletion(token, password: 'wrong', confirmation: 'DELETE'), throwsA(isA<ApiError>()));
      final req = h.server.requestDeletion(token, password: 'Secret123!', confirmation: 'DELETE')['request'] as Map;
      expect(req['status'], 'action_needed');
      h.tier2(token);
      final s = h.sec();
      h.server.withdraw(token, amountKobo: 195000, pin: '2580', idempotencyKey: s.key, nonce: s.nonce, sentAt: s.sentAt);
      h.advance(const Duration(seconds: 10));
      expect(h.server.wallet(token)['available'], 0);
      final re = h.server.recheckDeletion(token)['request'] as Map;
      expect(re['status'], 'scheduled');
      h.server.opsCompleteDeletions(h.ops);
      expect(() => h.server.me(token), throwsA(isA<ApiError>()));
      expect(() => h.server.login(email: 'del@x.com', password: 'Secret123!', deviceId: 'dev-1'), throwsA(isA<ApiError>()));
      final retained = h.server.db.where('txns', (t) => t['type'] == 'deposit').length;
      expect(retained, greaterThan(0), reason: 'financial records are retained');
    });
  });

  test('notifications: unread count only counts real unread items', () {
    final h = Harness();
    final token = h.onboard();
    final n = h.server.unreadCount(token)['unread'] as int;
    expect(n, greaterThan(0));
    h.server.markAllRead(token);
    expect(h.server.unreadCount(token)['unread'], 0);
  });
}
