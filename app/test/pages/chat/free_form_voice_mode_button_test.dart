// The toggle's error text (`free_form_voice_mode_button.dart`). Only the
// message mapping is covered: the widget itself is a gated icon whose taps go
// straight to `CaptureController`, already exercised in
// `test/services/capture/capture_controller_hub_test.dart`.
import 'package:flutter_test/flutter_test.dart';

import 'package:omi/pages/chat/widgets/free_form_voice_mode_button.dart';
import 'package:omi/services/mic/mic_arbiter.dart';

void main() {
  group('freeFormVoiceModeStartErrorMessage', () {
    // The reachable case: the phone is recording a conversation, which holds
    // the one native recorder the hub also captures through
    // (`arbitratedPhoneMicHandles`). Nothing is broken and there is something
    // the user can actually do about it.
    test('a mic held by conversation capture says so, and what to do', () {
      final message = freeFormVoiceModeStartErrorMessage(MicBusyError(kConversationMicOwner));

      expect(message, contains('записью разговора'));
      expect(message, isNot(contains('Bad state')));
    });

    test('a mic held by anyone else still names the holder', () {
      final message = freeFormVoiceModeStartErrorMessage(MicBusyError('mic'));

      expect(message, contains('mic'));
    });

    test('anything else keeps the underlying error visible', () {
      final message = freeFormVoiceModeStartErrorMessage(StateError('token mint failed'));

      expect(message, contains('token mint failed'));
    });
  });
}
