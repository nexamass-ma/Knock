import 'package:material_ui/material_ui.dart';

/// KNOCK design tokens.
///
/// Brand colours come from the swatches supplied by the founder:
///   green  #00B03C  (primary, highlights, selected states)
///   orange #FF5001  (sparing accent: alerts, "coming soon", warm glow)
///
/// The hero gradient keeps the muted-violet mood of the style reference and
/// lets it warm into KNOCK orange. [Guess] Swap [KnockColors.heroGradient]
/// for a green-led gradient if the team prefers less violet.
abstract final class KnockColors {
  // Surfaces (bright: warm off-white, white cards).
  static const background = Color(0xFFF6F9F3);
  static const surface = Color(0xFFFFFFFF);
  static const surfaceRaised = Color(0xFFF1F6EE);
  static const surfaceHigh = Color(0xFFE6EEE2);
  static const stroke = Color(0x14000000); // 8% black
  static const strokeStrong = Color(0x24000000);

  // Text.
  static const textPrimary = Color(0xFF10291C);
  static const textSecondary = Color(0xFF4F5F55);
  static const textTertiary = Color(0xFF7D8A82);
  static const onGreen = Color(0xFF04120A);

  // Brand.
  static const green = Color(0xFF00B03C);
  static const greenBright = Color(0xFF00953A); // darker so it reads on white
  static const greenSoft = Color(0x2600B03C); // 15%
  static const orange = Color(0xFFFF5001);
  static const orangeSoft = Color(0x26FF5001);

  // Mood colours used only inside gradients.
  static const violetDeep = Color(0xFF0B7A3E);
  static const violet = Color(0xFF00A63C);
  static const violetMuted = Color(0xFF3DBE62);
  static const ember = Color(0xFFFF7A1A);

  // Semantic.
  static const gain = greenBright;
  static const loss = Color(0xFFD63B2F);
  static const warning = orange;

  static const heroGradient = LinearGradient(
    begin: Alignment(-1.0, -1.0),
    end: Alignment(1.0, 1.1),
    colors: [violetDeep, violet, violetMuted, ember],
    stops: [0.0, 0.45, 0.8, 1.0],
  );

  static const cardGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFF0B7A3E), Color(0xFF00A63C), Color(0xFF1FBF5B)],
  );

  static const dollarCardGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFFE5480A), Color(0xFFFF5001), Color(0xFFFF8A3D)],
  );
}

abstract final class KnockSpace {
  static const xxs = 4.0;
  static const xs = 8.0;
  static const sm = 12.0;
  static const md = 16.0;
  static const lg = 20.0;
  static const xl = 24.0;
  static const xxl = 32.0;
  static const gutter = 20.0;
}

abstract final class KnockRadius {
  static const sm = 12.0;
  static const md = 18.0;
  static const lg = 24.0;
  static const xl = 32.0;
  static const pill = 999.0;
}

/// Typography. Uses the platform font (SF Pro on iOS, Roboto on Android)
/// with tight tracking for numbers so balances feel premium.
abstract final class KnockText {
  static const _num = [FontFeature.tabularFigures()];

  static const display = TextStyle(
    fontSize: 40,
    height: 1.05,
    fontWeight: FontWeight.w600,
    letterSpacing: -1.4,
    color: KnockColors.textPrimary,
    fontFeatures: _num,
  );
  static const title = TextStyle(
    fontSize: 24,
    height: 1.15,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.6,
    color: KnockColors.textPrimary,
  );
  static const headline = TextStyle(
    fontSize: 18,
    height: 1.2,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.3,
    color: KnockColors.textPrimary,
  );
  static const body = TextStyle(fontSize: 15, height: 1.4, fontWeight: FontWeight.w400, color: KnockColors.textPrimary);
  static const bodyStrong = TextStyle(
    fontSize: 15,
    height: 1.35,
    fontWeight: FontWeight.w600,
    color: KnockColors.textPrimary,
  );
  static const caption = TextStyle(
    fontSize: 13,
    height: 1.3,
    fontWeight: FontWeight.w400,
    color: KnockColors.textSecondary,
  );
  static const micro = TextStyle(
    fontSize: 11,
    height: 1.2,
    fontWeight: FontWeight.w600,
    letterSpacing: 0.4,
    color: KnockColors.textSecondary,
  );
  static const number = TextStyle(
    fontSize: 15,
    fontWeight: FontWeight.w600,
    color: KnockColors.textPrimary,
    fontFeatures: _num,
  );
}

abstract final class KnockMotion {
  static const fast = Duration(milliseconds: 160);
  static const base = Duration(milliseconds: 260);
  static const slow = Duration(milliseconds: 420);
  static const curve = Curves.easeOutCubic;
}
