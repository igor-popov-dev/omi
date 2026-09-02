// The hands-free voice-mode toggle from ДОПОЛНЕНИЕ 22.08 п.1 ("справа от
// иконки микрофона, круглая, как в ChatGPT/Claude"). Gated by the
// `freeFormMode` dev flag — `preferences.dart`'s own doc comment for that
// flag already reads "hands-free voice-mode button in chat (experimental)",
// i.e. this button IS what that flag was added to gate (`developer.dart`'s
// settings toggle). Hidden entirely while the flag is off, same discipline
// as every other experimental hub surface in this series
// (`HubVoiceStatusIndicator`, `pttHubEnabled`'s gesture routing).
//
// Tapping the button calls `CaptureController.startFreeFormVoiceMode()` /
// `stopFreeFormVoiceMode()` (`main.dart` wires `capture.freeFormVoiceMode`
// at bootstrap via `createProductionFreeFormVoiceMode`) — a real network
// call the moment it turns on (mints a token, opens a socket, starts
// continuous mic capture), not a stub: real per-minute-billed voice traffic
// (ДОПОЛНЕНИЕ 22.08 п.6), which is exactly why it stays behind the flag.
//
// Пока идёт разговор, кнопка — это живая иконка (`OmiVoiceOrb`, решение
// Игоря 24.08): она и показывает фазу, и остаётся единственным способом
// выключить поминутно оплачиваемый сокет.
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:provider/provider.dart';

import 'package:omi/backend/preferences.dart';
import 'package:omi/pages/chat/widgets/claude_escalation_sheet.dart';
import 'package:omi/pages/settings/voice_orb_theme_dialog.dart' show voiceOrbThemeFromIndex;
import 'package:omi/providers/capture_provider.dart';
import 'package:omi/providers/developer_mode_provider.dart';
import 'package:omi/services/mic/mic_arbiter.dart' show MicBusyError, kConversationMicOwner;
import 'package:omi/services/voice_hub/escalation_level.dart';
import 'package:omi/services/voice_hub/voice_turn_machine.dart' show VoiceTurnUiProjection;
import 'package:omi/utils/alerts/app_snackbar.dart';
import 'package:omi/widgets/omi_voice_orb.dart';

/// Диаметр круга иконки внутри кнопки. Меньше самой кнопки (38): ореол
/// выходит за её край через [OverflowBox] и не должен упираться в соседей.
const double _kOrbDiameter = 34;

class FreeFormVoiceModeButton extends StatelessWidget {
  /// True when the chat composer holds a draft. An idle button stands down in
  /// that case: with dictation appending to the draft, mic + Send are the two
  /// controls the draft needs, and a third circle only eats the width they are
  /// fighting for. An ACTIVE session keeps its button no matter what is in the
  /// field — it is the only way to stop a per-minute-billed socket, and text
  /// can appear (typed, dictated) while the session runs.
  final bool composerHasDraft;

  const FreeFormVoiceModeButton({super.key, this.composerHasDraft = false});

  @override
  Widget build(BuildContext context) {
    final captureProvider = context.watch<CaptureProvider>();
    // `DeveloperModeProvider` глобально НЕ зарегистрирован — он живёт только
    // внутри экрана настроек разработчика. Обязательный `context.select` отсюда
    // ронял build кнопки ProviderNotFound'ом, а за ним каскадом всю отрисовку
    // чата: чёрный экран на старте (баг Игоря 24.08 ~23:42).
    //
    // Чтение необязательное: есть провайдер в дереве (настройки, виджет-тест) —
    // берём из него и перерисовываемся сразу; нет — читаем то же самое из
    // настроек, которые провайдер и зеркалит. Тот же паттерн, что в
    // `HubVoiceStatusIndicator`; сторож на оба —
    // `test/pages/chat/chat_widgets_without_developer_provider_test.dart`.
    final developer = context.watch<DeveloperModeProvider?>();
    final prefs = SharedPreferencesUtil();
    if (!(developer?.freeFormMode ?? prefs.freeFormMode)) return const SizedBox.shrink();
    final themeIndex = developer?.voiceOrbTheme ?? prefs.voiceOrbTheme;

    return ValueListenableBuilder<bool>(
      valueListenable: captureProvider.freeFormModeActive,
      builder: (context, active, _) {
        if (!active && composerHasDraft) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.only(left: 8),
          child: ValueListenableBuilder<VoiceTurnUiProjection>(
            valueListenable: captureProvider.hubProjection,
            builder: (context, projection, _) {
              final phase = active ? _phaseFor(projection) : null;
              return GestureDetector(
                onTap: () => _onTap(context, captureProvider, active),
                // Долгое нажатие — ползунок «как часто голосовой режим ходит к
                // Claude» (5 ячеек, escalation_level.dart). Скрыт вместе с самим
                // ползунком (см. claudeEscalationSliderEnabled) — на правом крае
                // модель «двоилась», Игорь убрал до переделки доставки.
                onLongPress: !claudeEscalationSliderEnabled
                    ? null
                    : () {
                        HapticFeedback.mediumImpact();
                        showClaudeEscalationSheet(context);
                      },
                child: SizedBox(
                  height: 38,
                  width: 38,
                  child: AnimatedSwitcher(
                    // Разговор начинается и кончается не мгновенно, и кнопка не
                    // должна щёлкать формой на границе: 200 мс достаточно,
                    // чтобы переход читался, и мало, чтобы не мешать нажать
                    // снова.
                    duration: const Duration(milliseconds: 200),
                    child: phase == null
                        ? (active
                            ? const _StopButton(key: ValueKey('stop'))
                            : const _IdleOrbButton(key: ValueKey('idle-orb')))
                        : _OrbButton(
                            key: const ValueKey('orb'),
                            phase: phase,
                            theme: voiceOrbThemeFromIndex(themeIndex),
                            level: captureProvider.voiceOutputEnvelope.level,
                          ),
                  ),
                ),
              );
            },
          ),
        );
      },
    );
  }

  /// `null` — хода нет, кнопка остаётся обычной. Порядок как в
  /// `HubVoiceStatusIndicator`: слушание бьёт залежавшийся флаг речи.
  OmiVoiceOrbPhase? _phaseFor(VoiceTurnUiProjection projection) {
    if (projection.isListening) {
      return projection.isHearingUser ? OmiVoiceOrbPhase.hearingUser : OmiVoiceOrbPhase.listening;
    }
    if (projection.isThinking || projection.isResponseWaiting) return OmiVoiceOrbPhase.thinking;
    if (projection.isResponseActive) return OmiVoiceOrbPhase.speaking;
    return null;
  }

  void _onTap(BuildContext context, CaptureProvider captureProvider, bool active) {
    HapticFeedback.mediumImpact();
    if (active) {
      // Пока ассистент говорит, нажатие — это «замолчи», а не «выключи режим»:
      // прервать разговорившегося собеседника нужно куда чаще, чем закончить
      // разговор, и до сих пор для этого приходилось лезть к кулону. Когда
      // ассистент молчит, нажатие означает прежнее — выключить режим, так что
      // способ остановить поминутный сокет никуда не девается.
      if (captureProvider.interruptAssistantSpeech()) return;
      captureProvider.stopFreeFormVoiceMode();
      return;
    }
    captureProvider.startFreeFormVoiceMode().catchError((Object error) {
      AppSnackbar.showSnackbarError(freeFormVoiceModeStartErrorMessage(error));
    });
  }
}

/// Кнопка вне разговора: тот же orb, что живёт на кнопке во время разговора,
/// но застывший и всегда в чёрной теме (решение Игоря 02.09 — прежний серый
/// круг с «волной» ему не нравился). Тема фиксирована и не следует за
/// настройкой «Voice icon theme»: настройка описывает живую иконку разговора,
/// а в покое кнопка должна выглядеть одинаково и узнаваемо.
class _IdleOrbButton extends StatelessWidget {
  const _IdleOrbButton({super.key});

  @override
  Widget build(BuildContext context) {
    const side = _kOrbDiameter * kOmiVoiceOrbPadding;
    return const OverflowBox(
      maxWidth: side,
      maxHeight: side,
      child: OmiVoiceOrb(
        phase: OmiVoiceOrbPhase.listening,
        theme: OmiVoiceOrbTheme.black,
        diameter: _kOrbDiameter,
        animated: false,
      ),
    );
  }
}

/// Кнопка во время разговора вне хода (фазы нет): белый круг с иконкой стоп.
class _StopButton extends StatelessWidget {
  const _StopButton({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 38,
      width: 38,
      decoration: const BoxDecoration(
        color: Colors.white,
        shape: BoxShape.circle,
      ),
      child: const Center(
        child: FaIcon(
          FontAwesomeIcons.stop,
          color: Color(0xFF1f1f25),
          size: 16,
        ),
      ),
    );
  }
}

/// Кнопка во время разговора: живая иконка. Ореол шире кнопки, поэтому
/// [OverflowBox] — он выпускает свечение за её границы, не раздвигая ряд с
/// микрофоном и отправкой.
class _OrbButton extends StatelessWidget {
  const _OrbButton({required this.phase, required this.theme, required this.level, super.key});

  final OmiVoiceOrbPhase phase;
  final OmiVoiceOrbTheme theme;
  final ValueListenable<double> level;

  @override
  Widget build(BuildContext context) {
    const side = _kOrbDiameter * kOmiVoiceOrbPadding;
    return OverflowBox(
      maxWidth: side,
      maxHeight: side,
      child: ValueListenableBuilder<double>(
        valueListenable: level,
        builder: (context, value, _) => OmiVoiceOrb(
          phase: phase,
          theme: theme,
          diameter: _kOrbDiameter,
          level: value,
        ),
      ),
    );
  }
}

/// What the toggle says when the mode refuses to start.
///
/// A busy microphone is the one failure here that is not a malfunction: the
/// hub and conversation capture share one recorder through [MicArbiter], so
/// asking for the mic while the phone is recording a conversation is an
/// ordinary situation with an ordinary answer. Showing "Bad state:
/// Microphone is busy (held by conversation)" for it reads as a crash.
String freeFormVoiceModeStartErrorMessage(Object error) {
  if (error is MicBusyError) {
    return error.owner == kConversationMicOwner
        ? 'Микрофон занят записью разговора — остановите запись и включите режим снова'
        : 'Микрофон сейчас занят (${error.owner})';
  }
  return 'Не удалось включить голосовой режим: $error';
}
