// Вид кнопки голосового режима в покое: застывший чёрный orb (решение Игоря
// 02.09), а не прежний серый круг с иконкой волны. Тема фиксирована и не
// следует за настройкой «Voice icon theme» — та описывает живую иконку
// разговора; проверяем и это, выставив в настройках другую тему.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:omi/backend/preferences.dart';
import 'package:omi/pages/chat/widgets/free_form_voice_mode_button.dart';
import 'package:omi/providers/capture_provider.dart';
import 'package:omi/widgets/omi_voice_orb.dart';

Widget _host(Widget child) => MaterialApp(
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

  testWidgets('в покое кнопка — застывший чёрный orb без иконки волны', (tester) async {
    SharedPreferencesUtil().freeFormMode = true;
    // Тема живой иконки — градиент; кнопка в покое обязана остаться чёрной.
    SharedPreferencesUtil().voiceOrbTheme = OmiVoiceOrbTheme.gradient.index;

    await tester.pumpWidget(_host(const FreeFormVoiceModeButton()));

    final orb = tester.widget<OmiVoiceOrb>(find.byType(OmiVoiceOrb));
    expect(orb.theme, OmiVoiceOrbTheme.black);
    expect(orb.animated, isFalse, reason: 'в покое тикер не должен крутиться');
    expect(find.byType(FaIcon), findsNothing, reason: 'иконка волны ушла вместе с серым кругом');
  });
}
