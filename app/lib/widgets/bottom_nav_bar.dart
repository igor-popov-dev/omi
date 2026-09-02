import 'package:omi/utils/platform/platform_manager.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:provider/provider.dart';

import 'package:omi/providers/home_provider.dart';
import 'package:omi/utils/theme/glass_effects.dart';
import 'package:omi/utils/theme/omi_icons.dart';
import 'package:omi/utils/theme/omi_tokens.dart';

class BottomNavBar extends StatefulWidget {
  const BottomNavBar({super.key, required this.onTabTap, this.onTabWarmup});

  final void Function(int index, bool isRepeat) onTabTap;
  final ValueChanged<int>? onTabWarmup;

  @override
  State<BottomNavBar> createState() => _BottomNavBarState();
}

class _BottomNavBarState extends State<BottomNavBar> {
  // Keep the provider-dependent subtree stable when HomePage's broad Consumer
  // rebuilds for unrelated focus or loading changes. The cache is dropped when
  // the theme tokens change: otherwise Selector keeps returning the subtree it
  // built under the previous theme, and a runtime Glass/Classic switch leaves
  // the bar painted in the colours of the theme that is no longer active.
  Widget? _navigation;
  OmiTokens? _tokens;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final tokens = context.omi;
    if (_tokens != tokens) {
      _tokens = tokens;
      _navigation = _buildNavigation();
    }
  }

  /// Высота самой пилюли в Glass: кружок активной вкладки (46) плюс воздух
  /// сверху и снизу. Десктопный бар живёт по той же логике — 52 pt при 32 pt
  /// ряде контента (`TopNavigationLayoutMetrics.barHeight`).
  static const double _glassPillHeight = 68;

  /// Ряд иконок в Classic — прежние 90 pt внутри 100 pt контейнера.
  static const double _classicRowHeight = 90;

  /// Размытие того, что проезжает под пилюлей. На macOS нечитаемость подложки
  /// делает материал панели (`InkGlass.material`, `.hudWindow`) — размытием, а
  /// не краской. Во Flutter материала нет, поэтому работу берёт на себя blur:
  /// именно он, а не заливка, глушит контент. Чуть меньше фоновой
  /// (`GlassBackdrop.blurSigma` = 48): пилюля размывает ленту под собой.
  static const double _glassPillBlurSigma = 32;

  /// Заливка пилюли: белый 0.30.
  ///
  /// Меньше скрима панели (`InkGlass.scrim` = 0.46 → токен `bgPrimary`) ровно
  /// потому, что скрим на десктопе ложится на голый рабочий стол, а здесь под
  /// пилюлей уже лежит вуаль [GlassBackdrop] — белое на белёсом дало «наглухо
  /// белую» пилюлю. 0.30 хватает, чтобы иконки на `textPrimary`/`textTertiary`
  /// держали контраст, и мало, чтобы сквозь стекло угадывался фон и контент.
  static const Color _glassPillFill = Color(0x4DFFFFFF);

  Widget _buildNavigation() {
    return Selector<HomeProvider, int>(
      selector: (_, home) => home.selectedIndex,
      builder: (context, selectedIndex, _) {
        final t = context.omi;
        return Align(
          alignment: Alignment.bottomCenter,
          child: t.isGlass ? _buildGlassPill(context, t, selectedIndex) : _buildClassicBar(context, selectedIndex),
        );
      },
    );
  }

  /// Classic — прежний градиентный фейд на всю ширину, без пилюли.
  Widget _buildClassicBar(BuildContext context, int selectedIndex) {
    return Container(
      width: double.infinity,
      height: 100,
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          stops: [0.0, 0.30, 1.0],
          colors: [Colors.transparent, Color.fromARGB(255, 15, 15, 15), Color.fromARGB(255, 15, 15, 15)],
        ),
      ),
      child: _buildTabRow(context, selectedIndex, _classicRowHeight),
    );
  }

  /// Glass — плавающая пилюля как хедер десктопа: свой угол, свой hairline и
  /// одна общая ambient-тень, под ней просвечивает стекло страницы.
  ///
  /// Числа взяты у десктопа (`InkGlass` / `TopNavigationLayoutMetrics`):
  ///   * непрозрачность даёт blur, а не краска: единственный слой поверх
  ///     размытия — [_glassPillFill] (белый 0.30), см. его док;
  ///   * кромка — `InkGlass.edgeAlpha` (0.06), в мобильных токенах это
  ///     `glassEdge`; «нарисованный бордер» на стекле должен быть еле заметен;
  ///   * тень — `InkGlassShadow.ambient` (radius 8, opacity 0.10, offset 2),
  ///     тот же литерал, что уже рисуют остальные Glass-поверхности приложения.
  /// Единственное расхождение — радиус: десктоп режет бар под общий
  /// `InkGlass.cornerRadius` (22 при высоте 52), мобильная пилюля идёт капсулой
  /// (высота/2), потому что под ней нет соседних панелей с тем же углом.
  Widget _buildGlassPill(BuildContext context, OmiTokens t, int selectedIndex) {
    final radius = BorderRadius.circular(_glassPillHeight / 2);
    // Системная область снизу: жестовая полоса не должна резать пилюлю.
    final bottomInset = MediaQuery.paddingOf(context).bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 0, 16, bottomInset + 12),
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: radius,
          boxShadow: const [BoxShadow(color: Color(0x1A000000), blurRadius: 8, offset: Offset(0, 2))],
        ),
        // Blur идёт через общий хелпер, а не через свой BackdropFilter: так
        // пилюля попадает под общий рубильник kGlassRealBlur вместе с
        // остальными стеклянными панелями. Геометрия и альфы прежние.
        child: glassBlur(
          borderRadius: radius,
          sigma: _glassPillBlurSigma,
          child: Container(
            height: _glassPillHeight,
            decoration: BoxDecoration(
              color: _glassPillFill,
              borderRadius: radius,
              border: Border.all(color: t.glassEdge, width: 1),
            ),
            child: _buildTabRow(context, selectedIndex, _glassPillHeight),
          ),
        ),
      ),
    );
  }

  Widget _buildTabRow(BuildContext context, int selectedIndex, double rowHeight) {
    return Row(
      children: [
        _buildTab(context, selectedIndex, 0, OmiIcon.home, 'Home', rowHeight),
        _buildTab(context, selectedIndex, 1, OmiIcon.chat, 'Conversations', rowHeight),
        _buildTab(context, selectedIndex, 2, OmiIcon.tasks, 'Tasks', rowHeight),
        _buildTab(context, selectedIndex, 3, OmiIcon.apps, 'Apps', rowHeight),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => _navigation!;

  Widget _buildTab(
    BuildContext context,
    int selectedIndex,
    int index,
    OmiIcon icon,
    String label,
    double rowHeight,
  ) {
    final t = context.omi;
    final isSelected = selectedIndex == index;
    // Classic keeps the exact white/grey pair it has always drawn; Glass needs
    // ink tones instead, white would be invisible on the light bar.
    final color = t.isGlass ? (isSelected ? t.textPrimary : t.textTertiary) : (isSelected ? Colors.white : Colors.grey);
    final Widget iconWidget = OmiIconWidget(icon: icon, color: color, size: 26);
    // Glass marks the active tab with a filled circle behind the icon, the way
    // the desktop pill does; Classic keeps the bare icon it has always drawn.
    // 46 pt внутри 68 pt пилюли — те же 11 pt воздуха сверху и снизу.
    final Widget tabContent = t.isGlass && isSelected
        ? Container(
            width: 46,
            height: 46,
            alignment: Alignment.center,
            decoration: BoxDecoration(shape: BoxShape.circle, color: t.chipFillActive),
            child: iconWidget,
          )
        : iconWidget;
    return Expanded(
      child: InkWell(
        onTapDown: (_) => widget.onTabWarmup?.call(index),
        onTap: () {
          // Switch the visible page before crossing the platform channel for
          // haptics or analytics. Both can be delayed when the device is busy,
          // but neither should delay visual acknowledgement of the tap.
          widget.onTabTap(index, context.read<HomeProvider>().selectedIndex == index);
          primaryFocus?.unfocus();
          WidgetsBinding.instance.addPostFrameCallback((_) {
            HapticFeedback.selectionClick();
            PlatformManager.instance.analytics.bottomNavigationTabClicked(label);
          });
        },
        child: SizedBox(
          height: rowHeight,
          child: Center(child: tabContent),
        ),
      ),
    );
  }
}
