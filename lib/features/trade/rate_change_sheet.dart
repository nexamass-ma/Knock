import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../api/api.dart';
import '../../core/format.dart';
import '../../design/tokens.dart';
import '../../design/widgets/kit.dart';

enum RateChoice { accept, cancel }

/// The "Hey Chief!" live rate-change notice. The customer must choose; it
/// cannot be dismissed by tapping outside.
Future<RateChoice?> showRateChangeSheet(BuildContext context, {required Json cmp, required String currency, bool heyChief = true}) {
  HapticFeedback.heavyImpact();
  return showModalBottomSheet<RateChoice>(
    context: context,
    isDismissible: false,
    enableDrag: false,
    isScrollControlled: true,
    builder: (_) => RateChangeView(cmp: cmp, currency: currency, heyChief: heyChief),
  );
}

class RateChangeView extends StatelessWidget {
  const RateChangeView({super.key, required this.cmp, required this.currency, this.heyChief = true});
  final Json cmp;
  final String currency;
  final bool heyChief;

  @override
  Widget build(BuildContext context) {
    final up = cmp['direction'] == 'up';
    final expired = cmp['reason'] == 'lock_expired';
    final oldRate = cmp['oldRateKobo'] as int;
    final newRate = cmp['newRateKobo'] as int;
    final diff = cmp['differenceKobo'] as int;
    final prefix = heyChief ? 'Hey Chief! ' : '';
    final headline = up ? '${prefix}Good news. Your rate just went up!' : '${prefix}Your rate just changed.';
    final color = up ? KnockColors.greenBright : KnockColors.orange;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          TweenAnimationBuilder<double>(
            tween: Tween(begin: 0.5, end: 1),
            duration: const Duration(milliseconds: 600),
            curve: Curves.elasticOut,
            builder: (_, v, c) => Transform.scale(scale: v, alignment: Alignment.centerLeft, child: c),
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: color.withValues(alpha: 0.14), shape: BoxShape.circle),
              child: Icon(up ? Icons.trending_up_rounded : Icons.sync_alt_rounded, color: color, size: 28),
            ),
          ),
          const SizedBox(height: 14),
          Text(headline, key: const ValueKey('rate-change-title'), style: KnockText.title),
          const SizedBox(height: 8),
          Text(
            expired
                ? 'Your locked rate has expired. ${up ? 'The current rate is better.' : 'The previous rate is no longer available.'} Your new rate is ${F.rate(newRate, currency)}.'
                : up
                    ? 'Your new rate is ${F.rate(newRate, currency)}.'
                    : 'The previous rate is no longer available. Your new rate is ${F.rate(newRate, currency)}.',
            style: KnockText.body.copyWith(color: KnockColors.textSecondary),
          ),
          const SizedBox(height: 16),
          KnockCard(
            color: KnockColors.surfaceRaised,
            child: Column(children: [
              _Row('Rate', F.rate(oldRate, currency), F.rate(newRate, currency), color),
              const Divider(height: 18),
              _Row('Payout', F.ngnExact(cmp['oldNetKobo'] as int), F.ngnExact(cmp['newNetKobo'] as int), color),
              const Divider(height: 18),
              Row(children: [
                Text('Difference', style: KnockText.caption),
                const Spacer(),
                Text('${diff >= 0 ? '+' : '−'}${F.ngnExact(diff.abs())}', key: const ValueKey('rate-change-diff'), style: KnockText.bodyStrong.copyWith(color: diff >= 0 ? KnockColors.greenBright : KnockColors.loss)),
              ]),
            ]),
          ),
          const SizedBox(height: 10),
          Text(
            up ? 'Your estimated payout is now ${F.ngnExact(cmp['newNetKobo'] as int)}, after fees. Nothing changes until you confirm.' : 'Your estimated payout is now ${F.ngnExact(cmp['newNetKobo'] as int)}, after fees. We never change your payout without your consent.',
            style: KnockText.caption,
          ),
          const SizedBox(height: 18),
          KnockButton(key: const ValueKey('rate-accept'), label: 'Continue with New Rate', onPressed: () => Navigator.pop(context, RateChoice.accept)),
          const SizedBox(height: 10),
          KnockButton(key: const ValueKey('rate-cancel'), label: 'Cancel Trade', style: KnockButtonStyle.ghost, onPressed: () => Navigator.pop(context, RateChoice.cancel)),
        ]),
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row(this.label, this.oldV, this.newV, this.color);
  final String label, oldV, newV;
  final Color color;
  @override
  Widget build(BuildContext context) => Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
    SizedBox(width: 70, child: Text(label, style: KnockText.caption)),
    Expanded(
      child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
        Text(oldV, style: KnockText.caption.copyWith(decoration: TextDecoration.lineThrough)),
        const SizedBox(height: 2),
        Text(newV, style: KnockText.bodyStrong.copyWith(color: color)),
      ]),
    ),
  ]);
}
