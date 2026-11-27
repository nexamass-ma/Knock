import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/money.dart';
import '../tokens.dart';

/// Rounded dark card with a hairline border.
class KnockCard extends StatelessWidget {
  const KnockCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(KnockSpace.md),
    this.onTap,
    this.color = KnockColors.surface,
    this.gradient,
    this.radius = KnockRadius.lg,
    this.semanticLabel,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final VoidCallback? onTap;
  final Color color;
  final Gradient? gradient;
  final double radius;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(radius),
      side: const BorderSide(color: KnockColors.stroke),
    );
    final content = Ink(
      decoration: ShapeDecoration(shape: shape, color: gradient == null ? color : null, gradient: gradient),
      child: Padding(padding: padding, child: child),
    );
    return Semantics(
      label: semanticLabel,
      button: onTap != null,
      container: true,
      child: Material(
        type: MaterialType.transparency,
        child: onTap == null
            ? content
            : InkWell(
                customBorder: shape,
                onTap: () {
                  HapticFeedback.selectionClick();
                  onTap!();
                },
                child: content,
              ),
      ),
    );
  }
}

/// Frosted circular icon button used on the hero and headers.
class GlassIconButton extends StatelessWidget {
  const GlassIconButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.size = 44,
    this.badge = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final double size;
  final bool badge;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: label,
      child: Tooltip(
        message: label,
        child: InkResponse(
          onTap: onTap,
          radius: size / 2 + 4,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Container(
                width: size,
                height: size,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.white.withValues(alpha: 0.10),
                  border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
                ),
                child: Icon(icon, size: size * 0.42, color: KnockColors.textPrimary),
              ),
              if (badge)
                Positioned(
                  right: 10,
                  top: 10,
                  child: Container(
                    width: 8,
                    height: 8,
                    decoration: const BoxDecoration(color: KnockColors.orange, shape: BoxShape.circle),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Circular quick action with a caption underneath.
class CircleAction extends StatelessWidget {
  const CircleAction({super.key, required this.icon, required this.label, required this.onTap});
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: label,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          HapticFeedback.selectionClick();
          onTap();
        },
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.black.withValues(alpha: 0.22),
                border: Border.all(color: Colors.white.withValues(alpha: 0.14)),
              ),
              child: Icon(icon, size: 22, color: KnockColors.textPrimary),
            ),
            const SizedBox(height: 6),
            Text(label, style: KnockText.micro.copyWith(color: Colors.white.withValues(alpha: 0.78))),
          ],
        ),
      ),
    );
  }
}

/// Segmented pill tabs. The selected pill is KNOCK green.
class PillTabs<T> extends StatelessWidget {
  const PillTabs({
    super.key,
    required this.values,
    required this.selected,
    required this.labelOf,
    required this.onChanged,
    this.dense = false,
    this.background = KnockColors.surface,
  });

  final List<T> values;
  final T selected;
  final String Function(T) labelOf;
  final ValueChanged<T> onChanged;
  final bool dense;
  final Color background;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(KnockRadius.pill),
        border: Border.all(color: KnockColors.stroke),
      ),
      child: Row(
        children: [
          for (final v in values)
            Expanded(
              child: Semantics(
                selected: v == selected,
                button: true,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () {
                    HapticFeedback.selectionClick();
                    onChanged(v);
                  },
                  child: AnimatedContainer(
                    duration: KnockMotion.base,
                    curve: KnockMotion.curve,
                    padding: EdgeInsets.symmetric(vertical: dense ? 7 : 10),
                    decoration: BoxDecoration(
                      color: v == selected ? KnockColors.green : Colors.transparent,
                      borderRadius: BorderRadius.circular(KnockRadius.pill),
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      labelOf(v),
                      style: (dense ? KnockText.micro : KnockText.caption).copyWith(
                        fontWeight: FontWeight.w600,
                        color: v == selected ? KnockColors.onGreen : KnockColors.textSecondary,
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Small rounded label, e.g. "MOCK", "Coming soon", ticker chips.
class Tag extends StatelessWidget {
  const Tag(this.text, {super.key, this.color = KnockColors.textSecondary, this.fill, this.icon});
  final String text;
  final Color color;
  final Color? fill;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: fill ?? color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(KnockRadius.pill),
        border: Border.all(color: color.withValues(alpha: 0.22)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[Icon(icon, size: 12, color: color), const SizedBox(width: 4)],
          Text(text, style: KnockText.micro.copyWith(color: color)),
        ],
      ),
    );
  }
}

/// Marks data that does not come from a live backend.
class MockBadge extends StatelessWidget {
  const MockBadge({super.key, this.label = 'MOCK DATA'});
  final String label;
  @override
  Widget build(BuildContext context) => Semantics(
    label: 'Sample data, not live',
    child: Tag(label, color: KnockColors.orange, icon: Icons.science_outlined),
  );
}

class ChangeText extends StatelessWidget {
  const ChangeText(this.percent, {super.key, this.style = KnockText.caption});
  final double percent;
  final TextStyle style;
  @override
  Widget build(BuildContext context) {
    final up = percent >= 0;
    return Text(
      Fmt.percent(percent),
      style: style.copyWith(color: up ? KnockColors.gain : KnockColors.loss, fontWeight: FontWeight.w600),
      semanticsLabel: '${up ? 'up' : 'down'} ${percent.abs().toStringAsFixed(2)} percent',
    );
  }
}

class SectionHeader extends StatelessWidget {
  const SectionHeader(this.title, {super.key, this.action, this.onAction, this.trailing});
  final String title;
  final String? action;
  final VoidCallback? onAction;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(KnockSpace.gutter, KnockSpace.xl, KnockSpace.gutter, KnockSpace.sm),
      child: Row(
        children: [
          Expanded(
            child: Text(title, style: KnockText.headline, semanticsLabel: title),
          ),
          ?trailing,
          if (action != null)
            TextButton(
              onPressed: onAction,
              style: TextButton.styleFrom(foregroundColor: KnockColors.textSecondary),
              child: Text(action!, style: KnockText.caption),
            ),
        ],
      ),
    );
  }
}

/// Circular token / brand avatar drawn from a glyph, no image assets.
class GlyphAvatar extends StatelessWidget {
  const GlyphAvatar({super.key, required this.glyph, required this.tint, this.size = 44});
  final String glyph;
  final Color tint;
  final double size;

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(colors: [tint.withValues(alpha: 0.32), tint.withValues(alpha: 0.10)]),
          border: Border.all(color: tint.withValues(alpha: 0.35)),
        ),
        alignment: Alignment.center,
        child: Text(
          glyph,
          style: TextStyle(fontSize: size * 0.42, fontWeight: FontWeight.w700, color: tint, height: 1),
        ),
      ),
    );
  }
}

enum KnockButtonStyle { primary, secondary, ghost, light }

class KnockButton extends StatelessWidget {
  const KnockButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.style = KnockButtonStyle.primary,
    this.loading = false,
    this.expand = true,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final KnockButtonStyle style;
  final bool loading;
  final bool expand;

  @override
  Widget build(BuildContext context) {
    final (bg, fg) = switch (style) {
      KnockButtonStyle.primary => (KnockColors.green, KnockColors.onGreen),
      KnockButtonStyle.secondary => (KnockColors.surfaceHigh, KnockColors.textPrimary),
      KnockButtonStyle.ghost => (Colors.transparent, KnockColors.textPrimary),
      KnockButtonStyle.light => (Colors.white, KnockColors.textPrimary),
    };
    final enabled = onPressed != null && !loading;
    final child = Row(
      mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (loading)
          SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: fg))
        else ...[
          if (icon != null) ...[Icon(icon, size: 18, color: fg), const SizedBox(width: 8)],
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: KnockText.bodyStrong.copyWith(color: fg),
            ),
          ),
        ],
      ],
    );
    return Semantics(
      button: true,
      enabled: enabled,
      label: loading ? '$label, in progress' : label,
      excludeSemantics: true,
      child: AnimatedOpacity(
        duration: KnockMotion.fast,
        opacity: enabled || loading ? 1 : 0.45,
        child: Material(
          color: bg,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(KnockRadius.pill),
            side: style == KnockButtonStyle.ghost ? const BorderSide(color: KnockColors.strokeStrong) : BorderSide.none,
          ),
          child: InkWell(
            borderRadius: BorderRadius.circular(KnockRadius.pill),
            onTap: enabled
                ? () {
                    HapticFeedback.lightImpact();
                    onPressed!();
                  }
                : null,
            child: Padding(padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 15), child: child),
          ),
        ),
      ),
    );
  }
}

/// Text that masks itself when balances are hidden.
class BalanceText extends StatelessWidget {
  const BalanceText(this.value, {super.key, required this.hidden, this.style = KnockText.number});
  final String value;
  final bool hidden;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: KnockMotion.base,
      transitionBuilder: (c, a) => FadeTransition(opacity: a, child: c),
      child: Text(
        hidden ? '••••••' : value,
        key: ValueKey(hidden ? 'h' : value),
        style: style,
        semanticsLabel: hidden ? 'Hidden balance' : value,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}
