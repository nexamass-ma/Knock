part of 'server.dart';

/// Creates the sandbox world: rate rows, campaigns, the operations user and
/// a handful of clearly-labelled sandbox community accounts whose settled
/// test trades feed the leaderboard and activity feed.
///
/// New customer accounts always start empty: ₦0 balance, no history.
void seedSandbox(KnockServer s) {
  final db = s.db;
  final now = s.now;
  db.transaction(() {
    db.put('meta', {'id': 'seed', 'at': now.toIso8601String(), 'version': 2});
    db.put('meta', {'id': 'rates', 'last': now.toIso8601String(), 'cryptoLast': now.toIso8601String()});

    for (final b in giftBrands) {
      for (final e in b.rates.entries) {
        db.put('rates', {
          'id': '${b.id}|${e.key}',
          'brandId': b.id,
          'currency': e.key,
          'rate': e.value,
          'previousRate': e.value - (e.key == 'USD' ? 5 : 0),
          'version': 1,
          'updatedAt': now.subtract(const Duration(minutes: 7)).toIso8601String(),
          'history': [
            {'rate': e.value - 5, 'at': now.subtract(const Duration(hours: 6)).toIso8601String()},
            {'rate': e.value, 'at': now.subtract(const Duration(minutes: 7)).toIso8601String()},
          ],
        });
      }
    }
    for (final a in cryptoAssets) {
      db.put('crypto_prices', {'id': a.symbol, 'usd': a.usdPrice, 'open': a.usdPrice, 'change24h': 0.0, 'updatedAt': now.toIso8601String()});
    }

    // Fire Load campaigns with real start and end times.
    db.put('campaigns', {
      'id': 'cmp_apple_boost',
      'kind': 'rate_boost',
      'title': 'Apple Card Boost',
      'subtitle': '+₦15 per \$1 on Apple USD cards of \$50 or more',
      'brandId': 'apple',
      'currency': 'USD',
      'minFace': 50,
      'boostNgn': 15,
      'startsAt': now.subtract(const Duration(hours: 2)).toIso8601String(),
      'endsAt': now.add(const Duration(days: 5)).toIso8601String(),
      'eligibility': ['Tier 1 or above', 'Apple USD cards, physical or e-code', 'Card value \$50 or more'],
      'rule': 'The boost is added to the quoted rate automatically while the campaign is live.',
    });
    db.put('campaigns', {
      'id': 'cmp_trade300',
      'kind': 'volume_bonus',
      'title': 'Trade \$300, get ₦1,000',
      'subtitle': 'Sell \$300 of gift cards before the timer ends',
      'targetUsdCents': 30000,
      'rewardKobo': 100000,
      'minTier': 1,
      'startsAt': now.subtract(const Duration(hours: 1)).toIso8601String(),
      'endsAt': now.add(const Duration(days: 7)).toIso8601String(),
      'eligibility': ['Tier 1 or above', 'Completed gift card trades only', 'One reward per customer'],
      'rule': 'Eligible volume is the USD value of gift card trades completed during the campaign. The reward is added to your bonus balance.',
    });
    db.put('campaigns', {
      'id': 'cmp_launch',
      'kind': 'info',
      'title': 'Launch week double points',
      'subtitle': 'Double Knock Points on every challenge',
      'startsAt': now.subtract(const Duration(days: 17)).toIso8601String(),
      'endsAt': now.subtract(const Duration(days: 10)).toIso8601String(),
      'eligibility': ['All customers'],
      'rule': 'Ended.',
    });
    db.put('campaigns', {
      'id': 'cmp_festive',
      'kind': 'info',
      'title': 'Festive rate week',
      'subtitle': 'Better rates on Steam and Amazon cards',
      'startsAt': now.add(const Duration(days: 18)).toIso8601String(),
      'endsAt': now.add(const Duration(days: 25)).toIso8601String(),
      'eligibility': ['Tier 1 or above'],
      'rule': 'Details will be published when the campaign starts.',
    });

    Map<String, dynamic> mkUser(String name, String email, {String role = 'customer', bool seedUser = true}) {
      final salt = randomToken(8);
      final u = <String, dynamic>{
        'id': newId('usr'),
        'email': email,
        'emailVerified': true,
        'phone': null,
        'phoneVerified': true,
        'fullName': name,
        'username': name.split(' ').first.toLowerCase() + (role == 'ops' ? '_ops' : ''),
        'passwordHash': hashPassword(randomToken(), salt, iterations: 10),
        'salt': salt,
        'country': 'NG',
        'currency': 'NGN',
        'tier': 2,
        'role': role,
        'status': 'active',
        'referralCode': '${name.split(' ').first.toUpperCase()}SBX',
        'devices': <String>['sandbox-${randomToken(4)}'],
        'prefs': {},
        'privacy': {'feed': true, 'leaderboard': role == 'customer'},
        'createdAt': now.subtract(const Duration(days: 40)).toIso8601String(),
        'lastActiveAt': now.toIso8601String(),
        'sandboxSeed': seedUser,
        'guideEnabled': false,
      };
      db.insert('users', u);
      return u;
    }

    mkUser('Knock Operations', 'ops@sandbox.knock', role: 'ops');
    mkUser('Gift Sender', 'gifts@sandbox.knock', role: 'system');

    final community = [
      ('Ada Okafor', 14),
      ('Tunde Bakare', 11),
      ('Grace Mensah', 9),
      ('Ifeanyi Obi', 7),
      ('Zainab Musa', 6),
      ('Chidi Nwosu', 5),
      ('Funke Adeyemi', 4),
      ('Kwame Asante', 3),
      ('Emeka Eze', 2),
      ('Sade Lawal', 2),
      ('Bola Ajayi', 1),
    ];
    final rng = Random(7);
    final brandsForSeed = ['apple', 'amazon', 'steam', 'google_play', 'razer', 'sephora'];
    for (final (name, trades) in community) {
      final u = mkUser(name, '${name.split(' ').first.toLowerCase()}@sandbox.knock');
      for (var i = 0; i < trades; i++) {
        final b = brandById(brandsForSeed[rng.nextInt(brandsForSeed.length)]);
        final face = [50, 100, 150, 200, 300, 500, 1000][rng.nextInt(7)];
        final rate = b.rates['USD']! * 100;
        final gross = rate * face;
        final fee = KnockServer.tradeFeeKobo(gross);
        final at = i == 0 ? now.subtract(Duration(minutes: 20 + rng.nextInt(600))) : now.subtract(Duration(hours: 6 + rng.nextInt(24 * 25)));
        final id = newId('txn');
        db.insert('txns', {
          'id': id,
          'reference': newReference(),
          'userId': u['id'],
          'type': 'giftcard_sell',
          'title': '${b.name} gift card',
          'subtitle': '\$$face USD · Physical',
          'amount': gross - fee,
          'fee': fee,
          'currency': 'NGN',
          'direction': 'credit',
          'status': 'successful',
          'details': {
            'brandId': b.id,
            'brand': b.name,
            'currency': 'USD',
            'faceValue': face,
            'eligibleUsdCents': face * 100,
            'tracker': 'completed',
            'settlement': 'Settled to Naira wallet',
            'sandboxSeed': true,
          },
          'timeline': [],
          'createdAt': at.toIso8601String(),
          'updatedAt': at.add(const Duration(minutes: 9)).toIso8601String(),
        });
        db.insert('entries', {'id': newId('ent'), 'txnId': id, 'account': 'sys:giftcard_desk', 'amount': -gross, 'currency': 'NGN', 'at': at.toIso8601String()});
        db.insert('entries', {'id': newId('ent'), 'txnId': id, 'account': 'sys:fees', 'amount': fee, 'currency': 'NGN', 'at': at.toIso8601String()});
        db.insert('entries', {'id': newId('ent'), 'txnId': id, 'account': KnockServer.walletAcct(u['id'] as String), 'amount': gross - fee, 'currency': 'NGN', 'at': at.toIso8601String()});
      }
    }
    return null;
  });
}
