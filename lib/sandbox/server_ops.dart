part of 'server.dart';

/// Operations endpoints. In production these sit behind the staff console
/// with role-based access control. In the sandbox they power the
/// "Sandbox tools" screen so testers can play the operations team.
extension OpsApi on KnockServer {
  /// Sandbox only: a session for the seeded operations user.
  String sandboxOpsToken() {
    final ops = db.firstWhere('users', (u) => u['role'] == 'ops')!;
    return _openSession(ops, 'ops-console', 'Sandbox ops console');
  }

  /// Sandbox inbox: emails and SMS that would have been sent to [token]'s
  /// user. Lets testers read verification codes.
  Json sandboxInbox(String token) => _read(() {
    final s = _session(token);
    final u = db.get('users', s['userId'] as String)!;
    final list = db
        .where('outbox', (m) => m['userId'] == u['id'] || m['to'] == u['email'] || (m['to'] == u['pendingPhone']) || m['to'] == u['phone'])
        .where((m) => m['channel'] != 'push')
        .toList()
      ..sort((a, b) => (b['seq'] as int).compareTo(a['seq'] as int));
    return {'items': list.take(30).toList()};
  });

  /// Pre-login inbox lookup for password reset testing.
  Json sandboxInboxFor(String email) => _read(() {
    final mail = email.trim().toLowerCase();
    final list = db.where('outbox', (m) => m['to'] == mail).toList()..sort((a, b) => (b['seq'] as int).compareTo(a['seq'] as int));
    return {'items': list.take(10).toList()};
  });

  Json opsMoveRate(String opsToken, String brandId, String currency, int deltaNgn) => _mutate(() {
    _requireRole(opsToken, 'ops');
    final r = _rateRow(brandId, currency);
    _moveRate(brandId, currency, (r['rate'] as int) + deltaNgn, actor: 'ops');
    return _ok({'rate': _rateRow(brandId, currency)});
  });

  Json opsTrade(String opsToken, String txnId, String action, {String? note}) => _mutate(() {
    _requireRole(opsToken, 'ops');
    final t = db.get('txns', txnId);
    if (t == null || t['type'] != 'giftcard_sell') throw ApiError('not_found', 'Trade not found.');
    final d = t['details'] as Map;
    switch (action) {
      case 'action_required':
        if (t['status'] != 'pending') throw ApiError('bad_state', 'Only pending trades can be put on hold.');
        d['tracker'] = 'action_required';
        d['actionNeeded'] = note ?? 'Please upload a clearer photo of the back of the card, with the code and PIN fully visible.';
        (t['timeline'] as List).add(_step('Action required', note: d['actionNeeded'] as String));
        db.put('txns', t);
        _notify(t['userId'] as String, 'transaction', 'Action needed on your trade', d['actionNeeded'] as String, action: {'route': 'txn', 'id': t['id']});
      case 'fail':
        if (t['status'] != 'pending') throw ApiError('bad_state', 'Only pending trades can be declined.');
        d['tracker'] = 'failed';
        d['failReason'] = note ?? 'The card had already been redeemed.';
        _setTxnStatus(t, 'failed', step: 'Failed', note: d['failReason'] as String);
        _notify(t['userId'] as String, 'transaction', 'Trade unsuccessful', 'We could not complete your ${d['brand']} trade: ${d['failReason']}', action: {'route': 'txn', 'id': t['id']});
      case 'approve_now':
        if (t['status'] != 'pending') throw ApiError('bad_state', 'Trade is not pending.');
        for (var i = 0; i < TradeApi.tradeStages.length && t['status'] == 'pending'; i++) {
          d['stageChangedAt'] = now.subtract(const Duration(minutes: 1)).toIso8601String();
          d['opsHold'] = false;
          if (d['tracker'] == 'action_required') d['tracker'] = 'under_review';
          _advanceTrade(t);
        }
      default:
        throw ApiError('bad_request', 'Unknown action.');
    }
    _audit('ops', 'ops.trade_$action', txnId);
    return _ok({'txn': t});
  });

  /// Reverses a completed trade (e.g. chargeback or fraud). Any welcome bonus
  /// earned from it is reversed too.
  Json opsReverse(String opsToken, String txnId, {String reason = 'Card reported as fraudulent by issuer'}) => _mutate(() {
    _requireRole(opsToken, 'ops');
    final t = db.get('txns', txnId);
    if (t == null || t['status'] != 'successful') throw ApiError('bad_state', 'Only successful transactions can be reversed.');
    final uid = t['userId'] as String;
    final amt = t['amount'] as int;
    if (t['type'] == 'giftcard_sell' || t['type'] == 'deposit') {
      // Customer balance may go negative here in real life; the sandbox
      // only reverses what is still in the wallet.
      final available = balanceOf(KnockServer.walletAcct(uid));
      final take = amt.clamp(0, available);
      if (take > 0) _post('${t['id']}-rev', 'NGN', {KnockServer.walletAcct(uid): -take, 'sys:reversals': take}, memo: 'Reversal');
      if (take < amt) (t['details'] as Map)['recoveryDue'] = amt - take;
    }
    _setTxnStatus(t, 'reversed', step: 'Reversed', note: reason);
    (t['details'] as Map)['tracker'] = 'reversed';
    final bonus = db.firstWhere('reward_grants', (g) => g['kind'] == 'welcome' && g['sourceTxnId'] == txnId && g['status'] == 'credited');
    if (bonus != null) {
      final bal = balanceOf(KnockServer.bonusAcct(uid));
      final back = (bonus['amount'] as int).clamp(0, bal);
      if (back > 0) _post('${bonus['id']}-rev', 'NGN', {KnockServer.bonusAcct(uid): -back, 'sys:rewards': back}, memo: 'Bonus reversal');
      bonus['status'] = 'reversed';
      db.put('reward_grants', bonus);
      final bt = db.get('txns', bonus['txnId'] as String);
      if (bt != null) _setTxnStatus(bt, 'reversed', step: 'Reversed', note: 'The qualifying trade was reversed.');
    }
    _refreshReferral(uid);
    _notify(uid, 'transaction', 'Transaction reversed', '${t['title']} (${t['reference']}) was reversed: $reason', action: {'route': 'txn', 'id': t['id']});
    _audit('ops', 'ops.reverse', txnId, {'reason': reason});
    return _ok({'txn': t});
  });

  Json opsCompleteDeletions(String opsToken) => _mutate(() {
    _requireRole(opsToken, 'ops');
    var n = 0;
    for (final r in db.where('deletions', (d) => d['status'] == 'scheduled').toList()) {
      _completeDeletion(r);
      n++;
    }
    return _ok({'completed': n});
  });

  Json opsReleaseRewards(String opsToken) => _mutate(() {
    _requireRole(opsToken, 'ops');
    for (final r in db.where('referrals', (r) => r['rewardStatus'] == 'pending')) {
      r['releaseAt'] = nowIso;
    }
    _runRewardJobs();
    return _ok();
  });

  Json opsClearHold(String opsToken, String userId) => _mutate(() {
    _requireRole(opsToken, 'ops');
    final u = db.get('users', userId);
    if (u == null) throw ApiError('not_found', 'User not found.');
    u['securityHoldUntil'] = null;
    u['pinLockedUntil'] = null;
    db.put('users', u);
    return _ok();
  });

  /// Sandbox: a gift from the test sender to the given user.
  Json opsSendTestGift(String opsToken, String userId) => _mutate(() {
    _requireRole(opsToken, 'ops');
    final sender = db.firstWhere('users', (u) => u['email'] == 'gifts@sandbox.knock')!;
    final r = db.get('users', userId)!;
    const b = 'amazon';
    final brand = brandById(b);
    final g = {
      'id': newId('gft'),
      'reference': newReference('GFT'),
      'senderId': sender['id'],
      'senderName': 'Uncle Tunde (sandbox)',
      'recipientId': r['id'],
      'recipientName': publicName(r['fullName'] as String),
      'recipientType': 'username',
      'recipientHandle': r['username'],
      'brandId': b,
      'brand': brand.name,
      'color': brand.color,
      'glyph': brand.glyph,
      'currency': 'USD',
      'value': 100,
      'message': 'Happy birthday! Treat yourself. (Sandbox test gift)',
      'status': 'sent',
      'codeSealed': _vault.seal('AMZN-SANDBOX-${randomToken(6).toUpperCase()}'),
      'claimTokenHash': null,
      'claimExpiresAt': null,
      'expiresAt': now.add(const Duration(days: 365)).toIso8601String(),
      'txnId': null,
      'priceKobo': 0,
      'events': [
        {'status': 'payment_pending', 'at': nowIso},
        {'status': 'preparing', 'at': nowIso},
        {'status': 'sent', 'at': nowIso},
      ],
      'createdAt': nowIso,
      'updatedAt': now.subtract(const Duration(seconds: 5)).toIso8601String(),
      'owners': [sender['id']],
    };
    db.insert('gifts', g);
    return _ok({'gift': g['id']});
  });

  Json opsAudit(String opsToken, {int limit = 60}) => _read(() {
    _requireRole(opsToken, 'ops');
    final list = db.table('audit').values.toList()..sort((a, b) => (b['at'] as String).compareTo(a['at'] as String));
    return {'items': list.take(limit).toList()};
  });

  Json opsPendingTrades(String opsToken) => _read(() {
    _requireRole(opsToken, 'ops');
    final list = db.where('txns', (t) => t['type'] == 'giftcard_sell' && t['status'] == 'pending').toList()
      ..sort((a, b) => (b['createdAt'] as String).compareTo(a['createdAt'] as String));
    return {'items': list};
  });

  /// Reconciliation: every journal balances, and each customer wallet equals
  /// the sum of its ledger lines (no balance is stored anywhere else).
  Json reconcile(String opsToken) => _read(() {
    _requireRole(opsToken, 'ops');
    final byTxn = <String, Map<String, int>>{};
    for (final e in db.table('entries').values) {
      final k = (e['txnId'] as String).replaceAll('-rev', '');
      final m = byTxn.putIfAbsent('$k|${e['currency']}', () => {});
      m['sum'] = (m['sum'] ?? 0) + (e['amount'] as int);
    }
    final unbalanced = byTxn.entries.where((e) => e.value['sum'] != 0).map((e) => e.key).toList();
    final totals = <String, int>{};
    for (final e in db.table('entries').values) {
      totals[e['currency'] as String] = (totals[e['currency'] as String] ?? 0) + (e['amount'] as int);
    }
    var negative = 0;
    final accounts = <String>{for (final e in db.table('entries').values) e['account'] as String};
    for (final a in accounts.where((a) => a.startsWith('u:'))) {
      if (balanceOf(a) < 0) negative++;
    }
    return {
      'journals': byTxn.length,
      'unbalanced': unbalanced,
      'currencyTotals': totals,
      'negativeCustomerAccounts': negative,
      'ok': unbalanced.isEmpty && totals.values.every((v) => v == 0) && negative == 0,
      'at': nowIso,
    };
  });
}
