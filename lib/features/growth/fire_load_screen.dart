import 'package:material_ui/material_ui.dart';

import '../../api/api.dart';
import '../../app/app_controller.dart';
import '../../core/format.dart';
import '../../design/tokens.dart';
import '../../design/widgets/kit.dart';
import '../shell/nav.dart';

class FireLoadScreen extends StatelessWidget {
  const FireLoadScreen({super.key});

  Future<void> _claim(BuildContext context, String id) async {
    try {
      await context.api.call((s, t) => s.claimCampaign(t!, id));
      if (!context.mounted) return;
      context.app.poke();
      toast(context, 'Reward added to your bonus balance');
    } catch (e) {
      if (context.mounted) showApiError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ApiView(
      load: (api) => api.call((s, t) => s.fireLoad(t!)),
      builder: (context, d, reload) {
        final items = (d['items'] as List).cast<Json>();
        final live = items.where((c) => c['state'] == 'live').toList();
        final upcoming = items.where((c) => c['state'] == 'upcoming').toList();
        final ended = items.where((c) => c['state'] == 'ended').toList();
        return KPage(title: 'Fire Load 🔥', subtitle: 'Limited-time boosts. Every timer here is real.', onRefresh: reload, children: [
          if (items.isEmpty) const EmptyState(icon: Icons.local_fire_department_outlined, title: 'Nothing live right now', message: 'We will notify you when the next Fire Load starts.'),
          if (live.isNotEmpty) ...[const SectionTitle('Live now', top: 8), for (final c in live) _CampaignCard(c: c, onClaim: () => _claim(context, c['id'] as String), onExpired: reload)],
          if (upcoming.isNotEmpty) ...[const SectionTitle('Coming up'), for (final c in upcoming) _CampaignCard(c: c, onClaim: null, onExpired: reload)],
          if (ended.isNotEmpty) ...[const SectionTitle('History'), for (final c in ended) _CampaignCard(c: c, onClaim: null, onExpired: null)],
        ]);
      },
    );
  }
}

class _CampaignCard extends StatelessWidget {
  const _CampaignCard({required this.c, required this.onClaim, required this.onExpired});
  final Json c;
  final VoidCallback? onClaim;
  final VoidCallback? onExpired;

  @override
  Widget build(BuildContext context) {
    final state = c['state'] as String;
    final prog = c['progress'] as Map;
    final hasTarget = c['kind'] == 'volume_bonus' && prog['target'] != null;
    final value = (prog['value'] as int?) ?? 0;
    final target = (prog['target'] as int?) ?? 1;
    final claimed = prog['claimed'] == true;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: KnockCard(
        key: ValueKey('camp-${c['id']}'),
        gradient: state == 'live' ? LinearGradient(colors: [KnockColors.orange.withValues(alpha: 0.22), KnockColors.surface], begin: Alignment.topLeft, end: Alignment.bottomRight) : null,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(Icons.local_fire_department_rounded, color: state == 'ended' ? KnockColors.textTertiary : KnockColors.orange),
            const SizedBox(width: 8),
            Expanded(child: Text(c['title'] as String, style: KnockText.headline)),
            if (state != 'ended')
              Countdown(
                seconds: state == 'live' ? c['secondsLeft'] as int : c['secondsToStart'] as int,
                onDone: onExpired,
                builder: (left) => Text('${state == 'live' ? 'Ends in' : 'Starts in'} ${F.countdown(left)}', style: KnockText.caption.copyWith(color: KnockColors.orange)),
              )
            else
              Text('Ended', style: KnockText.caption),
          ]),
          const SizedBox(height: 6),
          Text(c['subtitle'] as String? ?? '', style: KnockText.body),
          if ((c['eligibility'] as List?)?.isNotEmpty == true) ...[
            const SizedBox(height: 8),
            for (final e in (c['eligibility'] as List).cast<String>()) Text('• $e', style: KnockText.caption),
          ],
          if (hasTarget) ...[
            const SizedBox(height: 12),
            KProgress((value / target).clamp(0, 1).toDouble()),
            const SizedBox(height: 6),
            Text('${F.usdCents(value)} of ${F.usdCents(target)} · reward ${F.ngn(c['rewardKobo'] as int)}', style: KnockText.caption),
          ],
          const SizedBox(height: 12),
          if (state == 'live' && hasTarget)
            claimed
                ? const StatusChip('successful', label: 'Reward claimed')
                : KnockButton(key: ValueKey('camp-claim-${c['id']}'), label: value >= target ? 'Claim reward' : 'Trade to qualify', onPressed: value >= target ? onClaim : () => Nav.sellGiftCard(context))
          else if (state == 'live')
            KnockButton(label: 'Trade now', onPressed: () => Nav.sellGiftCard(context)),
          if (c['rule'] != null) ...[const SizedBox(height: 8), Text(c['rule'] as String, style: KnockText.micro)],
        ]),
      ),
    );
  }
}
