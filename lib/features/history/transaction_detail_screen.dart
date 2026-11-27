import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:material_ui/material_ui.dart';

import '../../api/api.dart';
import '../../app/app_controller.dart';
import '../../core/format.dart';
import '../../design/tokens.dart';
import '../../design/widgets/kit.dart';
import '../common/pin_sheet.dart';
import '../common/receipt.dart';
import '../shell/nav.dart';
import '../support/support_screen.dart';
import 'txn_tile.dart';

const _tradeSteps = ['submitted', 'received', 'under_review', 'approved', 'payment_processing', 'completed'];

class TransactionDetailScreen extends StatelessWidget {
  const TransactionDetailScreen({super.key, required this.txnId});
  final String txnId;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Transaction')),
      body: ApiView(
        load: (api) => api.call((s, t) => s.transaction(t!, txnId)),
        builder: (context, d, reload) {
          final t = d['txn'] as Json;
          final dispute = d['dispute'] as Json?;
          final details = Map<String, dynamic>.from(t['details'] as Map);
          final credit = t['direction'] == 'credit';
          final amount = t['amount'] as int;
          final isTrade = t['type'] == 'giftcard_sell' && details['quoteId'] != null && t['status'] != 'cancelled';
          final tracker = details['tracker'] as String?;
          return ListView(padding: const EdgeInsets.fromLTRB(KnockSpace.gutter, 8, KnockSpace.gutter, 32), children: [
            Center(child: Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(color: KnockColors.surfaceRaised, borderRadius: BorderRadius.circular(18)),
              child: Icon(txnIcon(t['type'] as String), color: KnockColors.greenBright),
            )),
            const SizedBox(height: 12),
            Text(t['title'] as String, style: KnockText.headline, textAlign: TextAlign.center),
            const SizedBox(height: 6),
            Text(amount == 0 ? '—' : F.signed(amount, credit: credit), style: KnockText.display, textAlign: TextAlign.center),
            const SizedBox(height: 8),
            Center(child: StatusChip(tracker == 'action_required' ? 'action_required' : t['status'] as String, label: tracker != null && t['status'] == 'pending' ? trackerLabel(tracker) : F.status(t['status'] as String))),
            if (tracker == 'action_required') ...[
              const SizedBox(height: 16),
              _ActionRequired(txn: t, onDone: reload),
            ],
            if (isTrade) ...[
              const SectionTitle('Trade tracker'),
              _Tracker(tracker: tracker ?? 'submitted', timeline: (t['timeline'] as List).cast<Map>(), failed: t['status'] == 'failed' || t['status'] == 'reversed'),
            ] else ...[
              const SectionTitle('Timeline'),
              for (final s in (t['timeline'] as List).cast<Map>())
                ListRow(dense: true, icon: Icons.check_circle_outline_rounded, iconColor: KnockColors.greenBright, title: s['label'] as String, subtitle: '${F.dateTime(s['at'] as String)}${s['note'] != null ? '\n${s['note']}' : ''}'),
            ],
            const SectionTitle('Details'),
            KnockCard(child: Column(children: [
              KeyValue('Reference', t['reference'] as String, copy: true),
              KeyValue('Transaction ID', t['id'] as String, copy: true),
              KeyValue('Date and time', F.dateTime(t['createdAt'] as String)),
              KeyValue('Type', F.txnType(t['type'] as String)),
              if (t['subtitle'] != null) KeyValue('Description', t['subtitle'] as String),
              KeyValue('Amount', F.ngnExact(amount.abs())),
              KeyValue('Fees', F.ngnExact(t['fee'] as int? ?? 0)),
              KeyValue('Status', F.status(t['status'] as String)),
              ..._detailRows(details),
            ])),
            if (t['type'] == 'electricity' && details['token'] != null) ...[
              const SizedBox(height: 12),
              KnockCard(color: KnockColors.greenSoft, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Your token', style: KnockText.caption),
                const SizedBox(height: 4),
                SelectableText(details['token'] as String, style: KnockText.title),
                Text('${details['units']}', style: KnockText.caption),
                TextButton.icon(onPressed: () {
                  Clipboard.setData(ClipboardData(text: (details['token'] as String).replaceAll('-', '')));
                  toast(context, 'Token copied');
                }, icon: const Icon(Icons.copy_rounded, size: 16), label: const Text('Copy token')),
              ])),
            ],
            if (t['type'] == 'epin') _EpinReveal(txnId: t['id'] as String),
            if (t['type'] == 'esim') _EsimInstall(details: details),
            if (dispute != null) ...[
              const SizedBox(height: 16),
              KnockCard(
                onTap: () => go(context, TicketScreen(ticketId: dispute['id'] as String)),
                child: Row(children: [
                  const Icon(Icons.gavel_rounded, color: KnockColors.orange),
                  const SizedBox(width: 12),
                  Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('Case ${dispute['reference']}', style: KnockText.bodyStrong),
                    Text('${dispute['category']} · updated ${F.ago(dispute['updatedAt'] as String)}', style: KnockText.caption),
                  ])),
                  StatusChip(dispute['status'] as String),
                ]),
              ),
            ],
            const SizedBox(height: 20),
            KnockButton(key: const ValueKey('txn-receipt'), label: 'Download receipt', icon: Icons.download_rounded, style: KnockButtonStyle.secondary, onPressed: () => shareReceipt(context, t)),
            const SizedBox(height: 10),
            if (dispute == null)
              KnockButton(key: const ValueKey('txn-report'), label: 'Report a problem', icon: Icons.flag_outlined, style: KnockButtonStyle.ghost, onPressed: () => go(context, ReportProblemScreen(txn: t))),
          ]);
        },
      ),
    );
  }

  List<Widget> _detailRows(Map<String, dynamic> d) {
    const labels = {
      'brand': 'Brand',
      'currency': 'Card currency',
      'cardType': 'Card type',
      'settlement': 'Settlement',
      'customer': 'Customer',
      'customerName': 'Name on account',
      'plan': 'Plan',
      'bank': 'Bank',
      'accountName': 'Account name',
      'asset': 'Asset',
      'quantity': 'Quantity',
      'price': 'Price',
      'rate': 'Rate',
      'method': 'Method',
      'network': 'Network',
      'reason': 'Reason',
      'failReason': 'Reason',
      'recipient': 'Recipient',
      'package': 'Package',
      'rule': 'Rule',
    };
    final rows = <Widget>[];
    if (d['rateKobo'] != null && d['currency'] != null) rows.add(KeyValue('Rate', F.rate(d['rateKobo'] as int, d['currency'] as String)));
    if (d['faceValue'] != null && d['currency'] != null) rows.add(KeyValue('Card value', F.face(d['currency'] as String, d['faceValue'] as int)));
    for (final e in labels.entries) {
      final v = d[e.key];
      if (v == null || v.toString().isEmpty) continue;
      rows.add(KeyValue(e.value, e.key == 'cardType' ? (v == 'ecode' ? 'E-code' : 'Physical') : v.toString()));
    }
    final acc = (d['acceptances'] as List?)?.cast<Map>() ?? const [];
    for (final a in acc) {
      rows.add(KeyValue('Rate change accepted', '${F.ngnExact(a['oldNetKobo'] as int)} → ${F.ngnExact(a['newNetKobo'] as int)} · ${F.dateTime(a['at'] as String)}'));
    }
    return rows;
  }
}

class _Tracker extends StatelessWidget {
  const _Tracker({required this.tracker, required this.timeline, required this.failed});
  final String tracker;
  final List<Map> timeline;
  final bool failed;

  @override
  Widget build(BuildContext context) {
    final current = tracker == 'action_required' ? _tradeSteps.indexOf('under_review') : _tradeSteps.indexOf(tracker);
    DateTime? at(String label) {
      final m = timeline.lastWhere((s) => s['label'] == label, orElse: () => const {});
      return m['at'] == null ? null : DateTime.parse(m['at'] as String);
    }

    return KnockCard(
      child: Column(children: [
        for (var i = 0; i < _tradeSteps.length; i++)
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Column(children: [
              AnimatedContainer(
                duration: KnockMotion.slow,
                width: 22,
                height: 22,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: i <= current && !failed ? KnockColors.green : (failed && i == current + 1 ? KnockColors.loss : KnockColors.surfaceHigh),
                ),
                child: Icon(i < current || tracker == 'completed' ? Icons.check_rounded : (failed && i == current + 1 ? Icons.close_rounded : Icons.circle), size: i < current || tracker == 'completed' || (failed && i == current + 1) ? 14 : 6, color: Colors.white),
              ),
              if (i < _tradeSteps.length - 1) Container(width: 2, height: 30, color: i < current ? KnockColors.green : KnockColors.surfaceHigh),
            ]),
            const SizedBox(width: 12),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(top: 1),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(trackerLabel(_tradeSteps[i]), style: i <= current ? KnockText.bodyStrong : KnockText.body.copyWith(color: KnockColors.textTertiary)),
                  if (at(trackerLabel(_tradeSteps[i])) case final d?) Text(F.dateTime(d.toIso8601String()), style: KnockText.micro.copyWith(fontWeight: FontWeight.w400)),
                ]),
              ),
            ),
          ]),
        if (failed) ...[
          const SizedBox(height: 8),
          Note(timeline.last['note'] as String? ?? 'This trade could not be completed.', color: KnockColors.loss, icon: Icons.error_outline_rounded),
        ],
      ]),
    );
  }
}

class _ActionRequired extends StatefulWidget {
  const _ActionRequired({required this.txn, required this.onDone});
  final Json txn;
  final Future<void> Function() onDone;
  @override
  State<_ActionRequired> createState() => _ActionRequiredState();
}

class _ActionRequiredState extends State<_ActionRequired> {
  final _files = <String>[];
  final _note = TextEditingController();
  bool _busy = false;

  Future<void> _add() async {
    try {
      final x = await ImagePicker().pickImage(source: ImageSource.gallery, imageQuality: 70);
      if (x != null) setState(() => _files.add(x.name));
    } catch (_) {
      setState(() => _files.add('sandbox_extra_${_files.length + 1}.jpg'));
    }
  }

  Future<void> _send() async {
    setState(() => _busy = true);
    try {
      await context.api.call((s, t) => s.respondToTradeAction(t!, widget.txn['id'] as String, attachments: List.of(_files), note: _note.text));
      if (!mounted) return;
      context.app.poke();
      toast(context, 'Thanks. Your trade is back under review.');
      await widget.onDone();
    } catch (e) {
      if (mounted) showApiError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final need = (widget.txn['details'] as Map)['actionNeeded'] as String? ?? 'We need a little more information.';
    return KnockCard(
      color: KnockColors.orangeSoft,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Icon(Icons.priority_high_rounded, color: KnockColors.orange),
          const SizedBox(width: 8),
          Text('We need something from you', style: KnockText.bodyStrong),
        ]),
        const SizedBox(height: 6),
        Text(need, style: KnockText.body),
        const SizedBox(height: 10),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final f in _files) Chip(label: Text(f), onDeleted: () => setState(() => _files.remove(f))),
          ActionChip(key: const ValueKey('action-add-photo'), avatar: const Icon(Icons.add_a_photo_outlined, size: 18), label: const Text('Add photo'), onPressed: _add),
        ]),
        const SizedBox(height: 10),
        KField(label: 'Note (optional)', controller: _note, maxLines: 2),
        KnockButton(key: const ValueKey('action-send'), label: 'Send to review team', loading: _busy, onPressed: _send),
      ]),
    );
  }
}

class _EpinReveal extends StatefulWidget {
  const _EpinReveal({required this.txnId});
  final String txnId;
  @override
  State<_EpinReveal> createState() => _EpinRevealState();
}

class _EpinRevealState extends State<_EpinReveal> {
  List<String>? _pins;
  List<String>? _serials;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: KnockCard(
        child: _pins == null
            ? Row(children: [
                const Icon(Icons.lock_outline_rounded, color: KnockColors.textSecondary),
                const SizedBox(width: 12),
                Expanded(child: Text('Your PIN codes are encrypted.', style: KnockText.body)),
                KnockButton(
                  key: const ValueKey('epin-reveal'),
                  label: 'Reveal',
                  expand: false,
                  onPressed: () async {
                    try {
                      final r = await withPin<Json>(context, title: 'Reveal PINs', action: (pin) => context.api.call((s, t) => s.revealPins(t!, widget.txnId, pin)));
                      if (r != null) {
                        setState(() {
                          _pins = (r['pins'] as List).cast<String>();
                          _serials = (r['serials'] as List).cast<String>();
                        });
                      }
                    } catch (e) {
                      if (context.mounted) showApiError(context, e);
                    }
                  },
                ),
              ])
            : Column(children: [
                for (var i = 0; i < _pins!.length; i++)
                  KeyValue('PIN ${i + 1} · ${_serials![i]}', _pins![i], copy: true, strong: true),
              ]),
      ),
    );
  }
}

class _EsimInstall extends StatelessWidget {
  const _EsimInstall({required this.details});
  final Map<String, dynamic> details;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 12),
    child: KnockCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('Install your eSIM', style: KnockText.headline),
      const SizedBox(height: 8),
      KeyValue('SM-DP+ address', details['smdp'] as String, copy: true),
      KeyValue('Activation code', details['activationCode'] as String, copy: true),
      KeyValue('LPA string', details['lpa'] as String, copy: true),
      KeyValue('ICCID', details['iccid'] as String),
      const SizedBox(height: 6),
      TextButton(onPressed: () => Nav.esim(context), child: const Text('Step-by-step instructions')),
    ])),
  );
}

/// Transaction → Report a Problem. The reference is filled in for the customer.
class ReportProblemScreen extends StatefulWidget {
  const ReportProblemScreen({super.key, required this.txn});
  final Json txn;
  @override
  State<ReportProblemScreen> createState() => _ReportProblemScreenState();
}

class _ReportProblemScreenState extends State<ReportProblemScreen> {
  String _category = 'Payment not received';
  final _desc = TextEditingController();
  final _files = <String>[];
  bool _busy = false;
  String? _error;

  static const _categories = ['Payment not received', 'Wrong amount', 'Trade declined', 'Rate dispute', 'Duplicate charge', 'Something else'];

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final r = await context.api.call((s, t) => s.createTicket(t!, category: _category, subject: '$_category · ${widget.txn['reference']}', description: _desc.text, txnId: widget.txn['id'] as String, attachments: List.of(_files), dispute: true));
      if (!mounted) return;
      context.app.poke();
      final tk = r['ticket'] as Json;
      await Navigator.of(context).pushReplacement(KRoute(TicketScreen(ticketId: tk['id'] as String, justOpened: true)));
    } on ApiError catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return KPage(
      title: 'Report a problem',
      bottom: KnockButton(key: const ValueKey('dispute-submit'), label: 'Submit case', loading: _busy, onPressed: _submit),
      children: [
        KnockCard(color: KnockColors.surfaceRaised, child: Column(children: [
          KeyValue('Transaction', widget.txn['title'] as String),
          KeyValue('Reference', widget.txn['reference'] as String),
        ])),
        const SectionTitle('What went wrong?'),
        ChoiceWrap<String>(choices: [for (final c in _categories) Choice(c, c)], selected: _category, onSelected: (v) => setState(() => _category = v)),
        const SizedBox(height: 16),
        KField(key: const ValueKey('dispute-desc'), label: 'Tell us what happened', controller: _desc, maxLines: 4, hint: 'Include anything that helps us look into it.', error: _error),
        Wrap(spacing: 8, children: [
          for (final f in _files) Chip(label: Text(f), onDeleted: () => setState(() => _files.remove(f))),
          ActionChip(avatar: const Icon(Icons.attach_file_rounded, size: 18), label: const Text('Add attachment'), onPressed: () async {
            try {
              final x = await ImagePicker().pickImage(source: ImageSource.gallery);
              if (x != null) setState(() => _files.add(x.name));
            } catch (_) {
              setState(() => _files.add('sandbox_attachment_${_files.length + 1}.jpg'));
            }
          }),
        ]),
        const SizedBox(height: 16),
        const Note('You get a case reference straight away and can follow every reply here. No need to call.'),
      ],
    );
  }
}
