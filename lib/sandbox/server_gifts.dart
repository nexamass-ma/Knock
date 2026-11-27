part of 'server.dart';

/// Knock Gift Send: buy a gift card and deliver it securely to someone's
/// Knock account (or a claim link for people who are not on Knock yet).
extension GiftApi on KnockServer {
  int _giftPriceKobo(GiftBrand b, String currency, int value) {
    // Retail price: the card's face value at the sandbox buy rate plus a
    // small service charge. [Guess] Real pricing comes from the supplier.
    final ngnPerUnit = currencyByCode(currency).ngnPerUnit;
    return (value * ngnPerUnit * 1.03 * 100).round();
  }

  Json giftQuote(String token, {required String brandId, required String currency, required int value}) => _read(() {
    _user(token);
    final b = brandById(brandId);
    if (!b.sendable) throw ApiError('not_sendable', '${b.name} cards cannot be sent as gifts yet.');
    final price = _giftPriceKobo(b, currency, value);
    return {'priceKobo': price, 'feeKobo': (price * 0.03 / 1.03).round(), 'currency': currency, 'value': value};
  });

  Json lookupRecipient(String token, String handle) => _read(() {
    final u = _user(token);
    _rateLimit('lookup:${u['id']}', 30, const Duration(minutes: 10));
    final r = _findRecipient(handle);
    if (r == null) return {'exists': false};
    if (r['id'] == u['id']) throw ApiError('self', 'You cannot send a gift to yourself.');
    return {'exists': true, 'displayName': publicName(r['fullName'] as String), 'username': r['username']};
  });

  Json? _findRecipient(String handle) {
    final h = handle.trim().toLowerCase();
    if (h.isEmpty) return null;
    if (h.contains('@') && emailRe.hasMatch(h)) return db.firstWhere('users', (u) => u['email'] == h && u['status'] == 'active');
    final asUser = h.startsWith('@') ? h.substring(1) : h;
    final byUser = db.firstWhere('users', (u) => u['username'] == asUser && u['status'] == 'active');
    if (byUser != null) return byUser;
    final phone = normalisePhone('NG', h) ?? (h.startsWith('+') ? h.replaceAll(RegExp(r'[^\d+]'), '') : null);
    if (phone != null) return db.firstWhere('users', (u) => u['phone'] == phone && u['status'] == 'active');
    return null;
  }

  Json sendGift(
    String token, {
    required String brandId,
    required String currency,
    required int value,
    required String recipientType, // username | phone | email | link
    String? recipient,
    String message = '',
    required String pin,
    required String idempotencyKey,
    String? nonce,
    String? sentAt,
  }) => _mutate(() {
    _checkReplay(nonce, sentAt);
    final u = _user(token);
    _requireTier(u, 1, 'gift sending');
    _requireNoHold(u, 'Sending gifts');
    final b = brandById(brandId);
    if (!b.sendable) throw ApiError('not_sendable', '${b.name} cards cannot be sent as gifts yet.');
    if (!b.rates.containsKey(currency)) throw ApiError('bad_request', 'That currency is not available for ${b.name}.');
    if (!sendDenominations.contains(value)) throw ApiError('bad_amount', 'Choose one of the listed amounts.');
    if (message.length > 200) throw ApiError('too_long', 'Keep your message under 200 characters.');
    Json? r;
    String? handle;
    if (recipientType != 'link') {
      handle = (recipient ?? '').trim();
      if (handle.isEmpty) throw ApiError('bad_request', 'Enter who the gift is for.');
      r = _findRecipient(handle);
      if (r != null && r['id'] == u['id']) throw ApiError('self', 'You cannot send a gift to yourself.');
      if (r == null && recipientType == 'username') throw ApiError('not_found', 'No Knock user has that username.');
      if (r == null && recipientType == 'email' && !emailRe.hasMatch(handle.toLowerCase())) throw ApiError('invalid_email', 'Enter a valid email address.');
      if (r == null && recipientType == 'phone' && normalisePhone('NG', handle) == null && !handle.startsWith('+')) {
        throw ApiError('invalid_phone', 'Enter a valid phone number.');
      }
    }
    final price = _giftPriceKobo(b, currency, value);
    _checkLimits(u, price);
    _authorise(u, pin);
    final t = _newTxn(
      u,
      type: 'gift_send',
      title: 'Gift: ${b.name} ${currencySymbols[currency]}$value',
      subtitle: r != null ? 'To ${publicName(r['fullName'] as String)}' : (recipientType == 'link' ? 'Gift link' : 'To $handle'),
      amount: -price,
      idempotencyKey: idempotencyKey,
      details: {'brand': b.name, 'value': value, 'currency': currency, 'settlement': 'Paid from wallet'},
      timeline: [_step('Payment received')],
    );
    _post(t['id'] as String, 'NGN', {KnockServer.walletAcct(u['id'] as String): -price, 'sys:gift_supplier': price}, memo: 'Gift purchase');
    // The supplier code is generated (sandbox) and sealed immediately.
    final code = '${b.id.substring(0, 2).toUpperCase()}${randomToken(10).toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), 'X')}';
    String? claimToken;
    if (r == null) claimToken = randomToken(18);
    final g = {
      'id': newId('gft'),
      'reference': newReference('GFT'),
      'senderId': u['id'],
      'senderName': publicName(u['fullName'] as String),
      'recipientId': r?['id'],
      'recipientName': r == null ? null : publicName(r['fullName'] as String),
      'recipientType': recipientType,
      'recipientHandle': recipientType == 'email' ? handle?.toLowerCase() : (recipientType == 'phone' ? (normalisePhone('NG', handle ?? '') ?? handle) : handle),
      'brandId': b.id,
      'brand': b.name,
      'color': b.color,
      'glyph': b.glyph,
      'currency': currency,
      'value': value,
      'message': message.trim(),
      'status': 'payment_pending',
      'codeSealed': _vault.seal(code),
      'claimTokenHash': claimToken == null ? null : sha256Hex(claimToken),
      'claimExpiresAt': claimToken == null ? null : now.add(const Duration(days: 30)).toIso8601String(),
      'expiresAt': now.add(const Duration(days: 365)).toIso8601String(),
      'txnId': t['id'],
      'priceKobo': price,
      'events': [{'status': 'payment_pending', 'at': nowIso}],
      'createdAt': nowIso,
      'updatedAt': nowIso,
      'owners': [u['id']],
    };
    db.insert('gifts', g);
    (t['details'] as Map)['giftId'] = g['id'];
    db.put('txns', t);
    _notify(u['id'] as String, 'gift', 'Gift purchased', 'Your ${b.name} gift is being prepared.', action: {'route': 'gift', 'id': g['id']});
    _audit(u['id'] as String, 'gift.purchased', g['id'] as String);
    return _ok({
      'txn': t,
      'gift': _giftView(g, u['id'] as String),
      if (claimToken != null) 'claimLink': 'https://knock.app/gift/$claimToken',
      if (claimToken != null) 'claimToken': claimToken,
    });
  });

  void _giftEvent(Json g, String status) {
    g['status'] = status;
    g['updatedAt'] = nowIso;
    (g['events'] as List).add({'status': status, 'at': nowIso});
    db.put('gifts', g);
  }

  void _runGiftJobs() {
    for (final g in db.table('gifts').values.toList()) {
      final since = now.difference(DateTime.parse(g['updatedAt'] as String)).inSeconds;
      switch (g['status']) {
        case 'payment_pending' when since >= 2:
          _giftEvent(g, 'preparing');
        case 'preparing' when since >= 2:
          _giftEvent(g, 'sent');
          final t = db.get('txns', g['txnId'] as String);
          if (t != null) _setTxnStatus(t, 'successful', step: 'Gift sent');
          _notify(g['senderId'] as String, 'gift', 'Gift sent', 'Your ${g['brand']} gift is on its way.', action: {'route': 'gift', 'id': g['id']});
        case 'sent' when since >= 1:
          if (g['recipientId'] != null) {
            _deliverGift(g);
          } else {
            _giftEvent(g, 'awaiting_claim');
            if (g['recipientType'] == 'email' && g['recipientHandle'] != null) {
              _outbox(null, 'email', g['recipientHandle'] as String, '${g['senderName']} sent you a gift on Knock',
                  'You have received a ${g['brand']} gift card. Create a free Knock account with this email to claim it. Your gift code is never sent by email.');
            } else if (g['recipientType'] == 'phone' && g['recipientHandle'] != null) {
              _outbox(null, 'sms', g['recipientHandle'] as String, 'Gift on Knock', '${g['senderName']} sent you a gift on Knock. Join Knock with this number to claim it.');
            }
          }
        case 'awaiting_claim':
          final exp = g['claimExpiresAt'] == null ? null : DateTime.parse(g['claimExpiresAt'] as String);
          if (exp != null && now.isAfter(exp)) {
            _giftEvent(g, 'expired');
            _refundGift(g, 'Gift link expired unclaimed');
          }
      }
    }
  }

  void _deliverGift(Json g) {
    _giftEvent(g, 'delivered');
    final owners = (g['owners'] as List);
    if (!owners.contains(g['recipientId'])) owners.add(g['recipientId']);
    db.put('gifts', g);
    final value = '${currencySymbols[g['currency']]}${g['value']}';
    _notify(
      g['recipientId'] as String,
      'gift',
      "🎁 You've received a gift!",
      '${g['senderName']} has sent you a $value ${g['brand']} Gift Card. Your gift is waiting for you on Knock.',
      action: {'route': 'gift', 'id': g['id'], 'cta': 'Open My Gift'},
    );
    _notify(g['senderId'] as String, 'gift', 'Gift delivered', 'Your gift reached ${g['recipientName']}.', action: {'route': 'gift', 'id': g['id']});
  }

  void _refundGift(Json g, String reason) {
    final t = _newTxn(
      db.get('users', g['senderId'] as String)!,
      type: 'gift_send',
      title: 'Gift refund',
      subtitle: reason,
      amount: g['priceKobo'] as int,
      direction: 'credit',
      status: 'successful',
      details: {'giftId': g['id'], 'settlement': 'Refunded to Naira wallet'},
    );
    _post(t['id'] as String, 'NGN', {'sys:gift_supplier': -(g['priceKobo'] as int), KnockServer.walletAcct(g['senderId'] as String): g['priceKobo'] as int}, memo: 'Gift refund');
    _notify(g['senderId'] as String, 'gift', 'Gift refunded', '$reason. ${_naira(g['priceKobo'] as int)} was returned to your wallet.');
  }

  /// Attaches pending gifts addressed to this person's verified email or
  /// phone once they have an account.
  void _claimGiftsFor(Json u) {
    for (final g in db.where('gifts', (g) => g['status'] == 'awaiting_claim' && g['recipientId'] == null).toList()) {
      final matchEmail = g['recipientType'] == 'email' && g['recipientHandle'] == u['email'] && u['emailVerified'] == true;
      final matchPhone = g['recipientType'] == 'phone' && g['recipientHandle'] == u['phone'] && u['phoneVerified'] == true;
      if (!matchEmail && !matchPhone) continue;
      g['recipientId'] = u['id'];
      g['recipientName'] = publicName(u['fullName'] as String);
      g['claimTokenHash'] = null;
      _deliverGift(g);
    }
  }

  Json claimGift(String token, String claimTokenOrLink) => _mutate(() {
    final u = _user(token);
    _requireTier(u, 1, 'gift claiming');
    _rateLimit('claim:${u['id']}', 10, const Duration(minutes: 10));
    final raw = claimTokenOrLink.trim().split('/').last;
    final g = db.firstWhere('gifts', (g) => g['claimTokenHash'] == sha256Hex(raw));
    if (g == null) throw ApiError('not_found', 'This gift link is not valid or has already been claimed.');
    if (g['senderId'] == u['id']) throw ApiError('self', 'You cannot claim a gift you sent.');
    final exp = DateTime.parse(g['claimExpiresAt'] as String);
    if (now.isAfter(exp)) throw ApiError('expired', 'This gift link has expired.');
    if (g['status'] != 'awaiting_claim' && g['status'] != 'sent') throw ApiError('not_ready', 'This gift is not ready to claim yet.');
    g['recipientId'] = u['id'];
    g['recipientName'] = publicName(u['fullName'] as String);
    g['claimTokenHash'] = null; // single use
    _deliverGift(g);
    _audit(u['id'] as String, 'gift.claimed', g['id'] as String);
    return _ok({'gift': _giftView(g, u['id'] as String)});
  });

  Json _giftView(Json g, String viewer) {
    final received = g['recipientId'] == viewer;
    return {
      'id': g['id'],
      'reference': g['reference'],
      'direction': received ? 'received' : 'sent',
      'senderName': g['senderName'],
      'recipientName': g['recipientName'] ?? (g['recipientType'] == 'link' ? 'Gift link' : g['recipientHandle']),
      'brandId': g['brandId'],
      'brand': g['brand'],
      'color': g['color'],
      'glyph': g['glyph'],
      'currency': g['currency'],
      'value': g['value'],
      'message': g['message'],
      'status': g['status'],
      'events': g['events'],
      'createdAt': g['createdAt'],
      'expiresAt': g['expiresAt'],
      'claimExpiresAt': g['claimExpiresAt'],
      'forwardable': brandById(g['brandId'] as String).forwardable,
      'tradable': brandById(g['brandId'] as String).rates.containsKey(g['currency']),
    };
  }

  Json myGifts(String token) => _read(() {
    final u = _user(token);
    final uid = u['id'] as String;
    final list = db
        .where('gifts', (g) => g['senderId'] == uid || g['recipientId'] == uid)
        .map((g) => _giftView(g, uid))
        .toList()
      ..sort((a, b) => (b['createdAt'] as String).compareTo(a['createdAt'] as String));
    return {'items': list};
  });

  Json gift(String token, String giftId) => _read(() {
    final u = _user(token);
    final g = db.get('gifts', giftId);
    if (g == null || (g['senderId'] != u['id'] && g['recipientId'] != u['id'])) throw ApiError('not_found', 'Gift not found.');
    return {'gift': _giftView(g, u['id'] as String)};
  });

  Json _receivedGift(Json u, String giftId) {
    final g = db.get('gifts', giftId);
    if (g == null || g['recipientId'] != u['id']) throw ApiError('not_found', 'Gift not found.');
    return g;
  }

  Json openGift(String token, String giftId) => _mutate(() {
    final u = _user(token);
    final g = _receivedGift(u, giftId);
    if (g['status'] == 'delivered') {
      _giftEvent(g, 'opened');
      _notify(g['senderId'] as String, 'gift', 'Gift opened', '${g['recipientName']} opened your ${g['brand']} gift.', action: {'route': 'gift', 'id': g['id']});
    }
    return _ok({'gift': _giftView(g, u['id'] as String)});
  });

  /// Reveals the code only after the recipient re-authenticates.
  Json revealGiftCode(String token, String giftId, String pin) => _mutate(() {
    final u = _user(token);
    final g = _receivedGift(u, giftId);
    if (g['status'] == 'expired' || g['status'] == 'traded') throw ApiError('unavailable', 'This gift code is no longer available.');
    _authorise(u, pin);
    _audit(u['id'] as String, 'gift.code_revealed', giftId);
    if (g['status'] == 'delivered') _giftEvent(g, 'opened');
    return _ok({'code': _vault.open(g['codeSealed'] as String), 'pinNote': 'Redeem at the brand\'s official store or app.'});
  });

  Json markGiftRedeemed(String token, String giftId) => _mutate(() {
    final u = _user(token);
    final g = _receivedGift(u, giftId);
    if (g['status'] == 'redeemed' || g['status'] == 'traded') throw ApiError('already', 'This gift has already been used.');
    _giftEvent(g, 'redeemed');
    _notify(g['senderId'] as String, 'gift', 'Gift redeemed', '${g['recipientName']} redeemed your ${g['brand']} gift.');
    _audit(u['id'] as String, 'gift.redeemed', giftId);
    return _ok({'gift': _giftView(g, u['id'] as String)});
  });

  /// Trades a received gift through Knock: creates a sell quote for it.
  Json tradeGift(String token, String giftId) => _mutate(() {
    final u = _user(token);
    final g = _receivedGift(u, giftId);
    if (g['status'] == 'redeemed' || g['status'] == 'traded' || g['status'] == 'expired') {
      throw ApiError('already', 'This gift has already been used.');
    }
    final b = brandById(g['brandId'] as String);
    final q = _buildQuote(u, b, g['currency'] as String, 'ecode', g['value'] as int);
    q['giftId'] = g['id'];
    db.insert('quotes', q);
    _audit(u['id'] as String, 'gift.trade_quote', giftId);
    return _ok({'quote': _quoteView(q), 'ecode': _vault.open(g['codeSealed'] as String)});
  });

  Json forwardGift(String token, String giftId, String handle) => _mutate(() {
    final u = _user(token);
    final g = _receivedGift(u, giftId);
    if (!brandById(g['brandId'] as String).forwardable) {
      throw ApiError('not_forwardable', "${g['brand']}'s terms do not allow gifts to be passed on.");
    }
    final r = _findRecipient(handle);
    if (r == null) throw ApiError('not_found', 'No Knock user found.');
    g['recipientId'] = r['id'];
    g['recipientName'] = publicName(r['fullName'] as String);
    _deliverGift(g);
    return _ok();
  });

  /// Called when a trade quote created from a gift is submitted.
  void _markGiftTraded(Json q) {
    final gid = q['giftId'] as String?;
    if (gid == null) return;
    final g = db.get('gifts', gid);
    if (g != null) _giftEvent(g, 'traded');
  }
}
