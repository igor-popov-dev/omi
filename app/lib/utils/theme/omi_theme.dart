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
    // textTheme Glass — полоса Т2
    extensions: const [OmiTokens.glass],
  );
}
