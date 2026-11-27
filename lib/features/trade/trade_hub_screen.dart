import 'package:material_ui/material_ui.dart';

import '../../api/api.dart';
import '../../app/app_controller.dart';
import '../../design/tokens.dart';
import '../../design/widgets/kit.dart';
import '../history/txn_tile.dart';
import '../shell/nav.dart';
import '../shell/shell.dart';
import 'rates_screen.dart';

class TradeHubScreen extends StatelessWidget {
  const TradeHubScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final hidden = context.appWatch.hideBalances;
    return Scaffold(
      appBar: AppBar(
        leading: const MenuButton(),
        title: const Text('Trade'),
        actions: [
          TextButton.icon(
            key: const ValueKey('trade-current-rate'),
            onPressed: () => Nav.rates(context),
            icon: const Icon(Icons.trending_up_rounded, size: 18, color: KnockColors.greenBright),
            label: Text('Current Rate', style: KnockText.bodyStrong.copyWith(color: KnockColors.greenBright)),
          ),
        ],
      ),
      body: ApiView(
        load: (api) async {
          final r = await Future.wait([
            api.call((s, t) => s.transactions(t!, status: 'pending', type: 'giftcard_sell')),
            api.call((s, t) => s.watchlist(t!)),
            api.call((s, t) => s.giftCardRates(t!)),
          ]);
          return {'active': r[0], 'watch': r[1], 'rates': r[2]};
        },
        builder: (context, d, reload) {
          final active = ((d['active'] as Json)['items'] as List).cast<Json>();
          final watch = ((d['watch'] as Json)['items'] as List).cast<Json>();
          final top = ((d['rates'] as Json)['items'] as List).cast<Json>().where((r) => r['currency'] == 'USD').take(4).toList();
          return RefreshIndicator(
            color: KnockColors.green,
            onRefresh: reload,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(KnockSpace.gutter, 8, KnockSpace.gutter, 32),
              children: [
                _Big(
                  key: const ValueKey('trade-sell-gift'),
                  icon: Icons.card_giftcard_rounded,
                  title: 'Sell a gift card',
                  body: 'See your payout before you submit. Paid to your wallet.',
                  gradient: KnockColors.cardGradient,
                  onTap: () => Nav.sellGiftCard(context),
                ),
                const SizedBox(height: 10),
                Row(children: [
                  Expanded(child: _Small(key: const ValueKey('trade-sell-crypto'), icon: Icons.currency_bitcoin_rounded, title: 'Sell crypto', onTap: () => Nav.crypto(context))),
                  const SizedBox(width: 10),
                  Expanded(child: _Small(icon: Icons.shopping_bag_outlined, title: 'Buy crypto', onTap: () => Nav.crypto(context, side: 'buy'))),
                  const SizedBox(width: 10),
                  Expanded(child: _Small(icon: Icons.redeem_rounded, title: 'Send a gift', onTap: () => Nav.sendGift(context))),
                ]),
                if (active.isNotEmpty) ...[
                  const SectionTitle('Trades in progress'),
                  for (final t in active) TxnTile(t, hidden: hidden),
                ],
                SectionTitle('Today\'s rates', trailing: TextButton(onPressed: () => Nav.rates(context), child: Text('All rates', style: KnockText.bodyStrong.copyWith(color: KnockColors.greenBright)))),
                for (final r in top) RateRow(r: r, onTap: () => showRateDetail(context, r)),
                SectionTitle('Watchlist', trailing: TextButton(onPressed: () => Nav.watchlist(context), child: Text(watch.isEmpty ? 'Set up' : 'Manage', style: KnockText.bodyStrong.copyWith(color: KnockColors.greenBright)))),
                if (watch.isEmpty)
                  Text('Tap the bell on any rate to be alerted when it moves.', style: KnockText.caption)
                else
                  for (final w in watch) RateRow(r: w['rate'] as Json, onTap: () => showRateDetail(context, w['rate'] as Json)),
                const SizedBox(height: 16),
                ListRow(icon: Icons.history_rounded, title: 'All trades', subtitle: 'History, receipts and disputes', onTap: () => Nav.tab(context, ShellTab.history)),
                ListRow(icon: Icons.lightbulb_outline_rounded, title: 'How trading works', subtitle: 'Rates, fees and settlement explained', onTap: () => Nav.workings(context)),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _Big extends StatelessWidget {
  const _Big({super.key, required this.icon, required this.title, required this.body, required this.gradient, required this.onTap});
  final IconData icon;
  final String title, body;
  final Gradient gradient;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => KnockCard(
    gradient: gradient,
    onTap: onTap,
    padding: const EdgeInsets.all(20),
    child: Row(children: [
      Icon(icon, size: 34, color: KnockColors.greenBright),
      const SizedBox(width: 16),
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: KnockText.headline),
        const SizedBox(height: 4),
        Text(body, style: KnockText.caption.copyWith(color: Colors.white70)),
      ])),
      const Icon(Icons.arrow_forward_rounded),
    ]),
  );
}

class _Small extends StatelessWidget {
  const _Small({super.key, required this.icon, required this.title, required this.onTap});
  final IconData icon;
  final String title;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => KnockCard(
    onTap: onTap,
    padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 8),
    child: Column(children: [
      Icon(icon, color: KnockColors.greenBright),
      const SizedBox(height: 8),
      Text(title, style: KnockText.caption.copyWith(color: KnockColors.textPrimary, fontWeight: FontWeight.w600), textAlign: TextAlign.center),
    ]),
  );
}
