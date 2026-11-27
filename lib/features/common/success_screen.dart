import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../api/api.dart';
import '../../core/format.dart';
import '../../design/tokens.dart';
import '../../design/widgets/kit.dart';
import 'receipt.dart';

/// Animated result screen after any money movement.
class ResultScreen extends StatelessWidget {
  const ResultScreen({
    super.key,
    required this.title,
    this.success = true,
    this.amountKobo,
    this.amountLabel,
    this.message,
    this.txn,
    this.nextLabel,
    this.onNext,
    this.extra = const [],
  });

  final String title;
  final bool success;
  final int? amountKobo;
  final String? amountLabel;
  final String? message;
  final Json? txn;
  final String? nextLabel;
  final VoidCallback? onNext;
  final List<Widget> extra;

  @override
  Widget build(BuildContext context) {
    final t = txn;
    final settlement = (t?['details'] as Map?)?['settlement'] as String?;
    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(KnockSpace.gutter),
          children: [
            const SizedBox(height: 32),
            Center(child: ResultBurst(success: success)),
            const SizedBox(height: 24),
            Text(title, style: KnockText.title, textAlign: TextAlign.center),
            if (amountKobo != null || amountLabel != null) ...[
              const SizedBox(height: 10),
              TweenAnimationBuilder<double>(
                tween: Tween(begin: 0, end: (amountKobo ?? 0).toDouble()),
                duration: const Duration(milliseconds: 900),
                curve: Curves.easeOutCubic,
                builder: (_, v, _) => Text(amountLabel ?? F.ngnExact(v.round()), style: KnockText.display, textAlign: TextAlign.center),
              ),
            ],
            if (message != null) ...[
              const SizedBox(height: 10),
              Text(message!, style: KnockText.body.copyWith(color: KnockColors.textSecondary), textAlign: TextAlign.center),
            ],
            const SizedBox(height: 24),
            if (t != null)
              KnockCard(
                child: Column(children: [
                  KeyValue('Reference', t['reference'] as String, copy: true),
                  KeyValue('Status', F.status(t['status'] as String)),
                  if (settlement != null) KeyValue('Settlement', settlement),
                  KeyValue('Date', F.dateTime(t['createdAt'] as String)),
                  if ((t['fee'] as int? ?? 0) > 0) KeyValue('Fee', F.ngnExact(t['fee'] as int)),
                ]),
              ),
            ...extra,
            const SizedBox(height: 24),
            if (onNext != null) ...[
              KnockButton(key: const ValueKey('result-next'), label: nextLabel ?? 'Continue', onPressed: onNext),
              const SizedBox(height: 10),
            ],
            if (t != null) ...[
              KnockButton(label: 'Share receipt', icon: Icons.ios_share_rounded, style: KnockButtonStyle.secondary, onPressed: () => shareReceipt(context, t)),
              const SizedBox(height: 10),
            ],
            KnockButton(
              key: const ValueKey('result-done'),
              label: 'Done',
              style: KnockButtonStyle.ghost,
              onPressed: () {
                HapticFeedback.selectionClick();
                Navigator.of(context).popUntil((r) => r.isFirst);
              },
            ),
          ],
        ),
      ),
    );
  }
}
