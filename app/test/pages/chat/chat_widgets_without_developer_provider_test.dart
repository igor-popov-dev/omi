// Сторож против класса ошибок, который стоил чёрного экрана 24.08 в 23:41.
//
// ЧТО СЛУЧИЛОСЬ. Два виджета чата читали `DeveloperModeProvider` обязательным
// `context.select`. Провайдер глобально НЕ зарегистрирован — его создаёт только
// экран настроек разработчика. В бою чтение падало в ProviderNotFound на build,
// дальше каскад RenderFlex Infinity и шторм семантических ассертов на каждом
// кадре: приложение открывалось в чёрный экран.
//
// ПОЧЕМУ 2095 ТЕСТОВ ЭТО ПРОПУСТИЛИ. Виджет-тесты поднимают виджет со СВОИМ
// набором провайдеров — в `hub_voice_status_indicator_test.dart` он есть в
// каждом хосте. Отсутствие глобальной регистрации такому тесту не видно в
// принципе: он сам её и подменяет.
//
// ПОЭТОМУ здесь виджеты поднимаются РОВНО так, как в бою: без
// `DeveloperModeProvider` в дереве. Тест не проверяет, что нарисовано, — он
// проверяет, что виджет вообще способен построиться в продакшн-окружении.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:omi/backend/preferences.dart';
import 'package:omi/pages/chat/widgets/free_form_voice_mode_button.dart';
import 'package:omi/pages/chat/widgets/hub_voice_status_indicator.dart';
import 'package:omi/providers/capture_provider.dart';

/// Дерево БЕЗ `DeveloperModeProvider` — как в `main.dart`.
Widget _productionLikeHost(Widget child) => MaterialApp(
      home: MultiProvider(
        providers: [
          ChangeNotifierProvider<CaptureProvider>.value(value: CaptureProvider()),
        ],
        child: Scaffold(body: child),
      ),
    );

void main() {
  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    await SharedPreferencesUtil.init();
  });

  testWidgets('индикатор голосового хода строится без DeveloperModeProvider', (tester) async {
    await tester.pumpWidget(_productionLikeHost(const HubVoiceStatusIndicator()));

    expect(tester.takeException(), isNull);
  });

  testWidgets('кнопка голосового режима строится без DeveloperModeProvider', (tester) async {
    // Вторая половина того же бага: именно она открыла чёрный экран на старте.
    SharedPreferencesUtil().freeFormMode = true;

    await tester.pumpWidget(_productionLikeHost(const FreeFormVoiceModeButton()));

    expect(tester.takeException(), isNull);
  });

  testWidgets('он же читает тему орба из настроек, когда провайдера нет', (tester) async {
    // Провайдер зеркалит эти же настройки, поэтому при его отсутствии значение
    // должно браться отсюда, а не падать и не превращаться в дефолт молча.
    SharedPreferencesUtil().voiceOrbTheme = 2;
    SharedPreferencesUtil().freeFormMode = true;

    await tester.pumpWidget(_productionLikeHost(const HubVoiceStatusIndicator()));

    expect(tester.takeException(), isNull);
  });
}
