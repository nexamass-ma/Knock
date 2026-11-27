import 'dart:async';

import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:material_ui/material_ui.dart';

import '../../api/api.dart';
import '../../app/app_controller.dart';
import '../../core/format.dart';
import '../../design/tokens.dart';
import '../../design/widgets/kit.dart';
import '../common/pin_sheet.dart' show SandboxNote;
import '../common/success_screen.dart';
import '../history/transaction_detail_screen.dart';
import 'rate_change_sheet.dart';
import 'rates_screen.dart';

/// Dashboard → Sell Gift Card. Brand, details, live quote, submit.
class SellGiftCardScreen extends StatefulWidget {
  const SellGiftCardScreen({super.key, this.brandId, this.currency, this.cardType, this.faceValue, this.prefilledCode, this.giftQuote});
  final String? brandId;
  final String? currency;
  final String? cardType;
  final int? faceValue;
  final String? prefilledCode;

  /// A quote already created by trading a received gift.
  final Json? giftQuote;

  @override
  State<SellGiftCardScreen> createState() => _SellGiftCardScreenState();
}

class _SellGiftCardScreenState extends State<SellGiftCardScreen> {
  GiftBrand? _brand;
  String? _currency;
  String _cardType = 'physical';
  final _value = TextEditingController();
  final _ecode = TextEditingController();
  String _search = '';
  Json? _estimate;
  Json? _quote;
  final _attachments = <String>[];
  bool _busy = false;
  String? _error;
  Timer? _poll;
  Timer? _debounce;
  bool _sheetOpen = false;
  final _idem = KnockApi.newIdempotencyKey();
  bool _submitted = false;

  @override
  void initState() {
    super.initState();
    if (widget.brandId != null) _brand = brandById(widget.brandId!);
    _currency = widget.currency ?? _brand?.rates.keys.first;
    _cardType = widget.cardType ?? 'physical';
    if (widget.faceValue != null) _value.text = '${widget.faceValue}';
    if (widget.prefilledCode != null) _ecode.text = widget.prefilledCode!;
    if (widget.giftQuote != null) {
      _quote = widget.giftQuote;
      _startPolling();
    } else if (_brand == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _restoreDraft());
    } else {
      _refreshEstimate();
    }
  }

  Future<void> _restoreDraft() async {
    try {
      final r = await context.api.call((s, t) => s.tradeDraft(t!));
      final d = (r['draft'] as Map?)?['draft'] as Map?;
      if (d == null || !mounted) return;
      final resume = await confirm(context, title: 'Finish your last trade?', message: 'You started selling a ${d['brand']} card. Pick up where you left off?', yes: 'Continue', no: 'Start fresh');
      if (!mounted) return;
      if (!resume) {
        context.api.call((s, t) => s.clearTradeDraft(t!));
        return;
      }
      setState(() {
        _brand = brandById(d['brandId'] as String);
        _currency = d['currency'] as String?;
        _cardType = d['cardType'] as String? ?? 'physical';
        if (d['faceValue'] != null) _value.text = '${d['faceValue']}';
      });
      _refreshEstimate();
    } catch (_) {}
  }

  @override
  void dispose() {
    _poll?.cancel();
    _debounce?.cancel();
    if (!_submitted && _brand != null && _quote == null && _value.text.isNotEmpty) {
      // Remember an unfinished trade so we can offer to finish it later.
      final api = context.api;
      api.call((s, t) => s.saveTradeDraft(t!, {'brandId': _brand!.id, 'brand': _brand!.name, 'currency': _currency, 'cardType': _cardType, 'faceValue': int.tryParse(_value.text)}));
    }
    super.dispose();
  }

  int? get _face => int.tryParse(_value.text);

  void _refreshEstimate() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () async {
      final b = _brand, c = _currency, f = _face;
      if (b == null || c == null || f == null || f <= 0) {
        if (mounted) setState(() => _estimate = null);
        return;
      }
      try {
        final r = await context.api.call((s, t) => s.estimateGiftCard(t!, brandId: b.id, currency: c, cardType: _cardType, faceValue: f));
        if (mounted) setState(() => _estimate = r['estimate'] as Json);
      } catch (_) {}
    });
  }

  Future<void> _getQuote() async {
    final b = _brand!;
    final f = _face;
    if (f == null || f < b.minValue || f > b.maxValue) {
      setState(() => _error = 'Enter a card value between ${F.face(_currency!, b.minValue)} and ${F.face(_currency!, b.maxValue)}.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final r = await context.api.call((s, t) => s.quoteGiftCard(t!, brandId: b.id, currency: _currency!, cardType: _cardType, faceValue: f));
      setState(() => _quote = r['quote'] as Json);
      HapticFeedback.mediumImpact();
      _startPolling();
    } on ApiError catch (e) {
      if (mounted) showApiError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Watches the quote on the server while the customer completes the trade.
  void _startPolling() {
    _poll?.cancel();
    _poll = Timer.periodic(const Duration(seconds: 3), (_) => _check());
  }

  Future<void> _check() async {
    final q = _quote;
    if (q == null || _sheetOpen || _busy || !mounted) return;
    try {
      final c = await context.api.call((s, t) => s.checkQuote(t!, q['id'] as String));
      if (!mounted) return;
      setState(() => _quote = {...q, 'secondsLeft': c['secondsLeft']});
      if (c['changed'] == true) await _showChange(c);
    } catch (_) {}
  }

  Future<void> _showChange(Json cmp) async {
    if (_sheetOpen) return;
    _sheetOpen = true;
    final q = _quote!;
    final chief = (context.app.me?['prefs'] as Map?)?['heyChief'] != false;
    final choice = await showRateChangeSheet(context, cmp: cmp, currency: q['currency'] as String, heyChief: chief);
    _sheetOpen = false;
    if (!mounted) return;
    if (choice == RateChoice.accept) {
      setState(() => _busy = true);
      try {
        final r = await context.api.call((s, t) => s.acceptNewRate(t!, q['id'] as String, cmp['newRateKobo'] as int));
        setState(() => _quote = r['quote'] as Json);
        if (mounted) toast(context, 'New rate confirmed. Your payout is ${F.ngnExact(_quote!['netKobo'] as int)}.');
      } on ApiError catch (e) {
        if (e.code == 'rate_changed' && e.details != null) {
          setState(() => _busy = false);
          await _showChange(e.details!.cast<String, dynamic>());
          return;
        }
        if (mounted) showApiError(context, e);
      } finally {
        if (mounted) setState(() => _busy = false);
      }
    } else if (choice == RateChoice.cancel) {
      _poll?.cancel();
      try {
        final r = await context.api.call((s, t) => s.cancelQuote(t!, q['id'] as String, reason: 'rate_change_declined'));
        _submitted = true;
        if (!mounted) return;
        context.app.poke();
        await Navigator.of(context).pushReplacement(KRoute(ResultScreen(
          title: 'Trade cancelled',
          success: false,
          message: 'Nothing was submitted and no money moved. You can start a new trade whenever you are ready.',
          txn: r['txn'] as Json?,
          nextLabel: 'See current rates',
          onNext: () => Navigator.of(context).pushReplacement(KRoute(const RatesScreen())),
        )));
      } catch (e) {
        if (mounted) showApiError(context, e);
      }
    }
  }

  Future<void> _addPhoto() async {
    try {
      final x = await ImagePicker().pickImage(source: ImageSource.gallery, imageQuality: 70, maxWidth: 1600);
      if (x != null) setState(() => _attachments.add(x.name));
    } catch (_) {
      // Picker unavailable (emulator, web preview): offer a sandbox sample.
      if (!mounted) return;
      if (await confirm(context, title: 'Photos unavailable', message: 'This device could not open your photos. Attach a sandbox sample photo instead?', yes: 'Use sample')) {
        setState(() => _attachments.add('sandbox_card_${_attachments.length + 1}.jpg'));
      }
    }
  }

  Future<void> _submit() async {
    final q = _quote!;
    setState(() {
      _busy = true;
      _error = null;
    });
    final api = context.api;
    try {
      final sec = api.security();
      final r = await api.call((s, t) => s.submitGiftCardTrade(t!, quoteId: q['id'] as String, attachments: List.of(_attachments), ecode: _ecode.text.trim().isEmpty ? null : _ecode.text.trim(), idempotencyKey: _idem, nonce: sec.nonce, sentAt: sec.sentAt));
      _submitted = true;
      _poll?.cancel();
      final txn = r['txn'] as Json;
      if (!mounted) return;
      context.app.poke();
      await Navigator.of(context).pushReplacement(KRoute(ResultScreen(
        title: 'Trade submitted',
        amountKobo: txn['amount'] as int,
        message: 'Your ${q['brand']} card is in the queue. We will notify you at every step, and the payout goes straight to your wallet.',
        txn: txn,
        nextLabel: 'Track my trade',
        onNext: () => Navigator.of(context).pushReplacement(KRoute(TransactionDetailScreen(txnId: txn['id'] as String))),
      )));
    } on ApiError catch (e) {
      if (e.code == 'rate_changed' && e.details != null) {
        setState(() => _busy = false);
        await _showChange(e.details!.cast<String, dynamic>());
        return;
      }
      if (e.code == 'missing_images' || e.code == 'missing_code') {
        setState(() => _error = e.message);
      } else if (mounted) {
        showApiError(context, e);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_brand == null) return _brandPicker();
    if (_quote == null) return _details();
    return _review();
  }

  Widget _brandPicker() {
    final list = giftBrands.where((b) => b.name.toLowerCase().contains(_search.toLowerCase())).toList();
    return KPage(
      title: 'Sell a gift card',
      actions: [
        TextButton.icon(
          key: const ValueKey('sell-current-rates'),
          onPressed: () => go(context, const RatesScreen()),
          icon: const Icon(Icons.trending_up_rounded, size: 18, color: KnockColors.greenBright),
          label: Text('Current Rate', style: KnockText.bodyStrong.copyWith(color: KnockColors.greenBright)),
        ),
      ],
      children: [
        TextField(onChanged: (v) => setState(() => _search = v), style: KnockText.body, decoration: const InputDecoration(hintText: 'Which card do you have?', prefixIcon: Icon(Icons.search_rounded, color: KnockColors.textSecondary))),
        const SizedBox(height: 16),
        GridView.count(
          crossAxisCount: 3,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: 10,
          crossAxisSpacing: 10,
          childAspectRatio: 0.95,
          children: [
            for (final b in list)
              KnockCard(
                key: ValueKey('brand-${b.id}'),
                padding: const EdgeInsets.all(10),
                onTap: () {
                  setState(() {
                    _brand = b;
                    _currency = b.rates.keys.first;
                  });
                  _refreshEstimate();
                },
                child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                  BrandBadge(glyph: b.glyph, color: b.color),
                  const SizedBox(height: 8),
                  Text(b.name, style: KnockText.caption.copyWith(color: KnockColors.textPrimary, fontWeight: FontWeight.w600), textAlign: TextAlign.center, maxLines: 2),
                ]),
              ),
          ],
        ),
      ],
    );
  }

  Widget _details() {
    final b = _brand!;
    final cur = _currency!;
    final e = _estimate;
    return KPage(
      title: '${b.name} gift card',
      actions: [IconButton(tooltip: 'Change card', icon: const Icon(Icons.swap_horiz_rounded), onPressed: () => setState(() => _brand = null))],
      bottom: KnockButton(key: const ValueKey('sell-get-rate'), label: 'Lock in my rate', loading: _busy, onPressed: _face == null ? null : _getQuote),
      children: [
        Text('Card currency', style: KnockText.headline),
        const SizedBox(height: 10),
        ChoiceWrap<String>(choices: [for (final c in b.rates.keys) Choice(c, '${currencySymbols[c]} $c')], selected: cur, onSelected: (v) {
          setState(() => _currency = v);
          _refreshEstimate();
        }),
        const SizedBox(height: 20),
        Text('Card type', style: KnockText.headline),
        const SizedBox(height: 10),
        ChoiceWrap<String>(choices: const [Choice('physical', 'Physical card', icon: Icons.credit_card_rounded), Choice('ecode', 'E-code', icon: Icons.qr_code_rounded)], selected: _cardType, onSelected: (v) {
          setState(() => _cardType = v);
          _refreshEstimate();
        }),
        const SizedBox(height: 20),
        KField(
          key: const ValueKey('sell-value'),
          label: 'Card value',
          controller: _value,
          keyboard: TextInputType.number,
          formatters: [FilteringTextInputFormatter.digitsOnly],
          prefix: Padding(padding: const EdgeInsets.fromLTRB(16, 14, 4, 0), child: Text(currencySymbols[cur] ?? '', style: KnockText.body)),
          hint: '100',
          error: _error,
          helper: 'Between ${F.face(cur, b.minValue)} and ${F.face(cur, b.maxValue)}',
          onChanged: (_) {
            setState(() => _error = null);
            _refreshEstimate();
          },
        ),
        Wrap(spacing: 8, children: [
          for (final v in [25, 50, 100, 200, 500])
            ActionChip(
              label: Text(F.face(cur, v)),
              backgroundColor: KnockColors.surfaceRaised,
              side: const BorderSide(color: KnockColors.stroke),
              onPressed: () {
                _value.text = '$v';
                setState(() => _error = null);
                _refreshEstimate();
              },
            ),
        ]),
        const SizedBox(height: 20),
        AnimatedSwitcher(
          duration: KnockMotion.base,
          child: e == null
              ? const SizedBox.shrink()
              : KnockCard(
                  key: ValueKey(e['netKobo']),
                  color: KnockColors.surfaceRaised,
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      Text('Estimated payout', style: KnockText.caption),
                      const Spacer(),
                      Tag(e['mode'] == 'locked' ? 'Rate locks for ${b.lockMinutes} min' : 'Indicative rate', color: e['mode'] == 'locked' ? KnockColors.greenBright : KnockColors.orange),
                    ]),
                    const SizedBox(height: 6),
                    Text(F.ngnExact(e['netKobo'] as int), style: KnockText.display.copyWith(fontSize: 32)),
                    const SizedBox(height: 10),
                    KeyValue('Rate', F.rate(e['rateKobo'] as int, cur)),
                    if ((e['boostKobo'] as int) > 0) KeyValue('Includes campaign boost', '+${F.rate(e['boostKobo'] as int, cur)}', valueColor: KnockColors.greenBright),
                    if ((e['vipKobo'] as int) > 0) KeyValue('Includes VIP bonus', '+${F.rate(e['vipKobo'] as int, cur)}', valueColor: KnockColors.greenBright),
                    KeyValue('Before fees', F.ngnExact(e['grossKobo'] as int)),
                    KeyValue('Service fee', '−${F.ngnExact(e['feeKobo'] as int)}'),
                  ]),
                ),
        ),
        const SizedBox(height: 12),
        Note(b.lockMinutes > 0
            ? 'When you continue, we lock this rate for ${b.lockMinutes} minutes. It will not change while the lock is active.'
            : 'This rate is indicative. If it changes before you submit, we will show you the new payout and ask you to confirm.'),
      ],
    );
  }

  Widget _review() {
    final q = _quote!;
    final cur = q['currency'] as String;
    final locked = q['mode'] == 'locked';
    final secs = q['secondsLeft'] as int?;
    final acceptances = (q['acceptances'] as List? ?? const []).cast<Map>();
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (await confirm(context, title: 'Leave this trade?', message: 'Your card has not been submitted. You can start again any time.', yes: 'Leave', no: 'Stay')) {
          try {
            await context.api.call((s, t) => s.cancelQuote(t!, q['id'] as String));
          } catch (_) {}
          _submitted = true;
          if (mounted) Navigator.of(context).pop();
        }
      },
      child: KPage(
        title: 'Review and submit',
        bottom: KnockButton(key: const ValueKey('sell-submit'), label: 'Submit trade', loading: _busy, onPressed: (locked && secs == 0) ? null : _submit),
        children: [
          KnockCard(
            gradient: KnockColors.cardGradient,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Text('${q['brand']} · ${F.face(cur, q['faceValue'] as int)} · ${q['cardType'] == 'ecode' ? 'E-code' : 'Physical'}', style: KnockText.caption.copyWith(color: Colors.white70)),
                const Spacer(),
                if (locked && secs != null)
                  Countdown(
                    key: ValueKey('lock-${q['rateKobo']}-$secs'),
                    seconds: secs,
                    onDone: _check,
                    builder: (l) => Tag(l > 0 ? 'Locked · ${F.countdown(l)}' : 'Lock expired', color: l > 60 ? KnockColors.greenBright : KnockColors.orange, icon: Icons.lock_clock_rounded),
                  )
                else
                  const Tag('Indicative', color: KnockColors.orange),
              ]),
              const SizedBox(height: 8),
              Text('You will receive', style: KnockText.caption.copyWith(color: Colors.white70)),
              Text(F.ngnExact(q['netKobo'] as int), key: const ValueKey('quote-net'), style: KnockText.display),
              const SizedBox(height: 10),
              KeyValue('Rate', F.rate(q['rateKobo'] as int, cur), strong: true),
              KeyValue('Before fees', F.ngnExact(q['grossKobo'] as int)),
              KeyValue('Service fee', '−${F.ngnExact(q['feeKobo'] as int)}'),
              KeyValue('Paid to', 'Your Knock wallet'),
            ]),
          ),
          if (locked && secs != null && secs <= 120 && secs > 0)
            const Padding(padding: EdgeInsets.only(top: 12), child: Note('Your locked rate expires soon. Submit now to keep it.', icon: Icons.timer_outlined, color: KnockColors.orange)),
          if (acceptances.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Note('You accepted a new rate of ${F.rate(acceptances.last['newRateKobo'] as int, cur)} at ${F.dateTime(acceptances.last['at'] as String)}.', icon: Icons.check_circle_outline_rounded, color: KnockColors.greenBright),
            ),
          const SectionTitle('Your card'),
          if (q['cardType'] == 'ecode') ...[
            KField(key: const ValueKey('sell-ecode'), label: 'E-code', controller: _ecode, hint: 'XXXX-XXXX-XXXX', capitalization: TextCapitalization.characters, helper: 'Encrypted as soon as you submit. Only our review team can see it.'),
            Text('Or upload a screenshot of the code', style: KnockText.caption),
            const SizedBox(height: 8),
          ] else
            Text('Add clear photos of the front and back, with the code visible.', style: KnockText.caption),
          const SizedBox(height: 10),
          Wrap(spacing: 10, runSpacing: 10, children: [
            for (final a in _attachments)
              Chip(
                avatar: const Icon(Icons.image_outlined, size: 18),
                label: Text(a, overflow: TextOverflow.ellipsis),
                onDeleted: () => setState(() => _attachments.remove(a)),
                backgroundColor: KnockColors.surfaceRaised,
              ),
            ActionChip(key: const ValueKey('sell-add-photo'), avatar: const Icon(Icons.add_a_photo_outlined, size: 18, color: KnockColors.greenBright), label: const Text('Add photo'), onPressed: _addPhoto, backgroundColor: KnockColors.surfaceRaised),
          ]),
          if (_error != null) Padding(padding: const EdgeInsets.only(top: 12), child: Note(_error!, color: KnockColors.loss, icon: Icons.error_outline_rounded)),
          const SizedBox(height: 16),
          const SandboxNote('Sandbox: the review team is simulated. Rates move on their own every minute or so, so you may see a rate-change notice here.'),
        ],
      ),
    );
  }
}

/// Sell flow entry from a received gift (quote already exists).
Future<void> sellFromGift(BuildContext context, Json quote, String? ecode) =>
    go(context, SellGiftCardScreen(brandId: quote['brandId'] as String, currency: quote['currency'] as String, cardType: quote['cardType'] as String, faceValue: quote['faceValue'] as int, prefilledCode: ecode, giftQuote: quote));

