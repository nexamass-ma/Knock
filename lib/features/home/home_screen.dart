import 'package:material_ui/material_ui.dart';

import '../../app/app_scope.dart';
import '../../core/money.dart';
import '../../design/tokens.dart';
import '../../design/widgets/charts.dart';
import '../../design/widgets/states.dart';
import '../../design/widgets/surfaces.dart';
import '../../models/asset.dart';
import '../../models/ledger.dart';
import '../../models/quote.dart';
import '../../state/shell_controller.dart';
import '../../state/wallet_store.dart';
import '../auth/wordmark.dart';
import '../card/dollar_card_screen.dart';
import '../giftcards/buy_gift_card_screen.dart';
import '../giftcards/sell_gift_card_screen.dart';
import '../shell/shell.dart';
import '../wallet/asset_detail_screen.dart';
import '../wallet/money_sheets.dart';
import 'home_sheets.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

enum _BalanceTab { crypto, naira, card }

class _HomeScreenState extends State<HomeScreen> {
  _BalanceTab _tab = _BalanceTab.crypto;

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    return ListenableBuilder(
      listenable: Listenable.merge([app.wallet, app.session]),
      builder: (context, _) {
        final w = app.wallet;
        return RefreshIndicator(
          color: KnockColors.green,
          backgroundColor: KnockColors.surfaceRaised,
          onRefresh: () => w.load(silent: true),
          child: CustomScrollView(
            physics: const AlwaysScrollableScrollPhysics(parent: BouncingScrollPhysics()),
            slivers: [
              SliverToBoxAdapter(
                child: _Hero(key: ValueKey(Object.hash(w.portfolio, app.session.hideBalances, app.session.showUsd))),
              ),
              const SliverToBoxAdapter(child: SectionHeader('Start a trade')),
              const SliverToBoxAdapter(child: _TradeGrid()),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(
                    KnockSpace.gutter,
                    KnockSpace.xl,
                    KnockSpace.gutter,
                    KnockSpace.sm,
                  ),
                  child: PillTabs<_BalanceTab>(
                    values: _BalanceTab.values,
                    selected: _tab,
                    labelOf: (t) => switch (t) {
                      _BalanceTab.crypto => 'Crypto',
                      _BalanceTab.naira => 'Naira',
                      _BalanceTab.card => 'Dollar card',
                    },
                    onChanged: (t) => setState(() => _tab = t),
                  ),
                ),
              ),
              if (w.state == LoadState.loading || w.state == LoadState.idle)
                const SliverToBoxAdapter(child: SkeletonList())
              else if (w.state == LoadState.error)
                SliverToBoxAdapter(
                  child: ErrorState(message: w.error ?? '', onRetry: w.load),
                )
              else
                SliverToBoxAdapter(
                  child: AnimatedSwitcher(
                    duration: KnockMotion.base,
                    child: KeyedSubtree(key: ValueKey(_tab), child: _tabBody(context)),
                  ),
                ),
              const SliverToBoxAdapter(child: _CardTeaser()),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(KnockSpace.gutter, KnockSpace.xl, KnockSpace.gutter, 0),
                  child: Text(
                    'Prototype. Balances, prices and rates are sample data from mock services, not live markets.',
                    style: KnockText.micro.copyWith(color: KnockColors.textTertiary, fontWeight: FontWeight.w400),
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
              const SliverToBoxAdapter(child: SizedBox(height: kNavClearance + 16)),
            ],
          ),
        );
      },
    );
  }

  Widget _tabBody(BuildContext context) {
    final app = context.app;
    final w = app.wallet;
    final hidden = app.session.hideBalances;
    switch (_tab) {
      case _BalanceTab.crypto:
        return Column(
          children: [
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
        );
      case _BalanceTab.naira:
        final b = w.balance(LedgerKind.naira);
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: KnockSpace.gutter, vertical: 5),
          child: KnockCard(
            semanticLabel: 'Naira wallet',
            child: Row(
              children: [
                const GlyphAvatar(glyph: '₦', tint: KnockColors.green),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Naira wallet', style: KnockText.bodyStrong),
                      const SizedBox(height: 2),
                      Text('Funds bills, crypto and gift card purchases', style: KnockText.caption),
                    ],
                  ),
                ),
                BalanceText(b?.available.format() ?? '-', hidden: hidden),
              ],
            ),
          ),
        );
      case _BalanceTab.card:
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: KnockSpace.gutter, vertical: 5),
          child: KnockCard(
            onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const DollarCardScreen())),
            child: Row(
              children: [
                const GlyphAvatar(glyph: r'$', tint: KnockColors.violetMuted),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('KNOCK Dollar Card', style: KnockText.bodyStrong),
                      const SizedBox(height: 2),
                      Text('Not active yet. Join the early-access list.', style: KnockText.caption),
                    ],
                  ),
                ),
                const Tag('Coming soon', color: KnockColors.orange, icon: Icons.lock_rounded),
              ],
            ),
          ),
        );
    }
  }
}

// ------------------------------------------------------------------ hero

class _Hero extends StatelessWidget {
  const _Hero({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final session = app.session;
    final w = app.wallet;
    final p = w.portfolio;
    final top = MediaQuery.paddingOf(context).top;
    final total = p == null ? null : (session.showUsd ? p.totalUsd : p.totalNgn);

    return Container(
      decoration: const BoxDecoration(
        gradient: KnockColors.heroGradient,
        borderRadius: BorderRadius.vertical(bottom: Radius.circular(KnockRadius.xl + 4)),
      ),
      child: Stack(
        children: [
          // Soft light from the top right, like a studio light on glass.
          Positioned(
            right: -80,
            top: -60,
            child: IgnorePointer(
              child: Container(
                width: 280,
                height: 280,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(colors: [Color(0x33FFFFFF), Color(0x00FFFFFF)]),
                ),
              ),
            ),
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(KnockSpace.gutter, top + 12, KnockSpace.gutter, 22),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const KnockWordmark(size: 15),
                          const SizedBox(height: 10),
                          Text(
                            '${Fmt.greeting(DateTime.now())}, ${session.firstName}',
                            style: KnockText.body.copyWith(color: Colors.white.withValues(alpha: 0.82)),
                          ),
                        ],
                      ),
                    ),
                    GlassIconButton(icon: Icons.search_rounded, label: 'Search', onTap: () => showSearchSheet(context)),
                    const SizedBox(width: 10),
                    GlassIconButton(
                      icon: Icons.notifications_none_rounded,
                      label: 'Notifications',
                      badge: true,
                      onTap: () => showNotificationsSheet(context),
                    ),
                  ],
                ),
                const SizedBox(height: 26),
                Row(
                  children: [
                    Flexible(
                      flex: 3,
                      child: _CurrencySelector(usd: session.showUsd, onChanged: session.setShowUsd),
                    ),
                    const SizedBox(width: 6),
                    Semantics(
                      button: true,
                      label: session.hideBalances ? 'Show balances' : 'Hide balances',
                      excludeSemantics: true,
                      child: IconButton(
                        visualDensity: VisualDensity.compact,
                        onPressed: session.toggleHideBalances,
                        icon: Icon(
                          session.hideBalances ? Icons.visibility_off_outlined : Icons.visibility_outlined,
                          size: 18,
                          color: Colors.white.withValues(alpha: 0.7),
                        ),
                      ),
                    ),
                    const Spacer(flex: 1),
                    if (app.services.isMock) const MockBadge(label: 'MOCK'),
                  ],
                ),
                const SizedBox(height: 4),
                if (total == null)
                  const Skeleton(height: 42, width: 230)
                else
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: BalanceText(total.format(), hidden: session.hideBalances, style: KnockText.display),
                  ),
                const SizedBox(height: 10),
                if (p != null)
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.25),
                          borderRadius: BorderRadius.circular(KnockRadius.pill),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              p.changePercent >= 0 ? Icons.arrow_outward_rounded : Icons.south_east_rounded,
                              size: 13,
                              color: p.changePercent >= 0 ? KnockColors.greenBright : KnockColors.loss,
                            ),
                            const SizedBox(width: 3),
                            ChangeText(p.changePercent, style: KnockText.micro),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text('past ${_rangeWords(p.range)}', style: KnockText.micro.copyWith(color: Colors.white60)),
                    ],
                  ),
                const SizedBox(height: 14),
                if (p != null)
                  AreaChart(
                    values: p.history,
                    height: 70,
                    color: KnockColors.greenBright,
                    semanticLabel:
                        'Portfolio performance, ${Fmt.percent(p.changePercent)} over the past ${_rangeWords(p.range)}',
                  ),
                const SizedBox(height: 10),
                PillTabs<ChartRange>(
                  values: ChartRange.values,
                  selected: w.range,
                  labelOf: (r) => r.label,
                  onChanged: w.setRange,
                  dense: true,
                  background: Colors.black.withValues(alpha: 0.22),
                ),
                const SizedBox(height: 20),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    CircleAction(
                      icon: Icons.south_west_rounded,
                      label: 'Deposit',
                      onTap: () => showDepositSheet(context),
                    ),
                    const SizedBox(width: 14),
                    CircleAction(
                      icon: Icons.north_east_rounded,
                      label: 'Withdraw',
                      onTap: () => showWithdrawSheet(context),
                    ),
                    const SizedBox(width: 14),
                    CircleAction(icon: Icons.bolt_rounded, label: 'Bills', onTap: () => showBillsSheet(context)),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: _AskKnockPill(onTap: () => app.shell.select(AppTab.knock)),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static String _rangeWords(ChartRange r) => switch (r) {
    ChartRange.day => 'day',
    ChartRange.week => 'week',
    ChartRange.month => 'month',
    ChartRange.year => 'year',
  };
}

class _AskKnockPill extends StatelessWidget {
  const _AskKnockPill({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Ask KNOCK',
      excludeSemantics: true,
      child: Material(
        color: Colors.white,
        shape: const StadiumBorder(),
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: onTap,
          child: const SizedBox(
            height: 50,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                KnockMark(size: 18),
                SizedBox(width: 8),
                Flexible(
                  child: Text(
                    'Ask KNOCK',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: Color(0xFF111114), fontWeight: FontWeight.w700, fontSize: 14),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _CurrencySelector extends StatelessWidget {
  const _CurrencySelector({required this.usd, required this.onChanged});
  final bool usd;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<bool>(
      tooltip: 'Display currency',
      color: KnockColors.surfaceRaised,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(KnockRadius.md)),
      onSelected: onChanged,
      itemBuilder: (_) => const [
        PopupMenuItem(value: false, child: Text('Naira (NGN)')),
        PopupMenuItem(value: true, child: Text('US dollar (USD)')),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(
                'Portfolio · ${usd ? 'USD' : 'NGN'}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: KnockText.caption.copyWith(color: Colors.white.withValues(alpha: 0.8)),
              ),
            ),
            Icon(Icons.keyboard_arrow_down_rounded, size: 18, color: Colors.white.withValues(alpha: 0.8)),
          ],
        ),
      ),
    );
  }
}

// ----------------------------------------------------------- trade grid

class _TradeGrid extends StatelessWidget {
  const _TradeGrid();

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final items = [
      _TradeItem(
        Icons.add_chart_rounded,
        'Buy Crypto',
        'BTC, ETH, USDT, SOL',
        KnockColors.green,
        () => app.shell.openAssistant(TxFlow.buyCrypto),
      ),
      _TradeItem(
        Icons.currency_exchange_rounded,
        'Sell Crypto',
        'Cash out to Naira',
        KnockColors.greenBright,
        () => app.shell.openAssistant(TxFlow.sellCrypto),
      ),
      _TradeItem(
        Icons.card_giftcard_rounded,
        'Buy Gift Cards',
        'Apple, Amazon, Steam',
        KnockColors.violetMuted,
        () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const BuyGiftCardScreen())),
      ),
      _TradeItem(
        Icons.redeem_rounded,
        'Sell Gift Cards',
        'Snap, verify, get paid',
        KnockColors.orange,
        () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const SellGiftCardScreen())),
      ),
    ];
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: KnockSpace.gutter),
      child: LayoutBuilder(
        builder: (context, c) {
          final w = (c.maxWidth - 12) / 2;
          return Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              for (final i in items)
                SizedBox(
                  width: w,
                  child: _TradeCard(item: i),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _TradeItem {
  const _TradeItem(this.icon, this.title, this.subtitle, this.tint, this.onTap);
  final IconData icon;
  final String title;
  final String subtitle;
  final Color tint;
  final VoidCallback onTap;
}

class _TradeCard extends StatelessWidget {
  const _TradeCard({required this.item});
  final _TradeItem item;

  @override
  Widget build(BuildContext context) {
    return KnockCard(
      onTap: item.onTap,
      semanticLabel: '${item.title}. ${item.subtitle}',
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: item.tint.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(13),
                ),
                child: Icon(item.icon, color: item.tint, size: 21),
              ),
              const Spacer(),
              const Icon(Icons.arrow_outward_rounded, size: 16, color: KnockColors.textTertiary),
            ],
          ),
          const SizedBox(height: 18),
          Text(item.title, style: KnockText.bodyStrong),
          const SizedBox(height: 3),
          Text(item.subtitle, style: KnockText.caption, maxLines: 1, overflow: TextOverflow.ellipsis),
        ],
      ),
    );
  }
}

// ------------------------------------------------------------ asset row

class AssetRow extends StatelessWidget {
  const AssetRow({super.key, required this.holding, required this.hidden, this.onTap});
  final Holding holding;
  final bool hidden;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final h = holding;
    final a = h.asset;
    return KnockCard(
      onTap: onTap,
      radius: KnockRadius.xl,
      padding: const EdgeInsets.fromLTRB(12, 12, 14, 12),
      semanticLabel:
          '${a.name}, ${a.ticker}. Price ${Fmt.money(h.priceNgn, Currency.ngn)}, ${Fmt.percent(h.change24h)} today. '
          '${hidden ? 'Holdings hidden' : 'You hold ${Fmt.quantity(h.quantity)} ${a.ticker}, worth ${h.valueNgn.format()}'}',
      child: ExcludeSemantics(
        child: Row(
          children: [
            GlyphAvatar(glyph: a.glyph, tint: a.tint),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(a.name, style: KnockText.bodyStrong),
                  const SizedBox(height: 3),
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          Fmt.money(h.priceNgn, Currency.ngn, showDecimals: h.priceNgn < 10000),
                          style: KnockText.caption,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 6),
                      ChangeText(h.change24h, style: KnockText.micro),
                    ],
                  ),
                ],
              ),
            ),
            Sparkline(values: h.sparkline, positive: h.change24h >= 0, width: 48),
            const SizedBox(width: 12),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Tag(a.ticker, color: KnockColors.textSecondary, fill: KnockColors.surfaceRaised),
                const SizedBox(height: 6),
                BalanceText(
                  Fmt.quantity(h.quantity),
                  hidden: hidden,
                  style: KnockText.caption.copyWith(color: KnockColors.textPrimary, fontWeight: FontWeight.w600),
                ),
                BalanceText(
                  h.valueNgn.format(showDecimals: false),
                  hidden: hidden,
                  style: KnockText.micro.copyWith(fontWeight: FontWeight.w400),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ------------------------------------------------------------ card teaser

class _CardTeaser extends StatelessWidget {
  const _CardTeaser();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(KnockSpace.gutter, KnockSpace.xl, KnockSpace.gutter, 0),
      child: KnockCard(
        gradient: KnockColors.dollarCardGradient,
        onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const DollarCardScreen())),
        semanticLabel: 'KNOCK Dollar Card, coming soon',
        padding: const EdgeInsets.all(18),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Tag('Coming soon', color: KnockColors.orange, icon: Icons.lock_rounded),
                  const SizedBox(height: 12),
                  const Text('KNOCK Dollar Card', style: KnockText.headline),
                  const SizedBox(height: 4),
                  Text(
                    'Spend online in dollars. Get notified when early access opens.',
                    style: KnockText.caption.copyWith(color: Colors.white70),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Container(
              width: 64,
              height: 42,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                gradient: const LinearGradient(colors: [Color(0x55FFFFFF), Color(0x11FFFFFF)]),
                border: Border.all(color: Colors.white24),
              ),
              child: const Icon(Icons.lock_outline_rounded, size: 18, color: Colors.white70),
            ),
          ],
        ),
      ),
    );
  }
}
