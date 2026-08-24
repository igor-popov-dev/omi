// Проверяет ПОСЛЕДНЕЕ звено пути причины отказа: доезжает ли она до глаз.
//
// Сценарий в облаке кладёт причину в заголовок отказа, клиент превращает её в
// человеческий текст — а экран звонка показывал этот текст ровно две секунды и
// закрывался. После закрытия текста нет нигде: снэкбар на странице звонков
// показывается только когда звонок НЕ НАЧАЛСЯ, а отклонённый облаком звонок начался.
// То есть вся работа заканчивалась вспышкой на две секунды.
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:omi/l10n/app_localizations.dart';

import 'package:omi/backend/schema/phone_call.dart';
import 'package:omi/backend/schema/transcript_segment.dart';
import 'package:omi/models/audio_route.dart';
import 'package:omi/pages/phone_calls/active_call_page.dart';
import 'package:omi/providers/phone_call_provider.dart';

class _StubPhoneCallProvider extends ChangeNotifier implements PhoneCallProvider {
  PhoneCallState _state = PhoneCallState.active;
  PhoneCallError? _error;

  void fail(PhoneCallError? error) {
    _state = PhoneCallState.failed;
    _error = error;
    notifyListeners();
  }

  void end() {
    _state = PhoneCallState.ended;
    notifyListeners();
  }

  @override
  PhoneCallState get callState => _state;
  @override
  PhoneCallError? get lastError => _error;
  @override
  String? get remoteNumber => '+995555123456';
  @override
  String? get contactName => null;
  @override
  Duration get callDuration => Duration.zero;
  @override
  bool get isMuted => false;
  @override
  bool get isSpeakerOn => false;
  @override
  List<AudioRoute> get availableRoutes => const [];
  @override
  AudioRoute? get selectedRoute => null;
  @override
  List<TranscriptSegment> get transcriptSegments => const [];
  @override
  TranscriptionStatus get transcriptionStatus => TranscriptionStatus.idle;
  @override
  Future<void> loadAudioRoutes() async {}
  @override
  String getSpeakerLabel(TranscriptSegment segment) => '';

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> _pushCallScreen(WidgetTester tester, _StubPhoneCallProvider provider) async {
  await tester.pumpWidget(
    ChangeNotifierProvider<PhoneCallProvider>.value(
      value: provider,
      child: MaterialApp(
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) => Scaffold(
            body: ElevatedButton(
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ActiveCallPage())),
              child: const Text('call'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('call'));
  await tester.pumpAndSettle();
}

void main() {
  group('closingMessageFor', () {
    test('a named refusal is worth repeating after the screen closes', () {
      final message = closingMessageFor(
        PhoneCallState.failed,
        PhoneCallError(code: 'VOX_QUOTA_EXCEEDED', message: 'This month\'s calling limit is used up.'),
      );

      expect(message, 'This month\'s calling limit is used up.');
    });

    test('a plain hang-up says nothing — a snack bar with no news is noise', () {
      expect(closingMessageFor(PhoneCallState.ended, null), isNull);
    });

    test('a failure with no reason attached says nothing either', () {
      expect(closingMessageFor(PhoneCallState.failed, null), isNull);
      expect(closingMessageFor(PhoneCallState.failed, PhoneCallError(code: 'SIP_486', message: '   ')), isNull);
    });
  });

  group('ActiveCallPage', () {
    testWidgets('the refusal survives the screen it was shown on', (tester) async {
      final provider = _StubPhoneCallProvider();
      addTearDown(provider.dispose);
      await _pushCallScreen(tester, provider);

      provider.fail(PhoneCallError(
        code: 'VOX_QUOTA_EXCEEDED',
        message: 'This month\'s calling limit is used up (300 of 300 used).',
      ));
      await tester.pump();

      // Пока экран жив, текст на нём — как и раньше.
      expect(find.textContaining('300 of 300'), findsOneWidget);

      // …а через две секунды экран закрывается, и текст обязан остаться на виду.
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();

      expect(find.byType(ActiveCallPage), findsNothing, reason: 'экран звонка должен был закрыться');
      expect(
          find.widgetWithText(SnackBar, 'This month\'s calling limit is used up (300 of 300 used).'), findsOneWidget);
    });

    testWidgets('an ordinary hang-up closes the screen without a snack bar', (tester) async {
      final provider = _StubPhoneCallProvider();
      addTearDown(provider.dispose);
      await _pushCallScreen(tester, provider);

      provider.end();
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();

      expect(find.byType(ActiveCallPage), findsNothing);
      expect(find.byType(SnackBar), findsNothing);
    });
  });
}
