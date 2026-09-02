// The indicator renders the live icon, one phase per turn state — and, since
// the drop recovery exists, a hint that says something no icon can.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:omi/pages/chat/widgets/hub_voice_status_indicator.dart';
import 'package:omi/providers/capture_provider.dart';
import 'package:omi/providers/developer_mode_provider.dart';
import 'package:omi/services/voice_hub/voice_turn_machine.dart' show VoiceTurnUiProjection, idleVoiceTurnProjection;
import 'package:omi/widgets/omi_voice_orb.dart';

Widget _host(CaptureProvider provider, {DeveloperModeProvider? developer}) => MaterialApp(
      home: MultiProvider(
        providers: [
          ChangeNotifierProvider<CaptureProvider>.value(value: provider),
          ChangeNotifierProvider<DeveloperModeProvider>.value(value: developer ?? DeveloperModeProvider()),
        ],
        child: const Scaffold(body: HubVoiceStatusIndicator()),
      ),
    );

const VoiceTurnUiProjection _listening = VoiceTurnUiProjection(
  isListening: true,
  isLocked: false,
  isFollowUp: false,
  transcript: '',
  hint: '',
  isThinking: false,
  isResponseWaiting: false,
  isResponseActive: false,
);

OmiVoiceOrbPhase _renderedPhase(WidgetTester tester) => tester.widget<OmiVoiceOrb>(find.byType(OmiVoiceOrb)).phase;

void main() {
  testWidgets('an idle projection renders nothing', (tester) async {
    final provider = CaptureProvider();
    provider.hubProjection.value = idleVoiceTurnProjection;

    await tester.pumpWidget(_host(provider));

    expect(find.byType(OmiVoiceOrb), findsNothing);
  });

  testWidgets('listening and hearing are told apart', (tester) async {
    final provider = CaptureProvider();
    provider.hubProjection.value = _listening;

    await tester.pumpWidget(_host(provider));
    expect(_renderedPhase(tester), OmiVoiceOrbPhase.listening);

    provider.hubProjection.value = const VoiceTurnUiProjection(
      isListening: true,
      isLocked: false,
      isFollowUp: false,
      transcript: '',
      hint: '',
      isThinking: false,
      isResponseWaiting: false,
      isResponseActive: false,
      isHearingUser: true,
    );
    await tester.pump();
    expect(_renderedPhase(tester), OmiVoiceOrbPhase.hearingUser);
  });

  // Listening wins over a stale `isResponseActive` left from the prior turn:
  // for one frame a turn can carry both, and the icon must not flash into the
  // speaking tempo while the microphone is what is actually open.
  testWidgets('listening wins over a stale speaking flag', (tester) async {
    final provider = CaptureProvider();
    provider.hubProjection.value = const VoiceTurnUiProjection(
      isListening: true,
      isLocked: false,
      isFollowUp: false,
      transcript: '',
      hint: '',
      isThinking: false,
      isResponseWaiting: false,
      isResponseActive: true,
    );

    await tester.pumpWidget(_host(provider));

    expect(_renderedPhase(tester), OmiVoiceOrbPhase.listening);
  });

  testWidgets('the response phase renders the speaking tempo', (tester) async {
    final provider = CaptureProvider();
    provider.hubProjection.value = const VoiceTurnUiProjection(
      isListening: false,
      isLocked: false,
      isFollowUp: false,
      transcript: '',
      hint: '',
      isThinking: false,
      isResponseWaiting: false,
      isResponseActive: true,
    );

    await tester.pumpWidget(_host(provider));

    expect(_renderedPhase(tester), OmiVoiceOrbPhase.speaking);
  });

  // The recovery sets its hint alongside `isThinking`, so without the hint
  // branch a reconnect looked exactly like an ordinary pause for thought —
  // the one thing the user must not be told, since the whole point of the
  // recovery patch is that a drop used to be indistinguishable from being
  // ignored. The icon cannot say this, so the hint stays text.
  testWidgets('a hint wins over the icon it would otherwise contradict', (tester) async {
    final provider = CaptureProvider();
    provider.hubProjection.value = const VoiceTurnUiProjection(
      isListening: false,
      isLocked: false,
      isFollowUp: false,
      transcript: '',
      hint: 'Связь прервалась, восстанавливаю…',
      isThinking: true,
      isResponseWaiting: false,
      isResponseActive: false,
    );

    await tester.pumpWidget(_host(provider));

    expect(find.text('Связь прервалась, восстанавливаю…'), findsOneWidget);
    expect(find.byType(OmiVoiceOrb), findsNothing);
  });

  // Живая иконка во включённом свободном режиме живёт на кнопке
  // (`FreeFormVoiceModeButton`). Индикатор в этом случае обязан молчать —
  // иначе на экране два одинаковых орба разом.
  testWidgets('иконка не дублируется, когда на экране кнопка режима', (tester) async {
    final provider = CaptureProvider();
    provider.hubProjection.value = _listening;
    final developer = DeveloperModeProvider();
    developer.freeFormMode = true;

    await tester.pumpWidget(_host(provider, developer: developer));

    expect(find.byType(OmiVoiceOrb), findsNothing);
  });

  // ...а вот ход по жесту кулона (`pttHubEnabled`) идёт без всякой кнопки,
  // и без индикатора у такого разговора не было бы ни одного признака.
  testWidgets('без кнопки режима иконку показывает индикатор', (tester) async {
    final provider = CaptureProvider();
    provider.hubProjection.value = _listening;
    final developer = DeveloperModeProvider();
    developer.freeFormMode = false;

    await tester.pumpWidget(_host(provider, developer: developer));

    expect(find.byType(OmiVoiceOrb), findsOneWidget);
  });

  // The theme is a stored index, and the indicator is what turns it back into
  // a theme — a settings value the picker can produce must arrive intact.
  testWidgets('the icon follows the theme chosen in settings', (tester) async {
    final provider = CaptureProvider();
    provider.hubProjection.value = _listening;
    final developer = DeveloperModeProvider();
    developer.voiceOrbTheme = OmiVoiceOrbTheme.light.index;

    await tester.pumpWidget(_host(provider, developer: developer));

    expect(tester.widget<OmiVoiceOrb>(find.byType(OmiVoiceOrb)).theme, OmiVoiceOrbTheme.light);
  });
}
