import 'package:image_picker/image_picker.dart';
import 'package:material_ui/material_ui.dart';

import '../../api/api.dart';
import '../../app/app_controller.dart';
import '../../core/format.dart';
import '../../design/tokens.dart';
import '../../design/widgets/kit.dart';
import '../common/launch.dart';
import '../shell/nav.dart';
import '../shell/shell.dart';

const ticketCategories = ['Gift card trade', 'Crypto', 'Deposit', 'Withdrawal', 'Bills and services', 'Gift Send', 'Verification', 'Rewards and referrals', 'Account and security', 'Something else'];

class SupportScreen extends StatelessWidget {
  const SupportScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return KPage(title: 'Support', subtitle: 'Real people, here to help.', children: [
      Stack(children: [
        const SupportPhoto(height: 190),
        Positioned(
          left: 16,
          bottom: 14,
          right: 16,
          child: Text("We're here to help.\nCall or message us any time.", style: KnockText.headline.copyWith(shadows: const [Shadow(blurRadius: 12, color: Colors.black)])),
        ),
      ]),
      const SizedBox(height: 14),
      Row(children: [
        Expanded(child: KnockButton(key: const ValueKey('support-call'), label: 'Call us', icon: Icons.call_rounded, onPressed: () => callSupport(context))),
        const SizedBox(width: 10),
        Expanded(child: KnockButton(key: const ValueKey('support-whatsapp'), label: 'WhatsApp', icon: Icons.chat_rounded, style: KnockButtonStyle.secondary, onPressed: () => whatsAppSupport(context, message: 'Hi Knock, I need help with my account.'))),
      ]),
      const SizedBox(height: 8),
      Center(child: Text(supportPhoneDisplay, style: KnockText.caption)),
      const SectionTitle('Get help'),
      ListRow(key: const ValueKey('support-new'), icon: Icons.edit_note_rounded, title: 'Open a support ticket', subtitle: 'We reply in the app, usually within an hour', onTap: () => go(context, const NewTicketScreen())),
      ListRow(icon: Icons.gavel_rounded, title: 'Dispute Centre', subtitle: 'Problems with a specific transaction', onTap: () => go(context, const TicketsScreen(kind: 'dispute'))),
      ListRow(icon: Icons.quiz_outlined, title: 'FAQ', subtitle: 'Quick answers to common questions', onTap: () => Nav.faq(context)),
      ListRow(icon: Icons.school_outlined, title: 'How Knock works', onTap: () => Nav.workings(context)),
      const SectionTitle('Your tickets'),
      ApiView(
        load: (api) => api.call((s, t) => s.tickets(t!)),
        builder: (context, d, _) {
          final items = (d['items'] as List).cast<Json>();
          if (items.isEmpty) return const Note('You have no open tickets.');
          return Column(children: [
            for (final t in items.take(5)) TicketRow(t: t),
            if (items.length > 5) TextButton(onPressed: () => go(context, const TicketsScreen()), child: const Text('See all')),
          ]);
        },
      ),
    ]);
  }
}

String ticketStatusLabel(String s) => switch (s) {
      'open' => 'Received',
      'in_progress' => 'In progress',
      'awaiting_customer' => 'Waiting for you',
      'resolved' => 'Resolved',
      'closed' => 'Closed',
      _ => s,
    };

class TicketRow extends StatelessWidget {
  const TicketRow({super.key, required this.t});
  final Json t;
  @override
  Widget build(BuildContext context) => ListRow(
        key: ValueKey('ticket-${t['id']}'),
        icon: t['kind'] == 'dispute' ? Icons.gavel_rounded : Icons.support_agent_rounded,
        title: t['subject'] as String,
        subtitle: '${t['reference']} · ${F.ago(t['updatedAt'] as String)}',
        trailing: StatusChip(switch (t['status']) { 'resolved' || 'closed' => 'successful', 'awaiting_customer' => 'action_required', _ => 'pending' }, label: ticketStatusLabel(t['status'] as String)),
        onTap: () => go(context, TicketScreen(ticketId: t['id'] as String)),
      );
}

class TicketsScreen extends StatelessWidget {
  const TicketsScreen({super.key, this.kind});
  final String? kind;
  @override
  Widget build(BuildContext context) {
    return ApiView(
      load: (api) => api.call((s, t) => s.tickets(t!, kind: kind)),
      builder: (context, d, reload) {
        final items = (d['items'] as List).cast<Json>();
        return KPage(
          title: kind == 'dispute' ? 'Dispute Centre' : 'Your tickets',
          subtitle: kind == 'dispute' ? 'To open a case, go to the transaction and tap Report a problem.' : null,
          onRefresh: reload,
          children: [
            if (items.isEmpty)
              EmptyState(
                icon: Icons.inbox_outlined,
                title: kind == 'dispute' ? 'No cases' : 'No tickets',
                message: kind == 'dispute' ? 'If something goes wrong with a transaction, open it from History and tap Report a problem.' : 'Need help? Open a ticket.',
                action: kind == 'dispute' ? 'Go to History' : 'Open a ticket',
                onAction: () => kind == 'dispute' ? Nav.tab(context, ShellTab.history) : go(context, const NewTicketScreen()),
              )
            else
              for (final t in items) TicketRow(t: t),
          ],
        );
      },
    );
  }
}

class NewTicketScreen extends StatefulWidget {
  const NewTicketScreen({super.key});
  @override
  State<NewTicketScreen> createState() => _NewTicketScreenState();
}

class _NewTicketScreenState extends State<NewTicketScreen> {
  String _category = ticketCategories.first;
  final _subject = TextEditingController();
  final _desc = TextEditingController();
  final _attachments = <String>[];
  bool _busy = false;

  Future<void> _attach() async {
    try {
      final x = await ImagePicker().pickImage(source: ImageSource.gallery, imageQuality: 70);
      if (x != null) setState(() => _attachments.add(x.name));
    } catch (_) {
      setState(() => _attachments.add('screenshot-${_attachments.length + 1}.jpg (sandbox)'));
    }
  }

  Future<void> _submit() async {
    setState(() => _busy = true);
    try {
      final r = await context.api.call((s, t) => s.createTicket(t!, category: _category, subject: _subject.text, description: _desc.text, attachments: _attachments));
      if (!mounted) return;
      context.app.poke();
      await Navigator.of(context).pushReplacement(KRoute(TicketScreen(ticketId: (r['ticket'] as Json)['id'] as String, justOpened: true)));
    } catch (e) {
      if (mounted) showApiError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return KPage(
      title: 'Open a ticket',
      bottom: KnockButton(key: const ValueKey('ticket-submit'), label: 'Send to support', loading: _busy, onPressed: _busy ? null : _submit),
      children: [
        const SectionTitle('What is it about?', top: 0),
        ChoiceWrap<String>(choices: [for (final c in ticketCategories) Choice(c, c)], selected: _category, onSelected: (c) => setState(() => _category = c)),
        const SizedBox(height: 16),
        KField(key: const ValueKey('ticket-subject'), label: 'Subject', controller: _subject, hint: 'A short summary'),
        KField(key: const ValueKey('ticket-desc'), label: 'Tell us what happened', controller: _desc, maxLines: 5, hint: 'Include amounts, dates and anything you have tried.'),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final a in _attachments) InputChip(label: Text(a), onDeleted: () => setState(() => _attachments.remove(a))),
          ActionChip(avatar: const Icon(Icons.attach_file_rounded, size: 18), label: const Text('Add screenshot'), onPressed: _attach),
        ]),
        const SizedBox(height: 12),
        const Note('Never share your PIN, password or full card codes with anyone, including Knock staff.', icon: Icons.shield_outlined),
      ],
    );
  }
}

class TicketScreen extends StatefulWidget {
  const TicketScreen({super.key, required this.ticketId, this.justOpened = false});
  final String ticketId;
  final bool justOpened;
  @override
  State<TicketScreen> createState() => _TicketScreenState();
}

class _TicketScreenState extends State<TicketScreen> {
  final _reply = TextEditingController();
  bool _sending = false;

  Future<void> _send() async {
    if (_reply.text.trim().isEmpty) return;
    setState(() => _sending = true);
    try {
      await context.api.call((s, t) => s.replyTicket(t!, widget.ticketId, _reply.text));
      _reply.clear();
      if (mounted) context.app.poke();
    } catch (e) {
      if (mounted) showApiError(context, e);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _close() async {
    if (!await confirm(context, title: 'Close this ticket?', message: 'Only close it if your issue is sorted. You can open a new one any time.', yes: 'Close ticket')) return;
    if (!mounted) return;
    try {
      await context.api.call((s, t) => s.closeTicket(t!, widget.ticketId));
      if (mounted) context.app.poke();
    } catch (e) {
      if (mounted) showApiError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ApiView(
      load: (api) => api.call((s, t) => s.ticket(t!, widget.ticketId)),
      builder: (context, d, reload) {
        final t = d['ticket'] as Json;
        final msgs = (t['messages'] as List).cast<Json>();
        final hist = (t['history'] as List).cast<Json>();
        final closed = t['status'] == 'closed';
        return Scaffold(
          appBar: AppBar(title: Text(t['reference'] as String), actions: [
            if (!closed) TextButton(key: const ValueKey('ticket-close'), onPressed: _close, child: const Text('Close')),
          ]),
          body: Column(children: [
            Expanded(
              child: ListView(padding: const EdgeInsets.all(KnockSpace.gutter), children: [
                if (widget.justOpened)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Note('${t['kind'] == 'dispute' ? 'Case' : 'Ticket'} ${t['reference']} is open. We will reply here and notify you.', icon: Icons.check_circle_rounded, color: KnockColors.greenBright),
                  ),
                Text(t['subject'] as String, style: KnockText.title),
                const SizedBox(height: 4),
                Row(children: [
                  StatusChip(switch (t['status']) { 'resolved' || 'closed' => 'successful', 'awaiting_customer' => 'action_required', _ => 'pending' }, label: ticketStatusLabel(t['status'] as String)),
                  const SizedBox(width: 8),
                  Text('${t['category']}${t['txnRef'] != null ? ' · ${t['txnRef']}' : ''}', style: KnockText.caption),
                ]),
                if (t['txnId'] != null) TextButton(onPressed: () => Nav.txn(context, t['txnId'] as String), child: const Text('View transaction')),
                const SectionTitle('Progress'),
                for (final h in hist) Text('• ${h['label']} · ${F.dateTime(h['at'] as String)}', style: KnockText.caption),
                const SectionTitle('Conversation'),
                for (final m in msgs)
                  Align(
                    alignment: m['from'] == 'customer' ? Alignment.centerRight : Alignment.centerLeft,
                    child: Container(
                      margin: const EdgeInsets.only(bottom: 8),
                      padding: const EdgeInsets.all(12),
                      constraints: const BoxConstraints(maxWidth: 300),
                      decoration: BoxDecoration(color: m['from'] == 'customer' ? KnockColors.greenSoft : KnockColors.surfaceRaised, borderRadius: BorderRadius.circular(KnockRadius.md)),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(m['from'] == 'customer' ? 'You' : (m['name'] as String? ?? 'Knock Support'), style: KnockText.micro),
                        const SizedBox(height: 2),
                        Text(m['body'] as String, style: KnockText.body),
                        if ((m['attachments'] as List?)?.isNotEmpty == true) Text('📎 ${(m['attachments'] as List).join(', ')}', style: KnockText.micro),
                        Text(F.ago(m['at'] as String), style: KnockText.micro),
                      ]),
                    ),
                  ),
              ]),
            ),
            if (!closed)
              SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
                  child: Row(children: [
                    Expanded(child: TextField(key: const ValueKey('ticket-reply'), controller: _reply, style: KnockText.body, minLines: 1, maxLines: 4, decoration: const InputDecoration(hintText: 'Write a reply'))),
                    IconButton(key: const ValueKey('ticket-send'), tooltip: 'Send', onPressed: _sending ? null : _send, icon: const Icon(Icons.send_rounded, color: KnockColors.greenBright)),
                  ]),
                ),
              ),
          ]),
        );
      },
    );
  }
}
