import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:share_plus/share_plus.dart';

import '../../design/tokens.dart';
import '../../design/widgets/surfaces.dart';
import 'pl_models.dart';
import 'pl_sandbox.dart';
import 'pl_split.dart';
import 'pl_widgets.dart';

/// What a payer sees when they open a Knock payment link. Payers never see
/// the internal split: they just pay the requested amount.
class PayPageScreen extends StatefulWidget {
  const PayPageScreen({super.key, required this.sandbox, required this.linkId});
  final PlSandbox sandbox;
  final String linkId;

  @override
  State<PayPageScreen> createState() => _PayPageScreenState();
}

class _PayPageScreenState extends State<PayPageScreen> {
  PlSandbox get sb => widget.sandbox;
  PaymentLink get l => sb.link(widget.linkId);
  final amount = TextEditingController();
  final name = TextEditingController();
  final email = TextEditingController();
  final ref = TextEditingController();
  PayMethod method = PayMethod.bankTransfer;
  LinkPayment? payment;
  String? error;
  String? result;
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && payment != null) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  void _start() {
    setState(() => error = null);
    try {
      final p = sb.startCheckout(
        l,
        amount: l.amountMode == AmountMode.fixed ? null : PlFmt.parse(amount.text, l.asset),
        method: l.asset.isFiat ? method : PayMethod.crypto,
        payerName: name.text.trim().isEmpty ? null : name.text.trim(),
        payerEmail: email.text.trim().isEmpty ? null : email.text.trim(),
        customerReference: ref.text,
      );
      setState(() => payment = p);
    } on PlException catch (e) {
      setState(() => error = e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: sb,
      builder: (context, _) => Scaffold(
        backgroundColor: const Color(0xFF07070A),
        appBar: AppBar(
          backgroundColor: const Color(0xFF07070A),
          title: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Image.asset('assets/brand/knock_mark_brand.png', height: 22, errorBuilder: (_, _, _) => const SizedBox()),
              const SizedBox(width: 8),
              const Text('KNOCK Pay'),
            ],
          ),
          actions: const [
            Padding(
              padding: EdgeInsets.only(right: 12),
              child: Center(child: Tag('SANDBOX', color: KnockColors.orange)),
            ),
          ],
        ),
        body: SafeArea(
          child: ListView(padding: const EdgeInsets.all(KnockSpace.gutter), children: payment == null ? _form() : _status(payment!)),
        ),
      ),
    );
  }

  List<Widget> _form() {
    final t = sb.totals(l.id);
    int? amt;
    if (l.amountMode == AmountMode.fixed) {
      amt = l.fixedAmount;
    } else {
      amt = PlFmt.parse(amount.text, l.asset);
    }
    final fee = amt == null ? 0 : PlSplit.fee(l.asset, amt);
    final total = amt == null ? null : amt + (l.feeBearer == FeeBearer.payer ? fee : 0);
    final closed = l.status != LinkStatus.active || (l.expiresAt != null && !l.expiresAt!.isAfter(sb.now));
    return [
      KnockCard(
        padding: const EdgeInsets.all(KnockSpace.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${l.creator.displayName} is requesting', style: KnockText.caption),
            const SizedBox(height: 6),
            Text(l.title, style: KnockText.title),
            if (l.description != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(l.description!, style: KnockText.body.copyWith(color: KnockColors.textSecondary)),
              ),
            const SizedBox(height: KnockSpace.md),
            if (l.amountMode == AmountMode.fixed)
              Text(PlFmt.money(l.fixedAmount!, l.asset), style: KnockText.display)
            else
              TextField(
                controller: amount,
                enabled: !closed,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                style: KnockText.display.copyWith(fontSize: 30),
                decoration: plInput('Amount', prefix: l.asset.isFiat ? '₦ ' : null, helper: l.asset.isFiat ? null : l.asset.code),
                onChanged: (_) => setState(() {}),
              ),
            if (l.target != null) ...[
              const SizedBox(height: KnockSpace.md),
              ProgressBar(t.collected / l.target!),
              const SizedBox(height: 6),
              Text(
                '${PlFmt.money(t.collected, l.asset, decimals: false)} of ${PlFmt.money(l.target!, l.asset, decimals: false)} collected',
                style: KnockText.micro,
              ),
            ],
            if (l.invoiceNumber != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text('Invoice ${l.invoiceNumber}', style: KnockText.micro),
              ),
            if (l.instructions != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(l.instructions!, style: KnockText.caption),
              ),
          ],
        ),
      ),
      const SizedBox(height: KnockSpace.md),
      if (closed)
        KnockCard(
          child: Text(
            'This payment link is ${l.status == LinkStatus.active ? 'expired' : l.status.label.toLowerCase()} and is not accepting payments.',
            style: KnockText.body,
          ),
        )
      else ...[
        if (l.asset.isFiat) ...[
          Text('Pay with', style: KnockText.bodyStrong),
          const SizedBox(height: KnockSpace.xs),
          PillTabs<PayMethod>(
            values: const [PayMethod.bankTransfer, PayMethod.card, PayMethod.ussd],
            selected: method,
            labelOf: (m) => m.label,
            onChanged: (m) => setState(() => method = m),
          ),
        ] else
          KnockCard(
            child: Column(
              children: [
                KvRow('Asset', l.asset.code),
                KvRow('Network', l.asset.network, valueColor: KnockColors.orange),
                KvRow(
                  'Rate',
                  '1 ${l.asset.code} ≈ ${PlFmt.money((sb.rateNgn(l.asset) * 100).round(), PlAsset.ngn, decimals: false)} (sandbox)',
                ),
                if (amt != null)
                  KvRow('Value', '≈ ${PlFmt.money((amt / 1000000 * sb.rateNgn(l.asset) * 100).round(), PlAsset.ngn, decimals: false)}'),
              ],
            ),
          ),
        const SizedBox(height: KnockSpace.md),
        TextField(controller: name, decoration: plInput('Your name (optional)')),
        const SizedBox(height: KnockSpace.sm),
        TextField(controller: email, keyboardType: TextInputType.emailAddress, decoration: plInput('Email for your receipt (optional)')),
        if (l.requireCustomerReference) ...[
          const SizedBox(height: KnockSpace.sm),
          TextField(controller: ref, decoration: plInput('Customer reference')),
        ],
        const SizedBox(height: KnockSpace.md),
        if (total != null)
          KnockCard(
            child: Column(
              children: [
                KvRow('Amount', PlFmt.money(amt!, l.asset)),
                if (l.feeBearer == FeeBearer.payer) KvRow('Fee', PlFmt.money(fee, l.asset)),
                KvRow('You pay', PlFmt.money(total, l.asset), strong: true),
              ],
            ),
          ),
        if (error != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(error!, style: KnockText.caption.copyWith(color: KnockColors.loss)),
          ),
        const SizedBox(height: KnockSpace.md),
        KnockButton(label: 'Pay securely', icon: Icons.lock_rounded, onPressed: _start),
        const SizedBox(height: KnockSpace.sm),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.verified_user_outlined, size: 14, color: KnockColors.textTertiary),
            const SizedBox(width: 6),
            Text(
              'Payments are verified with the provider before anyone is credited.',
              style: KnockText.micro.copyWith(color: KnockColors.textTertiary),
            ),
          ],
        ),
      ],
    ];
  }

  List<Widget> _status(LinkPayment p) {
    final done = p.status == PayStatus.succeeded || p.status == PayStatus.disputed;
    final isCrypto = !l.asset.isFiat;
    return [
      KnockCard(
        padding: const EdgeInsets.all(KnockSpace.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  done
                      ? Icons.check_circle_rounded
                      : p.status == PayStatus.failed
                      ? Icons.cancel_rounded
                      : Icons.hourglass_top_rounded,
                  color: done
                      ? KnockColors.greenBright
                      : p.status == PayStatus.failed
                      ? KnockColors.loss
                      : KnockColors.orange,
                ),
                const SizedBox(width: 8),
                Text(
                  done
                      ? 'Payment confirmed'
                      : p.status == PayStatus.failed
                      ? 'Payment failed'
                      : p.status == PayStatus.confirming
                      ? 'Confirming on chain'
                      : 'Waiting for your payment',
                  style: KnockText.headline,
                ),
              ],
            ),
            const SizedBox(height: KnockSpace.md),
            KvRow('Amount', PlFmt.money(p.totalToPay, l.asset), strong: true),
            KvRow('Reference', p.reference),
            KvRow('Status', p.status.label, valueColor: payStatusColor(p.status)),
            if (isCrypto) ...[
              const Divider(color: KnockColors.stroke),
              Text('Send exactly ${PlFmt.money(p.totalToPay, l.asset)} on ${l.asset.network} to:', style: KnockText.caption),
              const SizedBox(height: 6),
              Row(
                children: [
                  Expanded(child: SelectableText(p.address!, style: KnockText.number.copyWith(fontSize: 13))),
                  IconButton(
                    tooltip: 'Copy address',
                    icon: const Icon(Icons.copy_rounded, size: 18),
                    onPressed: () => Clipboard.setData(ClipboardData(text: p.address!)),
                  ),
                ],
              ),
              Text(
                'Only send ${l.asset.code} on ${l.asset.network}. Other coins or networks can be lost.',
                style: KnockText.micro.copyWith(color: KnockColors.orange),
              ),
              KvRow('Confirmations', '${p.confirmations} of ${l.asset.confirmations}'),
              if (p.txHash != null) KvRow('Transaction', '${p.txHash!.substring(0, 10)}…'),
              KvRow(
                'Quote expires',
                p.createdAt.add(const Duration(minutes: 15)).difference(sb.now).isNegative
                    ? 'Expired, rate refreshes'
                    : '${p.createdAt.add(const Duration(minutes: 15)).difference(sb.now).inMinutes} min',
              ),
            ] else if (p.method == PayMethod.bankTransfer && !done) ...[
              const Divider(color: KnockColors.stroke),
              Text('Transfer to this one-time account:', style: KnockText.caption),
              const KvRow('Bank', 'Sandbox Bank (not real)'),
              KvRow('Account number', '99${p.providerReference.hashCode.abs().toString().padLeft(8, '0').substring(0, 8)}'),
              const KvRow('Expires in', '30 minutes'),
            ],
          ],
        ),
      ),
      const SizedBox(height: KnockSpace.md),
      if (!done && p.status != PayStatus.failed) ...[
        Text('Sandbox: act as the payment provider', style: KnockText.bodyStrong),
        const SizedBox(height: 4),
        Text(
          'In the live product these events come from the provider as signed webhooks, and Knock re-checks each one with the provider before crediting.',
          style: KnockText.caption,
        ),
        const SizedBox(height: KnockSpace.sm),
        if (isCrypto) ...[
          KnockButton(
            label: 'Transaction seen (3 confirmations)',
            style: KnockButtonStyle.secondary,
            onPressed: () => setState(() => result = sb.simulateChain(p, 3)),
          ),
          const SizedBox(height: 8),
          KnockButton(
            label: 'Reach ${l.asset.confirmations} confirmations',
            onPressed: () => setState(() => result = sb.simulateChain(p, l.asset.confirmations)),
          ),
          const SizedBox(height: 8),
          KnockButton(
            label: 'Sent on the wrong network',
            style: KnockButtonStyle.ghost,
            onPressed: () => setState(() => result = sb.simulateChain(p, 30, network: 'ERC20')),
          ),
        ] else ...[
          KnockButton(label: 'Simulate successful payment', onPressed: () => setState(() => result = sb.simulateProviderPayment(p))),
          const SizedBox(height: 8),
          KnockButton(
            label: 'Simulate failed payment',
            style: KnockButtonStyle.secondary,
            onPressed: () => setState(() => result = sb.simulateProviderPayment(p, fail: true)),
          ),
          const SizedBox(height: 8),
          KnockButton(
            label: 'Payer transfers ₦1,000 less',
            style: KnockButtonStyle.ghost,
            onPressed: () =>
                setState(() => result = sb.simulateProviderPayment(p, amountPaid: (p.totalToPay - 100000).clamp(100, 1 << 62))),
          ),
          KnockButton(
            label: 'Fake (unsigned) webhook',
            style: KnockButtonStyle.ghost,
            onPressed: () => setState(() => result = sb.simulateProviderPayment(p, badSignature: true)),
          ),
        ],
      ],
      if (result != null)
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Text('Engine: $result', style: KnockText.micro.copyWith(color: KnockColors.greenBright)),
        ),
      if (done) ...[
        KnockButton(
          label: 'Share receipt',
          icon: Icons.receipt_long_rounded,
          style: KnockButtonStyle.secondary,
          onPressed: () => shareReceipt(sb, p),
        ),
        const SizedBox(height: 8),
        KnockButton(label: 'Done', onPressed: () => Navigator.of(context).pop()),
      ],
    ];
  }
}

String receiptText(PlSandbox sb, LinkPayment p) {
  final l = sb.link(p.linkId);
  return [
    'KNOCK payment receipt (SANDBOX)',
    'Paid to: ${l.creator.displayName} · ${l.title}',
    'Amount: ${PlFmt.money(p.totalToPay, l.asset)}',
    'Reference: ${p.reference}',
    'Link: ${l.reference}',
    if (l.invoiceNumber != null) 'Invoice: ${l.invoiceNumber}',
    if (p.customerReference != null && p.customerReference!.isNotEmpty) 'Your reference: ${p.customerReference}',
    'Method: ${p.method.label}',
    if (p.txHash != null) 'Transaction: ${p.txHash}',
    'Status: ${p.status.label}',
    'Date: ${PlFmt.dateTime(p.verifiedAt ?? p.createdAt)}',
  ].join('\n');
}

Future<void> shareReceipt(PlSandbox sb, LinkPayment p) => SharePlus.instance.share(
  ShareParams(
    subject: 'Knock receipt ${p.reference}',
    files: [XFile.fromData(utf8.encode(receiptText(sb, p)), mimeType: 'text/plain', name: 'knock-receipt-${p.reference}.txt')],
    text: receiptText(sb, p),
  ),
);
