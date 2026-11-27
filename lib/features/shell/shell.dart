import 'dart:ui';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/app_scope.dart';
import '../../design/tokens.dart';
import '../../state/shell_controller.dart';
import '../activity/activity_screen.dart';
import '../assistant/assistant_screen.dart';
import '../auth/wordmark.dart';
import '../home/home_screen.dart';
import '../profile/profile_screen.dart';
import '../wallet/wallet_screen.dart';

/// Space the floating nav bar takes at the bottom of each tab.
const double kNavClearance = 104;

class Shell extends StatefulWidget {
  const Shell({super.key});

  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => context.app.wallet.load());
  }

  @override
  Widget build(BuildContext context) {
    final shell = context.app.shell;
    return ListenableBuilder(
      listenable: shell,
      builder: (context, _) {
        final keyboard = MediaQuery.viewInsetsOf(context).bottom > 0;
        final onKnock = shell.tab == AppTab.knock;
        return Scaffold(
          extendBody: true,
          resizeToAvoidBottomInset: false,
          body: IndexedStack(
            index: shell.tab.index,
            children: const [HomeScreen(), ActivityScreen(), AssistantScreen(), WalletScreen(), ProfileScreen()],
          ),
          bottomNavigationBar: AnimatedSlide(
            duration: KnockMotion.base,
            offset: keyboard || onKnock ? const Offset(0, 1.6) : Offset.zero,
            child: _FloatingNav(selected: shell.tab, onSelect: shell.select),
          ),
        );
      },
    );
  }
}

class _FloatingNav extends StatelessWidget {
  const _FloatingNav({required this.selected, required this.onSelect});
  final AppTab selected;
  final ValueChanged<AppTab> onSelect;

  static const _items = [
    (AppTab.home, Icons.home_rounded, 'Home'),
    (AppTab.activity, Icons.swap_vert_rounded, 'Activity'),
    (AppTab.knock, null, 'Knock assistant'),
    (AppTab.wallet, Icons.account_balance_wallet_outlined, 'Wallet'),
    (AppTab.profile, Icons.person_outline_rounded, 'Profile'),
  ];

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      minimum: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(KnockRadius.pill),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
            child: Container(
              height: 68,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              decoration: BoxDecoration(
                color: const Color(0xCC17171D),
                borderRadius: BorderRadius.circular(KnockRadius.pill),
                border: Border.all(color: KnockColors.stroke),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  for (final (tab, icon, label) in _items)
                    _NavItem(
                      selected: tab == selected,
                      icon: icon,
                      label: label,
                      isKnock: tab == AppTab.knock,
                      onTap: () {
                        HapticFeedback.selectionClick();
                        onSelect(tab);
                      },
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.selected,
    required this.icon,
    required this.label,
    required this.isKnock,
    required this.onTap,
  });
  final bool selected;
  final IconData? icon;
  final String label;
  final bool isKnock;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final Widget glyph = isKnock
        ? KnockMark(size: 28, tone: selected ? KnockMarkTone.white : KnockMarkTone.brand)
        : Icon(icon, size: 23, color: selected ? KnockColors.onGreen : KnockColors.textSecondary);
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      excludeSemantics: true,
      child: Tooltip(
        message: label,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: AnimatedContainer(
            duration: KnockMotion.base,
            curve: KnockMotion.curve,
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: selected
                  ? KnockColors.green
                  : isKnock
                  ? KnockColors.greenSoft
                  : Colors.transparent,
            ),
            child: Center(child: glyph),
          ),
        ),
      ),
    );
  }
}
