import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';

import 'tokens.dart';

ThemeData buildKnockTheme() {
  const scheme = ColorScheme.dark(
    primary: KnockColors.green,
    onPrimary: KnockColors.onGreen,
    secondary: KnockColors.orange,
    onSecondary: Colors.white,
    surface: KnockColors.surface,
    onSurface: KnockColors.textPrimary,
    error: KnockColors.loss,
  );

  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: scheme,
    scaffoldBackgroundColor: KnockColors.background,
    splashFactory: InkSparkle.splashFactory,
    appBarTheme: const AppBarTheme(
      backgroundColor: KnockColors.background,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      centerTitle: true,
      titleTextStyle: KnockText.headline,
      foregroundColor: KnockColors.textPrimary,
      systemOverlayStyle: SystemUiOverlayStyle.light,
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: KnockColors.surface,
      surfaceTintColor: Colors.transparent,
      showDragHandle: true,
      dragHandleColor: KnockColors.strokeStrong,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(KnockRadius.xl))),
    ),
    dividerTheme: const DividerThemeData(color: KnockColors.stroke, thickness: 1, space: 1),
    snackBarTheme: const SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: KnockColors.surfaceHigh,
      contentTextStyle: KnockText.body,
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? KnockColors.onGreen : KnockColors.textSecondary,
      ),
      trackColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? KnockColors.green : KnockColors.surfaceHigh,
      ),
      trackOutlineColor: WidgetStateProperty.all(Colors.transparent),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: KnockColors.surfaceRaised,
      hintStyle: KnockText.body.copyWith(color: KnockColors.textTertiary),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(KnockRadius.md), borderSide: BorderSide.none),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(KnockRadius.md),
        borderSide: const BorderSide(color: KnockColors.green, width: 1),
      ),
    ),
    textSelectionTheme: const TextSelectionThemeData(
      cursorColor: KnockColors.green,
      selectionColor: KnockColors.greenSoft,
      selectionHandleColor: KnockColors.green,
    ),
  );
}
