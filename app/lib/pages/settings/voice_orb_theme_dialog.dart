import 'package:flutter/material.dart';

import 'package:omi/widgets/omi_voice_orb.dart';

/// Выбор оформления живой иконки голосового режима.
///
/// Намеренно на простом английском, а не через `context.l10n`: как и соседние
/// «Free-form Voice Mode» / «Voice mode auto-off», это self-host-функция за
/// developer-флагом, и ключи в каждый upstream .arb добавили бы шум в будущий
/// диff.
///
/// Форма — как у [FreeFormVoiceTimeoutDialog]: та же карточка, та же рамка у
/// выбранного пункта, та же пара «Cancel / Save», чтобы два пикера в одних
/// настройках не выглядели из разных приложений. Отличие одно: каждый пункт
/// показывает живую иконку в этой теме — выбирать оформление по названию,
/// не видя его, бессмысленно.
class VoiceOrbThemeDialog {
  /// Возвращает индекс выбранной темы или `null`, если отменили. Сохраняет
  /// вызывающий: сам диалог не трогает настройки, и это позволяет гонять его
  /// в виджет-тесте без `SharedPreferences`.
  static Future<int?> show(BuildContext context, {required int currentIndex}) {
    int selected = currentIndex;
    return showDialog<int>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setState) {
            return AlertDialog(
              backgroundColor: const Color(0xFF1A1A1A),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              title: const Text(
                'Voice icon theme',
                style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w600),
              ),
              content: SizedBox(
                width: double.maxFinite,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'The animated icon shown in chat while a voice turn is running.',
                        style: TextStyle(color: Color(0xFF8E8E93), fontSize: 14),
                      ),
                      const SizedBox(height: 16),
                      ...kVoiceOrbThemeOrder.map((theme) {
                        final isSelected = selected == theme.index;
                        return Container(
                          margin: const EdgeInsets.only(bottom: 8),
                          child: Material(
                            color: Colors.transparent,
                            child: InkWell(
                              borderRadius: BorderRadius.circular(12),
                              onTap: () => setState(() => selected = theme.index),
                              child: Container(
                                padding: const EdgeInsets.all(12),
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(
                                    color: isSelected ? Colors.white : const Color(0xFF3A3A3C),
                                    width: isSelected ? 2 : 1,
                                  ),
                                ),
                                child: Row(
                                  children: [
                                    OmiVoiceOrb(
                                      phase: OmiVoiceOrbPhase.listening,
                                      theme: theme,
                                      diameter: 34,
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Text(
                                        voiceOrbThemeLabel(theme),
                                        style: TextStyle(
                                          color: isSelected ? Colors.white : const Color(0xFFB0B0B5),
                                          fontSize: 16,
                                          fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
                                        ),
                                      ),
                                    ),
                                    if (isSelected) const Icon(Icons.check, color: Colors.white, size: 18),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        );
                      }),
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancel', style: TextStyle(color: Color(0xFF8E8E93))),
                ),
                TextButton(
                  onPressed: () => Navigator.of(context).pop(selected),
                  child: const Text('Save', style: TextStyle(color: Colors.white)),
                ),
              ],
            );
          },
        );
      },
    );
  }
}

/// Подпись темы в пикере и в строке настроек.
String voiceOrbThemeLabel(OmiVoiceOrbTheme theme) {
  switch (theme) {
    case OmiVoiceOrbTheme.gradient:
      return 'Gradient';
    case OmiVoiceOrbTheme.dark:
      return 'Dark';
    case OmiVoiceOrbTheme.light:
      return 'Light';
    case OmiVoiceOrbTheme.black:
      return 'Black';
  }
}

/// Порядок тем в пикере. Отдельно от `OmiVoiceOrbTheme.values`, потому что в
/// enum новые темы дописываются в конец (индекс = сохранённая настройка), а
/// показывать их логичнее по родству: два тёмных подряд, светлая отдельно.
const List<OmiVoiceOrbTheme> kVoiceOrbThemeOrder = [
  OmiVoiceOrbTheme.gradient,
  OmiVoiceOrbTheme.dark,
  OmiVoiceOrbTheme.black,
  OmiVoiceOrbTheme.light,
];

/// Индекс из настроек в тему. Значение вне диапазона (руками правленая
/// настройка, откат версии) возвращает градиент, а не роняет экран.
OmiVoiceOrbTheme voiceOrbThemeFromIndex(int index) {
  if (index < 0 || index >= OmiVoiceOrbTheme.values.length) return OmiVoiceOrbTheme.gradient;
  return OmiVoiceOrbTheme.values[index];
}
