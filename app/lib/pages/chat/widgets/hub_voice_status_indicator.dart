// Индикатор голосового хода в чате: живая иконка Omi по центру вместо подписи
// «Слушаю…» (решение Игоря 24.08 — фазу показывает движение, а не слово).
//
// Deliberately NOT a mode toggle: starting/stopping the free-form voice mode
// (ДОПОЛНЕНИЕ 22.08's button) needs `FreeFormVoiceMode` wired to a
// `HubController` plus native audio focus / a foreground service — none of
// that exists yet. This widget only reflects turns the pendant's
// single-tap gesture already drives via `hubTurnDriver` (capture_controller.dart:861,886),
// gated by the `pttHubEnabled` dev flag — so it renders nothing for anyone
// who hasn't turned that on.
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:omi/pages/settings/voice_orb_theme_dialog.dart' show voiceOrbThemeFromIndex;
import 'package:omi/backend/preferences.dart';
import 'package:omi/providers/capture_provider.dart';
import 'package:omi/providers/developer_mode_provider.dart';
import 'package:omi/services/voice_hub/voice_turn_machine.dart' show VoiceTurnUiProjection;
import 'package:omi/widgets/omi_voice_orb.dart';

class HubVoiceStatusIndicator extends StatelessWidget {
  const HubVoiceStatusIndicator({super.key});

  @override
  Widget build(BuildContext context) {
    final captureProvider = context.watch<CaptureProvider>();
    // `DeveloperModeProvider` НЕ зарегистрирован глобально: его создаёт только
    // экран настроек разработчика. Обязательное чтение отсюда роняло чат в
    // ProviderNotFound → каскад RenderFlex Infinity → чёрный экран на старте
    // (живой случай 24.08 23:41, та же ошибка в соседней кнопке).
    //
    // Поэтому чтение необязательное: если провайдер в дереве есть (экран
    // настроек, виджет-тест) — берём из него и перерисовываемся при
    // переключении флага; если его нет — читаем то же самое из настроек,
    // которые провайдер и зеркалит. Обе половины контракта сохранены.
    final developer = context.watch<DeveloperModeProvider?>();
    final prefs = SharedPreferencesUtil();
    final themeIndex = developer?.voiceOrbTheme ?? prefs.voiceOrbTheme;
    final hasVoiceModeButton = developer?.freeFormMode ?? prefs.freeFormMode;

    return ValueListenableBuilder<VoiceTurnUiProjection>(
      valueListenable: captureProvider.hubProjection,
      builder: (context, projection, _) {
        // Подсказка — это конкретная фраза, которую хост хочет сказать ВМЕСТО
        // обычного слова фазы, и ставится она только когда обычное слово
        // соврало бы. Живой случай — восстановление связи: «Связь прервалась,
        // восстанавливаю…» вместе с `isThinking`. Такое иконкой не покажешь,
        // поэтому подсказка по-прежнему выводится текстом.
        if (projection.hint.isNotEmpty) return _HintChip(text: projection.hint);

        // Живая иконка живёт на кнопке голосового режима — когда та на
        // экране, второй такой же орб посреди чата был бы дубликатом.
        // Здесь она остаётся только для ходов, у которых кнопки нет: жест
        // кулона за флагом `pttHubEnabled` работает и при выключенном
        // `freeFormMode`, и без этой ветки такой разговор шёл бы вообще без
        // единого признака на экране.
        if (hasVoiceModeButton) return const SizedBox.shrink();

        final phase = _phaseFor(projection);
        if (phase == null) return const SizedBox.shrink();

        return Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Center(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 200),
              // Ключ постоянный, НЕ по фазе: иначе смена «слушаю → думаю»
              // пересоздавала бы виджет, а с ним и накопленное время
              // анимации — иконка дёргалась бы ровно на тех переходах, ради
              // плавности которых этот AnimatedSwitcher и стоит. Переход
              // нужен только между «иконки нет» и «иконка есть».
              child: OmiVoiceOrb(
                key: const ValueKey('orb'),
                phase: phase,
                theme: voiceOrbThemeFromIndex(themeIndex),
                diameter: 48,
                level: captureProvider.voiceOutputEnvelope.level.value,
              ),
            ),
          ),
        );
      },
    );
  }

  /// `null` means idle — nothing to show. Order matters: a turn can be
  /// listening AND have a stale `isResponseActive` from the prior turn for
  /// one frame, so listening wins.
  ///
  /// `isHearingUser` is the free-form mode's server-VAD state: same listening
  /// phase, but the provider is picking the user's voice up right now. It
  /// answers the question a silent screen cannot — whether the phone hears you
  /// at all — and the PTT path never sets it.
  OmiVoiceOrbPhase? _phaseFor(VoiceTurnUiProjection projection) {
    if (projection.isListening) {
      return projection.isHearingUser ? OmiVoiceOrbPhase.hearingUser : OmiVoiceOrbPhase.listening;
    }
    if (projection.isThinking || projection.isResponseWaiting) return OmiVoiceOrbPhase.thinking;
    if (projection.isResponseActive) return OmiVoiceOrbPhase.speaking;
    return null;
  }
}

/// Прежняя текстовая плашка — осталась ровно для подсказок хоста.
class _HintChip extends StatelessWidget {
  const _HintChip({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 64, right: 8, bottom: 6),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: const Color(0xFF1F1F25),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: const Color(0xFF35343B), width: 1),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 10,
                height: 10,
                child: CircularProgressIndicator(strokeWidth: 1.5, color: Colors.grey.shade400),
              ),
              const SizedBox(width: 8),
              Text(text, style: TextStyle(color: Colors.grey.shade300, fontSize: 13)),
            ],
          ),
        ),
      ),
    );
  }
}
