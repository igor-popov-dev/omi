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
  ///
  /// # Модель земли (порт `InkGlass.ground`)
  ///
  /// Всё ниже считается по той же двухслойной арифметике, что и на десктопе,
  /// поэтому числа здесь проверяемы, а не «на глаз»:
  ///
  ///     material(b) = 0.909 * 0.588 + b * (1 - 0.588)      // InkGlass.measuredMaterial*
  ///     page(b)     = 1.0 * 0.46 + material(b) * (1 - 0.46) // + InkGlass.scrim
  ///
  /// где `b` — светлота подложки. Модель воспроизводит опубликованные десктопные
  /// величины до 0.1/255: `page(0) = 190.8/255` (десктоп: 190.9), passthrough
  /// `(1-0.46)*(1-0.588) = 0.2230` (десктоп `backdropPassthrough`: 0.2225),
  /// interference при typeAlpha 0.68 = 0.880 (десктопная таблица: 0.88).
  ///
  /// Важное следствие, которым выведены [bgSecondary]/[bgTertiary]: **самая
  /// тёмная страница, которая физически возможна, — это `page(0) = 0.7481`.**
  /// Ниже она не опускается ни при какой подложке, потому что вуаль + скрим
  /// закрывают 77.7%.
  ///
  /// # Порядок яркости: страница светлее, плашки темнее
  ///
  /// На macOS страница — это сама панель, а карточка/строка рисуются на ней
  /// washes'ами `Ink.rowFill` / `Ink.rowFillHover` — не белым филлом, а лёгким
  /// затемнением. Чёрный wash инвариантен: он темнит на фиксированную долю при
  /// любой подложке. Фиксированный серый — нет, и это ровно та ловушка, о которой
  /// предупреждает `Ink.swift` («a wash that darkens in Light and lightens in Dark
  /// does, and a fixed grey does not»).
  ///
  /// **Отсюда железное правило тона: у любой серой поверхности тон обязан быть
  /// НИЖЕ 0.7481.** Тогда `surface - page = alpha * (тон - page) < 0` при любой
  /// подложке, то есть плашка темнее страницы безусловно. Прошлые значения
  /// (тон 0.8118 у карточки) этого не держали: карточка становилась светлее
  /// страницы при светлоте подложки ниже 0.286, а у нынешнего ассета
  /// `glass_backdrop_default.jpg` минимум после blur'а равен 0.251 — то есть
  /// инверсия реально видна в тёмном углу картинки.
  ///
  /// Композит на нынешнем ассете (тёмный угол / среднее / светлый угол),
  /// в L\* — воспринимаемых ступенях:
  ///
  /// | поверхность | тёмный | среднее | светлый |
  /// |---|---|---|---|
  /// | [bgPrimary] (страница) | 82.4 | 90.7 | 96.7 |
  /// | [bgSecondary] (карточка) | 79.5 (−3.0) | 83.3 (−7.4) | 86.1 (−10.6) |
  /// | [bgTertiary] (вложенная) | 74.5 (−4.9) | 80.2 (−3.1) | 84.3 (−1.8) |
  ///
  /// Серый тон, а не чистый чёрный wash, — потому что [bgSecondary] на мобиле
  /// обслуживает ещё и bottom sheets/диалоги, под которыми лежит затемняющий
  /// барьер (`black54`), а не размытая подложка. Чёрный wash сделал бы их
  /// нечитаемыми. Альфа карточки поэтому зажата снизу этим случаем: на барьере
  /// она даёт землю 151/255, где [textSecondary] держит ровно 4.51:1 (WCAG AA).
  /// Опускать альфу дальше можно только после того, как sheets/диалоги получат
  /// собственную подложку (или светлый барьер, как в
  /// `pages/conversation_detail/page.dart`).
  ///
  /// # Железное правило прозрачности
  ///
  /// **Ни у одной поверхности Glass не должно быть альфы 0xFF.** Непрозрачная
  /// заливка сразу ломает стек слоёв: подложка перестаёт просвечивать и плашка
  /// читается как белый слэб. Сейчас сквозь карточку проходит 45.5% страницы,
  /// сквозь вложенную — 66.7%. Непрозрачны здесь только «чернила» и состояния
  /// ([accent], [onAccent], [error], [success], [warning]) — на десктопе это тоже
  /// именованные системные цвета, а не поверхности.
  ///
  /// Прозрачность безопасна только потому, что подложку гарантирует builder в
  /// main.dart для любого isGlass-экрана.
  ///
  /// # Конвенция альф: всё композитится через `labelColor`
  ///
  /// В `.aqua` `NSColor.labelColor` — это чёрный с альфой 0.85, поэтому
  /// `Ink.rowFill = labelColor.opacity(0.045)` рисует чёрный при 0.85 × 0.045 =
  /// 0.03825, а не при 0.045. Все производные от `labelColor` токены здесь
  /// перенесены уже композитными — одна конвенция на файл:
  ///
  /// | токен | Swift | ×0.85 | байт |
  /// |---|---|---|---|
  /// | [textPrimary] | `labelColor` | 0.850 | 0xD9 |
  /// | [textSecondary] | `Ink.secondary` 0.80 | 0.680 | 0xAD |
  /// | [textTertiary] | `Ink.tertiary` 0.68 | 0.578 | 0x93 |
  /// | [hairline] | `Ink.hairline` 0.22 | 0.187 | 0x30 |
  /// | [rowFill] / [chipFill] | `Ink.rowFill` 0.045 | 0.038 | 0x0A |
  /// | [rowFillHover] | `Ink.rowFillHover` 0.085 | 0.072 | 0x12 |
  /// | [glassEdge] | `InkGlass.edgeAlpha` 0.06 | 0.051 | 0x0D |
  ///
  /// [chipFillActive] десктопного прообраза не имеет (чипов там нет) и остаётся
  /// мобильным решением: −8.9 L\* от карточки, чтобы «включено» читалось на
  /// солнце. [divider] сейчас дублирует [hairline]; на десктопе это разные вещи
  /// (`Ink.separator` = `separatorColor`, заметно бледнее), но токен используется
  /// на call site'ах ещё и как тон шеврона/подписи, поэтому не трогается здесь.
  ///
  /// [textTertiary] на десктопе на стекле **запрещён** (`Ink.tertiary`: «never on
  /// glass»); здесь он оставлен, но на карточке над тёмным углом подложки даёт
  /// 4.44:1 — под AA. Считать его глянцевой подписью, не текстом абзаца.
  static const OmiTokens glass = OmiTokens(
    bgPrimary: Color(0x75FFFFFF),
    bgSecondary: Color(0x8BBEBEC4),
    bgTertiary: Color(0x558C8C91),
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
