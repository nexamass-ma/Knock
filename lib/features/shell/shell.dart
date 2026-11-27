import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/app_controller.dart';
import '../../design/tokens.dart';
import '../../design/widgets/kit.dart';
import '../gifts/my_gifts_screen.dart';
import '../history/history_screen.dart';
import '../home/home_screen.dart';
import '../onboarding/guide.dart';
import '../settings/verification_screen.dart';
import '../trade/trade_hub_screen.dart';
import 'app_drawer.dart';

/// Bottom tabs. There is one account: the balance lives on Home (Chanor,
/// 2026-11-27), so there is no separate Wallet tab.
enum ShellTab { home, trade, gifts, history }

class ShellScope extends InheritedWidget {
  const ShellScope({super.key, required this.state, required super.child});
  final ShellState state;
  static ShellState? of(BuildContext context) => context.getInheritedWidgetOfExactType<ShellScope>()?.state;
  @override
  bool updateShouldNotify(ShellScope old) => false;
}

/// Signed-in app frame: bottom navigation, slide-out drawer, first-run guide.
class Shell extends StatefulWidget {
  const Shell({super.key});
  @override
  State<Shell> createState() => ShellState();
}

class ShellState extends State<Shell> {
  final scaffoldKey = GlobalKey<ScaffoldState>();
  ShellTab _tab = ShellTab.home;
  final _visited = <ShellTab>{ShellTab.home};

  // Tour targets.
  final tradeKey = GlobalKey(debugLabel: 'tour-trade');
  final ratesKey = GlobalKey(debugLabel: 'tour-rates');
  final walletKey = GlobalKey(debugLabel: 'tour-wallet');
  final historyKey = GlobalKey(debugLabel: 'tour-history');

  ShellTab get tab => _tab;

  void goTab(ShellTab t) {
    HapticFeedback.selectionClick();
    setState(() {
      _tab = t;
      _visited.add(t);
    });
  }

  void openDrawer() => scaffoldKey.currentState?.openDrawer();

  @override
  void initState() {
    super.initState();
    openVerificationHook = (c) => go(c, const VerificationScreen());
    WidgetsBinding.instance.addPostFrameCallback((_) => _firstRun());
  }

  Future<void> _firstRun() async {
    final me = context.app.me;
    if (me == null || me['guideEnabled'] != true || me['guideSeen'] == true) return;
    await go(context, GuideScreen(onDone: () => Navigator.of(context).pop()));
    if (!mounted) return;
    await Future<void>.delayed(const Duration(milliseconds: 350));
    if (mounted) await startTour();
  }

  Future<void> startTour() {
    goTab(ShellTab.home);
    return showTour(context, [
      TourStep(tradeKey, 'Trade', 'Sell gift cards and crypto, see your payout up front and track every trade.'),
      TourStep(ratesKey, 'Current Rates', 'Check today\'s rates for every card, currency and denomination before you trade.'),
      TourStep(walletKey, 'Your balance', 'One account for everything: your balance, deposits and withdrawals live here.'),
      TourStep(historyKey, 'History', 'Every transaction with its status, fees, reference and a receipt you can share.'),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    const tabs = ShellTab.values;
    return ShellScope(
      state: this,
      child: PopScope(
        canPop: _tab == ShellTab.home,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) goTab(ShellTab.home);
        },
        child: Scaffold(
          key: scaffoldKey,
          drawer: const AppDrawer(),
          body: IndexedStack(
            index: _tab.index,
            children: [
              for (final t in tabs)
                _visited.contains(t)
                    ? switch (t) {
                        ShellTab.home => const HomeScreen(),
                        ShellTab.trade => const TradeHubScreen(),
                        ShellTab.gifts => const MyGiftsScreen(),
                        ShellTab.history => const HistoryScreen(),
                      }
                    : const SizedBox.shrink(),
            ],
          ),
          bottomNavigationBar: NavigationBar(
            backgroundColor: KnockColors.surface,
            indicatorColor: KnockColors.greenSoft,
            selectedIndex: _tab.index,
            onDestinationSelected: (i) => goTab(tabs[i]),
            labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
            destinations: [
              const NavigationDestination(icon: Icon(Icons.home_outlined), selectedIcon: Icon(Icons.home_rounded, color: KnockColors.greenBright), label: 'Home'),
              NavigationDestination(key: tradeKey, icon: const Icon(Icons.swap_horiz_rounded), selectedIcon: const Icon(Icons.swap_horiz_rounded, color: KnockColors.greenBright), label: 'Trade'),
              const NavigationDestination(icon: Icon(Icons.redeem_outlined), selectedIcon: Icon(Icons.redeem_rounded, color: KnockColors.greenBright), label: 'Gifts'),
              NavigationDestination(key: historyKey, icon: const Icon(Icons.receipt_long_outlined), selectedIcon: const Icon(Icons.receipt_long_rounded, color: KnockColors.greenBright), label: 'History'),
            ],
          ),
        ),
      ),
    );
  }
}

/// Leading menu button for tab screens.
class MenuButton extends StatelessWidget {
  const MenuButton({super.key});
  @override
  Widget build(BuildContext context) => IconButton(
    key: const ValueKey('open-drawer'),
    tooltip: 'Menu',
    icon: const Icon(Icons.menu_rounded),
    onPressed: () => ShellScope.of(context)?.openDrawer(),
  );
}

/// Bell with an unread dot that appears only when there are unread notifications.
class BellButton extends StatelessWidget {
  const BellButton({super.key, required this.onTap});
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final unread = context.appWatch.unread;
    return GlassIconButton(
      key: const ValueKey('bell'),
      icon: Icons.notifications_none_rounded,
      label: unread > 0 ? 'Notifications, $unread unread' : 'Notifications',
      badge: unread > 0,
      onTap: onTap,
    );
  }
}
