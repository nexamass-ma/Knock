import 'package:material_ui/material_ui.dart';

import '../tokens.dart';
import 'surfaces.dart';

/// Pulsing placeholder block for loading states.
class Skeleton extends StatefulWidget {
  const Skeleton({super.key, this.height = 16, this.width, this.radius = KnockRadius.sm});
  final double height;
  final double? width;
  final double radius;

  @override
  State<Skeleton> createState() => _SkeletonState();
}

class _SkeletonState extends State<Skeleton> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1100))
    ..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: Tween(begin: 0.45, end: 1.0).animate(_c),
      child: Container(
        height: widget.height,
        width: widget.width,
        decoration: BoxDecoration(color: KnockColors.surfaceRaised, borderRadius: BorderRadius.circular(widget.radius)),
      ),
    );
  }
}

class SkeletonList extends StatelessWidget {
  const SkeletonList({super.key, this.rows = 4});
  final int rows;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Loading',
      child: Column(
        children: [
          for (var i = 0; i < rows; i++)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: KnockSpace.gutter, vertical: 6),
              child: Row(
                children: [
                  const Skeleton(height: 44, width: 44, radius: 22),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Skeleton(height: 14, width: 120 + (i % 3) * 20.0),
                        const SizedBox(height: 8),
                        const Skeleton(height: 12, width: 80),
                      ],
                    ),
                  ),
                  const Skeleton(height: 14, width: 70),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
    this.action,
    this.onAction,
  });
  final IconData icon;
  final String title;
  final String message;
  final String? action;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 48),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 64,
            height: 64,
            decoration: const BoxDecoration(color: KnockColors.surfaceRaised, shape: BoxShape.circle),
            child: Icon(icon, color: KnockColors.textSecondary, size: 28),
          ),
          const SizedBox(height: KnockSpace.md),
          Text(title, style: KnockText.headline, textAlign: TextAlign.center),
          const SizedBox(height: 6),
          Text(message, style: KnockText.caption, textAlign: TextAlign.center),
          if (action != null) ...[
            const SizedBox(height: KnockSpace.lg),
            KnockButton(label: action!, onPressed: onAction, expand: false, style: KnockButtonStyle.secondary),
          ],
        ],
      ),
    );
  }
}

class ErrorState extends StatelessWidget {
  const ErrorState({super.key, required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => EmptyState(
    icon: Icons.wifi_off_rounded,
    title: 'Something went wrong',
    message: message,
    action: 'Try again',
    onAction: onRetry,
  );
}
