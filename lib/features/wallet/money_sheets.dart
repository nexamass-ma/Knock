import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../design/tokens.dart';
import '../../design/widgets/surfaces.dart';

/// Deposit: a dedicated virtual account per user, issued by the Naira
/// wallet partner. Mock details shown.
Future<void> showDepositSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(KnockSpace.gutter, 0, KnockSpace.gutter, KnockSpace.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Text('Add money', style: KnockText.title),
                Spacer(),
                MockBadge(label: 'MOCK'),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'Transfer to your KNOCK account from any Nigerian bank. Funds arrive in your Naira wallet.',
              style: KnockText.caption,
            ),
            const SizedBox(height: KnockSpace.lg),
            KnockCard(
              color: KnockColors.surfaceRaised,
              child: Column(
                children: [
                  _row('Bank', 'Partner MFB (mock)'),
                  const Divider(height: 24),
                  _row('Account number', '9 012 345 678', copy: '9012345678', context: ctx),
                  const Divider(height: 24),
                  _row('Account name', 'KNOCK / Ada Okafor'),
                ],
              ),
            ),
            const SizedBox(height: KnockSpace.md),
            Text(
              'Transfers usually reflect within a minute. Daily inflow limit depends on your verification level.',
              style: KnockText.micro.copyWith(fontWeight: FontWeight.w400),
            ),
            const SizedBox(height: KnockSpace.lg),
            KnockButton(label: 'Done', onPressed: () => Navigator.of(ctx).pop(), style: KnockButtonStyle.secondary),
          ],
        ),
      ),
    ),
  );
}

Widget _row(String k, String v, {String? copy, BuildContext? context}) {
  return Row(
    children: [
      Text(k, style: KnockText.caption),
      const Spacer(),
      Text(v, style: KnockText.bodyStrong),
      if (copy != null) ...[
        const SizedBox(width: 6),
        IconButton(
          tooltip: 'Copy account number',
          visualDensity: VisualDensity.compact,
          icon: const Icon(Icons.copy_rounded, size: 17, color: KnockColors.green),
          onPressed: () {
            Clipboard.setData(ClipboardData(text: copy));
            if (context != null) {
              ScaffoldMessenger.maybeOf(context)?.showSnackBar(const SnackBar(content: Text('Account number copied')));
            }
          },
        ),
      ],
    ],
  );
}

Future<void> showWithdrawSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(ctx).bottom),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(KnockSpace.gutter, 0, KnockSpace.gutter, KnockSpace.lg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Row(
                children: [
                  Text('Withdraw', style: KnockText.title),
                  Spacer(),
                  MockBadge(label: 'MOCK'),
                ],
              ),
              const SizedBox(height: 4),
              Text('Send money from your Naira wallet to a saved bank account.', style: KnockText.caption),
              const SizedBox(height: KnockSpace.lg),
              KnockCard(
                color: KnockColors.surfaceRaised,
                child: const Row(
                  children: [
                    GlyphAvatar(glyph: 'G', tint: Color(0xFFFF7A00), size: 38),
                    SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('GTBank · 0123 *** 789', style: KnockText.bodyStrong),
                          Text('Ada Okafor', style: KnockText.caption),
                        ],
                      ),
                    ),
                    Icon(Icons.check_circle_rounded, color: KnockColors.green),
                  ],
                ),
              ),
              const SizedBox(height: KnockSpace.md),
              const TextField(
                keyboardType: TextInputType.number,
                decoration: InputDecoration(hintText: 'Amount in ₦', prefixText: '₦ '),
              ),
              const SizedBox(height: KnockSpace.lg),
              KnockButton(
                label: 'Continue',
                onPressed: () {
                  Navigator.of(ctx).pop();
                  ScaffoldMessenger.maybeOf(context)
                      ?.showSnackBar(const SnackBar(content: Text('Withdrawals are not wired up in this prototype.')));
                },
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
