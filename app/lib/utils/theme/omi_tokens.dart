import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';

/// Design tokens for both app themes.
///
/// Glass values are ported from the macOS desktop design system
/// (`desktop/macos/Desktop/Sources/Theme/{Ink,InkGlass,OmiSpacing}.swift`):
/// one ink base color with an alpha ladder, systemBlue accent, no purple.
///
/// Classic values mirror the current (dark) look of the app one-to-one, so
/// migrating a widget to these tokens must not change anything in Classic.
@immutable
class OmiTokens extends ThemeExtension<OmiTokens> {
  /// Scaffold / page background.
  final Color bgPrimary;

  /// Cards and sheets.
  final Color bgSecondary;

  /// Nested surfaces inside cards.
  final Color bgTertiary;

  /// List row fill.
  final Color rowFill;

  /// List row fill while pressed / selected.
  final Color rowFillHover;

  /// Chip fill (idle).
  final Color chipFill;

  /// Chip fill (active).
  final Color chipFillActive;

  /// Primary text.
  final Color textPrimary;

  /// Secondary text.
  final Color textSecondary;

  /// Tertiary text (captions, muted status).
  final Color textTertiary;

  /// Divider lines.
  final Color divider;

  /// Hairline borders of controls.
  final Color hairline;

  /// Card edge stroke.
  final Color glassEdge;

  /// Accent color.
  final Color accent;

  /// Text/icons drawn on top of [accent].
  final Color onAccent;

  /// Destructive / error color.
  final Color error;

  /// Success color.
  final Color success;

  /// Warning color.
  final Color warning;

  /// Corner radius of cards and sheets.
  final double cardRadius;

  /// Corner radius of list rows.
  final double rowRadius;

  /// Corner radius of chips.
  final double chipRadius;

  /// Corner radius of text fields.
  final double fieldRadius;

  /// Corner radius of settings cards.
  final double settingsCardRadius;

  /// True for the light "glass" theme, false for the classic dark theme.
  final bool isGlass;

  const OmiTokens({
    required this.bgPrimary,
    required this.bgSecondary,
    required this.bgTertiary,
    required this.rowFill,
    required this.rowFillHover,
    required this.chipFill,
    required this.chipFillActive,
    required this.textPrimary,
    required this.textSecondary,
    required this.textTertiary,
    required this.divider,
    required this.hairline,
    required this.glassEdge,
    required this.accent,
    required this.onAccent,
    required this.error,
    required this.success,
    required this.warning,
    required this.cardRadius,
    required this.rowRadius,
    required this.chipRadius,
    required this.fieldRadius,
    required this.settingsCardRadius,
    required this.isGlass,
  });

  /// Light "glass" theme — the macOS desktop design system.
  static const OmiTokens glass = OmiTokens(
    bgPrimary: Color(0xFFF5F5F7),
    bgSecondary: Color(0xFFFFFFFF),
    bgTertiary: Color(0xFFEDEDF0),
    rowFill: Color(0x0A000000),
    rowFillHover: Color(0x12000000),
    chipFill: Color(0x0A000000),
    chipFillActive: Color(0x1E000000),
    textPrimary: Color(0xD9000000),
    textSecondary: Color(0xAD000000),
    textTertiary: Color(0x93000000),
    divider: Color(0x30000000),
    hairline: Color(0x30000000),
    glassEdge: Color(0x0D000000),
    accent: Color(0xFF007AFF),
    onAccent: Color(0xFFFFFFFF),
    error: Color(0xFFFF3B30),
    success: Color(0xFF34C759),
    warning: Color(0xFFFF9500),
    cardRadius: 22,
    rowRadius: 13,
    chipRadius: 11,
    fieldRadius: 13,
    settingsCardRadius: 10,
    isGlass: true,
  );

  /// Classic dark theme — the current look of the app, unchanged.
  static const OmiTokens classic = OmiTokens(
    bgPrimary: Colors.black,
    bgSecondary: Color(0xFF1F1F25),
    bgTertiary: Color(0xFF35343B),
    rowFill: Color(0x0FFFFFFF),
    rowFillHover: Color(0x1AFFFFFF),
    chipFill: Color(0x0FFFFFFF),
    chipFillActive: Color(0x29FFFFFF),
    textPrimary: Colors.white,
    textSecondary: Color(0xFF8E8E93),
    textTertiary: Color(0xFF757575),
    divider: Color(0xFF3C3C43),
    hairline: Color(0x29FFFFFF),
    glassEdge: Color(0x0FFFFFFF),
    accent: Colors.deepPurple,
    onAccent: Colors.white,
    error: Color(0xFFEF4444),
    success: Color(0xFF22C55E),
    warning: Color(0xFFF59E0B),
    cardRadius: 16,
    rowRadius: 12,
    chipRadius: 12,
    fieldRadius: 12,
    settingsCardRadius: 12,
    isGlass: false,
  );

  /// Shared spacing scale. Round "magic" numbers (10/14/18/22/26/28/36) to the nearest step.
  static const List<double> spacing = [2, 4, 6, 8, 12, 16, 20, 24, 32, 40];

  @override
  OmiTokens copyWith({
    Color? bgPrimary,
    Color? bgSecondary,
    Color? bgTertiary,
    Color? rowFill,
    Color? rowFillHover,
    Color? chipFill,
    Color? chipFillActive,
    Color? textPrimary,
    Color? textSecondary,
    Color? textTertiary,
    Color? divider,
    Color? hairline,
    Color? glassEdge,
    Color? accent,
    Color? onAccent,
    Color? error,
    Color? success,
    Color? warning,
    double? cardRadius,
    double? rowRadius,
    double? chipRadius,
    double? fieldRadius,
    double? settingsCardRadius,
    bool? isGlass,
  }) {
    return OmiTokens(
      bgPrimary: bgPrimary ?? this.bgPrimary,
      bgSecondary: bgSecondary ?? this.bgSecondary,
      bgTertiary: bgTertiary ?? this.bgTertiary,
      rowFill: rowFill ?? this.rowFill,
      rowFillHover: rowFillHover ?? this.rowFillHover,
      chipFill: chipFill ?? this.chipFill,
      chipFillActive: chipFillActive ?? this.chipFillActive,
      textPrimary: textPrimary ?? this.textPrimary,
      textSecondary: textSecondary ?? this.textSecondary,
      textTertiary: textTertiary ?? this.textTertiary,
      divider: divider ?? this.divider,
      hairline: hairline ?? this.hairline,
      glassEdge: glassEdge ?? this.glassEdge,
      accent: accent ?? this.accent,
      onAccent: onAccent ?? this.onAccent,
      error: error ?? this.error,
      success: success ?? this.success,
      warning: warning ?? this.warning,
      cardRadius: cardRadius ?? this.cardRadius,
      rowRadius: rowRadius ?? this.rowRadius,
      chipRadius: chipRadius ?? this.chipRadius,
      fieldRadius: fieldRadius ?? this.fieldRadius,
      settingsCardRadius: settingsCardRadius ?? this.settingsCardRadius,
      isGlass: isGlass ?? this.isGlass,
    );
  }

  @override
  OmiTokens lerp(covariant OmiTokens? other, double t) {
    if (other == null) return this;
    return OmiTokens(
      bgPrimary: Color.lerp(bgPrimary, other.bgPrimary, t)!,
      bgSecondary: Color.lerp(bgSecondary, other.bgSecondary, t)!,
      bgTertiary: Color.lerp(bgTertiary, other.bgTertiary, t)!,
      rowFill: Color.lerp(rowFill, other.rowFill, t)!,
      rowFillHover: Color.lerp(rowFillHover, other.rowFillHover, t)!,
      chipFill: Color.lerp(chipFill, other.chipFill, t)!,
      chipFillActive: Color.lerp(chipFillActive, other.chipFillActive, t)!,
      textPrimary: Color.lerp(textPrimary, other.textPrimary, t)!,
      textSecondary: Color.lerp(textSecondary, other.textSecondary, t)!,
      textTertiary: Color.lerp(textTertiary, other.textTertiary, t)!,
      divider: Color.lerp(divider, other.divider, t)!,
      hairline: Color.lerp(hairline, other.hairline, t)!,
      glassEdge: Color.lerp(glassEdge, other.glassEdge, t)!,
      accent: Color.lerp(accent, other.accent, t)!,
      onAccent: Color.lerp(onAccent, other.onAccent, t)!,
      error: Color.lerp(error, other.error, t)!,
      success: Color.lerp(success, other.success, t)!,
      warning: Color.lerp(warning, other.warning, t)!,
      cardRadius: lerpDouble(cardRadius, other.cardRadius, t)!,
      rowRadius: lerpDouble(rowRadius, other.rowRadius, t)!,
      chipRadius: lerpDouble(chipRadius, other.chipRadius, t)!,
      fieldRadius: lerpDouble(fieldRadius, other.fieldRadius, t)!,
      settingsCardRadius: lerpDouble(settingsCardRadius, other.settingsCardRadius, t)!,
      isGlass: t < 0.5 ? isGlass : other.isGlass,
    );
  }
}

/// Widget-facing accessor: `final t = context.omi;`.
///
/// Falls back to [OmiTokens.classic] so widgets keep working under a
/// ThemeData that does not carry the extension (e.g. in tests).
extension OmiTokensX on BuildContext {
  OmiTokens get omi => Theme.of(this).extension<OmiTokens>() ?? OmiTokens.classic;
}
