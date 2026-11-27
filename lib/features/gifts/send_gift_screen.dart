import 'package:material_ui/material_ui.dart';

import '../../api/api.dart';
import '../../app/app_controller.dart';
import '../../core/format.dart';
import '../../design/tokens.dart';
import '../../design/widgets/kit.dart';
import '../common/pin_sheet.dart';
import '../common/receipt.dart';
import '../common/success_screen.dart';
import '../common/launch.dart';
import 'gift_art.dart';
import 'gift_detail_screen.dart';

/// Knock Gift Send: brand, amount, recipient, message, review, PIN.
class SendGiftScreen extends StatefulWidget {
  const SendGiftScreen({super.key});
  @override
  State<SendGiftScreen> createState() => _SendGiftScreenState();
}

class _SendGiftScreenState extends State<SendGiftScreen> {
  final _brands = giftBrands.where((b) => b.sendable).toList();
  late GiftBrand _brand = _brands.first;
  late String _currency = _brand.rates.keys.first;
  int _value = 50;
  String _type = 'username';
  final _recipient = TextEditingController();
  final _message = TextEditingController();
  Json? _lookup;
  String? _lookupError;
  bool _checking = false;
  Json? _quote;
  bool _review = false;
  final _key = KnockApi.newIdempotencyKey();

  @override
  void initState() {
    super.initState();
    _refreshQuote();
  }

  @override
  void dispose() {
    _recipient.dispose();
    _message.dispose();
    super.dispose();
  }

  Future<void> _refreshQuote() async {
    try {
      final q = await context.api.call((s, t) => s.giftQuote(t!, brandId: _brand.id, currency: _currency, value: _value));
      if (mounted) setState(() => _quote = q);
    } catch (e) {
      if (mounted) setState(() => _quote = null);
    }
  }

  Future<void> _check() async {
    final h = _recipient.text.trim();
    if (h.isEmpty) return;
    setState(() {
      _checking = true;
      _lookupError = null;
    });
    try {
      final r = await context.api.call((s, t) => s.lookupRecipient(t!, h));
      if (mounted) setState(() => _lookup = r);
    } on ApiError catch (e) {
      if (mounted) setState(() => _lookupError = e.message);
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  String? get _recipientProblem {
    if (_type == 'link') return null;
    final h = _recipient.text.trim();
    if (h.isEmpty) return 'Enter who the gift is for.';
    if (_lookupError != null) return _lookupError;
    if (_type == 'username' && _lookup != null && _lookup!['exists'] != true) return 'No Knock user has that username.';
    if (_type == 'email' && !RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(h)) return 'Enter a valid email address.';
    if (_type == 'phone' && h.replaceAll(RegExp(r'\D'), '').length < 10) return 'Enter a valid phone number.';
    return null;
  }

  String get _recipientLabel {
    if (_type == 'link') return 'Anyone with the claim link';
    if (_lookup?['exists'] == true) return '${_lookup!['displayName']} (@${_lookup!['username']})';
    return _recipient.text.trim();
  }

  Future<void> _send() async {
    final api = context.api;
    try {
      final r = await withPin<Json>(context, title: 'Send gift', subtitle: '${_brand.name} ${F.face(_currency, _value)} for ${F.ngnExact(_quote?['priceKobo'] as int? ?? 0)}', action: (pin) {
        final sec = api.security();
        return api.call((s, t) => s.sendGift(t!,
            brandId: _brand.id,
            currency: _currency,
            value: _value,
            recipientType: _type,
            recipient: _type == 'link' ? null : _recipient.text.trim(),
            message: _message.text.trim(),
            pin: pin,
            idempotencyKey: _key,
            nonce: sec.nonce,
            sentAt: sec.sentAt));
      });
      if (r == null || !mounted) return;
      context.app.poke();
      final gift = r['gift'] as Json;
      final link = r['claimLink'] as String?;
      await Navigator.of(context).pushReplacement(KRoute(ResultScreen(
        title: 'Gift on its way 🎁',
        amountKobo: -((r['txn'] as Json)['amount'] as int),
        message: link != null
            ? 'Share this link with the person you are gifting. It works once and expires in 30 days. If nobody claims it, we refund you.'
            : _type == 'username'
                ? '${gift['recipientName']} will get a gift to open in their Knock app.'
                : 'We will let them know. They claim it by joining Knock with this ${_type == 'email' ? 'email' : 'number'}. The code is never sent in a message.',
        txn: r['txn'] as Json,
        extra: [
          if (link != null) ...[
            KnockCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Claim link', style: KnockText.caption),
              const SizedBox(height: 4),
              SelectableText(link, key: const ValueKey('gift-claim-url'), style: KnockText.bodyStrong),
            ])),
            const SizedBox(height: 10),
            KnockButton(key: const ValueKey('gift-share-link'), label: 'Share gift link', icon: Icons.ios_share_rounded, onPressed: () => shareText(context, "I've sent you a ${_brand.name} gift card on Knock 🎁 Open it here: $link", subject: 'A gift for you')),
            const SizedBox(height: 8),
            KnockButton(label: 'Share on WhatsApp', icon: Icons.chat_rounded, style: KnockButtonStyle.secondary, onPressed: () => whatsAppShare(context, "I've sent you a ${_brand.name} gift card on Knock 🎁 Open it here: $link")),
          ],
        ],
        nextLabel: 'Track gift',
        onNext: () => Navigator.of(context).pushReplacement(KRoute(GiftDetailScreen(giftId: gift['id'] as String))),
      )));
    } catch (e) {
      if (mounted) showApiError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_review,
      onPopInvokedWithResult: (did, _) {
        if (!did) setState(() => _review = false);
      },
      child: KPage(
        title: _review ? 'Review gift' : 'Send a Gift Card',
        subtitle: _review ? null : 'They get a gift to open, not a code in a text.',
        bottom: _review
            ? KnockButton(key: const ValueKey('gift-confirm'), label: 'Pay ${F.ngnExact(_quote?['priceKobo'] as int? ?? 0)} and send', onPressed: _quote == null ? null : _send)
            : KnockButton(
                key: const ValueKey('gift-continue'),
                label: 'Review gift',
                onPressed: () async {
                  if (_type == 'username' && _lookup == null) await _check();
                  final p = _recipientProblem;
                  if (p != null) {
                    if (context.mounted) toast(context, p, error: true);
                    return;
                  }
                  setState(() => _review = true);
                },
              ),
        children: _review ? _reviewChildren() : _formChildren(),
      ),
    );
  }

  List<Widget> _formChildren() => [
        GiftCardArt(brand: _brand.name, glyph: _brand.glyph, color: _brand.color, valueLabel: F.face(_currency, _value), height: 150),
        const SectionTitle('Brand'),
        ChoiceWrap<String>(
          choices: [for (final b in _brands) Choice(b.id, b.name)],
          selected: _brand.id,
          onSelected: (id) {
            setState(() {
              _brand = _brands.firstWhere((b) => b.id == id);
              if (!_brand.rates.containsKey(_currency)) _currency = _brand.rates.keys.first;
            });
            _refreshQuote();
          },
        ),
        const SectionTitle('Card currency'),
        ChoiceWrap<String>(
          choices: [for (final c in _brand.rates.keys) Choice(c, c)],
          selected: _currency,
          onSelected: (c) {
            setState(() => _currency = c);
            _refreshQuote();
          },
        ),
        const SectionTitle('Amount'),
        ChoiceWrap<int>(
          choices: [for (final v in sendDenominations) Choice(v, F.face(_currency, v))],
          selected: _value,
          onSelected: (v) {
            setState(() => _value = v);
            _refreshQuote();
          },
        ),
        if (_quote != null) ...[
          const SizedBox(height: 10),
          Note('You pay ${F.ngnExact(_quote!['priceKobo'] as int)} from your Naira wallet, including a ${F.ngnExact(_quote!['feeKobo'] as int)} service charge.', icon: Icons.info_outline_rounded),
        ],
        const SectionTitle('Send to'),
        ChoiceWrap<String>(
          choices: const [Choice('username', 'Knock username'), Choice('phone', 'Phone'), Choice('email', 'Email'), Choice('link', 'Claim link')],
          selected: _type,
          onSelected: (t) => setState(() {
            _type = t;
            _lookup = null;
            _lookupError = null;
          }),
        ),
        const SizedBox(height: 12),
        if (_type == 'link')
          const Note('We create a one-time link you can share anywhere. Whoever opens it first and signs in to Knock receives the gift. Unclaimed links are refunded after 30 days.', icon: Icons.link_rounded)
        else
          KField(
            key: const ValueKey('gift-recipient'),
            label: switch (_type) { 'phone' => 'Phone number', 'email' => 'Email address', _ => 'Username' },
            hint: switch (_type) { 'phone' => '0803 000 0000', 'email' => 'name@example.com', _ => '@username' },
            controller: _recipient,
            keyboard: switch (_type) { 'phone' => TextInputType.phone, 'email' => TextInputType.emailAddress, _ => TextInputType.text },
            error: _lookupError,
            helper: _lookup?['exists'] == true
                ? 'Sending to ${_lookup!['displayName']}'
                : _lookup?['exists'] == false && _type != 'username'
                    ? 'Not on Knock yet. They can claim it when they join with this ${_type == 'email' ? 'email' : 'number'}.'
                    : null,
            onChanged: (_) => setState(() {
              _lookup = null;
              _lookupError = null;
            }),
            onSubmitted: (_) => _check(),
            suffix: _checking
                ? const Padding(padding: EdgeInsets.all(14), child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)))
                : IconButton(tooltip: 'Check recipient', icon: const Icon(Icons.person_search_rounded), onPressed: _check),
          ),
        KField(key: const ValueKey('gift-message'), label: 'Message (optional)', controller: _message, hint: 'Happy birthday! 🎉', maxLength: 200, maxLines: 3),
      ];

  List<Widget> _reviewChildren() => [
        GiftCardArt(brand: _brand.name, glyph: _brand.glyph, color: _brand.color, valueLabel: F.face(_currency, _value), height: 150),
        const SizedBox(height: 16),
        KnockCard(
          child: Column(children: [
            KeyValue('Gift', '${_brand.name} ${F.face(_currency, _value)}'),
            KeyValue('To', _recipientLabel),
            if (_message.text.trim().isNotEmpty) KeyValue('Message', '"${_message.text.trim()}"'),
            KeyValue('Service charge', F.ngnExact(_quote?['feeKobo'] as int? ?? 0)),
            KeyValue('You pay', F.ngnExact(_quote?['priceKobo'] as int? ?? 0), strong: true),
            const KeyValue('Paid from', 'Naira wallet'),
          ]),
        ),
        const SizedBox(height: 12),
        const Note('The gift code is sealed. Only the recipient can reveal it, after signing in and confirming with their PIN.', icon: Icons.lock_outline_rounded),
        const SizedBox(height: 8),
        TextButton(onPressed: () => setState(() => _review = false), child: const Text('Edit gift')),
      ];
}
