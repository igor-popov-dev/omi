import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:omi/utils/theme/omi_tokens.dart';

/// Builds the [ThemeData] for a token set.
///
/// Classic is a literal copy of the inline theme that used to live in
/// `main.dart` — it must stay pixel-identical to the current app.
/// Glass is the light theme derived from the macOS desktop design system.
ThemeData buildOmiTheme(OmiTokens t) => t.isGlass ? _buildGlassTheme(t) : _buildClassicTheme();

ThemeData _buildClassicTheme() {
  return ThemeData(
    useMaterial3: false,
    colorScheme: const ColorScheme.dark(primary: Colors.black, secondary: Color(0xFF35343B), surface: Colors.black38),
    snackBarTheme: const SnackBarThemeData(
      backgroundColor: Color(0xFF1F1F25),
      contentTextStyle: TextStyle(fontSize: 16, color: Colors.white, fontWeight: FontWeight.w500),
    ),
    textTheme: TextTheme(
      titleLarge: const TextStyle(fontSize: 18, color: Colors.white),
      titleMedium: const TextStyle(fontSize: 16, color: Colors.white),
      bodyMedium: const TextStyle(fontSize: 14, color: Colors.white),
      labelMedium: TextStyle(fontSize: 12, color: Colors.grey.shade200),
    ),
    textSelectionTheme: const TextSelectionThemeData(
      cursorColor: Colors.white,
      selectionColor: Colors.white24,
      selectionHandleColor: Colors.white,
    ),
    cupertinoOverrideTheme: const CupertinoThemeData(
      primaryColor: Colors.white, // Controls the selection handles on iOS
    ),
    extensions: const [OmiTokens.classic],
  );
}

ThemeData _buildGlassTheme(OmiTokens t) {
  return ThemeData(
    useMaterial3: false,
    brightness: Brightness.light,
    colorScheme: ColorScheme.light(primary: t.accent, secondary: t.bgTertiary, surface: t.bgSecondary),
    scaffoldBackgroundColor: t.bgPrimary,
    dividerColor: t.divider,
    snackBarTheme: SnackBarThemeData(
      backgroundColor: t.bgSecondary,
      contentTextStyle: TextStyle(fontSize: 16, color: t.textPrimary, fontWeight: FontWeight.w500),
    ),
    textTheme: _glassTextTheme(t),
    extensions: const [OmiTokens.glass],
  );
}

/// Family name declared in `pubspec.yaml` for the bundled Open Runde weights.
const String _glassDisplayFont = 'Open Runde';

/// Glass typography: Open Runde for display sizes (>= 22pt), system font below.
///
/// The system font is SF on iOS and Roboto on Android — deliberate, since SF Pro
/// cannot be bundled for Android. Slots without `fontFamily` therefore inherit it.
TextTheme _glassTextTheme(OmiTokens t) {
  return TextTheme(
    headlineMedium: TextStyle(
      fontFamily: _glassDisplayFont,
      fontSize: 27,
      fontWeight: FontWeight.w600,
      letterSpacing: -0.81,
      height: 1.18,
      color: t.textPrimary,
    ),
    headlineSmall: TextStyle(
      fontFamily: _glassDisplayFont,
      fontSize: 22,
      fontWeight: FontWeight.w600,
      letterSpacing: -0.66,
      height: 1.2,
      color: t.textPrimary,
    ),
    bodyLarge: TextStyle(
      fontSize: 17,
      fontWeight: FontWeight.w400,
      letterSpacing: -0.17,
      height: 1.55,
      color: t.textPrimary,
    ),
    bodyMedium: TextStyle(
      fontSize: 15,
      fontWeight: FontWeight.w500,
      letterSpacing: -0.15,
      height: 1.40,
      color: t.textPrimary,
    ),
    labelLarge: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, letterSpacing: -0.15, color: t.textPrimary),
    bodySmall: TextStyle(fontSize: 12, fontWeight: FontWeight.w400, letterSpacing: 0, color: t.textSecondary),
  );
}
