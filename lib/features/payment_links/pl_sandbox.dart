import 'dart:math';

import 'package:material_ui/material_ui.dart';

import 'pl_models.dart';
import 'pl_split.dart';

/// In-app SANDBOX for Payment Links.
///
/// This mirrors the real engine in backend/supabase/migrations (same split
/// maths, same double-entry postings, same idempotency keys, same states) so
/// the demo behaves like the product. No real money, provider or blockchain
/// is involved: "payments" are simulated, and every screen says SANDBOX.
class PlSandbox extends ChangeNotifier {
  PlSandbox({bool seed = true, DateTime Function()? clock}) : _clock = clock ?? DateTime.now {
    _seedUsers();
    if (seed) _seedDemo();
  }

  static final PlSandbox instance = PlSandbox();

  final DateTime Function() _clock;
  final _rng = Random(7);
  DateTime get now => _clock();

  // ---------------------------------------------------------------- users
  final Map<String, KnockUser> _users = {};
  late KnockUser me;
  final Set<String> _frozen = {};

  void _seedUsers() {
    for (final u in const [
      KnockUser(id: 'u_chanor', username: 'chanor', displayName: 'Chanor', initials: 'CH', verified: true),
      KnockUser(id: 'u_mary', username: 'mary', displayName: 'Mary Okafor', initials: 'MO', verified: true),
      KnockUser(id: 'u_innocent', username: 'innocent', displayName: 'Innocent Eze', initials: 'IE', verified: true),
      KnockUser(id: 'u_favour', username: 'favour', displayName: 'Favour Adeyemi', initials: 'FA', verified: true),
      KnockUser(id: 'u_tunde', username: 'tunde', displayName: 'Tunde Bakare', initials: 'TB', verified: true),
      KnockUser(id: 'u_ada', username: 'ada', displayName: 'Ada Nwosu', initials: 'AN', verified: true),
      KnockUser(id: 'u_david', username: 'david', displayName: 'David Musa', initials: 'DM', verified: false),
    ]) {
      _users[u.id] = u;
    }
    me = _users['u_chanor']!;
  }

  KnockUser user(String id) {
    final u = _users[id]!;
    return KnockUser(id: u.id, username: u.username, displayName: u.displayName, initials: u.initials, verified: u.verified, frozen: _frozen.contains(id));
  }

  List<KnockUser> get allUsers => [for (final id in _users.keys) user(id)];

  /// Exact username lookup, minimum fields only (no phone, email, BVN).
  Future<KnockUser?> lookup(String username) async {
    await Future<void>.delayed(const Duration(milliseconds: 250));
    final q = username.trim().toLowerCase().replaceFirst('@', '');
    if (q.isEmpty) return null;
    for (final u in _users.values) {
      if (u.username == q) return user(u.id);
    }
    return null;
  }

  /// Sandbox control: freeze a recipient to see failed credits roll back and retry.
  void setFrozen(String userId, bool frozen) {
    frozen ? _frozen.add(userId) : _frozen.remove(userId);
    _audit('staff', frozen ? 'user.frozen' : 'user.unfrozen', detail: '@${_users[userId]!.username}');
    notifyListeners();
  }

  // ---------------------------------------------------------------- ledger
  /// Signed sums per account: positive = debit, negative = credit.
  final Map<String, int> _acct = {};
  final List<LedgerEntry> entries = [];
  final Map<String, LedgerEntry> _byKey = {};

  static const _debitNormal = {'provider_clearing', 'settlement_bank', 'recovery_receivable', 'provider_fee_expense'};

  int balance(String account) {
    final raw = _acct[account] ?? 0;
    return _debitNormal.contains(account.split(':').first) ? raw : -raw;
  }

  String _a(String purpose, String owner, String cur) => '$purpose:$owner:$cur';

  /// Idempotent, balanced posting. Replaying a key posts nothing.
  LedgerEntry _post(String key, String kind, String cur, List<(String, int)> lines, {String? linkId, String? paymentId}) {
    final existing = _byKey[key];
    if (existing != null) return existing;
    final sum = lines.fold<int>(0, (a, l) => a + l.$2);
    if (sum != 0) throw StateError('unbalanced entry $key ($sum)');
    for (final (acct, amt) in lines) {
      _acct[acct] = (_acct[acct] ?? 0) + amt;
    }
    for (final (acct, _) in lines) {
      final p = acct.split(':').first;
      if (!_debitNormal.contains(p) && balance(acct) < 0) {
        for (final (a2, amt) in lines) {
          _acct[a2] = _acct[a2]! - amt; // undo
        }
        throw StateError('$acct would go negative');
      }
    }
    final e = LedgerEntry(key, kind, cur, [for (final l in lines) l], now, linkId: linkId, paymentId: paymentId);
    entries.add(e);
    _byKey[key] = e;
    return e;
  }

  /// Wallet view for one user and currency.
  ({int pending, int available, int held}) walletOf(String userId, String cur) =>
      (pending: balance(_a('user_pending', userId, cur)), available: balance(_a('user_available', userId, cur)), held: balance(_a('user_held', userId, cur)));

  // ---------------------------------------------------------------- state
  final List<PaymentLink> links = [];
  final List<LinkPayment> payments = [];
  final List<Allocation> allocations = [];
  final List<PlNotification> notifications = [];
  final List<AuditEntry> audit = [];
  final List<RiskFlag> flags = [];
  final List<SplitTemplate> templates = [];
  final List<Amendment> amendments = [];
  final List<({String id, String event, String paymentRef, String result, DateTime at})> webhookLog = [];
  final Set<String> _seenEvents = {};
  int _seq = 0;

  String _id(String p) => '${p}_${++_seq}';
  String _ref(String p) {
    const alphabet = '23456789ABCDEFGHJKMNPQRSTUVWXYZ';
    return '$p-${List.generate(8, (_) => alphabet[_rng.nextInt(alphabet.length)]).join()}';
  }

  void _audit(String actor, String action, {String? linkId, String? detail}) => audit.add(AuditEntry(now, actor, action, linkId: linkId, detail: detail));

  void _notify(String userId, String kind, String title, String body, {String? linkId}) => notifications.add(PlNotification(userId, kind, title, body, now, linkId: linkId));

  PaymentLink link(String id) => links.firstWhere((l) => l.id == id);
  List<LinkPayment> paymentsOf(String linkId) => payments.where((p) => p.linkId == linkId).toList().reversed.toList();
  List<Allocation> allocationsOf(String linkId) => allocations.where((a) => a.linkId == linkId).toList();
  List<PlNotification> notificationsFor(String userId) => notifications.where((n) => n.userId == userId).toList().reversed.toList();

  int collected(String linkId) => payments.where((p) => p.linkId == linkId && (p.status == PayStatus.succeeded || p.status == PayStatus.disputed)).fold(0, (a, p) => a + p.amount);

  LinkTotals totals(String linkId) {
    final ps = payments.where((p) => p.linkId == linkId);
    final al = allocations.where((a) => a.linkId == linkId && a.state != AllocState.reversed);
    final heldPs = ps.where((p) => p.status == PayStatus.succeeded && p.distribution != DistributionStatus.distributed);
    return LinkTotals(
      collected: collected(linkId),
      distributed: al.fold(0, (a, x) => a + x.net),
      held: heldPs.fold(0, (a, p) => a + (p.grossPaid ?? 0) - p.knockFee),
      succeeded: ps.where((p) => p.status == PayStatus.succeeded || p.status == PayStatus.disputed).length,
      pending: ps.where((p) => const [PayStatus.initiated, PayStatus.pending, PayStatus.confirming].contains(p.status)).length,
      failed: ps.where((p) => p.status == PayStatus.failed).length,
    );
  }

  /// Gross already credited to each recipient toward fixed targets.
  Map<String, int> receivedOn(String linkId) {
    final m = <String, int>{};
    for (final a in allocations.where((a) => a.linkId == linkId && !a.overflow && a.state != AllocState.reversed)) {
      m[a.recipient.id] = (m[a.recipient.id] ?? 0) + a.gross;
    }
    return m;
  }

  // ---------------------------------------------------------------- links
  /// [Guess] KYC tier limits (tier 2 for the demo user): ₦10M target, ₦5M per payment, 20 recipients.
  static const maxTarget = 1000000000;
  static const maxSinglePayment = 500000000;
  static const maxRecipients = 20;

  PaymentLink createLink({
    required LinkType type,
    required String title,
    String? description,
    required PlAsset asset,
    required AmountMode amountMode,
    int? fixedAmount,
    int? target,
    SplitMethod splitMethod = SplitMethod.percentage,
    SettlementMode settlementMode = SettlementMode.eachPayment,
    FeeBearer feeBearer = FeeBearer.deduct,
    bool remainderToCreator = false,
    List<(KnockUser, int, int)> recipients = const [],
    DateTime? expiresAt,
    bool requireCustomerReference = false,
    String? invoiceNumber,
    String? instructions,
  }) {
    if (title.trim().isEmpty) throw PlException('invalid_link', 'Give the link a name.');
    if (amountMode == AmountMode.fixed && (fixedAmount == null || fixedAmount <= 0)) {
      throw PlException('invalid_amount', 'Enter the amount each payer pays.');
    }
    if (asset.isFiat && (target ?? 0) > maxTarget) throw PlException('limit_exceeded', 'The total is above your tier limit.');
    if (asset.isFiat && (fixedAmount ?? 0) > maxSinglePayment) {
      throw PlException('limit_exceeded', 'The amount is above your per-payment limit.');
    }
    if (expiresAt != null && !expiresAt.isAfter(now)) throw PlException('invalid_expiry', 'The expiry must be in the future.');
    if (settlementMode == SettlementMode.onTarget && target == null) {
      throw PlException('invalid_settlement', 'Collect-then-distribute needs a total target.');
    }
    if (recipients.length > maxRecipients) throw PlException('limit_exceeded', 'Up to $maxRecipients recipients on your tier.');
    final rules = type == LinkType.split
        ? PlSplit.buildRules(creator: me, method: splitMethod, target: target, remainderToCreator: remainderToCreator, input: recipients)
        : [RecipientRule(user: me, allocated: target ?? 0, basisPoints: 10000)];
    final l = PaymentLink(
      id: _id('pl'),
      reference: _ref('KPL'),
      slug: List.generate(16, (_) => 'abcdefghjkmnpqrstuvwxyz23456789'[_rng.nextInt(31)]).join(),
      creator: me,
      type: type,
      title: title.trim(),
      description: description?.trim().isEmpty ?? true ? null : description!.trim(),
      asset: asset,
      amountMode: amountMode,
      fixedAmount: amountMode == AmountMode.fixed ? fixedAmount : null,
      target: target,
      splitMethod: type == LinkType.split ? splitMethod : SplitMethod.percentage,
      settlementMode: settlementMode,
      feeBearer: feeBearer,
      rules: [rules],
      createdAt: now,
      expiresAt: expiresAt,
      requireCustomerReference: requireCustomerReference,
      invoiceNumber: invoiceNumber,
      instructions: instructions,
    );
    links.add(l);
    _audit('@${me.username}', 'link.created', linkId: l.id, detail: '${l.type.label}, ${rules.length} recipient(s)');
    _notify(me.id, 'link_created', 'Payment link created', '"${l.title}" (${l.reference}) is live and ready to share.', linkId: l.id);
    notifyListeners();
    return l;
  }

  void updateDetails(PaymentLink l, {String? title, String? description, String? instructions, DateTime? expiresAt, bool clearExpiry = false}) {
    if (expiresAt != null && !expiresAt.isAfter(now)) throw PlException('invalid_expiry', 'The expiry must be in the future.');
    if (title != null && title.trim().isNotEmpty) l.title = title.trim();
    if (description != null) l.description = description.trim().isEmpty ? null : description.trim();
    if (instructions != null) l.instructions = instructions.trim().isEmpty ? null : instructions.trim();
    if (clearExpiry) l.expiresAt = null;
    if (expiresAt != null) l.expiresAt = expiresAt;
    if (l.status == LinkStatus.expired && (clearExpiry || expiresAt != null)) l.status = LinkStatus.active;
    _audit('@${me.username}', 'link.updated', linkId: l.id);
    notifyListeners();
  }

  void setStatus(PaymentLink l, String action, {bool asStaff = false}) {
    final next = switch (action) {
      'pause' => l.status == LinkStatus.active ? LinkStatus.paused : null,
      'resume' => l.status == LinkStatus.paused && (l.expiresAt == null || l.expiresAt!.isAfter(now)) ? LinkStatus.active : null,
      'close' => l.status != LinkStatus.closed && l.status != LinkStatus.underReview ? LinkStatus.closed : null,
      'review' => asStaff ? LinkStatus.underReview : null,
      'clear_review' => asStaff && l.status == LinkStatus.underReview ? LinkStatus.active : null,
      _ => null,
    };
    if (next == null) throw PlException('invalid_state', 'Cannot $action a link that is ${l.status.label.toLowerCase()}.');
    final from = l.status;
    l.status = next;
    _audit(asStaff ? 'compliance' : '@${me.username}', 'link.$action', linkId: l.id, detail: '${from.label} → ${next.label}');
    if (action == 'clear_review' && l.settlementMode == SettlementMode.eachPayment) {
      for (final p in payments.where((p) => p.linkId == l.id && p.status == PayStatus.succeeded && p.distribution == DistributionStatus.held)) {
        _tryDistribute(p);
      }
    }
    notifyListeners();
  }

  /// Cron job in production (knock.expire_links). Also warns 24h ahead.
  void runExpiry() {
    for (final l in links) {
      if ((l.status == LinkStatus.active || l.status == LinkStatus.paused) && l.expiresAt != null && !l.expiresAt!.isAfter(now)) {
        l.status = LinkStatus.expired;
        _audit('system', 'link.expired', linkId: l.id);
        _notify(l.creator.id, 'link_expired', 'Payment link expired', '"${l.title}" no longer accepts payments.', linkId: l.id);
      } else if (l.status == LinkStatus.active && l.expiresAt != null && l.expiresAt!.difference(now).inHours < 24 && !notifications.any((n) => n.linkId == l.id && n.kind == 'link_expiring')) {
        _notify(l.creator.id, 'link_expiring', 'Payment link expires soon', '"${l.title}" expires within 24 hours.', linkId: l.id);
      }
    }
    notifyListeners();
  }

  // ---------------------------------------------------------------- checkout
  ({int amount, int knockFee, int payerFee, int total, int? remaining}) quote(PaymentLink l, int? amount) {
    if (l.status == LinkStatus.active && l.expiresAt != null && !l.expiresAt!.isAfter(now)) {
      throw PlException('link_expired', 'This payment link has expired.');
    }
    if (l.status != LinkStatus.active) throw PlException('link_${l.status.name}', 'This payment link is ${l.status.label.toLowerCase()} and not accepting payments.');
    final a = l.amountMode == AmountMode.fixed ? l.fixedAmount! : amount;
    if (a == null || a <= 0) throw PlException('invalid_amount', 'Enter an amount.');
    if (l.asset.isFiat && a > maxSinglePayment) throw PlException('limit_exceeded', 'That amount is above this link\'s per-payment limit.');
    int? remaining;
    if (l.target != null) {
      remaining = l.target! - collected(l.id);
      if (a > remaining) throw PlException('over_target', 'Only ${PlFmt.money(remaining.clamp(0, 1 << 62), l.asset)} remains to be collected.');
    }
    final fee = PlSplit.fee(l.asset, a);
    final payerFee = l.feeBearer == FeeBearer.payer ? fee : 0;
    return (amount: a, knockFee: fee, payerFee: payerFee, total: a + payerFee, remaining: remaining);
  }

  /// Opens a sandbox checkout (bank transfer account / card / crypto address). Nothing is credited.
  LinkPayment startCheckout(PaymentLink l, {int? amount, required PayMethod method, String? payerName, String? payerEmail, String? customerReference}) {
    final q = quote(l, amount);
    if (l.requireCustomerReference && (customerReference ?? '').trim().isEmpty) {
      throw PlException('reference_required', 'Enter your customer reference.');
    }
    final isCrypto = !l.asset.isFiat;
    final p = LinkPayment(
      id: _id('pay'),
      reference: _ref('KPY'),
      linkId: l.id,
      provider: isCrypto ? 'sandbox_crypto' : 'sandbox_naira',
      providerReference: 'SBX-${_ref(isCrypto ? 'CX' : 'NG')}',
      method: isCrypto ? PayMethod.crypto : method,
      amount: q.amount,
      payerFee: q.payerFee,
      knockFee: q.knockFee,
      createdAt: now,
      payerName: payerName,
      payerEmail: payerEmail,
      customerReference: customerReference,
      network: isCrypto ? l.asset.network : null,
      address: isCrypto
          ? (l.asset.network == 'TRC20'
                ? 'T${List.generate(33, (_) => 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz123456789'[_rng.nextInt(58)]).join()}'
                : l.asset.network == 'BITCOIN'
                ? 'bc1q${List.generate(38, (_) => 'qpzry9x8gf2tvdw0s3jn54khce6mua7l'[_rng.nextInt(32)]).join()}'
                : '0x${List.generate(40, (_) => '0123456789abcdef'[_rng.nextInt(16)]).join()}')
          : null,
      rateNgn: isCrypto ? rateNgn(l.asset) : null,
    );
    payments.add(p);
    notifyListeners();
    return p;
  }

  /// [Guess] Sandbox rates; the live feed comes from the liquidity partner.
  double rateNgn(PlAsset a) => switch (a.code) {
    'BTC' => 158000000,
    _ => 1650,
  };

  // ---------------------------------------------------------------- provider events
  /// Simulates the provider: payer pays, provider sends a signed webhook,
  /// Knock re-verifies with the provider, then credits. [amountPaid] lets you
  /// simulate an under/over payment; [fail] a failed payment.
  String simulateProviderPayment(LinkPayment p, {int? amountPaid, bool fail = false, bool badSignature = false}) {
    final eventId = _id('evt');
    if (badSignature) return _webhook(eventId, p, 'charge.success', signatureValid: false);
    if (fail) return _webhook(eventId, p, 'charge.failed', failed: true);
    return _webhook(eventId, p, 'charge.success', amountPaid: amountPaid ?? p.totalToPay);
  }

  /// Crypto: a transaction is seen on chain with [confirmations] so far.
  String simulateChain(LinkPayment p, int confirmations, {int? amountPaid, String? network}) {
    p.txHash ??= '0x${List.generate(64, (_) => '0123456789abcdef'[_rng.nextInt(16)]).join()}';
    return _webhook(_id('evt'), p, 'crypto.confirmation', amountPaid: amountPaid ?? p.totalToPay, confirmations: confirmations, network: network ?? p.network);
  }

  /// Replays the last webhook for a payment (providers retry deliveries).
  String replayWebhook(LinkPayment p) {
    final last = webhookLog.lastWhere((w) => w.paymentRef == p.reference, orElse: () => (id: '', event: '', paymentRef: '', result: '', at: now));
    if (last.id.isEmpty) return 'nothing to replay';
    return _webhook(last.id, p, last.event, amountPaid: p.grossPaid ?? p.totalToPay, confirmations: p.confirmations, network: p.network);
  }

  String _webhook(String eventId, LinkPayment p, String event, {bool signatureValid = true, bool failed = false, int? amountPaid, int? confirmations, String? network}) {
    String result;
    if (!signatureValid) {
      result = 'rejected: bad signature (stored, not processed)';
      flags.add(RiskFlag(now, 'bad_webhook_signature', 'medium', 'Unsigned webhook for ${p.reference}', linkId: p.linkId, paymentId: p.id));
    } else if (_seenEvents.contains(eventId)) {
      result = 'duplicate event ignored';
    } else {
      _seenEvents.add(eventId);
      if (failed) {
        if (p.status != PayStatus.succeeded) {
          p.status = PayStatus.failed;
          final l = link(p.linkId);
          _notify(l.creator.id, 'payment_failed', 'A payment failed', 'A payment to "${l.title}" did not go through (${p.reference}).', linkId: l.id);
        }
        result = 'payment failed';
      } else {
        // Verify with the provider's API (sandbox: what it recorded), then confirm.
        result = _confirm(p, amountPaid: amountPaid!, confirmations: confirmations ?? 0, network: network ?? p.network, txHash: p.txHash);
      }
    }
    webhookLog.add((id: eventId, event: event, paymentRef: p.reference, result: result, at: now));
    notifyListeners();
    return result;
  }

  String _confirm(LinkPayment p, {required int amountPaid, required int confirmations, String? network, String? txHash}) {
    if (p.status == PayStatus.succeeded || p.status == PayStatus.disputed || p.status == PayStatus.reversed) return 'duplicate: already credited';
    final l = link(p.linkId);
    if (!l.asset.isFiat) {
      if (network != l.asset.network) {
        flags.add(RiskFlag(now, 'wrong_network', 'high', 'Funds sent on $network, expected ${l.asset.network}', linkId: l.id, paymentId: p.id));
        return 'rejected: wrong network (sent to operations for recovery)';
      }
      if (txHash == null) return 'rejected: missing transaction hash';
      p.confirmations = confirmations;
      if (confirmations < l.asset.confirmations) {
        p.status = PayStatus.confirming;
        return 'waiting: $confirmations of ${l.asset.confirmations} confirmations';
      }
    }
    String? hold;
    final expected = p.totalToPay;
    if (amountPaid != expected) {
      p.amount = amountPaid;
      p.payerFee = 0;
      p.knockFee = PlSplit.fee(l.asset, amountPaid);
      hold = 'Amount mismatch: expected ${PlFmt.money(expected, l.asset)}, received ${PlFmt.money(amountPaid, l.asset)}';
      flags.add(RiskFlag(now, 'amount_mismatch', 'medium', hold, linkId: l.id, paymentId: p.id));
    }
    if (l.status != LinkStatus.active) hold ??= 'Payment arrived while the link was ${l.status.label.toLowerCase()}';
    p
      ..status = PayStatus.succeeded
      ..grossPaid = amountPaid
      ..verifiedAt = now
      ..distribution = DistributionStatus.held
      ..holdReason = hold;
    l.firstPaymentAt ??= now;
    final cur = l.asset.code;
    final coll = _a('link_collection', l.id, cur);
    _post('pay:${p.id}:received', 'payment_received', cur, [(_a('provider_clearing', 'system', cur), amountPaid), (coll, -amountPaid)], linkId: l.id, paymentId: p.id);
    if (p.knockFee > 0) {
      _post('pay:${p.id}:fee', 'knock_fee', cur, [(coll, p.knockFee), (_a('fee_revenue', 'system', cur), -p.knockFee)], linkId: l.id, paymentId: p.id);
    }
    _audit('provider', 'payment.verified', linkId: l.id, detail: '${p.reference} ${PlFmt.money(amountPaid, l.asset)}');
    _notify(l.creator.id, 'payment_received', 'Payment received', '${PlFmt.money(p.amount, l.asset)} paid to "${l.title}".', linkId: l.id);
    _riskChecks(l, p);

    var result = 'confirmed';
    if (hold == null && l.settlementMode == SettlementMode.eachPayment) {
      result = _tryDistribute(p) ? 'confirmed and split' : 'confirmed; split failed, will retry';
    } else if (hold != null) {
      result = 'confirmed and held: $hold';
    } else {
      result = 'confirmed and held in collection balance';
    }
    if (l.target != null && collected(l.id) >= l.target! && l.status == LinkStatus.active) {
      l.status = LinkStatus.completed;
      _notify(l.creator.id, 'target_reached', 'Collection target reached', '"${l.title}" has collected its full target.', linkId: l.id);
      if (l.settlementMode == SettlementMode.onTarget) {
        for (final hp in payments.where((x) => x.linkId == l.id && x.status == PayStatus.succeeded && x.distribution == DistributionStatus.held && x.holdReason == null)) {
          _tryDistribute(hp);
        }
        result = '$result; target reached, all held payments split';
      }
    }
    // Sandbox: Naira providers settle T+1; we settle crypto immediately (custody).
    if (!l.asset.isFiat) settle(p, notify: false);
    return result;
  }

  void _riskChecks(PaymentLink l, LinkPayment p) {
    final recent = payments.where((x) => x.linkId == l.id && x.payerEmail != null && x.payerEmail == p.payerEmail && now.difference(x.createdAt).inMinutes < 10);
    if (p.payerEmail != null && recent.length >= 5) {
      flags.add(RiskFlag(now, 'payer_velocity', 'medium', '${recent.length} payments in 10 minutes from one payer', linkId: l.id, paymentId: p.id));
    }
    if (l.asset.isFiat && p.amount >= 450000000 && p.amount < maxSinglePayment) {
      flags.add(RiskFlag(now, 'near_limit', 'low', 'Payment just under the per-payment limit', linkId: l.id, paymentId: p.id));
    }
  }

  /// All-or-nothing distribution. Everything is computed first; any failure
  /// leaves the money in the link's collection account and schedules a retry.
  bool _tryDistribute(LinkPayment p) {
    final l = link(p.linkId);
    p.attempts++;
    try {
      if (p.distribution == DistributionStatus.distributed) return true;
      if (l.status == LinkStatus.underReview) throw PlException('under_review', 'Link is under compliance review');
      for (final r in l.currentRules) {
        if (_frozen.contains(r.user.id)) throw PlException('recipient_unavailable', '@${r.user.username} cannot be credited (account frozen)');
      }
      final shares = PlSplit.previewPayment(
        method: l.splitMethod,
        rules: l.currentRules,
        creator: l.creator,
        amount: p.amount,
        knockFee: p.knockFee,
        feeBearer: l.feeBearer,
        received: receivedOn(l.id),
      );
      final cur = l.asset.code;
      final state = p.settledAt == null ? AllocState.pending : AllocState.available;
      final totalNet = shares.fold<int>(0, (a, s) => a + s.gross - s.fee);
      final lines = <(String, int)>[
        (_a('link_collection', l.id, cur), totalNet),
        for (final s in shares)
          if (s.gross - s.fee > 0) (_a('user_${state.name}', s.user.id, cur), -(s.gross - s.fee)),
      ];
      final entry = _post('pay:${p.id}:split', 'split_distribution', cur, lines, linkId: l.id, paymentId: p.id);
      for (final s in shares) {
        allocations.add(
          Allocation(
            id: _id('al'),
            paymentId: p.id,
            linkId: l.id,
            recipient: s.user,
            ruleVersion: l.ruleVersion,
            gross: s.gross,
            fee: s.fee,
            overflow: s.overflow,
            entryRef: entry.key,
            at: now,
            state: state,
          ),
        );
        _notify(
          s.user.id,
          'split_credited',
          state == AllocState.pending ? 'Incoming split (pending)' : 'Split credited',
          '${PlFmt.money(s.gross - s.fee, l.asset)} from "${l.title}" (${p.reference}).',
          linkId: l.id,
        );
      }
      p
        ..distribution = DistributionStatus.distributed
        ..ruleVersion = l.ruleVersion
        ..holdReason = null;
      _audit('system', 'payment.distributed', linkId: l.id, detail: '${p.reference} to ${shares.length} recipient(s), rules v${l.ruleVersion}');
      return true;
    } on Object catch (e) {
      p
        ..distribution = DistributionStatus.failedRetrying
        ..holdReason = e.toString();
      _audit('system', 'payment.distribution_failed', linkId: l.id, detail: '${p.reference}: $e (attempt ${p.attempts})');
      if (p.attempts == 1) {
        _notify(l.creator.id, 'allocation_pending', 'Split distribution pending', 'A payment to "${l.title}" is safely held and will be split when this clears: $e', linkId: l.id);
      }
      return false;
    }
  }

  /// Retry job (every few minutes in production, with back-off).
  int retryFailed() {
    var n = 0;
    for (final p in payments.where((p) => p.distribution == DistributionStatus.failedRetrying).toList()) {
      if (_tryDistribute(p)) n++;
    }
    notifyListeners();
    return n;
  }

  /// Manual distribution of held payments.
  int distributeHeld(PaymentLink l) {
    var n = 0;
    for (final p
        in payments.where((p) => p.linkId == l.id && p.status == PayStatus.succeeded && (p.distribution == DistributionStatus.held || p.distribution == DistributionStatus.failedRetrying)).toList()) {
      if (_tryDistribute(p)) n++;
    }
    _audit('@${me.username}', 'link.distribute_held', linkId: l.id, detail: '$n payment(s)');
    notifyListeners();
    return n;
  }

  /// Provider has settled funds to Knock: pending shares become available.
  void settle(LinkPayment p, {bool notify = true}) {
    if (p.settledAt != null || p.grossPaid == null) return;
    final l = link(p.linkId);
    final cur = l.asset.code;
    final providerFee = l.asset.isFiat ? (p.grossPaid! * 150 ~/ 10000).clamp(0, 200000) : 0; // [Guess] provider cost
    _post(
      'pay:${p.id}:settled',
      'provider_settlement',
      cur,
      [
        (_a('settlement_bank', 'system', cur), p.grossPaid! - providerFee),
        if (providerFee > 0) (_a('provider_fee_expense', 'system', cur), providerFee),
        (_a('provider_clearing', 'system', cur), -p.grossPaid!),
      ],
      linkId: l.id,
      paymentId: p.id,
    );
    p.settledAt = now;
    for (final a in allocations.where((a) => a.paymentId == p.id && a.state == AllocState.pending)) {
      _post('alloc:${a.id}:available', 'split_release', cur, [(_a('user_pending', a.recipient.id, cur), a.net), (_a('user_available', a.recipient.id, cur), -a.net)], linkId: l.id, paymentId: p.id);
      a.state = AllocState.available;
    }
    _audit('provider', 'payment.settled', linkId: l.id, detail: p.reference);
    if (notify) notifyListeners();
  }

  // ---------------------------------------------------------------- reversals & disputes
  void openDispute(LinkPayment p, String reason) {
    if (p.status != PayStatus.succeeded) throw PlException('invalid_state', 'Only successful payments can be disputed.');
    final l = link(p.linkId);
    final cur = l.asset.code;
    p.status = PayStatus.disputed;
    for (final a in allocations.where((a) => a.paymentId == p.id && (a.state == AllocState.pending || a.state == AllocState.available))) {
      final from = _a('user_${a.state.name}', a.recipient.id, cur);
      final take = min(a.net, max(balance(from), 0));
      if (take > 0) _post('alloc:${a.id}:held', 'allocation_held', cur, [(from, take), (_a('user_held', a.recipient.id, cur), -take)], linkId: l.id, paymentId: p.id);
      a.state = AllocState.held;
      _notify(a.recipient.id, 'payment_disputed', 'Split on hold', 'A payer disputed a payment on "${l.title}". Your share is on hold.', linkId: l.id);
    }
    _notify(l.creator.id, 'payment_disputed', 'Payment disputed', '${p.reference} on "${l.title}" was disputed: $reason', linkId: l.id);
    _audit('provider', 'payment.disputed', linkId: l.id, detail: '${p.reference}: $reason');
    notifyListeners();
  }

  void resolveDispute(LinkPayment p, {required bool won}) {
    if (p.status != PayStatus.disputed) throw PlException('invalid_state', 'No open dispute.');
    final l = link(p.linkId);
    final cur = l.asset.code;
    if (won) {
      p.status = PayStatus.succeeded;
      for (final a in allocations.where((a) => a.paymentId == p.id && a.state == AllocState.held)) {
        _post(
          'alloc:${a.id}:released',
          'allocation_released',
          cur,
          [(_a('user_held', a.recipient.id, cur), a.net), (_a('user_available', a.recipient.id, cur), -a.net)],
          linkId: l.id,
          paymentId: p.id,
        );
        a.state = AllocState.available;
      }
      _audit('staff', 'dispute.won', linkId: l.id, detail: p.reference);
      notifyListeners();
    } else {
      _audit('staff', 'dispute.lost', linkId: l.id, detail: p.reference);
      reverse(p, 'chargeback', 'Dispute lost');
    }
  }

  /// Refund or chargeback: unwinds every allocation, the fee and the receipt.
  /// If a recipient already spent their share, the shortfall becomes a
  /// recovery receivable owed to Knock.
  void reverse(LinkPayment p, String kind, String reason) {
    if (p.status == PayStatus.reversed) return;
    if (p.status != PayStatus.succeeded && p.status != PayStatus.disputed) throw PlException('invalid_state', 'Only verified payments can be reversed.');
    final l = link(p.linkId);
    final cur = l.asset.code;
    final coll = _a('link_collection', l.id, cur);
    for (final a in allocations.where((a) => a.paymentId == p.id && a.state != AllocState.reversed)) {
      final from = _a('user_${a.state.name}', a.recipient.id, cur);
      final take = min(a.net, max(balance(from), 0));
      final short = a.net - take;
      _post(
        'alloc:${a.id}:reversed',
        'allocation_reversed',
        cur,
        [if (take > 0) (from, take), if (short > 0) (_a('recovery_receivable', a.recipient.id, cur), short), (coll, -a.net)],
        linkId: l.id,
        paymentId: p.id,
      );
      if (short > 0) flags.add(RiskFlag(now, 'recovery_receivable', 'high', '@${a.recipient.username} owes ${PlFmt.money(short, l.asset)}', linkId: l.id, paymentId: p.id));
      a.state = AllocState.reversed;
      _notify(a.recipient.id, 'payment_reversed', 'Split reversed', 'A $kind on "${l.title}" (${p.reference}) was reversed: $reason', linkId: l.id);
    }
    if (p.knockFee > 0) _post('pay:${p.id}:fee_reversed', 'knock_fee_reversal', cur, [(_a('fee_revenue', 'system', cur), p.knockFee), (coll, -p.knockFee)], linkId: l.id, paymentId: p.id);
    final out = p.settledAt == null ? _a('provider_clearing', 'system', cur) : _a('settlement_bank', 'system', cur);
    _post('pay:${p.id}:reversed', 'payment_$kind', cur, [(coll, p.grossPaid!), (out, -p.grossPaid!)], linkId: l.id, paymentId: p.id);
    p
      ..status = PayStatus.reversed
      ..distribution = DistributionStatus.reversed;
    if (l.status == LinkStatus.completed && l.target != null && collected(l.id) < l.target!) l.status = LinkStatus.active;
    _notify(l.creator.id, 'payment_reversed', 'Payment reversed', '${kind[0].toUpperCase()}${kind.substring(1)} on "${l.title}" (${p.reference}): $reason', linkId: l.id);
    _audit('finance', 'payment.$kind', linkId: l.id, detail: '${p.reference}: $reason');
    notifyListeners();
  }

  // ---------------------------------------------------------------- amendments
  /// Rules are frozen after the first payment. Changes create a new version
  /// for future payments only; recipients whose share drops must approve.
  Amendment proposeAmendment(PaymentLink l, String reason, List<(KnockUser, int, int)> input, {bool remainderToCreator = false}) {
    if (l.type != LinkType.split) throw PlException('invalid_request', 'Only split links have split rules.');
    if (reason.trim().length < 3) throw PlException('invalid_request', 'Give a reason for the change.');
    if (amendments.any((m) => m.linkId == l.id && m.status == 'proposed')) throw PlException('amendment_pending', 'Another change is waiting for approval.');
    final rules = PlSplit.buildRules(creator: l.creator, method: l.splitMethod, target: l.target, remainderToCreator: remainderToCreator, input: input);
    final approvers = <String, bool?>{};
    for (final old in l.currentRules) {
      final nw = rules.where((r) => r.user.id == old.user.id).firstOrNull;
      if (old.user.id != me.id && (nw?.basisPoints ?? 0) < old.basisPoints) approvers[old.user.id] = null;
    }
    final m = Amendment(id: _id('am'), linkId: l.id, fromVersion: l.ruleVersion, reason: reason, proposed: rules, approvers: approvers, at: now);
    amendments.add(m);
    _audit('@${me.username}', 'split.amendment_proposed', linkId: l.id, detail: reason);
    for (final id in approvers.keys) {
      _notify(id, 'amendment_approval', 'Approve a split change', 'The creator of "${l.title}" wants to change the split: $reason', linkId: l.id);
    }
    if (approvers.isEmpty) _applyAmendment(m);
    notifyListeners();
    return m;
  }

  void decideAmendment(Amendment m, String userId, bool approve) {
    if (m.status != 'proposed' || !m.approvers.containsKey(userId)) throw PlException('forbidden', 'Approval not needed.');
    m.approvers[userId] = approve;
    _audit('@${user(userId).username}', 'split.amendment_${approve ? 'approved' : 'rejected'}', linkId: m.linkId);
    if (!approve) {
      m.status = 'rejected';
    } else if (m.approvers.values.every((v) => v == true)) {
      _applyAmendment(m);
    }
    notifyListeners();
  }

  void _applyAmendment(Amendment m) {
    final l = link(m.linkId);
    if (l.ruleVersion != m.fromVersion) {
      m.status = 'cancelled';
      return;
    }
    l.rules.add(m.proposed);
    m.status = 'applied';
    _audit('system', 'split.amended', linkId: l.id, detail: 'v${m.fromVersion} → v${l.ruleVersion}: ${m.reason}');
    for (final r in {...l.rules[m.fromVersion - 1], ...m.proposed}) {
      _notify(r.user.id, 'split_amended', 'Split rules updated', 'The split for "${l.title}" changed for future payments. Past payments keep their split.', linkId: l.id);
    }
  }

  // ---------------------------------------------------------------- templates
  SplitTemplate saveTemplate(String name, SplitMethod method, List<(KnockUser, int, int)> members) {
    if (name.trim().isEmpty) throw PlException('invalid_request', 'Name the group.');
    templates.removeWhere((t) => t.name.toLowerCase() == name.trim().toLowerCase());
    final t = SplitTemplate(_id('tpl'), name.trim(), method, members);
    templates.add(t);
    notifyListeners();
    return t;
  }

  // ---------------------------------------------------------------- reconciliation
  /// Same checks as knock.reconcile(). Empty list = ledger agrees with payments.
  List<String> reconcile() {
    final problems = <String>[];
    for (final e in entries) {
      if (e.lines.fold<int>(0, (a, l) => a + l.$2) != 0) problems.add('Entry ${e.key} does not balance');
    }
    for (final p in payments.where((p) => p.grossPaid != null)) {
      final l = link(p.linkId);
      if (!_byKey.containsKey('pay:${p.id}:received')) problems.add('${p.reference} has no receipt posting');
      if (p.distribution == DistributionStatus.distributed) {
        final net = allocations.where((a) => a.paymentId == p.id).fold<int>(0, (a, x) => a + x.net);
        final expected = p.amount - (l.feeBearer == FeeBearer.deduct ? p.knockFee : 0);
        if (net != expected) problems.add('${p.reference} allocations $net ≠ $expected');
      }
    }
    for (final l in links) {
      final held = payments
          .where((p) => p.linkId == l.id && (p.status == PayStatus.succeeded || p.status == PayStatus.disputed) && p.distribution != DistributionStatus.distributed)
          .fold<int>(0, (a, p) => a + p.grossPaid! - p.knockFee);
      final bal = balance(_a('link_collection', l.id, l.asset.code));
      if (bal != held) problems.add('${l.reference} collection balance $bal ≠ held $held');
    }
    for (final cur in {for (final l in links) l.asset.code}) {
      final unsettled = payments
          .where((p) => link(p.linkId).asset.code == cur && (p.status == PayStatus.succeeded || p.status == PayStatus.disputed) && p.settledAt == null)
          .fold<int>(0, (a, p) => a + p.grossPaid!);
      final bal = balance(_a('provider_clearing', 'system', cur));
      if (bal != unsettled) problems.add('Provider clearing $cur $bal ≠ $unsettled');
    }
    for (final acct in _acct.keys) {
      if (!_debitNormal.contains(acct.split(':').first) && balance(acct) < 0) problems.add('$acct is negative');
    }
    return problems;
  }

  /// Knock fee income net of reversals, per currency.
  int feeRevenue(String cur) => balance(_a('fee_revenue', 'system', cur));

  // ---------------------------------------------------------------- demo data
  void _seedDemo() {
    final mary = user('u_mary'), innocent = user('u_innocent'), favour = user('u_favour');
    final alpha = createLink(
      type: LinkType.split,
      title: 'Project Alpha',
      description: 'Brand identity project for Lagos Coffee Co.',
      asset: PlAsset.ngn,
      amountMode: AmountMode.flexible,
      target: 50000000,
      splitMethod: SplitMethod.percentage,
      recipients: [(me, 0, 4000), (mary, 0, 3000), (innocent, 0, 2000), (favour, 0, 1000)],
      expiresAt: now.add(const Duration(days: 14)),
      invoiceNumber: 'INV-2026-031',
    );
    for (final (amt, name, email) in [(10000000, 'Adaeze Obi', 'adaeze@example.com'), (15000000, 'Lagos Coffee Co.', 'accounts@example.com'), (5000000, 'Emeka Johnson', 'emeka@example.com')]) {
      final p = startCheckout(alpha, amount: amt, method: PayMethod.bankTransfer, payerName: name, payerEmail: email);
      simulateProviderPayment(p);
    }
    settle(payments.first);
    createLink(type: LinkType.naira, title: 'Ankara tote bag', description: 'Handmade tote, delivery in Lagos included.', asset: PlAsset.ngn, amountMode: AmountMode.fixed, fixedAmount: 1500000);
    createLink(type: LinkType.crypto, title: 'Logo design deposit', asset: PlAsset.crypto.first, amountMode: AmountMode.fixed, fixedAmount: 150000000);
    saveTemplate('Agency Team', SplitMethod.percentage, [(me, 0, 5000), (mary, 0, 3000), (innocent, 0, 2000)]);
    notifications.clear();
  }
}

class LedgerEntry {
  LedgerEntry(this.key, this.kind, this.currency, this.lines, this.at, {this.linkId, this.paymentId});
  final String key;
  final String kind;
  final String currency;
  final List<(String, int)> lines;
  final DateTime at;
  final String? linkId;
  final String? paymentId;
}
