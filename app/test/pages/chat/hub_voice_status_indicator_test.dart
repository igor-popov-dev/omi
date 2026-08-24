// The indicator renders one word per phase — and, since the drop recovery
// exists, a hint that says something the phase word cannot.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:omi/pages/chat/widgets/hub_voice_status_indicator.dart';
import 'package:omi/providers/capture_provider.dart';
import 'package:omi/services/voice_hub/voice_turn_machine.dart' show VoiceTurnUiProjection, idleVoiceTurnProjection;

Widget _host(CaptureProvider provider) => MaterialApp(
      home: ChangeNotifierProvider<CaptureProvider>.value(
        value: provider,
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

void main() {
  testWidgets('an idle projection renders nothing', (tester) async {
    final provider = CaptureProvider();
    provider.hubProjection.value = idleVoiceTurnProjection;

    await tester.pumpWidget(_host(provider));

    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('listening and hearing are told apart', (tester) async {
    final provider = CaptureProvider();
    provider.hubProjection.value = _listening;

    await tester.pumpWidget(_host(provider));
    expect(find.text('Слушаю…'), findsOneWidget);

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
    expect(find.text('Слышу…'), findsOneWidget);
  });

  // The recovery sets its hint alongside `isThinking`, so without the hint
  // branch a reconnect looked exactly like an ordinary pause for thought —
  // the one thing the user must not be told, since the whole point of the
  // recovery patch is that a drop used to be indistinguishable from being
  // ignored.
  testWidgets('a hint wins over the phase word it would otherwise contradict', (tester) async {
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
    expect(find.text('Думаю…'), findsNothing);
  });
}
