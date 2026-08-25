import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// Матовое стекло под всем интерфейсом Glass-темы (спецификация Т8,
/// omi-jarvis/docs/macos-theme-design.md, «Дополнение 2026-08-25»).
///
/// Пайплайн всегда один: подложка (картинка) → гауссов blur → белая вуаль →
/// интерфейс. Сейчас единственный источник подложки — сгенерированный
/// перламутровый градиент (лицензий не требует); слоты для «своего фото» и
/// обоев устройства добавляются заменой [child] у [_backdropSource].
///
/// В Classic слой НЕ строится вовсе — виджет вставляется в дерево только при
/// isGlass (см. builder в main.dart), тема по умолчанию не меняется ни на пиксель.
class GlassBackdrop extends StatelessWidget {
  final Widget child;

  const GlassBackdrop({super.key, required this.child});

  static const double blurSigma = 48;

  /// Вуаль поверх размытой подложки: даёт «матовость» и держит контраст токенов.
  ///
  /// Это перенос десктопного материала `InkGlass.material` (`.hudWindow`), и оба
  /// его числа — **замеры, а не решения дизайна**: непрозрачность 0.588 (=0x96)
  /// и тон 0.909 от белого (=0xE8), см. `InkGlass.measuredMaterialOpacity` /
  /// `measuredMaterialTint`. Их не подкручивают — их перезамеряют.
  ///
  /// Второй слой — скрим — живёт в `OmiTokens.glass.bgPrimary` (`Ink.surface`
  /// при `InkGlass.scrim` = 0.46, байт 0x75). Вместе они пропускают
  /// `(1 - 0.46) * (1 - 0.588) = 22.3%` подложки — ровно
  /// `InkGlass.backdropPassthrough` (0.2225) на macOS.
  ///
  /// **Ручка здесь ровно одна — скрим, и свободного хода у неё почти нет.**
  /// Осветлить картинку = утоньшить скрим, но его держит не контраст на
  /// однородном фоне, а `InkGlass.interferenceRatio`: амплитуда чужой картинки
  /// на панели против амплитуды собственного текста. При 1.0 они равны, выше —
  /// текст начинает «переплетаться» с подложкой. Пересчитано для этих значений:
  ///
  /// | скрим | passthrough | interference (typeAlpha 0.68) |
  /// |---|---|---|
  /// | 0.46 — текущий | 22.3% | 0.88 |
  /// | 0.4131 — граница | 24.3% | 1.00 |
  /// | 0.32 | 28.0% | 1.28 ✗ |
  ///
  /// То есть весь запас — 22.3% → 24.3%, около 9% картинки. Считать его надо
  /// по полному ходу подложки (чёрное → белое), а не по нынешнему ассету: слоты
  /// под «своё фото» и обои устройства предусмотрены, а фотография этот диапазон
  /// проходит целиком. На нынешнем `glass_backdrop_default.jpg` (после blur'а
  /// светлота 0.251…0.961) interference всего 0.55 — но это свойство ассета, не
  /// темы, и оно исчезает вместе с ним.
  ///
  /// Читаемость на самом тёмном углу подложки при этих значениях:
  /// страница 205/255, `textPrimary` 10.4:1, `textSecondary` 6.4:1.
  static const Color veil = Color(0x96E8E8E8);

  Widget _backdropSource() => Image.asset(
        'assets/images/glass_backdrop_default.jpg',
        fit: BoxFit.cover,
        errorBuilder: (context, error, stackTrace) => const _PearlGradient(),
      );

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        Positioned.fill(
          child: ImageFiltered(
            imageFilter: ui.ImageFilter.blur(sigmaX: blurSigma, sigmaY: blurSigma),
            child: _backdropSource(),
          ),
        ),
        const Positioned.fill(child: ColoredBox(color: veil)),
        child,
      ],
    );
  }
}

/// Перламутровый градиент в духе фона macOS: мягкие цветные пятна на светлом.
class _PearlGradient extends StatelessWidget {
  const _PearlGradient();

  @override
  Widget build(BuildContext context) {
    return CustomPaint(painter: _PearlPainter(), child: const SizedBox.expand());
  }
}

class _PearlPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final base = Paint()..color = const Color(0xFFEDEBF2);
    canvas.drawRect(Offset.zero & size, base);

    void blob(double dx, double dy, double r, Color color) {
      final paint = Paint()
        ..shader = ui.Gradient.radial(
          Offset(size.width * dx, size.height * dy),
          size.shortestSide * r,
          [color, color.withValues(alpha: 0)],
        );
      canvas.drawRect(Offset.zero & size, paint);
    }

    blob(0.15, 0.12, 0.9, const Color(0xFFC9B8F0)); // сирень
    blob(0.85, 0.25, 0.8, const Color(0xFFA9CDF5)); // голубой
    blob(0.25, 0.75, 0.9, const Color(0xFFBFE8D9)); // мятный
    blob(0.85, 0.85, 0.8, const Color(0xFFF5D9E8)); // розовый
    blob(0.55, 0.45, 0.7, const Color(0xFFF2EBDB)); // тёплый центр
  }

  @override
  bool shouldRepaint(covariant _PearlPainter oldDelegate) => false;
}
