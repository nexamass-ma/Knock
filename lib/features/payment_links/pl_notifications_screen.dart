import 'package:material_ui/material_ui.dart';

import '../../design/tokens.dart';
import '../../design/widgets/states.dart';
import '../../design/widgets/surfaces.dart';
import 'pl_models.dart';
import 'pl_sandbox.dart';
import 'pl_split.dart';
import 'pl_widgets.dart';

/// Payment Links notifications, viewable as any sandbox user so you can see
/// what recipients get. Live delivery (push, SMS, email) needs provider keys.
class PlNotificationsScreen extends StatefulWidget {
  const PlNotificationsScreen({super.key, required this.sandbox});
  final PlSandbox sandbox;

  @override
  State<PlNotificationsScreen> createState() => _PlNotificationsScreenState();
}

class _PlNotificationsScreenState extends State<PlNotificationsScreen> {
  late KnockUser viewer = widget.sandbox.me;

  IconData _icon(String kind) => switch (kind) {
    'payment_received' => Icons.south_west_rounded,
    'split_credited' => Icons.call_split_rounded,
    'payment_failed' => Icons.error_outline_rounded,
    'target_reached' => Icons.flag_rounded,
    'allocation_pending' => Icons.hourglass_top_rounded,
    'link_expiring' || 'link_expired' => Icons.schedule_rounded,
    'payment_reversed' || 'payment_disputed' => Icons.gavel_rounded,
    _ => Icons.notifications_none_rounded,
  };

  @override
  Widget build(BuildContext context) {
    final sb = widget.sandbox;
    return ListenableBuilder(
      listenable: sb,
      builder: (context, _) {
        final items = sb.notificationsFor(viewer.id);
        final w = sb.walletOf(viewer.id, 'NGN');
        return Scaffold(
          backgroundColor: KnockColors.background,
          appBar: AppBar(backgroundColor: KnockColors.background, title: const Text('Notifications')),
          body: ListView(
            padding: const EdgeInsets.all(KnockSpace.gutter),
            children: [
              DropdownButtonFormField<String>(
                initialValue: viewer.id,
                dropdownColor: KnockColors.surfaceRaised,
                decoration: plInput('Viewing as (sandbox)'),
                items: [for (final u in sb.allUsers) DropdownMenuItem(value: u.id, child: Text('@${u.username} · ${u.displayName}'))],
                onChanged: (id) => setState(() => viewer = sb.user(id!)),
              ),
              const SizedBox(height: KnockSpace.sm),
              KnockCard(
                child: Column(
                  children: [
                    KvRow('NGN available', PlFmt.money(w.available, PlAsset.ngn), valueColor: KnockColors.greenBright),
                    KvRow('NGN pending settlement', PlFmt.money(w.pending, PlAsset.ngn), valueColor: KnockColors.orange),
                    if (w.held > 0) KvRow('NGN on hold', PlFmt.money(w.held, PlAsset.ngn), valueColor: KnockColors.loss),
                  ],
                ),
              ),
              const SizedBox(height: KnockSpace.md),
              if (items.isEmpty)
                const EmptyState(
                  icon: Icons.notifications_none_rounded,
                  title: 'Nothing yet',
                  message: 'Payments, splits and link updates show here.',
                ),
              for (final n in items)
                Padding(
                  padding: const EdgeInsets.only(bottom: KnockSpace.xs),
                  child: KnockCard(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(_icon(n.kind), color: KnockColors.greenBright, size: 20),
                        const SizedBox(width: KnockSpace.sm),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(n.title, style: KnockText.bodyStrong),
                              const SizedBox(height: 2),
                              Text(n.body, style: KnockText.caption),
                              const SizedBox(height: 4),
                              Text(PlFmt.dateTime(n.at), style: KnockText.micro.copyWith(color: KnockColors.textTertiary)),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}
