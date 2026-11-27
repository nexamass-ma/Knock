import '../core/money.dart';
import '../models/catalog.dart';
import '../models/quote.dart';
import 'contracts.dart';

/// A small rule-based parser that stands in for the AI conversation
/// service in the prototype. In production the backend's language model
/// returns the same structured [Interpretation]. Either way the output is
/// only an intent plus the values the user typed: no prices, no execution.
abstract final class IntentParser {
  static const _assets = {
    'BTC': ['btc', 'bitcoin'],
    'ETH': ['eth', 'ethereum', 'ether'],
    'USDT': ['usdt', 'tether'],
    'SOL': ['sol', 'solana'],
    'USDC': ['usdc', 'usd coin'],
  };

  static const _brands = {
    'apple': ['apple', 'itunes'],
    'amazon': ['amazon'],
    'steam': ['steam'],
    'googleplay': ['google play', 'googleplay', 'play store'],
    'razer': ['razer'],
    'sephora': ['sephora'],
  };

  static bool _has(String s, String word) => RegExp('\\b${RegExp.escape(word)}\\b').hasMatch(s);

  static Interpretation parse(String raw, {TxFlow? activeFlow, String? pendingField}) {
    final s = raw.toLowerCase().trim();
    final fields = <String, String>{};

    // ---- small talk ----
    if (RegExp(r'^(cancel|stop|never ?mind|start over)\b').hasMatch(s)) {
      return const Interpretation(smallTalk: SmallTalk.cancel);
    }
    if (RegExp(r'^(no|nope|not now|no thanks|i.?m good|maybe later)\b').hasMatch(s)) {
      return const Interpretation(smallTalk: SmallTalk.decline);
    }

    // ---- flow ----
    final giftCard = s.contains('gift card') || s.contains('giftcard') || s.contains('gift-card');
    final cryptoWord = s.contains('crypto') || _assets.values.expand((e) => e).any((w) => _has(s, w));
    final sell = _has(s, 'sell') || _has(s, 'cash out') || _has(s, 'redeem') || _has(s, 'trade');
    final buy = _has(s, 'buy') || _has(s, 'purchase') || _has(s, 'get') || _has(s, 'top up') || _has(s, 'recharge');

    TxFlow? flow;
    if (giftCard && sell) {
      flow = TxFlow.sellGiftCard;
    } else if (giftCard) {
      flow = buy ? TxFlow.buyGiftCard : TxFlow.sellGiftCard;
    } else if (_has(s, 'airtime') || _has(s, 'recharge card')) {
      flow = TxFlow.airtime;
    } else if (RegExp(r'\b(data|bundle|internet)\b').hasMatch(s) && pendingField == null) {
      flow = TxFlow.data;
    } else if (RegExp(r'\b(electricity|light bill|nepa|prepaid meter|power|disco|meter token)\b').hasMatch(s)) {
      flow = TxFlow.electricity;
    } else if (RegExp(r'\b(cable|dstv|gotv|startimes|tv subscription)\b').hasMatch(s)) {
      flow = TxFlow.cable;
    } else if (cryptoWord && sell) {
      flow = TxFlow.sellCrypto;
    } else if (cryptoWord && buy) {
      flow = TxFlow.buyCrypto;
    }

    // ---- values ----
    _assets.forEach((ticker, words) {
      if (words.any((w) => _has(s, w))) fields['asset'] = ticker;
    });
    _brands.forEach((id, words) {
      if (words.any((w) => s.contains(w))) fields['brand'] = id;
    });
    for (final n in BillCatalog.networks) {
      if (_has(s, n.toLowerCase())) fields['network'] = n;
    }
    for (final d in BillCatalog.discos) {
      final key = d.split(' ').first.toLowerCase();
      if (_has(s, key)) fields['disco'] = d;
    }
    for (final p in BillCatalog.cableProviders) {
      if (_has(s, p.toLowerCase())) fields['provider'] = p;
    }
    for (final plan in [...BillCatalog.dataPlans.keys, ...BillCatalog.cablePlans.values.expand((m) => m.keys)]) {
      final head = plan.split(' ').first.toLowerCase();
      if (s == plan.toLowerCase() || _has(s, head)) fields['plan'] = plan;
    }
    if (RegExp(r'\b(e-?code|digital)\b').hasMatch(s)) fields['cardType'] = 'E-code';
    if (RegExp(r'\b(physical)\b').hasMatch(s)) fields['cardType'] = 'Physical';

    final joined = s.replaceAll(RegExp(r'(?<=\d)[\s-](?=\d)'), '');
    final phone = RegExp(r'(?<!\d)0[789][01]\d{8}(?!\d)').firstMatch(joined);
    if (phone != null) fields['phone'] = phone.group(0)!;

    // Long digit strings are meter / smartcard numbers only when asked for.
    final digits = s.replaceAll(RegExp(r'[\s-]'), '');
    if (pendingField == 'meter' && RegExp(r'^\d{11,13}$').hasMatch(digits)) fields['meter'] = digits;
    if (pendingField == 'smartcard' && RegExp(r'^\d{10,11}$').hasMatch(digits)) fields['smartcard'] = digits;

    // USD amounts (gift cards).
    final usd = RegExp(r'\$\s?(\d[\d,]*)|(\d[\d,]*)\s?(usd|dollars?)\b').firstMatch(s);
    if (usd != null) fields['value'] = (usd.group(1) ?? usd.group(2))!.replaceAll(',', '');

    // Naira amounts.
    if (pendingField == 'amount') {
      final v = parseNairaAmount(s);
      if (v != null) fields['amount'] = v.toStringAsFixed(0);
    }
    if (!fields.containsKey('amount') && usd == null) {
      final m = RegExp(r'(₦|\bn|\bngn)?\s?(\d[\d,]*(?:\.\d+)?)\s?(k|m)?\b(\s?naira)?').allMatches(s);
      for (final match in m) {
        final whole = match.group(0)!.trim();
        final number = match.group(2)!.replaceAll(',', '');
        final hasMarker =
            match.group(1) != null || match.group(3) != null || match.group(4) != null || raw.contains(',');
        // Skip phone, meter and card numbers.
        if (number.length >= 10 && match.group(3) == null) continue;
        if (!hasMarker && pendingField != 'amount' && number.length < 4) continue;
        final v = parseNairaAmount(whole.replaceAll('naira', ''));
        if (v != null) {
          fields['amount'] = v.toStringAsFixed(0);
          break;
        }
      }
    }

    if (pendingField == 'value' && !fields.containsKey('value')) {
      final v = parseUsdAmount(s);
      if (v != null) fields['value'] = v.toStringAsFixed(0);
    }

    if (flow == null && fields.isEmpty) {
      if (RegExp(r'\b(balance|how much do i have|my wallet|portfolio)\b').hasMatch(s)) {
        return const Interpretation(smallTalk: SmallTalk.balance);
      }
      if (RegExp(r'^(hi|hello|hey|good (morning|afternoon|evening)|howdy)\b').hasMatch(s)) {
        return const Interpretation(smallTalk: SmallTalk.greeting);
      }
      if (RegExp(r'\b(thanks|thank you|thx)\b').hasMatch(s)) {
        return const Interpretation(smallTalk: SmallTalk.thanks);
      }
      if (RegExp(r'\b(help|what can you do|options)\b').hasMatch(s)) {
        return const Interpretation(smallTalk: SmallTalk.help);
      }
      // Free-text answer to the field we asked for (e.g. a meter number
      // with spaces, a name of a plan) is handled by the caller.
    }

    return Interpretation(flow: flow, fields: fields);
  }
}
