part of 'server.dart';

/// Authentication, sessions, one-time codes and the transaction PIN.
extension AuthApi on KnockServer {
  // ---- Registration -------------------------------------------------------

  Json register({
    required String fullName,
    required String email,
    required String password,
    required bool acceptedTerms,
    required String deviceId,
    String deviceName = 'This device',
    String? referralCode,
  }) => _mutate(() {
    _rateLimit('register:$deviceId', 5, const Duration(hours: 1));
    final name = fullName.trim().replaceAll(RegExp(r'\s+'), ' ');
    final mail = email.trim().toLowerCase();
    if (name.length < 3 || !name.contains(' ')) {
      throw ApiError('invalid_name', 'Enter your first and last name.');
    }
    if (!emailRe.hasMatch(mail)) throw ApiError('invalid_email', 'Enter a valid email address.');
    final pw = passwordProblem(password);
    if (pw != null) throw ApiError('weak_password', pw);
    if (!acceptedTerms) throw ApiError('terms', 'Please accept the Terms and Privacy Policy to continue.');
    if (db.firstWhere('users', (u) => u['email'] == mail) != null) {
      throw ApiError('email_taken', 'An account with this email already exists. Try logging in instead.');
    }

    Json? referrer;
    if (referralCode != null && referralCode.trim().isNotEmpty) {
      final code = referralCode.trim().toUpperCase();
      referrer = db.firstWhere('users', (u) => u['referralCode'] == code);
      if (referrer == null) throw ApiError('invalid_referral', 'That referral code was not found.');
    }

    final id = newId('usr');
    final salt = randomToken(12);
    final u = <String, dynamic>{
      'id': id,
      'email': mail,
      'emailVerified': false,
      'phone': null,
      'phoneVerified': false,
      'fullName': name,
      'username': _uniqueUsername(name),
      'passwordHash': hashPassword(password, salt),
      'salt': salt,
      'country': null,
      'currency': 'NGN',
      'tier': 0,
      'role': 'customer',
      'status': 'active',
      'referralCode': _uniqueReferralCode(name),
      'referredBy': referrer?['id'],
      'devices': [deviceId],
      'twoFactor': false,
      'biometrics': false,
      'guideEnabled': true,
      'guideSeen': false,
      'onboarding': 'verify_email',
      'prefs': _defaultPrefs(),
      'privacy': {'feed': true, 'leaderboard': true},
      'marketingConsent': false,
      'createdAt': nowIso,
      'lastActiveAt': nowIso,
      'securityHoldUntil': null,
    };
    db.insert('users', u);
    _audit(id, 'user.register', id, {'device': deviceId});

    if (referrer != null) _createReferral(referrer, u, deviceId);
    _sendCode(u, 'verify_email', mail);
    final token = _openSession(u, deviceId, deviceName);
    return _ok({'token': token, 'user': _publicMe(u)});
  });

  Json resendCode(String token, String purpose) => _mutate(() {
    final u = _user(token, requireVerifiedEmail: false);
    final target = purpose == 'verify_phone' ? u['pendingPhone'] as String? : u['email'] as String;
    if (target == null) throw ApiError('bad_request', 'Add a phone number first.');
    _sendCode(u, purpose, target);
    return _ok({'cooldownSeconds': 60});
  });

  Json verifyEmail(String token, String code) => _mutate(() {
    final u = _user(token, requireVerifiedEmail: false);
    _consumeCode(u['id'] as String, 'verify_email', code);
    u['emailVerified'] = true;
    if (u['onboarding'] == 'verify_email') u['onboarding'] = 'phone';
    db.put('users', u);
    _audit(u['id'] as String, 'user.email_verified', u['id'] as String);
    return _ok({'user': _publicMe(u)});
  });

  /// Changes the email on an account that has not verified its email yet
  /// ("wrong email? change it" on the code screen).
  Json changeUnverifiedEmail(String token, String email) => _mutate(() {
    final u = _user(token, requireVerifiedEmail: false);
    if (u['emailVerified'] == true) throw ApiError('bad_request', 'Use Settings to change a verified email.');
    final mail = email.trim().toLowerCase();
    if (!emailRe.hasMatch(mail)) throw ApiError('invalid_email', 'Enter a valid email address.');
    if (db.firstWhere('users', (x) => x['email'] == mail && x['id'] != u['id']) != null) {
      throw ApiError('email_taken', 'An account with this email already exists.');
    }
    u['email'] = mail;
    db.put('users', u);
    _sendCode(u, 'verify_email', mail);
    return _ok({'user': _publicMe(u)});
  });

  Json startPhoneVerification(String token, String countryCode, String nationalNumber) => _mutate(() {
    final u = _user(token);
    final phone = normalisePhone(countryCode, nationalNumber);
    if (phone == null) throw ApiError('invalid_phone', 'Enter a valid mobile number.');
    final taken = db.firstWhere('users', (x) => x['phone'] == phone && x['id'] != u['id']);
    if (taken != null) {
      _audit(u['id'] as String, 'fraud.duplicate_phone', phone);
      throw ApiError('phone_taken', 'This number is already linked to another Knock account.');
    }
    u['pendingPhone'] = phone;
    db.put('users', u);
    _sendCode(u, 'verify_phone', phone);
    return _ok({'phone': maskPhone(phone)});
  });

  Json verifyPhone(String token, String code) => _mutate(() {
    final u = _user(token);
    _consumeCode(u['id'] as String, 'verify_phone', code);
    u['phone'] = u['pendingPhone'];
    u['pendingPhone'] = null;
    u['phoneVerified'] = true;
    if ((u['tier'] as int) < 1) {
      u['tier'] = 1;
      _notify(u['id'] as String, 'verification', 'Your account is verified', 'You are on Tier 1. You can start trading within Basic limits.');
    }
    if (u['onboarding'] == 'phone') u['onboarding'] = 'personalise';
    db.put('users', u);
    _refreshReferral(u['id'] as String);
    _audit(u['id'] as String, 'user.phone_verified', u['id'] as String);
    return _ok({'user': _publicMe(u)});
  });

  Json personalise(String token, {required String country, required String currency, bool marketingConsent = false}) =>
      _mutate(() {
        final u = _user(token);
        if (!countries.any((c) => c.code == country)) throw ApiError('bad_request', 'Choose your country.');
        if (!displayCurrencies.any((c) => c.code == currency)) throw ApiError('bad_request', 'Choose a currency.');
        u['country'] = country;
        u['currency'] = currency;
        u['marketingConsent'] = marketingConsent;
        (u['prefs'] as Map)['campaign'] = marketingConsent;
        if (u['onboarding'] == 'personalise') u['onboarding'] = 'done';
        db.put('users', u);
        _claimGiftsFor(u);
        return _ok({'user': _publicMe(u)});
      });

  // ---- Login ----------------------------------------------------------------

  Json login({required String email, required String password, required String deviceId, String deviceName = 'This device'}) =>
      _mutate(() {
        final mail = email.trim().toLowerCase();
        _rateLimit('login:$mail', 10, const Duration(minutes: 15));
        final u = db.firstWhere('users', (x) => x['email'] == mail);
        // Same message for unknown email and wrong password (no account enumeration).
        const wrong = 'That email and password do not match.';
        if (u == null || u['status'] == 'closed') throw ApiError('bad_credentials', wrong);
        final lockedUntil = u['lockedUntil'] == null ? null : DateTime.parse(u['lockedUntil'] as String);
        if (lockedUntil != null && now.isBefore(lockedUntil)) {
          throw ApiError('locked', 'Too many failed attempts. Try again after ${_hm(lockedUntil)} or reset your password.');
        }
        if (!constantTimeEquals(hashPassword(password, u['salt'] as String), u['passwordHash'] as String)) {
          final fails = (u['failedLogins'] as int? ?? 0) + 1;
          u['failedLogins'] = fails;
          if (fails >= 5) {
            u['lockedUntil'] = now.add(const Duration(minutes: 15)).toIso8601String();
            u['failedLogins'] = 0;
            _notify(u['id'] as String, 'security', 'Login attempts blocked', 'We blocked several failed login attempts on your account for 15 minutes. If this was not you, reset your password.');
          }
          db.put('users', u);
          _keep('users', u['id'] as String, {'failedLogins': u['failedLogins'], 'lockedUntil': u['lockedUntil']});
          _audit(u['id'] as String, 'auth.login_failed', u['id'] as String, {'device': deviceId});
          throw ApiError('bad_credentials', wrong);
        }
        u['failedLogins'] = 0;
        u['lockedUntil'] = null;
        final known = (u['devices'] as List).contains(deviceId);
        if (u['twoFactor'] == true) {
          final challenge = randomToken();
          db.insert('challenges2fa', {
            'id': sha256Hex(challenge),
            'userId': u['id'],
            'deviceId': deviceId,
            'deviceName': deviceName,
            'expiresAt': now.add(const Duration(minutes: 10)).toIso8601String(),
          });
          _sendCode(u, 'login_2fa', u['email'] as String);
          db.put('users', u);
          return _ok({'twoFactorRequired': true, 'challenge': challenge, 'email': maskEmail(u['email'] as String)});
        }
        final token = _openSession(u, deviceId, deviceName);
        if (!known) _newDeviceAlert(u, deviceId, deviceName);
        _audit(u['id'] as String, 'auth.login', u['id'] as String, {'device': deviceId});
        return _ok({'token': token, 'user': _publicMe(u)});
      });

  Json completeTwoFactor(String challenge, String code) => _mutate(() {
    final c = db.get('challenges2fa', sha256Hex(challenge));
    if (c == null || now.isAfter(DateTime.parse(c['expiresAt'] as String))) {
      throw ApiError('expired', 'That sign-in has expired. Please log in again.');
    }
    final u = db.get('users', c['userId'] as String)!;
    _consumeCode(u['id'] as String, 'login_2fa', code);
    db.delete('challenges2fa', c['id'] as String);
    final known = (u['devices'] as List).contains(c['deviceId']);
    final token = _openSession(u, c['deviceId'] as String, c['deviceName'] as String);
    if (!known) _newDeviceAlert(u, c['deviceId'] as String, c['deviceName'] as String);
    _audit(u['id'] as String, 'auth.login_2fa', u['id'] as String);
    return _ok({'token': token, 'user': _publicMe(u)});
  });

  Json logout(String token) => _mutate(() {
    final s = db.get('sessions', sha256Hex(token));
    if (s != null) {
      s['revoked'] = true;
      s['revokedReason'] = 'logout';
      db.put('sessions', s);
      _audit(s['userId'] as String, 'auth.logout', s['id'] as String);
    }
    return _ok();
  });

  // ---- Password recovery ---------------------------------------------------

  Json forgotPassword(String email) => _mutate(() {
    final mail = email.trim().toLowerCase();
    _rateLimit('forgot:$mail', 3, const Duration(minutes: 15));
    final u = db.firstWhere('users', (x) => x['email'] == mail && x['status'] != 'closed');
    if (u != null) {
      _sendCode(u, 'reset_password', mail);
      _audit(u['id'] as String, 'auth.reset_requested', u['id'] as String);
    }
    // Always the same answer, whether or not the email exists.
    return _ok({'message': 'If an account exists for $mail, we have sent a reset code.'});
  });

  Json resetPassword({required String email, required String code, required String newPassword}) => _mutate(() {
    final mail = email.trim().toLowerCase();
    final u = db.firstWhere('users', (x) => x['email'] == mail);
    if (u == null) throw ApiError('bad_code', 'That code is not valid.');
    _consumeCode(u['id'] as String, 'reset_password', code);
    final pw = passwordProblem(newPassword);
    if (pw != null) throw ApiError('weak_password', pw);
    final salt = randomToken(12);
    u['salt'] = salt;
    u['passwordHash'] = hashPassword(newPassword, salt);
    u['lockedUntil'] = null;
    u['failedLogins'] = 0;
    // Account takeover protection: hold withdrawals and gift sends for 24h.
    u['securityHoldUntil'] = now.add(const Duration(hours: 24)).toIso8601String();
    db.put('users', u);
    _revokeAllSessions(u['id'] as String, 'password_reset');
    _notify(u['id'] as String, 'security', 'Your password was changed', 'Your Knock password was reset and all devices were signed out. Withdrawals are paused for 24 hours as a precaution.');
    _audit(u['id'] as String, 'auth.password_reset', u['id'] as String);
    return _ok();
  });

  Json changePassword(String token, String current, String next) => _mutate(() {
    final u = _user(token);
    if (!constantTimeEquals(hashPassword(current, u['salt'] as String), u['passwordHash'] as String)) {
      throw ApiError('bad_credentials', 'Your current password is not correct.');
    }
    final pw = passwordProblem(next);
    if (pw != null) throw ApiError('weak_password', pw);
    final salt = randomToken(12);
    u['salt'] = salt;
    u['passwordHash'] = hashPassword(next, salt);
    db.put('users', u);
    final keep = sha256Hex(token);
    for (final s in db.where('sessions', (s) => s['userId'] == u['id'] && s['id'] != keep).toList()) {
      s['revoked'] = true;
      s['revokedReason'] = 'password_changed';
    }
    _notify(u['id'] as String, 'security', 'Password changed', 'Your password was changed. Other devices have been signed out.');
    _audit(u['id'] as String, 'auth.password_changed', u['id'] as String);
    return _ok();
  });

  bool _checkPassword(Json u, String password) =>
      constantTimeEquals(hashPassword(password, u['salt'] as String), u['passwordHash'] as String);

  // ---- Sessions & devices ----------------------------------------------------

  Json sessions(String token) => _read(() {
    final u = _user(token);
    final mine = sha256Hex(token);
    final list = db
        .where('sessions', (s) => s['userId'] == u['id'] && s['revoked'] != true)
        .map((s) => {
              'id': s['id'],
              'deviceName': s['deviceName'],
              'createdAt': s['createdAt'],
              'lastSeenAt': s['lastSeenAt'],
              'current': s['id'] == mine,
            })
        .toList();
    return {'sessions': list};
  });

  Json revokeSession(String token, String sessionId) => _mutate(() {
    final u = _user(token);
    final s = db.get('sessions', sessionId);
    if (s == null || s['userId'] != u['id']) throw ApiError('not_found', 'Session not found.');
    s['revoked'] = true;
    s['revokedReason'] = 'revoked_by_user';
    db.put('sessions', s);
    _audit(u['id'] as String, 'auth.session_revoked', sessionId);
    return _ok();
  });

  // ---- Transaction PIN -----------------------------------------------------

  Json setPin(String token, String pin, {String? currentPin, String? password}) => _mutate(() {
    final u = _user(token);
    if (!RegExp(r'^\d{4}$').hasMatch(pin)) throw ApiError('bad_pin', 'Your PIN must be 4 digits.');
    if (RegExp(r'^(\d)\1{3}$').hasMatch(pin) || '0123456789'.contains(pin) || '9876543210'.contains(pin)) {
      throw ApiError('weak_pin', 'Choose a PIN that is harder to guess.');
    }
    if (u['pinHash'] != null) {
      final okCurrent = currentPin != null && _pinMatches(u, currentPin);
      final okPassword = password != null && _checkPassword(u, password);
      if (!okCurrent && !okPassword) throw ApiError('bad_pin', 'Confirm your current PIN or password to change it.');
    }
    final salt = randomToken(8);
    u['pinSalt'] = salt;
    u['pinHash'] = hashPassword(pin, salt, iterations: 600);
    u['pinFails'] = 0;
    db.put('users', u);
    _audit(u['id'] as String, 'auth.pin_set', u['id'] as String);
    return _ok({'user': _publicMe(u)});
  });

  bool _pinMatches(Json u, String pin) =>
      u['pinHash'] != null && constantTimeEquals(hashPassword(pin, u['pinSalt'] as String, iterations: 600), u['pinHash'] as String);

  /// Verifies the transaction PIN for a money movement. Five wrong PINs lock
  /// payments for 30 minutes.
  void _authorise(Json u, String? pin) {
    if (u['pinHash'] == null) throw ApiError('pin_required', 'Create a transaction PIN first.');
    final lock = u['pinLockedUntil'] == null ? null : DateTime.parse(u['pinLockedUntil'] as String);
    if (lock != null && now.isBefore(lock)) {
      throw ApiError('pin_locked', 'Payments are paused until ${_hm(lock)} after too many wrong PINs.');
    }
    if (pin == null || !_pinMatches(u, pin)) {
      final fails = (u['pinFails'] as int? ?? 0) + 1;
      u['pinFails'] = fails;
      if (fails >= 5) {
        u['pinLockedUntil'] = now.add(const Duration(minutes: 30)).toIso8601String();
        u['pinFails'] = 0;
        _notify(u['id'] as String, 'security', 'Payments paused', 'Your PIN was entered incorrectly 5 times. Payments are paused for 30 minutes.');
      }
      db.put('users', u);
      _keep('users', u['id'] as String, {'pinFails': u['pinFails'], 'pinLockedUntil': u['pinLockedUntil']});
      throw ApiError('bad_pin', fails >= 5 ? 'Too many wrong PINs. Payments are paused for 30 minutes.' : 'That PIN is not correct. ${5 - fails} attempts left.');
    }
    u['pinFails'] = 0;
  }

  void _requireNoHold(Json u, String what) {
    final hold = u['securityHoldUntil'] == null ? null : DateTime.parse(u['securityHoldUntil'] as String);
    if (hold != null && now.isBefore(hold)) {
      throw ApiError('security_hold', '$what is paused until ${Fmt2.dateTime(hold)} because your password or email changed recently.');
    }
  }

  // ---- Helpers --------------------------------------------------------------

  String _openSession(Json u, String deviceId, String deviceName) {
    final token = randomToken(32);
    db.insert('sessions', {
      'id': sha256Hex(token),
      'userId': u['id'],
      'deviceId': deviceId,
      'deviceName': deviceName,
      'createdAt': nowIso,
      'lastSeenAt': nowIso,
      'expiresAt': now.add(const Duration(days: 30)).toIso8601String(),
      'revoked': false,
    });
    final devices = (u['devices'] as List);
    if (!devices.contains(deviceId)) devices.add(deviceId);
    db.put('users', u);
    return token;
  }

  void _revokeAllSessions(String userId, String reason) {
    for (final s in db.where('sessions', (s) => s['userId'] == userId).toList()) {
      s['revoked'] = true;
      s['revokedReason'] = reason;
    }
  }

  void _newDeviceAlert(Json u, String deviceId, String deviceName) {
    _notify(
      u['id'] as String,
      'security',
      'New sign-in to your account',
      'Your account was accessed from $deviceName. If this was not you, change your password and sign out other devices in Settings.',
      action: {'route': 'devices'},
    );
  }

  void _sendCode(Json u, String purpose, String target) {
    final existing = db.firstWhere('otps', (o) => o['userId'] == u['id'] && o['purpose'] == purpose && o['consumed'] != true);
    if (existing != null) {
      final sent = DateTime.parse(existing['sentAt'] as String);
      if (now.difference(sent) < const Duration(seconds: 55)) {
        throw ApiError('cooldown', 'Please wait a moment before requesting another code.');
      }
      db.delete('otps', existing['id'] as String);
    }
    final code = newOtp();
    db.insert('otps', {
      'id': newId('otp'),
      'userId': u['id'],
      'purpose': purpose,
      'target': target,
      'codeHash': sha256Hex('$code:${u['id']}'),
      'attempts': 0,
      'consumed': false,
      'sentAt': nowIso,
      'expiresAt': now.add(const Duration(minutes: 10)).toIso8601String(),
    });
    final channel = purpose == 'verify_phone' ? 'sms' : 'email';
    final label = switch (purpose) {
      'verify_email' => 'Verify your email',
      'verify_phone' => 'Verify your phone',
      'reset_password' => 'Reset your password',
      'login_2fa' => 'Your sign-in code',
      'change_email' => 'Confirm your new email',
      _ => 'Your Knock code',
    };
    // Sandbox: messages land in the in-app sandbox inbox instead of being sent.
    _outbox(u['id'] as String, channel, target, label, 'Your Knock code is $code. It expires in 10 minutes. Never share it with anyone.');
  }

  void _consumeCode(String userId, String purpose, String code) {
    final o = db.firstWhere('otps', (o) => o['userId'] == userId && o['purpose'] == purpose && o['consumed'] != true);
    if (o == null) throw ApiError('bad_code', 'Request a new code to continue.');
    if (now.isAfter(DateTime.parse(o['expiresAt'] as String))) {
      throw ApiError('code_expired', 'That code has expired. Request a new one.');
    }
    if ((o['attempts'] as int) >= 5) throw ApiError('too_many', 'Too many wrong codes. Request a new one.');
    if (!constantTimeEquals(sha256Hex('${code.trim()}:$userId'), o['codeHash'] as String)) {
      o['attempts'] = (o['attempts'] as int) + 1;
      db.put('otps', o);
      _keep('otps', o['id'] as String, {'attempts': o['attempts']});
      throw ApiError('bad_code', 'That code is not correct.');
    }
    o['consumed'] = true;
    db.put('otps', o);
  }

  String _uniqueUsername(String name) {
    final base = name.split(' ').first.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
    var candidate = base.isEmpty ? 'knocker' : base;
    var n = 0;
    while (db.firstWhere('users', (u) => u['username'] == candidate) != null) {
      n++;
      candidate = '$base${_rng.nextInt(9000) + 100}';
      if (n > 20) candidate = 'k${randomToken(4).toLowerCase()}';
    }
    return candidate;
  }

  String _uniqueReferralCode(String name) {
    final base = name.split(' ').first.toUpperCase().replaceAll(RegExp(r'[^A-Z]'), '');
    final stem = base.length > 6 ? base.substring(0, 6) : base;
    String code;
    do {
      code = '$stem${List.generate(4, (_) => _refAlphabetPublic[_rng.nextInt(_refAlphabetPublic.length)]).join()}';
    } while (db.firstWhere('users', (u) => u['referralCode'] == code) != null);
    return code;
  }

  Json _defaultPrefs() => {
        'transaction': true,
        'security': true,
        'referral': true,
        'reward': true,
        'campaign': false,
        'reminder': true,
        'rate_alert': true,
        'push': true,
        'email': true,
      };

  /// What the client is allowed to know about the signed-in user.
  Json _publicMe(Json u) {
    final kyc = db.get('kyc', u['id'] as String);
    return {
      'id': u['id'],
      'fullName': u['fullName'],
      'firstName': (u['fullName'] as String).split(' ').first,
      'username': u['username'],
      'email': u['email'],
      'emailVerified': u['emailVerified'],
      'phone': u['phone'],
      'phoneVerified': u['phoneVerified'],
      'pendingPhone': u['pendingPhone'] == null ? null : maskPhone(u['pendingPhone'] as String),
      'country': u['country'],
      'currency': u['currency'],
      'tier': u['tier'],
      'onboarding': u['onboarding'],
      'referralCode': u['referralCode'],
      'twoFactor': u['twoFactor'],
      'biometrics': u['biometrics'],
      'guideEnabled': u['guideEnabled'],
      'guideSeen': u['guideSeen'],
      'hasPin': u['pinHash'] != null,
      'prefs': u['prefs'],
      'privacy': u['privacy'],
      'marketingConsent': u['marketingConsent'],
      'avatar': u['avatar'],
      'createdAt': u['createdAt'],
      'status': u['status'],
      'securityHoldUntil': u['securityHoldUntil'],
      'kyc': {
        'tier2': kyc?['tier2']?['status'] ?? 'not_started',
        'tier3': kyc?['tier3']?['status'] ?? 'not_started',
      },
      'vip': _vipLevel(u).id,
    };
  }
}

const _refAlphabetPublic = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';

String? normalisePhone(String countryCode, String national) {
  final digits = national.replaceAll(RegExp(r'\D'), '');
  final c = countryByCode(countryCode);
  var n = digits;
  if (n.startsWith('0')) n = n.substring(1);
  if (n.length < 7 || n.length > 11) return null;
  if (c.code == 'NG' && !(n.length == 10 && RegExp(r'^[789][01]').hasMatch(n))) return null;
  return '${c.dial}$n';
}

String _hm(DateTime d) => '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

abstract final class Fmt2 {
  static String dateTime(DateTime d) {
    const m = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return '${d.day} ${m[d.month - 1]}, ${_hm(d)}';
  }
}
