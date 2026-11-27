import 'dart:convert';

import 'package:material_ui/material_ui.dart';

import '../../api/api.dart';
import '../../app/app_controller.dart';
import '../../core/format.dart';
import '../../design/tokens.dart';
import '../../design/widgets/kit.dart';

/// Tester controls. Clearly separated from the product: none of this exists
/// in a production build, where operations run in the back office.
class SandboxToolsScreen extends StatefulWidget {
  const SandboxToolsScreen({super.key});
  @override
  State<SandboxToolsScreen> createState() => _SandboxToolsScreenState();
}

class _SandboxToolsScreenState extends State<SandboxToolsScreen> {
  String _brand = 'apple';
  String _currency = 'USD';

  KnockApi get _api => context.api;

  Future<void> _ops(String label, Json Function(KnockServer s, String ops) f, {bool show = false}) async {
    try {
      final r = await _api.call((s, _) => f(s, _api.opsToken));
      if (!mounted) return;
      context.app.poke();
      if (show) {
        await showModalBottomSheet<void>(
          context: context,
          isScrollControlled: true,
          builder: (_) => DraggableScrollableSheet(
            expand: false,
            initialChildSize: 0.7,
            builder: (_, c) => SingleChildScrollView(controller: c, padding: const EdgeInsets.all(20), child: SelectableText(const JsonEncoder.withIndent('  ').convert(r), style: KnockText.caption.copyWith(fontFamily: 'monospace'))),
          ),
        );
      } else {
        toast(context, label);
      }
    } catch (e) {
      if (mounted) showApiError(context, e);
    }
  }

  Future<void> _tradeAction(String action) async {
    try {
      final r = await _api.call((s, _) => s.opsPendingTrades(_api.opsToken));
      final items = (r['items'] as List).cast<Json>().where((t) => t['userId'] == context.app.me?['id']).toList();
      if (!mounted) return;
      if (items.isEmpty) {
        toast(context, 'You have no pending trades. Sell a gift card first.', error: true);
        return;
      }
      final t = items.first;
      await _ops('${t['reference']}: $action', (s, ops) => s.opsTrade(ops, t['id'] as String, action, note: action == 'action_required' ? 'Please upload a clearer photo of the back of the card.' : null));
    } catch (e) {
      if (mounted) showApiError(context, e);
    }
  }

  Future<void> _reverseLast() async {
    try {
      final r = await _api.call((s, t) => s.transactions(t!, status: 'successful', limit: 50));
      final t = (r['items'] as List).cast<Json>().where((t) => t['type'] == 'giftcard_sell').firstOrNull;
      if (!mounted) return;
      if (t == null) {
        toast(context, 'No completed gift card trade to reverse.', error: true);
        return;
      }
      await _ops('Reversed ${t['reference']}', (s, ops) => s.opsReverse(ops, t['id'] as String));
    } catch (e) {
      if (mounted) showApiError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final me = context.app.me ?? {};
    final uid = me['id'] as String? ?? '';
    final brand = brandById(_brand);
    return KPage(title: 'Sandbox tools', subtitle: 'For testing only. Not part of the customer app.', children: [
      const Note('Everything here is simulated. No real money, cards, banks or messages are involved.', icon: Icons.science_outlined, color: KnockColors.orange),
      const SectionTitle('Messages'),
      ListRow(key: const ValueKey('sb-inbox'), icon: Icons.mark_email_unread_outlined, title: 'Test inbox', subtitle: 'Emails and SMS codes the sandbox sent you', onTap: () => go(context, const SandboxInboxScreen())),
      const SectionTitle('Rates'),
      ChoiceWrap<String>(choices: [for (final b in giftBrands.take(6)) Choice(b.id, b.name)], selected: _brand, onSelected: (v) => setState(() {
            _brand = v;
            if (!brandById(v).rates.containsKey(_currency)) _currency = brandById(v).rates.keys.first;
          })),
      const SizedBox(height: 8),
      ChoiceWrap<String>(choices: [for (final c in brand.rates.keys) Choice(c, c)], selected: _currency, onSelected: (v) => setState(() => _currency = v)),
      const SizedBox(height: 10),
      Row(children: [
        Expanded(child: KnockButton(key: const ValueKey('sb-rate-up'), label: 'Rate +₦20', icon: Icons.trending_up_rounded, onPressed: () => _ops('${brand.name} $_currency rate up ₦20', (s, ops) => s.opsMoveRate(ops, _brand, _currency, 20)))),
        const SizedBox(width: 10),
        Expanded(child: KnockButton(key: const ValueKey('sb-rate-down'), label: 'Rate −₦20', icon: Icons.trending_down_rounded, style: KnockButtonStyle.secondary, onPressed: () => _ops('${brand.name} $_currency rate down ₦20', (s, ops) => s.opsMoveRate(ops, _brand, _currency, -20)))),
      ]),
      const SizedBox(height: 6),
      Text('Move a rate while reviewing a trade to see the rate-change notice.', style: KnockText.micro),
      const SectionTitle('Trades'),
      ListRow(icon: Icons.check_circle_outline_rounded, title: 'Approve my latest pending trade now', onTap: () => _tradeAction('approve_now')),
      ListRow(icon: Icons.report_gmailerrorred_rounded, title: 'Ask me for more information', subtitle: 'Sets "Action required" with a note', onTap: () => _tradeAction('action_required')),
      ListRow(icon: Icons.cancel_outlined, title: 'Fail my latest pending trade', onTap: () => _tradeAction('fail')),
      ListRow(icon: Icons.undo_rounded, title: 'Reverse my last completed gift card trade', subtitle: 'Also reverses any welcome bonus it earned', onTap: _reverseLast),
      const SectionTitle('Gifts and rewards'),
      ListRow(key: const ValueKey('sb-gift'), icon: Icons.redeem_rounded, title: 'Send me a test gift', subtitle: 'From a sandbox user', onTap: () => _ops('A gift is on its way', (s, ops) => s.opsSendTestGift(ops, uid))),
      ListRow(icon: Icons.lock_open_rounded, title: 'Release held rewards', onTap: () => _ops('Held rewards released', (s, ops) => s.opsReleaseRewards(ops))),
      ListRow(icon: Icons.shield_outlined, title: 'Clear my security hold', onTap: () => _ops('Security hold cleared', (s, ops) => s.opsClearHold(ops, uid))),
      const SectionTitle('Operations'),
      ListRow(icon: Icons.delete_forever_outlined, title: 'Complete due account deletions', subtitle: 'Skips the 14-day wait', onTap: () => _ops('Due deletions completed', (s, ops) => s.opsCompleteDeletions(ops))),
      ListRow(key: const ValueKey('sb-reconcile'), icon: Icons.balance_rounded, title: 'Run ledger reconciliation', onTap: () => _ops('Reconciled', (s, ops) => s.reconcile(ops), show: true)),
      ListRow(icon: Icons.history_rounded, title: 'View audit log', onTap: () => _ops('Audit', (s, ops) => s.opsAudit(ops), show: true)),
      const SectionTitle('App'),
      StatefulBuilder(
        builder: (context, set) => SwitchListTile(
          key: const ValueKey('sb-offline'),
          contentPadding: EdgeInsets.zero,
          title: Text('Simulate no connection', style: KnockText.body),
          subtitle: Text('Every request fails, to test error states', style: KnockText.caption),
          value: _api.simulateOffline,
          onChanged: (v) => set(() => _api.simulateOffline = v),
        ),
      ),
      ListRow(
        key: const ValueKey('sb-reset'),
        icon: Icons.restart_alt_rounded,
        danger: true,
        title: 'Reset the sandbox',
        subtitle: 'Deletes every test account and starts fresh',
        onTap: () async {
          if (!await confirm(context, title: 'Reset the sandbox?', message: 'All test accounts and transactions on this device are deleted.', yes: 'Reset', danger: true)) return;
          if (!context.mounted) return;
          final app = context.app;
          await _api.resetSandbox();
          await app.logout(message: 'The sandbox was reset.');
        },
      ),
    ]);
  }
}

class SandboxInboxScreen extends StatelessWidget {
  const SandboxInboxScreen({super.key});
  @override
  Widget build(BuildContext context) {
    return ApiView(
      load: (api) => api.call((s, t) => s.sandboxInbox(t!)),
      builder: (context, d, reload) {
        final items = (d['items'] as List).cast<Json>();
        return KPage(title: 'Test inbox', onRefresh: reload, children: [
          if (items.isEmpty) const EmptyState(icon: Icons.inbox_outlined, title: 'Nothing yet', message: 'Codes and emails the sandbox sends appear here.'),
          for (final m in items)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: KnockCard(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Icon(m['channel'] == 'sms' ? Icons.sms_outlined : Icons.mail_outline_rounded, size: 18, color: KnockColors.textSecondary),
                    const SizedBox(width: 6),
                    Expanded(child: Text('${m['channel']} to ${m['to']}', style: KnockText.micro)),
                    Text(F.ago(m['at'] as String? ?? DateTime.now().toIso8601String()), style: KnockText.micro),
                  ]),
                  const SizedBox(height: 4),
                  Text(m['subject'] as String? ?? '', style: KnockText.bodyStrong),
                  SelectableText(m['body'] as String? ?? '', style: KnockText.caption),
                ]),
              ),
            ),
        ]);
      },
    );
  }
}
