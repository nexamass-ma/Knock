import 'dart:math';
import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';

import '../app/app_scope.dart';
import '../core/money.dart';
import '../models/asset.dart';
import '../models/catalog.dart';
import '../models/chat.dart';
import '../models/ledger.dart';
import '../models/quote.dart';
import '../services/contracts.dart';
import 'wallet_store.dart';

/// Drives the KNOCK conversation.
///
/// The controller fills in the details a transaction needs, asks the
/// backend for a quote, and shows it. It cannot execute anything by itself:
/// [confirm] requires an [AuthorizationProof] that only the native
/// confirmation sheet can produce after the user verifies.
class AssistantController extends ChangeNotifier {
  AssistantController(this._services, this._wallet);

  final AppServices _services;
  final WalletStore _wallet;

  final List<ChatMessage> messages = [];
  bool thinking = false;

  TxFlow? _flow;
  final Map<String, String> _fields = {};
  String? _pending;
  GiftCardScanResult? _scan;
  final Map<String, String> _idempotencyKeys = {};

  /// Quotes that have been executed; their cards show "Confirmed".
  final Set<String> usedQuotes = {};

  String? get pendingField => _pending;
  bool get awaitingImage => _pending == 'image';
  TxFlow? get activeFlow => _flow;

  List<String> get quickReplies {
    if (messages.isEmpty || thinking) return const [];
    final last = messages.last;
    return last.speaker == Speaker.knock ? last.quickReplies : const [];
  }

  /// Context-aware starters shown on an empty conversation.
  List<String> get starters {
    final naira = _wallet.balance(LedgerKind.naira)?.available.major ?? 0;
    return [
      if (naira >= 101000) 'Buy ₦100,000 worth of USDT' else 'Buy ₦20,000 worth of USDT',
      'Sell my Apple gift card',
      'Sell ₦50,000 of BTC',
      'Buy ₦1,000 MTN airtime',
      'Pay my electricity bill',
      "What's my balance?",
    ];
  }

  // ------------------------------------------------------------ entry points

  /// Opened from a home action. The intent is already chosen.
  void launch(TxFlow flow, {Map<String, String> fields = const {}}) {
    _resetDraft();
    _flow = flow;
    _fields.addAll(fields);
    _say(_launchLine(flow));
    _advance();
  }

  Future<void> send(String raw) async {
    final text = raw.trim();
    if (text.isEmpty || thinking) return;
    messages.add(ChatMessage(Speaker.user, TextContent(text)));
    notifyListeners();

    // Special replies that steer the current step.
    if (text == 'Change amount' && _flow != null) {
      _fields.remove('amount');
      _advance();
      return;
    }
    if (_pending == 'scanConfirm') {
      await _handleScanReply(text);
      return;
    }
    if (_pending == 'followUp') {
      _pending = null;
    }
    if (text == 'Try again' && _pending == 'image') {
      _pending = null;
      _scan = null;
      await _advance();
      return;
    }
    if (text == 'Refresh quote' && _lastQuote != null) {
      _pending = null;
      await _requestQuote();
      return;
    }
    if (text == 'Pay a bill') {
      _resetDraft();
      _say(
        'Which bill would you like to pay?',
        replies: const ['Buy airtime', 'Buy data', 'Pay electricity', 'Pay cable TV'],
      );
      return;
    }

    _setThinking(true);
    final i = await _services.conversation.interpret(text, activeFlow: _flow, pendingField: _pending);
    _setThinking(false);

    switch (i.smallTalk) {
      case SmallTalk.cancel:
        _resetDraft();
        _say('Cancelled. Nothing was charged. What would you like to do next?', replies: _menu);
        return;
      case SmallTalk.decline:
        _resetDraft();
        _say('No problem. Nothing else will be charged. I am here when you need me.');
        return;
      case SmallTalk.greeting:
        _say(
          'Hi ${_firstName()}. I can buy or sell crypto, trade gift cards and pay bills. What would you like to do?',
          replies: _menu,
        );
        return;
      case SmallTalk.thanks:
        _say('Anytime.');
        return;
      case SmallTalk.help:
        _say(
          'Tell me what you want in your own words, for example "buy ₦50,000 of BTC" or "pay my DStv". '
          'I will fetch a quote from KNOCK and you confirm it before anything moves.',
          replies: _menu,
        );
        return;
      case SmallTalk.balance:
        _sayBalances();
        return;
      case null:
        break;
    }

    if (i.flow != null && i.flow != _flow) {
      _resetDraft();
      _flow = i.flow;
      _fields.addAll(i.fields);
      if (i.fields.isEmpty || (i.flow == TxFlow.sellGiftCard)) _say(_launchLine(i.flow!));
      await _advance();
      return;
    }

    if (_flow == null) {
      final asset = i.fields['asset'];
      if (asset != null) {
        _say('Would you like to buy or sell $asset?', replies: ['Buy $asset', 'Sell $asset']);
      } else {
        _say("I can help with crypto, gift cards and bills. Which one?", replies: _menu);
      }
      return;
    }

    _fields.addAll(i.fields);
    // Free-text fallback for the field we asked about.
    final p = _pending;
    if (p != null && !_fields.containsKey(p)) {
      final fallback = _fallbackFor(p, text);
      if (fallback != null) {
        _fields[p] = fallback;
      } else {
        _say("Sorry, I didn't catch that. ${_promptFor(p)}", replies: _optionsFor(p));
        return;
      }
    }
    await _advance();
  }

  Future<void> attachImage(Uint8List bytes) async {
    if (_flow != TxFlow.sellGiftCard) {
      _resetDraft();
      _flow = TxFlow.sellGiftCard;
    }
    messages.add(ChatMessage(Speaker.user, ImageContent(bytes, 'Gift card photo')));
    _pending = null;
    _say('Scanning your card…');
    _setThinking(true);
    try {
      final scan = await _services.recognition.recognize(bytes, hintBrandId: _fields['brand']);
      _scan = scan;
      _setThinking(false);
      messages.add(
        ChatMessage(Speaker.knock, ScanResultContent(scan), replies: const ['Looks right', 'Change value', 'Cancel']),
      );
      _pending = 'scanConfirm';
      notifyListeners();
    } catch (e) {
      _setThinking(false);
      _error(e.toString(), replies: const ['Try again', 'Cancel']);
      _pending = 'image';
      notifyListeners();
    }
  }

  /// Called by the confirmation sheet after the user verified on device.
  Future<TransactionReceipt?> confirm(Quote quote, AuthorizationProof proof) async {
    final key = _idempotencyKeys.putIfAbsent(quote.id, _newKey);
    _setThinking(true);
    try {
      final receipt = await _services.transactions.execute(quote: quote, proof: proof, idempotencyKey: key);
      _setThinking(false);
      usedQuotes.add(quote.id);
      messages.add(ChatMessage(Speaker.knock, ReceiptContent(receipt)));
      _resetDraft();
      await _wallet.load(silent: true);
      if (receipt.flow == TxFlow.buyCrypto) {
        final naira = _wallet.balance(LedgerKind.naira)?.available.format() ?? '';
        _say(
          'Your crypto purchase is complete. Would you also like to buy airtime, data or pay a utility '
          'bill using your available wallet balance${naira.isEmpty ? '' : ' ($naira)'}?',
          replies: const ['Buy airtime', 'Buy data', 'Pay electricity', 'Not now'],
        );
        _pending = 'followUp';
      } else {
        _say('Anything else?', replies: const ['Buy crypto', 'Pay a bill', 'No, thanks']);
      }
      notifyListeners();
      return receipt;
    } catch (e) {
      _setThinking(false);
      _error(e.toString(), replies: const ['Refresh quote', 'Cancel']);
      _pending = 'refresh';
      _lastQuote = quote;
      notifyListeners();
      return null;
    }
  }

  Quote? _lastQuote;

  Future<void> refreshQuote(Quote quote) async {
    _flow = quote.flow;
    _lastQuote = quote;
    await _requestQuote();
  }

  void clear() {
    messages.clear();
    _resetDraft();
    notifyListeners();
  }

  // ------------------------------------------------------------- internals

  static const _menu = ['Buy crypto', 'Sell crypto', 'Sell a gift card', 'Pay a bill'];

  String _firstName() => 'Ada';

  void _resetDraft() {
    _flow = null;
    _fields.clear();
    _pending = null;
    _scan = null;
  }

  String _newKey() {
    final r = Random.secure();
    return List.generate(16, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
  }

  void _setThinking(bool v) {
    thinking = v;
    notifyListeners();
  }

  void _say(String text, {List<String> replies = const []}) {
    messages.add(ChatMessage(Speaker.knock, TextContent(text), replies: replies));
    notifyListeners();
  }

  void _error(String text, {List<String> replies = const []}) {
    messages.add(ChatMessage(Speaker.knock, NoticeContent(text, isError: true), replies: replies));
    notifyListeners();
  }

  void _sayBalances() {
    final n = _wallet.balance(LedgerKind.naira);
    final c = _wallet.balance(LedgerKind.crypto);
    if (n == null || c == null) {
      _say('I could not load your balances just now. Pull to refresh on Home and try again.');
      return;
    }
    _say(
      'Here is what KNOCK has on record:\n'
      '• Naira wallet: ${n.available.format()}\n'
      '• Crypto: about ${c.available.format()}\n'
      '• Dollar card: coming soon\n\n'
      'These are separate balances. I never move money between them without your confirmation.',
      replies: _menu,
    );
  }

  String _launchLine(TxFlow f) => switch (f) {
    TxFlow.buyCrypto => "Let's buy crypto.",
    TxFlow.sellCrypto => "Let's sell crypto. The proceeds go to your Naira wallet.",
    TxFlow.buyGiftCard => "Let's get you a gift card.",
    TxFlow.sellGiftCard =>
      _fields['brand'] != null
          ? "Let's sell your ${GiftCardCatalog.byId(_fields['brand']!)?.name ?? ''} gift card."
          : "Let's sell your gift card.",
    TxFlow.airtime => "Let's top up airtime.",
    TxFlow.data => "Let's buy a data plan.",
    TxFlow.electricity => "Let's pay for electricity.",
    TxFlow.cable => "Let's renew your cable subscription.",
  };

  List<String> _required(TxFlow f) => switch (f) {
    TxFlow.buyCrypto || TxFlow.sellCrypto => ['asset', 'amount'],
    TxFlow.buyGiftCard => ['brand', 'value'],
    TxFlow.sellGiftCard => ['image'],
    TxFlow.airtime => ['network', 'phone', 'amount'],
    TxFlow.data => ['network', 'phone', 'plan'],
    TxFlow.electricity => ['disco', 'meter', 'amount'],
    TxFlow.cable => ['provider', 'smartcard', 'plan'],
  };

  Future<void> _advance() async {
    final f = _flow;
    if (f == null) return;
    for (final key in _required(f)) {
      if (key == 'image') {
        if (_scan == null) {
          _pending = 'image';
          messages.add(
            ChatMessage(
              Speaker.knock,
              const UploadRequestContent(
                'Upload a photo of the card',
                'A clear photo of the front, with the code area visible. Add the receipt if you have one. '
                    'KNOCK identifies the card, then our partner verifies it before you get a final rate.',
              ),
            ),
          );
          notifyListeners();
          return;
        }
        continue;
      }
      if (!_fields.containsKey(key)) {
        _pending = key;
        _say(_promptFor(key), replies: _optionsFor(key));
        return;
      }
    }
    _pending = null;
    await _requestQuote();
  }

  Future<void> _requestQuote() async {
    final f = _flow ?? _lastQuote?.flow;
    if (f == null) return;
    _say(
      f == TxFlow.sellGiftCard
          ? 'Verifying your card details with our partner and fetching today\'s rate…'
          : 'Sure. Let me calculate your available quote.',
    );
    _setThinking(true);
    try {
      final quote = await _services.quotes.requestQuote(QuoteRequest(f, Map.of(_fields)));
      _setThinking(false);
      messages.add(ChatMessage(Speaker.knock, QuoteContent(quote)));
      _lastQuote = quote;
      notifyListeners();
    } on QuoteException catch (e) {
      _setThinking(false);
      final msg = e.suggestion == null ? e.message : '${e.message} ${e.suggestion}';
      _error(msg, replies: const ['Change amount', 'Cancel']);
    } catch (e) {
      _setThinking(false);
      _error(e.toString(), replies: const ['Cancel']);
    }
  }

  Future<void> _handleScanReply(String text) async {
    final scan = _scan;
    final t = text.toLowerCase();
    if (scan == null) return;
    if (t.contains('cancel')) {
      _resetDraft();
      _say('Cancelled. Your photo has been discarded.');
      return;
    }
    if (t.contains('change')) {
      _fields
        ..['brand'] = scan.brandId
        ..['cardType'] = scan.cardType
        ..['region'] = scan.region;
      _pending = 'value';
      _say(_promptFor('value'), replies: _optionsFor('value'));
      // _advance() quotes as soon as the corrected value arrives.
      return;
    }
    _fields
      ..['brand'] = scan.brandId
      ..['value'] = scan.faceValueUsd.toString()
      ..['cardType'] = scan.cardType
      ..['region'] = scan.region;
    _pending = null;
    await _requestQuote();
  }

  String _promptFor(String key) {
    final f = _flow;
    switch (key) {
      case 'asset':
        return f == TxFlow.sellCrypto ? 'Which asset would you like to sell?' : 'Which asset would you like to buy?';
      case 'amount':
        if (f == TxFlow.sellCrypto) {
          final h = _holdingFor(_fields['asset']);
          final held = h == null
              ? ''
              : ' You hold ${Fmt.quantity(h.quantity)} ${h.asset.ticker}, about ${h.valueNgn.format(showDecimals: false)}.';
          return 'How much would you like to sell, in Naira value?$held';
        }
        if (f == TxFlow.electricity) return 'How much power would you like to buy?';
        if (f == TxFlow.airtime) return 'How much airtime?';
        final naira = _wallet.balance(LedgerKind.naira)?.available.format();
        return 'How much would you like to spend, in Naira?${naira == null ? '' : ' Your Naira wallet has $naira.'}';
      case 'brand':
        return 'Which gift card would you like?';
      case 'value':
        return 'What is the card value, in US dollars?';
      case 'network':
        return 'Which network?';
      case 'phone':
        return 'Which phone number?';
      case 'plan':
        return 'Pick a plan.';
      case 'disco':
        return 'Who is your electricity provider?';
      case 'meter':
        return 'What is your meter number?';
      case 'provider':
        return 'Which cable provider?';
      case 'smartcard':
        return 'What is your smartcard or IUC number?';
    }
    return 'Tell me a little more.';
  }

  List<String> _optionsFor(String key) {
    final f = _flow;
    switch (key) {
      case 'asset':
        if (f == TxFlow.sellCrypto) {
          return [
            for (final h in _wallet.holdings)
              if (h.quantity > 0) h.asset.ticker,
          ];
        }
        return SupportedAssets.all.map((a) => a.ticker).toList();
      case 'amount':
        if (f == TxFlow.airtime) return const ['₦500', '₦1,000', '₦2,000', '₦5,000'];
        if (f == TxFlow.electricity) return const ['₦5,000', '₦10,000', '₦20,000'];
        return const ['₦10,000', '₦50,000', '₦100,000', '₦250,000'];
      case 'brand':
        return GiftCardCatalog.brands.map((b) => b.name).toList();
      case 'value':
        return GiftCardCatalog.denominations.map((d) => '\$$d').toList();
      case 'network':
        return BillCatalog.networks;
      case 'phone':
        return const ['08035554412'];
      case 'plan':
        if (f == TxFlow.cable) return BillCatalog.cablePlans[_fields['provider']]?.keys.toList() ?? const [];
        return BillCatalog.dataPlans.keys.toList();
      case 'disco':
        return BillCatalog.discos;
      case 'meter':
        return const ['45001234211'];
      case 'provider':
        return BillCatalog.cableProviders;
      case 'smartcard':
        return const ['7012345618'];
    }
    return const [];
  }

  String? _fallbackFor(String key, String text) {
    final t = text.trim();
    switch (key) {
      case 'plan':
        for (final o in _optionsFor('plan')) {
          if (o.toLowerCase().startsWith(t.toLowerCase()) ||
              t.toLowerCase().contains(o.split(' ').first.toLowerCase())) {
            return o;
          }
        }
        return null;
      case 'phone':
        final d = t.replaceAll(RegExp(r'\D'), '');
        return RegExp(r'^0\d{10}$').hasMatch(d) ? d : null;
      case 'meter':
        final d = t.replaceAll(RegExp(r'\D'), '');
        return d.length >= 11 && d.length <= 13 ? d : null;
      case 'smartcard':
        final d = t.replaceAll(RegExp(r'\D'), '');
        return d.length >= 10 && d.length <= 11 ? d : null;
      default:
        return null;
    }
  }

  Holding? _holdingFor(String? ticker) {
    for (final h in _wallet.holdings) {
      if (h.asset.ticker == ticker) return h;
    }
    return null;
  }
}
