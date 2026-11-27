import 'package:material_ui/material_ui.dart';

import '../../api/api.dart';
import '../../app/app_controller.dart';
import '../../design/tokens.dart';
import '../../design/widgets/kit.dart';

class KnockoutScreen extends StatelessWidget {
  const KnockoutScreen({super.key});

  Future<void> _claim(BuildContext context, String id) async {
    try {
      final r = await context.api.call((s, t) => s.claimChallenge(t!, id));
      if (!context.mounted) return;
      context.app.poke();
      toast(context, 'Claimed. You now have ${r['points']} points.');
    } catch (e) {
      if (context.mounted) showApiError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ApiView(
      load: (api) => api.call((s, t) => s.knockout(t!)),
      builder: (context, d, reload) {
        final ch = (d['challenges'] as List).cast<Json>();
        final badges = (d['badges'] as List).cast<Json>();
        final groups = <String, List<Json>>{};
        for (final c in ch) {
          groups.putIfAbsent(c['group'] as String? ?? 'Challenges', () => []).add(c);
        }
        return KPage(title: 'Knockout', onRefresh: reload, children: [
          KnockCard(
            gradient: KnockColors.heroGradient,
            child: Row(children: [
              const Icon(Icons.military_tech_rounded, size: 40, color: KnockColors.orange),
              const SizedBox(width: 14),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${d['points']} Knock Points', key: const ValueKey('ko-points'), style: KnockText.title),
                Text('${badges.where((b) => b['earned'] == true).length} of ${badges.length} badges earned', style: KnockText.caption.copyWith(color: Colors.white70)),
              ])),
            ]),
          ),
          for (final e in groups.entries) ...[
            SectionTitle(e.key),
            for (final c in e.value) _ChallengeCard(c: c, onClaim: () => _claim(context, c['id'] as String)),
          ],
          const SectionTitle('Badges'),
          Wrap(spacing: 10, runSpacing: 10, children: [
            for (final b in badges)
              Tooltip(
                message: b['desc'] as String,
                child: Container(
                  width: 100,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(color: b['earned'] == true ? KnockColors.greenSoft : KnockColors.surface, borderRadius: BorderRadius.circular(KnockRadius.md), border: Border.all(color: b['earned'] == true ? KnockColors.green : KnockColors.stroke)),
                  child: Column(children: [
                    Icon(Icons.verified_rounded, color: b['earned'] == true ? KnockColors.greenBright : KnockColors.textTertiary),
                    const SizedBox(height: 6),
                    Text(b['name'] as String, textAlign: TextAlign.center, style: KnockText.micro.copyWith(color: KnockColors.textPrimary)),
                  ]),
                ),
              ),
          ]),
          const SizedBox(height: 14),
          Note(d['note'] as String),
        ]);
      },
    );
  }
}

class _ChallengeCard extends StatelessWidget {
  const _ChallengeCard({required this.c, required this.onClaim});
  final Json c;
  final VoidCallback onClaim;
  @override
  Widget build(BuildContext context) {
    final state = c['state'] as String;
    final p = (c['progress'] as num).toDouble();
    final target = (c['target'] as num).toDouble();
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: KnockCard(
        key: ValueKey('ch-${c['id']}'),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text(c['title'] as String, style: KnockText.bodyStrong)),
            Text('+${c['points']} pts', style: KnockText.caption.copyWith(color: KnockColors.greenBright)),
          ]),
          const SizedBox(height: 4),
          Text(c['desc'] as String, style: KnockText.caption),
          const SizedBox(height: 10),
          KProgress(target == 0 ? 0 : (p / target).clamp(0, 1)),
          const SizedBox(height: 8),
          Row(children: [
            Text('${p.toInt()} / ${target.toInt()}', style: KnockText.micro),
            const Spacer(),
            switch (state) {
              'completed' => KnockButton(key: ValueKey('claim-${c['id']}'), label: 'Claim', expand: false, onPressed: onClaim),
              'claimed' => const StatusChip('successful', label: 'Claimed'),
              'upcoming' => const StatusChip('pending', label: 'Starts soon'),
              'ended' => const StatusChip('failed', label: 'Ended'),
              _ => const StatusChip('pending', label: 'In progress'),
            },
          ]),
        ]),
      ),
    );
  }
}
