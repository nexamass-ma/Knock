import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../api/api.dart';
import '../../app/app_controller.dart';
import '../../core/format.dart';
import '../../design/tokens.dart';
import '../../design/widgets/kit.dart';
import '../common/launch.dart';
import '../common/receipt.dart';
import '../settings/legal_screen.dart';

String inviteText(Json d) =>
    'Join me on Knock, the easy way to trade gift cards and crypto in Nigeria. Sign up with my code ${d['code']}: ${d['link']}';

/// One-tap invite: share sheet with the code and link, recorded for stats.
Future<void> shareInvite(BuildContext context, {String channel = 'share'}) async {
  final api = context.api;
  try {
    final d = await api.call((s, t) => s.referrals(t!));
    if (!context.mounted) return;
    api.call((s, t) => s.recordInvite(t!, channel)).ignore();
    if (channel == 'whatsapp') {
      await whatsAppShare(context, inviteText(d));
    } else {
      await shareText(context, inviteText(d), subject: 'Join me on Knock');
    }
  } catch (e) {
    if (context.mounted) showApiError(context, e);
  }
}

class ReferralsScreen extends StatelessWidget {
  const ReferralsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return ApiView(
      load: (api) => api.call((s, t) => s.referrals(t!)),
      builder: (context, d, reload) {
        final st = d['stats'] as Json;
        final items = (d['items'] as List).cast<Json>();
        return KPage(
          title: 'Invite Friends',
          onRefresh: reload,
          actions: [IconButton(tooltip: 'Referral terms', icon: const Icon(Icons.gavel_rounded), onPressed: () => go(context, const LegalScreen(kind: LegalKind.referralTerms)))],
          children: [
            KnockCard(
              gradient: KnockColors.heroGradient,
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Earn ${F.ngn(d['rewardPerReferral'] as int)} for every friend', style: KnockText.title),
                const SizedBox(height: 6),
                Text('Your friend qualifies once they complete \$${d['qualifyUsd']} in settled, eligible trades.', style: KnockText.body.copyWith(color: Colors.white70)),
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  decoration: BoxDecoration(color: Colors.black26, borderRadius: BorderRadius.circular(KnockRadius.sm)),
                  child: Row(children: [
                    Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('Your code', style: KnockText.micro),
                      Text(d['code'] as String, key: const ValueKey('ref-code'), style: KnockText.headline.copyWith(letterSpacing: 2)),
                    ])),
                    IconButton(
                      tooltip: 'Copy link',
                      icon: const Icon(Icons.copy_rounded),
                      onPressed: () {
                        Clipboard.setData(ClipboardData(text: d['link'] as String));
                        toast(context, 'Invite link copied');
                      },
                    ),
                  ]),
                ),
                const SizedBox(height: 12),
                Row(children: [
                  Expanded(child: KnockButton(key: const ValueKey('ref-share'), label: 'Share', icon: Icons.ios_share_rounded, onPressed: () => shareInvite(context))),
                  const SizedBox(width: 10),
                  Expanded(child: KnockButton(label: 'WhatsApp', icon: Icons.chat_rounded, style: KnockButtonStyle.secondary, onPressed: () => shareInvite(context, channel: 'whatsapp'))),
                ]),
              ]),
            ),
            const SectionTitle('Your referrals'),
            GridView.count(
              crossAxisCount: 3,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              mainAxisSpacing: 10,
              crossAxisSpacing: 10,
              childAspectRatio: 1.15,
              children: [
                _Stat('Invited', '${st['invited']}'),
                _Stat('Registered', '${st['registered']}'),
                _Stat('Verified', '${st['verified']}'),
                _Stat('Qualified', '${st['qualified']}'),
                _Stat('Pending', F.ngn(st['pendingRewards'] as int)),
                _Stat('Earned', F.ngn(st['totalEarned'] as int), highlight: true),
              ],
            ),
            const SizedBox(height: 10),
            const Note('Rewards are held for review before they become available, to protect against fraud. Self-referrals and duplicate accounts do not qualify.', icon: Icons.shield_outlined),
            const SectionTitle('People you invited'),
            if (items.isEmpty)
              const EmptyState(icon: Icons.group_add_outlined, title: 'No referrals yet', message: 'Share your code. You will see each friend here as they join and trade.')
            else
              for (final r in items)
                ListRow(
                  key: ValueKey('ref-${r['id']}'),
                  leading: Avatar(name: r['name'] as String),
                  title: r['name'] as String,
                  subtitle: '${r['statusLabel']} · ${F.usdCents(r['volumeUsdCents'] as int)} of \$${d['qualifyUsd']}',
                  trailing: StatusChip(_chip(r['rewardStatus'] as String?), label: _rewardLabel(r['rewardStatus'] as String?)),
                  onTap: () => go(context, ReferralDetailScreen(r: r, qualifyUsd: d['qualifyUsd'] as int)),
                ),
          ],
        );
      },
    );
  }
}

String _chip(String? s) => switch (s) { 'available' => 'successful', 'rejected' || 'reversed' => 'failed', _ => 'pending' };
String _rewardLabel(String? s) => switch (s) { 'available' => 'Earned', 'pending' => 'On hold', 'rejected' => 'Not eligible', 'reversed' => 'Reversed', _ => 'Not yet' };

class _Stat extends StatelessWidget {
  const _Stat(this.label, this.value, {this.highlight = false});
  final String label;
  final String value;
  final bool highlight;
  @override
  Widget build(BuildContext context) => KnockCard(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.center, children: [
          FittedBox(child: Text(value, style: KnockText.headline.copyWith(color: highlight ? KnockColors.greenBright : null))),
          const SizedBox(height: 2),
          Text(label, style: KnockText.caption),
        ]),
      );
}

class ReferralDetailScreen extends StatelessWidget {
  const ReferralDetailScreen({super.key, required this.r, required this.qualifyUsd});
  final Json r;
  final int qualifyUsd;
  @override
  Widget build(BuildContext context) {
    final v = r['volumeUsdCents'] as int;
    final target = qualifyUsd * 100;
    return KPage(title: r['name'] as String, children: [
      KnockCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [Avatar(name: r['name'] as String), const SizedBox(width: 12), Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(r['name'] as String, style: KnockText.bodyStrong), Text(r['email'] as String, style: KnockText.caption)]))]),
          const SizedBox(height: 16),
          Text('Qualifying volume', style: KnockText.caption),
          const SizedBox(height: 6),
          KProgress((v / target).clamp(0, 1).toDouble()),
          const SizedBox(height: 6),
          Text('${F.usdCents(v)} of \$$qualifyUsd', style: KnockText.bodyStrong),
        ]),
      ),
      const SizedBox(height: 12),
      KeyValue('Status', r['statusLabel'] as String),
      KeyValue('Joined', F.date(r['joinedAt'] as String)),
      if (r['qualifiedAt'] != null) KeyValue('Qualified', F.date(r['qualifiedAt'] as String)),
      KeyValue('Reward', F.ngn(r['reward'] as int)),
      KeyValue('Reward status', _rewardLabel(r['rewardStatus'] as String?)),
      if (r['reason'] != null) ...[const SizedBox(height: 10), Note(r['reason'] as String, icon: Icons.info_outline_rounded)],
      const SizedBox(height: 10),
      const Note('For privacy we only show a masked email and your friend\'s progress, never their transactions.', icon: Icons.lock_outline_rounded),
    ]);
  }
}
