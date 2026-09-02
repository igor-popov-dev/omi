import 'package:flutter/material.dart';

import 'package:shared_preferences/shared_preferences.dart';

import 'package:omi/utils/theme/omi_theme.dart';
import 'package:omi/utils/theme/omi_tokens.dart';

/// Identifiers persisted in [SharedPreferences] under `app_theme`.
const String kOmiThemeClassic = 'classic';
const String kOmiThemeGlass = 'glass';

/// Holds the selected app theme (Classic / Glass) and persists it.
///
/// Classic is the default and is pixel-identical to the theme the app used
/// before theming existed; Glass is the light theme ported from the macOS
/// desktop design system.
class ThemeProvider extends ChangeNotifier {
  static const String _themeKey = 'app_theme';

  String _themeId = kOmiThemeClassic;
  bool _initialized = false;

  ThemeProvider() {
    _loadSavedTheme();
  }

  /// The selected theme id: `classic` or `glass`.
  String get themeId => _themeId;

  bool get isGlass => _themeId == kOmiThemeGlass;

  bool get isInitialized => _initialized;

  /// The [ThemeData] for the selected theme.
  ThemeData get themeData => buildOmiTheme(isGlass ? OmiTokens.glass : OmiTokens.classic);

  Future<void> _loadSavedTheme() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_themeKey);
    if (saved == kOmiThemeGlass || saved == kOmiThemeClassic) {
      _themeId = saved!;
    }
    _initialized = true;
    notifyListeners();
  }

  /// Select a theme by id. Unknown ids are ignored.
  Future<void> setTheme(String themeId) async {
    if (themeId != kOmiThemeClassic && themeId != kOmiThemeGlass) return;
    if (themeId == _themeId) return;
    _themeId = themeId;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_themeKey, themeId);
    notifyListeners();
  }
}
