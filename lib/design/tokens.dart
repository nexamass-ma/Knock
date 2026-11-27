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
  // Surfaces (near-black, charcoal).
  static const background = Color(0xFF0A0A0E);
  static const surface = Color(0xFF14141A);
  static const surfaceRaised = Color(0xFF1C1C24);
  static const surfaceHigh = Color(0xFF26262F);
  static const stroke = Color(0x14FFFFFF); // 8% white
  static const strokeStrong = Color(0x24FFFFFF);

  // Text.
  static const textPrimary = Color(0xFFF4F4F6);
  static const textSecondary = Color(0xFF9B9BA7);
  static const textTertiary = Color(0xFF62626E);
  static const onGreen = Color(0xFF04120A);

  // Brand.
  static const green = Color(0xFF00B03C);
  static const greenBright = Color(0xFF2BD66A);
  static const greenSoft = Color(0x2600B03C); // 15%
  static const orange = Color(0xFFFF5001);
  static const orangeSoft = Color(0x26FF5001);

  // Mood colours used only inside gradients.
  static const violetDeep = Color(0xFF211C33);
  static const violet = Color(0xFF4A3D6E);
  static const violetMuted = Color(0xFF6E5A8E);
  static const ember = Color(0xFFB8664E);

  // Semantic.
  static const gain = greenBright;
  static const loss = Color(0xFFFF6B6B);
  static const warning = orange;

  static const heroGradient = LinearGradient(
    begin: Alignment(-1.0, -1.0),
    end: Alignment(1.0, 1.1),
    colors: [violetDeep, violet, violetMuted, ember],
    stops: [0.0, 0.42, 0.72, 1.0],
  );

  static const cardGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFF1B1F1C), Color(0xFF0F2A19), Color(0xFF0A4A23)],
  );

  static const dollarCardGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFF17151F), violet, Color(0xFF8C5A4C)],
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
