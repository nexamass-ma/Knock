import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../design/tokens.dart';
import '../../design/widgets/surfaces.dart';
import 'pl_models.dart';
import 'pl_sandbox.dart';
import 'pl_split.dart';
import 'pl_widgets.dart';

/// Create Payment Link, with progressive disclosure:
/// type → basics & amount → recipients (split only) → rules → review.
class CreateLinkFlow extends StatefulWidget {
  const CreateLinkFlow({super.key, required this.sandbox, this.initialType});
  final PlSandbox sandbox;
  final LinkType? initialType;

  @override
  State<CreateLinkFlow> createState() => _CreateLinkFlowState();
}

class _RecipientDraft {
  _RecipientDraft(this.user, {int amount = 0, int bps = 0})
    : amount = TextEditingController(text: amount == 0 ? '' : PlFmt.major(amount, PlAsset.ngn)),
      pct = TextEditingController(text: bps == 0 ? '' : PlFmt.percent(bps).replaceAll('%', ''));
  final KnockUser user;
  final TextEditingController amount;
  final TextEditingController pct;
}

enum _Step { type, basics, recipients, rules, review }

class _CreateLinkFlowState extends State<CreateLinkFlow> {
  PlSandbox get sb => widget.sandbox;
  _Step step = _Step.type;
  LinkType? type;
  final title = TextEditingController();
  final description = TextEditingController();
  final fixedAmount = TextEditingController();
  final target = TextEditingController();
  final invoice = TextEditingController();
  final instructions = TextEditingController();
  PlAsset asset = PlAsset.ngn;
  AmountMode amountMode = AmountMode.flexible;
  SplitMethod method = SplitMethod.fixed;
  SettlementMode settlement = SettlementMode.eachPayment;
  FeeBearer feeBearer = FeeBearer.deduct;
  bool remainderToCreator = false;
  bool requireRef = false;
  int? expiryDays = 30;
  bool confirmed = false;
  final recipients = <_RecipientDraft>[];
  String? error;

  // Username search.
  final search = TextEditingController();
  KnockUser? found;
  bool searching = false;
  String? searchMsg;

  @override
  void initState() {
    super.initState();
    if (widget.initialType != null) _pickType(widget.initialType!);
  }

  void _pickType(LinkType t) {
    setState(() {
      type = t;
      asset = t == LinkType.crypto ? PlAsset.crypto.first : PlAsset.ngn;
      amountMode = t == LinkType.split ? AmountMode.flexible : AmountMode.fixed;
      step = _Step.basics;
      if (t == LinkType.split && recipients.isEmpty) recipients.add(_RecipientDraft(sb.me));
    });
  }

  int? get _target => target.text.trim().isEmpty ? null : PlFmt.parse(target.text, asset);
  int? get _fixed => fixedAmount.text.trim().isEmpty ? null : PlFmt.parse(fixedAmount.text, asset);
  int _amt(_RecipientDraft r) => PlFmt.parse(r.amount.text, asset) ?? 0;
  int _bps(_RecipientDraft r) {
    final v = double.tryParse(r.pct.text.replaceAll('%', '').trim());
    return v == null ? 0 : (v * 100).round();
  }

  List<(KnockUser, int, int)> get _input => [for (final r in recipients) (r.user, _amt(r), _bps(r))];

  List<RecipientRule>? _rules() {
    try {
      return PlSplit.buildRules(creator: sb.me, method: method, target: _target, remainderToCreator: remainderToCreator, input: _input);
    } on PlException {
      return null;
    }
  }

  String? _validate(_Step s) {
    switch (s) {
      case _Step.type:
        return null;
      case _Step.basics:
        if (title.text.trim().isEmpty) return 'Give your link a name people will recognise.';
        if (amountMode == AmountMode.fixed && (_fixed == null || _fixed! <= 0)) return 'Enter the amount each payer pays.';
        if (target.text.trim().isNotEmpty && (_target == null || _target! <= 0)) return 'Enter a valid total.';
        if (type == LinkType.split && method == SplitMethod.fixed && _target == null) {
          return 'Set the total amount to collect. You can switch to a percentage split later if there is no fixed total.';
        }
        if (amountMode == AmountMode.fixed && _target != null && _fixed! > _target!) return 'The amount per payer is more than the total.';
        return null;
      case _Step.recipients:
        if (method == SplitMethod.fixed && _target == null) return 'A fixed split needs a total. Go back and set one, or use percentages.';
        try {
          PlSplit.buildRules(creator: sb.me, method: method, target: _target, remainderToCreator: remainderToCreator, input: _input);
          return null;
        } on PlException catch (e) {
          return e.message;
        }
      case _Step.rules:
        if (settlement == SettlementMode.onTarget && _target == null) return 'Collect-then-split needs a total target.';
        return null;
      case _Step.review:
        return confirmed ? null : 'Tick the box to confirm the split rules.';
    }
  }

  void _next() {
    final e = _validate(step);
    if (e != null) {
      setState(() => error = e);
      HapticFeedback.mediumImpact();
      return;
    }
    setState(() {
      error = null;
      step = switch (step) {
        _Step.type => _Step.basics,
        _Step.basics => type == LinkType.split ? _Step.recipients : _Step.rules,
        _Step.recipients => _Step.rules,
        _Step.rules => _Step.review,
        _Step.review => _Step.review,
      };
    });
    if (step == _Step.review && error == null && confirmed) _create();
  }

  void _back() {
    if (step == _Step.type || (step == _Step.basics && widget.initialType != null)) {
      Navigator.of(context).pop();
      return;
    }
    setState(() {
      error = null;
      step = switch (step) {
        _Step.basics => _Step.type,
        _Step.recipients => _Step.basics,
        _Step.rules => type == LinkType.split ? _Step.recipients : _Step.basics,
        _Step.review => _Step.rules,
        _Step.type => _Step.type,
      };
    });
  }

  void _create() {
    try {
      final l = sb.createLink(
        type: type!,
        title: title.text,
        description: description.text,
        asset: asset,
        amountMode: amountMode,
        fixedAmount: _fixed,
        target: _target,
        splitMethod: method,
        settlementMode: settlement,
        feeBearer: feeBearer,
        remainderToCreator: remainderToCreator,
        recipients: _input,
        expiresAt: expiryDays == null ? null : sb.now.add(Duration(days: expiryDays!)),
        requireCustomerReference: requireRef,
        invoiceNumber: invoice.text.trim().isEmpty ? null : invoice.text.trim(),
        instructions: instructions.text.trim().isEmpty ? null : instructions.text.trim(),
      );
      HapticFeedback.heavyImpact();
      Navigator.of(context).pop(l);
    } on PlException catch (e) {
      setState(() => error = e.message);
    }
  }

  Future<void> _lookup() async {
    final q = search.text.trim();
    if (q.isEmpty) return;
    setState(() {
      searching = true;
      found = null;
      searchMsg = null;
    });
    final u = await sb.lookup(q);
    if (!mounted || search.text.trim() != q) return;
    setState(() {
      searching = false;
      found = u;
      searchMsg = u == null
          ? 'No Knock user is called @${q.replaceFirst('@', '')}.'
          : !u.verified
          ? '@${u.username} has not verified their account yet, so they cannot receive splits.'
          : recipients.any((r) => r.user.id == u.id)
          ? '@${u.username} is already in this split.'
          : null;
    });
  }

  void _add(KnockUser u) {
    setState(() {
      recipients.add(_RecipientDraft(u));
      search.clear();
      found = null;
      searchMsg = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final steps = type == LinkType.split ? 4 : 3;
    final idx = switch (step) {
      _Step.type => 0,
      _Step.basics => 1,
      _Step.recipients => 2,
      _Step.rules => type == LinkType.split ? 3 : 2,
      _Step.review => steps,
    };
    return PopScope(
      canPop: step == _Step.type,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _back();
      },
      child: Scaffold(
        backgroundColor: KnockColors.background,
        appBar: AppBar(
          backgroundColor: KnockColors.background,
          leading: IconButton(icon: const Icon(Icons.arrow_back_rounded), onPressed: _back, tooltip: 'Back'),
          title: Text(switch (step) {
            _Step.type => 'Create payment link',
            _Step.basics => type == LinkType.split ? 'Split payment' : type!.label,
            _Step.recipients => 'Add recipients',
            _Step.rules => 'Payout rules',
            _Step.review => 'Review and create',
          }),
          bottom: step == _Step.type
              ? null
              : PreferredSize(
                  preferredSize: const Size.fromHeight(4),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: KnockSpace.gutter),
                    child: ProgressBar(idx / steps, height: 4),
                  ),
                ),
        ),
        body: SafeArea(
          child: Column(
            children: [
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(KnockSpace.gutter, KnockSpace.md, KnockSpace.gutter, KnockSpace.xl),
                  children: switch (step) {
                    _Step.type => _typeStep(),
                    _Step.basics => _basicsStep(),
                    _Step.recipients => _recipientsStep(),
                    _Step.rules => _rulesStep(),
                    _Step.review => _reviewStep(),
                  },
                ),
              ),
              if (step != _Step.type)
                Padding(
                  padding: const EdgeInsets.fromLTRB(KnockSpace.gutter, 0, KnockSpace.gutter, KnockSpace.md),
                  child: Column(
                    children: [
                      if (error != null)
                        Padding(
                          padding: const EdgeInsets.only(bottom: KnockSpace.sm),
                          child: Row(
                            children: [
                              const Icon(Icons.error_outline_rounded, color: KnockColors.loss, size: 18),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(error!, style: KnockText.caption.copyWith(color: KnockColors.loss)),
                              ),
                            ],
                          ),
                        ),
                      KnockButton(
                        label: step == _Step.review ? 'Create link' : 'Continue',
                        icon: step == _Step.review ? Icons.check_rounded : Icons.arrow_forward_rounded,
                        onPressed: _next,
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  // ------------------------------------------------------------ steps

  List<Widget> _typeStep() => [
    Text('What do you want to collect?', style: KnockText.title),
    const SizedBox(height: 6),
    Text('You can share any link by WhatsApp, SMS, email or QR code.', style: KnockText.caption),
    const SizedBox(height: KnockSpace.lg),
    for (final t in LinkType.values)
      ChoiceCard(
        title: t.label,
        subtitle: t.blurb,
        icon: linkTypeIcon(t),
        badge: t == LinkType.split ? 'SMART SPLIT' : null,
        selected: type == t,
        onTap: () => _pickType(t),
      ),
    const SizedBox(height: KnockSpace.md),
    const SandboxBanner(),
  ];

  List<Widget> _basicsStep() {
    final isSplit = type == LinkType.split;
    return [
      TextField(
        controller: title,
        maxLength: 80,
        decoration: plInput('Link name', hint: isSplit ? 'e.g. Project Alpha' : 'e.g. Ankara tote bag'),
      ),
      const SizedBox(height: KnockSpace.xs),
      TextField(
        controller: description,
        maxLength: 500,
        maxLines: 2,
        decoration: plInput('Description (optional)', hint: 'What is this payment for?'),
      ),
      const SizedBox(height: KnockSpace.md),
      if (type == LinkType.crypto || isSplit) ...[
        Text(isSplit ? 'Currency' : 'Coin and network', style: KnockText.bodyStrong),
        const SizedBox(height: KnockSpace.xs),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final a in [if (isSplit) PlAsset.ngn, ...PlAsset.crypto])
              ChoiceChip(
                label: Text(a.label),
                selected: asset == a,
                onSelected: (_) => setState(() => asset = a),
                selectedColor: KnockColors.green,
                showCheckmark: false,
                labelStyle: KnockText.caption.copyWith(
                  color: asset == a ? KnockColors.onGreen : KnockColors.textPrimary,
                  fontWeight: FontWeight.w600,
                ),
                backgroundColor: KnockColors.surface,
                side: const BorderSide(color: KnockColors.stroke),
              ),
          ],
        ),
        if (!asset.isFiat)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              'Payers must send ${asset.code} on ${asset.network} only. Funds are credited after ${asset.confirmations} confirmations.',
              style: KnockText.caption.copyWith(color: KnockColors.orange),
            ),
          ),
        const SizedBox(height: KnockSpace.md),
      ],
      if (isSplit) ...[
        Text('Step 1 · Total to collect', style: KnockText.bodyStrong),
        const SizedBox(height: KnockSpace.xs),
        TextField(
          controller: target,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: plInput(
            'Total amount',
            prefix: asset.isFiat ? '₦ ' : null,
            hint: asset.isFiat ? '500,000' : '1,000',
            helper: 'Needed for a fixed split. Optional for a percentage split.',
          ),
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: KnockSpace.md),
        Text('How should payers pay?', style: KnockText.bodyStrong),
        const SizedBox(height: KnockSpace.xs),
      ],
      PillTabs<AmountMode>(
        values: AmountMode.values,
        selected: amountMode,
        labelOf: (m) => m == AmountMode.fixed ? 'Fixed amount' : 'Payer enters amount',
        onChanged: (m) => setState(() => amountMode = m),
      ),
      const SizedBox(height: KnockSpace.sm),
      if (amountMode == AmountMode.fixed)
        TextField(
          controller: fixedAmount,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: plInput(
            'Amount each payer pays',
            prefix: asset.isFiat ? '₦ ' : null,
            helper: asset.isFiat ? null : 'In ${asset.code}',
          ),
          onChanged: (_) => setState(() {}),
        )
      else
        Text('Each payer types how much they are paying.', style: KnockText.caption),
      if (!isSplit) ...[
        const SizedBox(height: KnockSpace.md),
        TextField(
          controller: target,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: plInput(
            'Collection target (optional)',
            prefix: asset.isFiat ? '₦ ' : null,
            helper: 'Set a target to track progress from several payers. The link completes when it is reached.',
          ),
        ),
      ],
    ];
  }

  List<Widget> _recipientsStep() {
    final t = _target;
    final allocatedAmt = recipients.fold<int>(0, (a, r) => a + _amt(r));
    final allocatedBps = recipients.fold<int>(0, (a, r) => a + _bps(r));
    final ok = method == SplitMethod.fixed ? (t != null && allocatedAmt == t) : allocatedBps == 10000;
    final over = method == SplitMethod.fixed ? (t != null && allocatedAmt > t) : allocatedBps > 10000;
    return [
      Text('Step 2 · Who gets paid?', style: KnockText.bodyStrong),
      const SizedBox(height: KnockSpace.xs),
      Row(
        children: [
          Expanded(
            child: TextField(
              controller: search,
              autocorrect: false,
              textInputAction: TextInputAction.search,
              decoration: plInput('Knock username', prefix: '@ ', hint: 'mary'),
              onChanged: (v) {
                if (v.trim().length >= 3) _lookup();
              },
              onSubmitted: (_) => _lookup(),
            ),
          ),
        ],
      ),
      if (searching)
        const Padding(
          padding: EdgeInsets.all(12),
          child: LinearProgressIndicator(color: KnockColors.green),
        ),
      if (found != null)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: KnockCard(
            child: Row(
              children: [
                UserAvatar(found!),
                const SizedBox(width: KnockSpace.sm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(child: Text(found!.displayName, style: KnockText.bodyStrong)),
                          const SizedBox(width: 6),
                          if (found!.verified) const Icon(Icons.verified_rounded, size: 16, color: KnockColors.greenBright),
                        ],
                      ),
                      Text('@${found!.username}', style: KnockText.caption),
                    ],
                  ),
                ),
                if (searchMsg == null) KnockButton(label: 'Add', expand: false, icon: Icons.add_rounded, onPressed: () => _add(found!)),
              ],
            ),
          ),
        ),
      if (searchMsg != null)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(searchMsg!, style: KnockText.caption.copyWith(color: KnockColors.orange)),
        ),
      if (sb.templates.isNotEmpty) ...[
        const SizedBox(height: KnockSpace.sm),
        Wrap(
          spacing: 8,
          children: [
            for (final tpl in sb.templates)
              ActionChip(
                avatar: const Icon(Icons.group_outlined, size: 16, color: KnockColors.greenBright),
                label: Text('Use "${tpl.name}"'),
                backgroundColor: KnockColors.surface,
                side: const BorderSide(color: KnockColors.stroke),
                onPressed: () => setState(() {
                  method = tpl.method;
                  recipients
                    ..clear()
                    ..addAll([for (final (u, a, b) in tpl.members) _RecipientDraft(u, amount: a, bps: b)]);
                }),
              ),
          ],
        ),
      ],
      const SizedBox(height: KnockSpace.lg),
      Text('Step 3 · How much each person gets', style: KnockText.bodyStrong),
      const SizedBox(height: KnockSpace.xs),
      PillTabs<SplitMethod>(
        values: SplitMethod.values,
        selected: method,
        labelOf: (m) => m == SplitMethod.fixed ? 'Fixed amounts' : 'Percentages',
        onChanged: (m) => setState(() => method = m),
      ),
      const SizedBox(height: 6),
      Text(method.blurb, style: KnockText.caption),
      const SizedBox(height: KnockSpace.sm),
      for (final r in recipients) _recipientRow(r, t),
      const SizedBox(height: KnockSpace.sm),
      KnockCard(
        color: ok ? KnockColors.greenSoft : (over ? const Color(0x33FF6B6B) : KnockColors.surface),
        child: Column(
          children: [
            KvRow(
              'Total allocated',
              method == SplitMethod.fixed
                  ? '${PlFmt.money(allocatedAmt, asset, decimals: false)}${t != null ? ' of ${PlFmt.money(t, asset, decimals: false)}' : ''}'
                  : '${PlFmt.percent(allocatedBps)} of 100%',
              strong: true,
              valueColor: ok ? KnockColors.greenBright : (over ? KnockColors.loss : null),
            ),
            if (!ok)
              KvRow(
                over ? 'Over by' : 'Left to allocate',
                method == SplitMethod.fixed
                    ? PlFmt.money(((t ?? 0) - allocatedAmt).abs(), asset, decimals: false)
                    : PlFmt.percent((10000 - allocatedBps).abs()),
                valueColor: over ? KnockColors.loss : KnockColors.orange,
              ),
          ],
        ),
      ),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        value: remainderToCreator,
        activeThumbColor: KnockColors.green,
        onChanged: (v) => setState(() => remainderToCreator = v),
        title: Text('Partial allocation', style: KnockText.bodyStrong),
        subtitle: Text('Anything not allocated goes to you (@${sb.me.username}).', style: KnockText.caption),
      ),
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          onPressed: recipients.isEmpty ? null : _saveGroup,
          icon: const Icon(Icons.bookmark_add_outlined, color: KnockColors.greenBright),
          label: Text('Save as a reusable group', style: KnockText.caption.copyWith(color: KnockColors.greenBright)),
        ),
      ),
    ];
  }

  Widget _recipientRow(_RecipientDraft r, int? t) {
    final amt = _amt(r);
    final bps = _bps(r);
    final derived = method == SplitMethod.fixed
        ? (t == null || t == 0 ? '–' : PlFmt.percent((amt * 10000 / t).round()))
        : (t == null ? 'of every payment' : PlFmt.money(PlSplit.splitAmount(t, [bps, 10000 - bps])[0], asset, decimals: false));
    final estNet = method == SplitMethod.fixed ? amt : (t == null ? 0 : (t * bps ~/ 10000));
    final net = feeBearer == FeeBearer.deduct ? estNet - PlSplit.fee(asset, estNet) : estNet;
    return Padding(
      padding: const EdgeInsets.only(bottom: KnockSpace.xs),
      child: KnockCard(
        padding: const EdgeInsets.fromLTRB(KnockSpace.sm, KnockSpace.sm, 4, KnockSpace.sm),
        child: Column(
          children: [
            Row(
              children: [
                UserAvatar(r.user, size: 34),
                const SizedBox(width: KnockSpace.sm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(r.user.id == sb.me.id ? '${r.user.displayName} (you)' : r.user.displayName, style: KnockText.bodyStrong),
                      Text('@${r.user.username} · ${asset.code} wallet', style: KnockText.micro),
                    ],
                  ),
                ),
                SizedBox(
                  width: method == SplitMethod.fixed ? 120 : 84,
                  child: TextField(
                    controller: method == SplitMethod.fixed ? r.amount : r.pct,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    textAlign: TextAlign.right,
                    style: KnockText.number,
                    decoration: plInput(
                      method == SplitMethod.fixed ? 'Amount' : '%',
                      prefix: method == SplitMethod.fixed && asset.isFiat ? '₦' : null,
                    ).copyWith(isDense: true),
                    onChanged: (_) => setState(() {}),
                  ),
                ),
                IconButton(
                  tooltip: 'Remove @${r.user.username}',
                  icon: const Icon(Icons.close_rounded, size: 18, color: KnockColors.textTertiary),
                  onPressed: () => setState(() => recipients.remove(r)),
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(left: 46, right: 12, top: 4),
              child: Row(
                children: [
                  Text(method == SplitMethod.fixed ? derived : derived, style: KnockText.micro.copyWith(color: KnockColors.greenBright)),
                  const Spacer(),
                  if (estNet > 0) Text('≈ ${PlFmt.money(net, asset, decimals: false)} after fees', style: KnockText.micro),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _saveGroup() async {
    final c = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: KnockColors.surfaceRaised,
        title: const Text('Save group'),
        content: TextField(
          controller: c,
          autofocus: true,
          decoration: plInput('Group name', hint: 'Agency Team, Event Team …'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, c.text), child: const Text('Save')),
        ],
      ),
    );
    if (name == null || name.trim().isEmpty || !mounted) return;
    sb.saveTemplate(name, method, _input);
    plToast(context, 'Saved "$name". Reuse it on your next split.');
  }

  List<Widget> _rulesStep() {
    final isSplit = type == LinkType.split;
    final auto = settlement == SettlementMode.eachPayment;
    return [
      if (isSplit) ...[
        Text('Step 4 · When does money go out?', style: KnockText.bodyStrong),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: auto,
          activeThumbColor: KnockColors.green,
          onChanged: (v) => setState(() => settlement = v ? SettlementMode.eachPayment : SettlementMode.manual),
          title: Text('Automatic distribution', style: KnockText.bodyStrong),
          subtitle: Text(
            auto
                ? 'Every verified payment is split and credited to recipients straight away.'
                : 'Payments wait in your collection balance.',
            style: KnockText.caption,
          ),
        ),
        if (!auto)
          for (final m in [SettlementMode.onTarget, SettlementMode.manual])
            ChoiceCard(title: m.label, subtitle: m.blurb, selected: settlement == m, onTap: () => setState(() => settlement = m)),
        const SizedBox(height: KnockSpace.md),
      ],
      Text('Who pays the Knock fee?', style: KnockText.bodyStrong),
      const SizedBox(height: 4),
      Text(
        'Knock fee: ${asset.isFiat ? '1.5% per payment, capped at ₦2,000' : '1% per payment'}. [Sandbox fee: final pricing to be confirmed]',
        style: KnockText.caption,
      ),
      const SizedBox(height: KnockSpace.xs),
      for (final f in FeeBearer.values)
        ChoiceCard(title: f.label, subtitle: f.blurb, selected: feeBearer == f, onTap: () => setState(() => feeBearer = f)),
      const SizedBox(height: KnockSpace.md),
      Text('Link expiry', style: KnockText.bodyStrong),
      const SizedBox(height: KnockSpace.xs),
      Wrap(
        spacing: 8,
        children: [
          for (final d in [1, 7, 30, null])
            ChoiceChip(
              label: Text(
                d == null
                    ? 'No expiry'
                    : d == 1
                    ? '24 hours'
                    : '$d days',
              ),
              selected: expiryDays == d,
              onSelected: (_) => setState(() => expiryDays = d),
              selectedColor: KnockColors.green,
              showCheckmark: false,
              labelStyle: KnockText.caption.copyWith(
                color: expiryDays == d ? KnockColors.onGreen : KnockColors.textPrimary,
                fontWeight: FontWeight.w600,
              ),
              backgroundColor: KnockColors.surface,
              side: const BorderSide(color: KnockColors.stroke),
            ),
        ],
      ),
      const SizedBox(height: KnockSpace.sm),
      Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: EdgeInsets.zero,
          title: Text('More options', style: KnockText.bodyStrong),
          subtitle: Text('Invoice number, customer reference, payment instructions', style: KnockText.caption),
          children: [
            TextField(controller: invoice, decoration: plInput('Invoice number (optional)')),
            const SizedBox(height: KnockSpace.sm),
            TextField(
              controller: instructions,
              maxLines: 2,
              maxLength: 500,
              decoration: plInput('Payment instructions (optional)', hint: 'e.g. Use your order number as the reference'),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: requireRef,
              activeThumbColor: KnockColors.green,
              onChanged: (v) => setState(() => requireRef = v),
              title: Text('Ask payers for a reference', style: KnockText.body),
            ),
          ],
        ),
      ),
    ];
  }

  List<Widget> _reviewStep() {
    final isSplit = type == LinkType.split;
    final rules = isSplit ? _rules() ?? [] : [RecipientRule(user: sb.me, allocated: _target ?? 0, basisPoints: 10000)];
    final sample = _fixed ?? _target ?? (asset.isFiat ? 10000000 : 100 * 1000000);
    final fee = PlSplit.fee(asset, sample);
    final preview = PlSplit.previewPayment(
      method: isSplit ? method : SplitMethod.percentage,
      rules: rules,
      creator: sb.me,
      amount: sample,
      knockFee: fee,
      feeBearer: feeBearer,
    );
    return [
      Text(title.text.trim(), style: KnockText.title),
      if (description.text.trim().isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(description.text.trim(), style: KnockText.caption),
        ),
      const SizedBox(height: KnockSpace.md),
      KnockCard(
        child: Column(
          children: [
            KvRow('Link type', type!.label),
            KvRow('Currency', asset.label),
            KvRow('Payment methods', asset.isFiat ? 'Bank transfer, card, USSD' : '${asset.code} on ${asset.network}'),
            KvRow('Amount', amountMode == AmountMode.fixed ? '${PlFmt.money(_fixed!, asset)} per payer' : 'Payer enters amount'),
            KvRow('Total expected', _target == null ? 'No target' : PlFmt.money(_target!, asset), strong: true),
            if (isSplit) KvRow('Recipients', '${rules.length}'),
            if (isSplit) KvRow('Split rule', method.label),
            KvRow('Distribution', settlement.label),
            KvRow('Fees', '${feeBearer.label} · ${asset.isFiat ? '1.5%, max ₦2,000' : '1%'}'),
            KvRow('Expiry', expiryDays == null ? 'Never' : PlFmt.date(sb.now.add(Duration(days: expiryDays!)))),
          ],
        ),
      ),
      if (isSplit) ...[
        SectionHeader('Allocations'),
        for (final r in rules)
          KnockCard(
            padding: const EdgeInsets.symmetric(horizontal: KnockSpace.md, vertical: KnockSpace.sm),
            child: Row(
              children: [
                UserAvatar(r.user, size: 32),
                const SizedBox(width: KnockSpace.sm),
                Expanded(child: Text('@${r.user.username}${r.isCreatorRemainder ? ' (remainder)' : ''}', style: KnockText.body)),
                Text(
                  method == SplitMethod.fixed
                      ? '${PlFmt.money(r.allocated, asset, decimals: false)} · ${PlFmt.percent(r.basisPoints)}'
                      : PlFmt.percent(r.basisPoints),
                  style: KnockText.number,
                ),
              ],
            ),
          ),
      ],
      SectionHeader('If someone pays ${PlFmt.money(sample, asset, decimals: false)}'),
      KnockCard(
        child: Column(
          children: [
            if (feeBearer == FeeBearer.payer) KvRow('Payer pays', PlFmt.money(sample + fee, asset)),
            KvRow('Knock fee', PlFmt.money(fee, asset)),
            const Divider(color: KnockColors.stroke),
            for (final s in preview)
              KvRow('@${s.user.username}${s.overflow ? ' (overflow)' : ''} receives', PlFmt.money(s.gross - s.fee, asset), strong: true),
          ],
        ),
      ),
      const SizedBox(height: KnockSpace.sm),
      Text(
        feeBearer == FeeBearer.deduct
            ? 'Fees are deducted before the split and shared in proportion to each person\'s share.'
            : 'The payer pays the fee on top, so recipients receive their full share.',
        style: KnockText.caption,
      ),
      const SizedBox(height: KnockSpace.md),
      CheckboxListTile(
        contentPadding: EdgeInsets.zero,
        controlAffinity: ListTileControlAffinity.leading,
        activeColor: KnockColors.green,
        value: confirmed,
        onChanged: (v) => setState(() {
          confirmed = v ?? false;
          error = null;
        }),
        title: Text(
          isSplit
              ? 'I confirm these split rules. Once the first payment arrives they lock, and changes need approval from anyone whose share goes down.'
              : 'I confirm these payment details.',
          style: KnockText.caption.copyWith(color: KnockColors.textPrimary),
        ),
      ),
    ];
  }
}
