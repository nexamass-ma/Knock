import 'package:image_picker/image_picker.dart';
import 'package:material_ui/material_ui.dart';

import '../../api/api.dart';
import '../../app/app_controller.dart';
import '../../core/format.dart';
import '../../design/tokens.dart';
import '../../design/widgets/kit.dart';

class VerificationScreen extends StatelessWidget {
  const VerificationScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return ApiView(
      load: (api) => api.call((s, t) => s.verification(t!)),
      builder: (context, d, reload) {
        final tiers = (d['tiers'] as List).cast<Json>();
        final usage = d['usage'] as Map?;
        final bank = d['bank'] as Json?;
        return KPage(title: 'Verification', subtitle: 'You are on Tier ${d['tier']}.', onRefresh: reload, children: [
          if (usage != null)
            KnockCard(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Today\'s limit', style: KnockText.caption),
                const SizedBox(height: 6),
                if (usage['dailyLimit'] != null && (usage['dailyLimit'] as int) > 0) ...[
                  KProgress(((usage['usedToday'] as int? ?? 0) / (usage['dailyLimit'] as int)).clamp(0, 1).toDouble()),
                  const SizedBox(height: 6),
                  Text('${F.ngn(usage['usedToday'] as int? ?? 0)} of ${F.ngn(usage['dailyLimit'] as int)} used', style: KnockText.bodyStrong),
                ] else
                  Text('Verify your phone to start trading.', style: KnockText.bodyStrong),
              ]),
            ),
          if (bank != null) ...[
            const SizedBox(height: 10),
            ListRow(icon: Icons.account_balance_rounded, title: '${bank['bankName']} ••••${bank['last4']}', subtitle: '${bank['accountName']} · payout account'),
          ],
          for (final t in tiers) _TierCard(t: t, current: d['tier'] as int),
          const SizedBox(height: 12),
          const Note('We check your BVN and NIN with our licensed verification partner. We never store the raw numbers, and your tier only changes after a successful check.', icon: Icons.lock_outline_rounded),
        ]);
      },
    );
  }
}

class _TierCard extends StatelessWidget {
  const _TierCard({required this.t, required this.current});
  final Json t;
  final int current;
  @override
  Widget build(BuildContext context) {
    final status = t['status'] as String;
    final tier = t['tier'] as int;
    final canStart = tier == current + 1 && (status == 'not_started' || status == 'failed');
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: KnockCard(
        key: ValueKey('tier-$tier'),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Text('Tier $tier · ${t['name']}', style: KnockText.headline),
            const Spacer(),
            StatusChip(switch (status) { 'verified' => 'successful', 'failed' => 'failed', 'pending' => 'pending', _ => 'not_started' }, label: switch (status) { 'verified' => 'Verified', 'failed' => 'Unsuccessful', 'pending' => 'Checking', _ => 'Not started' }),
          ]),
          const SizedBox(height: 6),
          Text('Up to ${F.ngn(t['dailyLimit'] as int)} a day · ${F.ngn(t['singleLimit'] as int)} per transaction', style: KnockText.caption),
          const SizedBox(height: 10),
          for (final r in (t['requirements'] as List).cast<Json>())
            Row(children: [
              Icon(r['done'] == true ? Icons.check_circle_rounded : Icons.radio_button_unchecked_rounded, size: 18, color: r['done'] == true ? KnockColors.green : KnockColors.textTertiary),
              const SizedBox(width: 8),
              Text(r['label'] as String, style: KnockText.body),
            ]),
          const SizedBox(height: 8),
          Text('Unlocks: ${(t['capabilities'] as List).join(' · ')}', style: KnockText.caption),
          if (t['reason'] != null) ...[const SizedBox(height: 8), Note(t['reason'] as String, color: KnockColors.loss, icon: Icons.error_outline_rounded)],
          if (canStart) ...[
            const SizedBox(height: 12),
            KnockButton(key: ValueKey('tier-start-$tier'), label: status == 'failed' ? 'Try again' : 'Upgrade to Tier $tier', onPressed: () => go(context, tier == 2 ? const Tier2Screen() : const Tier3Screen())),
          ],
        ]),
      ),
    );
  }
}

class Tier2Screen extends StatefulWidget {
  const Tier2Screen({super.key});
  @override
  State<Tier2Screen> createState() => _Tier2ScreenState();
}

class _Tier2ScreenState extends State<Tier2Screen> {
  String _bank = banks.first.$1;
  final _acct = TextEditingController();
  final _bvn = TextEditingController();
  final _nin = TextEditingController();
  String? _name;
  String? _acctError;
  bool _busy = false;

  Future<void> _resolve() async {
    if (_acct.text.length != 10) return;
    try {
      final r = await context.api.call((s, t) => s.resolveBankAccount(t!, _bank, _acct.text));
      if (mounted) setState(() {
        _name = r['accountName'] as String;
        _acctError = null;
      });
    } on ApiError catch (e) {
      if (mounted) setState(() {
        _name = null;
        _acctError = e.message;
      });
    }
  }

  Future<void> _submit() async {
    setState(() => _busy = true);
    try {
      await context.api.call((s, t) => s.submitTier2(t!, bankCode: _bank, accountNumber: _acct.text, bvn: _bvn.text, nin: _nin.text));
      if (!mounted) return;
      context.app.poke();
      toast(context, 'Submitted. We are checking your details; this usually takes a few seconds.');
      Navigator.of(context).pop();
    } catch (e) {
      if (mounted) showApiError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return KPage(
      title: 'Upgrade to Tier 2',
      subtitle: 'Withdraw to your bank and get higher limits.',
      bottom: KnockButton(key: const ValueKey('t2-submit'), label: 'Verify me', loading: _busy, onPressed: _busy || _name == null ? null : _submit),
      children: [
        const SectionTitle('Payout bank account', top: 0),
        DropdownButtonFormField<String>(
          initialValue: _bank,
          items: [for (final (code, name) in banks) DropdownMenuItem(value: code, child: Text(name))],
          onChanged: (v) {
            setState(() => _bank = v ?? _bank);
            _resolve();
          },
          decoration: const InputDecoration(labelText: 'Bank'),
        ),
        const SizedBox(height: 12),
        KField(
          key: const ValueKey('t2-account'),
          label: 'Account number',
          controller: _acct,
          keyboard: TextInputType.number,
          maxLength: 10,
          error: _acctError,
          helper: _name == null ? 'Must be in your own name' : 'Account name: $_name',
          onChanged: (v) {
            setState(() => _name = null);
            if (v.length == 10) _resolve();
          },
        ),
        const SectionTitle('Identity'),
        KField(key: const ValueKey('t2-bvn'), label: 'BVN', controller: _bvn, keyboard: TextInputType.number, maxLength: 11, helper: 'Dial *565*0# to get your BVN'),
        KField(key: const ValueKey('t2-nin'), label: 'NIN', controller: _nin, keyboard: TextInputType.number, maxLength: 11, helper: 'Dial *346# to get your NIN'),
        const Note('Sandbox: any 11 digits pass except BVN 00000000000, which simulates a failed check.', icon: Icons.science_outlined, color: KnockColors.orange),
        const SizedBox(height: 8),
        const Note('We only use your BVN and NIN to confirm your identity. We do not store them, and they do not give us access to your bank account.', icon: Icons.lock_outline_rounded),
      ],
    );
  }
}

class Tier3Screen extends StatefulWidget {
  const Tier3Screen({super.key});
  @override
  State<Tier3Screen> createState() => _Tier3ScreenState();
}

class _Tier3ScreenState extends State<Tier3Screen> {
  final _line1 = TextEditingController();
  final _city = TextEditingController();
  final _state = TextEditingController();
  String _doc = 'utility_bill';
  String? _file;
  bool _busy = false;

  Future<void> _pick() async {
    try {
      final x = await ImagePicker().pickImage(source: ImageSource.gallery, imageQuality: 70);
      if (x != null) setState(() => _file = x.name);
    } catch (_) {
      setState(() => _file = 'proof-of-address.jpg (sandbox)');
    }
  }

  Future<void> _submit() async {
    setState(() => _busy = true);
    try {
      await context.api.call((s, t) => s.submitTier3(t!, address: {'line1': _line1.text, 'city': _city.text, 'state': _state.text}, docType: _doc, docRef: _file ?? ''));
      if (!mounted) return;
      context.app.poke();
      toast(context, 'Submitted for review');
      Navigator.of(context).pop();
    } catch (e) {
      if (mounted) showApiError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return KPage(title: 'Upgrade to Tier 3', bottom: KnockButton(label: 'Submit for review', loading: _busy, onPressed: _busy ? null : _submit), children: [
      KField(label: 'Street address', controller: _line1),
      KField(label: 'City', controller: _city),
      KField(label: 'State', controller: _state),
      const SectionTitle('Proof of address'),
      ChoiceWrap<String>(choices: const [Choice('utility_bill', 'Utility bill'), Choice('bank_statement', 'Bank statement'), Choice('tenancy', 'Tenancy agreement')], selected: _doc, onSelected: (v) => setState(() => _doc = v)),
      const SizedBox(height: 12),
      ListRow(icon: Icons.upload_file_rounded, title: _file ?? 'Upload document', subtitle: 'Dated in the last 3 months', onTap: _pick),
    ]);
  }
}
