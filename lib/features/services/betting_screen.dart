import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../api/api.dart';
import '../../app/app_controller.dart';
import '../../core/format.dart';
import '../../design/tokens.dart';
import '../../design/widgets/kit.dart';
import '../shell/nav.dart';
import '../wallet/money_screens.dart';
import 'service_common.dart';

class BettingScreen extends StatefulWidget {
  const BettingScreen({super.key});
  @override
  State<BettingScreen> createState() => _BettingScreenState();
}

class _BettingScreenState extends State<BettingScreen> {
  String? _provider;
  final _account = TextEditingController();
  final _amount = TextEditingController();
  bool _adult = false;
  String? _name;
  String? _error;
  final _idem = KnockApi.newIdempotencyKey();

  Future<void> _verify() async {
    try {
      final r = await context.api.call((s, t) => s.validateCustomer(t!, kind: 'betting', billerId: _provider!, customerId: _account.text));
      setState(() {
        _name = r['customerName'] as String;
        _error = null;
      });
    } on ApiError catch (e) {
      setState(() => _error = e.message);
    }
  }

  Future<void> _pay() async {
    final k = parseNaira(_amount.text);
    if (_provider == null || _account.text.isEmpty || k == null) return setState(() => _error = 'Choose a provider, enter your account ID and an amount.');
    if (_name == null) return setState(() => _error = 'Verify your betting account first.');
    if (!_adult) return setState(() => _error = 'Please confirm you are 18 or older.');
    await payForService(context, kind: 'betting', billerId: _provider!, amountKobo: k, customer: _account.text, customerName: _name, idempotencyKey: _idem, summary: '${F.ngnExact(k)} to ${_account.text}', confirmedAdult: true, successTitle: 'Wallet funded');
  }

  @override
  Widget build(BuildContext context) {
    final app = context.appWatch;
    if (app.tier < 2) {
      return KPage(title: 'Betting', children: [
        EmptyState(icon: Icons.sports_soccer_rounded, title: 'Verify to fund betting wallets', message: 'Betting wallet funding needs Tier 2 verification and is only for customers aged 18 or over.', action: 'Verify now', onAction: () => Nav.verification(context)),
      ]);
    }
    return KPage(
      title: 'Fund betting wallet',
      bottom: KnockButton(key: const ValueKey('bet-pay'), label: 'Fund wallet', onPressed: _pay),
      children: [
        ChoiceWrap<String>(choices: [for (final b in bettingProviders) Choice(b.id, b.name)], selected: _provider, onSelected: (v) => setState(() {
          _provider = v;
          _name = null;
        })),
        const SizedBox(height: 18),
        KField(key: const ValueKey('bet-account'), label: 'Betting account ID', controller: _account, onChanged: (_) => setState(() => _name = null), suffix: TextButton(onPressed: _provider == null ? null : _verify, child: const Text('Verify'))),
        if (_name != null) Padding(padding: const EdgeInsets.only(bottom: 12), child: Note('Account holder: $_name', icon: Icons.check_circle_outline_rounded, color: KnockColors.greenBright)),
        KField(key: const ValueKey('bet-amount'), label: 'Amount (₦)', controller: _amount, keyboard: TextInputType.number, formatters: [FilteringTextInputFormatter.digitsOnly], helper: '₦100 to ₦500,000'),
        CheckboxListTile(
          key: const ValueKey('bet-adult'),
          contentPadding: EdgeInsets.zero,
          value: _adult,
          onChanged: (v) => setState(() => _adult = v ?? false),
          activeColor: KnockColors.green,
          controlAffinity: ListTileControlAffinity.leading,
          title: Text('I am 18 or older and I gamble responsibly', style: KnockText.body),
        ),
        if (_error != null) Note(_error!, color: KnockColors.loss, icon: Icons.error_outline_rounded),
        const SizedBox(height: 12),
        const Note('Set limits and take breaks. If gambling stops being fun, your provider offers self-exclusion tools.', icon: Icons.favorite_border_rounded),
        const SizedBox(height: 10),
        const BalanceLine(),
      ],
    );
  }
}
