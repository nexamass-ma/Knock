import 'package:material_ui/material_ui.dart';

import '../../app/app_scope.dart';
import '../../core/money.dart';
import '../../design/tokens.dart';
import '../../design/widgets/states.dart';
import '../../design/widgets/surfaces.dart';
import '../../models/quote.dart';
import '../giftcards/buy_gift_card_screen.dart';
import '../giftcards/sell_gift_card_screen.dart';
import '../wallet/asset_detail_screen.dart';

Future<void> showBillsSheet(BuildContext context) {
  final shell = context.app.shell;
  const items = [
    (TxFlow.airtime, Icons.phone_iphone_rounded, 'Airtime', 'MTN, Airtel, Glo, 9mobile'),
    (TxFlow.data, Icons.wifi_rounded, 'Mobile data', 'Daily, weekly and monthly plans'),
    (TxFlow.electricity, Icons.bolt_rounded, 'Electricity', 'Prepaid and postpaid meters'),
    (TxFlow.cable, Icons.live_tv_rounded, 'Cable TV', 'DStv, GOtv, StarTimes'),
  ];
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(KnockSpace.gutter, 0, KnockSpace.gutter, KnockSpace.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Pay a bill', style: KnockText.title),
            const SizedBox(height: 4),
            Text('KNOCK will walk you through it in chat and show a quote before you pay.', style: KnockText.caption),
            const SizedBox(height: KnockSpace.md),
            for (final (flow, icon, title, sub) in items)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: KnockCard(
                  color: KnockColors.surfaceRaised,
                  onTap: () {
                    Navigator.of(ctx).pop();
                    shell.openAssistant(flow);
                  },
                  child: Row(
                    children: [
                      Container(
                        width: 42,
                        height: 42,
                        decoration: BoxDecoration(
                          color: KnockColors.greenSoft,
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Icon(icon, color: KnockColors.green, size: 21),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(title, style: KnockText.bodyStrong),
                            Text(sub, style: KnockText.caption),
                          ],
                        ),
                      ),
                      const Icon(Icons.chevron_right_rounded, color: KnockColors.textTertiary),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    ),
  );
}

Future<void> showNotificationsSheet(BuildContext context) {
  final now = DateTime.now();
  final items = [
    (
      Icons.check_circle_outline_rounded,
      KnockColors.green,
      'USDT purchase complete',
      '31.6 USDT added to your crypto balance.',
      now.subtract(const Duration(hours: 2)),
    ),
    (
      Icons.credit_card_rounded,
      KnockColors.orange,
      'Dollar card is coming',
      'Join the early-access list to be first in line.',
      now.subtract(const Duration(hours: 20)),
    ),
    (
      Icons.verified_user_outlined,
      KnockColors.textSecondary,
      'New sign-in',
      'Your account was opened on this device.',
      now.subtract(const Duration(days: 2)),
    ),
  ];
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(KnockSpace.gutter, 0, KnockSpace.gutter, KnockSpace.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Text('Notifications', style: KnockText.title),
                Spacer(),
                MockBadge(label: 'MOCK'),
              ],
            ),
            const SizedBox(height: KnockSpace.md),
            for (final (icon, tint, title, body, at) in items)
              Padding(
                padding: const EdgeInsets.only(bottom: 14),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(icon, color: tint, size: 22),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(title, style: KnockText.bodyStrong),
                          const SizedBox(height: 2),
                          Text(body, style: KnockText.caption),
                        ],
                      ),
                    ),
                    Text(Fmt.dayLabel(at), style: KnockText.micro),
                  ],
                ),
              ),
          ],
        ),
      ),
    ),
  );
}

Future<void> showSearchSheet(BuildContext context) {
  return showModalBottomSheet<void>(context: context, isScrollControlled: true, builder: (ctx) => const _SearchSheet());
}

class _SearchSheet extends StatefulWidget {
  const _SearchSheet();
  @override
  State<_SearchSheet> createState() => _SearchSheetState();
}

class _SearchSheetState extends State<_SearchSheet> {
  String _q = '';

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final nav = Navigator.of(context);
    final actions = <(String, IconData, VoidCallback)>[
      ('Buy crypto', Icons.add_chart_rounded, () => app.shell.openAssistant(TxFlow.buyCrypto)),
      ('Sell crypto', Icons.currency_exchange_rounded, () => app.shell.openAssistant(TxFlow.sellCrypto)),
      (
        'Buy gift cards',
        Icons.card_giftcard_rounded,
        () => nav.push(MaterialPageRoute<void>(builder: (_) => const BuyGiftCardScreen())),
      ),
      (
        'Sell gift cards',
        Icons.redeem_rounded,
        () => nav.push(MaterialPageRoute<void>(builder: (_) => const SellGiftCardScreen())),
      ),
      ('Buy airtime', Icons.phone_iphone_rounded, () => app.shell.openAssistant(TxFlow.airtime)),
      ('Buy data', Icons.wifi_rounded, () => app.shell.openAssistant(TxFlow.data)),
      ('Pay electricity', Icons.bolt_rounded, () => app.shell.openAssistant(TxFlow.electricity)),
      ('Pay cable TV', Icons.live_tv_rounded, () => app.shell.openAssistant(TxFlow.cable)),
    ];
    final q = _q.toLowerCase();
    final assets = app.wallet.holdings
        .where((h) => q.isEmpty || h.asset.name.toLowerCase().contains(q) || h.asset.ticker.toLowerCase().contains(q))
        .toList();
    final acts = actions.where((a) => q.isEmpty || a.$1.toLowerCase().contains(q)).toList();

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.75,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: KnockSpace.gutter),
              child: TextField(
                autofocus: true,
                onChanged: (v) => setState(() => _q = v),
                decoration: const InputDecoration(
                  hintText: 'Search assets and actions',
                  prefixIcon: Icon(Icons.search_rounded, color: KnockColors.textSecondary),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: assets.isEmpty && acts.isEmpty
                  ? const EmptyState(
                      icon: Icons.search_off_rounded,
                      title: 'No results',
                      message: 'Try an asset like "BTC" or an action like "airtime".',
                    )
                  : ListView(
                      children: [
                        if (assets.isNotEmpty) const _Label('Assets'),
                        for (final h in assets)
                          ListTile(
                            leading: GlyphAvatar(glyph: h.asset.glyph, tint: h.asset.tint, size: 36),
                            title: Text(h.asset.name, style: KnockText.bodyStrong),
                            subtitle: Text(h.asset.ticker, style: KnockText.caption),
                            trailing: ChangeText(h.change24h),
                            onTap: () {
                              nav.pop();
                              nav.push(MaterialPageRoute<void>(builder: (_) => AssetDetailScreen(holding: h)));
                            },
                          ),
                        if (acts.isNotEmpty) const _Label('Actions'),
                        for (final a in acts)
                          ListTile(
                            leading: Icon(a.$2, color: KnockColors.green),
                            title: Text(a.$1, style: KnockText.body),
                            onTap: () {
                              nav.pop();
                              a.$3();
                            },
                          ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Label extends StatelessWidget {
  const _Label(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(KnockSpace.gutter, 14, KnockSpace.gutter, 4),
    child: Text(text.toUpperCase(), style: KnockText.micro),
  );
}
