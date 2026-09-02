import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import 'package:omi/utils/theme/omi_tokens.dart';

/// Геометрия нижней навигации для контента, который должен её обходить.
///
/// В Classic бар — прежний градиентный фейд на всю ширину высотой 100 pt, и
/// все отступы остаются ровно теми, что были: методы ниже в Classic отдают
/// переданное «прежнее» значение без изменений.
///
/// В Glass бар — плавающая пилюля, поэтому под ней остаётся живой фон и текст
/// списка читается насквозь. Числа продублированы из
/// `lib/widgets/bottom_nav_bar.dart` (`_glassPillHeight` = 68 и внешний
/// `EdgeInsets.fromLTRB(16, 0, 16, bottomInset + 12)` в `_buildGlassPill`) —
/// тот файл рисует саму пилюлю, этот считает отступы вокруг неё. Меняешь
/// высоту или отступ пилюли там — поправь константы здесь.
class BottomNavMetrics {
  const BottomNavMetrics._();

  /// `_glassPillHeight` из bottom_nav_bar.dart.
  static const double glassPillHeight = 68;

  /// Зазор пилюли до системного инсета — нижний отступ `_buildGlassPill`.
  static const double glassPillBottomGap = 12;

  /// Высота Classic-бара (`_buildClassicBar`): база, относительно которой
  /// считались все прежние отступы списков.
  static const double classicBarHeight = 100;

  /// Воздух между последней строкой контента и краем пилюли.
  static const double contentGap = 12;

  /// Высота чат-бара «Ask Omi» на главной (см. `_buildChatBar` в
  /// `lib/pages/home/page.dart`).
  static const double askOmiBarHeight = 62;

  /// Зазор между чат-баром и верхним краем пилюли в Glass.
  static const double glassAskOmiGap = 10;

  /// Прежняя позиция чат-бара в Classic — `Positioned(bottom: 78)`.
  static const double classicAskOmiBottom = 78;

  /// Сколько места нижняя навигация занимает от края экрана.
  static double barExtent(BuildContext context) {
    if (!context.omi.isGlass) return classicBarHeight;
    return glassPillHeight + MediaQuery.paddingOf(context).bottom + glassPillBottomGap;
  }

  /// Нижний отступ прокручиваемого списка.
  ///
  /// [classic] — прежнее значение; всё, что в нём было сверх [classicBarHeight],
  /// это запас под другие плавающие элементы (панель мультивыбора, чат-бар), и
  /// он сохраняется поверх glass-геометрии.
  static double listBottomPadding(BuildContext context, {required double classic}) {
    if (!context.omi.isGlass) return classic;
    return barExtent(context) + contentGap + math.max(0.0, classic - classicBarHeight);
  }

  /// Позиция чат-бара «Ask Omi» на главной: в Classic прежние
  /// [classicAskOmiBottom], в Glass — над пилюлей с зазором [glassAskOmiGap].
  static double askOmiBottom(BuildContext context) {
    if (!context.omi.isGlass) return classicAskOmiBottom;
    return barExtent(context) + glassAskOmiGap;
  }

  /// Панели мультивыбора (`MergeActionBar`, `TaskSelectionActionBar`) висят в
  /// `Positioned(bottom: 0)` и закрывают навигацию собой. В Classic бар ниже
  /// их края, в Glass пилюля выше — без этого запаса её верхняя кромка
  /// выглядывает из-под панели.
  static double actionSheetBottomPadding(BuildContext context, {required double classic}) {
    if (!context.omi.isGlass) return classic;
    return classic + contentGap;
  }

  /// Нижний отступ ленты главной: контент не должен уезжать под чат-бар.
  static double homeListBottomPadding(BuildContext context, {required double classic}) {
    if (!context.omi.isGlass) return classic;
    return askOmiBottom(context) + askOmiBarHeight + contentGap;
  }
}
