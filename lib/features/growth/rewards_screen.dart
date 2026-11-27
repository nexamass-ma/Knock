import 'package:material_ui/material_ui.dart';

import '../../api/api.dart';
import '../../core/format.dart';
import '../../design/tokens.dart';
import '../../design/widgets/kit.dart';
import '../shell/nav.dart';

class RewardsScreen extends StatelessWidget {
  const RewardsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return ApiView(
      load: (api) async {
        final r = await api.call((s, t) => s.rewards(t!));
        final w = await api.call((s, t) => s.welcomeBonus(t!));
        final v = await api.call((s, t) => s.vip(t!));
        return {'r': r, 'w': w, 'v': v};
      },
      builder: (context, d, reload) {
        final r = d['r'] as Json;
        final w = d['w'] as Json;
        final v = d['v'] as Json;
        final history = (r['history'] as List).cast<Json>();
        return KPage(title: 'Rewards', onRefresh: reload, children: [
          Row(children: [
            Expanded(child: _Tile(label: 'Bonus balance', value: F.ngnExact(r['bonusBalance'] as int), note: 'Not withdrawable')),
            const SizedBox(width: 10),
            Expanded(child: _Tile(label: 'Knock Points', value: '${r['points']}', note: 'No cash value')),
          ]),
          const SizedBox(height: 10),
          _Tile(label: 'Earned from referrals', value: F.ngnExact(r['referralEarned'] as int), note: 'Paid to your Naira wallet after review'),
          const SectionTitle('Welcome bonus'),
          WelcomeBonusCard(data: w),
          const SectionTitle('VIP level'),
          VipCard(data: v),
          const SectionTitle('Earn more'),
          ListRow(icon: Icons.group_add_rounded, title: 'Invite friends', subtitle: 'Earn ₦5,000 per qualified friend', onTap: () => Nav.referrals(context)),
          ListRow(icon: Icons.military_tech_rounded, title: 'Knockout challenges', subtitle: 'Complete challenges for points and badges', onTap: () => Nav.knockout(context)),
          ListRow(icon: Icons.local_fire_department_rounded, iconColor: KnockColors.orange, title: 'Fire Load', subtitle: 'Limited-time rate boosts and bonuses', onTap: () => Nav.fireLoad(context)),
          const SectionTitle('History'),
          if (history.isEmpty)
            const EmptyState(icon: Icons.card_giftcard_rounded, title: 'No rewards yet', message: 'Rewards you earn will appear here.')
          else
            for (final g in history)
              ListRow(
                icon: switch (g['kind']) { 'referral' => Icons.group_rounded, 'welcome' => Icons.celebration_rounded, 'campaign' => Icons.local_fire_department_rounded, _ => Icons.military_tech_rounded },
                title: g['title'] as String? ?? 'Reward',
                subtitle: '${F.date(g['createdAt'] as String)}${g['reason'] != null ? ' · ${g['reason']}' : ''}',
                trailing: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.end, children: [
                  Text((g['amount'] as int? ?? 0) > 0 ? F.ngn(g['amount'] as int) : '+${g['points']} pts', style: KnockText.bodyStrong),
                  Text(g['status'] as String, style: KnockText.micro),
                ]),
              ),
        ]);
      },
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile({required this.label, required this.value, required this.note});
  final String label;
  final String value;
  final String note;
  @override
  Widget build(BuildContext context) => KnockCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: KnockText.caption),
          const SizedBox(height: 4),
          FittedBox(child: Text(value, style: KnockText.title)),
          Text(note, style: KnockText.micro),
        ]),
      );
}

class WelcomeBonusCard extends StatelessWidget {
  const WelcomeBonusCard({super.key, required this.data});
  final Json data;
  @override
  Widget build(BuildContext context) {
    final steps = (data['steps'] as List).cast<Json>();
    final status = data['status'] as String;
    return KnockCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Icon(Icons.celebration_rounded, color: KnockColors.orange),
          const SizedBox(width: 10),
          Expanded(child: Text('${F.ngn(data['amount'] as int)} welcome bonus', style: KnockText.headline)),
          StatusChip(switch (status) { 'credited' => 'successful', 'reversed' || 'rejected' => 'failed', _ => 'pending' }, label: switch (status) { 'credited' => 'Paid', 'reversed' => 'Reversed', 'rejected' => 'Not eligible', 'in_progress' => 'Trade in progress', 'held' => 'In review', _ => 'Available' }),
        ]),
        const SizedBox(height: 12),
        for (final s in steps)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(children: [
              Icon(s['done'] == true ? Icons.check_circle_rounded : Icons.radio_button_unchecked_rounded, size: 18, color: s['done'] == true ? KnockColors.green : KnockColors.textTertiary),
              const SizedBox(width: 8),
              Text(s['label'] as String, style: KnockText.body),
            ]),
          ),
        if (data['reason'] != null) Note(data['reason'] as String),
        if (data['reference'] != null) Text('Ref ${data['reference']}', style: KnockText.micro),
        ExpansionTile(
          tilePadding: EdgeInsets.zero,
          title: Text('How it works', style: KnockText.bodyStrong),
          children: [for (final r in (data['rules'] as List).cast<String>()) Padding(padding: const EdgeInsets.only(bottom: 6), child: Text('• $r', style: KnockText.caption))],
        ),
      ]),
    );
  }
}

class VipCard extends StatelessWidget {
  const VipCard({super.key, required this.data});
  final Json data;
  @override
  Widget build(BuildContext context) {
    final levels = (data['levels'] as List).cast<Json>();
    final current = levels.firstWhere((l) => l['id'] == data['level']);
    final next = data['next'] as Json?;
    final vol = data['volumeUsdCents90d'] as int;
    final colour = switch (current['id']) { 'gold' => const Color(0xFFFFC94D), 'black' => Colors.white, _ => const Color(0xFFC9CED6) };
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      KnockCard(
        gradient: LinearGradient(colors: [colour.withValues(alpha: 0.25), KnockColors.surface]),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [Icon(Icons.workspace_premium_rounded, color: colour), const SizedBox(width: 8), Text('Knock ${current['name']}', key: const ValueKey('vip-level'), style: KnockText.headline)]),
          const SizedBox(height: 8),
          Text('${F.usdCents(vol)} traded in the last 90 days', style: KnockText.caption),
          if (next != null) ...[
            const SizedBox(height: 10),
            KProgress((vol / ((next['minUsd'] as int) * 100)).clamp(0, 1).toDouble()),
            const SizedBox(height: 6),
            Text('${F.usdCents((next['minUsd'] as int) * 100 - vol)} more to reach ${next['name']}', style: KnockText.caption),
          ],
        ]),
      ),
      const SizedBox(height: 8),
      for (final l in levels)
        ExpansionTile(
          tilePadding: EdgeInsets.zero,
          title: Text('${l['name']}${l['id'] == current['id'] ? ' · your level' : ''}', style: KnockText.bodyStrong),
          subtitle: Text((l['minUsd'] as int) == 0 ? 'Everyone starts here' : 'From \$${l['minUsd']} in 90 days', style: KnockText.caption),
          children: [for (final b in (l['benefits'] as List).cast<String>()) Align(alignment: Alignment.centerLeft, child: Padding(padding: const EdgeInsets.only(bottom: 6), child: Text('• $b', style: KnockText.caption)))],
        ),
      Text(data['rule'] as String, style: KnockText.micro),
    ]);
  }
}
