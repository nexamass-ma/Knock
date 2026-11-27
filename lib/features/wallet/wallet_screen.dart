import 'package:material_ui/material_ui.dart';

import '../../app/app_scope.dart';
import '../../design/tokens.dart';
import '../../design/widgets/states.dart';
import '../../design/widgets/surfaces.dart';
import '../../models/ledger.dart';
import '../../state/wallet_store.dart';
import '../card/dollar_card_screen.dart';
import '../home/home_screen.dart';
import '../shell/shell.dart';
import 'asset_detail_screen.dart';
import 'money_sheets.dart';

class WalletScreen extends StatelessWidget {
  const WalletScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    return ListenableBuilder(
      listenable: Listenable.merge([app.wallet, app.session]),
      builder: (context, _) {
        final w = app.wallet;
        final hidden = app.session.hideBalances;
        return Scaffold(
          body: SafeArea(
            bottom: false,
            child: RefreshIndicator(
              color: KnockColors.green,
              onRefresh: () => w.load(silent: true),
              child: ListView(
                padding: const EdgeInsets.only(bottom: kNavClearance + 16),
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(KnockSpace.gutter, 12, KnockSpace.gutter, 4),
                    child: Row(
                      children: [
                        const Expanded(child: Text('Wallet', style: KnockText.title)),
                        if (app.services.isMock) const MockBadge(label: 'MOCK'),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: KnockSpace.gutter),
                    child: Text(
                      'Three separate balances. Money only moves between them when you confirm a transaction.',
                      style: KnockText.caption,
                    ),
                  ),
                  const SizedBox(height: KnockSpace.md),
                  if (w.state == LoadState.error)
                    ErrorState(message: w.error ?? '', onRetry: w.load)
                  else if (w.state != LoadState.ready)
                    const SkeletonList(rows: 3)
                  else ...[
                    _NairaCard(balance: w.balance(LedgerKind.naira)!, hidden: hidden),
                    _LedgerTile(
                      title: 'Crypto',
                      subtitle: 'Held with our custody partner',
                      value: w.balance(LedgerKind.crypto)!.available.format(),
                      hidden: hidden,
                      glyph: '₿',
                      tint: const Color(0xFFF2A33A),
                    ),
                    _LedgerTile(
                      title: 'Dollar card',
                      subtitle: 'Not active yet',
                      value: 'Coming soon',
                      hidden: false,
                      glyph: r'$',
                      tint: KnockColors.violetMuted,
                      locked: true,
                      onTap: () =>
                          Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const DollarCardScreen())),
                    ),
                    const SectionHeader('Crypto holdings'),
                    for (final h in w.holdings)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: KnockSpace.gutter, vertical: 5),
                        child: AssetRow(
                          holding: h,
                          hidden: hidden,
                          onTap: () =>
                              Navigator.of(context)
                                  .push(MaterialPageRoute<void>(builder: (_) => AssetDetailScreen(holding: h))),
                        ),
                      ),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _NairaCard extends StatelessWidget {
  const _NairaCard({required this.balance, required this.hidden});
  final LedgerBalance balance;
  final bool hidden;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: KnockSpace.gutter),
      child: KnockCard(
        gradient: KnockColors.cardGradient,
        padding: const EdgeInsets.all(20),
        semanticLabel: 'Naira wallet',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('Naira wallet', style: KnockText.caption.copyWith(color: Colors.white70)),
                const Spacer(),
                const Tag('NGN', color: KnockColors.greenBright),
              ],
            ),
            const SizedBox(height: 8),
            BalanceText(balance.available.format(), hidden: hidden, style: KnockText.display.copyWith(fontSize: 32)),
            const SizedBox(height: 4),
            Text('Pending ${balance.pending.format()}', style: KnockText.micro.copyWith(fontWeight: FontWeight.w400)),
            const SizedBox(height: 18),
            Row(
              children: [
                Expanded(
                  child: KnockButton(
                    label: 'Add money',
                    icon: Icons.south_west_rounded,
                    onPressed: () => showDepositSheet(context),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: KnockButton(
                    label: 'Withdraw',
                    icon: Icons.north_east_rounded,
                    style: KnockButtonStyle.secondary,
                    onPressed: () => showWithdrawSheet(context),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _LedgerTile extends StatelessWidget {
  const _LedgerTile({
    required this.title,
    required this.subtitle,
    required this.value,
    required this.hidden,
    required this.glyph,
    required this.tint,
    this.locked = false,
    this.onTap,
  });

  final String title;
  final String subtitle;
  final String value;
  final bool hidden;
  final String glyph;
  final Color tint;
  final bool locked;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(KnockSpace.gutter, 10, KnockSpace.gutter, 0),
      child: KnockCard(
        onTap: onTap,
        child: Row(
          children: [
            GlyphAvatar(glyph: glyph, tint: tint, size: 40),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: KnockText.bodyStrong),
                  Text(subtitle, style: KnockText.caption),
                ],
              ),
            ),
            if (locked)
              const Tag('Coming soon', color: KnockColors.orange, icon: Icons.lock_rounded)
            else
              BalanceText(value, hidden: hidden),
          ],
        ),
      ),
    );
  }
}
