import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../tokens.dart';

/// Smooth area chart drawn with a CustomPainter. Animates between series.
class AreaChart extends StatelessWidget {
  const AreaChart({
    super.key,
    required this.values,
    this.color = KnockColors.green,
    this.height = 120,
    this.strokeWidth = 2,
    this.fill = true,
    this.showEndDot = true,
    this.semanticLabel,
  });

  final List<double> values;
  final Color color;
  final double height;
  final double strokeWidth;
  final bool fill;
  final bool showEndDot;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    return Semantics(
      label: semanticLabel ?? 'Price chart',
      image: true,
      child: SizedBox(
        height: height,
        width: double.infinity,
        child: TweenAnimationBuilder<double>(
          key: ValueKey(values.length * 1000 + (values.isEmpty ? 0 : values.last.round())),
          tween: Tween(begin: reduceMotion ? 1 : 0, end: 1),
          duration: KnockMotion.slow,
          curve: KnockMotion.curve,
          builder: (context, t, _) =>
              CustomPaint(painter: _AreaPainter(values, color, strokeWidth, fill, showEndDot, t)),
        ),
      ),
    );
  }
}

class _AreaPainter extends CustomPainter {
  _AreaPainter(this.values, this.color, this.stroke, this.fill, this.dot, this.progress);
  final List<double> values;
  final Color color;
  final double stroke;
  final bool fill;
  final bool dot;
  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    if (values.length < 2) return;
    final minV = values.reduce(math.min);
    final maxV = values.reduce(math.max);
    final span = (maxV - minV).abs() < 1e-9 ? 1.0 : maxV - minV;
    final pad = stroke + 4;
    final pts = <Offset>[
      for (var i = 0; i < values.length; i++)
        Offset(i / (values.length - 1) * size.width, pad + (1 - (values[i] - minV) / span) * (size.height - pad * 2)),
    ];

    final path = Path()..moveTo(pts.first.dx, pts.first.dy);
    for (var i = 0; i < pts.length - 1; i++) {
      final p0 = pts[i];
      final p1 = pts[i + 1];
      final mid = (p0.dx + p1.dx) / 2;
      path.cubicTo(mid, p0.dy, mid, p1.dy, p1.dx, p1.dy);
    }

    canvas.save();
    canvas.clipRect(Rect.fromLTWH(0, 0, size.width * progress, size.height));
    if (fill) {
      final area = Path.from(path)
        ..lineTo(size.width, size.height)
        ..lineTo(0, size.height)
        ..close();
      canvas.drawPath(
        area,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [color.withValues(alpha: 0.28), color.withValues(alpha: 0.0)],
          ).createShader(Offset.zero & size),
      );
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
    canvas.restore();

    if (dot && progress > 0.98) {
      final end = pts.last;
      canvas.drawCircle(end, 7, Paint()..color = color.withValues(alpha: 0.25));
      canvas.drawCircle(end, 3.5, Paint()..color = color);
    }
  }

  @override
  bool shouldRepaint(_AreaPainter old) => old.values != values || old.progress != progress || old.color != color;
}

class Sparkline extends StatelessWidget {
  const Sparkline({super.key, required this.values, required this.positive, this.width = 64, this.height = 28});
  final List<double> values;
  final bool positive;
  final double width;
  final double height;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: SizedBox(
      width: width,
      child: AreaChart(
        values: values,
        height: height,
        color: positive ? KnockColors.gain : KnockColors.loss,
        strokeWidth: 1.5,
        showEndDot: false,
      ),
    ),
  );
}
