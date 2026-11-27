import 'package:flutter_test/flutter_test.dart';
import 'package:knock/sandbox/catalog.dart';
import 'package:knock/sandbox/server.dart';

import 'sandbox_test.dart' show Harness;

/// Crypto deposit lifecycle in the in-app sandbox. Mirrors the backend rules
/// in backend/test/crypto.test.ts: nothing is credited until completion, a
/// completion credits once, below-minimum deposits aggregate, reviews and
/// on-chain failures never credit.
void main() {
  late Harness h;
  late String token;
  int balance() => (h.server.wallet(token)['available'] as int);
  List<Map<String, dynamic>> deposits() => (h.server.cryptoDeposits(token)['items'] as List).cast<Map<String, dynamic>>();

  setUp(() {
    h = Harness();
    token = h.onboard();
  });

  Map<String, dynamic> address([String asset = 'USDT_TRC20']) {
    var a = h.server.cryptoDepositAddress(token, asset);
    expect(a['status'], 'Generating Address');
    expect(a['address'], isNull);
    h.advance(const Duration(seconds: 2));
    a = h.server.cryptoDepositAddress(token, asset);
    expect(a['status'], 'Awaiting Deposit');
    return a;
  }

  test('one permanent address per asset and network, labelled with the user id', () {
    final a = address();
    expect(h.server.cryptoDepositAddress(token, 'USDT_TRC20')['address'], a['address']);
    expect(a['address'], startsWith('T'));
    expect(a['label'], isNot(contains('@')));
    expect(h.server.cryptoDepositAddress(token, 'BTC')['address'], isNull); // different asset, new address
  });

  test('pending never credits; completion credits once with confirmation progress', () {
    address();
    final start = balance();
    h.server.sandboxCryptoDeposit(token, 'USDT_TRC20', scenario: 'completed', usd: 20);
    expect(deposits().first['customerStatus'], 'Deposit Detected');
    h.advance(const Duration(seconds: 4));
    expect(deposits().first['customerStatus'], 'Confirming on Blockchain');
    expect(balance(), start);
    h.advance(const Duration(seconds: 12));
    final d = deposits().first;
    expect(d['customerStatus'], 'Deposit Completed');
    expect(balance(), start + 20 * cryptoSellNgnPerUsd * 100);
    h.advance(const Duration(seconds: 30));
    expect(balance(), start + 20 * cryptoSellNgnPerUsd * 100); // never twice
  });

  test('below minimum is held, then credited together with the top-up', () {
    address();
    final start = balance();
    h.server.sandboxCryptoDeposit(token, 'USDT_TRC20', scenario: 'below_minimum', usd: 4);
    h.advance(const Duration(seconds: 15));
    expect(deposits().first['customerStatus'], 'Awaiting Top-up');
    expect(balance(), start);
    h.server.sandboxCryptoDeposit(token, 'USDT_TRC20', scenario: 'completed', usd: 7);
    h.advance(const Duration(seconds: 15));
    expect(deposits().every((d) => d['customerStatus'] == 'Deposit Completed'), isTrue);
    expect(balance(), start + 11 * cryptoSellNgnPerUsd * 100);
  });

  test('review, on-chain failure and KYT hold never credit', () {
    address();
    final start = balance();
    h.server.sandboxCryptoDeposit(token, 'USDT_TRC20', scenario: 'under_review', usd: 50);
    h.server.sandboxCryptoDeposit(token, 'USDT_TRC20', scenario: 'failed_on_chain', usd: 50);
    h.server.sandboxCryptoDeposit(token, 'USDT_TRC20', scenario: 'kyt_hold', usd: 50);
    h.advance(const Duration(seconds: 20));
    final statuses = deposits().map((d) => d['customerStatus']).toList();
    expect(statuses, containsAll(['Deposit Failed', 'Deposit Under Review']));
    expect(statuses.where((s) => s == 'Deposit Failed').length, 2);
    expect(balance(), start);
    final txt = deposits().toString().toLowerCase();
    expect(txt.contains('breet'), isFalse); // provider never shown to customers
  });
}
