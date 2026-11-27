part of 'server.dart';

/// Gift card pricing, rate locks, live rate changes, trade review and the
/// rate watchlist.
extension TradeApi on KnockServer {
  // ---- Rates --------------------------------------------------------------------

  Json _rateView(Json? u, GiftBrand b, String currency) {
    final r = _rateRow(b.id, currency);
    final eff = _effectiveRate(u, b.id, currency, 'physical', 100);
    final effE = _effectiveRate(u, b.id, currency, 'ecode', 100);
    final prev = r['previousRate'] as int? ?? r['rate'] as int;
    final rate = r['rate'] as int;
    return {
      'brandId': b.id,
      'brand': b.name,
      'category': b.category,
      'glyph': b.glyph,
      'color': b.color,
      'currency': currency,
      'symbol': currencySymbols[currency],
      'rate': rate,
      'previousRate': prev,
      'movement': rate > prev ? 'up' : rate < prev ? 'down' : 'flat',
      'movementPct': prev == 0 ? 0 : (rate - prev) / prev * 100,
      'effectiveKobo': eff.rateKobo,
      'effectiveEcodeKobo': effE.rateKobo,
      'boostKobo': eff.boostKobo,
      'vipKobo': eff.vipKobo,
      'campaign': eff.campaign?['title'],
      'mode': b.lockMinutes > 0 ? 'locked' : 'indicative',
      'lockMinutes': b.lockMinutes,
      'updatedAt': r['updatedAt'],
      'version': r['version'],
      'minValue': b.minValue,
      'maxValue': b.maxValue,
      'feeRule': '0.5% service fee, minimum ₦100, maximum ₦5,000',
      'history': r['history'],
    };
  }

  Json giftCardRates(String token, {String? query, String? category}) => _read(() {
    final u = _user(token);
    final items = <Json>[];
    for (final b in giftBrands) {
      if (category != null && b.category != category) continue;
      if (query != null && query.trim().isNotEmpty && !b.name.toLowerCase().contains(query.trim().toLowerCase())) continue;
      for (final c in b.rates.keys) {
        items.add(_rateView(u, b, c));
      }
    }
    final watched = db.where('watchlist', (w) => w['userId'] == u['id']).map((w) => '${w['brandId']}|${w['currency']}').toSet();
    for (final i in items) {
      i['watched'] = watched.contains('${i['brandId']}|${i['currency']}');
    }
    return {'items': items, 'categories': giftCategories, 'updatedAt': nowIso, 'source': 'Knock pricing engine (sandbox)'};
  });

  Json brands(String token) => _read(() {
    _user(token);
    return {
      'items': [
        for (final b in giftBrands)
          {
            'id': b.id,
            'name': b.name,
            'category': b.category,
            'glyph': b.glyph,
            'color': b.color,
            'currencies': b.rates.keys.toList(),
            'mode': b.lockMinutes > 0 ? 'locked' : 'indicative',
            'lockMinutes': b.lockMinutes,
            'minValue': b.minValue,
            'maxValue': b.maxValue,
            'sendable': b.sendable,
            'forwardable': b.forwardable,
          },
      ],
    };
  });

  // ---- Quotes and live rate changes ------------------------------------------------

  Json quoteGiftCard(String token, {required String brandId, required String currency, required String cardType, required int faceValue}) =>
      _mutate(() {
        final u = _user(token);
        final b = brandById(brandId);
        if (!b.rates.containsKey(currency)) throw ApiError('bad_request', '${b.name} ${currency} cards are not supported.');
        if (faceValue < b.minValue || faceValue > b.maxValue) {
          throw ApiError('bad_amount', 'Enter a card value between ${currencySymbols[currency]}${b.minValue} and ${currencySymbols[currency]}${_groupInt(b.maxValue)}.');
        }
        final q = _buildQuote(u, b, currency, cardType, faceValue);
        db.insert('quotes', q);
        _audit(u['id'] as String, 'trade.quote', q['id'] as String, {'rate': q['rateKobo'], 'mode': q['mode']});
        return _ok({'quote': _quoteView(q)});
      });

  Json _buildQuote(Json u, GiftBrand b, String currency, String cardType, int faceValue, {String? id}) {
    final eff = _effectiveRate(u, b.id, currency, cardType, faceValue);
    final gross = eff.rateKobo * faceValue;
    final fee = KnockServer.tradeFeeKobo(gross);
    final row = _rateRow(b.id, currency);
    return {
      'id': id ?? newId('qt'),
      'userId': u['id'],
      'brandId': b.id,
      'brand': b.name,
      'currency': currency,
      'cardType': cardType,
      'faceValue': faceValue,
      'rateKobo': eff.rateKobo,
      'boostKobo': eff.boostKobo,
      'vipKobo': eff.vipKobo,
      'campaignId': eff.campaign?['id'],
      'version': row['version'],
      'mode': b.lockMinutes > 0 ? 'locked' : 'indicative',
      'lockExpiresAt': b.lockMinutes > 0 ? now.add(Duration(minutes: b.lockMinutes)).toIso8601String() : null,
      'grossKobo': gross,
      'feeKobo': fee,
      'netKobo': gross - fee,
      'eligibleUsdCents': _usdCentsFor(currency, faceValue),
      'status': 'open',
      'acceptances': <Json>[],
      'createdAt': nowIso,
    };
  }

  Json _quoteView(Json q) {
    final exp = q['lockExpiresAt'] == null ? null : DateTime.parse(q['lockExpiresAt'] as String);
    return {...q, 'secondsLeft': exp == null ? null : exp.difference(now).inSeconds.clamp(0, 1 << 30)};
  }

  Json _ownQuote(Json u, String quoteId) {
    final q = db.get('quotes', quoteId);
    if (q == null || q['userId'] != u['id']) throw ApiError('not_found', 'This trade could not be found.');
    return q;
  }

  /// What would the customer get right now, compared with their quote?
  Json _compare(Json u, Json q) {
    final b = brandById(q['brandId'] as String);
    final fresh = _buildQuote(u, b, q['currency'] as String, q['cardType'] as String, q['faceValue'] as int, id: q['id'] as String);
    final locked = q['mode'] == 'locked';
    final exp = q['lockExpiresAt'] == null ? null : DateTime.parse(q['lockExpiresAt'] as String);
    final lockValid = locked && exp != null && now.isBefore(exp);
    final oldRate = q['rateKobo'] as int;
    final newRate = fresh['rateKobo'] as int;
    final material = oldRate == 0 ? false : (newRate - oldRate).abs() / oldRate >= 0.001;
    final changed = lockValid ? false : (material || (locked && !lockValid));
    return {
      'quoteId': q['id'],
      'status': q['status'],
      'mode': q['mode'],
      'lockValid': lockValid,
      'secondsLeft': exp == null ? null : exp.difference(now).inSeconds.clamp(0, 1 << 30),
      'changed': changed,
      'reason': !changed ? null : (locked ? 'lock_expired' : 'rate_moved'),
      'direction': newRate > oldRate ? 'up' : newRate < oldRate ? 'down' : 'flat',
      'oldRateKobo': oldRate,
      'newRateKobo': newRate,
      'oldNetKobo': q['netKobo'],
      'newNetKobo': fresh['netKobo'],
      'oldGrossKobo': q['grossKobo'],
      'newGrossKobo': fresh['grossKobo'],
      'differenceKobo': (fresh['netKobo'] as int) - (q['netKobo'] as int),
      'newVersion': fresh['version'],
    };
  }

  /// Polled by the app while a customer is completing a trade.
  Json checkQuote(String token, String quoteId) => _read(() {
    final u = _user(token);
    return _compare(u, _ownQuote(u, quoteId));
  });

  /// Customer explicitly accepts the new rate. The acceptance and timestamp
  /// are recorded on the quote and in the audit log.
  Json acceptNewRate(String token, String quoteId, int expectedRateKobo) => _mutate(() {
    final u = _user(token);
    final q = _ownQuote(u, quoteId);
    if (q['status'] != 'open') throw ApiError('quote_closed', 'This trade is no longer open.');
    final cmp = _compare(u, q);
    if (cmp['newRateKobo'] != expectedRateKobo) {
      // The rate moved again while the customer was reading. Ask again.
      throw ApiError('rate_changed', 'The rate changed again. Please review the latest rate.', details: cmp);
    }
    final b = brandById(q['brandId'] as String);
    final fresh = _buildQuote(u, b, q['currency'] as String, q['cardType'] as String, q['faceValue'] as int, id: q['id'] as String);
    final acceptances = List<Json>.from((q['acceptances'] as List).cast<Map>().map((m) => Map<String, dynamic>.from(m)))
      ..add({
        'oldRateKobo': q['rateKobo'],
        'newRateKobo': fresh['rateKobo'],
        'oldNetKobo': q['netKobo'],
        'newNetKobo': fresh['netKobo'],
        'at': nowIso,
      });
    fresh['acceptances'] = acceptances;
    fresh['createdAt'] = q['createdAt'];
    db.put('quotes', fresh);
    _audit(u['id'] as String, 'trade.rate_accepted', q['id'] as String, {'old': q['rateKobo'], 'new': fresh['rateKobo']});
    return _ok({'quote': _quoteView(fresh)});
  });

  Json cancelQuote(String token, String quoteId, {String reason = 'customer_cancelled'}) => _mutate(() {
    final u = _user(token);
    final q = _ownQuote(u, quoteId);
    if (q['status'] != 'open') return _ok({'quote': q});
    q['status'] = 'cancelled';
    q['cancelledAt'] = nowIso;
    q['cancelReason'] = reason;
    db.put('quotes', q);
    // Recorded so history shows what happened. Nothing was submitted and no
    // money moved.
    final t = _newTxn(
      u,
      type: 'giftcard_sell',
      title: '${q['brand']} gift card',
      subtitle: '${currencySymbols[q['currency']]}${q['faceValue']} · Cancelled before submission',
      amount: 0,
      direction: 'credit',
      status: 'cancelled',
      details: {
        'quoteId': q['id'],
        'tracker': 'cancelled',
        'brand': q['brand'],
        'faceValue': q['faceValue'],
        'currency': q['currency'],
        'reason': reason == 'rate_change_declined' ? 'You declined a rate change' : 'You cancelled the trade',
      },
      timeline: [_step('Trade started'), _step('Cancelled', note: 'Not submitted. No card was sent and no money moved.')],
    );
    _audit(u['id'] as String, 'trade.cancelled', q['id'] as String, {'reason': reason});
    return _ok({'quote': q, 'txn': t});
  });

  Json submitGiftCardTrade(
    String token, {
    required String quoteId,
    required List<String> attachments,
    String? ecode,
    required String idempotencyKey,
    String? nonce,
    String? sentAt,
  }) => _mutate(() {
    _checkReplay(nonce, sentAt);
    final u = _user(token);
    final q = _ownQuote(u, quoteId);
    if (q['status'] == 'used') {
      final t = db.firstWhere('txns', (t) => (t['details'] as Map?)?['quoteId'] == q['id'] && t['status'] != 'cancelled');
      if (t != null) return _ok({'txn': t, 'replayed': true});
    }
    if (q['status'] != 'open') throw ApiError('quote_closed', 'This trade is no longer open. Start a new one.');
    // Server-side rate validation: never trust the price the app shows.
    final cmp = _compare(u, q);
    if (cmp['changed'] == true) {
      throw ApiError('rate_changed', 'Your rate has changed. Please confirm the new rate to continue.', details: cmp);
    }
    if (q['cardType'] == 'physical' && attachments.isEmpty) throw ApiError('missing_images', 'Add at least one photo of your card.');
    if (q['cardType'] == 'ecode' && (ecode == null || ecode.trim().length < 6) && attachments.isEmpty) {
      throw ApiError('missing_code', 'Enter the e-code or upload a screenshot.');
    }
    _checkLimits(u, q['netKobo'] as int);
    final t = _newTxn(
      u,
      type: 'giftcard_sell',
      title: '${q['brand']} gift card',
      subtitle: '${currencySymbols[q['currency']]}${_groupInt(q['faceValue'] as int)} ${q['currency']} · ${q['cardType'] == 'ecode' ? 'E-code' : 'Physical'}',
      amount: q['netKobo'] as int,
      fee: q['feeKobo'] as int,
      direction: 'credit',
      idempotencyKey: idempotencyKey,
      details: {
        'quoteId': q['id'],
        'brandId': q['brandId'],
        'brand': q['brand'],
        'currency': q['currency'],
        'faceValue': q['faceValue'],
        'cardType': q['cardType'],
        'rateKobo': q['rateKobo'],
        'boostKobo': q['boostKobo'],
        'vipKobo': q['vipKobo'],
        'grossKobo': q['grossKobo'],
        'mode': q['mode'],
        'acceptances': q['acceptances'],
        'attachments': attachments,
        'ecodeSealed': ecode == null || ecode.isEmpty ? null : _vault.seal(ecode.trim()),
        'eligibleUsdCents': q['eligibleUsdCents'],
        'tracker': 'submitted',
        'stageChangedAt': nowIso,
        'settlement': 'Pending review',
        'campaignId': q['campaignId'],
      },
      timeline: [_step('Submitted', note: 'We have your card details.')],
    );
    q['status'] = 'used';
    q['txnId'] = t['id'];
    db.put('quotes', q);
    _markGiftTraded(q);
    db.delete('drafts', u['id'] as String);
    _notify(u['id'] as String, 'transaction', 'Trade submitted', 'Your ${q['brand']} card is in the queue. We will update you at every step.', action: {'route': 'txn', 'id': t['id']});
    _audit(u['id'] as String, 'trade.submitted', t['id'] as String, {'quote': q['id']});
    return _ok({'txn': t});
  });

  static const tradeStages = [
    ('submitted', 'Submitted', 0),
    ('received', 'Received', 3),
    ('under_review', 'Under review', 4),
    ('approved', 'Approved', 5),
    ('payment_processing', 'Payment processing', 3),
    ('completed', 'Completed', 3),
  ];

  void _advanceTrade(Json t) {
    final d = t['details'] as Map;
    final stage = d['tracker'] as String;
    if (stage == 'action_required' || d['opsHold'] == true) return;
    final idx = tradeStages.indexWhere((s) => s.$1 == stage);
    if (idx < 0 || idx == tradeStages.length - 1) return;
    final next = tradeStages[idx + 1];
    final since = now.difference(DateTime.parse(d['stageChangedAt'] as String)).inSeconds;
    if (since < next.$3) return;
    d['tracker'] = next.$1;
    d['stageChangedAt'] = nowIso;
    (t['timeline'] as List).add(_step(next.$2));
    t['updatedAt'] = nowIso;
    if (next.$1 == 'completed') {
      _completeTrade(t);
      return;
    }
    db.put('txns', t);
    if (next.$1 == 'approved') {
      _notify(t['userId'] as String, 'transaction', 'Card approved', 'Your ${d['brand']} card was approved. Your payout is on its way.', action: {'route': 'txn', 'id': t['id']});
    }
  }

  void _completeTrade(Json t) {
    final uid = t['userId'] as String;
    final net = t['amount'] as int;
    final fee = t['fee'] as int;
    _post(t['id'] as String, 'NGN', {'sys:giftcard_desk': -(net + fee), 'sys:fees': fee, KnockServer.walletAcct(uid): net}, memo: 'Gift card payout');
    t['status'] = 'successful';
    (t['details'] as Map)['settlement'] = 'Settled to Naira wallet';
    db.put('txns', t);
    _notify(uid, 'transaction', 'Your payout is ready', '${_naira(net)} from your ${(t['details'] as Map)['brand']} card is in your wallet.', action: {'route': 'txn', 'id': t['id']});
    _onSettledTrade(db.get('users', uid)!, t);
  }

  /// Customer response to "Action required".
  Json respondToTradeAction(String token, String txnId, {required List<String> attachments, String note = ''}) => _mutate(() {
    final u = _user(token);
    final t = db.get('txns', txnId);
    if (t == null || t['userId'] != u['id']) throw ApiError('not_found', 'Transaction not found.');
    final d = t['details'] as Map;
    if (d['tracker'] != 'action_required') throw ApiError('bad_request', 'Nothing is needed on this trade right now.');
    if (attachments.isEmpty && note.trim().isEmpty) throw ApiError('bad_request', 'Add a photo or a note.');
    d['attachments'] = [...(d['attachments'] as List), ...attachments];
    d['tracker'] = 'under_review';
    d['stageChangedAt'] = nowIso;
    d['actionNeeded'] = null;
    (t['timeline'] as List).add(_step('Information received', note: note.isEmpty ? null : note));
    (t['timeline'] as List).add(_step('Under review'));
    db.put('txns', t);
    _audit(u['id'] as String, 'trade.action_response', txnId);
    return _ok({'txn': t});
  });

  Json saveTradeDraft(String token, Json draft) => _mutate(() {
    final u = _user(token);
    db.put('drafts', {'id': u['id'], 'draft': draft, 'savedAt': nowIso, 'reminded': false});
    return _ok();
  });

  Json tradeDraft(String token) => _read(() {
    final u = _user(token);
    return {'draft': db.get('drafts', u['id'] as String)};
  });

  Json clearTradeDraft(String token) => _mutate(() {
    final u = _user(token);
    db.delete('drafts', u['id'] as String);
    return _ok();
  });

  /// Last brands this customer sold, for contextual shortcuts.
  Json suggestions(String token) => _read(() {
    final u = _user(token);
    final counts = <String, int>{};
    final last = <String, Json>{};
    for (final t in db.where('txns', (t) => t['userId'] == u['id'] && t['type'] == 'giftcard_sell' && t['status'] != 'cancelled')) {
      final d = t['details'] as Map;
      final key = '${d['brandId']}|${d['currency']}';
      counts[key] = (counts[key] ?? 0) + 1;
      last[key] = {'brandId': d['brandId'], 'brand': d['brand'], 'currency': d['currency'], 'cardType': d['cardType'], 'faceValue': d['faceValue']};
    }
    final keys = counts.keys.toList()..sort((a, b) => counts[b]!.compareTo(counts[a]!));
    return {'items': [for (final k in keys.take(3)) {...last[k]!, 'count': counts[k]}]};
  });

  // ---- Watchlist ------------------------------------------------------------------

  Json watchlist(String token) => _read(() {
    final u = _user(token);
    final items = <Json>[];
    for (final w in db.where('watchlist', (w) => w['userId'] == u['id'])) {
      final b = brandById(w['brandId'] as String);
      items.add({...w, 'rate': _rateView(u, b, w['currency'] as String)});
    }
    items.sort((a, b) => (a['createdAt'] as String).compareTo(b['createdAt'] as String));
    return {'items': items};
  });

  Json setWatch(String token, {required String brandId, required String currency, required bool watch, int? targetRate, String direction = 'any'}) =>
      _mutate(() {
        final u = _user(token);
        final id = '${u['id']}|$brandId|$currency';
        if (!watch) {
          db.delete('watchlist', id);
          return _ok();
        }
        brandById(brandId);
        if (targetRate != null && (targetRate < 100 || targetRate > 100000)) throw ApiError('bad_target', 'Enter a realistic target rate.');
        final existing = db.get('watchlist', id);
        db.put('watchlist', {
          'id': id,
          'userId': u['id'],
          'brandId': brandId,
          'currency': currency,
          'targetRate': targetRate,
          'direction': direction,
          'createdAt': existing?['createdAt'] ?? nowIso,
          'lastAlertAt': existing?['lastAlertAt'],
          'lastSeenRate': _rateRow(brandId, currency)['rate'],
        });
        return _ok();
      });

  /// Moves a rate (pricing engine update). Bumps the version so open
  /// indicative quotes see the change.
  void _moveRate(String brandId, String currency, int newRate, {String actor = 'pricing_engine'}) {
    final r = _rateRow(brandId, currency);
    final old = r['rate'] as int;
    if (newRate == old) return;
    final history = List<Json>.from((r['history'] as List? ?? []).cast<Map>().map((m) => Map<String, dynamic>.from(m)))
      ..add({'rate': newRate, 'at': nowIso});
    if (history.length > 12) history.removeAt(0);
    db.put('rates', {
      ...r,
      'previousRate': old,
      'rate': newRate,
      'version': (r['version'] as int) + 1,
      'updatedAt': nowIso,
      'history': history,
    });
    _audit(actor, 'rate.update', '$brandId|$currency', {'old': old, 'new': newRate});
    // Rate watchlist alerts.
    for (final w in db.where('watchlist', (w) => w['brandId'] == brandId && w['currency'] == currency).toList()) {
      final target = w['targetRate'] as int?;
      final last = w['lastAlertAt'] == null ? null : DateTime.parse(w['lastAlertAt'] as String);
      if (last != null && now.difference(last) < const Duration(minutes: 2)) continue;
      final up = newRate > old;
      bool fire;
      if (target != null) {
        fire = (w['direction'] != 'down' && old < target && newRate >= target) || (w['direction'] != 'up' && old > target && newRate <= target);
      } else {
        fire = (newRate - old).abs() / old >= 0.005;
      }
      if (!fire) continue;
      final b = brandById(brandId);
      final u = db.get('users', w['userId'] as String);
      final chief = (u?['prefs'] as Map?)?['heyChief'] != false;
      _notify(
        w['userId'] as String,
        'rate_alert',
        up ? (chief ? 'Hey Chief! ${b.name} rate is up' : '${b.name} rate is up') : '${b.name} rate changed',
        '${b.name} $currency is now ₦${_groupInt(newRate)}/${currencySymbols[currency]} (was ₦${_groupInt(old)}).',
        action: {'route': 'rates', 'brandId': brandId},
      );
      db.put('watchlist', {...w, 'lastAlertAt': nowIso, 'lastSeenRate': newRate});
    }
  }

  void _runRateFeed() {
    final meta = db.get('meta', 'rates') ?? {'id': 'rates', 'last': nowIso, 'cryptoLast': nowIso};
    final last = DateTime.parse(meta['last'] as String);
    if (now.difference(last) >= const Duration(seconds: 75)) {
      final b = giftBrands[_rng.nextInt(giftBrands.length)];
      final c = b.rates.keys.elementAt(_rng.nextInt(b.rates.length));
      final r = _rateRow(b.id, c)['rate'] as int;
      final step = (_rng.nextInt(12) + 3) * (_rng.nextBool() ? 1 : -1);
      final base = b.rates[c]!;
      final next = (r + step).clamp((base * 0.92).round(), (base * 1.08).round());
      _moveRate(b.id, c, next);
      meta['last'] = nowIso;
    }
    final cl = DateTime.parse(meta['cryptoLast'] as String);
    if (now.difference(cl) >= const Duration(seconds: 20)) {
      for (final a in cryptoAssets) {
        if (a.symbol == 'USDT' || a.symbol == 'USDC') continue;
        final row = db.get('crypto_prices', a.symbol) ?? {'id': a.symbol, 'usd': a.usdPrice, 'open': a.usdPrice};
        final usd = (row['usd'] as num).toDouble() * (1 + (_rng.nextDouble() - 0.5) * 0.004);
        row['usd'] = double.parse(usd.toStringAsFixed(2));
        row['change24h'] = ((usd - (row['open'] as num)) / (row['open'] as num) * 100);
        row['updatedAt'] = nowIso;
        db.put('crypto_prices', row);
      }
      meta['cryptoLast'] = nowIso;
    }
    db.put('meta', meta);
  }
}
