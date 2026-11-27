part of 'server.dart';

/// Crypto deposits through Knock's crypto infrastructure partner (Breet).
///
/// This in-app sandbox mirrors the real backend in backend/src/crypto and
/// backend/supabase/migrations/2026112700030x_*: one permanent address per
/// customer, asset and network; deposits move pending -> confirming ->
/// completed (or below minimum / under review / failed); only a completed
/// deposit credits the Naira wallet, exactly once, with the amount the
/// provider reports. Nothing here talks to Breet. Customers never see the
/// provider's name, ids or raw messages.
extension CryptoRailsApi on KnockServer {
  static const _minUsd = 10.0;

  /// Assets and networks available for deposit. In production this list
  /// comes from the provider's live asset configuration, not code.
  static const depositAssets = <Map<String, Object>>[
    {'assetId': 'USDT_TRC20', 'symbol': 'USDT', 'network': 'TRC20', 'networkName': 'Tron (TRC20)', 'confirmations': 3},
    {'assetId': 'USDT_BSC', 'symbol': 'USDT', 'network': 'BSC', 'networkName': 'BNB Smart Chain (BEP20)', 'confirmations': 3},
    {'assetId': 'USDC_SOL', 'symbol': 'USDC', 'network': 'SOL', 'networkName': 'Solana', 'confirmations': 2},
    {'assetId': 'BTC', 'symbol': 'BTC', 'network': '', 'networkName': 'Bitcoin', 'confirmations': 2},
    {'assetId': 'LTC', 'symbol': 'LTC', 'network': '', 'networkName': 'Litecoin', 'confirmations': 3},
  ];

  Map<String, Object> _depAsset(String assetId) =>
      depositAssets.firstWhere((a) => a['assetId'] == assetId, orElse: () => throw ApiError('asset_unavailable', 'This asset is not available for deposits right now.'));

  Json cryptoDepositOptions(String token) => _read(() {
    _user(token);
    return {
      'assets': depositAssets,
      'minimumUsd': _minUsd,
      'ngnPerUsd': cryptoSellNgnPerUsd,
      'note': 'Crypto you send is converted to Naira when the deposit is confirmed, at the rate at that moment.',
    };
  });

  /// One permanent address per customer, asset and network. The first
  /// request shows "Generating address" for a moment, like the real provider call.
  Json cryptoDepositAddress(String token, String assetId) => _mutate(() {
    final u = _user(token);
    _requireTier(u, 1, 'crypto deposits');
    final a = _depAsset(assetId);
    final id = '${u['id']}|$assetId';
    var row = db.get('crypto_addresses', id);
    if (row == null) {
      final h = sha256Hex('${u['id']}:$assetId');
      final address = switch (a['symbol']) {
        'BTC' => 'tb1q${h.substring(0, 38)}',
        'LTC' => 'tltc1q${h.substring(0, 36)}',
        _ when a['network'] == 'TRC20' => 'T${h.substring(0, 33)}',
        _ when a['network'] == 'SOL' => h.substring(0, 44),
        _ => '0x${h.substring(0, 40)}',
      };
      row = {
        'id': id,
        'userId': u['id'],
        'assetId': assetId,
        'symbol': a['symbol'],
        'network': a['network'],
        'networkName': a['networkName'],
        'address': address,
        'label': u['id'], // Knock user id, never email or phone
        'readyAt': now.add(const Duration(milliseconds: 1500)).toIso8601String(),
        'createdAt': nowIso,
      };
      db.insert('crypto_addresses', row);
      _audit(u['id'] as String, 'crypto.address.requested', id);
    }
    final ready = !now.isBefore(DateTime.parse(row['readyAt'] as String));
    return {
      ...row,
      'status': ready ? 'Awaiting Deposit' : 'Generating Address',
      'address': ready ? row['address'] : null,
      'requiredConfirmations': a['confirmations'],
      'minimumUsd': _minUsd,
    };
  });

  Json cryptoDeposits(String token) => _read(() {
    final u = _user(token);
    final list = db.where('crypto_deposits', (d) => d['userId'] == u['id']).toList()
      ..sort((a, b) => (b['createdAt'] as String).compareTo(a['createdAt'] as String));
    return {'items': [for (final d in list) _publicDeposit(d)]};
  });

  Json _publicDeposit(Json d) => {
    'id': d['id'],
    'txnId': d['txnId'],
    'symbol': d['symbol'],
    'networkName': d['networkName'],
    'cryptoAmount': d['cryptoAmount'],
    'usd': d['usd'],
    'status': d['status'],
    'customerStatus': depositCustomerStatus(d),
    'message': depositMessage(d),
    'confirmations': d['confirmations'],
    'requiredConfirmations': d['requiredConfirmations'],
    'creditedKobo': d['creditedKobo'],
    'balanceRemainingUsd': d['balanceRemainingUsd'],
    'createdAt': d['createdAt'],
    'updatedAt': d['updatedAt'],
  };

  static String depositCustomerStatus(Json d) => switch (d['status']) {
    'pending' => (d['confirmations'] as int) == 0 ? 'Deposit Detected' : 'Confirming on Blockchain',
    'below_minimum' => 'Awaiting Top-up',
    'under_review' => 'Deposit Under Review',
    'completed' => 'Deposit Completed',
    _ => 'Deposit Failed',
  };

  static String depositMessage(Json d) => switch (d['status']) {
    'pending' => "We've detected your crypto deposit. We're waiting for the required blockchain confirmations.",
    'below_minimum' => 'This deposit is below the \$${_minUsd.toStringAsFixed(0)} minimum. Send a top-up to the same address and we\'ll credit the total once the minimum is reached.',
    'under_review' => "Your deposit is undergoing additional verification. We'll update you when the review is complete.",
    'completed' => 'Your deposit has been confirmed and your account has been updated.',
    _ => 'This deposit could not be completed and was not credited.',
  };

  /// Sandbox only: send a test-network deposit with one of the provider's
  /// documented sandbox scenarios.
  /// completed | confirming | below_minimum | failed_on_chain | under_review | kyt_hold
  Json sandboxCryptoDeposit(String token, String assetId, {required String scenario, required double usd}) => _mutate(() {
    final u = _user(token);
    final a = _depAsset(assetId);
    final addr = db.get('crypto_addresses', '${u['id']}|$assetId');
    if (addr == null) throw ApiError('no_address', 'Get your deposit address first.');
    final symbol = a['symbol'] as String;
    final price = symbol == 'BTC' ? _cryptoUsd('BTC') : symbol == 'LTC' ? 85.0 : 1.0;
    final qty = usd / price;
    final t = _newTxn(
      u,
      type: 'crypto_deposit',
      title: '$symbol deposit',
      subtitle: '${Fmt3.qty(qty)} $symbol · ${a['networkName']}',
      amount: 0,
      direction: 'credit',
      status: 'pending',
      details: {'asset': symbol, 'quantity': qty, 'network': a['networkName'], 'customerStatus': 'Deposit Detected', 'sandbox': true},
      timeline: [_step('Deposit detected', note: 'Waiting for blockchain confirmations')],
    );
    final d = <String, dynamic>{
      'id': newId('cdp'),
      'userId': u['id'],
      'txnId': t['id'],
      'addressId': addr['id'],
      'assetId': assetId,
      'symbol': symbol,
      'networkName': a['networkName'],
      'cryptoAmount': qty,
      'usd': usd,
      'scenario': scenario,
      'status': scenario == 'under_review' ? 'under_review' : 'pending',
      'confirmations': 0,
      'requiredConfirmations': a['confirmations'],
      'nextAt': now.add(const Duration(seconds: 3)).toIso8601String(),
      'createdAt': nowIso,
      'updatedAt': nowIso,
    };
    db.insert('crypto_deposits', d);
    if (d['status'] == 'under_review') _depositUnderReview(d, t);
    _notify(u['id'] as String, 'transaction', 'Deposit detected', depositMessage(d), action: {'route': 'txn', 'id': t['id']});
    return _ok({'deposit': _publicDeposit(d)});
  });

  /// Background job: confirmations arrive, deposits complete, reviews end.
  void _runCryptoDepositJobs() {
    for (final d in db.where('crypto_deposits', (d) => d['status'] == 'pending' || d['status'] == 'under_review').toList()) {
      if (now.isBefore(DateTime.parse(d['nextAt'] as String))) continue;
      final t = db.get('txns', d['txnId'] as String)!;
      final scenario = d['scenario'] as String;
      d['updatedAt'] = nowIso;
      d['nextAt'] = now.add(const Duration(seconds: 3)).toIso8601String();
      if (d['status'] == 'under_review') {
        if (scenario == 'under_review') {
          d['status'] = 'failed';
          d['failureReason'] = 'rejected_after_review';
          _finishDeposit(d, t, 'failed', 'Review completed', 'This deposit did not pass review and was not credited.');
        }
        db.put('crypto_deposits', d);
        continue;
      }
      final confs = (d['confirmations'] as int) + 1;
      final required = d['requiredConfirmations'] as int;
      if (scenario == 'failed_on_chain') {
        d['status'] = 'failed';
        d['failureReason'] = 'failed_on_chain';
        _finishDeposit(d, t, 'failed', 'Failed on the blockchain', 'The transaction failed on the blockchain. Nothing was credited.');
      } else if (scenario == 'confirming' && confs >= required) {
        d['confirmations'] = required - 1; // stays confirming
      } else if (confs < required) {
        d['confirmations'] = confs;
        (t['details'] as Map)['customerStatus'] = 'Confirming on Blockchain';
        (t['timeline'] as List).add(_step('Confirmation $confs of $required'));
        t['updatedAt'] = nowIso;
        db.put('txns', t);
      } else if (scenario == 'kyt_hold') {
        d['confirmations'] = required;
        _depositUnderReview(d, t);
      } else if (scenario == 'below_minimum' || (d['usd'] as num) < _minUsd) {
        d['confirmations'] = required;
        final held = _heldUsdAt(d['addressId'] as String, except: d['id'] as String);
        if ((d['usd'] as num) + held < _minUsd) {
          d['status'] = 'below_minimum';
          d['balanceRemainingUsd'] = _minUsd - (d['usd'] as num) - held;
          (t['details'] as Map)['customerStatus'] = 'Awaiting Top-up';
          (t['timeline'] as List).add(_step('Below minimum', note: depositMessage(d)));
          t['updatedAt'] = nowIso;
          db.put('txns', t);
          _notify(d['userId'] as String, 'transaction', 'Deposit below minimum', depositMessage(d), action: {'route': 'txn', 'id': t['id']});
        } else {
          _completeDeposit(d, t);
        }
      } else {
        d['confirmations'] = required;
        _completeDeposit(d, t);
      }
      db.put('crypto_deposits', d);
    }
  }

  double _heldUsdAt(String addressId, {required String except}) => db
      .where('crypto_deposits', (x) => x['addressId'] == addressId && x['status'] == 'below_minimum' && x['id'] != except)
      .fold<double>(0, (s, x) => s + (x['usd'] as num).toDouble());

  void _depositUnderReview(Json d, Json t) {
    d['status'] = 'under_review';
    (t['details'] as Map)['customerStatus'] = 'Deposit Under Review';
    (t['timeline'] as List).add(_step('Under review', note: depositMessage(d)));
    t['updatedAt'] = nowIso;
    db.put('txns', t);
    _notify(d['userId'] as String, 'transaction', 'Deposit under review', depositMessage(d), action: {'route': 'txn', 'id': t['id']});
  }

  /// Credits the Naira wallet once. Earlier below-minimum deposits at the
  /// same address are settled together with this one, never credited twice.
  void _completeDeposit(Json d, Json t) {
    final batch = db.where('crypto_deposits', (x) => x['addressId'] == d['addressId'] && x['status'] == 'below_minimum').toList();
    final usd = (d['usd'] as num).toDouble() + batch.fold<double>(0, (s, x) => s + (x['usd'] as num).toDouble());
    // The provider reports the credited Naira amount (rate and its fee applied).
    final credited = (usd * cryptoSellNgnPerUsd * 100).round();
    d['status'] = 'completed';
    d['creditedKobo'] = credited;
    t['amount'] = credited;
    (t['details'] as Map)['customerStatus'] = 'Deposit Completed';
    (t['details'] as Map)['rate'] = '₦$cryptoSellNgnPerUsd per \$1';
    if (batch.isNotEmpty) (t['details'] as Map)['includesTopUps'] = batch.length;
    _post(t['id'] as String, 'NGN', {'sys:crypto_partner_ngn': -credited, KnockServer.walletAcct(d['userId'] as String): credited}, memo: 'Crypto deposit');
    _setTxnStatus(t, 'successful', step: 'Deposit completed', note: 'Converted at ₦$cryptoSellNgnPerUsd per \$1');
    for (final x in batch) {
      x['status'] = 'completed';
      x['settledVia'] = d['id'];
      x['creditedKobo'] = 0;
      x['updatedAt'] = nowIso;
      db.put('crypto_deposits', x);
      final xt = db.get('txns', x['txnId'] as String);
      if (xt != null) {
        (xt['details'] as Map)['customerStatus'] = 'Deposit Completed';
        (xt['details'] as Map)['settledWith'] = t['reference'];
        _setTxnStatus(xt, 'successful', step: 'Credited with your top-up', note: 'Included in ${t['reference']}');
      }
    }
    _notify(d['userId'] as String, 'transaction', 'Deposit completed', '${_naira(credited)} has been added to your wallet. ${depositMessage(d)}', action: {'route': 'txn', 'id': t['id']});
    _audit(d['userId'] as String, 'crypto.deposit.completed', d['id'] as String, {'creditedKobo': credited});
  }

  void _finishDeposit(Json d, Json t, String status, String step, String note) {
    (t['details'] as Map)['customerStatus'] = 'Deposit Failed';
    _setTxnStatus(t, status, step: step, note: note);
    _notify(d['userId'] as String, 'transaction', 'Deposit not completed', note, action: {'route': 'txn', 'id': t['id']});
  }
}
