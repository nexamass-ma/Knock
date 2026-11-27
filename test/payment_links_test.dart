import 'package:flutter_test/flutter_test.dart';
import 'package:knock/features/payment_links/pl_models.dart';
import 'package:knock/features/payment_links/pl_sandbox.dart';
import 'package:knock/features/payment_links/pl_split.dart';

// Acceptance tests from the Payment Links brief, run against the in-app
// sandbox engine. The same scenarios run against Postgres in backend/test.

const ngn = PlAsset.ngn;
int naira(int major) => major * 100;

void main() {
  late PlSandbox sb;
  late KnockUser me, mary, innocent, favour;

  setUp(() {
    sb = PlSandbox(seed: false);
    me = sb.me;
    mary = sb.user('u_mary');
    innocent = sb.user('u_innocent');
    favour = sb.user('u_favour');
  });

  PaymentLink split4({SettlementMode mode = SettlementMode.eachPayment, SplitMethod method = SplitMethod.percentage}) => sb.createLink(
    type: LinkType.split,
    title: 'Team',
    asset: ngn,
    amountMode: AmountMode.flexible,
    target: naira(500000),
    splitMethod: method,
    settlementMode: mode,
    recipients: method == SplitMethod.percentage
        ? [(me, 0, 4000), (mary, 0, 3000), (innocent, 0, 2000), (favour, 0, 1000)]
        : [(me, naira(200000), 0), (mary, naira(150000), 0), (innocent, naira(100000), 0), (favour, naira(50000), 0)],
  );

  LinkPayment pay(PaymentLink l, int amount) {
    final p = sb.startCheckout(l, amount: amount, method: PayMethod.bankTransfer, payerEmail: 'p${sb.payments.length}@x.com');
    sb.simulateProviderPayment(p);
    return p;
  }

  Map<String, int> netBy(String paymentId) => {
    for (final a in sb.allocations.where((a) => a.paymentId == paymentId)) a.recipient.username: a.net,
  };

  group('split maths', () {
    test('largest remainder always sums exactly', () {
      expect(PlSplit.splitAmount(100001, [1, 1, 1]), [33334, 33334, 33333]);
      expect(PlSplit.splitAmount(naira(100000), [4000, 3000, 2000, 1000]), [naira(40000), naira(30000), naira(20000), naira(10000)]);
      for (var t = 0; t < 2000; t += 37) {
        expect(PlSplit.splitAmount(t, [3, 7, 11]).reduce((a, b) => a + b), t);
      }
    });

    test('percentages derive from fixed amounts', () {
      final rules = PlSplit.buildRules(
        creator: me,
        method: SplitMethod.fixed,
        target: naira(500000),
        remainderToCreator: false,
        input: [(me, naira(200000), 0), (mary, naira(150000), 0), (innocent, naira(100000), 0), (favour, naira(50000), 0)],
      );
      expect(rules.map((r) => r.basisPoints), [4000, 3000, 2000, 1000]);
    });

    test('7. allocation must match total unless remainder goes to creator', () {
      expect(
        () => PlSplit.buildRules(
          creator: me,
          method: SplitMethod.fixed,
          target: naira(500000),
          remainderToCreator: false,
          input: [(mary, naira(100000), 0)],
        ),
        throwsA(isA<PlException>()),
      );
      expect(
        () => PlSplit.buildRules(
          creator: me,
          method: SplitMethod.percentage,
          target: null,
          remainderToCreator: false,
          input: [(mary, 0, 6000), (favour, 0, 5000)],
        ),
        throwsA(isA<PlException>()),
      );
      final r = PlSplit.buildRules(
        creator: me,
        method: SplitMethod.fixed,
        target: naira(500000),
        remainderToCreator: true,
        input: [(mary, naira(100000), 0)],
      );
      expect(r.last.user.id, me.id);
      expect(r.last.allocated, naira(400000));
      expect(r.last.isCreatorRemainder, isTrue);
    });

    test('unverified users cannot be recipients', () {
      expect(
        () => PlSplit.buildRules(
          creator: me,
          method: SplitMethod.percentage,
          target: null,
          remainderToCreator: false,
          input: [(sb.user('u_david'), 0, 10000)],
        ),
        throwsA(isA<PlException>()),
      );
    });
  });

  test('1-2. fixed and flexible Naira links', () {
    final fixed = sb.createLink(type: LinkType.naira, title: 'Tote', asset: ngn, amountMode: AmountMode.fixed, fixedAmount: naira(15000));
    final q = sb.quote(fixed, 999);
    expect(q.amount, naira(15000));
    expect(q.knockFee, naira(225)); // [Guess] 1.5%
    final flex = sb.createLink(type: LinkType.naira, title: 'Tips', asset: ngn, amountMode: AmountMode.flexible);
    expect(() => sb.quote(flex, null), throwsA(isA<PlException>()));
    final p = pay(flex, naira(2000));
    expect(p.status, PayStatus.succeeded);
    expect(netBy(p.id)['chanor'], naira(2000) - naira(30));
    expect(sb.reconcile(), isEmpty);
  });

  test('3. crypto link credits only after required confirmations', () {
    final l = sb.createLink(
      type: LinkType.crypto,
      title: 'Deposit',
      asset: PlAsset.crypto.first,
      amountMode: AmountMode.fixed,
      fixedAmount: 150000000,
    );
    final p = sb.startCheckout(l, method: PayMethod.crypto);
    expect(p.address, startsWith('T'));
    expect(sb.simulateChain(p, 3), contains('waiting'));
    expect(p.status, PayStatus.confirming);
    expect(sb.allocations, isEmpty);
    expect(sb.simulateChain(p, 1, network: 'BEP20'), contains('wrong network'));
    expect(sb.simulateChain(p, 20), contains('split'));
    expect(p.status, PayStatus.succeeded);
    expect(sb.walletOf(me.id, 'USDT').available, 150000000 - 1500000);
    expect(sb.reconcile(), isEmpty);
  });

  test('8-10. partial and multiple payments split independently (brief example)', () {
    final l = split4();
    final p1 = pay(l, naira(100000));
    final fee1 = p1.knockFee; // ₦1,500, shared pro rata
    expect(netBy(p1.id), {
      'chanor': naira(40000) - fee1 * 4 ~/ 10,
      'mary': naira(30000) - fee1 * 3 ~/ 10,
      'innocent': naira(20000) - fee1 * 2 ~/ 10,
      'favour': naira(10000) - fee1 ~/ 10,
    });
    final p2 = pay(l, naira(50000));
    expect(sb.allocations.where((a) => a.paymentId == p2.id).map((a) => a.gross), [naira(20000), naira(15000), naira(10000), naira(5000)]);
    final t = sb.totals(l.id);
    expect(t.collected, naira(150000));
    expect(l.target! - t.collected, naira(350000));
    expect(t.succeeded, 2);
    expect(sb.reconcile(), isEmpty);
  });

  test('payer-pays fee gives recipients their full share', () {
    final l = sb.createLink(
      type: LinkType.split,
      title: 'Event',
      asset: ngn,
      amountMode: AmountMode.flexible,
      feeBearer: FeeBearer.payer,
      recipients: [(mary, 0, 5000), (favour, 0, 5000)],
    );
    final p = pay(l, naira(10000));
    expect(p.grossPaid, naira(10150));
    expect(netBy(p.id), {'mary': naira(5000), 'favour': naira(5000)});
    expect(sb.reconcile(), isEmpty);
  });

  test('5. fixed split fills targets, overflow goes to the creator', () {
    final l = split4(method: SplitMethod.fixed);
    pay(l, naira(250000));
    pay(l, naira(250000));
    final got = <String, int>{};
    for (final a in sb.allocations) {
      got[a.recipient.username] = (got[a.recipient.username] ?? 0) + a.gross;
    }
    expect(got, {'chanor': naira(200000), 'mary': naira(150000), 'innocent': naira(100000), 'favour': naira(50000)});
    expect(l.status, LinkStatus.completed);
  });

  test('11. duplicate webhooks never double-credit', () {
    final l = split4();
    final p = pay(l, naira(100000));
    final before = sb.allocations.length;
    expect(sb.replayWebhook(p), contains('duplicate'));
    expect(sb.simulateProviderPayment(p), contains('duplicate'));
    expect(sb.allocations.length, before);
    expect(sb.simulateProviderPayment(p, badSignature: true), contains('bad signature'));
    expect(sb.reconcile(), isEmpty);
  });

  test('12. failed recipient credit rolls back the whole split and retries', () {
    final l = split4();
    sb.setFrozen(mary.id, true);
    final p = pay(l, naira(100000));
    expect(p.distribution, DistributionStatus.failedRetrying);
    expect(sb.allocations, isEmpty);
    expect(sb.reconcile(), isEmpty); // money is held in the collection account
    sb.setFrozen(mary.id, false);
    expect(sb.retryFailed(), 1);
    expect(sb.allocations.length, 4);
    expect(sb.reconcile(), isEmpty);
  });

  test('settlement modes: manual and on-target hold, then distribute', () {
    final manual = split4(mode: SettlementMode.manual);
    final p = pay(manual, naira(100000));
    expect(p.distribution, DistributionStatus.held);
    expect(sb.distributeHeld(manual), 1);
    final target = split4(mode: SettlementMode.onTarget);
    pay(target, naira(300000));
    expect(sb.allocations.where((a) => a.linkId == target.id), isEmpty);
    pay(target, naira(200000));
    expect(sb.allocations.where((a) => a.linkId == target.id).length, 8);
    expect(target.status, LinkStatus.completed);
    expect(sb.reconcile(), isEmpty);
  });

  test('pending becomes available on provider settlement', () {
    final l = split4();
    final p = pay(l, naira(100000));
    expect(sb.walletOf(mary.id, 'NGN').pending, greaterThan(0));
    sb.settle(p);
    expect(sb.walletOf(mary.id, 'NGN').pending, 0);
    expect(sb.walletOf(mary.id, 'NGN').available, naira(30000) - 450 * 100);
    expect(sb.reconcile(), isEmpty);
  });

  test('13. disputes hold shares; lost disputes reverse everything', () {
    final l = split4();
    final p = pay(l, naira(100000));
    sb.openDispute(p, 'not received');
    expect(sb.walletOf(mary.id, 'NGN').held, greaterThan(0));
    sb.resolveDispute(p, won: true);
    expect(sb.walletOf(mary.id, 'NGN').available, greaterThan(0));
    final p2 = pay(l, naira(50000));
    sb.openDispute(p2, 'fraud');
    sb.resolveDispute(p2, won: false);
    expect(p2.status, PayStatus.reversed);
    expect(sb.allocations.where((a) => a.paymentId == p2.id).every((a) => a.state == AllocState.reversed), isTrue);
    sb.reverse(p, 'refund', 'customer refund');
    expect(sb.walletOf(mary.id, 'NGN').available, 0);
    expect(sb.feeRevenue('NGN'), 0);
    expect(sb.reconcile(), isEmpty);
  });

  test('14. paused and expired links refuse payments', () {
    final l = split4();
    sb.setStatus(l, 'pause');
    expect(() => sb.quote(l, naira(1000)), throwsA(isA<PlException>()));
    sb.setStatus(l, 'resume');
    expect(sb.quote(l, naira(1000)).amount, naira(1000));
    expect(() => sb.quote(l, naira(600000)), throwsA(isA<PlException>())); // over target
    l.expiresAt = sb.now.subtract(const Duration(minutes: 1));
    sb.runExpiry();
    expect(l.status, LinkStatus.expired);
    expect(() => sb.quote(l, naira(1000)), throwsA(isA<PlException>()));
  });

  test('amendments keep history; reduced recipients must approve', () {
    final l = split4();
    final p1 = pay(l, naira(100000));
    final m = sb.proposeAmendment(l, 'Favour left the project', [(me, 0, 5000), (mary, 0, 3000), (innocent, 0, 2000)]);
    expect(m.status, 'proposed');
    expect(m.approvers.keys, [favour.id]);
    sb.decideAmendment(m, favour.id, true);
    expect(l.ruleVersion, 2);
    final p2 = pay(l, naira(100000));
    expect(sb.allocations.where((a) => a.paymentId == p1.id).first.ruleVersion, 1);
    expect(netBy(p2.id).containsKey('favour'), isFalse);
    expect(sb.reconcile(), isEmpty);
  });

  test('17. compliance review holds distributions until cleared', () {
    final l = split4();
    sb.setStatus(l, 'review', asStaff: true);
    expect(() => sb.setStatus(l, 'clear_review'), throwsA(isA<PlException>()));
    sb.setStatus(l, 'clear_review', asStaff: true);
    expect(l.status, LinkStatus.active);
  });

  test('amount mismatch is accounted for but held', () {
    final l = sb.createLink(type: LinkType.naira, title: 'Tote', asset: ngn, amountMode: AmountMode.fixed, fixedAmount: naira(15000));
    final p = sb.startCheckout(l, method: PayMethod.bankTransfer);
    sb.simulateProviderPayment(p, amountPaid: naira(14000));
    expect(p.status, PayStatus.succeeded);
    expect(p.distribution, DistributionStatus.held);
    expect(sb.flags.single.rule, 'amount_mismatch');
    expect(sb.reconcile(), isEmpty);
  });

  test('formatting', () {
    expect(PlFmt.money(naira(500000), ngn), '₦500,000.00');
    expect(PlFmt.money(150000000, PlAsset.crypto.first), '150.00 USDT');
    expect(PlFmt.parse('500k', ngn), naira(500000));
    expect(PlFmt.parse('1,250.5', ngn), 125050);
    expect(PlFmt.percent(3333), '33.33%');
    expect(PlFmt.maskEmail('adaeze@example.com'), 'a***@example.com');
  });
}
