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
    late int expiringCalls;
    late HubControllerEvents events;

    setUp(() {
      applied = [];
      disconnectCalls = 0;
      expiringCalls = 0;
      events = freeFormModeProjectionEvents(
        applyProjection: (p) => applied.add(p),
        onDisconnected: (_) => disconnectCalls += 1,
        onSocketExpiring: () => expiringCalls += 1,
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

    test('onUserSpeechState(true) projects listening AND hearing-user', () {
      events.onUserSpeechState!(true);

      expect(applied.single.isListening, isTrue);
      expect(applied.single.isHearingUser, isTrue);
      expect(applied.single.isResponseActive, isFalse);
    });

    test('onUserSpeechState(false) projects thinking — the user stopped, the reply has not started', () {
      events.onUserSpeechState!(false);

      expect(applied.single.isThinking, isTrue);
      expect(applied.single.isListening, isFalse);
      expect(applied.single.isHearingUser, isFalse);
    });

    // The regression this pair guards: a transcript lands in the same frame
    // as the end-of-utterance verdict (measured live, 23.08), so projecting
    // it would overwrite "Думаю…" with "Слушаю…" every single turn — and the
    // gap it covers is exactly where `ask_claude` spends its silent seconds.
    test('a transcript arriving after the end-of-utterance verdict does not drag the state back to listening', () {
      events.onUserSpeechState!(false);
      events.onInputTranscript!('привет', true, null);

      expect(applied, hasLength(1));
      expect(applied.single.isThinking, isTrue);
    });

    test('onInputTranscript projects nothing on its own', () {
      events.onInputTranscript!('hello', false, null);
      events.onInputTranscript!('', true, null);

      expect(applied, isEmpty);
    });

    test('a full free-form turn walks listening -> hearing -> thinking -> speaking -> listening', () {
      events.onConnected!('sess-1');
      events.onUserSpeechState!(true);
      events.onUserSpeechState!(false);
      events.onSpeakingStart!();
      events.onSpeakingEnd!();

      expect(
        applied.map((p) => (p.isListening, p.isHearingUser, p.isThinking, p.isResponseActive)),
        [
          (true, false, false, false), // connected: mic open, nothing heard yet
          (true, true, false, false), // server VAD hears the user
          (false, false, true, false), // user stopped; reply not started
          (false, false, false, true), // assistant audible
          (true, false, false, false), // player drained: back to listening
        ],
      );
    });

    test('onError fires onDisconnected, not applyProjection', () {
      events.onError!(const HubControllerError(reason: 'boom', retryable: false, aliveForMs: 0));

      expect(disconnectCalls, 1);
      expect(applied, isEmpty);
    });

    test('goAway asks for a rebuild without touching the on-screen state', () {
      // The user is mid-conversation and the rebuild is meant to be
      // invisible: showing "reconnecting" for a socket that still works
      // would be a worse lie than saying nothing.
      events.onGoAway!(const Duration(seconds: 50));

      expect(expiringCalls, 1);
      expect(disconnectCalls, 0);
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
