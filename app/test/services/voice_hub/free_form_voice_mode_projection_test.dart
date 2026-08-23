// Tests for `free_form_voice_mode_projection.dart` — a pure event->projection
// mapping, so this stays a hermetic unit test with no HubController/session
// fakes needed: `freeFormModeProjectionEvents` builds a `HubControllerEvents`
// and this file just invokes its callbacks directly.
import 'package:flutter_test/flutter_test.dart';

import 'package:omi/services/voice_hub/free_form_voice_mode_projection.dart';
import 'package:omi/services/voice_hub/hub_controller.dart';
import 'package:omi/services/voice_hub/voice_turn_machine.dart' show VoiceTurnUiProjection, idleVoiceTurnProjection;

void main() {
  group('freeFormModeProjectionEvents', () {
    late List<VoiceTurnUiProjection> applied;
    late int disconnectCalls;
    late HubControllerEvents events;

    setUp(() {
      applied = [];
      disconnectCalls = 0;
      events = freeFormModeProjectionEvents(
        applyProjection: (p) => applied.add(p),
        onDisconnected: () => disconnectCalls += 1,
      );
    });

    test('onConnected projects listening', () {
      events.onConnected!('sess-1');

      expect(applied, hasLength(1));
      expect(applied.single.isListening, isTrue);
      expect(applied.single.isResponseActive, isFalse);
    });

    test('onSpeakingStart projects response-active (not listening)', () {
      events.onSpeakingStart!();

      expect(applied.single.isResponseActive, isTrue);
      expect(applied.single.isListening, isFalse);
    });

    test('onSpeakingEnd projects back to listening', () {
      events.onSpeakingStart!();
      events.onSpeakingEnd!();

      expect(applied.last.isListening, isTrue);
      expect(applied.last.isResponseActive, isFalse);
    });

    test('onInputTranscript with non-empty text projects listening', () {
      events.onInputTranscript!('hello', false, null);

      expect(applied.single.isListening, isTrue);
    });

    test('onInputTranscript with empty text is a no-op', () {
      events.onInputTranscript!('', true, null);

      expect(applied, isEmpty);
    });

    test('onError fires onDisconnected, not applyProjection', () {
      events.onError!(const HubControllerError(reason: 'boom', retryable: false, aliveForMs: 0));

      expect(disconnectCalls, 1);
      expect(applied, isEmpty);
    });

    test('none of the projected states ever equal idle', () {
      events.onConnected!('sess-1');
      events.onSpeakingStart!();
      events.onSpeakingEnd!();

      for (final p in applied) {
        expect(p, isNot(equals(idleVoiceTurnProjection)));
      }
    });
  });
}
