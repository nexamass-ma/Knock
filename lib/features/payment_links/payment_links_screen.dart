import 'package:material_ui/material_ui.dart';

import '../../design/tokens.dart';
import '../../design/widgets/states.dart';
import '../../design/widgets/surfaces.dart';
import 'create_link_flow.dart';
import 'link_detail_screen.dart';
import 'pl_models.dart';
import 'pl_notifications_screen.dart';
import 'pl_sandbox.dart';
import 'pl_split.dart';
import 'pl_widgets.dart';

/// Entry point for the rest of the app: `PaymentLinks.open(context)`.
abstract final class PaymentLinks {
  static Future<void> open(BuildContext context) =>
      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const PaymentLinksScreen()));
}

enum _Filter {
  all('All'),
  active('Active'),
  completed('Completed'),
  paused('Paused'),
  expired('Expired');

  const _Filter(this.label);
  final String label;
}

class PaymentLinksScreen extends StatefulWidget {
  const PaymentLinksScreen({super.key, this.sandbox});
  final PlSandbox? sandbox;

  @override
  State<PaymentLinksScreen> createState() => _PaymentLinksScreenState();
}

class _PaymentLinksScreenState extends State<PaymentLinksScreen> {
  _Filter _filter = _Filter.all;
  PlSandbox get sb => widget.sandbox ?? PlSandbox.instance;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: sb,
      builder: (context, _) {
        final all = sb.links.reversed.toList();
        final shown = all
            .where(
              (l) => switch (_filter) {
                _Filter.all => true,
                _Filter.active => l.status == LinkStatus.active,
                _Filter.completed => l.status == LinkStatus.completed,
                _Filter.paused => l.status == LinkStatus.paused || l.status == LinkStatus.underReview,
                _Filter.expired => l.status == LinkStatus.expired || l.status == LinkStatus.closed,
              },
            )
            .toList();
        final ngnLinks = all.where((l) => l.asset.isFiat);
        var expected = 0, collected = 0, distributed = 0, successes = 0;
        for (final l in ngnLinks) {
          final t = sb.totals(l.id);
          expected += l.target ?? 0;
          collected += t.collected;
          distributed += t.distributed;
          successes += t.succeeded;
        }
        final outstanding = ngnLinks.fold<int>(
          0,
          (a, l) => a + (l.target == null ? 0 : (l.target! - sb.totals(l.id).collected).clamp(0, 1 << 62)),
        );
        final unread = sb.notificationsFor(sb.me.id).length;

        return Scaffold(
          backgroundColor: KnockColors.background,
          appBar: AppBar(
            backgroundColor: KnockColors.background,
            title: const Text('Payment Links'),
            actions: [
              IconButton(
                tooltip: 'Notifications',
                onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => PlNotificationsScreen(sandbox: sb))),
                icon: Badge(
                  isLabelVisible: unread > 0,
                  label: Text('$unread'),
                  backgroundColor: KnockColors.orange,
                  child: const Icon(Icons.notifications_none_rounded),
                ),
              ),
            ],
          ),
          floatingActionButton: FloatingActionButton.extended(
            backgroundColor: KnockColors.green,
            foregroundColor: KnockColors.onGreen,
            onPressed: () => _create(context),
            icon: const Icon(Icons.add_link_rounded),
            label: const Text('Create link'),
          ),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(KnockSpace.gutter, 0, KnockSpace.gutter, 100),
            children: [
              const SandboxBanner(),
              const SizedBox(height: KnockSpace.md),
              KnockCard(
                gradient: KnockColors.cardGradient,
                padding: const EdgeInsets.all(KnockSpace.lg),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Collected (NGN links)', style: KnockText.caption.copyWith(color: Colors.white70)),
                    const SizedBox(height: 6),
                    Text(PlFmt.money(collected, PlAsset.ngn, decimals: false), style: KnockText.display.copyWith(fontSize: 34)),
                    const SizedBox(height: 12),
                    ProgressBar(expected == 0 ? 0 : collected / expected),
                    const SizedBox(height: 14),
                    Row(
                      children: [
                        _Stat('Expected', PlFmt.money(expected, PlAsset.ngn, decimals: false)),
                        _Stat('Split out', PlFmt.money(distributed, PlAsset.ngn, decimals: false)),
                        _Stat('Outstanding', PlFmt.money(outstanding, PlAsset.ngn, decimals: false)),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        _Stat('Links', '${all.length}'),
                        _Stat('Active', '${all.where((l) => l.status == LinkStatus.active).length}'),
                        _Stat('Payments', '$successes'),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: KnockSpace.md),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    for (final f in _Filter.values)
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: ChoiceChip(
                          label: Text(f.label),
                          selected: _filter == f,
                          onSelected: (_) => setState(() => _filter = f),
                          selectedColor: KnockColors.green,
                          labelStyle: KnockText.caption.copyWith(
                            color: _filter == f ? KnockColors.onGreen : KnockColors.textSecondary,
                            fontWeight: FontWeight.w600,
                          ),
                          backgroundColor: KnockColors.surface,
                          side: const BorderSide(color: KnockColors.stroke),
                          showCheckmark: false,
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: KnockSpace.sm),
              if (shown.isEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 40),
                  child: EmptyState(
                    icon: Icons.link_rounded,
                    title: 'No links here yet',
                    message: 'Create a payment link to collect money, or split it with your team automatically.',
                    action: 'Create link',
                    onAction: () => _create(context),
                  ),
                ),
              for (final l in shown) _LinkTile(link: l, sb: sb),
            ],
          ),
        );
      },
    );
  }

  Future<void> _create(BuildContext context) async {
    final created = await Navigator.of(context).push<PaymentLink>(MaterialPageRoute(builder: (_) => CreateLinkFlow(sandbox: sb)));
    if (created != null && context.mounted) {
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => LinkDetailScreen(sandbox: sb, linkId: created.id, justCreated: true),
        ),
      );
    }
  }
}

class _Stat extends StatelessWidget {
  const _Stat(this.label, this.value);
  final String label;
  final String value;
  @override
  Widget build(BuildContext context) => Expanded(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: KnockText.micro.copyWith(color: Colors.white60)),
        const SizedBox(height: 2),
        Text(value, style: KnockText.number.copyWith(fontSize: 14), overflow: TextOverflow.ellipsis),
      ],
    ),
  );
}

class _LinkTile extends StatelessWidget {
  const _LinkTile({required this.link, required this.sb});
  final PaymentLink link;
  final PlSandbox sb;

  @override
  Widget build(BuildContext context) {
    final t = sb.totals(link.id);
    final l = link;
    return Padding(
      padding: const EdgeInsets.only(bottom: KnockSpace.sm),
      child: KnockCard(
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => LinkDetailScreen(sandbox: sb, linkId: l.id),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: const BoxDecoration(shape: BoxShape.circle, color: KnockColors.surfaceHigh),
                  child: Icon(
                    linkTypeIcon(l.type),
                    size: 20,
                    color: l.type == LinkType.split ? KnockColors.orange : KnockColors.greenBright,
                  ),
                ),
                const SizedBox(width: KnockSpace.sm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(l.title, style: KnockText.bodyStrong, overflow: TextOverflow.ellipsis),
                      Text('${l.reference} · ${l.type.label} · ${l.asset.code}', style: KnockText.micro),
                    ],
                  ),
                ),
                StatusTag(l.status.label, linkStatusColor(l.status)),
              ],
            ),
            const SizedBox(height: KnockSpace.sm),
            if (l.target != null) ...[ProgressBar(t.collected / l.target!, height: 6), const SizedBox(height: 8)],
            Row(
              children: [
                Expanded(
                  child: Text(
                    l.target != null
                        ? '${PlFmt.money(t.collected, l.asset, decimals: false)} of ${PlFmt.money(l.target!, l.asset, decimals: false)}'
                        : '${PlFmt.money(t.collected, l.asset, decimals: false)} collected',
                    style: KnockText.number.copyWith(fontSize: 13),
                  ),
                ),
                Text(
                  '${l.currentRules.length} recipient${l.currentRules.length == 1 ? '' : 's'} · ${t.succeeded} paid',
                  style: KnockText.micro,
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'Created ${PlFmt.date(l.createdAt)}${l.expiresAt != null ? ' · Expires ${PlFmt.date(l.expiresAt!)}' : ''}',
              style: KnockText.micro.copyWith(color: KnockColors.textTertiary),
            ),
          ],
        ),
      ),
    );
  }
}
