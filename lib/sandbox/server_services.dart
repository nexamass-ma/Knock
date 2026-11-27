part of 'server.dart';

/// Bills, betting, e-pins and eSIM. Providers are simulated.
extension ServicesApi on KnockServer {
  Json servicesCatalog(String token) => _read(() {
    _user(token);
    Json plan(Plan p) => {'id': p.id, 'name': p.name, 'price': p.priceNgn * 100, 'detail': p.detail};
    Json biller(Biller b) => {'id': b.id, 'name': b.name, 'kind': b.kind, 'color': b.color, 'plans': [for (final p in b.plans) plan(p)]};
    return {
      'networks': [for (final b in networks) biller(b)],
      'dataPlans': [for (final p in dataPlans) plan(p)],
      'discos': [for (final b in discos) biller(b)],
      'cable': [for (final b in cableProviders) biller(b)],
      'betting': [for (final b in bettingProviders) biller(b)],
      'epins': [
        for (final e in epinProducts) {'id': e.id, 'name': e.name, 'group': e.group, 'price': e.priceNgn * 100, 'detail': e.detail},
      ],
      'esim': [
        for (final e in esimPackages)
          {
            'id': e.id,
            'region': e.region,
            'flag': e.flag,
            'dataGb': e.dataGb,
            'days': e.days,
            'usd': e.usd,
            'price': (e.usd * cryptoBuyNgnPerUsd * 100).round(),
          },
      ],
      'note': 'Sandbox providers. No real airtime, bills, bets, PINs or eSIMs are issued.',
    };
  });

  /// Looks up the customer name for a meter, smartcard or betting account.
  Json validateCustomer(String token, {required String kind, required String billerId, required String customerId}) => _read(() {
    final u = _user(token);
    _rateLimit('validate:${u['id']}', 30, const Duration(minutes: 10));
    final id = customerId.replaceAll(RegExp(r'\s'), '');
    final ok = switch (kind) {
      'electricity' => RegExp(r'^\d{11,13}$').hasMatch(id),
      'cable' => RegExp(r'^\d{10,11}$').hasMatch(id),
      'betting' => RegExp(r'^[A-Za-z0-9]{5,15}$').hasMatch(id),
      _ => true,
    };
    if (!ok || id.startsWith('000')) {
      throw ApiError('not_found', switch (kind) {
        'electricity' => 'We could not find that meter number.',
        'cable' => 'We could not find that smartcard or IUC number.',
        _ => 'We could not find that account.',
      });
    }
    final names = ['A. Bello', 'C. Eze', 'F. Adeyemi', 'T. Okonkwo', 'M. Ibrahim', 'K. Mensah'];
    final name = kind == 'betting' ? (u['fullName'] as String) : names[id.codeUnits.fold<int>(0, (a, b) => a + b) % names.length];
    return {'customerName': name, 'customerId': id, 'address': kind == 'electricity' ? '12 Admiralty Way, Lekki (sandbox)' : null};
  });

  Json purchaseService(
    String token, {
    required String kind,
    required String billerId,
    String? planId,
    int? amountKobo,
    required String customer,
    String? customerName,
    required String pin,
    required String idempotencyKey,
    String? nonce,
    String? sentAt,
    bool confirmedAdult = false,
  }) => _mutate(() {
    _checkReplay(nonce, sentAt);
    final u = _user(token);
    _requireTier(u, kind == 'betting' ? 2 : 1, switch (kind) {
      'betting' => 'betting wallet funding',
      'esim' => 'eSIM',
      'epin' => 'e-pins',
      _ => 'bill payments',
    });
    late String title;
    late String subtitle;
    late int price;
    final details = <String, dynamic>{'customer': customer, 'provider': billerId, 'customerName': ?customerName};
    var status = 'successful';
    switch (kind) {
      case 'airtime':
        final n = networks.firstWhere((b) => b.id == billerId, orElse: () => throw ApiError('bad_request', 'Choose a network.'));
        if (normalisePhone('NG', customer) == null) throw ApiError('invalid_phone', 'Enter a valid Nigerian mobile number.');
        price = amountKobo ?? 0;
        if (price < 5000 || price > 5000000) throw ApiError('bad_amount', 'Airtime must be between ₦50 and ₦50,000.');
        title = '${n.name} airtime';
        subtitle = customer;
      case 'data':
        final n = networks.firstWhere((b) => b.id == billerId, orElse: () => throw ApiError('bad_request', 'Choose a network.'));
        if (normalisePhone('NG', customer) == null) throw ApiError('invalid_phone', 'Enter a valid Nigerian mobile number.');
        final p = dataPlans.firstWhere((p) => p.id == planId, orElse: () => throw ApiError('bad_request', 'Choose a data plan.'));
        price = p.priceNgn * 100;
        title = '${n.name} data · ${p.name}';
        subtitle = '$customer · ${p.detail}';
        details['plan'] = '${p.name}, ${p.detail}';
      case 'electricity':
        final d = discos.firstWhere((b) => b.id == billerId, orElse: () => throw ApiError('bad_request', 'Choose your electricity company.'));
        price = amountKobo ?? 0;
        if (price < 100000) throw ApiError('bad_amount', 'The minimum electricity purchase is ₦1,000.');
        title = '${d.name} prepaid';
        subtitle = 'Meter $customer';
        status = 'pending';
      case 'cable':
        final c = cableProviders.firstWhere((b) => b.id == billerId, orElse: () => throw ApiError('bad_request', 'Choose a TV provider.'));
        final p = c.plans.firstWhere((p) => p.id == planId, orElse: () => throw ApiError('bad_request', 'Choose a package.'));
        price = p.priceNgn * 100;
        title = '${c.name} ${p.name}';
        subtitle = 'Smartcard $customer';
        details['plan'] = p.name;
      case 'betting':
        final b = bettingProviders.firstWhere((b) => b.id == billerId, orElse: () => throw ApiError('bad_request', 'Choose a provider.'));
        if (!confirmedAdult) throw ApiError('age', 'Please confirm you are 18 or older.');
        price = amountKobo ?? 0;
        if (price < 10000 || price > 50000000) throw ApiError('bad_amount', 'Funding must be between ₦100 and ₦500,000.');
        title = '${b.name} wallet funding';
        subtitle = 'Account $customer';
        details['responsibleGambling'] = 'Set limits and take breaks. Help is available from your provider.';
      case 'epin':
        final e = epinProducts.firstWhere((e) => e.id == billerId, orElse: () => throw ApiError('bad_request', 'Choose a product.'));
        final qty = (amountKobo ?? 1).clamp(1, 10);
        price = e.priceNgn * 100 * qty;
        title = qty > 1 ? '${e.name} × $qty' : e.name;
        subtitle = e.detail;
        details['quantity'] = qty;
        details['pinsSealed'] = [for (var i = 0; i < qty; i++) _vault.seal(_fakePin(e.group))];
        details['serials'] = [for (var i = 0; i < qty; i++) 'SN${_rng.nextInt(900000000) + 100000000}'];
      case 'esim':
        final e = esimPackages.firstWhere((e) => e.id == billerId, orElse: () => throw ApiError('bad_request', 'Choose a package.'));
        price = (e.usd * cryptoBuyNgnPerUsd * 100).round();
        title = '${e.region} eSIM';
        subtitle = '${e.dataGb == 0 ? 'Unlimited' : '${e.dataGb}GB'} · ${e.days} days';
        final code = randomToken(12).toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), 'K');
        details.addAll({
          'region': e.region,
          'flag': e.flag,
          'package': subtitle,
          'usd': e.usd,
          'iccid': '8988${List.generate(15, (_) => _rng.nextInt(10)).join()}',
          'smdp': 'sandbox.esim.knock.app',
          'activationCode': code,
          'lpa': 'LPA:1\$sandbox.esim.knock.app\$$code',
          'esimStatus': 'Ready to install',
        });
        details.remove('customer');
      default:
        throw ApiError('bad_request', 'Unknown service.');
    }
    _checkLimits(u, price);
    _authorise(u, pin);
    final t = _newTxn(
      u,
      type: kind,
      title: title,
      subtitle: subtitle,
      amount: -price,
      status: status,
      idempotencyKey: idempotencyKey,
      details: {...details, 'settlement': status == 'pending' ? 'Waiting for provider' : 'Delivered by provider (sandbox)'},
      timeline: [_step('Paid from wallet'), if (status == 'successful') _step('Delivered')],
    );
    _post(t['id'] as String, 'NGN', {KnockServer.walletAcct(u['id'] as String): -price, 'sys:provider:$kind': price}, memo: title);
    if (status == 'successful') {
      _notify(u['id'] as String, 'transaction', '$title successful', '${_naira(price)} paid. Reference ${t['reference']}.', action: {'route': 'txn', 'id': t['id']});
    }
    _checkChallengesFor(u);
    _audit(u['id'] as String, 'service.$kind', t['id'] as String);
    return _ok({'txn': t});
  });

  /// Returns e-pin codes after the customer re-authenticates.
  Json revealPins(String token, String txnId, String pin) => _mutate(() {
    final u = _user(token);
    final t = db.get('txns', txnId);
    if (t == null || t['userId'] != u['id'] || t['type'] != 'epin') throw ApiError('not_found', 'Not found.');
    _authorise(u, pin);
    final sealed = ((t['details'] as Map)['pinsSealed'] as List).cast<String>();
    _audit(u['id'] as String, 'epin.revealed', txnId);
    return _ok({'pins': [for (final s in sealed) _vault.open(s)], 'serials': (t['details'] as Map)['serials']});
  });

  String _fakePin(String group) => group == 'Exams'
      ? List.generate(12, (_) => _rng.nextInt(10)).join()
      : [for (var i = 0; i < 4; i++) List.generate(4, (_) => _rng.nextInt(10)).join()].join(' ');
}
