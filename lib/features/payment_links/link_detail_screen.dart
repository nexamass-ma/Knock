import 'package:material_ui/material_ui.dart';

import '../../design/tokens.dart';
import '../../design/widgets/states.dart';
import '../../design/widgets/surfaces.dart';
import 'pay_page_screen.dart';
import 'pl_models.dart';
import 'pl_sandbox.dart';
import 'pl_split.dart';
import 'pl_widgets.dart';
import 'share_sheet.dart';

class LinkDetailScreen extends StatelessWidget {
  const LinkDetailScreen({super.key, required this.sandbox, required this.linkId, this.justCreated = false});
  final PlSandbox sandbox;
  final String linkId;
  final bool justCreated;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: sandbox,
      builder: (context, _) {
        final l = sandbox.link(linkId);
        return DefaultTabController(
          length: 5,
          child: Scaffold(
            backgroundColor: KnockColors.background,
            appBar: AppBar(
              backgroundColor: KnockColors.background,
              title: Text(l.title, overflow: TextOverflow.ellipsis),
              actions: [IconButton(tooltip: 'Share', icon: const Icon(Icons.ios_share_rounded), onPressed: () => showShareSheet(context, l))],
              bottom: const TabBar(
                isScrollable: true,
                tabAlignment: TabAlignment.start,
                indicatorColor: KnockColors.green,
                labelColor: KnockColors.textPrimary,
                unselectedLabelColor: KnockColors.textSecondary,
                tabs: [
                  Tab(text: 'Overview'),
                  Tab(text: 'Recipients'),
                  Tab(text: 'Payments'),
                  Tab(text: 'Split history'),
                  Tab(text: 'Settings'),
                ],
              ),
            ),
            body: TabBarView(
              children: [
                _Overview(sb: sandbox, l: l, justCreated: justCreated),
                _Recipients(sb: sandbox, l: l),
                _Payments(sb: sandbox, l: l),
                _SplitHistory(sb: sandbox, l: l),
                _Settings(sb: sandbox, l: l),
              ],
            ),
          ),
        );
      },
    );
  }
}

EdgeInsets get _pad => const EdgeInsets.fromLTRB(KnockSpace.gutter, KnockSpace.md, KnockSpace.gutter, KnockSpace.xxl);

void _openPayPage(BuildContext context, PlSandbox sb, PaymentLink l) => Navigator.of(context).push(
  MaterialPageRoute<void>(
    builder: (_) => PayPageScreen(sandbox: sb, linkId: l.id),
  ),
);

class _Overview extends StatelessWidget {
  const _Overview({required this.sb, required this.l, required this.justCreated});
  final PlSandbox sb;
  final PaymentLink l;
  final bool justCreated;

  @override
  Widget build(BuildContext context) {
    final t = sb.totals(l.id);
    final ps = sb.paymentsOf(l.id);
    return ListView(
      padding: _pad,
      children: [
        if (justCreated) ...[
          KnockCard(
            color: KnockColors.greenSoft,
            child: Row(
              children: [
                const Icon(Icons.check_circle_rounded, color: KnockColors.greenBright),
                const SizedBox(width: 10),
                Expanded(child: Text('Your link is live. Share it, or open it as a payer to try a sandbox payment.', style: KnockText.body)),
              ],
            ),
          ),
          const SizedBox(height: KnockSpace.sm),
        ],
        KnockCard(
          gradient: KnockColors.cardGradient,
          padding: const EdgeInsets.all(KnockSpace.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text('${l.reference} · ${l.type.label}', style: KnockText.micro.copyWith(color: Colors.white70)),
                  ),
                  StatusTag(l.status.label, linkStatusColor(l.status)),
                ],
              ),
              const SizedBox(height: 10),
              Text('Collected', style: KnockText.caption.copyWith(color: Colors.white70)),
              Text(PlFmt.money(t.collected, l.asset), style: KnockText.display.copyWith(fontSize: 32)),
              if (l.target != null) ...[
                const SizedBox(height: 10),
                ProgressBar(t.collected / l.target!),
                const SizedBox(height: 8),
                Text(
                  '${(t.collected * 100 / l.target!).toStringAsFixed(0)}% of ${PlFmt.money(l.target!, l.asset, decimals: false)} · ${PlFmt.money((l.target! - t.collected).clamp(0, 1 << 62), l.asset, decimals: false)} remaining',
                  style: KnockText.micro.copyWith(color: Colors.white70),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: KnockSpace.sm),
        Row(
          children: [
            Expanded(
              child: KnockButton(label: 'Share', icon: Icons.ios_share_rounded, onPressed: () => showShareSheet(context, l)),
            ),
            const SizedBox(width: KnockSpace.sm),
            Expanded(
              child: KnockButton(label: 'Pay as customer', icon: Icons.open_in_new_rounded, style: KnockButtonStyle.secondary, onPressed: () => _openPayPage(context, sb, l)),
            ),
          ],
        ),
        const SizedBox(height: KnockSpace.md),
        KnockCard(
          child: Column(
            children: [
              KvRow('Total expected', l.target == null ? 'No target' : PlFmt.money(l.target!, l.asset)),
              KvRow('Split out to recipients', PlFmt.money(t.distributed, l.asset)),
              KvRow('Held in collection balance', PlFmt.money(t.held, l.asset), valueColor: t.held > 0 ? KnockColors.orange : null),
              KvRow('Successful payments', '${t.succeeded}'),
              KvRow('Pending payments', '${t.pending}'),
              KvRow('Failed payments', '${t.failed}'),
              KvRow('Distribution', l.settlementMode.label),
              KvRow('Expires', l.expiresAt == null ? 'Never' : PlFmt.dateTime(l.expiresAt!)),
            ],
          ),
        ),
        const SectionHeader('Recent payments'),
        if (ps.isEmpty) Text('No payments yet.', style: KnockText.caption),
        for (final p in ps.take(5)) _PaymentTile(sb: sb, l: l, p: p),
      ],
    );
  }
}

class _Recipients extends StatelessWidget {
  const _Recipients({required this.sb, required this.l});
  final PlSandbox sb;
  final PaymentLink l;

  @override
  Widget build(BuildContext context) {
    final als = sb.allocationsOf(l.id);
    final recips = {for (final r in l.currentRules) r.user.id: r.user, for (final a in als) a.recipient.id: a.recipient};
    return ListView(
      padding: _pad,
      children: [
        Text('Rules v${l.ruleVersion} · ${l.splitMethod.label}${l.rulesLocked ? ' · locked' : ''}', style: KnockText.caption),
        const SizedBox(height: KnockSpace.sm),
        for (final u in recips.values) _recipientCard(u, als.where((a) => a.recipient.id == u.id).toList()),
      ],
    );
  }

  Widget _recipientCard(KnockUser u, List<Allocation> mine) {
    final rule = l.currentRules.where((r) => r.user.id == u.id).firstOrNull;
    int sum(AllocState s) => mine.where((a) => a.state == s).fold(0, (a, x) => a + x.net);
    final received = mine.where((a) => a.state != AllocState.reversed).fold<int>(0, (a, x) => a + x.net);
    final live = sb.user(u.id);
    return Padding(
      padding: const EdgeInsets.only(bottom: KnockSpace.sm),
      child: KnockCard(
        child: Column(
          children: [
            Row(
              children: [
                UserAvatar(u),
                const SizedBox(width: KnockSpace.sm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(u.displayName, style: KnockText.bodyStrong),
                      Text('@${u.username} · ${l.asset.code} wallet', style: KnockText.micro),
                    ],
                  ),
                ),
                if (live.frozen) const StatusTag('Frozen', KnockColors.loss),
                if (rule == null) const StatusTag('Removed', KnockColors.textTertiary),
              ],
            ),
            const SizedBox(height: 8),
            if (rule != null) ...[
              KvRow('Allocated', l.splitMethod == SplitMethod.fixed || l.target != null ? PlFmt.money(rule.allocated, l.asset) : 'Of every payment'),
              KvRow('Percentage', PlFmt.percent(rule.basisPoints)),
            ],
            KvRow('Total received', PlFmt.money(received, l.asset), strong: true),
            KvRow('Pending', PlFmt.money(sum(AllocState.pending), l.asset), valueColor: KnockColors.orange),
            KvRow('Available', PlFmt.money(sum(AllocState.available), l.asset), valueColor: KnockColors.greenBright),
            if (sum(AllocState.held) > 0) KvRow('On hold (dispute)', PlFmt.money(sum(AllocState.held), l.asset), valueColor: KnockColors.loss),
            KvRow('Distributions', '${mine.length}'),
          ],
        ),
      ),
    );
  }
}

class _Payments extends StatelessWidget {
  const _Payments({required this.sb, required this.l});
  final PlSandbox sb;
  final PaymentLink l;

  @override
  Widget build(BuildContext context) {
    final ps = sb.paymentsOf(l.id);
    if (ps.isEmpty) {
      return EmptyState(
        icon: Icons.payments_outlined,
        title: 'No payments yet',
        message: 'Share the link, or open it as a customer to try a sandbox payment.',
        action: 'Pay as customer',
        onAction: () => _openPayPage(context, sb, l),
      );
    }
    return ListView(
      padding: _pad,
      children: [for (final p in ps) _PaymentTile(sb: sb, l: l, p: p)],
    );
  }
}

class _PaymentTile extends StatelessWidget {
  const _PaymentTile({required this.sb, required this.l, required this.p});
  final PlSandbox sb;
  final PaymentLink l;
  final LinkPayment p;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: KnockSpace.xs),
      child: KnockCard(
        onTap: () => _paymentSheet(context),
        padding: const EdgeInsets.symmetric(horizontal: KnockSpace.md, vertical: KnockSpace.sm),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(PlFmt.maskName(p.payerName), style: KnockText.bodyStrong),
                  Text('${p.reference} · ${p.method.label} · ${PlFmt.dateTime(p.createdAt)}', style: KnockText.micro),
                ],
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(PlFmt.money(p.grossPaid ?? p.totalToPay, l.asset, decimals: l.asset.isFiat ? false : true), style: KnockText.number),
                const SizedBox(height: 2),
                StatusTag(p.status.label, payStatusColor(p.status)),
              ],
            ),
          ],
        ),
      ),
    );
  }

  void _paymentSheet(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: KnockColors.surfaceRaised,
      builder: (ctx) => ListenableBuilder(
        listenable: sb,
        builder: (ctx, _) {
          Future<void> act(void Function() f) async {
            try {
              f();
            } on PlException catch (e) {
              plToast(ctx, e.message, error: true);
            }
          }

          return SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(KnockSpace.gutter),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Payment ${p.reference}', style: KnockText.headline),
                  const SizedBox(height: KnockSpace.sm),
                  KvRow('Payer', '${PlFmt.maskName(p.payerName)} ${PlFmt.maskEmail(p.payerEmail)}'),
                  KvRow('Amount paid', PlFmt.money(p.grossPaid ?? p.totalToPay, l.asset), strong: true),
                  KvRow('Knock fee', PlFmt.money(p.knockFee, l.asset)),
                  KvRow('Method', p.method.label),
                  KvRow('Currency', l.asset.label),
                  KvRow('Status', p.status.label, valueColor: payStatusColor(p.status)),
                  KvRow('Distribution', p.distribution.label),
                  KvRow('Provider ref', p.providerReference),
                  if (p.txHash != null) KvRow('Tx hash', '${p.txHash!.substring(0, 14)}…'),
                  if (p.holdReason != null) KvRow('Note', p.holdReason!, valueColor: KnockColors.orange),
                  KvRow('Provider settlement', p.settledAt == null ? 'Not yet' : PlFmt.dateTime(p.settledAt!)),
                  const SizedBox(height: KnockSpace.md),
                  Text('Sandbox actions', style: KnockText.bodyStrong),
                  const SizedBox(height: KnockSpace.xs),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      if (p.status == PayStatus.succeeded && p.settledAt == null) _chip('Provider settles (T+1)', () => act(() => sb.settle(p))),
                      if (p.grossPaid != null) _chip('Replay webhook', () => act(() => plToast(ctx, 'Engine: ${sb.replayWebhook(p)}'))),
                      if (p.status == PayStatus.succeeded) _chip('Open dispute', () => act(() => sb.openDispute(p, 'Payer says item not received'))),
                      if (p.status == PayStatus.disputed) ...[
                        _chip('Dispute won', () => act(() => sb.resolveDispute(p, won: true))),
                        _chip('Dispute lost', () => act(() => sb.resolveDispute(p, won: false))),
                      ],
                      if (p.status == PayStatus.succeeded) _chip('Refund', () => act(() => sb.reverse(p, 'refund', 'Refund requested by creator'))),
                      if (p.distribution == DistributionStatus.failedRetrying) _chip('Retry split now', () => act(() => sb.retryFailed())),
                      if (p.status == PayStatus.succeeded || p.status == PayStatus.disputed) _chip('Share receipt', () => shareReceipt(sb, p)),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text('Refunds and disputes depend on the payment provider supporting them for that method.', style: KnockText.micro),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _chip(String label, VoidCallback onTap) => ActionChip(
    label: Text(label),
    onPressed: onTap,
    backgroundColor: KnockColors.surfaceHigh,
    side: const BorderSide(color: KnockColors.stroke),
  );
}

class _SplitHistory extends StatelessWidget {
  const _SplitHistory({required this.sb, required this.l});
  final PlSandbox sb;
  final PaymentLink l;

  @override
  Widget build(BuildContext context) {
    final ps = sb.paymentsOf(l.id).where((p) => p.grossPaid != null).toList();
    if (ps.isEmpty) return const EmptyState(icon: Icons.call_split_rounded, title: 'No splits yet', message: 'Each verified payment shows here with its allocation per recipient.');
    return ListView(
      padding: _pad,
      children: [
        for (final p in ps)
          Padding(
            padding: const EdgeInsets.only(bottom: KnockSpace.sm),
            child: KnockCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(child: Text('${PlFmt.money(p.grossPaid!, l.asset)} · ${p.reference}', style: KnockText.bodyStrong)),
                      StatusTag(p.distribution.label, p.distribution == DistributionStatus.distributed ? KnockColors.greenBright : KnockColors.orange),
                    ],
                  ),
                  Text('${PlFmt.dateTime(p.verifiedAt!)}${p.ruleVersion != null ? ' · rules v${p.ruleVersion}' : ''}', style: KnockText.micro),
                  const SizedBox(height: 6),
                  KvRow('Knock fee', PlFmt.money(p.knockFee, l.asset)),
                  for (final a in sb.allocations.where((a) => a.paymentId == p.id))
                    KvRow('@${a.recipient.username}${a.overflow ? ' (overflow)' : ''} · ${a.state.label}', PlFmt.money(a.net, l.asset), valueColor: allocColor(a.state)),
                  if (p.holdReason != null) Text(p.holdReason!, style: KnockText.micro.copyWith(color: KnockColors.orange)),
                  if (sb.allocations.any((a) => a.paymentId == p.id)) Text('Ledger ref pay:${p.id}:split', style: KnockText.micro.copyWith(color: KnockColors.textTertiary)),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

class _Settings extends StatelessWidget {
  const _Settings({required this.sb, required this.l});
  final PlSandbox sb;
  final PaymentLink l;

  void _do(BuildContext context, void Function() f, String ok) {
    try {
      f();
      plToast(context, ok);
    } on PlException catch (e) {
      plToast(context, e.message, error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final pending = sb.amendments.where((m) => m.linkId == l.id && m.status == 'proposed').toList();
    final held = sb.totals(l.id).held;
    return ListView(
      padding: _pad,
      children: [
        KnockCard(
          child: Column(
            children: [
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text('Link name', style: KnockText.caption),
                subtitle: Text(l.title, style: KnockText.bodyStrong),
                trailing: const Icon(Icons.edit_outlined),
                onTap: () => _edit(context, 'Link name', l.title, (v) => sb.updateDetails(l, title: v)),
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text('Payment instructions', style: KnockText.caption),
                subtitle: Text(l.instructions ?? 'None', style: KnockText.body),
                trailing: const Icon(Icons.edit_outlined),
                onTap: () => _edit(context, 'Payment instructions', l.instructions ?? '', (v) => sb.updateDetails(l, instructions: v)),
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text('Expiry', style: KnockText.caption),
                subtitle: Text(l.expiresAt == null ? 'Never' : PlFmt.dateTime(l.expiresAt!), style: KnockText.body),
                trailing: PopupMenuButton<int>(
                  icon: const Icon(Icons.schedule_rounded),
                  onSelected: (d) => _do(context, () => d == 0 ? sb.updateDetails(l, clearExpiry: true) : sb.updateDetails(l, expiresAt: sb.now.add(Duration(days: d))), 'Expiry updated'),
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 1, child: Text('24 hours from now')),
                    PopupMenuItem(value: 7, child: Text('7 days from now')),
                    PopupMenuItem(value: 30, child: Text('30 days from now')),
                    PopupMenuItem(value: 0, child: Text('No expiry')),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: KnockSpace.md),
        if (l.status == LinkStatus.active)
          KnockButton(
            label: 'Pause link',
            icon: Icons.pause_rounded,
            style: KnockButtonStyle.secondary,
            onPressed: () => _do(context, () => sb.setStatus(l, 'pause'), 'Link paused. Payers will see it is not accepting payments.'),
          ),
        if (l.status == LinkStatus.paused) KnockButton(label: 'Resume link', icon: Icons.play_arrow_rounded, onPressed: () => _do(context, () => sb.setStatus(l, 'resume'), 'Link resumed')),
        if (held > 0) ...[
          const SizedBox(height: KnockSpace.sm),
          KnockButton(
            label: 'Distribute ${PlFmt.money(held, l.asset, decimals: false)} now',
            icon: Icons.call_split_rounded,
            onPressed: () => _do(context, () => sb.distributeHeld(l), 'Distribution run'),
          ),
        ],
        const SectionHeader('Split rules'),
        KnockCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              KvRow('Method', l.splitMethod.label),
              KvRow('Distribution', l.settlementMode.label),
              KvRow('Fees', l.feeBearer.label),
              KvRow('Version', 'v${l.ruleVersion}'),
              for (final r in l.currentRules) KvRow('@${r.user.username}', PlFmt.percent(r.basisPoints)),
              const SizedBox(height: 6),
              Text(
                l.rulesLocked
                    ? 'Locked: payments have started. Changes apply to future payments only and need approval from anyone whose share goes down. Past splits never change.'
                    : 'Rules lock when the first payment arrives.',
                style: KnockText.micro,
              ),
            ],
          ),
        ),
        if (l.type == LinkType.split) ...[
          const SizedBox(height: KnockSpace.sm),
          KnockButton(label: 'Propose a split change', icon: Icons.edit_note_rounded, style: KnockButtonStyle.secondary, onPressed: pending.isEmpty ? () => _amend(context) : null),
        ],
        for (final m in pending)
          Padding(
            padding: const EdgeInsets.only(top: KnockSpace.sm),
            child: KnockCard(
              color: KnockColors.orangeSoft,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Waiting for approval: "${m.reason}"', style: KnockText.bodyStrong),
                  for (final e in m.approvers.entries)
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            '@${sb.user(e.key).username}: ${e.value == null
                                ? 'pending'
                                : e.value!
                                ? 'approved'
                                : 'rejected'}',
                            style: KnockText.caption,
                          ),
                        ),
                        if (e.value == null) TextButton(onPressed: () => sb.decideAmendment(m, e.key, true), child: const Text('Approve as them')),
                      ],
                    ),
                ],
              ),
            ),
          ),
        const SectionHeader('Sandbox controls'),
        Text('Freeze a recipient to see a failed credit roll back safely and retry.', style: KnockText.caption),
        for (final r in l.currentRules.where((r) => r.user.id != sb.me.id))
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: sb.user(r.user.id).frozen,
            activeThumbColor: KnockColors.loss,
            onChanged: (v) => sb.setFrozen(r.user.id, v),
            title: Text('Freeze @${r.user.username}', style: KnockText.body),
          ),
        TextButton(onPressed: () => _do(context, () => plToast(context, '${sb.retryFailed()} split(s) retried successfully'), 'Retry run'), child: const Text('Run retry job')),
        TextButton(
          onPressed: () => _do(context, () {
            l.expiresAt = sb.now.subtract(const Duration(seconds: 1));
            sb.runExpiry();
          }, 'Link expired'),
          child: const Text('Expire this link now'),
        ),
        if (l.status != LinkStatus.closed)
          TextButton(
            onPressed: () => _do(context, () => sb.setStatus(l, 'close'), 'Link closed'),
            child: const Text('Close link permanently', style: TextStyle(color: KnockColors.loss)),
          ),
      ],
    );
  }

  Future<void> _edit(BuildContext context, String label, String initial, void Function(String) save) async {
    final c = TextEditingController(text: initial);
    final v = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: KnockColors.surfaceRaised,
        title: Text(label),
        content: TextField(controller: c, autofocus: true, maxLines: null, decoration: plInput(label)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, c.text), child: const Text('Save')),
        ],
      ),
    );
    if (v != null && context.mounted) _do(context, () => save(v), 'Saved');
  }

  Future<void> _amend(BuildContext context) async {
    final isFixed = l.splitMethod == SplitMethod.fixed;
    final ctrls = {for (final r in l.currentRules) r.user.id: TextEditingController(text: isFixed ? PlFmt.major(r.allocated, l.asset) : (r.basisPoints / 100).toString())};
    final reason = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: KnockColors.surfaceRaised,
        title: const Text('Propose a split change'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Applies to future payments only. Set a share to 0 to remove someone.', style: KnockText.caption),
              const SizedBox(height: 8),
              for (final r in l.currentRules)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: TextField(
                    controller: ctrls[r.user.id],
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: plInput('@${r.user.username} ${isFixed ? 'amount' : '%'}'),
                  ),
                ),
              TextField(
                controller: reason,
                decoration: plInput('Reason', hint: 'e.g. Favour left the project'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Propose')),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    final input = <(KnockUser, int, int)>[];
    for (final r in l.currentRules) {
      final t = ctrls[r.user.id]!.text;
      if (isFixed) {
        final a = PlFmt.parse(t, l.asset) ?? 0;
        if (a > 0) input.add((r.user, a, 0));
      } else {
        final b = ((double.tryParse(t) ?? 0) * 100).round();
        if (b > 0) input.add((r.user, 0, b));
      }
    }
    _do(context, () {
      final m = sb.proposeAmendment(l, reason.text, input);
      if (m.status == 'applied') plToast(context, 'Split updated to v${l.ruleVersion}');
    }, 'Change proposed');
  }
}
