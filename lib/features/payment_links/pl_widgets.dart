import 'package:material_ui/material_ui.dart';

import '../../design/tokens.dart';
import '../../design/widgets/surfaces.dart';
import 'pl_models.dart';

/// Shown on every Payment Links screen: nothing here moves real money yet.
class SandboxBanner extends StatelessWidget {
  const SandboxBanner({super.key, this.text = 'SANDBOX · simulated payments, no real money moves'});
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: KnockSpace.md, vertical: 8),
      decoration: BoxDecoration(
        color: KnockColors.orangeSoft,
        borderRadius: BorderRadius.circular(KnockRadius.sm),
        border: Border.all(color: KnockColors.orange.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          const Icon(Icons.science_outlined, size: 16, color: KnockColors.orange),
          const SizedBox(width: 8),
          Expanded(
            child: Text(text, style: KnockText.micro.copyWith(color: KnockColors.orange)),
          ),
        ],
      ),
    );
  }
}

Color linkStatusColor(LinkStatus s) => switch (s) {
  LinkStatus.active => KnockColors.greenBright,
  LinkStatus.completed => const Color(0xFF6FB7FF),
  LinkStatus.paused => KnockColors.orange,
  LinkStatus.underReview => KnockColors.loss,
  LinkStatus.expired || LinkStatus.closed => KnockColors.textTertiary,
};

Color payStatusColor(PayStatus s) => switch (s) {
  PayStatus.succeeded => KnockColors.greenBright,
  PayStatus.failed || PayStatus.reversed => KnockColors.loss,
  PayStatus.disputed => KnockColors.orange,
  _ => KnockColors.textSecondary,
};

Color allocColor(AllocState s) => switch (s) {
  AllocState.available => KnockColors.greenBright,
  AllocState.pending => KnockColors.orange,
  AllocState.held => KnockColors.loss,
  AllocState.reversed => KnockColors.textTertiary,
};

IconData linkTypeIcon(LinkType t) => switch (t) {
  LinkType.naira => Icons.account_balance_wallet_outlined,
  LinkType.crypto => Icons.currency_bitcoin_rounded,
  LinkType.split => Icons.call_split_rounded,
};

class StatusTag extends StatelessWidget {
  const StatusTag(this.label, this.color, {super.key});
  final String label;
  final Color color;
  @override
  Widget build(BuildContext context) => Tag(label, color: color);
}

class UserAvatar extends StatelessWidget {
  const UserAvatar(this.user, {super.key, this.size = 38});
  final KnockUser user;
  final double size;

  @override
  Widget build(BuildContext context) {
    final tints = [KnockColors.green, KnockColors.orange, const Color(0xFF8C7BFF), const Color(0xFF4FC3F7), const Color(0xFFFFB74D)];
    final tint = tints[user.username.codeUnits.fold<int>(0, (a, b) => a + b) % tints.length];
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: tint.withValues(alpha: 0.18),
        border: Border.all(color: tint.withValues(alpha: 0.4)),
      ),
      child: Text(
        user.initials,
        style: KnockText.micro.copyWith(color: tint, fontSize: size * 0.32),
      ),
    );
  }
}

class ProgressBar extends StatelessWidget {
  const ProgressBar(this.value, {super.key, this.height = 8});
  final double value;
  final double height;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(KnockRadius.pill),
      child: SizedBox(
        height: height,
        child: Stack(
          children: [
            Container(color: KnockColors.surfaceHigh),
            FractionallySizedBox(
              widthFactor: value.clamp(0, 1).toDouble(),
              child: Container(
                decoration: const BoxDecoration(gradient: LinearGradient(colors: [KnockColors.green, KnockColors.greenBright])),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class KvRow extends StatelessWidget {
  const KvRow(this.label, this.value, {super.key, this.strong = false, this.valueColor});
  final String label;
  final String value;
  final bool strong;
  final Color? valueColor;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: Text(label, style: KnockText.caption)),
          const SizedBox(width: 12),
          Flexible(
            child: Text(
              value,
              textAlign: TextAlign.right,
              style: (strong ? KnockText.bodyStrong : KnockText.number).copyWith(color: valueColor),
            ),
          ),
        ],
      ),
    );
  }
}

/// Large selectable option card used throughout the create flow.
class ChoiceCard extends StatelessWidget {
  const ChoiceCard({
    super.key,
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.onTap,
    this.icon,
    this.badge,
  });
  final String title;
  final String subtitle;
  final bool selected;
  final VoidCallback onTap;
  final IconData? icon;
  final String? badge;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: KnockSpace.sm),
      child: Semantics(
        selected: selected,
        child: KnockCard(
          onTap: onTap,
          color: selected ? KnockColors.greenSoft : KnockColors.surface,
          child: Row(
            children: [
              if (icon != null) ...[
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: (selected ? KnockColors.green : KnockColors.surfaceHigh).withValues(alpha: selected ? 0.25 : 1),
                  ),
                  child: Icon(icon, color: selected ? KnockColors.greenBright : KnockColors.textPrimary, size: 22),
                ),
                const SizedBox(width: KnockSpace.sm),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(child: Text(title, style: KnockText.bodyStrong)),
                        if (badge != null) ...[const SizedBox(width: 8), Tag(badge!, color: KnockColors.orange)],
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(subtitle, style: KnockText.caption),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Icon(
                selected ? Icons.radio_button_checked_rounded : Icons.radio_button_off_rounded,
                color: selected ? KnockColors.greenBright : KnockColors.textTertiary,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

InputDecoration plInput(String label, {String? hint, String? prefix, String? helper, String? error}) => InputDecoration(
  labelText: label,
  hintText: hint,
  prefixText: prefix,
  helperText: helper,
  errorText: error,
  helperMaxLines: 3,
  filled: true,
  fillColor: KnockColors.surface,
  border: OutlineInputBorder(
    borderRadius: BorderRadius.circular(KnockRadius.sm),
    borderSide: const BorderSide(color: KnockColors.stroke),
  ),
  enabledBorder: OutlineInputBorder(
    borderRadius: BorderRadius.circular(KnockRadius.sm),
    borderSide: const BorderSide(color: KnockColors.stroke),
  ),
  focusedBorder: OutlineInputBorder(
    borderRadius: BorderRadius.circular(KnockRadius.sm),
    borderSide: const BorderSide(color: KnockColors.green),
  ),
);

void plToast(BuildContext context, String message, {bool error = false}) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        backgroundColor: error ? const Color(0xFF3A1717) : KnockColors.surfaceHigh,
      ),
    );
}
