import 'package:flutter_test/flutter_test.dart';
import 'package:knock/core/money.dart';
import 'package:knock/models/quote.dart';
import 'package:knock/services/contracts.dart';
import 'package:knock/services/intent_parser.dart';
import 'package:knock/services/mock/mock_backend.dart';

AuthorizationProof proofFor(Quote q) =>
    AuthorizationProof(quoteId: q.id, method: 'test', signedChallenge: 'sig', at: DateTime.now());

void main() {
  group('money', () {
    test('formats naira with grouping', () {
      expect(Money.major(100000, Currency.ngn).format(), '₦100,000.00');
      expect(Fmt.money(1234567.5, Currency.ngn, showDecimals: false), '₦1,234,568');
    });

    test('parses how people type amounts', () {
      expect(parseNairaAmount('₦100,000'), 100000);
      expect(parseNairaAmount('100k'), 100000);
      expect(parseNairaAmount('1.5m'), 1500000);
      expect(parseNairaAmount('N50000'), 50000);
      expect(parseNairaAmount('abc'), isNull);
    });
  });

  group('intent parser', () {
    test('buy crypto with asset and amount', () {
      final i = IntentParser.parse('I want to buy ₦100,000 worth of USDT');
      expect(i.flow, TxFlow.buyCrypto);
      expect(i.fields['asset'], 'USDT');
      expect(i.fields['amount'], '100000');
    });

    test('sell gift card with brand', () {
      final i = IntentParser.parse('I want to sell my Apple gift card');
      expect(i.flow, TxFlow.sellGiftCard);
      expect(i.fields['brand'], 'apple');
    });

    test('airtime with network, phone, amount', () {
      final i = IntentParser.parse('Buy 1000 MTN airtime for 08035554412');
      expect(i.flow, TxFlow.airtime);
      expect(i.fields['network'], 'MTN');
      expect(i.fields['phone'], '08035554412');
      expect(i.fields['amount'], '1000');
    });

    test('phone numbers are not read as amounts', () {
      final i = IntentParser.parse('08035554412', activeFlow: TxFlow.airtime, pendingField: 'phone');
      expect(i.fields['phone'], '08035554412');
      expect(i.fields.containsKey('amount'), isFalse);
    });

    test('small talk', () {
      expect(IntentParser.parse("What's my balance?").smallTalk, SmallTalk.balance);
      expect(IntentParser.parse('Not now').smallTalk, SmallTalk.decline);
      expect(IntentParser.parse('cancel').smallTalk, SmallTalk.cancel);
    });
  });

  group('mock backend', () {
    late MockBackend b;
    setUp(() => b = MockBackend()..latency = Duration.zero);

    test('quotes a crypto buy with fee and total', () async {
      final q = await b.quote(const QuoteRequest(TxFlow.buyCrypto, {'asset': 'USDT', 'amount': '100000'}));
      expect(q.total, Money.major(101000, Currency.ngn));
      expect(q.lines.map((l) => l.label), containsAll(['Asset', 'Amount', 'Rate', 'Fee (1%)']));
    });

    test('rejects amounts above the naira balance', () async {
      expect(
        () => b.quote(const QuoteRequest(TxFlow.buyCrypto, {'asset': 'BTC', 'amount': '4000000'})),
        throwsA(isA<QuoteException>()),
      );
    });

    test('execution is idempotent on the key', () async {
      final before = (await b.balances()).first.available;
      final q = await b.quote(
        const QuoteRequest(TxFlow.airtime, {'network': 'MTN', 'phone': '08035554412', 'amount': '1000'}),
      );
      final r1 = await b.execute(q, proofFor(q), 'key-1');
      final r2 = await b.execute(q, proofFor(q), 'key-1');
      expect(r1.record.id, r2.record.id);
      final after = (await b.balances()).first.available;
      expect(before.minor - after.minor, 100000); // charged once: ₦1,000
    });

    test('a used quote cannot be executed again with a new key', () async {
      final q = await b.quote(
        const QuoteRequest(TxFlow.airtime, {'network': 'MTN', 'phone': '08035554412', 'amount': '500'}),
      );
      await b.execute(q, proofFor(q), 'a');
      expect(() => b.execute(q, proofFor(q), 'b'), throwsA(isA<QuoteException>()));
    });

    test('authorisation must match the quote', () async {
      final q = await b.quote(
        const QuoteRequest(TxFlow.airtime, {'network': 'MTN', 'phone': '08035554412', 'amount': '500'}),
      );
      final wrong = AuthorizationProof(quoteId: 'other', method: 'test', signedChallenge: 's', at: DateTime.now());
      expect(() => b.execute(q, wrong, 'k'), throwsA(isA<QuoteException>()));
    });
  });
}
