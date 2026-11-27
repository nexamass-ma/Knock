import 'package:material_ui/material_ui.dart';

import '../../api/api.dart';
import '../../app/app_controller.dart';
import '../../core/format.dart';
import '../../design/tokens.dart';
import '../../design/widgets/kit.dart';
import '../settings/settings_screen.dart';
import '../shell/nav.dart';

class NotificationsScreen extends StatefulWidget {
  const NotificationsScreen({super.key});
  @override
  State<NotificationsScreen> createState() => _NotificationsScreenState();
}

class _NotificationsScreenState extends State<NotificationsScreen> {
  String? _kind;

  static const _kinds = [(null, 'All'), ('transaction', 'Transactions'), ('gift', 'Gifts'), ('security', 'Security'), ('reward', 'Rewards'), ('referral', 'Referrals'), ('campaign', 'Promotions'), ('rate_alert', 'Rate alerts')];

  Future<void> _tap(Json n) async {
    final api = context.api;
    if (n['read'] != true) {
      try {
        await api.call((s, t) => s.markRead(t!, n['id'] as String));
        if (mounted) context.app.poke();
      } catch (_) {}
    }
    if (mounted) await Nav.action(context, n['action'] as Map?);
  }

  Future<void> _all() async {
    try {
      await context.api.call((s, t) => s.markAllRead(t!));
      if (mounted) {
        context.app.poke();
        toast(context, 'All caught up');
      }
    } catch (e) {
      if (mounted) showApiError(context, e);
    }
  }

  IconData _icon(String k) => switch (k) {
        'transaction' => Icons.receipt_long_rounded,
        'gift' => Icons.redeem_rounded,
        'security' => Icons.shield_rounded,
        'reward' => Icons.military_tech_rounded,
        'referral' => Icons.group_rounded,
        'campaign' => Icons.local_fire_department_rounded,
        'rate_alert' => Icons.trending_up_rounded,
        'verification' => Icons.verified_user_rounded,
        _ => Icons.notifications_rounded,
      };

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Notifications'), actions: [
        TextButton(key: const ValueKey('notif-mark-all'), onPressed: _all, child: const Text('Mark all read')),
        IconButton(tooltip: 'Notification settings', icon: const Icon(Icons.tune_rounded), onPressed: () => go(context, const NotificationPrefsScreen())),
      ]),
      body: Column(children: [
        SizedBox(
          height: 44,
          child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: KnockSpace.gutter), children: [
            for (final (k, l) in _kinds)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: ChoiceChip(label: Text(l), selected: _kind == k, showCheckmark: false, selectedColor: KnockColors.greenSoft, onSelected: (_) => setState(() => _kind = k)),
              ),
          ]),
        ),
        Expanded(
          child: ApiView(
            key: ValueKey(_kind),
            load: (api) => api.call((s, t) => s.notifications(t!, kind: _kind)),
            builder: (context, d, reload) {
              final items = (d['items'] as List).cast<Json>();
              if (items.isEmpty) return const EmptyState(icon: Icons.notifications_none_rounded, title: 'No notifications', message: 'Updates about your trades, gifts and account will appear here.');
              return RefreshIndicator(
                onRefresh: reload,
                child: ListView.separated(
                  padding: const EdgeInsets.fromLTRB(KnockSpace.gutter, 8, KnockSpace.gutter, 32),
                  itemCount: items.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (context, i) {
                    final n = items[i];
                    final unread = n['read'] != true;
                    final cta = (n['action'] as Map?)?['cta'] as String?;
                    return KnockCard(
                      key: ValueKey('notif-${n['id']}'),
                      color: unread ? KnockColors.surfaceRaised : KnockColors.surface,
                      onTap: () => _tap(n),
                      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Container(
                          width: 40,
                          height: 40,
                          decoration: BoxDecoration(color: n['kind'] == 'gift' ? KnockColors.orangeSoft : KnockColors.greenSoft, borderRadius: BorderRadius.circular(12)),
                          child: Icon(_icon(n['kind'] as String), color: n['kind'] == 'gift' ? KnockColors.orange : KnockColors.greenBright, size: 20),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Row(children: [
                              Expanded(child: Text(n['title'] as String, style: unread ? KnockText.bodyStrong : KnockText.body)),
                              if (unread) Container(width: 8, height: 8, decoration: const BoxDecoration(color: KnockColors.orange, shape: BoxShape.circle)),
                            ]),
                            const SizedBox(height: 2),
                            Text(n['body'] as String, style: KnockText.caption),
                            const SizedBox(height: 4),
                            Text(F.ago(n['createdAt'] as String), style: KnockText.micro),
                            if (cta != null) ...[
                              const SizedBox(height: 10),
                              KnockButton(key: ValueKey('notif-cta-${n['id']}'), label: cta, icon: Icons.redeem_rounded, expand: false, onPressed: () => _tap(n)),
                            ],
                          ]),
                        ),
                      ]),
                    );
                  },
                ),
              );
            },
          ),
        ),
      ]),
    );
  }
}
