import 'package:material_ui/material_ui.dart';

import '../../design/tokens.dart';

/// The KNOCK wordmark: the supplied door-knock mark plus "KNOCK" set in
/// the platform font. [Guess] The supplied wordmark reads "Knocking"; the
/// app keeps the product name KNOCK until the team confirms.
class KnockWordmark extends StatelessWidget {
  const KnockWordmark({super.key, this.size = 18, this.color = KnockColors.textPrimary});
  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'KNOCK',
      excludeSemantics: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          KnockMark(size: size * 1.5),
          SizedBox(width: size * 0.4),
          Text(
            'KNOCK',
            style: TextStyle(
              fontSize: size,
              fontWeight: FontWeight.w800,
              letterSpacing: size * 0.12,
              color: color,
              height: 1,
            ),
          ),
        ],
      ),
    );
  }
}

enum KnockMarkTone { brand, white }

/// The KNOCK door-knock mark from the supplied logo, recoloured to the
/// brand green #00B03C and orange #FF5001 for the dark UI.
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
      ),
    );
  }
}
