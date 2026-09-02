import 'package:flutter/material.dart';

import 'package:omi/utils/theme/omi_tokens.dart';

/// Builds a settings-row glyph at the size the current theme asks for.
typedef SettingsIconBuilder = Widget Function(double size);

/// Leading icon of a settings row.
///
/// Glass draws the macOS-settings shape: a rounded square that is a touch
/// darker than the row, outlined by a hairline stroke, with a thin monochrome
/// glyph inside. The corner radius belongs to the same family as the settings
/// card ([OmiTokens.settingsCardRadius] = 10) — never a pill, never a circle.
///
/// Classic is reproduced verbatim from whatever the row had before this widget
/// existed, so switching a row over changes nothing there:
///
/// * [SettingsIconChip.plain] — the bare `SizedBox(24) → icon` rows
///   (`settings_drawer`, `profile`, `device_settings`, `permissions_page`).
/// * [SettingsIconChip.boxed] — rows that already carry a filled square
///   (`developer`, `language_settings_page`, `notifications_settings_page`, …).
class SettingsIconChip extends StatelessWidget {
  /// Side of the Glass square. 34 sits between the two Classic shapes (24 bare,
  /// 40 boxed) and keeps every settings row aligned on one grid.
  static const double glassSize = 34;

  /// Corner radius of the Glass square: one notch tighter than the card it sits
  /// in, so icon and card read as the same family.
  static const double glassRadius = 9;

  /// Glyph size inside the Glass square.
  static const double glassIconSize = 18;

  /// Builds the glyph at the size the current theme wants.
  final SettingsIconBuilder icon;

  /// Side of the Classic box.
  final double classicSize;

  /// Glyph size in Classic.
  final double classicIconSize;

  /// Corner radius of the Classic box; null means Classic draws no container at
  /// all (the bare `SizedBox` rows).
  final double? classicRadius;

  /// Fill of the Classic box; null falls back to [OmiTokens.bgTertiary].
  final Color? classicColor;

  /// Row whose Classic form is a bare `SizedBox(width: 24, height: 24)`.
  const SettingsIconChip.plain({
    super.key,
    required this.icon,
    this.classicSize = 24,
    this.classicIconSize = 20,
  })  : classicRadius = null,
        classicColor = null;

  /// Row whose Classic form is already a filled rounded square.
  const SettingsIconChip.boxed({
    super.key,
    required this.icon,
    this.classicSize = 40,
    this.classicIconSize = 16,
    double radius = 10,
    this.classicColor,
  }) : classicRadius = radius;

  @override
  Widget build(BuildContext context) {
    final t = context.omi;

    if (!t.isGlass) {
      final glyph = icon(classicIconSize);
      if (classicRadius == null) {
        return SizedBox(width: classicSize, height: classicSize, child: glyph);
      }
      return Container(
        width: classicSize,
        height: classicSize,
        decoration: BoxDecoration(
          color: classicColor ?? t.bgTertiary,
          borderRadius: BorderRadius.circular(classicRadius!),
        ),
        child: Center(child: glyph),
      );
    }

    return Container(
      width: glassSize,
      height: glassSize,
      decoration: BoxDecoration(
        color: t.bgTertiary,
        borderRadius: BorderRadius.circular(glassRadius),
        border: Border.all(color: t.hairline, width: 0.5),
      ),
      child: Center(child: icon(glassIconSize)),
    );
  }
}
