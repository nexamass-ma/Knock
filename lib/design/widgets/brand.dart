import 'package:material_ui/material_ui.dart';

import '../tokens.dart';

/// The Knock wordmark: the door-knock mark plus "Knock".
class KnockWordmark extends StatelessWidget {
  const KnockWordmark({super.key, this.size = 18, this.color = KnockColors.textPrimary});
  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Knock',
      excludeSemantics: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          KnockMark(size: size * 1.5),
          SizedBox(width: size * 0.4),
          Text('Knock', style: TextStyle(fontSize: size * 1.1, fontWeight: FontWeight.w800, letterSpacing: -0.4, color: color, height: 1)),
        ],
      ),
    );
  }
}

enum KnockMarkTone { brand, white }

class KnockMark extends StatelessWidget {
  const KnockMark({super.key, this.size = 20, this.tone = KnockMarkTone.brand});
  final double size;
  final KnockMarkTone tone;

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: Image.asset(
        tone == KnockMarkTone.white ? 'assets/brand/knock_mark_white.png' : 'assets/brand/knock_mark_brand.png',
        width: size,
        height: size,
        fit: BoxFit.contain,
        filterQuality: FilterQuality.medium,
        errorBuilder: (_, _, _) => Icon(Icons.door_front_door_rounded, size: size, color: KnockColors.green),
      ),
    );
  }
}
