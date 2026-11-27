part of 'server.dart';

/// Notifications, support tickets, disputes, account deletion and reminders.
extension SupportApi on KnockServer {
  static const supportPhone = '+447575895007';

  // ---- Notifications ----------------------------------------------------------------

  Json notifications(String token, {String? kind}) => _read(() {
    final u = _user(token);
    final list = db
        .where('notifications', (n) => n['userId'] == u['id'] && (kind == null || n['kind'] == kind))
        .toList()
      ..sort((a, b) => (b['createdAt'] as String).compareTo(a['createdAt'] as String));
    return {'items': list.take(100).toList(), 'unread': list.where((n) => n['read'] != true).length};
  });

  Json unreadCount(String token) => _read(() {
    final u = _user(token, requireVerifiedEmail: false);
    return {'unread': db.where('notifications', (n) => n['userId'] == u['id'] && n['read'] != true).length};
  });

  Json markRead(String token, String id) => _mutate(() {
    final u = _user(token);
    final n = db.get('notifications', id);
    if (n == null || n['userId'] != u['id']) throw ApiError('not_found', 'Notification not found.');
    n['read'] = true;
    db.put('notifications', n);
    return _ok();
  });

  Json markAllRead(String token) => _mutate(() {
    final u = _user(token);
    for (final n in db.where('notifications', (n) => n['userId'] == u['id'] && n['read'] != true).toList()) {
      n['read'] = true;
    }
    return _ok();
  });

  // ---- Support tickets and disputes --------------------------------------------------

  Json createTicket(
    String token, {
    required String category,
    required String subject,
    required String description,
    String? txnId,
    List<String> attachments = const [],
    bool dispute = false,
  }) => _mutate(() {
    final u = _user(token);
    _rateLimit('ticket:${u['id']}', 10, const Duration(hours: 1));
    if (description.trim().length < 10) throw ApiError('too_short', 'Tell us a little more so we can help (at least 10 characters).');
    Json? t;
    if (txnId != null) {
      t = db.get('txns', txnId);
      if (t == null || t['userId'] != u['id']) throw ApiError('not_found', 'Transaction not found.');
      if (dispute && db.firstWhere('tickets', (x) => x['txnId'] == txnId && x['kind'] == 'dispute' && x['status'] != 'resolved' && x['status'] != 'closed') != null) {
        throw ApiError('exists', 'There is already an open case for this transaction.');
      }
    }
    final ticket = {
      'id': newId('tkt'),
      'reference': newReference(dispute ? 'CASE' : 'TKT'),
      'userId': u['id'],
      'kind': dispute ? 'dispute' : 'ticket',
      'category': category,
      'subject': subject.trim().isEmpty ? category : subject.trim(),
      'description': description.trim(),
      'txnId': txnId,
      'txnRef': t?['reference'],
      'attachments': attachments,
      'status': 'open',
      'priority': _vipLevel(u).id == 'silver' ? 'normal' : 'priority',
      'messages': [
        {'from': 'customer', 'body': description.trim(), 'at': nowIso, 'attachments': attachments},
      ],
      'history': [
        {'status': 'open', 'at': nowIso, 'label': 'Case opened'},
      ],
      'createdAt': nowIso,
      'updatedAt': nowIso,
    };
    db.insert('tickets', ticket);
    _notify(u['id'] as String, 'transaction', dispute ? 'Case ${ticket['reference']} opened' : 'Ticket ${ticket['reference']} received', 'We have your message and will reply here. You can track it in Support.', action: {'route': 'ticket', 'id': ticket['id']});
    _audit(u['id'] as String, dispute ? 'dispute.opened' : 'ticket.opened', ticket['id'] as String);
    return _ok({'ticket': ticket});
  });

  Json tickets(String token, {String? kind}) => _read(() {
    final u = _user(token);
    final list = db.where('tickets', (t) => t['userId'] == u['id'] && (kind == null || t['kind'] == kind)).toList()
      ..sort((a, b) => (b['updatedAt'] as String).compareTo(a['updatedAt'] as String));
    return {'items': list};
  });

  Json ticket(String token, String id) => _read(() {
    final u = _user(token);
    final t = db.get('tickets', id);
    if (t == null || t['userId'] != u['id']) throw ApiError('not_found', 'Ticket not found.');
    return {'ticket': t};
  });

  Json replyTicket(String token, String id, String body, {List<String> attachments = const []}) => _mutate(() {
    final u = _user(token);
    final t = db.get('tickets', id);
    if (t == null || t['userId'] != u['id']) throw ApiError('not_found', 'Ticket not found.');
    if (t['status'] == 'closed') throw ApiError('closed', 'This case is closed. Open a new one if you still need help.');
    if (body.trim().isEmpty && attachments.isEmpty) throw ApiError('empty', 'Write a message first.');
    (t['messages'] as List).add({'from': 'customer', 'body': body.trim(), 'at': nowIso, 'attachments': attachments});
    if (t['status'] == 'awaiting_customer' || t['status'] == 'resolved') {
      t['status'] = 'in_progress';
      (t['history'] as List).add({'status': 'in_progress', 'at': nowIso, 'label': 'Reopened by you'});
    }
    t['updatedAt'] = nowIso;
    t['agentReplyDue'] = now.add(const Duration(seconds: 8)).toIso8601String();
    db.put('tickets', t);
    return _ok({'ticket': t});
  });

  Json closeTicket(String token, String id) => _mutate(() {
    final u = _user(token);
    final t = db.get('tickets', id);
    if (t == null || t['userId'] != u['id']) throw ApiError('not_found', 'Ticket not found.');
    t['status'] = 'closed';
    (t['history'] as List).add({'status': 'closed', 'at': nowIso, 'label': 'Closed by you'});
    t['updatedAt'] = nowIso;
    db.put('tickets', t);
    return _ok({'ticket': t});
  });

  void _runSupportJobs() {
    for (final t in db.table('tickets').values) {
      final age = now.difference(DateTime.parse(t['createdAt'] as String)).inSeconds;
      if (t['status'] == 'open' && age >= 6) {
        t['status'] = 'in_progress';
        (t['history'] as List).add({'status': 'in_progress', 'at': nowIso, 'label': 'Assigned to a specialist'});
        (t['messages'] as List).add({
          'from': 'agent',
          'agent': 'Knock Support (sandbox)',
          'body': t['kind'] == 'dispute'
              ? 'Thanks for reporting this. We have linked your case to ${t['txnRef'] ?? 'your account'} and a specialist is reviewing it now. We will update you here.'
              : 'Thanks for getting in touch. A member of our team is looking into this and will reply here.',
          'at': nowIso,
        });
        t['updatedAt'] = nowIso;
        _notify(t['userId'] as String, 'transaction', 'Update on ${t['reference']}', 'A specialist is now handling your case.', action: {'route': 'ticket', 'id': t['id']});
      }
      final due = t['agentReplyDue'] == null ? null : DateTime.parse(t['agentReplyDue'] as String);
      if (due != null && now.isAfter(due)) {
        t['agentReplyDue'] = null;
        (t['messages'] as List).add({
          'from': 'agent',
          'agent': 'Knock Support (sandbox)',
          'body': 'Thanks, we have received your update and added it to your case.',
          'at': nowIso,
        });
        t['updatedAt'] = nowIso;
      }
    }
  }

  // ---- Account deletion -----------------------------------------------------------------

  List<Json> _deletionBlockers(Json u) {
    final uid = u['id'] as String;
    final out = <Json>[];
    final bal = balanceOf(KnockServer.walletAcct(uid));
    if (bal > 0) out.add({'code': 'balance', 'label': 'Withdraw your wallet balance of ${_naira(bal)} first.'});
    var crypto = 0;
    for (final a in cryptoAssets) {
      crypto += balanceOf(KnockServer.cryptoAcct(uid, a.symbol));
    }
    if (crypto > 0) out.add({'code': 'crypto', 'label': 'Sell or withdraw your crypto balance first.'});
    final pending = db.where('txns', (t) => t['userId'] == uid && t['status'] == 'pending').length;
    if (pending > 0) out.add({'code': 'pending', 'label': 'Wait for $pending pending transaction${pending == 1 ? '' : 's'} to finish.'});
    final open = db.where('tickets', (t) => t['userId'] == uid && t['status'] != 'resolved' && t['status'] != 'closed').length;
    if (open > 0) out.add({'code': 'tickets', 'label': 'Close or resolve $open open support request${open == 1 ? '' : 's'}.'});
    final gifts = db.where('gifts', (g) => g['recipientId'] == uid && (g['status'] == 'delivered' || g['status'] == 'opened')).length;
    if (gifts > 0) out.add({'code': 'gifts', 'label': 'Use or trade $gifts unused gift${gifts == 1 ? '' : 's'}, or they will be lost.', 'warning': true});
    return out;
  }

  Json deletionCheck(String token) => _read(() {
    final u = _user(token);
    final req = db.firstWhere('deletions', (d) => d['userId'] == u['id'] && d['status'] != 'cancelled');
    return {
      'blockers': _deletionBlockers(u),
      'request': req,
      'bonusForfeit': balanceOf(KnockServer.bonusAcct(u['id'] as String)),
      'retention': [
        'Transaction records are kept for at least 5 years after closure, as required by anti-money-laundering law.',
        'Identity verification results are kept for the same period. Raw BVN and NIN are never stored.',
        'Your profile, photo, preferences and marketing data are deleted.',
        'Support conversations are kept for 2 years, then deleted.',
      ],
    };
  });

  Json requestDeletion(String token, {required String password, required String confirmation, String reason = ''}) => _mutate(() {
    final u = _user(token);
    if (!_checkPassword(u, password)) {
      _audit(u['id'] as String, 'deletion.reauth_failed', u['id'] as String);
      throw ApiError('bad_credentials', 'That password is not correct.');
    }
    if (confirmation.trim().toUpperCase() != 'DELETE') throw ApiError('confirm', 'Type DELETE to confirm.');
    final existing = db.firstWhere('deletions', (d) => d['userId'] == u['id'] && (d['status'] == 'scheduled' || d['status'] == 'action_needed'));
    if (existing != null) return _ok({'request': existing});
    final blockers = _deletionBlockers(u).where((b) => b['warning'] != true).toList();
    final req = {
      'id': newId('del'),
      'reference': newReference('DEL'),
      'userId': u['id'],
      'status': blockers.isEmpty ? 'scheduled' : 'action_needed',
      'blockers': blockers,
      'reason': reason,
      'createdAt': nowIso,
      'scheduledFor': blockers.isEmpty ? now.add(const Duration(days: 14)).toIso8601String() : null,
      'history': [
        {'label': 'Request received', 'at': nowIso},
        if (blockers.isEmpty) {'label': 'Scheduled. You can cancel any time in the next 14 days.', 'at': nowIso}
        else {'label': 'Action needed before we can close your account', 'at': nowIso},
      ],
    };
    db.insert('deletions', req);
    if (blockers.isEmpty) {
      u['status'] = 'closing';
      db.put('users', u);
    }
    _notify(u['id'] as String, 'security', 'Account deletion requested', blockers.isEmpty ? 'Your account will be closed on ${Fmt2.dateTime(now.add(const Duration(days: 14)))}. Log in and cancel if you change your mind.' : 'We need you to resolve a few things before your account can be closed.');
    _outbox(u['id'] as String, 'email', u['email'] as String, 'Your account deletion request', 'We received a request to delete your Knock account. Reference ${req['reference']}.');
    _audit(u['id'] as String, 'deletion.requested', req['id'] as String);
    return _ok({'request': req});
  });

  Json recheckDeletion(String token) => _mutate(() {
    final u = _user(token);
    final req = db.firstWhere('deletions', (d) => d['userId'] == u['id'] && d['status'] == 'action_needed');
    if (req == null) throw ApiError('not_found', 'No request needs action.');
    final blockers = _deletionBlockers(u).where((b) => b['warning'] != true).toList();
    req['blockers'] = blockers;
    if (blockers.isEmpty) {
      req['status'] = 'scheduled';
      req['scheduledFor'] = now.add(const Duration(days: 14)).toIso8601String();
      (req['history'] as List).add({'label': 'Scheduled. You can cancel any time in the next 14 days.', 'at': nowIso});
      u['status'] = 'closing';
      db.put('users', u);
    }
    db.put('deletions', req);
    return _ok({'request': req});
  });

  Json cancelDeletion(String token) => _mutate(() {
    final u = _user(token);
    final req = db.firstWhere('deletions', (d) => d['userId'] == u['id'] && (d['status'] == 'scheduled' || d['status'] == 'action_needed'));
    if (req == null) throw ApiError('not_found', 'There is no deletion request to cancel.');
    req['status'] = 'cancelled';
    (req['history'] as List).add({'label': 'Cancelled by you', 'at': nowIso});
    db.put('deletions', req);
    u['status'] = 'active';
    db.put('users', u);
    _audit(u['id'] as String, 'deletion.cancelled', req['id'] as String);
    return _ok({'request': req});
  });

  /// Closes the account: personal data is erased, financial records kept.
  void _completeDeletion(Json req) {
    final u = db.get('users', req['userId'] as String);
    if (u == null) return;
    u
      ..['status'] = 'closed'
      ..['fullName'] = 'Closed Account'
      ..['email'] = 'closed+${sha256Hex(u['email'] as String).substring(0, 12)}@deleted.knock'
      ..['phone'] = null
      ..['avatar'] = null
      ..['username'] = 'closed_${(u['id'] as String).substring(4, 10)}'
      ..['prefs'] = {}
      ..['marketingConsent'] = false
      ..['closedAt'] = nowIso;
    db.put('users', u);
    _revokeAllSessions(u['id'] as String, 'account_closed');
    for (final n in db.where('notifications', (n) => n['userId'] == u['id']).toList()) {
      db.delete('notifications', n['id'] as String);
    }
    req['status'] = 'completed';
    req['completedAt'] = nowIso;
    (req['history'] as List).add({'label': 'Account closed. Required financial records retained.', 'at': nowIso});
    db.put('deletions', req);
    _audit('system', 'deletion.completed', req['id'] as String);
  }

  // ---- Reminders and win-back ------------------------------------------------------------

  void _runReminderJobs() {
    for (final u in db.table('users').values) {
      if (u['status'] != 'active' || u['sandboxSeed'] == true || u['emailVerified'] != true) continue;
      final uid = u['id'] as String;
      final prefs = (u['prefs'] as Map?) ?? {};
      if (prefs['reminder'] == false) continue;
      final age = now.difference(DateTime.parse(u['createdAt'] as String));
      // Pending verification (once).
      if ((u['tier'] as int) < 2 && age > const Duration(minutes: 10) && _once('rem:verify:$uid')) {
        _notify(uid, 'reminder', 'Unlock withdrawals', 'Verify your BVN and NIN to withdraw to your bank and raise your limits. It takes about two minutes.', action: {'route': 'verification'}, push: false);
      }
      // Incomplete trade.
      final d = db.get('drafts', uid);
      if (d != null && d['reminded'] != true && now.difference(DateTime.parse(d['savedAt'] as String)) > const Duration(minutes: 3)) {
        d['reminded'] = true;
        db.put('drafts', d);
        final brand = (d['draft'] as Map)['brand'] ?? 'gift card';
        _notify(uid, 'reminder', 'Finish your $brand trade', 'You started a trade but did not submit it. Pick up where you left off.', action: {'route': 'sell', 'draft': true});
      }
      // Unclaimed rewards.
      final unclaimed = _challengeStates(u).where((c) => c['state'] == 'completed').toList();
      if (unclaimed.isNotEmpty && _once('rem:claim:$uid:${unclaimed.map((c) => '${c['id']}${c['periodKey']}').join()}', after: const Duration(minutes: 5))) {
        _notify(uid, 'reminder', 'You have rewards to claim', 'Claim ${unclaimed.fold<int>(0, (a, c) => a + (c['points'] as int))} Knock Points in Knockout.', action: {'route': 'knockout'});
      }
      // Win-back: inactive for 14 days, only with marketing consent.
      final last = DateTime.parse(u['lastActiveAt'] as String);
      if (u['marketingConsent'] == true && prefs['campaign'] == true && now.difference(last) > const Duration(days: 14) && _once('winback:$uid:${last.toIso8601String().substring(0, 10)}')) {
        _notify(uid, 'campaign', 'We have missed you', 'Check today\'s gift card rates. Your next trade could be one tap away.', action: {'route': 'rates'});
        if (prefs['email'] != false) _outbox(uid, 'email', u['email'] as String, 'Today\'s rates on Knock', 'See today\'s gift card rates on Knock. Unsubscribe any time in Settings.');
      }
    }
  }

  /// True the first time [key] is seen (optionally only after [after] has
  /// passed since the key was first considered).
  bool _once(String key, {Duration? after}) {
    final existing = db.get('notices', key);
    if (existing == null) {
      db.insert('notices', {'id': key, 'at': nowIso, 'fired': after == null});
      return after == null;
    }
    if (existing['fired'] == true) return false;
    if (after != null && now.difference(DateTime.parse(existing['at'] as String)) >= after) {
      existing['fired'] = true;
      db.put('notices', existing);
      return true;
    }
    return false;
  }
}
