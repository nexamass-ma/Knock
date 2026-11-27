import 'package:material_ui/material_ui.dart';

import '../../api/api.dart';
import '../../app/app_controller.dart';
import '../../core/format.dart';
import '../../design/tokens.dart';
import '../../design/widgets/kit.dart';
import '../shell/nav.dart';
import '../shell/shell.dart';

/// Settings → Account → Delete account. Shows consequences, blockers and the
/// records we must keep, then re-authenticates and asks for typed
/// confirmation. The request is tracked and can be cancelled for 14 days.
class DeleteAccountScreen extends StatefulWidget {
  const DeleteAccountScreen({super.key});
  @override
  State<DeleteAccountScreen> createState() => _DeleteAccountScreenState();
}

class _DeleteAccountScreenState extends State<DeleteAccountScreen> {
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  final _reason = TextEditingController();
  bool _ack = false;
  bool _busy = false;

  Future<void> _submit() async {
    final ok = await confirm(context, title: 'Delete your Knock account?', message: 'This closes your account after 14 days. You can cancel before then.', yes: 'Delete account', danger: true);
    if (!ok || !mounted) return;
    setState(() => _busy = true);
    try {
      await context.api.call((s, t) => s.requestDeletion(t!, password: _password.text, confirmation: _confirm.text, reason: _reason.text));
      if (!mounted) return;
      context.app.poke();
      _password.clear();
      _confirm.clear();
    } catch (e) {
      if (mounted) showApiError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _do(Json Function(KnockServer s, String t) f, String msg) async {
    try {
      await context.api.call((s, t) => f(s, t!));
      if (!mounted) return;
      context.app.poke();
      toast(context, msg);
    } catch (e) {
      if (mounted) showApiError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ApiView(
      load: (api) => api.call((s, t) => s.deletionCheck(t!)),
      builder: (context, d, reload) {
        final req = d['request'] as Json?;
        final blockers = (d['blockers'] as List).cast<Json>();
        final retention = (d['retention'] as List).cast<String>();
        final bonus = d['bonusForfeit'] as int;
        if (req != null && (req['status'] == 'scheduled' || req['status'] == 'action_needed')) {
          return _Tracking(req: req, onRecheck: () => _do((s, t) => s.recheckDeletion(t), 'Checked again'), onCancel: () => _do((s, t) => s.cancelDeletion(t), 'Deletion cancelled. Your account stays open.'));
        }
        final hard = blockers.where((b) => b['warning'] != true).toList();
        final canSubmit = _ack && _password.text.isNotEmpty && _confirm.text.trim().toUpperCase() == 'DELETE' && !_busy;
        return KPage(
          title: 'Delete account',
          bottom: DangerAwareButton(key: const ValueKey('delete-submit'), label: 'Delete my account', danger: true, loading: _busy, onPressed: canSubmit ? _submit : null),
          children: [
            const Note('Deleting your account is permanent once the 14-day cooling-off period ends.', icon: Icons.warning_amber_rounded, color: KnockColors.loss),
            const SectionTitle('What happens'),
            for (final t in [
              'You will be signed out on every device and cannot log back in.',
              'Your username, photo and preferences are deleted.',
              if (bonus > 0) 'Your bonus balance of ${F.ngnExact(bonus)} and any Knock Points are forfeited.',
              'Pending referral rewards are cancelled.',
            ])
              Padding(padding: const EdgeInsets.only(bottom: 6), child: Text('• $t', style: KnockText.body)),
            const SectionTitle('What we must keep'),
            for (final r in retention) Padding(padding: const EdgeInsets.only(bottom: 6), child: Text('• $r', style: KnockText.caption)),
            if (blockers.isNotEmpty) ...[
              const SectionTitle('Before you go'),
              for (final b in blockers)
                ListRow(
                  icon: b['warning'] == true ? Icons.info_outline_rounded : Icons.error_outline_rounded,
                  iconColor: b['warning'] == true ? KnockColors.orange : KnockColors.loss,
                  title: b['label'] as String,
                  onTap: switch (b['code']) {
                    'balance' => () => Nav.withdraw(context),
                    'crypto' => () => Nav.crypto(context),
                    'tickets' => () => Nav.support(context),
                    'gifts' => () => Nav.tab(context, ShellTab.gifts),
                    _ => null,
                  },
                ),
              if (hard.isNotEmpty) const Note('You can still submit. We will hold the request until these are sorted.', icon: Icons.schedule_rounded),
            ],
            const SectionTitle('Confirm'),
            KField(label: 'Why are you leaving? (optional)', controller: _reason, maxLines: 2),
            KField(key: const ValueKey('delete-password'), label: 'Your password', controller: _password, password: true, onChanged: (_) => setState(() {})),
            KField(key: const ValueKey('delete-confirm'), label: 'Type DELETE to confirm', controller: _confirm, capitalization: TextCapitalization.characters, onChanged: (_) => setState(() {})),
            CheckboxListTile(
              key: const ValueKey('delete-ack'),
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              value: _ack,
              onChanged: (v) => setState(() => _ack = v == true),
              title: Text('I understand what will be deleted and what Knock must keep.', style: KnockText.body),
            ),
          ],
        );
      },
    );
  }
}

class _Tracking extends StatelessWidget {
  const _Tracking({required this.req, required this.onRecheck, required this.onCancel});
  final Json req;
  final VoidCallback onRecheck;
  final VoidCallback onCancel;
  @override
  Widget build(BuildContext context) {
    final scheduled = req['status'] == 'scheduled';
    final blockers = (req['blockers'] as List).cast<Json>();
    return KPage(title: 'Deletion request', children: [
      KnockCard(
        key: const ValueKey('deletion-status'),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            StatusChip(scheduled ? 'pending' : 'action_required', label: scheduled ? 'Scheduled' : 'Action needed'),
            const Spacer(),
            Text(req['reference'] as String, style: KnockText.caption),
          ]),
          const SizedBox(height: 10),
          Text(scheduled ? 'Your account closes on ${F.dateTime(req['scheduledFor'] as String)}.' : 'Sort these out and we will schedule the closure.', style: KnockText.bodyStrong),
          const SizedBox(height: 10),
          for (final h in (req['history'] as List).cast<Json>()) Text('• ${h['label']} · ${F.dateTime(h['at'] as String)}', style: KnockText.caption),
        ]),
      ),
      if (!scheduled) ...[
        const SectionTitle('Action needed'),
        for (final b in blockers) ListRow(icon: Icons.error_outline_rounded, iconColor: KnockColors.loss, title: b['label'] as String),
        KnockButton(label: 'Check again', style: KnockButtonStyle.secondary, onPressed: onRecheck),
      ],
      const SizedBox(height: 16),
      KnockButton(key: const ValueKey('deletion-cancel'), label: 'Keep my account', onPressed: onCancel),
    ]);
  }
}
