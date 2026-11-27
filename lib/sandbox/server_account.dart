part of 'server.dart';

/// Profile, settings, verification tiers, limits and waitlists.
extension AccountApi on KnockServer {
  Json me(String token) => _read(() {
    final u = _user(token, requireVerifiedEmail: false);
    return {'user': _publicMe(u)};
  });

  /// Cheap poll used by the app to know when to refresh screens.
  Json syncState(String token) => _read(() {
    final u = _user(token, requireVerifiedEmail: false);
    final uid = u['id'] as String;
    var last = '';
    void see(String? at) {
      if (at != null && at.compareTo(last) > 0) last = at;
    }
    for (final t in db.where('txns', (t) => t['userId'] == uid)) {
      see(t['updatedAt'] as String?);
    }
    for (final g in db.where('gifts', (g) => g['senderId'] == uid || g['recipientId'] == uid)) {
      see(g['updatedAt'] as String?);
    }
    for (final t in db.where('tickets', (t) => t['userId'] == uid)) {
      see(t['updatedAt'] as String?);
    }
    for (final n in db.where('notifications', (n) => n['userId'] == uid)) {
      see(n['createdAt'] as String?);
    }
    final k = db.get('kyc', uid);
    see((k?['tier2'] as Map?)?['verifiedAt'] as String?);
    see((k?['tier3'] as Map?)?['reviewedAt'] as String?);
    return {
      'unread': db.where('notifications', (n) => n['userId'] == uid && n['read'] != true).length,
      'available': balanceOf(KnockServer.walletAcct(uid)),
      'bonus': balanceOf(KnockServer.bonusAcct(uid)),
      'tier': u['tier'],
      'last': last,
      'rates': db.get('meta', 'rates')?['last'],
    };
  });

  /// Unlock after inactivity, or confirm before revealing secrets.
  Json checkPin(String token, String pin) => _mutate(() {
    final u = _user(token);
    _authorise(u, pin);
    db.put('users', u);
    return _ok();
  });

  Json updateProfile(String token, {String? fullName, String? username, String? avatar}) => _mutate(() {
    final u = _user(token);
    if (fullName != null) {
      final n = fullName.trim().replaceAll(RegExp(r'\s+'), ' ');
      if (n.length < 3 || !n.contains(' ')) throw ApiError('invalid_name', 'Enter your first and last name.');
      if ((u['tier'] as int) >= 2 && n != u['fullName']) {
        throw ApiError('locked_field', 'Your name is locked to your verified identity. Contact support to change it.');
      }
      u['fullName'] = n;
    }
    if (username != null) {
      final un = username.trim().toLowerCase();
      if (!RegExp(r'^[a-z0-9_]{3,20}$').hasMatch(un)) {
        throw ApiError('invalid_username', 'Use 3 to 20 letters, numbers or underscores.');
      }
      if (db.firstWhere('users', (x) => x['username'] == un && x['id'] != u['id']) != null) {
        throw ApiError('username_taken', 'That username is taken.');
      }
      u['username'] = un;
    }
    if (avatar != null) u['avatar'] = avatar.isEmpty ? null : avatar;
    db.put('users', u);
    _audit(u['id'] as String, 'profile.update', u['id'] as String);
    return _ok({'user': _publicMe(u)});
  });

  Json updateSettings(
    String token, {
    Json? prefs,
    Json? privacy,
    bool? guideEnabled,
    bool? guideSeen,
    bool? biometrics,
    bool? marketingConsent,
    String? currency,
  }) => _mutate(() {
    final u = _user(token, requireVerifiedEmail: false);
    if (prefs != null) {
      final p = Map<String, dynamic>.from(u['prefs'] as Map)..addAll(prefs);
      // Transaction and security messages cannot be switched off.
      p['transaction'] = true;
      p['security'] = true;
      if (p['campaign'] == true && u['marketingConsent'] != true && marketingConsent != true) {
        throw ApiError('consent', 'Turn on marketing consent to receive campaign messages.');
      }
      u['prefs'] = p;
    }
    if (privacy != null) u['privacy'] = Map<String, dynamic>.from(u['privacy'] as Map)..addAll(privacy);
    if (guideEnabled != null) u['guideEnabled'] = guideEnabled;
    if (guideSeen != null) u['guideSeen'] = guideSeen;
    if (biometrics != null) u['biometrics'] = biometrics;
    if (marketingConsent != null) {
      u['marketingConsent'] = marketingConsent;
      if (!marketingConsent) (u['prefs'] as Map)['campaign'] = false;
      _audit(u['id'] as String, 'consent.marketing', '$marketingConsent');
    }
    if (currency != null) {
      if (!displayCurrencies.any((c) => c.code == currency)) throw ApiError('bad_request', 'Unsupported currency.');
      u['currency'] = currency;
    }
    db.put('users', u);
    return _ok({'user': _publicMe(u)});
  });

  Json setTwoFactor(String token, bool enabled, String password) => _mutate(() {
    final u = _user(token);
    if (!_checkPassword(u, password)) throw ApiError('bad_credentials', 'That password is not correct.');
    u['twoFactor'] = enabled;
    db.put('users', u);
    _notify(u['id'] as String, 'security', enabled ? 'Two-step verification is on' : 'Two-step verification is off',
        enabled ? 'We will ask for an email code each time you log in.' : 'You will no longer be asked for a code when you log in.');
    _audit(u['id'] as String, 'security.2fa', '$enabled');
    return _ok({'user': _publicMe(u)});
  });

  Json startEmailChange(String token, String password, String newEmail) => _mutate(() {
    final u = _user(token);
    if (!_checkPassword(u, password)) throw ApiError('bad_credentials', 'That password is not correct.');
    final mail = newEmail.trim().toLowerCase();
    if (!emailRe.hasMatch(mail)) throw ApiError('invalid_email', 'Enter a valid email address.');
    if (db.firstWhere('users', (x) => x['email'] == mail) != null) throw ApiError('email_taken', 'That email is already in use.');
    u['pendingEmail'] = mail;
    db.put('users', u);
    _sendCode(u, 'change_email', mail);
    return _ok({'email': mail});
  });

  Json confirmEmailChange(String token, String code) => _mutate(() {
    final u = _user(token);
    _consumeCode(u['id'] as String, 'change_email', code);
    final old = u['email'] as String;
    u['email'] = u['pendingEmail'];
    u['pendingEmail'] = null;
    u['securityHoldUntil'] = now.add(const Duration(hours: 24)).toIso8601String();
    db.put('users', u);
    _outbox(u['id'] as String, 'email', old, 'Your Knock email was changed', 'The email on your Knock account was changed. If this was not you, contact support immediately.');
    _notify(u['id'] as String, 'security', 'Email address changed', 'Your email is now ${u['email']}. Withdrawals are paused for 24 hours as a precaution.');
    _audit(u['id'] as String, 'security.email_changed', u['id'] as String);
    return _ok({'user': _publicMe(u)});
  });

  // ---- Verification tiers ------------------------------------------------------

  Json verification(String token) => _read(() {
    final u = _user(token);
    final k = db.get('kyc', u['id'] as String) ?? {};
    final t2 = (k['tier2'] as Map?) ?? {};
    final t3 = (k['tier3'] as Map?) ?? {};
    final tier = u['tier'] as int;
    return {
      'tier': tier,
      'tiers': [
        for (final r in tierRules.skip(1))
          {
            'tier': r.tier,
            'name': r.name,
            'dailyLimit': r.dailyLimitNgn * 100,
            'singleLimit': r.singleLimitNgn * 100,
            'canWithdraw': r.canWithdraw,
            'status': tier >= r.tier
                ? 'verified'
                : r.tier == 2
                ? (t2['status'] ?? 'not_started')
                : r.tier == 3
                ? (t3['status'] ?? 'not_started')
                : 'not_started',
            'requirements': switch (r.tier) {
              1 => [
                  {'label': 'Full name', 'done': true},
                  {'label': 'Email address', 'done': u['emailVerified'] == true},
                  {'label': 'Phone number', 'done': u['phoneVerified'] == true},
                ],
              2 => [
                  {'label': 'Bank account', 'done': t2['bankVerified'] == true},
                  {'label': 'BVN', 'done': t2['bvnVerified'] == true},
                  {'label': 'NIN', 'done': t2['ninVerified'] == true},
                ],
              _ => [
                  {'label': 'Residential address', 'done': t3['address'] != null},
                  {'label': 'Proof of address', 'done': t3['docRef'] != null},
                  {'label': 'Review by our team', 'done': t3['status'] == 'verified'},
                ],
            },
            'capabilities': switch (r.tier) {
              1 => ['Browse every service', 'Sell gift cards and crypto within Basic limits', 'Buy airtime, data and bills', 'Send and receive gift cards'],
              2 => ['Withdraw to your bank', 'Higher limits', 'Betting wallet funding', 'Receive bank payments'],
              _ => ['Highest limits', 'Priority review on large trades', 'Early access to new services'],
            },
            if (r.tier == 2 && t2['reason'] != null) 'reason': t2['reason'],
            if (r.tier == 3 && t3['reason'] != null) 'reason': t3['reason'],
          },
      ],
      'bank': t2['bankVerified'] == true
          ? {'bankName': t2['bankName'], 'accountName': t2['accountName'], 'last4': t2['accountLast4']}
          : null,
      'usage': _usage(u),
    };
  });

  /// Sandbox identity provider: returns the account name for a bank account.
  Json resolveBankAccount(String token, String bankCode, String accountNumber) => _read(() {
    final u = _user(token);
    _rateLimit('nuban:${u['id']}', 20, const Duration(minutes: 10));
    if (!RegExp(r'^\d{10}$').hasMatch(accountNumber)) throw ApiError('invalid_account', 'Account numbers have 10 digits.');
    if (accountNumber.startsWith('000')) throw ApiError('not_found', 'We could not find that account. Check the number and bank.');
    return {'accountName': (u['fullName'] as String).toUpperCase(), 'bankName': bankName(bankCode)};
  });

  Json submitTier2(String token, {required String bankCode, required String accountNumber, required String bvn, required String nin}) =>
      _mutate(() {
        final u = _user(token);
        _requireTier(u, 1, 'Tier 2 verification');
        if (!RegExp(r'^\d{10}$').hasMatch(accountNumber)) throw ApiError('invalid_account', 'Account numbers have 10 digits.');
        if (!RegExp(r'^\d{11}$').hasMatch(bvn)) throw ApiError('invalid_bvn', 'Your BVN has 11 digits.');
        if (!RegExp(r'^\d{11}$').hasMatch(nin)) throw ApiError('invalid_nin', 'Your NIN has 11 digits.');
        final k = db.get('kyc', u['id'] as String) ?? {'id': u['id']};
        final t2 = (k['tier2'] as Map?) ?? {};
        if (t2['status'] == 'pending') throw ApiError('pending', 'Your verification is already being checked.');
        // Never keep raw BVN/NIN. Store a keyed fingerprint (to detect one
        // identity on many accounts) and the last 4 digits for display.
        final bvnToken = sha256Hex('bvn:$bvn:${KnockServer._webhookSecret}');
        final dup = db.firstWhere('kyc', (x) => x['id'] != u['id'] && (x['tier2'] as Map?)?['bvnToken'] == bvnToken);
        if (dup != null) {
          _audit(u['id'] as String, 'fraud.duplicate_identity', 'bvn');
          throw ApiError('identity_in_use', 'This identity is already linked to another Knock account. Contact support if you think this is a mistake.');
        }
        k['tier2'] = <String, dynamic>{
          'status': 'pending',
          'submittedAt': nowIso,
          'bankCode': bankCode,
          'bankName': bankName(bankCode),
          'accountLast4': last4(accountNumber),
          'accountToken': sha256Hex('acct:$bankCode:$accountNumber'),
          'accountName': (u['fullName'] as String).toUpperCase(),
          'bvnLast4': last4(bvn),
          'bvnToken': bvnToken,
          'ninLast4': last4(nin),
          'ninToken': sha256Hex('nin:$nin:${KnockServer._webhookSecret}'),
          'sandboxOutcome': bvn == '00000000000' || nin == '00000000000' ? 'fail' : 'pass',
        };
        db.put('kyc', k);
        _audit(u['id'] as String, 'kyc.tier2_submitted', u['id'] as String);
        _notify(u['id'] as String, 'verification', 'Verification submitted', 'We are checking your bank account, BVN and NIN with our identity partner.');
        return _ok();
      });

  Json submitTier3(String token, {required Json address, required String docType, required String docRef}) => _mutate(() {
    final u = _user(token);
    _requireTier(u, 2, 'Tier 3 verification');
    for (final f in ['line1', 'city', 'state']) {
      if ((address[f] as String? ?? '').trim().length < 2) throw ApiError('invalid_address', 'Please complete your address.');
    }
    if (docRef.isEmpty) throw ApiError('missing_doc', 'Upload a proof of address.');
    final k = db.get('kyc', u['id'] as String) ?? {'id': u['id']};
    k['tier3'] = <String, dynamic>{
      'status': 'pending',
      'submittedAt': nowIso,
      'address': address,
      'docType': docType,
      'docRef': docRef,
    };
    db.put('kyc', k);
    _audit(u['id'] as String, 'kyc.tier3_submitted', u['id'] as String);
    _notify(u['id'] as String, 'verification', 'Address submitted', 'Our team is reviewing your proof of address.');
    return _ok();
  });

  void _runKycJobs() {
    for (final k in db.table('kyc').values) {
      final t2 = k['tier2'] as Map?;
      if (t2 != null && t2['status'] == 'pending' && now.difference(DateTime.parse(t2['submittedAt'] as String)).inSeconds >= 5) {
        final u = db.get('users', k['id'] as String);
        if (u == null) continue;
        if (t2['sandboxOutcome'] == 'fail') {
          t2['status'] = 'failed';
          t2['reason'] = 'Your BVN details did not match your name. Check them and try again.';
          _notify(u['id'] as String, 'verification', 'Verification unsuccessful', t2['reason'] as String, action: {'route': 'verification'});
        } else {
          t2
            ..['status'] = 'verified'
            ..['verifiedAt'] = nowIso
            ..['bankVerified'] = true
            ..['bvnVerified'] = true
            ..['ninVerified'] = true;
          if ((u['tier'] as int) < 2) u['tier'] = 2;
          db.put('users', u);
          _notify(u['id'] as String, 'verification', 'You are now Tier 2', 'Your account has been verified. Withdrawals and higher limits are unlocked.', action: {'route': 'verification'});
          _refreshReferral(u['id'] as String);
        }
        _audit('system', 'kyc.tier2_${t2['status']}', k['id'] as String);
        db.put('kyc', k);
      }
      final t3 = k['tier3'] as Map?;
      if (t3 != null && t3['status'] == 'pending' && now.difference(DateTime.parse(t3['submittedAt'] as String)).inSeconds >= 10) {
        final u = db.get('users', k['id'] as String);
        if (u == null) continue;
        t3['status'] = 'verified';
        t3['reviewedAt'] = nowIso;
        u['tier'] = 3;
        db.put('users', u);
        db.put('kyc', k);
        _notify(u['id'] as String, 'verification', 'You are now Tier 3', 'Advanced verification is complete. Your highest limits are unlocked.', action: {'route': 'verification'});
        _audit('system', 'kyc.tier3_verified', k['id'] as String);
      }
    }
  }

  Json _usage(Json u) {
    final rule = tierRules[u['tier'] as int];
    final today = DateTime(now.year, now.month, now.day);
    var used = 0;
    for (final t in db.where('txns', (t) => t['userId'] == u['id'])) {
      if (t['status'] == 'failed' || t['status'] == 'cancelled' || t['status'] == 'reversed') continue;
      if (DateTime.parse(t['createdAt'] as String).isBefore(today)) continue;
      if (t['type'] == 'reward' || t['type'] == 'deposit') continue;
      used += (t['amount'] as int).abs();
    }
    return {'dailyLimit': rule.dailyLimitNgn * 100, 'usedToday': used, 'singleLimit': rule.singleLimitNgn * 100};
  }

  void _checkLimits(Json u, int amountKobo) {
    final rule = tierRules[u['tier'] as int];
    if (rule.tier == 0) throw ApiError('tier_required', 'Verify your phone number to start transacting.', details: {'tier': 1});
    if (amountKobo > rule.singleLimitNgn * 100) {
      throw ApiError('limit', 'This is above your ${rule.name} limit of ₦${_groupInt(rule.singleLimitNgn)} per transaction. Upgrade your verification to continue.', details: {'tier': rule.tier + 1});
    }
    final used = _usage(u)['usedToday'] as int;
    if (used + amountKobo > rule.dailyLimitNgn * 100) {
      throw ApiError('limit', 'This would take you over your daily ${rule.name} limit of ₦${_groupInt(rule.dailyLimitNgn)}. Upgrade your verification for higher limits.', details: {'tier': rule.tier + 1});
    }
  }

  // ---- VIP -------------------------------------------------------------------

  int _volumeUsdCents(String uid, {Duration? within, DateTime? since}) {
    var v = 0;
    for (final t in db.where('txns', (t) => t['userId'] == uid && t['status'] == 'successful')) {
      final cents = (t['details'] as Map?)?['eligibleUsdCents'] as int?;
      if (cents == null) continue;
      final at = DateTime.parse(t['createdAt'] as String);
      if (within != null && now.difference(at) > within) continue;
      if (since != null && at.isBefore(since)) continue;
      v += cents;
    }
    return v;
  }

  VipLevel _vipLevel(Json u) {
    final usd = _volumeUsdCents(u['id'] as String, within: const Duration(days: 90)) ~/ 100;
    return vipLevels.lastWhere((l) => usd >= l.minUsd90d);
  }

  Json vip(String token) => _read(() {
    final u = _user(token);
    final usd = _volumeUsdCents(u['id'] as String, within: const Duration(days: 90));
    final level = _vipLevel(u);
    final idx = vipLevels.indexOf(level);
    final next = idx + 1 < vipLevels.length ? vipLevels[idx + 1] : null;
    return {
      'level': level.id,
      'volumeUsdCents90d': usd,
      'next': next == null ? null : {'id': next.id, 'name': next.name, 'minUsd': next.minUsd90d},
      'levels': [
        for (final l in vipLevels) {'id': l.id, 'name': l.name, 'minUsd': l.minUsd90d, 'benefits': l.benefits, 'rateBonusNgn': l.rateBonusNgn},
      ],
      'rule': 'Your level is recalculated daily from eligible, settled trade volume in the last 90 days.',
    };
  });

  // ---- Waitlists (USA account, Knock AI) ---------------------------------------

  Json joinWaitlist(String token, String product, {required bool consent, String? note}) => _mutate(() {
    final u = _user(token);
    if (!consent) throw ApiError('consent', 'Please agree to be contacted about this product.');
    final id = '${u['id']}|$product';
    final existing = db.get('waitlist', id);
    db.put('waitlist', {
      'id': id,
      'userId': u['id'],
      'product': product,
      'consent': true,
      'note': note,
      'createdAt': existing?['createdAt'] ?? nowIso,
      'updatedAt': nowIso,
    });
    _audit(u['id'] as String, 'waitlist.join', product);
    return _ok({'joined': true, 'position': db.where('waitlist', (w) => w['product'] == product).length});
  });

  Json waitlistStatus(String token, String product) => _read(() {
    final u = _user(token);
    final w = db.get('waitlist', '${u['id']}|$product');
    return {'joined': w != null, 'joinedAt': w?['createdAt']};
  });
}

String _groupInt(int v) {
  final s = v.toString();
  final b = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) b.write(',');
    b.write(s[i]);
  }
  return b.toString();
}
