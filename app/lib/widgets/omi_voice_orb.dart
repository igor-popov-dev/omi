// Анимированная иконка голосового режима: тот же аватар Omi (градиентный круг
// плюс кольцо из восьми точек), но живой — она заменяет подпись «Слушаю…» в
// чате, см. `HubVoiceStatusIndicator`.
//
// Движение выбрано на стенде (решение Игоря 24.08) и здесь ОДНО, а не набор
// вариантов: «сияние» для круга (градиент медленно проворачивается внутри,
// снаружи дышит ореол) плюс «пульс» для точек (все восемь дышат яркостью, не
// сдвигаясь с места и не меняя размер). Фаза разговора задаёт темп, уровень
// звука — размах.
//
// Почему точки не вращаются: вращающееся кольцо читается как спиннер загрузки,
// то есть как «идёт обработка», и в фазе ожидания это врёт. Движение отдано
// кругу, точки держат форму логотипа узнаваемой.
import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart' show rootBundle;

import 'package:omi/utils/logger.dart';

/// Оформление иконки. Хранится в настройках (`SharedPreferencesUtil.voiceOrbTheme`)
/// по индексу, поэтому порядок значений менять нельзя — сдвиг переназначит
/// тему у всех, кто её уже выбрал.
enum OmiVoiceOrbTheme {
  /// Фирменный градиент из `assets/images/background.png` — то же, что рисует
  /// статичный аватар в шапке чата.
  gradient,

  /// Тёмный круг с белыми точками.
  dark,

  /// Светлый круг с тёмными точками. Самый контрастный на мелком размере.
  light,

  /// Плоский чёрный без градиента и блика: точки читаются резче, но перелив
  /// в этой теме не виден — крутить внутри нечего, работает один ореол.
  /// Добавлена последней намеренно: индексы уже сохранённых тем не сдвигаются.
  black,
}

/// Фаза разговора. Не влияет на то, ЧТО анимируется, только на темп — одна
/// анимация во всех состояниях, иначе переключение выглядит как подмена иконки.
enum OmiVoiceOrbPhase {
  listening,
  hearingUser,
  thinking,
  speaking,
}

/// Во сколько раз быстрее идёт анимация в каждой фазе. Ожидание намеренно
/// вялое: иконка должна показывать «жив», а не «занят».
double _tempoFor(OmiVoiceOrbPhase phase) {
  switch (phase) {
    case OmiVoiceOrbPhase.listening:
      return 1.0;
    case OmiVoiceOrbPhase.hearingUser:
      return 1.35;
    case OmiVoiceOrbPhase.thinking:
      return 2.4;
    case OmiVoiceOrbPhase.speaking:
      return 1.1;
  }
}

/// Поле виджета шире круга: растущему кругу и ореолу нужен запас по краям.
/// Круг в покое занимает `diameter`, виджет — `diameter * kOmiVoiceOrbPadding`.
const double kOmiVoiceOrbPadding = 1.8;

// Геометрия кольца в долях ДИАМЕТРА круга. Пропорции взяты из herologo.png
// (радиус кольца 86.6/260, радиус точки 17.75/260), домноженные на 16/24 —
// в `_getOmiAvatar()` логотип 16pt лежит в контейнере 24pt, то есть занимает
// две трети диаметра, а не весь.
const double _kFit = 16 / 24;
const double _kRingRadius = (86.6 / 260) * _kFit;
const double _kDotRadius = (17.75 / 260) * _kFit;
const int _kDotCount = 8;

/// Палитра одной темы. `fill == null` — «взять фирменный градиент из PNG»,
/// остальные темы собираются из двух близких тонов, между которыми и ходит
/// перелив: в монохроме проворачивать нечего, поэтому перелив ведёт ось
/// градиента, а не картинку.
class _OrbPalette {
  const _OrbPalette({
    required this.dot,
    required this.dotHaloOpacity,
    this.fill,
    this.halo,
    this.ring,
    this.sheen,
  });

  final Color dot;
  final double dotHaloOpacity;
  final List<Color>? fill;
  final Color? halo;
  final Color? ring;
  final Color? sheen;
}

const Map<OmiVoiceOrbTheme, _OrbPalette> _kPalettes = {
  OmiVoiceOrbTheme.gradient: _OrbPalette(
    dot: Color(0xFFFFFFFF),
    dotHaloOpacity: 0.33,
  ),
  OmiVoiceOrbTheme.dark: _OrbPalette(
    dot: Color(0xFFFFFFFF),
    dotHaloOpacity: 0.30,
    fill: [Color(0xFF2C2C3A), Color(0xFF07070B)],
    halo: Color(0xFFC4D4EA),
    // без обводки тёмный круг сливается с тёмным экраном чата
    ring: Color(0x24FFFFFF),
    sheen: Color(0x1CFFFFFF),
  ),
  OmiVoiceOrbTheme.black: _OrbPalette(
    dot: Color(0xFFFFFFFF),
    dotHaloOpacity: 0.30,
    // оба тона одинаковы — градиент вырождается в сплошную заливку
    fill: [Color(0xFF000000), Color(0xFF000000)],
    halo: Color(0xFFC4D4EA),
    // ярче, чем у тёмной: без градиента и блика круг больше нечем отделить
    ring: Color(0x2EFFFFFF),
  ),
  OmiVoiceOrbTheme.light: _OrbPalette(
    dot: Color(0xFF0C0C12),
    // тёмное свечение на светлом расплывается сильнее белого — держим слабее
    dotHaloOpacity: 0.16,
    fill: [Color(0xFFFFFFFF), Color(0xFFCED6E4)],
    halo: Color(0xFFECF1FA),
    ring: Color(0x12000000),
  ),
};

/// Фоновая картинка фирменного градиента, общая на все экземпляры иконки.
/// Декодируется один раз за процесс: `ImageCache` бы тоже справился, но здесь
/// нужен именно `ui.Image` для `drawImageRect`, а не виджет.
class _OrbBackground {
  static ui.Image? image;
  static Future<void>? _loading;

  static Future<void> ensureLoaded() {
    if (image != null) return Future<void>.value();
    return _loading ??= _load();
  }

  static Future<void> _load() async {
    try {
      final data = await rootBundle.load('assets/images/background.png');
      final codec = await ui.instantiateImageCodec(data.buffer.asUint8List());
      final frame = await codec.getNextFrame();
      image = frame.image;
    } catch (e) {
      // Ассет не прочитался — иконка останется на запасном тоне, ронять из-за
      // этого экран чата незачем. `_loading` сбрасывается, чтобы следующий
      // экземпляр попробовал снова, а не унаследовал разовый сбой.
      Logger.error('[OmiVoiceOrb] фон не загрузился: $e');
      _loading = null;
    }
  }
}

/// Живая иконка голосового режима.
class OmiVoiceOrb extends StatefulWidget {
  const OmiVoiceOrb({
    super.key,
    required this.phase,
    this.theme = OmiVoiceOrbTheme.gradient,
    this.diameter = 48,
    this.level = 0,
    this.animated = true,
  });

  final OmiVoiceOrbPhase phase;
  final OmiVoiceOrbTheme theme;

  /// `false` — иконка рисуется один раз и замирает (тикер не запускается
  /// вовсе, как при системном «уменьшить движение»). Нужно кнопке голосового
  /// режима в покое: там orb — обложка, а не индикатор живого разговора.
  final bool animated;

  /// Диаметр круга в покое. Виджет занимает [kOmiVoiceOrbPadding] от него.
  final double diameter;

  /// Громкость 0..1. Пока источник не подключён, остаётся нулём — иконка тогда
  /// живёт одним темпом фазы. Сглаживание — на стороне вызывающего.
  final double level;

  @override
  State<OmiVoiceOrb> createState() => _OmiVoiceOrbState();
}

class _OmiVoiceOrbState extends State<OmiVoiceOrb> with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  final _clock = _OrbClock();
  Duration _lastTick = Duration.zero;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick);
    unawaited(_OrbBackground.ensureLoaded().then((_) {
      if (mounted) setState(() {});
    }));
  }

  void _onTick(Duration elapsed) {
    final dt = (elapsed - _lastTick).inMicroseconds / Duration.microsecondsPerSecond;
    _lastTick = elapsed;
    // первый кадр приходит с нулём, а после паузы — с дырой в несколько
    // секунд: и то и другое не должно давать рывок
    if (dt <= 0) return;
    _clock.advance(dt.clamp(0.0, 0.05), _tempoFor(widget.phase), widget.level);
  }

  @override
  void dispose() {
    _ticker.dispose();
    _clock.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // «Уменьшить движение» в системных настройках — не косметика: у части
    // людей от постоянной анимации в поле зрения болит голова. Иконка тогда
    // рисуется один раз и замирает, оставаясь на своём месте и в своей теме.
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (reduceMotion || !widget.animated) {
      if (_ticker.isActive) _ticker.stop();
    } else if (!_ticker.isActive) {
      _ticker.start();
    }

    final side = widget.diameter * kOmiVoiceOrbPadding;
    return SizedBox(
      width: side,
      height: side,
      child: CustomPaint(
        painter: _OmiVoiceOrbPainter(
          clock: _clock,
          theme: widget.theme,
          phase: widget.phase,
          baseDiameter: widget.diameter,
          level: widget.level,
        ),
      ),
    );
  }
}

/// Время анимации. Копится с учётом темпа, а не умножается на него в момент
/// отрисовки: иначе смена фазы меняла бы аргумент синуса скачком и иконка
/// дёргалась бы на каждом переходе «слушаю → думаю».
class _OrbClock extends ChangeNotifier {
  double phaseClock = 0;
  double swirl = 0;

  void advance(double dt, double tempo, double level) {
    phaseClock += dt * tempo;
    // перелив идёт медленнее: быстрее — и градиент читается как крутящийся
    // барабан, а не как переливающийся свет
    swirl += ((2 * math.pi) / 26 * tempo + level * 0.22) * dt;
    notifyListeners();
  }
}

class _OmiVoiceOrbPainter extends CustomPainter {
  _OmiVoiceOrbPainter({
    required this.clock,
    required this.theme,
    required this.phase,
    required this.baseDiameter,
    required this.level,
  }) : super(repaint: clock);

  final _OrbClock clock;
  final OmiVoiceOrbTheme theme;
  final OmiVoiceOrbPhase phase;
  final double baseDiameter;
  final double level;

  @override
  void paint(Canvas canvas, Size size) {
    final palette = _kPalettes[theme]!;
    final center = Offset(size.width / 2, size.height / 2);
    final t = clock.phaseClock;
    final lvl = level.clamp(0.0, 1.0);

    // Размер круга почти не ходит — за «дыхание» отвечает ореол снаружи.
    final scale = 1 + 0.008 * math.sin(t * 2 * math.pi / 3.0) + 0.07 * lvl;
    final radius = (baseDiameter / 2) * scale;

    _paintHalo(canvas, center, radius, palette, t, lvl);
    _paintBody(canvas, center, radius, palette);
    _paintDots(canvas, center, radius, palette, t);
  }

  void _paintHalo(Canvas canvas, Offset center, double radius, _OrbPalette palette, double t, double lvl) {
    final glow = 0.42 + 0.28 * (0.5 + 0.5 * math.sin(t * 2 * math.pi / 2.2)) + 0.55 * lvl;
    final outer = radius * 1.5;

    // У фирменного градиента ореол ведёт цвет за ним: холодный край — голубое
    // свечение, тёплый — розоватое. У монохромных тем цвет задан палитрой.
    final Color color = palette.halo ??
        Color.lerp(
          const Color(0xFFBAD8F5),
          const Color(0xFFE7BED0),
          0.5 + 0.5 * math.sin(clock.swirl),
        )!;

    final shader = ui.Gradient.radial(
      center,
      outer,
      [color.withValues(alpha: math.min(0.5, glow * 0.42)), color.withValues(alpha: 0)],
      [radius * 0.96 / outer, 1.0],
    );
    canvas.drawCircle(center, outer, Paint()..shader = shader);
  }

  void _paintBody(Canvas canvas, Offset center, double radius, _OrbPalette palette) {
    final circle = Rect.fromCircle(center: center, radius: radius);
    canvas.save();
    canvas.clipPath(Path()..addOval(circle));

    final fill = palette.fill;
    if (fill != null) {
      // Монохром: перелив ведёт ОСЬ градиента между двумя близкими тонами —
      // светлая сторона медленно обходит круг.
      final angle = clock.swirl;
      final axis = Offset(math.cos(angle), math.sin(angle)) * radius;
      canvas.drawRect(
        circle,
        Paint()..shader = ui.Gradient.linear(center - axis, center + axis, [fill.first, fill.last]),
      );

      final sheen = palette.sheen;
      if (sheen != null) {
        // блик, иначе тёмный круг читается плоской дырой
        final spot = center + axis * 0.42;
        canvas.drawRect(
          circle,
          Paint()..shader = ui.Gradient.radial(spot, radius, [sheen, sheen.withValues(alpha: 0)]),
        );
      }
    } else {
      final image = _OrbBackground.image;
      if (image == null) {
        // до декодирования картинки — ровный тон из середины градиента
        canvas.drawRect(circle, Paint()..color = const Color(0xFF6D63A6));
      } else {
        // BoxFit.cover из 390x844 в квадрат — центральный квадрат 390x390,
        // ровно то же, что делает `_getOmiAvatar()` со статичным аватаром
        final side = image.width.toDouble();
        final top = (image.height - image.width) / 2;
        final src = Rect.fromLTWH(0, top, side, side);

        canvas.save();
        canvas.translate(center.dx, center.dy);
        canvas.rotate(clock.swirl);
        // квадрат стороной 2R при любом повороте накрывает круг радиуса R
        canvas.drawImageRect(
          image,
          src,
          Rect.fromCircle(center: Offset.zero, radius: radius),
          Paint()..filterQuality = FilterQuality.medium,
        );
        canvas.restore();
      }
    }
    canvas.restore();

    final ring = palette.ring;
    if (ring != null) {
      canvas.drawCircle(
        center,
        radius,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = math.max(0.6, baseDiameter * 0.008)
          ..color = ring,
      );
    }
  }

  void _paintDots(Canvas canvas, Offset center, double radius, _OrbPalette palette, double t) {
    final diameter = radius * 2;
    final ringRadius = diameter * _kRingRadius;
    final dotRadius = diameter * _kDotRadius;

    // «Пульс»: все восемь дышат разом. Точки не сдвигаются и не меняют размер —
    // работает только яркость, поэтому форма логотипа остаётся собой.
    final alpha = 0.55 + 0.45 * (0.5 + 0.5 * math.sin(t * 2 * math.pi / 2.1));

    for (var i = 0; i < _kDotCount; i++) {
      final angle = (i / _kDotCount) * 2 * math.pi;
      final position = center + Offset(math.cos(angle), math.sin(angle)) * ringRadius;

      // у точек в herologo.png мягкий ореол — без него край выглядит вырубленным
      final haloRadius = dotRadius * 1.56;
      canvas.drawCircle(
        position,
        haloRadius,
        Paint()
          ..shader = ui.Gradient.radial(
            position,
            haloRadius,
            [
              palette.dot.withValues(alpha: palette.dotHaloOpacity * alpha),
              palette.dot.withValues(alpha: 0),
            ],
            [dotRadius / haloRadius, 1.0],
          ),
      );

      canvas.drawCircle(position, dotRadius, Paint()..color = palette.dot.withValues(alpha: alpha));
    }
  }

  @override
  bool shouldRepaint(covariant _OmiVoiceOrbPainter old) =>
      old.theme != theme || old.phase != phase || old.baseDiameter != baseDiameter || old.level != level;
}
