part of 'server.dart';

/// Wallets, deposits, withdrawals, crypto and transaction history.
extension WalletApi on KnockServer {
  Json wallet(String token) => _read(() {
    final u = _user(token);
    final uid = u['id'] as String;
    final holdings = <Json>[];
    var cryptoKobo = 0;
    for (final a in cryptoAssets) {
      final units = balanceOf(KnockServer.cryptoAcct(uid, a.symbol));
      if (units == 0) continue;
      final qty = units / pow(10, a.decimals);
      final valueKobo = (qty * _cryptoUsd(a.symbol) * cryptoSellNgnPerUsd * 100).round();
      cryptoKobo += valueKobo;
      holdings.add({'symbol': a.symbol, 'name': a.name, 'units': units, 'quantity': qty, 'valueKobo': valueKobo});
    }
    final pending = db
        .where('txns', (t) => t['userId'] == uid && t['status'] == 'pending' && t['direction'] == 'credit')
        .fold<int>(0, (a, t) => a + (t['amount'] as int));
    return {
      'available': balanceOf(KnockServer.walletAcct(uid)),
      'bonus': balanceOf(KnockServer.bonusAcct(uid)),
      'pendingIn': pending,
      'cryptoValue': cryptoKobo,
      'holdings': holdings,
      'currency': 'NGN',
      'bonusNote': 'Bonus balance is not withdrawable. How it can be used will be announced before launch.',
    };
  });

  // ---- Deposits --------------------------------------------------------------

  Json depositInstructions(String token) => _read(() {
    final u = _user(token);
    _requireTier(u, 1, 'deposits');
    final digits = sha256Hex(u['id'] as String).replaceAll(RegExp(r'[^0-9]'), '');
    return {
      'bankName': 'Knock Sandbox Bank',
      'accountNumber': '90${digits.substring(0, 8)}',
      'accountName': 'Knock / ${u['fullName']}',
      'note': 'Sandbox account. No real bank transfer will arrive here. Use "Simulate a transfer" to test.',
      'fee': 0,
    };
  });

  /// Sandbox stand-in for a customer making a bank transfer. The payment
  /// provider later calls our webhook, which is signature-verified.
  Json simulateDeposit(String token, int amountKobo) => _mutate(() {
    final u = _user(token);
    _requireTier(u, 1, 'deposits');
    if (amountKobo < 10000) throw ApiError('min', 'The minimum deposit is ₦100.');
    if (amountKobo > 500000000) throw ApiError('max', 'The sandbox accepts up to ₦5,000,000 per transfer.');
    final t = _newTxn(
      u,
      type: 'deposit',
      title: 'Bank deposit',
      subtitle: 'Bank transfer',
      amount: amountKobo,
      direction: 'credit',
      details: {'method': 'Bank transfer (sandbox)', 'sender': u['fullName']},
      timeline: [_step('Transfer detected')],
    );
    final event = {'id': newId('evt'), 'type': 'transfer.received', 'txnId': t['id'], 'amount': amountKobo};
    final body = jsonEncode(event);
    db.insert('webhooks', {
      'id': event['id'],
      'body': body,
      'signature': _hmac(body),
      'deliverAt': now.add(const Duration(seconds: 4)).toIso8601String(),
    });
    return _ok({'txn': t});
  });

  /// Payment provider webhook. Rejects bad signatures and replays.
  Json providerWebhook(String body, String signature) => _mutate(() {
    if (!constantTimeEquals(_hmac(body), signature)) {
      _audit('provider', 'webhook.bad_signature', 'payments');
      throw ApiError('bad_signature', 'Invalid webhook signature.');
    }
    final event = jsonDecode(body) as Json;
    if (db.get('webhook_events', event['id'] as String) != null) return _ok({'duplicate': true});
    db.insert('webhook_events', {'id': event['id'], 'at': nowIso});
    if (event['type'] == 'transfer.received') {
      final t = db.get('txns', event['txnId'] as String);
      if (t == null || t['status'] != 'pending') return _ok();
      if (t['amount'] != event['amount']) throw ApiError('mismatch', 'Amount mismatch');
      _post(t['id'] as String, 'NGN', {'sys:bank_settlement': -(t['amount'] as int), KnockServer.walletAcct(t['userId'] as String): t['amount'] as int}, memo: 'Deposit');
      _setTxnStatus(t, 'successful', step: 'Credited to your wallet');
      t['details'] = {...t['details'] as Map, 'settlement': 'Settled to Naira wallet'};
      db.put('txns', t);
      _notify(t['userId'] as String, 'transaction', 'Deposit received', '${_naira(t['amount'] as int)} has been added to your wallet.', action: {'route': 'txn', 'id': t['id']});
    }
    _audit('provider', 'webhook.${event['type']}', event['id'] as String);
    return _ok();
  });

  // ---- Withdrawals ----------------------------------------------------------

  static const withdrawalFeeKobo = 5000;

  Json withdraw(String token, {required int amountKobo, required String pin, required String idempotencyKey, String? nonce, String? sentAt}) =>
      _mutate(() {
        _checkReplay(nonce, sentAt);
        final u = _user(token);
        _requireTier(u, 2, 'withdrawals');
        _requireNoHold(u, 'Withdrawals');
        final k = db.get('kyc', u['id'] as String);
        final t2 = k?['tier2'] as Map?;
        if (t2?['bankVerified'] != true) throw ApiError('no_bank', 'Add and verify a bank account first.', details: {'tier': 2});
        if (amountKobo < 100000) throw ApiError('min', 'The minimum withdrawal is ₦1,000.');
        _checkLimits(u, amountKobo);
        _authorise(u, pin);
        final t = _newTxn(
          u,
          type: 'withdrawal',
          title: 'Withdrawal',
          subtitle: '${t2!['bankName']} •••• ${t2['accountLast4']}',
          amount: -amountKobo,
          fee: withdrawalFeeKobo,
          idempotencyKey: idempotencyKey,
          details: {'bank': t2['bankName'], 'accountName': t2['accountName'], 'last4': t2['accountLast4']},
          timeline: [_step('Withdrawal requested')],
        );
        _post(t['id'] as String, 'NGN', {
          KnockServer.walletAcct(u['id'] as String): -(amountKobo + withdrawalFeeKobo),
          'sys:payouts_in_flight': amountKobo,
          'sys:fees': withdrawalFeeKobo,
        }, memo: 'Withdrawal');
        _audit(u['id'] as String, 'wallet.withdraw', t['id'] as String, {'amount': amountKobo});
        return _ok({'txn': t});
      });

  void _runSettlementJobs() {
    // Deliver queued provider webhooks.
    for (final w in db.table('webhooks').values.toList()) {
      if (now.isBefore(DateTime.parse(w['deliverAt'] as String))) continue;
      db.delete('webhooks', w['id'] as String);
      providerWebhook(w['body'] as String, w['signature'] as String);
    }
    for (final t in db.where('txns', (t) => t['status'] == 'pending').toList()) {
      final age = now.difference(DateTime.parse(t['createdAt'] as String)).inSeconds;
      switch (t['type']) {
        case 'withdrawal' when age >= 8:
          if ((t['timeline'] as List).length < 2) {
            (t['timeline'] as List).add(_step('Sent to your bank'));
          }
          final amt = -(t['amount'] as int);
          _post(t['id'] as String, 'NGN', {'sys:payouts_in_flight': -amt, 'sys:bank_settlement': amt}, memo: 'Payout settled');
          _setTxnStatus(t, 'successful', step: 'Paid to your bank');
          t['details'] = {...t['details'] as Map, 'settlement': 'Paid to ${(t['details'] as Map)['bank']}'};
          db.put('txns', t);
          _notify(t['userId'] as String, 'transaction', 'Withdrawal complete', '${_naira(amt)} has been sent to your bank.', action: {'route': 'txn', 'id': t['id']});
        case 'giftcard_sell':
          _advanceTrade(t);
        case 'electricity' when age >= 3:
          final token = List.generate(20, (_) => _rng.nextInt(10)).join();
          final grouped = [for (var i = 0; i < 20; i += 4) token.substring(i, i + 4)].join('-');
          t['details'] = {...t['details'] as Map, 'token': grouped, 'units': '${((-(t['amount'] as int)) / 100 / 68).toStringAsFixed(1)} kWh'};
          _setTxnStatus(t, 'successful', step: 'Token issued');
          _notify(t['userId'] as String, 'transaction', 'Electricity token ready', 'Your token for ${(t['details'] as Map)['customer']} is ready.', action: {'route': 'txn', 'id': t['id']});
      }
    }
  }

  // ---- Crypto ------------------------------------------------------------------

  double _cryptoUsd(String symbol) {
    final r = db.get('crypto_prices', symbol);
    return (r?['usd'] as num?)?.toDouble() ?? cryptoBySymbol(symbol).usdPrice;
  }

  Json cryptoMarkets(String token) => _read(() {
    _user(token);
    return {
      'buyNgnPerUsd': cryptoBuyNgnPerUsd,
      'sellNgnPerUsd': cryptoSellNgnPerUsd,
      'assets': [
        for (final a in cryptoAssets)
          {
            'symbol': a.symbol,
            'name': a.name,
            'usd': _cryptoUsd(a.symbol),
            'buyNgn': (_cryptoUsd(a.symbol) * cryptoBuyNgnPerUsd * 100).round(),
            'sellNgn': (_cryptoUsd(a.symbol) * cryptoSellNgnPerUsd * 100).round(),
            'change24h': (db.get('crypto_prices', a.symbol)?['change24h'] as num?)?.toDouble() ?? 0,
            'updatedAt': db.get('crypto_prices', a.symbol)?['updatedAt'] ?? nowIso,
          },
      ],
    };
  });

  /// [side] buy: amountKobo NGN to spend. sell: units of the asset to sell.
  Json cryptoQuote(String token, {required String side, required String symbol, int? amountKobo, int? units}) => _mutate(() {
    final u = _user(token);
    _requireTier(u, 1, 'crypto');
    final a = cryptoBySymbol(symbol);
    final usd = _cryptoUsd(symbol);
    int ngnKobo;
    int qtyUnits;
    int fee;
    if (side == 'buy') {
      if (amountKobo == null || amountKobo < 100000) throw ApiError('min', 'The minimum purchase is ₦1,000.');
      fee = (amountKobo * 0.01).round().clamp(10000, 1000000);
      final spend = amountKobo - fee;
      final qty = spend / 100 / cryptoBuyNgnPerUsd / usd;
      qtyUnits = (qty * pow(10, a.decimals)).floor();
      ngnKobo = amountKobo;
      _checkLimits(u, amountKobo);
    } else {
      final held = balanceOf(KnockServer.cryptoAcct(u['id'] as String, symbol));
      if (units == null || units <= 0) throw ApiError('bad_request', 'Enter an amount to sell.');
      if (units > held) throw ApiError('insufficient_funds', 'You only have ${Fmt3.qty(held / pow(10, a.decimals))} $symbol.');
      qtyUnits = units;
      final gross = (units / pow(10, a.decimals) * usd * cryptoSellNgnPerUsd * 100).round();
      fee = (gross * 0.005).round().clamp(5000, 500000);
      ngnKobo = gross - fee;
      if (ngnKobo < 50000) throw ApiError('min', 'The minimum sale is worth ₦500.');
      _checkLimits(u, gross);
    }
    final q = {
      'id': newId('cq'),
      'userId': u['id'],
      'side': side,
      'symbol': symbol,
      'units': qtyUnits,
      'quantity': qtyUnits / pow(10, a.decimals),
      'ngnKobo': ngnKobo,
      'fee': fee,
      'usdPrice': usd,
      'ngnPerUsd': side == 'buy' ? cryptoBuyNgnPerUsd : cryptoSellNgnPerUsd,
      'expiresAt': now.add(const Duration(seconds: 30)).toIso8601String(),
      'status': 'open',
      'createdAt': nowIso,
    };
    db.insert('crypto_quotes', q);
    return _ok({'quote': q});
  });

  Json cryptoExecute(String token, {required String quoteId, required String pin, required String idempotencyKey, String? nonce, String? sentAt}) =>
      _mutate(() {
        _checkReplay(nonce, sentAt);
        final u = _user(token);
        final q = db.get('crypto_quotes', quoteId);
        if (q == null || q['userId'] != u['id']) throw ApiError('not_found', 'Quote not found.');
        if (q['status'] != 'open') throw ApiError('quote_used', 'This quote has already been used. Get a new quote.');
        if (now.isAfter(DateTime.parse(q['expiresAt'] as String))) {
          throw ApiError('quote_expired', 'This price has expired. Get a fresh quote to continue.');
        }
        _authorise(u, pin);
        final uid = u['id'] as String;
        final sym = q['symbol'] as String;
        final buy = q['side'] == 'buy';
        final usdCents = (((q['units'] as int) / pow(10, cryptoBySymbol(sym).decimals)) * (q['usdPrice'] as num) * 100).round();
        final t = _newTxn(
          u,
          type: buy ? 'crypto_buy' : 'crypto_sell',
          title: buy ? 'Bought $sym' : 'Sold $sym',
          subtitle: '${Fmt3.qty((q['quantity'] as num).toDouble())} $sym',
          amount: buy ? -(q['ngnKobo'] as int) : q['ngnKobo'] as int,
          fee: q['fee'] as int,
          direction: buy ? 'debit' : 'credit',
          status: 'successful',
          idempotencyKey: idempotencyKey,
          details: {
            'asset': sym,
            'quantity': q['quantity'],
            'price': '\$${(q['usdPrice'] as num).toStringAsFixed(2)}',
            'rate': '₦${q['ngnPerUsd']}/\$',
            'eligibleUsdCents': usdCents,
            'settlement': buy ? 'Delivered to your crypto wallet' : 'Settled to Naira wallet',
          },
        );
        if (buy) {
          _post(t['id'] as String, 'NGN', {
            KnockServer.walletAcct(uid): -(q['ngnKobo'] as int),
            'sys:crypto_desk_ngn': (q['ngnKobo'] as int) - (q['fee'] as int),
            'sys:fees': q['fee'] as int,
          }, memo: 'Crypto buy');
          _post(t['id'] as String, sym, {'sys:crypto_desk:$sym': -(q['units'] as int), KnockServer.cryptoAcct(uid, sym): q['units'] as int});
        } else {
          _post(t['id'] as String, sym, {KnockServer.cryptoAcct(uid, sym): -(q['units'] as int), 'sys:crypto_desk:$sym': q['units'] as int});
          _post(t['id'] as String, 'NGN', {
            'sys:crypto_desk_ngn': -((q['ngnKobo'] as int) + (q['fee'] as int)),
            'sys:fees': q['fee'] as int,
            KnockServer.walletAcct(uid): q['ngnKobo'] as int,
          }, memo: 'Crypto sell');
        }
        q['status'] = 'used';
        db.put('crypto_quotes', q);
        _onSettledTrade(u, t);
        _notify(uid, 'transaction', buy ? '$sym purchase complete' : '$sym sale complete', buy ? 'You bought ${t['subtitle']}.' : '${_naira(q['ngnKobo'] as int)} was added to your wallet.', action: {'route': 'txn', 'id': t['id']});
        _audit(uid, 'crypto.${q['side']}', t['id'] as String);
        return _ok({'txn': t});
      });

  Json cryptoReceiveAddress(String token, String symbol) => _read(() {
    final u = _user(token);
    final h = sha256Hex('${u['id']}:$symbol');
    final address = switch (symbol) {
      'BTC' => 'tb1q${h.substring(0, 38)}',
      'SOL' => h.substring(0, 44),
      _ => '0x${h.substring(0, 40)}',
    };
    return {
      'symbol': symbol,
      'network': switch (symbol) { 'BTC' => 'Bitcoin testnet', 'SOL' => 'Solana devnet', 'ETH' => 'Ethereum Sepolia', _ => 'Ethereum Sepolia (ERC-20)' },
      'address': address,
      'note': 'Sandbox test network address. Do not send real funds.',
    };
  });

  /// Sandbox: credits a small test-network deposit so selling can be tried.
  Json simulateCryptoDeposit(String token, String symbol) => _mutate(() {
    final u = _user(token);
    final a = cryptoBySymbol(symbol);
    final qty = switch (symbol) { 'BTC' => 0.002, 'ETH' => 0.05, 'SOL' => 1.5, _ => 150.0 };
    final units = (qty * pow(10, a.decimals)).round();
    final t = _newTxn(
      u,
      type: 'crypto_deposit',
      title: '$symbol received',
      subtitle: '${Fmt3.qty(qty)} $symbol',
      amount: 0,
      direction: 'credit',
      status: 'successful',
      details: {'asset': symbol, 'quantity': qty, 'network': 'Test network (sandbox)'},
    );
    _post(t['id'] as String, symbol, {'sys:chain:$symbol': -units, KnockServer.cryptoAcct(u['id'] as String, symbol): units});
    _notify(u['id'] as String, 'transaction', '$symbol received', '${Fmt3.qty(qty)} $symbol arrived in your wallet.', action: {'route': 'txn', 'id': t['id']});
    return _ok({'txn': t});
  });

  // ---- History -------------------------------------------------------------------

  Json transactions(String token, {String status = 'all', String? type, String? query, int limit = 200}) => _read(() {
    final u = _user(token);
    var list = db.where('txns', (t) => t['userId'] == u['id']).toList();
    if (status != 'all') list = list.where((t) => t['status'] == status).toList();
    if (type != null) list = list.where((t) => _typeGroup(t['type'] as String) == type).toList();
    if (query != null && query.trim().isNotEmpty) {
      final q = query.toLowerCase();
      list = list
          .where((t) => '${t['title']} ${t['subtitle']} ${t['reference']}'.toLowerCase().contains(q))
          .toList();
    }
    list.sort((a, b) => (b['createdAt'] as String).compareTo(a['createdAt'] as String));
    return {'items': list.take(limit).toList()};
  });

  Json transaction(String token, String id) => _read(() {
    final u = _user(token);
    final t = db.get('txns', id) ?? db.firstWhere('txns', (t) => t['reference'] == id);
    // Same answer for "not yours" and "does not exist".
    if (t == null || t['userId'] != u['id']) throw ApiError('not_found', 'Transaction not found.');
    final dispute = db.firstWhere('tickets', (x) => x['txnId'] == t['id'] && x['kind'] == 'dispute');
    return {'txn': t, 'dispute': dispute};
  });
}

String _typeGroup(String type) => switch (type) {
      'giftcard_sell' => 'giftcards',
      'crypto_buy' || 'crypto_sell' || 'crypto_deposit' => 'crypto',
      'deposit' => 'deposits',
      'withdrawal' => 'withdrawals',
      'airtime' || 'data' || 'electricity' || 'cable' => 'bills',
      'betting' => 'betting',
      'epin' => 'epins',
      'esim' => 'esim',
      'gift_send' || 'gift_received' => 'gifts',
      'reward' => 'rewards',
      'referral_payout' => 'referrals',
      _ => 'other',
    };

String _naira(int kobo) => '₦${_groupInt(kobo ~/ 100)}${kobo % 100 == 0 ? '' : '.${(kobo % 100).toString().padLeft(2, '0')}'}';

abstract final class Fmt3 {
  static String qty(double v) {
    var s = v.toStringAsFixed(v >= 100 ? 2 : 6);
    if (s.contains('.')) s = s.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
    return s;
  }
}
