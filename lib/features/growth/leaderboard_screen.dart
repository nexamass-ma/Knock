import 'package:material_ui/material_ui.dart';

import '../../api/api.dart';
import '../../core/format.dart';
import '../../design/tokens.dart';
import '../../design/widgets/kit.dart';

class LeaderboardScreen extends StatefulWidget {
  const LeaderboardScreen({super.key});
  @override
  State<LeaderboardScreen> createState() => _LeaderboardScreenState();
}

class _LeaderboardScreenState extends State<LeaderboardScreen> {
  String _board = 'traders';
  String _period = 'monthly';

  String _score(Json r, String unit) => switch (unit) {
        'usd_cents' => F.usdCents(r['score'] as int),
        'referrals' => '${r['score']} referral${r['score'] == 1 ? '' : 's'}',
        _ => '${r['score']} trade${r['score'] == 1 ? '' : 's'}',
      };

  @override
  Widget build(BuildContext context) {
    return KPage(title: 'Leaderboard', children: [
      PillTabs<String>(values: const ['traders', 'referrers', 'volume'], selected: _board, labelOf: (v) => switch (v) { 'traders' => 'Top traders', 'referrers' => 'Top referrers', _ => 'Volume' }, onChanged: (v) => setState(() => _board = v)),
      const SizedBox(height: 10),
      PillTabs<String>(dense: true, values: const ['weekly', 'monthly', 'all'], selected: _period, labelOf: (v) => switch (v) { 'weekly' => 'This week', 'monthly' => 'This month', _ => 'All time' }, onChanged: (v) => setState(() => _period = v)),
      const SizedBox(height: 16),
      ApiView(
        key: ValueKey('$_board-$_period'),
        load: (api) => api.call((s, t) => s.leaderboard(t!, board: _board, period: _period)),
        builder: (context, d, _) {
          final top = (d['top'] as List).cast<Json>();
          final me = d['me'] as Json;
          final unit = d['unit'] as String;
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            KnockCard(
              key: const ValueKey('lb-me'),
              color: KnockColors.greenSoft,
              child: Row(children: [
                Text(me['position'] == null ? '—' : '#${me['position']}', style: KnockText.title),
                const SizedBox(width: 14),
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('Your rank', style: KnockText.bodyStrong),
                  Text(me['position'] == null ? 'Complete a trade to join the board.' : 'of ${d['total']} · ${_score(me, unit)}', style: KnockText.caption),
                ])),
              ]),
            ),
            const SizedBox(height: 12),
            if (top.isEmpty)
              const EmptyState(icon: Icons.emoji_events_outlined, title: 'No one here yet', message: 'Be the first on this board.')
            else
              for (final r in top)
                ListRow(
                  leading: SizedBox(
                    width: 40,
                    child: Center(
                      child: (r['position'] as int) <= 3
                          ? Icon(Icons.emoji_events_rounded, color: [const Color(0xFFFFC94D), const Color(0xFFC9CED6), const Color(0xFFCD8B5A)][(r['position'] as int) - 1])
                          : Text('${r['position']}', style: KnockText.bodyStrong),
                    ),
                  ),
                  title: r['displayName'] as String,
                  subtitle: [if (r['rewardStatus'] != null) r['rewardStatus'], if (r['sandbox'] == true) 'Sandbox user'].join(' · '),
                  trailing: Text(_score(r, unit), style: KnockText.bodyStrong),
                ),
            const SizedBox(height: 12),
            Note(d['rules'] as String, icon: Icons.info_outline_rounded),
          ]);
        },
      ),
    ]);
  }
}
