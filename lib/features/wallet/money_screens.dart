import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../api/api.dart';
import '../../app/app_controller.dart';
import '../../core/format.dart';
import '../../design/tokens.dart';
import '../../design/widgets/kit.dart';
import '../common/pin_sheet.dart';
import '../common/success_screen.dart';
import '../history/transaction_detail_screen.dart';
import '../shell/nav.dart';

int? parseNaira(String s) {
  final v = double.tryParse(s.replaceAll(',', '').trim());
  return v == null ? null : (v * 100).round();
}

class DepositScreen extends StatefulWidget {
  const DepositScreen({super.key});
  @override
  State<DepositScreen> createState() => _DepositScreenState();
}

class _DepositScreenState extends State<DepositScreen> {
  final _amount = TextEditingController(text: '50000');
  bool _busy = false;

  Future<void> _simulate() async {
    final k = parseNaira(_amount.text);
    if (k == null) return;
    setState(() => _busy = true);
    try {
      final r = await context.api.call((s, t) => s.simulateDeposit(t!, k));
      if (!mounted) return;
      toast(context, 'Transfer detected. It will land in a few seconds.');
      context.app.poke();
      await go(context, TransactionDetailScreen(txnId: (r['txn'] as Json)['id'] as String));
    } catch (e) {
      if (mounted) showApiError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Deposit')),
      body: ApiView(
        live: false,
        load: (api) => api.call((s, t) => s.depositInstructions(t!)),
        builder: (context, d, _) => ListView(
          padding: const EdgeInsets.all(KnockSpace.gutter),
          children: [
            Text('Send money to your Knock account from any Nigerian bank app.', style: KnockText.body.copyWith(color: KnockColors.textSecondary)),
            const SizedBox(height: 16),
            KnockCard(child: Column(children: [
              KeyValue('Bank', d['bankName'] as String),
              KeyValue('Account number', d['accountNumber'] as String, strong: true, copy: true),
              KeyValue('Account name', d['accountName'] as String),
              KeyValue('Fee', 'Free'),
            ])),
            const SizedBox(height: 12),
            SandboxNote(d['note'] as String),
            const SectionTitle('Test a transfer'),
            KField(key: const ValueKey('deposit-amount'), label: 'Amount (₦)', controller: _amount, keyboard: TextInputType.number, formatters: [FilteringTextInputFormatter.allow(RegExp(r'[\d.]'))]),
            KnockButton(key: const ValueKey('deposit-simulate'), label: 'Simulate a bank transfer', loading: _busy, onPressed: _simulate),
            const SizedBox(height: 8),
            Text('The payment provider confirms the transfer with a signed webhook before your balance changes.', style: KnockText.caption),
          ],
        ),
      ),
    );
  }
}

class WithdrawScreen extends StatefulWidget {
  const WithdrawScreen({super.key});
  @override
  State<WithdrawScreen> createState() => _WithdrawScreenState();
}

class _WithdrawScreenState extends State<WithdrawScreen> {
  final _amount = TextEditingController();
  final _idem = KnockApi.newIdempotencyKey();
  bool _busy = false;
  String? _error;

  Future<void> _go(Json wallet) async {
    final k = parseNaira(_amount.text);
    if (k == null || k <= 0) {
      setState(() => _error = 'Enter an amount.');
      return;
    }
    if (k + 5000 > (wallet['available'] as int)) {
      setState(() => _error = 'That is more than your available balance (including the ₦50 fee).');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final api = context.api;
    try {
      final r = await withPin<Json>(context, title: 'Confirm withdrawal', subtitle: '${F.ngnExact(k)} to your bank · ₦50 fee', action: (pin) {
        final sec = api.security();
        return api.call((s, t) => s.withdraw(t!, amountKobo: k, pin: pin, idempotencyKey: _idem, nonce: sec.nonce, sentAt: sec.sentAt));
      });
      if (r == null || !mounted) return;
      final txn = r['txn'] as Json;
      context.app.poke();
      await Navigator.of(context).pushReplacement(KRoute(ResultScreen(
        title: 'Withdrawal on its way',
        amountKobo: k,
        message: 'Your money is being sent to ${(txn['details'] as Map)['bank']}. We will let you know when it arrives.',
        txn: txn,
        nextLabel: 'Track withdrawal',
        onNext: () => Navigator.of(context).pushReplacement(KRoute(TransactionDetailScreen(txnId: txn['id'] as String))),
      )));
    } catch (e) {
      if (mounted) showApiError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = context.appWatch;
    if (app.tier < 2) {
      return KPage(title: 'Withdraw', children: [
        EmptyState(
          icon: Icons.verified_user_outlined,
          title: 'Verify to withdraw',
          message: 'Withdrawals to your bank need Tier 2: your bank account, BVN and NIN. It takes a few minutes.',
          action: 'Verify now',
          onAction: () => Nav.verification(context),
        ),
      ]);
    }
    return Scaffold(
      appBar: AppBar(title: const Text('Withdraw')),
      body: ApiView(
        load: (api) async {
          final r = await Future.wait([api.call((s, t) => s.wallet(t!)), api.call((s, t) => s.verification(t!))]);
          return {'wallet': r[0], 'kyc': r[1]};
        },
        builder: (context, d, _) {
          final w = d['wallet'] as Json;
          final bank = ((d['kyc'] as Json)['bank'] as Map?);
          return ListView(padding: const EdgeInsets.all(KnockSpace.gutter), children: [
            KnockCard(child: Column(children: [
              KeyValue('Available', F.ngnExact(w['available'] as int), strong: true),
              if (bank != null) KeyValue('To', '${bank['bankName']} •••• ${bank['last4']}'),
              if (bank != null) KeyValue('Account name', bank['accountName'] as String),
              const KeyValue('Fee', '₦50'),
            ])),
            const SizedBox(height: 16),
            KField(key: const ValueKey('withdraw-amount'), label: 'Amount (₦)', controller: _amount, keyboard: const TextInputType.numberWithOptions(decimal: true), formatters: [FilteringTextInputFormatter.allow(RegExp(r'[\d.]'))], error: _error, helper: 'Minimum ₦1,000'),
            KnockButton(key: const ValueKey('withdraw-submit'), label: 'Withdraw', loading: _busy, onPressed: () => _go(w)),
            const SizedBox(height: 10),
            Text('Withdrawals pause for 24 hours after a password or email change, to protect your account.', style: KnockText.caption),
          ]);
        },
      ),
    );
  }
}
