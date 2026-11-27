import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:material_ui/material_ui.dart';

import '../../api/api.dart';
import '../../app/app_controller.dart';
import '../../core/format.dart';
import '../../design/tokens.dart';
import '../../design/widgets/kit.dart';

/// Developer test controls. Only in debug builds (or builds made with
/// --dart-define=KNOCK_DEV_TOOLS=true); never in the customer release.
/// Staff and admin work (trade review, reversals, audit, reconciliation)
/// is not in the customer app at all: it belongs in the separate admin app.
const devToolsEnabled = kDebugMode || bool.fromEnvironment('KNOCK_DEV_TOOLS');

class SandboxToolsScreen extends StatefulWidget {
  const SandboxToolsScreen({super.key});
  @override
  State<SandboxToolsScreen> createState() => _SandboxToolsScreenState();
}

class _SandboxToolsScreenState extends State<SandboxToolsScreen> {
  String _brand = 'apple';
  String _currency = 'USD';

  KnockApi get _api => context.api;

  Future<void> _ops(String label, Json Function(KnockServer s, String ops) f) async {
    try {
      await _api.call((s, _) => f(s, _api.opsToken));
      if (!mounted) return;
      context.app.poke();
      toast(context, label);
    } catch (e) {
      if (mounted) showApiError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final me = context.app.me ?? {};
    final uid = me['id'] as String? ?? '';
    final brand = brandById(_brand);
    return KPage(title: 'Developer tools', subtitle: 'Debug builds only. Not part of the customer app.', children: [
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
      const SectionTitle('Gifts'),
      ListRow(key: const ValueKey('sb-gift'), icon: Icons.redeem_rounded, title: 'Send me a test gift', subtitle: 'From a sandbox user', onTap: () => _ops('A gift is on its way', (s, ops) => s.opsSendTestGift(ops, uid))),
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
