// Тесты живой иконки голосового режима: геометрия кольца, разбор сохранённой
// темы и то, что пикер показывает все темы.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:omi/pages/settings/voice_orb_theme_dialog.dart';
import 'package:omi/widgets/omi_voice_orb.dart';

void main() {
  group('voiceOrbThemeFromIndex', () {
    test('разбирает сохранённые индексы', () {
      for (final theme in OmiVoiceOrbTheme.values) {
        expect(voiceOrbThemeFromIndex(theme.index), theme);
      }
    });

    // Настройка правится руками и переживает откат версии, а индекс из будущей
    // сборки в старой не существует. Нечитаемое значение обязано давать
    // градиент, а не падение экрана чата.
    test('значение вне диапазона даёт градиент', () {
      expect(voiceOrbThemeFromIndex(-1), OmiVoiceOrbTheme.gradient);
      expect(voiceOrbThemeFromIndex(OmiVoiceOrbTheme.values.length), OmiVoiceOrbTheme.gradient);
      expect(voiceOrbThemeFromIndex(999), OmiVoiceOrbTheme.gradient);
    });
  });

  // Порядок в пикере задан руками, отдельно от `values`, — значит новую тему
  // можно добавить в enum и забыть показать её пользователю.
  test('пикер показывает все темы ровно по разу', () {
    expect(kVoiceOrbThemeOrder.toSet(), OmiVoiceOrbTheme.values.toSet());
    expect(kVoiceOrbThemeOrder.length, OmiVoiceOrbTheme.values.length);
  });

  test('у каждой темы есть подпись', () {
    for (final theme in OmiVoiceOrbTheme.values) {
      expect(voiceOrbThemeLabel(theme), isNotEmpty);
    }
  });

  group('OmiVoiceOrb', () {
    testWidgets('занимает поле с запасом под ореол', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: Center(child: OmiVoiceOrb(phase: OmiVoiceOrbPhase.listening, diameter: 48)),
        ),
      ));

      final size = tester.getSize(find.byType(OmiVoiceOrb));
      expect(size.width, 48 * kOmiVoiceOrbPadding);
      expect(size.height, 48 * kOmiVoiceOrbPadding);
    });

    // Тикер должен останавливаться вместе с виджетом: иначе иконка, ушедшая с
    // экрана вместе с закрытым чатом, продолжит будить кадры до конца сессии.
    testWidgets('перестаёт тикать после снятия с экрана', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: OmiVoiceOrb(phase: OmiVoiceOrbPhase.speaking)),
      ));
      await tester.pump(const Duration(milliseconds: 32));

      await tester.pumpWidget(const MaterialApp(home: Scaffold(body: SizedBox.shrink())));

      // незакрытый Ticker валит тест сам — flutter_test проверяет это в tearDown
      expect(find.byType(OmiVoiceOrb), findsNothing);
    });

    // «Уменьшить движение» — системная настройка доступности: при ней иконка
    // обязана замереть, а не продолжать дышать в поле зрения.
    testWidgets('замирает при системном «уменьшить движение»', (tester) async {
      // MediaQuery именно ВНУТРИ MaterialApp: снаружи его переопределит
      // собственный MediaQuery приложения, и настройка до иконки не дойдёт.
      await tester.pumpWidget(const MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(disableAnimations: true),
          child: Scaffold(body: OmiVoiceOrb(phase: OmiVoiceOrbPhase.thinking, diameter: 32)),
        ),
      ));
      await tester.pump(const Duration(milliseconds: 16));

      // работающий тикер держит transient-колбэк на каждом кадре
      expect(tester.binding.transientCallbackCount, 0);
    });

    testWidgets('без этой настройки тикает', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(disableAnimations: false),
          child: Scaffold(body: OmiVoiceOrb(phase: OmiVoiceOrbPhase.thinking, diameter: 32)),
        ),
      ));
      await tester.pump(const Duration(milliseconds: 16));

      expect(tester.binding.transientCallbackCount, greaterThan(0));
    });

    testWidgets('рисуется во всех темах и фазах', (tester) async {
      for (final theme in OmiVoiceOrbTheme.values) {
        for (final phase in OmiVoiceOrbPhase.values) {
          await tester.pumpWidget(MaterialApp(
            home: Scaffold(body: OmiVoiceOrb(phase: phase, theme: theme, diameter: 24)),
          ));
          await tester.pump(const Duration(milliseconds: 16));
          expect(tester.takeException(), isNull);
        }
      }
    });
  });
}
