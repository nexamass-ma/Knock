import 'package:material_ui/material_ui.dart';

import '../../design/tokens.dart';
import '../../design/widgets/surfaces.dart';
import 'link_detail_screen.dart';
import 'pl_models.dart';
import 'pl_sandbox.dart';
import 'pl_split.dart';
import 'pl_widgets.dart';

enum StaffRole {
  support('Support', 'View only'),
  compliance('Compliance', 'Place links under review, clear flags'),
  finance('Finance', 'Refunds, manual distribution'),
  admin('Admin', 'Everything');

  const StaffRole(this.label, this.can);
  final String label;
  final String can;
}

/// Knock Admin: Payment Links section. Same data as the backend admin API.
class PlAdminScreen extends StatefulWidget {
  const PlAdminScreen({super.key, required this.sandbox});
  final PlSandbox sandbox;

  @override
  State<PlAdminScreen> createState() => _PlAdminScreenState();
}

class _PlAdminScreenState extends State<PlAdminScreen> {
  StaffRole role = StaffRole.compliance;
  String query = '';
  PlSandbox get sb => widget.sandbox;

  bool get canReview => role == StaffRole.compliance || role == StaffRole.admin;
  bool get canMoveMoney => role == StaffRole.finance || role == StaffRole.admin;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: sb,
      builder: (context, _) => DefaultTabController(
        length: 5,
        child: Scaffold(
          backgroundColor: KnockColors.background,
          appBar: AppBar(
            backgroundColor: KnockColors.background,
            title: const Text('Admin · Payment Links'),
            actions: [
              PopupMenuButton<StaffRole>(
                tooltip: 'Staff role',
                initialValue: role,
                onSelected: (r) => setState(() => role = r),
                itemBuilder: (_) => [for (final r in StaffRole.values) PopupMenuItem(value: r, child: Text('${r.label} · ${r.can}'))],
                child: Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child: Center(child: Tag(role.label, color: KnockColors.orange)),
                ),
              ),
            ],
            bottom: const TabBar(
              isScrollable: true,
              tabAlignment: TabAlignment.start,
              indicatorColor: KnockColors.green,
              labelColor: KnockColors.textPrimary,
              unselectedLabelColor: KnockColors.textSecondary,
              tabs: [
                Tab(text: 'Analytics'),
                Tab(text: 'Links'),
                Tab(text: 'Failed splits'),
                Tab(text: 'Risk'),
                Tab(text: 'Ledger & audit'),
              ],
            ),
          ),
          body: TabBarView(children: [_analytics(), _links(), _failed(), _risk(), _ledger()]),
        ),
      ),
    );
  }

  EdgeInsets get _pad => const EdgeInsets.all(KnockSpace.gutter);

  Widget _analytics() {
    final ngn = sb.links.where((l) => l.asset.isFiat);
    var collected = 0, distributed = 0, held = 0, payments = 0, failed = 0;
    for (final l in ngn) {
      final t = sb.totals(l.id);
      collected += t.collected;
      distributed += t.distributed;
      held += t.held;
      payments += t.succeeded;
      failed += t.failed;
    }
    final byType = {for (final t in LinkType.values) t: sb.links.where((l) => l.type == t).length};
    return ListView(
      padding: _pad,
      children: [
        const SandboxBanner(),
        const SizedBox(height: KnockSpace.md),
        KnockCard(
          child: Column(
            children: [
              KvRow('Links', '${sb.links.length}', strong: true),
              for (final e in byType.entries) KvRow('  ${e.key.label}', '${e.value}'),
              KvRow('Active', '${sb.links.where((l) => l.status == LinkStatus.active).length}'),
              KvRow('Under review', '${sb.links.where((l) => l.status == LinkStatus.underReview).length}'),
            ],
          ),
        ),
        const SizedBox(height: KnockSpace.sm),
        KnockCard(
          child: Column(
            children: [
              KvRow('NGN collected', PlFmt.money(collected, PlAsset.ngn), strong: true),
              KvRow('NGN split out', PlFmt.money(distributed, PlAsset.ngn)),
              KvRow('NGN held in collection', PlFmt.money(held, PlAsset.ngn)),
              KvRow('Knock fee revenue (NGN)', PlFmt.money(sb.feeRevenue('NGN'), PlAsset.ngn), valueColor: KnockColors.greenBright),
              KvRow('Knock fee revenue (USDT)', PlFmt.money(sb.feeRevenue('USDT'), PlAsset.crypto.first)),
              KvRow('Successful payments', '$payments'),
              KvRow('Failed payments', '$failed'),
              KvRow('Disputes', '${sb.payments.where((p) => p.status == PayStatus.disputed).length}'),
              KvRow('Reversed', '${sb.payments.where((p) => p.status == PayStatus.reversed).length}'),
            ],
          ),
        ),
      ],
    );
  }

  Widget _links() {
    final q = query.toLowerCase();
    final ls = sb.links.reversed
        .where(
          (l) =>
              q.isEmpty ||
              l.reference.toLowerCase().contains(q) ||
              l.creator.username.contains(q.replaceFirst('@', '')) ||
              l.title.toLowerCase().contains(q),
        )
        .toList();
    return ListView(
      padding: _pad,
      children: [
        TextField(
          decoration: plInput('Search by link ID, creator or name', hint: 'KPL-… or @chanor'),
          onChanged: (v) => setState(() => query = v),
        ),
        const SizedBox(height: KnockSpace.sm),
        for (final l in ls)
          Padding(
            padding: const EdgeInsets.only(bottom: KnockSpace.xs),
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
                      Expanded(child: Text('${l.title} · ${l.reference}', style: KnockText.bodyStrong)),
                      StatusTag(l.status.label, linkStatusColor(l.status)),
                    ],
                  ),
                  Text(
                    '@${l.creator.username} · ${l.type.label} · ${l.currentRules.map((r) => '@${r.user.username}').join(', ')}',
                    style: KnockText.micro,
                  ),
                  Text('Collected ${PlFmt.money(sb.totals(l.id).collected, l.asset)} · rules v${l.ruleVersion}', style: KnockText.micro),
                  if (canReview)
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton(
                        onPressed: () =>
                            _try(() => sb.setStatus(l, l.status == LinkStatus.underReview ? 'clear_review' : 'review', asStaff: true)),
                        child: Text(l.status == LinkStatus.underReview ? 'Clear review' : 'Place under review'),
                      ),
                    ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Widget _failed() {
    final ps = sb.payments
        .where(
          (p) => p.distribution == DistributionStatus.failedRetrying || (p.distribution == DistributionStatus.held && p.holdReason != null),
        )
        .toList();
    return ListView(
      padding: _pad,
      children: [
        Text(
          'Payments that are verified but not yet split. The money is safe in the link\'s collection account.',
          style: KnockText.caption,
        ),
        const SizedBox(height: KnockSpace.sm),
        if (ps.isEmpty) Text('None. Every verified payment has been split.', style: KnockText.body),
        for (final p in ps)
          KnockCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('${p.reference} · ${sb.link(p.linkId).title}', style: KnockText.bodyStrong),
                Text('${p.distribution.label} · attempts ${p.attempts}', style: KnockText.micro),
                Text(p.holdReason ?? '', style: KnockText.caption.copyWith(color: KnockColors.orange)),
                if (canMoveMoney)
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(
                      onPressed: () => _try(() => sb.distributeHeld(sb.link(p.linkId))),
                      child: const Text('Retry / distribute'),
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _risk() {
    return ListView(
      padding: _pad,
      children: [
        Text(
          'Automatic checks: amount mismatches, wrong network, unsigned webhooks, payer velocity, payments just under limits, recovery shortfalls.',
          style: KnockText.caption,
        ),
        const SizedBox(height: KnockSpace.sm),
        if (sb.flags.isEmpty) Text('No open flags.', style: KnockText.body),
        for (final f in sb.flags.reversed)
          Padding(
            padding: const EdgeInsets.only(bottom: KnockSpace.xs),
            child: KnockCard(
              child: Row(
                children: [
                  StatusTag(f.severity.toUpperCase(), f.severity == 'high' ? KnockColors.loss : KnockColors.orange),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(f.rule.replaceAll('_', ' '), style: KnockText.bodyStrong),
                        Text(f.detail, style: KnockText.caption),
                      ],
                    ),
                  ),
                  if (canReview && f.open) TextButton(onPressed: () => setState(() => f.open = false), child: const Text('Clear')),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Widget _ledger() {
    final problems = sb.reconcile();
    return ListView(
      padding: _pad,
      children: [
        KnockCard(
          color: problems.isEmpty ? KnockColors.greenSoft : const Color(0x33FF6B6B),
          child: Row(
            children: [
              Icon(
                problems.isEmpty ? Icons.verified_rounded : Icons.warning_amber_rounded,
                color: problems.isEmpty ? KnockColors.greenBright : KnockColors.loss,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  problems.isEmpty
                      ? 'Reconciled: ${sb.entries.length} balanced journal entries match every payment and allocation.'
                      : problems.join('\n'),
                  style: KnockText.body,
                ),
              ),
            ],
          ),
        ),
        const SectionHeader('Webhooks'),
        for (final w in sb.webhookLog.reversed.take(15))
          Text('${PlFmt.dateTime(w.at)} · ${w.event} · ${w.paymentRef} → ${w.result}', style: KnockText.micro),
        const SectionHeader('Journal (latest)'),
        for (final e in sb.entries.reversed.take(20))
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: KnockCard(
              padding: const EdgeInsets.all(KnockSpace.sm),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('${e.kind} · ${e.key}', style: KnockText.micro.copyWith(color: KnockColors.textPrimary)),
                  for (final (acct, amt) in e.lines)
                    Text(
                      '${amt > 0 ? 'DR' : 'CR'} ${acct.split(':').first} ${_owner(acct)}  ${PlFmt.major(amt.abs(), e.currency == 'NGN' ? PlAsset.ngn : PlAsset.crypto.first)} ${e.currency}',
                      style: KnockText.micro,
                    ),
                ],
              ),
            ),
          ),
        const SectionHeader('Audit log'),
        for (final a in sb.audit.reversed.take(30))
          Text('${PlFmt.dateTime(a.at)} · ${a.actor} · ${a.action}${a.detail != null ? ' · ${a.detail}' : ''}', style: KnockText.micro),
      ],
    );
  }

  String _owner(String acct) {
    final id = acct.split(':')[1];
    if (id.startsWith('u_')) return '@${sb.user(id).username}';
    if (id.startsWith('pl_')) return sb.link(id).reference;
    return '';
  }

  void _try(void Function() f) {
    try {
      f();
    } on PlException catch (e) {
      plToast(context, e.message, error: true);
    }
  }
}
