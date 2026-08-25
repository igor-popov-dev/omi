import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'package:omi/utils/theme/omi_theme.dart';
import 'package:omi/utils/theme/omi_tokens.dart';

/// Свитч приложения: iOS-форма в Glass, прежний Material-свитч в Classic.
///
/// Цвета Glass-свитча задаёт `switchTheme` в [buildOmiTheme], но **форму** тема
/// задать не может: Glass стоит на `useMaterial3: false`, а это конфиг M2 —
/// трек 33×14 с бегунком радиусом 10, который торчит за трек сверху и снизу.
/// Эталон (скриншот macOS + стандарт iOS) — трек 51×31 с бегунком внутри, и
/// единственный виджет, который рисует ровно его, это [CupertinoSwitch]. Поэтому
/// развилка живёт здесь, а не в теме.
///
/// Габарит при этом не меняется: M2-свитч занимает 59 логических пикселей в
/// ширину, [CupertinoSwitch] — те же 59 (высота 39 против 48, то есть строка
/// может стать чуть ниже).
///
/// Classic обязан остаться байт-в-байт прежним, поэтому цветовые параметры
/// call site'ов не выброшены, а проброшены сюда как [classicActiveThumbColor] /
/// [classicActiveTrackColor] — имена честные: в Glass они не участвуют, там
/// цвета берутся из токенов. `null` в обоих полях — это ровно то же самое, что
/// не передавать параметр в [Switch] (его дефолт и есть `null`).
///
/// В Glass бегунок белый (дефолт [CupertinoSwitch]), включённый трек —
/// [OmiTokens.accent], выключенный — [kGlassSwitchOffTrack]. Disabled гасится
/// самим [CupertinoSwitch] (общая прозрачность 0.5 при `onChanged == null`) —
/// так же, как это делает iOS, и так же, как настроен `switchTheme` для тех
/// свитчей, до которых обёртка не достаёт (`SwitchListTile`).
class OmiSwitch extends StatelessWidget {
  const OmiSwitch({
    super.key,
    required this.value,
    required this.onChanged,
    this.classicActiveThumbColor,
    this.classicActiveTrackColor,
  });

  final bool value;

  /// `null` выключает свитч (в обеих темах он гаснет).
  final ValueChanged<bool>? onChanged;

  /// `activeThumbColor` прежнего [Switch]. Только Classic.
  final Color? classicActiveThumbColor;

  /// `activeTrackColor` прежнего [Switch]. Только Classic.
  final Color? classicActiveTrackColor;

  @override
  Widget build(BuildContext context) {
    final t = context.omi;
    if (!t.isGlass) {
      return Switch(
        value: value,
        onChanged: onChanged,
        activeThumbColor: classicActiveThumbColor,
        activeTrackColor: classicActiveTrackColor,
      );
    }
    return CupertinoSwitch(
      value: value,
      onChanged: onChanged,
      activeTrackColor: t.accent,
      inactiveTrackColor: kGlassSwitchOffTrack,
    );
  }
}
