import 'package:material_ui/material_ui.dart';

import '../../app/app_controller.dart';
import '../../design/tokens.dart';
import '../../design/widgets/brand.dart';
import '../../design/widgets/kit.dart';
import '../payment_links/payment_links_screen.dart';
import 'nav.dart';
import 'shell.dart';

class DrawerEntry {
  const DrawerEntry(this.label, this.icon, this.open, {this.soon = false, this.danger = false});
  final String label;
  final IconData icon;
  final void Function(BuildContext) open;
  final bool soon;
  final bool danger;
}

class DrawerGroup {
  const DrawerGroup(this.label, this.icon, this.entries);
  final String label;
  final IconData icon;
  final List<DrawerEntry> entries;
}

/// The slide-out menu. Related items sit together in collapsible groups so
/// the menu stays short; single destinations show on their own.
List<Object> drawerItems() => [
  DrawerEntry('Dashboard', Icons.space_dashboard_outlined, (c) => Nav.tab(c, ShellTab.home)),
  DrawerGroup('Trade', Icons.swap_horiz_rounded, [
    DrawerEntry('Trade', Icons.swap_horiz_rounded, (c) => Nav.tab(c, ShellTab.trade)),
    DrawerEntry('Gift Cards', Icons.card_giftcard_rounded, (c) => Nav.sellGiftCard(c)),
    DrawerEntry('Crypto', Icons.currency_bitcoin_rounded, (c) => Nav.crypto(c)),
  ]),
  DrawerGroup('Pay bills', Icons.receipt_rounded, [
    DrawerEntry('Bills', Icons.receipt_rounded, (c) => Nav.billsHub(c)),
    DrawerEntry('Betting', Icons.sports_soccer_rounded, (c) => Nav.betting(c)),
    DrawerEntry('E-pins', Icons.pin_outlined, (c) => Nav.epins(c)),
    DrawerEntry('eSIM & Data', Icons.sim_card_outlined, (c) => Nav.esim(c)),
  ]),
  DrawerGroup('Money', Icons.account_balance_wallet_outlined, [
    DrawerEntry('Payment Links', Icons.link_rounded, (c) => PaymentLinks.open(c)),
    DrawerEntry('Transaction History', Icons.receipt_long_outlined, (c) => Nav.tab(c, ShellTab.history)),
    DrawerEntry('Get a USA Account', Icons.flag_outlined, (c) => Nav.usaAccount(c), soon: true),
  ]),
  DrawerGroup('Rewards', Icons.workspace_premium_outlined, [
    DrawerEntry('Referrals', Icons.group_add_outlined, (c) => Nav.referrals(c)),
    DrawerEntry('Rewards', Icons.workspace_premium_outlined, (c) => Nav.rewards(c)),
    DrawerEntry('Knockout', Icons.emoji_events_outlined, (c) => Nav.knockout(c)),
    DrawerEntry('Fire Load', Icons.local_fire_department_outlined, (c) => Nav.fireLoad(c)),
    DrawerEntry('Workings', Icons.lightbulb_outline_rounded, (c) => Nav.workings(c)),
  ]),
  DrawerGroup('Help', Icons.support_agent_rounded, [
    DrawerEntry('Contact Support', Icons.support_agent_rounded, (c) => Nav.support(c)),
    DrawerEntry('FAQs', Icons.help_outline_rounded, (c) => Nav.faq(c)),
  ]),
  DrawerEntry('Settings', Icons.settings_outlined, (c) => Nav.settings(c)),
  DrawerEntry('Logout', Icons.logout_rounded, _logout, danger: true),
];

/// Every destination in the menu, flattened (used by search and tests).
List<DrawerEntry> drawerEntries() => [
  for (final i in drawerItems())
    if (i is DrawerGroup) ...i.entries else i as DrawerEntry,
];

Future<void> _logout(BuildContext c) async {
  if (await confirm(c, title: 'Log out of Knock?', message: 'You will need your email and password to log back in.', yes: 'Log out', danger: true)) {
    if (c.mounted) await c.app.logout();
  }
}

class AppDrawer extends StatelessWidget {
  const AppDrawer({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.appWatch;
    final me = app.me ?? const {};
    final items = drawerItems();
    return Drawer(
      backgroundColor: KnockColors.surface,
      child: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 12, 8),
              child: Row(children: [
                const KnockWordmark(size: 18),
                const Spacer(),
                IconButton(tooltip: 'Close menu', icon: const Icon(Icons.close_rounded), onPressed: () => Navigator.pop(context)),
              ]),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: KnockCard(
                color: KnockColors.surfaceRaised,
                onTap: () {
                  Navigator.pop(context);
                  Nav.settings(context);
                },
                child: Row(children: [
                  Avatar(name: me['fullName'] as String? ?? '', highlight: true),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(me['fullName'] as String? ?? '', style: KnockText.bodyStrong, overflow: TextOverflow.ellipsis),
                      Text('@${me['username']} · Tier ${me['tier']} · ${(me['vip'] as String? ?? 'silver')[0].toUpperCase()}${(me['vip'] as String? ?? 'silver').substring(1)}', style: KnockText.caption),
                    ]),
                  ),
                ]),
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                children: [
                  for (final item in items)
                    if (item is DrawerGroup)
                      Theme(
                        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
                        child: ExpansionTile(
                          key: PageStorageKey('drawer-group-${item.label}'),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(KnockRadius.md)),
                          collapsedShape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(KnockRadius.md)),
                          leading: Icon(item.icon, color: KnockColors.textSecondary, size: 22),
                          title: Text(item.label, style: KnockText.bodyStrong),
                          iconColor: KnockColors.green,
                          collapsedIconColor: KnockColors.textSecondary,
                          childrenPadding: const EdgeInsets.only(left: 20),
                          children: [for (final e in item.entries) _tile(context, e)],
                        ),
                      )
                    else
                      _tile(context, item as DrawerEntry),
                ],
              ),
            ),
            const Padding(padding: EdgeInsets.all(12), child: SandboxPill(label: 'SANDBOX · NOT LIVE')),
          ],
        ),
      ),
    );
  }

  Widget _tile(BuildContext context, DrawerEntry e) => ListTile(
        key: ValueKey('drawer-${e.label}'),
        dense: true,
        visualDensity: VisualDensity.compact,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(KnockRadius.md)),
        leading: Icon(e.icon, color: e.danger ? KnockColors.loss : KnockColors.textSecondary, size: 22),
        title: Text(e.label, style: KnockText.body.copyWith(color: e.danger ? KnockColors.loss : null)),
        trailing: e.soon ? const Tag('Coming soon', color: KnockColors.orange) : null,
        onTap: () {
          final shell = ShellScope.of(context);
          Navigator.pop(context);
          final ctx = shell?.context ?? context;
          e.open(ctx);
        },
      );
}
