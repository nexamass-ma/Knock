import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../api/api.dart';
import '../../app/app_controller.dart';
import '../../core/format.dart';
import '../../design/tokens.dart';
import '../../design/widgets/kit.dart';
import '../common/pin_sheet.dart';
import '../history/transaction_detail_screen.dart';
import '../trade/sell_gift_card_screen.dart';
import 'gift_art.dart';

class GiftDetailScreen extends StatefulWidget {
  const GiftDetailScreen({super.key, required this.giftId});
  final String giftId;
  @override
  State<GiftDetailScreen> createState() => _GiftDetailScreenState();
}

class _GiftDetailScreenState extends State<GiftDetailScreen> {
  String? _code;
  String? _pinNote;

  Future<void> _open() async {
    try {
      await context.api.call((s, t) => s.openGift(t!, widget.giftId));
      if (mounted) context.app.poke();
    } catch (e) {
      if (mounted) showApiError(context, e);
    }
  }

  Future<void> _reveal() async {
    final api = context.api;
    try {
      final r = await withPin<Json>(context, title: 'Reveal gift code', subtitle: 'Confirm it is you before we show the code.', action: (pin) => api.call((s, t) => s.revealGiftCode(t!, widget.giftId, pin)));
      if (r == null || !mounted) return;
      setState(() {
        _code = r['code'] as String;
        _pinNote = r['pinNote'] as String?;
      });
      context.app.poke();
    } catch (e) {
      if (mounted) showApiError(context, e);
    }
  }

  Future<void> _redeemed() async {
    if (!await confirm(context, title: 'Mark as redeemed?', message: 'Do this once you have used the code at the brand. You will not be able to trade it afterwards.', yes: 'Mark redeemed')) return;
    if (!mounted) return;
    try {
      await context.api.call((s, t) => s.markGiftRedeemed(t!, widget.giftId));
      if (!mounted) return;
      context.app.poke();
      toast(context, 'Enjoy your gift!');
    } catch (e) {
      if (mounted) showApiError(context, e);
    }
  }

  Future<void> _trade() async {
    final api = context.api;
    try {
      final r = await withPin<Json>(context, title: 'Trade this gift', subtitle: 'We will prepare a sell quote at the current rate.', action: (pin) => api.call((s, t) => s.tradeGift(t!, widget.giftId, pin)));
      if (r == null || !mounted) return;
      await sellFromGift(context, r['quote'] as Json, r['ecode'] as String?);
    } catch (e) {
      if (mounted) showApiError(context, e);
    }
  }

  Future<void> _forward(Json g) async {
    final c = TextEditingController();
    final handle = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (s) => Padding(
        padding: EdgeInsets.fromLTRB(24, 0, 24, 24 + MediaQuery.viewInsetsOf(s).bottom),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Forward this gift', style: KnockText.title),
          const SizedBox(height: 6),
          Text('${g['brand']} lets you pass this gift on to another Knock user. Once forwarded, it leaves your account.', style: KnockText.caption),
          const SizedBox(height: 16),
          KField(key: const ValueKey('forward-field'), label: 'Knock username, phone or email', controller: c, autofocus: true),
          KnockButton(key: const ValueKey('forward-submit'), label: 'Continue', onPressed: () => Navigator.pop(s, c.text.trim())),
        ]),
      ),
    );
    if (handle == null || handle.isEmpty || !mounted) return;
    final api = context.api;
    try {
      final r = await withPin<Json>(context, title: 'Forward gift', subtitle: 'To $handle', action: (pin) => api.call((s, t) => s.forwardGift(t!, widget.giftId, handle, pin)));
      if (r == null || !mounted) return;
      context.app.poke();
      toast(context, 'Gift forwarded');
      Navigator.of(context).pop();
    } catch (e) {
      if (mounted) showApiError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ApiView(
      load: (api) => api.call((s, t) => s.gift(t!, widget.giftId)),
      builder: (context, d, reload) {
        final g = d['gift'] as Json;
        final received = g['direction'] == 'received';
        final status = g['status'] as String;
        if (received && status == 'delivered') return _Unopened(g: g, onOpened: _open);
        return KPage(
          title: received ? 'Your gift' : 'Gift you sent',
          onRefresh: reload,
          children: [
            GiftCardArt(brand: g['brand'] as String, glyph: g['glyph'] as String, color: g['color'] as int, valueLabel: F.face(g['currency'] as String, g['value'] as int)),
            const SizedBox(height: 14),
            Row(children: [
              StatusChip(status == 'redeemed' || status == 'opened' || status == 'delivered' ? 'successful' : (status == 'expired' ? 'failed' : (status == 'traded' ? 'traded' : 'pending')), label: giftStatusLabel(status)),
              const Spacer(),
              Text(g['reference'] as String, style: KnockText.caption),
            ]),
            if ((g['message'] as String?)?.isNotEmpty == true) ...[
              const SizedBox(height: 14),
              KnockCard(child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Icon(Icons.format_quote_rounded, color: KnockColors.orange),
                const SizedBox(width: 8),
                Expanded(child: Text('${g['message']}\n— ${received ? g['senderName'] : 'You'}', style: KnockText.body)),
              ])),
            ],
            if (received) ..._receivedActions(g, status) else ..._senderView(g),
          ],
        );
      },
    );
  }

  List<Widget> _receivedActions(Json g, String status) {
    final usable = status == 'opened' || status == 'delivered';
    return [
      const SectionTitle('Gift code'),
      if (_code != null)
        KnockCard(
          key: const ValueKey('gift-code-card'),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(child: SelectableText(_code!, key: const ValueKey('gift-code'), style: KnockText.headline.copyWith(letterSpacing: 2))),
              IconButton(
                tooltip: 'Copy code',
                icon: const Icon(Icons.copy_rounded),
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: _code!));
                  toast(context, 'Code copied');
                },
              ),
            ]),
            if (_pinNote != null) Text(_pinNote!, style: KnockText.caption),
          ]),
        )
      else if (status == 'traded' || status == 'expired')
        Note(status == 'traded' ? 'You traded this gift on Knock. See the trade in your history.' : 'This gift has expired.', icon: Icons.info_outline_rounded)
      else
        KnockButton(key: const ValueKey('gift-reveal'), label: 'Reveal code', icon: Icons.visibility_rounded, onPressed: _reveal),
      if (usable) ...[
        const SectionTitle('What would you like to do?'),
        ListRow(key: const ValueKey('gift-redeem'), icon: Icons.shopping_bag_outlined, title: 'Redeem it', subtitle: 'Use the code at ${g['brand']}, then mark it redeemed', onTap: _redeemed),
        if (g['tradable'] == true) ListRow(key: const ValueKey('gift-trade'), icon: Icons.currency_exchange_rounded, title: 'Trade it for Naira', subtitle: 'Sell it on Knock at today\'s rate', onTap: _trade),
        if (g['forwardable'] == true)
          ListRow(key: const ValueKey('gift-forward'), icon: Icons.forward_rounded, title: 'Forward it', subtitle: 'Pass it on to someone else on Knock', onTap: () => _forward(g))
        else
          ListRow(icon: Icons.block_rounded, title: 'Forwarding not available', subtitle: "${g['brand']}'s terms do not allow passing gifts on", onTap: null),
      ],
      const SizedBox(height: 12),
      KeyValue('From', g['senderName'] as String),
      KeyValue('Received', F.dateTime(g['createdAt'] as String)),
      KeyValue('Use before', F.date(g['expiresAt'] as String)),
    ];
  }

  List<Widget> _senderView(Json g) {
    final events = (g['events'] as List).cast<Json>();
    const flow = ['payment_pending', 'preparing', 'sent', 'delivered', 'opened', 'redeemed'];
    final reached = {for (final e in events) e['status'] as String: e['at'] as String};
    final steps = [
      ...flow,
    ];
    if (reached.containsKey('awaiting_claim')) steps.insert(3, 'awaiting_claim');
    if (reached.containsKey('traded')) steps[steps.length - 1] = 'traded';
    if (reached.containsKey('expired')) steps.add('expired');
    return [
      const SectionTitle('Gift tracker'),
      KnockCard(
        child: Column(children: [
          for (var i = 0; i < steps.length; i++)
            _TrackStep(label: giftStatusLabel(steps[i]), at: reached[steps[i]], done: reached.containsKey(steps[i]), last: i == steps.length - 1),
        ]),
      ),
      const SizedBox(height: 12),
      KeyValue('To', g['recipientName'] as String? ?? '—'),
      KeyValue('Sent', F.dateTime(g['createdAt'] as String)),
      if (g['claimExpiresAt'] != null && g['status'] == 'awaiting_claim') KeyValue('Claim by', F.date(g['claimExpiresAt'] as String)),
      const SizedBox(height: 8),
      const Note('You can see the gift\'s progress, but never its code. Only the recipient can reveal it.', icon: Icons.lock_outline_rounded),
      const SizedBox(height: 12),
      ApiView(
        live: false,
        load: (api) => api.call((s, t) => s.transactions(t!, type: 'gifts', limit: 50)),
        builder: (context, d, _) {
          final t = (d['items'] as List).cast<Json>().where((t) => (t['details'] as Map?)?['giftId'] == g['id']).firstOrNull;
          if (t == null) return const SizedBox.shrink();
          return KnockButton(label: 'View payment receipt', style: KnockButtonStyle.secondary, onPressed: () => go(context, TransactionDetailScreen(txnId: t['id'] as String)));
        },
      ),
    ];
  }
}

class _TrackStep extends StatelessWidget {
  const _TrackStep({required this.label, required this.at, required this.done, required this.last});
  final String label;
  final String? at;
  final bool done;
  final bool last;
  @override
  Widget build(BuildContext context) {
    return IntrinsicHeight(
      child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Column(children: [
          Container(width: 14, height: 14, decoration: BoxDecoration(shape: BoxShape.circle, color: done ? KnockColors.green : KnockColors.surfaceHigh, border: Border.all(color: done ? KnockColors.green : KnockColors.stroke, width: 2))),
          if (!last) Expanded(child: Container(width: 2, color: done ? KnockColors.green.withValues(alpha: 0.5) : KnockColors.stroke)),
        ]),
        const SizedBox(width: 12),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(label, style: done ? KnockText.bodyStrong : KnockText.body.copyWith(color: KnockColors.textSecondary)),
              if (at != null) Text(F.dateTime(at!), style: KnockText.caption),
            ]),
          ),
        ),
      ]),
    );
  }
}

class _Unopened extends StatelessWidget {
  const _Unopened({required this.g, required this.onOpened});
  final Json g;
  final VoidCallback onOpened;
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(children: [
            const Spacer(),
            Text("🎁 You've received a gift!", style: KnockText.title, textAlign: TextAlign.center),
            const SizedBox(height: 8),
            Text('${g['senderName']} sent you a ${F.face(g['currency'] as String, g['value'] as int)} ${g['brand']} Gift Card.', style: KnockText.body, textAlign: TextAlign.center),
            const SizedBox(height: 24),
            GiftBox(onOpened: onOpened),
            const SizedBox(height: 8),
            Text('Tap the gift to open it', style: KnockText.caption),
            const Spacer(),
            KnockButton(key: const ValueKey('gift-open'), label: 'Open My Gift', icon: Icons.redeem_rounded, onPressed: onOpened),
          ]),
        ),
      ),
    );
  }
}
