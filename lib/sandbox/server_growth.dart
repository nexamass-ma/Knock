part of 'server.dart';

/// Welcome bonus, referrals, Knockout challenges, Fire Load campaigns,
/// leaderboard and the live activity feed. Every reward is a ledger entry
/// backed by a written rule below.
extension GrowthApi on KnockServer {
  static const qualifyingTypes = {'giftcard_sell', 'crypto_buy', 'crypto_sell'};

  /// Sandbox shortens the 7-day referral security hold to one minute.
  static const referralHold = Duration(minutes: 1);

  // ---- Hooks ---------------------------------------------------------------------

  void _onSettledTrade(Json u, Json t) {
    if (!qualifyingTypes.contains(t['type'])) return;
    _grantWelcomeBonus(u, t);
    _refreshReferral(u['id'] as String);
    _checkChallengesFor(u);
  }

  Json? _grant(String uniqueKey) => db.firstWhere('reward_grants', (g) => g['uniqueKey'] == uniqueKey);

  Json _rewardTxn(Json u, {required String title, required String subtitle, required int amount, required String kind, required String account, Json details = const {}}) {
    final t = _newTxn(
      u,
      type: kind == 'referral' ? 'referral_payout' : 'reward',
      title: title,
      subtitle: subtitle,
      amount: amount,
      direction: 'credit',
      status: 'successful',
      details: {...details, 'settlement': account == 'bonus' ? 'Added to bonus balance (not withdrawable)' : 'Settled to Naira wallet'},
    );
    _post(t['id'] as String, 'NGN', {
      'sys:rewards': -amount,
      account == 'bonus' ? KnockServer.bonusAcct(u['id'] as String) : KnockServer.walletAcct(u['id'] as String): amount,
    }, memo: title);
    return t;
  }

  // ---- Welcome bonus --------------------------------------------------------------

  void _grantWelcomeBonus(Json u, Json trade) {
    final uid = u['id'] as String;
    final key = 'welcome:$uid';
    if (_grant(key) != null) return;
    if (u['sandboxSeed'] == true) return;
    // Fraud checks: one bonus per device and per identity.
    final devices = (u['devices'] as List).cast<String>();
    final sharedDevice = db.firstWhere(
      'reward_grants',
      (g) => g['kind'] == 'welcome' && g['status'] == 'credited' && g['userId'] != uid && devices.contains(g['deviceId']),
    );
    if (sharedDevice != null) {
      db.insert('reward_grants', {
        'id': newId('rg'),
        'uniqueKey': key,
        'userId': uid,
        'kind': 'welcome',
        'status': 'blocked',
        'reason': 'A welcome bonus was already paid to an account on this device.',
        'createdAt': nowIso,
      });
      _audit('system', 'fraud.welcome_blocked', uid);
      return;
    }
    final t = _rewardTxn(
      u,
      title: 'Welcome bonus',
      subtitle: 'For your first trade',
      amount: welcomeBonusNgn * 100,
      kind: 'welcome',
      account: 'bonus',
      details: {'rule': 'First successful qualifying trade', 'sourceRef': trade['reference']},
    );
    db.insert('reward_grants', {
      'id': newId('rg'),
      'uniqueKey': key,
      'userId': uid,
      'kind': 'welcome',
      'amount': welcomeBonusNgn * 100,
      'points': 0,
      'status': 'credited',
      'txnId': t['id'],
      'reference': t['reference'],
      'sourceTxnId': trade['id'],
      'deviceId': devices.isEmpty ? null : devices.last,
      'createdAt': nowIso,
    });
    _notify(uid, 'reward', 'Welcome bonus earned', 'Thanks for your first trade. ₦$welcomeBonusNgn has been added to your bonus balance.', action: {'route': 'rewards'});
  }

  Json welcomeBonus(String token) => _read(() {
    final u = _user(token);
    final g = _grant('welcome:${u['id']}');
    final firstTrade = db.firstWhere('txns', (t) => t['userId'] == u['id'] && qualifyingTypes.contains(t['type']) && t['status'] == 'pending');
    return {
      'amount': welcomeBonusNgn * 100,
      'status': g?['status'] ?? (firstTrade != null ? 'in_progress' : 'eligible'),
      'reference': g?['reference'],
      'reason': g?['reason'],
      'steps': [
        {'label': 'Create your account', 'done': true},
        {'label': 'Verify your phone', 'done': (u['tier'] as int) >= 1},
        {'label': 'Complete your first trade', 'done': g != null && g['status'] == 'credited'},
      ],
      'rules': [
        'New customers only, one bonus per person and per device.',
        'Paid after your first gift card or crypto trade is completed. Failed, reversed or cancelled trades do not count.',
        'The bonus goes to your bonus balance. It is not withdrawable; how it can be used will be announced before launch.',
        'If the trade is reversed or found to be fraudulent, the bonus is reversed.',
      ],
    };
  });

  // ---- Referrals ------------------------------------------------------------------

  void _createReferral(Json referrer, Json referee, String deviceId) {
    final rDevices = (referrer['devices'] as List).cast<String>();
    String status = 'registered';
    String? reason;
    if (rDevices.contains(deviceId)) {
      status = 'rejected';
      reason = 'Self-referral: the new account was created on the referrer\'s device.';
      _audit('system', 'fraud.self_referral', referee['id'] as String);
    }
    db.insert('referrals', {
      'id': newId('ref'),
      'referrerId': referrer['id'],
      'refereeId': referee['id'],
      'status': status,
      'reason': reason,
      'volumeUsdCents': 0,
      'rewardStatus': 'none',
      'createdAt': nowIso,
    });
    if (status != 'rejected') {
      _notify(referrer['id'] as String, 'referral', 'Someone joined with your code', '${publicName(referee['fullName'] as String)} signed up with your referral code.', action: {'route': 'referrals'});
    }
  }

  void _refreshReferral(String refereeId) {
    final r = db.firstWhere('referrals', (r) => r['refereeId'] == refereeId);
    if (r == null || r['status'] == 'rejected' || r['status'] == 'qualified') return;
    final referee = db.get('users', refereeId)!;
    final vol = _volumeUsdCents(refereeId);
    r['volumeUsdCents'] = vol;
    if ((referee['tier'] as int) >= 1 && r['status'] == 'registered') r['status'] = 'verified';
    final referrer = db.get('users', r['referrerId'] as String);
    if (vol > referralQualifyUsd * 100 && referrer != null) {
      r['status'] = 'qualified';
      r['qualifiedAt'] = nowIso;
      r['rewardStatus'] = 'pending';
      r['releaseAt'] = now.add(referralHold).toIso8601String();
      _notify(referrer['id'] as String, 'referral', 'Referral qualified', '${publicName(referee['fullName'] as String)} passed \$$referralQualifyUsd in trades. Your ₦${_groupInt(referralRewardNgn)} reward is pending a short security check.', action: {'route': 'referrals'});
      _checkChallengesFor(referrer);
    } else if (referrer != null && vol >= referralQualifyUsd * 50 && r['halfwayNotified'] != true) {
      r['halfwayNotified'] = true;
      _notify(referrer['id'] as String, 'reminder', 'Your referral is halfway there', '${publicName(referee['fullName'] as String)} has traded over \$${referralQualifyUsd ~/ 2}. Your reward unlocks at \$$referralQualifyUsd.', action: {'route': 'referrals'});
    }
    db.put('referrals', r);
  }

  void _runRewardJobs() {
    for (final r in db.where('referrals', (r) => r['rewardStatus'] == 'pending').toList()) {
      if (now.isBefore(DateTime.parse(r['releaseAt'] as String))) continue;
      final referrer = db.get('users', r['referrerId'] as String);
      final referee = db.get('users', r['refereeId'] as String);
      if (referrer == null || referee == null) continue;
      final key = 'referral:${r['id']}';
      if (_grant(key) != null) continue;
      final t = _rewardTxn(
        referrer,
        title: 'Referral reward',
        subtitle: 'For inviting ${publicName(referee['fullName'] as String)}',
        amount: referralRewardNgn * 100,
        kind: 'referral',
        account: 'wallet',
        details: {'rule': 'Referred customer passed \$$referralQualifyUsd of settled, eligible trades'},
      );
      db.insert('reward_grants', {
        'id': newId('rg'),
        'uniqueKey': key,
        'userId': referrer['id'],
        'kind': 'referral',
        'amount': referralRewardNgn * 100,
        'points': 0,
        'status': 'credited',
        'txnId': t['id'],
        'reference': t['reference'],
        'createdAt': nowIso,
      });
      r['rewardStatus'] = 'available';
      r['rewardTxnId'] = t['id'];
      db.put('referrals', r);
      _notify(referrer['id'] as String, 'reward', 'Referral reward paid', '₦${_groupInt(referralRewardNgn)} has been added to your wallet.', action: {'route': 'txn', 'id': t['id']});
    }
  }

  Json referrals(String token) => _read(() {
    final u = _user(token);
    final mine = db.where('referrals', (r) => r['referrerId'] == u['id']).toList()
      ..sort((a, b) => (b['createdAt'] as String).compareTo(a['createdAt'] as String));
    int count(bool Function(Json) f) => mine.where(f).length;
    final pending = count((r) => r['rewardStatus'] == 'pending') * referralRewardNgn * 100;
    final earned = count((r) => r['rewardStatus'] == 'available') * referralRewardNgn * 100;
    final invites = db.where('invites', (i) => i['userId'] == u['id']).length;
    return {
      'code': u['referralCode'],
      'link': 'https://knock.app/r/${u['referralCode']}',
      'rewardPerReferral': referralRewardNgn * 100,
      'qualifyUsd': referralQualifyUsd,
      'stats': {
        'invited': invites + mine.length,
        'registered': mine.where((r) => r['status'] != 'rejected').length,
        'verified': count((r) => r['status'] == 'verified' || r['status'] == 'qualified'),
        'qualified': count((r) => r['status'] == 'qualified'),
        'pendingRewards': pending,
        'availableRewards': earned,
        'totalEarned': earned,
      },
      'items': [for (final r in mine) _referralView(r)],
    };
  });

  Json _referralView(Json r) {
    final referee = db.get('users', r['refereeId'] as String);
    return {
      'id': r['id'],
      'name': referee == null ? 'Closed account' : publicName(referee['fullName'] as String),
      // Masked: referrers never see a referred customer's full email.
      'email': referee == null ? '' : maskEmail(referee['email'] as String),
      'status': r['status'],
      'statusLabel': switch (r['status']) {
        'qualified' => 'Qualified',
        'verified' => 'Pending · Verified',
        'rejected' => 'Not eligible',
        _ => 'Pending · Registered',
      },
      'volumeUsdCents': r['volumeUsdCents'],
      'reward': referralRewardNgn * 100,
      'rewardStatus': r['rewardStatus'],
      'reason': r['reason'],
      'joinedAt': r['createdAt'],
      'qualifiedAt': r['qualifiedAt'],
    };
  }

  Json recordInvite(String token, String channel) => _mutate(() {
    final u = _user(token);
    db.insert('invites', {'id': newId('inv'), 'userId': u['id'], 'channel': channel, 'at': nowIso});
    return _ok();
  });

  // ---- Knockout challenges ------------------------------------------------------

  List<Json> _challengeDefs() {
    final seed = DateTime.parse((db.get('meta', 'seed')?['at'] as String?) ?? nowIso);
    return [
      {'id': 'daily_txn', 'group': 'Daily', 'title': 'Daily Knock', 'desc': 'Complete one successful transaction today.', 'metric': 'txns', 'target': 1, 'period': 'day', 'points': 10},
      {'id': 'weekly_gc', 'group': 'Weekly', 'title': 'Card Week', 'desc': 'Sell \$200 of gift cards this week.', 'metric': 'gc_usd', 'target': 20000, 'period': 'week', 'points': 50},
      {'id': 'first_trade', 'group': 'Milestones', 'title': 'First Knock', 'desc': 'Complete your first trade.', 'metric': 'trades', 'target': 1, 'period': 'ever', 'points': 25, 'badge': 'First Knock'},
      {'id': 'five_txn', 'group': 'Milestones', 'title': 'High Five', 'desc': 'Complete five successful transactions.', 'metric': 'txns', 'target': 5, 'period': 'ever', 'points': 50, 'badge': 'High Five'},
      {'id': 'ten_txn', 'group': 'Milestones', 'title': 'Perfect Ten', 'desc': 'Complete ten successful transactions.', 'metric': 'txns', 'target': 10, 'period': 'ever', 'points': 100, 'badge': 'Perfect Ten'},
      {'id': 'monthly_1k', 'group': 'Milestones', 'title': 'Monthly Mover', 'desc': 'Trade \$1,000 in a calendar month.', 'metric': 'trade_usd', 'target': 100000, 'period': 'month', 'points': 150, 'badge': 'Monthly Mover'},
      {'id': 'refer_one', 'group': 'Referrals', 'title': 'Connector', 'desc': 'Get your first qualified referral.', 'metric': 'qualified_refs', 'target': 1, 'period': 'ever', 'points': 100, 'badge': 'Connector'},
      {'id': 'refer_three', 'group': 'Referrals', 'title': 'Ambassador', 'desc': 'Refer three qualified users.', 'metric': 'qualified_refs', 'target': 3, 'period': 'ever', 'points': 300, 'badge': 'Ambassador'},
      {
        'id': 'festive',
        'group': 'Weekly',
        'title': 'Festive Sprint',
        'desc': 'Complete three gift card trades during the festive week.',
        'metric': 'trades',
        'target': 3,
        'period': 'window',
        'startsAt': seed.add(const Duration(days: 18)).toIso8601String(),
        'endsAt': seed.add(const Duration(days: 25)).toIso8601String(),
        'points': 120,
      },
    ];
  }

  (DateTime, String) _periodStart(String period) {
    switch (period) {
      case 'day':
        final d = DateTime(now.year, now.month, now.day);
        return (d, 'd${d.toIso8601String().substring(0, 10)}');
      case 'week':
        final d = DateTime(now.year, now.month, now.day).subtract(Duration(days: now.weekday - 1));
        return (d, 'w${d.toIso8601String().substring(0, 10)}');
      case 'month':
        final d = DateTime(now.year, now.month);
        return (d, 'm${d.toIso8601String().substring(0, 7)}');
      default:
        return (DateTime(2000), 'ever');
    }
  }

  int _metric(String uid, String metric, DateTime since, [DateTime? until]) {
    final txns = db.where('txns', (t) {
      if (t['userId'] != uid || t['status'] != 'successful') return false;
      final at = DateTime.parse(t['createdAt'] as String);
      return !at.isBefore(since) && (until == null || at.isBefore(until));
    });
    switch (metric) {
      case 'txns':
        return txns.where((t) => t['type'] != 'reward' && t['type'] != 'referral_payout' && t['type'] != 'crypto_deposit').length;
      case 'trades':
        return txns.where((t) => qualifyingTypes.contains(t['type'])).length;
      case 'gc_usd':
        return txns.where((t) => t['type'] == 'giftcard_sell').fold<int>(0, (a, t) => a + ((t['details'] as Map)['eligibleUsdCents'] as int? ?? 0));
      case 'trade_usd':
        return txns.fold<int>(0, (a, t) => a + ((t['details'] as Map?)?['eligibleUsdCents'] as int? ?? 0));
      case 'qualified_refs':
        return db.where('referrals', (r) => r['referrerId'] == uid && r['status'] == 'qualified').length;
    }
    return 0;
  }

  List<Json> _challengeStates(Json u) {
    final uid = u['id'] as String;
    final out = <Json>[];
    for (final c in _challengeDefs()) {
      int progress;
      String periodKey;
      var windowEnded = false;
      if (c['period'] == 'window') {
        final s = DateTime.parse(c['startsAt'] as String);
        final e = DateTime.parse(c['endsAt'] as String);
        periodKey = 'win';
        if (now.isBefore(s)) {
          out.add({...c, 'state': 'upcoming', 'progress': 0});
          continue;
        }
        progress = _metric(uid, c['metric'] as String, s, e);
        windowEnded = now.isAfter(e);
      } else {
        final (since, key) = _periodStart(c['period'] as String);
        periodKey = key;
        progress = _metric(uid, c['metric'] as String, since);
      }
      final claim = _grant('ch:${c['id']}:$periodKey:$uid');
      final done = progress >= (c['target'] as int);
      final String state = claim != null ? 'claimed' : (done ? 'completed' : (windowEnded ? 'ended' : 'active'));
      out.add({...c, 'state': state, 'progress': progress.clamp(0, c['target'] as int), 'periodKey': periodKey, 'claimedAt': claim?['createdAt']});
    }
    return out;
  }

  void _checkChallengesFor(Json u) {
    for (final c in _challengeStates(u)) {
      if (c['state'] != 'completed') continue;
      final key = 'notice:${c['id']}:${c['periodKey']}:${u['id']}';
      if (db.get('notices', key) != null) continue;
      db.insert('notices', {'id': key, 'at': nowIso});
      _notify(u['id'] as String, 'reward', 'Challenge complete: ${c['title']}', 'Claim your ${c['points']} Knock Points in Knockout.', action: {'route': 'knockout'});
    }
  }

  Json knockout(String token) => _read(() {
    final u = _user(token);
    final states = _challengeStates(u);
    return {
      'points': _points(u['id'] as String),
      'challenges': states,
      'badges': [
        for (final c in states)
          if (c['badge'] != null) {'name': c['badge'], 'earned': c['state'] == 'claimed' || c['state'] == 'completed', 'desc': c['desc']},
      ],
      'note': 'Knock Points track your achievements. They have no cash value yet; any future use will be published in the Rewards terms.',
    };
  });

  Json claimChallenge(String token, String challengeId) => _mutate(() {
    final u = _user(token);
    final c = _challengeStates(u).firstWhere((c) => c['id'] == challengeId, orElse: () => throw ApiError('not_found', 'Challenge not found.'));
    if (c['state'] == 'claimed') throw ApiError('already', 'You have already claimed this reward.');
    if (c['state'] != 'completed') throw ApiError('not_complete', 'Finish the challenge first.');
    db.insert('reward_grants', {
      'id': newId('rg'),
      'uniqueKey': 'ch:${c['id']}:${c['periodKey']}:${u['id']}',
      'userId': u['id'],
      'kind': 'challenge',
      'points': c['points'],
      'amount': 0,
      'status': 'credited',
      'title': c['title'],
      'createdAt': nowIso,
    });
    _audit(u['id'] as String, 'reward.challenge_claimed', challengeId);
    return _ok({'points': _points(u['id'] as String)});
  });

  int _points(String uid) => db
      .where('reward_grants', (g) => g['userId'] == uid && g['status'] == 'credited')
      .fold<int>(0, (a, g) => a + (g['points'] as int? ?? 0));

  Json rewards(String token) => _read(() {
    final u = _user(token);
    final grants = db.where('reward_grants', (g) => g['userId'] == u['id']).toList()
      ..sort((a, b) => (b['createdAt'] as String).compareTo(a['createdAt'] as String));
    return {
      'bonusBalance': balanceOf(KnockServer.bonusAcct(u['id'] as String)),
      'points': _points(u['id'] as String),
      'referralEarned': grants.where((g) => g['kind'] == 'referral' && g['status'] == 'credited').fold<int>(0, (a, g) => a + (g['amount'] as int? ?? 0)),
      'history': grants,
      'vip': _vipLevel(u).id,
    };
  });

  // ---- Fire Load campaigns ----------------------------------------------------------

  Json fireLoad(String token) => _read(() {
    final u = _user(token);
    final out = <Json>[];
    for (final c in db.table('campaigns').values) {
      final s = DateTime.parse(c['startsAt'] as String);
      final e = DateTime.parse(c['endsAt'] as String);
      final state = now.isBefore(s) ? 'upcoming' : (now.isBefore(e) ? 'live' : 'ended');
      Json progress = {};
      if (c['kind'] == 'volume_bonus') {
        final v = _campaignVolume(u['id'] as String, c);
        progress = {'value': v, 'target': c['targetUsdCents'], 'claimed': _grant('camp:${c['id']}:${u['id']}') != null};
      }
      out.add({...c, 'state': state, 'progress': progress, 'secondsLeft': e.difference(now).inSeconds, 'secondsToStart': s.difference(now).inSeconds});
    }
    out.sort((a, b) => (a['startsAt'] as String).compareTo(b['startsAt'] as String));
    return {'items': out};
  });

  int _campaignVolume(String uid, Json c) {
    final s = DateTime.parse(c['startsAt'] as String);
    final e = DateTime.parse(c['endsAt'] as String);
    return db
        .where('txns', (t) {
          if (t['userId'] != uid || t['status'] != 'successful' || t['type'] != 'giftcard_sell') return false;
          final at = DateTime.parse(t['createdAt'] as String);
          return !at.isBefore(s) && at.isBefore(e);
        })
        .fold<int>(0, (a, t) => a + ((t['details'] as Map)['eligibleUsdCents'] as int? ?? 0));
  }

  Json claimCampaign(String token, String campaignId) => _mutate(() {
    final u = _user(token);
    final c = db.get('campaigns', campaignId);
    if (c == null || c['kind'] != 'volume_bonus') throw ApiError('not_found', 'Campaign not found.');
    if (!_campaignLive(c)) throw ApiError('ended', 'This campaign is not live.');
    _requireTier(u, c['minTier'] as int? ?? 1, 'this campaign');
    final key = 'camp:${c['id']}:${u['id']}';
    if (_grant(key) != null) throw ApiError('already', 'You have already claimed this reward.');
    if (_campaignVolume(u['id'] as String, c) < (c['targetUsdCents'] as int)) throw ApiError('not_complete', 'You have not reached the target yet.');
    final t = _rewardTxn(u, title: c['title'] as String, subtitle: 'Campaign reward', amount: c['rewardKobo'] as int, kind: 'campaign', account: 'bonus', details: {'rule': c['rule']});
    db.insert('reward_grants', {
      'id': newId('rg'),
      'uniqueKey': key,
      'userId': u['id'],
      'kind': 'campaign',
      'amount': c['rewardKobo'],
      'points': 0,
      'status': 'credited',
      'txnId': t['id'],
      'reference': t['reference'],
      'title': c['title'],
      'createdAt': nowIso,
    });
    return _ok({'txn': t});
  });

  // ---- Leaderboard -------------------------------------------------------------------

  Json leaderboard(String token, {String board = 'traders', String period = 'monthly'}) => _read(() {
    final me = _user(token);
    final since = switch (period) {
      'weekly' => _periodStart('week').$1,
      'monthly' => _periodStart('month').$1,
      _ => DateTime(2000),
    };
    final rows = <Json>[];
    for (final u in db.table('users').values) {
      if (u['status'] != 'active' || u['emailVerified'] != true) continue;
      final uid = u['id'] as String;
      final score = switch (board) {
        'referrers' => db.where('referrals', (r) => r['referrerId'] == uid && r['status'] == 'qualified' && !DateTime.parse(r['qualifiedAt'] as String).isBefore(since)).length,
        'volume' => _metric(uid, 'trade_usd', since),
        _ => _metric(uid, 'trades', since),
      };
      if (score == 0 && uid != me['id']) continue;
      final visible = (u['privacy'] as Map?)?['leaderboard'] != false;
      rows.add({
        'userId': uid,
        'displayName': uid == me['id'] ? 'You' : (visible ? publicName(u['fullName'] as String) : 'Anonymous trader'),
        'initials': visible || uid == me['id'] ? (u['fullName'] as String).split(' ').map((p) => p[0]).take(2).join() : '?',
        'score': score,
        'sandbox': u['sandboxSeed'] == true,
      });
    }
    rows.sort((a, b) => (b['score'] as int).compareTo(a['score'] as int));
    for (var i = 0; i < rows.length; i++) {
      rows[i]['position'] = i + 1;
      rows[i]['rewardStatus'] = period == 'monthly' && i < 3 && (rows[i]['score'] as int) > 0 ? 'Top 3 · 500 points at month end' : null;
    }
    final mine = rows.firstWhere((r) => r['userId'] == me['id'], orElse: () => {'position': null, 'score': 0});
    for (final r in rows) {
      r.remove('userId');
    }
    return {
      'board': board,
      'period': period,
      'unit': board == 'volume' ? 'usd_cents' : (board == 'referrers' ? 'referrals' : 'trades'),
      'top': rows.take(10).toList(),
      'me': mine,
      'total': rows.length,
      'rules': 'Only settled, eligible trades count. Names are shown as first name and initial; you can hide yours in Settings → Privacy.',
    };
  });

  // ---- Live activity feed ------------------------------------------------------------

  Json activityFeed(String token) => _read(() {
    final me = _user(token);
    final items = <Json>[];
    for (final t in db.where('txns', (t) => t['status'] == 'successful' && (t['type'] == 'giftcard_sell' || t['type'] == 'crypto_sell' || t['type'] == 'gift_send'))) {
      final at = DateTime.parse(t['updatedAt'] as String);
      if (now.difference(at) > const Duration(days: 2)) continue;
      final owner = db.get('users', t['userId'] as String);
      if (owner == null || (owner['privacy'] as Map?)?['feed'] == false) continue;
      final d = t['details'] as Map;
      final self = owner['id'] == me['id'];
      final text = switch (t['type']) {
        'giftcard_sell' => '${self ? 'You' : 'Someone'} just sold a ${currencySymbols[d['currency']]}${_groupInt(d['faceValue'] as int)} ${d['brand']} gift card.',
        'crypto_sell' => self ? 'You completed a crypto sale.' : 'Another user completed a crypto sale.',
        _ => self ? 'You sent a gift card.' : 'Someone just sent a gift card to a friend.',
      };
      items.add({'text': text, 'at': t['updatedAt'], 'kind': t['type'], 'sandbox': owner['sandboxSeed'] == true});
    }
    for (final r in db.where('referrals', (r) => r['referrerId'] == me['id'])) {
      final first = db.firstWhere('txns', (t) => t['userId'] == r['refereeId'] && t['status'] == 'successful' && qualifyingTypes.contains(t['type']));
      if (first != null) items.add({'text': 'Your referral just completed their first trade.', 'at': first['updatedAt'], 'kind': 'referral'});
    }
    items.sort((a, b) => (b['at'] as String).compareTo(a['at'] as String));
    return {'items': items.take(12).toList()};
  });
}
