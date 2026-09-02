// A 1:1-in-spirit port of the desktop (Electron/TS) test suite at
// `desktop/windows/src/renderer/src/lib/voice/hub/geminiHubSession.test.ts`.
// Test names/groupings are kept close to upstream where they apply.
//
// The upstream suite's tool-catalog test against a SECOND provider lane
// (`OpenAiHubSession`, asserting the sanitizer doesn't leak cross-lane) is
// NOT ported: design doc §3, there is no OpenAI lane in this port at all.
// The catalog-wiring tests themselves (empty + non-empty, sanitized
// `parameters`) ARE ported below, now that `tools` is a real seam
// (lane5.md §"ГЛАВНЫЙ ПРИОРИТЕТ 22.08" step 3) — `gemini_tool_schema_test.dart`
// covers `sanitizeGeminiToolSchema` itself in isolation.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:omi/services/voice_hub/gemini_hub_session.dart';
import 'package:omi/services/voice_hub/hub_session.dart';
import 'package:omi/services/voice_hub/voice_turn_machine.dart' show VoiceResponseId, VoiceTurnId;

// ---- fixtures --------------------------------------------------------------

class _FakeVoicePlayer implements VoicePlayer {
  final List<Uint8List> enqueued = [];
  int clearCount = 0;
  int flushCount = 0;
  int closeCount = 0;

  @override
  void enqueuePcm16(Uint8List bytes) => enqueued.add(bytes);
  @override
  void clear() => clearCount++;
  @override
  void flush() => flushCount++;
  @override
  void close() => closeCount++;
}

class _RecordingHubSocket implements HubSocket {
  int _readyState = 0; // CONNECTING
  final List<String> sent = [];
  bool closed = false;

  @override
  void send(String data) => sent.add(data);

  @override
  void close() {
    _readyState = 2;
    closed = true;
  }

  @override
  int? get readyState => _readyState;

  void setReadyState(int state) => _readyState = state;

  List<Map<String, dynamic>> frames() => sent.map((s) => jsonDecode(s) as Map<String, dynamic>).toList();

  /// The realtimeInput sub-frame kind (activityStart / activityEnd / audio),
  /// mirroring the TS harness's `riKinds()`.
  List<String> riKinds() => frames()
      .map((f) => f['realtimeInput'] as Map<String, dynamic>?)
      .whereType<Map<String, dynamic>>()
      .map((r) => r.keys.first)
      .toList();
}

class _RecordingSocketFactory {
  _RecordingHubSocket? socket;
  HubSocketOpenSpec? spec;

  HubSocket factory(HubSocketOpenSpec spec) {
    this.spec = spec;
    return socket = _RecordingHubSocket();
  }

  void open() {
    socket?.setReadyState(webSocketOpenReadyState);
    spec?.onOpen();
  }

  void message(String data) => spec?.onMessage(data);
}

class _FakeHubClock implements HubClock {
  final List<_FakeTimer> _timers = [];

  @override
  Object setTimer(Duration duration, void Function() fire) {
    final timer = _FakeTimer(duration: duration, fire: fire);
    _timers.add(timer);
    return timer;
  }

  @override
  void clearTimer(Object handle) => _timers.remove(handle);

  void fireDuration(Duration duration) {
    final timer = _timers.firstWhere(
      (t) => t.duration == duration,
      orElse: () => throw StateError('no pending timer for $duration'),
    );
    _timers.remove(timer);
    timer.fire();
  }
}

class _FakeTimer {
  final Duration duration;
  final void Function() fire;
  _FakeTimer({required this.duration, required this.fire});
}

class _Harness {
  final GeminiHubSession session;
  final _RecordingSocketFactory socketFactory;
  final _FakeVoicePlayer player;
  final List<({String message, bool retryable, int? closeCode})> errors = [];
  final List<String> connected = [];
  final List<bool> speechStates = [];

  /// Every value the session offered via `onResumptionHandle`, nulls
  /// included — the nulls are the safety half of the contract.
  final List<String?> resumptionHandles = [];

  /// Every `goAway` warning, with the deadline the server named (null when
  /// it named none).
  final List<Duration?> goAways = [];

  final List<String> assistantTexts = [];

  /// Every tool call the session surfaced, transcript attachment included.
  final List<HubToolCallRequest> toolRequests = [];

  _Harness._(this.session, this.socketFactory, this.player);

  factory _Harness({
    HubClock? clock,
    bool freeFormMode = false,
    List<VoiceToolDeclaration> tools = const [],
    String? resumptionHandle,
  }) {
    final socketFactory = _RecordingSocketFactory();
    final player = _FakeVoicePlayer();
    late final _Harness h;
    final session = GeminiHubSession(
      token: 'auth_tokens/x',
      instructions: 'INSTR',
      socketFactory: socketFactory.factory,
      playerFactory: (spec) async => player,
      clock: clock,
      mintSessionId: () => 'sess-1',
      freeFormMode: freeFormMode,
      tools: tools,
      resumptionHandle: resumptionHandle,
      events: HubSessionEvents(
        onConnected: (sid) => h.connected.add(sid),
        onUserSpeechState: (isSpeaking) => h.speechStates.add(isSpeaking),
        onResumptionHandle: (handle) => h.resumptionHandles.add(handle),
        onGoAway: (timeLeft) => h.goAways.add(timeLeft),
        onError: (message, retryable, closeCode) =>
            h.errors.add((message: message, retryable: retryable, closeCode: closeCode)),
        onAssistantText: (text, isFinal, identity) {
          if (text.isNotEmpty) h.assistantTexts.add(text);
        },
        onToolRequest: (call, identity) => h.toolRequests.add(call),
      ),
    );
    h = _Harness._(session, socketFactory, player);
    return h;
  }

  _RecordingHubSocket get socket {
    final s = socketFactory.socket;
    if (s == null) throw StateError('socket not created');
    return s;
  }
}

/// Warms the session up to (but not including) the point of asserting on the
/// setup frame: creates the socket without opening it.
Future<void> _armConnection(_Harness h) async {
  unawaited(h.session.ensureWarm().catchError((_) {}));
  // `_openConnection` awaits the player factory before creating the socket.
  await Future<void>.value();
  await Future<void>.value();
}

Future<void> _connect(_Harness h) async {
  final warm = h.session.ensureWarm();
  await Future<void>.value();
  await Future<void>.value();
  h.socketFactory.open();
  h.socketFactory.message(jsonEncode({'setupComplete': <String, dynamic>{}}));
  await warm;
  h.socket.sent.clear();
}

Map<String, dynamic> _serverContent(Map<String, dynamic> body) => {'serverContent': body};

/// [tag] is base64-encoded here (unlike the TS harness, which stubs out
/// `base64ToBytes` entirely) because `playAudio` runs the real
/// `base64Decode` in this port.
Map<String, dynamic> _audioPart(String tag) => {
      'modelTurn': {
        'parts': [
          {
            'inlineData': {'mimeType': 'audio/pcm', 'data': base64Encode(utf8.encode(tag))}
          }
        ]
      }
    };

const VoiceTurnId tid = 't1';
const VoiceResponseId rid = 'r1';

void main() {
  group('GeminiHubSession — warm config', () {
    test('warms with automaticActivityDetection.disabled (manual VAD, PTT owns turns)', () async {
      final h = _Harness();
      await _armConnection(h);
      h.socketFactory.open();
      final setup = h.socket.frames()[0]['setup'] as Map<String, dynamic>;
      final ric = setup['realtimeInputConfig'] as Map<String, dynamic>;
      final aad = ric['automaticActivityDetection'] as Map<String, dynamic>;
      expect(aad['disabled'], isTrue);
      expect((setup['generationConfig'] as Map<String, dynamic>)['responseModalities'], ['AUDIO']);
      // No tool passed to this harness ⇒ an empty (but faithful)
      // functionDeclarations frame.
      expect(setup['tools'], [
        {'functionDeclarations': <Map<String, dynamic>>[]}
      ]);
      h.socketFactory.message(jsonEncode({'setupComplete': <String, dynamic>{}}));
      await Future<void>.value();
      expect(h.connected, ['sess-1']);
    });

    // 24.08, после перехода на 2.5-native-audio: thinking выключен в сетапе,
    // а thought-части (внутренний монолог модели, английские саммари) не
    // должны попадать в транскрипт и чат даже если модель их всё же прислала.
    test('setup несёт thinkingBudget=0; thought-части не доходят до onAssistantText', () async {
      final h = _Harness(freeFormMode: true);
      await _armConnection(h);
      h.socketFactory.open();
      final setup = h.socket.frames()[0]['setup'] as Map<String, dynamic>;
      final gen = setup['generationConfig'] as Map<String, dynamic>;
      expect((gen['thinkingConfig'] as Map<String, dynamic>)['thinkingBudget'], 0);

      h.socketFactory.message(jsonEncode({'setupComplete': <String, dynamic>{}}));
      await Future<void>.value();
      h.session.beginTurn();
      h.socketFactory.message(jsonEncode(_serverContent({
        'modelTurn': {
          'parts': [
            {'text': 'Testing Response Generation…', 'thought': true},
            {'text': 'Слышу тебя.'},
          ]
        }
      })));

      expect(h.assistantTexts, ['Слышу тебя.'], reason: 'thought-часть — не сказанное');
    });

    test('projects an injected tool catalog into functionDeclarations, schema sanitized', () async {
      final h = _Harness(tools: const [
        VoiceToolDeclaration(
          name: 'ask_claude',
          description: 'ask the smart model',
          parameters: {
            'type': 'object',
            'properties': {
              'question': {'type': 'string', 'additionalProperties': false},
            },
            'required': ['question'],
            'additionalProperties': false, // must be stripped — Gemini rejects it
          },
        ),
      ]);
      await _armConnection(h);
      h.socketFactory.open();
      final setup = h.socket.frames()[0]['setup'] as Map<String, dynamic>;
      expect(setup['tools'], [
        {
          'functionDeclarations': [
            {
              'name': 'ask_claude',
              'description': 'ask the smart model',
              'parameters': {
                'type': 'object',
                'properties': {
                  'question': {'type': 'string'}, // additionalProperties stripped
                },
                'required': ['question'],
              },
            },
          ],
        },
      ]);
    });
  });

  group('GeminiHubSession — one turn', () {
    test('activityStart → audio → activityEnd, in that exact order', () async {
      final h = _Harness();
      await _connect(h);
      h.session.beginTurn(const HubBeginTurnOptions(turnId: tid, responseId: rid));
      h.session.appendAudio(Uint8List.fromList([1, 2]));
      h.session.commitTurn();
      expect(h.socket.riKinds(), ['activityStart', 'audio', 'activityEnd']);
      final audioFrame = h.socket.frames()[1]['realtimeInput'] as Map<String, dynamic>;
      expect((audioFrame['audio'] as Map<String, dynamic>)['mimeType'], 'audio/pcm;rate=16000');
    });
  });

  group('GeminiHubSession — barge-in (fresh-session strategy, no in-session cancel)', () {
    test('gates trailing audio off on interrupt and starts a fresh window without a cancel frame', () async {
      final h = _Harness();
      await _connect(h);
      h.session.beginTurn(const HubBeginTurnOptions(turnId: tid, responseId: rid));
      h.session.commitTurn(); // activityEnd → responsePending=true
      // Reply audio plays while pending.
      h.socketFactory.message(jsonEncode(_serverContent(_audioPart('g1'))));
      expect(h.player.enqueued.length, 1);
      // Server confirms interrupt → gate closes, queued playback flushed.
      h.socketFactory.message(jsonEncode(_serverContent({'interrupted': true})));
      expect(h.player.clearCount, 1);
      // Trailing audio for the dead generation is dropped.
      h.socketFactory.message(jsonEncode(_serverContent(_audioPart('g1-trailing'))));
      expect(h.player.enqueued.length, 1);
      // The barge-in turn opens a FRESH window (activityStart) — Gemini has
      // no in-session response cancel, so there is no cancel frame on the
      // wire.
      h.socket.sent.clear();
      h.session.beginTurn(const HubBeginTurnOptions(
        turnId: 't2',
        responseId: 'r2',
        interrupting: true,
      ));
      expect(h.socket.riKinds(), ['activityStart']);
      expect(jsonEncode(h.socket.frames()), isNot(contains('cancel')));
    });

    test('abandon (cancelTurn) closes the open activity window with activityEnd', () async {
      final h = _Harness();
      await _connect(h);
      h.session.beginTurn(const HubBeginTurnOptions(turnId: tid, responseId: rid));
      h.socket.sent.clear();
      h.session.cancelTurn();
      expect(h.socket.riKinds(), ['activityEnd']);
    });
  });

  group('GeminiHubSession — idle release (D4) + re-warm', () {
    test('tears the socket down after the idle timer, then ensureWarm re-establishes', () {
      fakeAsync((async) {
        final h = _Harness(clock: const DefaultHubClock());
        unawaited(h.session.ensureWarm());
        async.elapse(const Duration(milliseconds: 1));
        h.socketFactory.open();
        h.socketFactory.message(jsonEncode({'setupComplete': <String, dynamic>{}}));
        expect(h.session.isWarm(), isTrue);

        final first = h.socket;
        async.elapse(hubIdleReleaseDuration + const Duration(seconds: 1));
        expect(first.closed, isTrue);
        expect(h.session.isWarm(), isFalse);

        unawaited(h.session.ensureWarm());
        async.elapse(const Duration(milliseconds: 1));
        final second = h.socket;
        expect(second, isNot(same(first)));
        second.setReadyState(webSocketOpenReadyState);
        h.socketFactory.spec!.onOpen();
        h.socketFactory.spec!.onMessage(jsonEncode({'setupComplete': <String, dynamic>{}}));
        expect(h.session.isWarm(), isTrue);
      });
    });
  });

  group('GeminiHubSession — cold press (warm-wait buffer)', () {
    test('buffers activityStart/PCM/commit before ready, flushes in order on connect', () async {
      final h = _Harness();
      final warm = h.session.ensureWarm();
      await Future<void>.value();
      await Future<void>.value();
      // Press before the socket is ready.
      h.session.beginTurn(const HubBeginTurnOptions(turnId: tid, responseId: rid));
      h.session.appendAudio(Uint8List.fromList([7, 7]));
      h.session.commitTurn();
      h.socketFactory.open();
      // Only the setup frame so far; no per-turn frames until ready.
      expect(h.socket.riKinds(), isEmpty);
      h.socketFactory.message(jsonEncode({'setupComplete': <String, dynamic>{}}));
      await warm;
      // Deferred activityStart, then buffered audio, then the deferred commit.
      expect(h.socket.riKinds(), ['activityStart', 'audio', 'activityEnd']);
    });
  });

  group('GeminiHubSession — warm timeout', () {
    test('fails fast when the socket opens but the provider never signals readiness', () {
      fakeAsync((async) {
        final clock = _FakeHubClock();
        final h = _Harness(clock: clock);
        unawaited(h.session.ensureWarm().catchError((_) {}));
        async.elapse(const Duration(milliseconds: 1));
        h.socketFactory.open(); // OPEN + setup frame sent, but no setupComplete ever arrives
        expect(h.session.isWarm(), isFalse);

        clock.fireDuration(hubWarmTimeoutDuration);
        expect(h.session.isWarm(), isFalse);
        expect(h.errors, [(message: 'hub warm timeout', retryable: true, closeCode: null)]);
      });
    });
  });

  group('GeminiHubSession — freeFormMode (server VAD)', () {
    test('setup frame carries automaticActivityDetection.disabled=false', () async {
      final h = _Harness(freeFormMode: true);
      await _armConnection(h);
      h.socketFactory.open();
      final setup = h.socket.frames()[0]['setup'] as Map<String, dynamic>;
      final ric = setup['realtimeInputConfig'] as Map<String, dynamic>;
      final aad = ric['automaticActivityDetection'] as Map<String, dynamic>;
      expect(aad['disabled'], isFalse);
    });

    test('beginTurn() opens continuous input with no activityStart frame; audio flows immediately', () async {
      final h = _Harness(freeFormMode: true);
      await _connect(h);
      h.session.beginTurn(const HubBeginTurnOptions(turnId: tid, responseId: rid));
      expect(h.socket.riKinds(), isEmpty); // no activityStart on the wire
      h.session.appendAudio(Uint8List.fromList([1, 2]));
      expect(h.socket.riKinds(), ['audio']);
    });

    test('a second beginTurn() while already streaming is a no-op', () async {
      final h = _Harness(freeFormMode: true);
      await _connect(h);
      h.session.beginTurn(const HubBeginTurnOptions(turnId: tid, responseId: rid));
      h.session.appendAudio(Uint8List.fromList([1]));
      h.session.beginTurn(const HubBeginTurnOptions(turnId: 't2', responseId: 'r2'));
      h.session.appendAudio(Uint8List.fromList([2]));
      expect(h.socket.riKinds(), ['audio', 'audio']); // still just audio, streaming never toggled off
    });

    // Wire shape + timing measured against live Gemini 23.08 (design doc §9):
    // SPEECH lands 0.24s after speech onset, NON_SPEECH 1.2s after it stops,
    // and neither repeats during idle silence.
    test('serverContent.speechState surfaces as onUserSpeechState', () async {
      final h = _Harness(freeFormMode: true);
      await _connect(h);

      h.socketFactory.message(jsonEncode(_serverContent({'speechState': 'SPEECH'})));
      h.socketFactory.message(jsonEncode(_serverContent({'speechState': 'NON_SPEECH'})));

      expect(h.speechStates, [true, false]);
    });

    test('an unknown speechState value is ignored, not guessed at as "stopped talking"', () async {
      final h = _Harness(freeFormMode: true);
      await _connect(h);

      h.socketFactory.message(jsonEncode(_serverContent({'speechState': 'SPEECH_STATE_UNSPECIFIED'})));
      h.socketFactory.message(jsonEncode(_serverContent({'modelTurn': <String, dynamic>{}})));

      expect(h.speechStates, isEmpty);
    });

    test('speechState riding along with a transcript emits both, in wire order', () async {
      final h = _Harness(freeFormMode: true);
      var transcripts = <String>[];
      final session = GeminiHubSession(
        token: 'auth_tokens/x',
        instructions: 'INSTR',
        socketFactory: h.socketFactory.factory,
        playerFactory: (spec) async => h.player,
        mintSessionId: () => 'sess-1',
        freeFormMode: true,
        events: HubSessionEvents(
          onUserSpeechState: (isSpeaking) => h.speechStates.add(isSpeaking),
          onInputTranscript: (text, isFinal, _) => transcripts.add(text),
        ),
      );
      final warm = session.ensureWarm();
      await Future<void>.value();
      await Future<void>.value();
      h.socketFactory.open();
      h.socketFactory.message(jsonEncode({'setupComplete': <String, dynamic>{}}));
      await warm;

      // The live wire delivers the end-of-utterance verdict and the final
      // transcript in the same frame, 10ms apart from the reply's first audio.
      h.socketFactory.message(jsonEncode(_serverContent({
        'speechState': 'NON_SPEECH',
        'inputTranscription': {'text': 'привет'},
      })));

      expect(h.speechStates, [false]);
      expect(transcripts, ['привет']);
    });

    test('commitTurn() is a no-op — no activityEnd frame, server ends the turn on its own', () async {
      final h = _Harness(freeFormMode: true);
      await _connect(h);
      h.session.beginTurn(const HubBeginTurnOptions(turnId: tid, responseId: rid));
      h.session.commitTurn();
      expect(h.socket.riKinds(), isEmpty);
    });

    test('turnComplete plays audio, fires onTurnDone, and keeps accepting the next utterance without a new beginTurn()',
        () async {
      final h = _Harness(freeFormMode: true);
      var turnDoneCount = 0;
      final session = GeminiHubSession(
        token: 'auth_tokens/x',
        instructions: 'INSTR',
        socketFactory: h.socketFactory.factory,
        playerFactory: (spec) async => h.player,
        freeFormMode: true,
        events: HubSessionEvents(onTurnDone: (_) => turnDoneCount++),
      );
      final warm = session.ensureWarm();
      await Future<void>.value();
      await Future<void>.value();
      h.socketFactory.open();
      h.socketFactory.message(jsonEncode({'setupComplete': <String, dynamic>{}}));
      await warm;
      session.beginTurn(const HubBeginTurnOptions(turnId: tid, responseId: rid));

      // First utterance completes.
      h.socketFactory.message(jsonEncode(_serverContent(_audioPart('u1'))));
      h.socketFactory.message(jsonEncode(_serverContent({'turnComplete': true})));
      expect(h.player.enqueued.length, 1);
      expect(turnDoneCount, 1);

      // A second utterance arrives on the SAME session, with no further
      // beginTurn() call — the driver never calls it again in free-form
      // mode.
      h.socketFactory.message(jsonEncode(_serverContent(_audioPart('u2'))));
      h.socketFactory.message(jsonEncode(_serverContent({'turnComplete': true})));
      expect(h.player.enqueued.length, 2);
      expect(turnDoneCount, 2);
    });

    test('interrupted clears playback but leaves streaming on (no fresh beginTurn needed)', () async {
      final h = _Harness(freeFormMode: true);
      await _connect(h);
      h.session.beginTurn(const HubBeginTurnOptions(turnId: tid, responseId: rid));
      h.socketFactory.message(jsonEncode(_serverContent(_audioPart('g1'))));
      expect(h.player.enqueued.length, 1);
      h.socketFactory.message(jsonEncode(_serverContent({'interrupted': true})));
      expect(h.player.clearCount, 1);
      // Streaming stayed on: a new utterance's audio still plays without
      // another beginTurn() call.
      h.socketFactory.message(jsonEncode(_serverContent(_audioPart('g2'))));
      expect(h.player.enqueued.length, 2);
    });

    test(
        'cancelTurn() switches free-form mode off with no activityEnd frame; input is rejected until beginTurn() again',
        () async {
      final h = _Harness(freeFormMode: true);
      await _connect(h);
      h.session.beginTurn(const HubBeginTurnOptions(turnId: tid, responseId: rid));
      h.session.cancelTurn();
      expect(h.socket.riKinds(), isEmpty);
      h.session.appendAudio(Uint8List.fromList([9]));
      expect(h.socket.riKinds(), isEmpty); // buffered, not sent — canAcceptInput() is false again
    });
  });

  // Session resumption — every assertion below mirrors a measurement from
  // `marathon/probes/lane5-session-resumption.py` /
  // `marathon/probes/lane5-resumption-bargein.py` (design doc §10), NOT the
  // API docs.
  group('sessionResumption', () {
    Map<String, dynamic> setupOf(_Harness h) => (h.socket.frames().first['setup'] as Map<String, dynamic>);

    Map<String, dynamic> resumptionUpdate(String handle, {bool? resumable}) => {
          'sessionResumptionUpdate': {
            'newHandle': handle,
            if (resumable != null) 'resumable': resumable,
          }
        };

    test('setup frame asks for handles even with nothing to resume (empty map, not absent)', () async {
      final h = _Harness();
      await _armConnection(h);
      h.socketFactory.open();
      expect(setupOf(h)['sessionResumption'], <String, dynamic>{});
    });

    test('a supplied handle rides the setup frame', () async {
      final h = _Harness(resumptionHandle: 'HANDLE-7');
      await _armConnection(h);
      h.socketFactory.open();
      expect(setupOf(h)['sessionResumption'], {'handle': 'HANDLE-7'});
    });

    test('an offered handle reaches the host', () async {
      final h = _Harness();
      await _connect(h);
      h.socketFactory.message(jsonEncode(resumptionUpdate('H1', resumable: true)));
      expect(h.resumptionHandles, ['H1']);
    });

    test('resumable:false is ignored — the previous good handle is kept, not downgraded', () async {
      final h = _Harness();
      await _connect(h);
      h.socketFactory.message(jsonEncode(resumptionUpdate('H1', resumable: true)));
      h.socketFactory.message(jsonEncode(resumptionUpdate('H2', resumable: false)));
      expect(h.resumptionHandles, ['H1']);
    });

    test('a reply starting withdraws the handle (null), and turnComplete re-offers it', () async {
      final h = _Harness(freeFormMode: true);
      await _connect(h);
      h.session.beginTurn(const HubBeginTurnOptions(turnId: tid, responseId: rid));
      h.socketFactory.message(jsonEncode(resumptionUpdate('H1')));
      expect(h.resumptionHandles, ['H1']);
      // The model starts speaking: resuming from here would replay this very
      // reply on the next socket (measured 24.08 — 102 chunks of an
      // abandoned monologue glued in front of the next answer).
      h.socketFactory.message(jsonEncode(_serverContent(_audioPart('a1'))));
      expect(h.resumptionHandles, ['H1', null]);
      // Still speaking — a handle that arrives mid-reply is stored but not offered.
      h.socketFactory.message(jsonEncode(resumptionUpdate('H2')));
      expect(h.resumptionHandles, ['H1', null]);
      h.socketFactory.message(jsonEncode(_serverContent({'turnComplete': true})));
      expect(h.resumptionHandles, ['H1', null, 'H2']);
    });

    test('withdrawal fires once per generation, not once per audio chunk', () async {
      final h = _Harness(freeFormMode: true);
      await _connect(h);
      h.session.beginTurn(const HubBeginTurnOptions(turnId: tid, responseId: rid));
      h.socketFactory.message(jsonEncode(resumptionUpdate('H1')));
      for (var i = 0; i < 5; i++) {
        h.socketFactory.message(jsonEncode(_serverContent(_audioPart('a$i'))));
      }
      expect(h.resumptionHandles, ['H1', null]);
    });

    test('a reply we ignore locally still withdraws the handle — the SERVER is the one replaying it', () async {
      // Manual mode, no committed turn: `_responsePending` is false, so this
      // audio is dropped on the floor locally. The server does not know that,
      // and would replay the generation on resume.
      final h = _Harness();
      await _connect(h);
      h.socketFactory.message(jsonEncode(resumptionUpdate('H1')));
      h.socketFactory.message(jsonEncode(_serverContent(_audioPart('ghost'))));
      expect(h.player.enqueued, isEmpty); // not played...
      expect(h.resumptionHandles, ['H1', null]); // ...but still unsafe to resume
    });

    test('interrupted does not re-offer on its own; its own turnComplete does (no latch)', () async {
      final h = _Harness(freeFormMode: true);
      await _connect(h);
      h.session.beginTurn(const HubBeginTurnOptions(turnId: tid, responseId: rid));
      h.socketFactory.message(jsonEncode(resumptionUpdate('H1')));
      h.socketFactory.message(jsonEncode(_serverContent(_audioPart('a1'))));
      expect(h.resumptionHandles, ['H1', null]);
      h.socketFactory.message(jsonEncode(_serverContent({'interrupted': true})));
      expect(h.resumptionHandles, ['H1', null]);
      // ~0.1s later on the real wire (design doc §9) — this is what unlatches.
      h.socketFactory.message(jsonEncode(_serverContent({'turnComplete': true})));
      expect(h.resumptionHandles, ['H1', null, 'H1']);
    });

    test('a turn deferred on tool results still re-offers the handle at turnComplete', () async {
      final h = _Harness(freeFormMode: true, tools: const [
        VoiceToolDeclaration(name: 'ask_claude', description: 'd', parameters: {'type': 'object'}),
      ]);
      await _connect(h);
      h.session.beginTurn(const HubBeginTurnOptions(turnId: tid, responseId: rid));
      h.socketFactory.message(jsonEncode(resumptionUpdate('H1')));
      h.socketFactory.message(jsonEncode({
        'toolCall': {
          'functionCalls': [
            {'id': 'c1', 'name': 'ask_claude', 'args': <String, dynamic>{}}
          ]
        }
      }));
      h.socketFactory.message(jsonEncode(_serverContent(_audioPart('filler'))));
      expect(h.resumptionHandles, ['H1', null]);
      // turnComplete arrives while a tool call is still pending: the reply
      // bookkeeping defers, but the SERVER closed the generation, so the
      // handle must come back regardless.
      h.socketFactory.message(jsonEncode(_serverContent({'turnComplete': true})));
      expect(h.resumptionHandles, ['H1', null, 'H1']);
    });

    test('no handle is invented when the server never offered one', () async {
      final h = _Harness(freeFormMode: true);
      await _connect(h);
      h.session.beginTurn(const HubBeginTurnOptions(turnId: tid, responseId: rid));
      h.socketFactory.message(jsonEncode(_serverContent(_audioPart('a1'))));
      h.socketFactory.message(jsonEncode(_serverContent({'turnComplete': true})));
      // The withdrawal still fires (safety), but nothing is offered back.
      expect(h.resumptionHandles, [null]);
    });
  });

  // Дословная речь для ask_claude (шапка gemini_hub_session.dart, «Дословная
  // речь для ask_claude»): транскрипт хода прикладывается к tool-call'у, а
  // вызов, обогнавший транскрипт, ждёт его ограниченное время.
  group('verbatim user transcript on tool calls', () {
    const askClaude = [
      VoiceToolDeclaration(name: 'ask_claude', description: 'd', parameters: {'type': 'object'}),
    ];
    Map<String, dynamic> toolCall(String id, [Map<String, dynamic> args = const {'question': 'пересказ'}]) => {
          'toolCall': {
            'functionCalls': [
              {'id': id, 'name': 'ask_claude', 'args': args}
            ]
          }
        };
    Map<String, dynamic> transcript(String text) => _serverContent({
          'inputTranscription': {'text': text}
        });
    const grace = Duration(milliseconds: 700);
    const settle = Duration(milliseconds: 300);

    Future<_Harness> freeForm(_FakeHubClock clock) async {
      final h = _Harness(freeFormMode: true, tools: askClaude, clock: clock);
      await _connect(h);
      h.session.beginTurn(const HubBeginTurnOptions(turnId: tid, responseId: rid));
      return h;
    }

    test('the accumulated transcript of the turn rides the tool call, chunks glued as deltas', () async {
      final clock = _FakeHubClock();
      final h = await freeForm(clock);
      h.socketFactory.message(jsonEncode(transcript('какие у меня ')));
      h.socketFactory.message(jsonEncode(transcript('планы на завтра')));
      h.socketFactory.message(jsonEncode(toolCall('c1')));

      expect(h.toolRequests, hasLength(1));
      expect(h.toolRequests.single.callId, 'c1');
      expect(h.toolRequests.single.userTranscript, 'какие у меня планы на завтра');
      // The model's own argument still travels untouched.
      expect(jsonDecode(h.toolRequests.single.argumentsJson), {'question': 'пересказ'});
    });

    test('segments separated by a pause (new SPEECH verdict) are joined with a space', () async {
      final clock = _FakeHubClock();
      final h = await freeForm(clock);
      h.socketFactory.message(jsonEncode(_serverContent({'speechState': 'SPEECH'})));
      h.socketFactory.message(jsonEncode(transcript('первая часть')));
      h.socketFactory.message(jsonEncode(_serverContent({'speechState': 'NON_SPEECH'})));
      h.socketFactory.message(jsonEncode(_serverContent({'speechState': 'SPEECH'})));
      h.socketFactory.message(jsonEncode(transcript('вторая часть')));
      h.socketFactory.message(jsonEncode(toolCall('c1')));

      expect(h.toolRequests.single.userTranscript, 'первая часть вторая часть');
    });

    test('a tool call that beats the transcript waits for it, then settles for the tail', () async {
      final clock = _FakeHubClock();
      final h = await freeForm(clock);
      h.socketFactory.message(jsonEncode(toolCall('c1')));
      expect(h.toolRequests, isEmpty, reason: 'deferred: nothing to attach yet');

      h.socketFactory.message(jsonEncode(transcript('что я ел ')));
      expect(h.toolRequests, isEmpty, reason: 'first chunk landed — give the tail a moment');
      h.socketFactory.message(jsonEncode(transcript('сегодня на обед')));
      clock.fireDuration(settle);

      expect(h.toolRequests, hasLength(1));
      expect(h.toolRequests.single.callId, 'c1');
      expect(h.toolRequests.single.userTranscript, 'что я ел сегодня на обед');
      // The grace timer was replaced by the settle timer, not left to fire twice.
      expect(() => clock.fireDuration(grace), throwsStateError);
    });

    test('a transcript that never comes: the call goes out after the grace window with no transcript', () async {
      final clock = _FakeHubClock();
      final h = await freeForm(clock);
      h.socketFactory.message(jsonEncode(toolCall('c1')));
      expect(h.toolRequests, isEmpty);
      clock.fireDuration(grace);

      expect(h.toolRequests, hasLength(1));
      expect(h.toolRequests.single.userTranscript, isNull);
      expect(jsonDecode(h.toolRequests.single.argumentsJson), {'question': 'пересказ'});
    });

    test('turnComplete while a call is deferred still waits for the tool result (pending id is set)', () async {
      final clock = _FakeHubClock();
      final socketFactory = _RecordingSocketFactory();
      final requests = <HubToolCallRequest>[];
      var turnDone = 0;
      final session = GeminiHubSession(
        token: 'auth_tokens/x',
        instructions: 'INSTR',
        socketFactory: socketFactory.factory,
        playerFactory: (spec) async => _FakeVoicePlayer(),
        clock: clock,
        freeFormMode: true,
        tools: askClaude,
        events: HubSessionEvents(
          onToolRequest: (call, _) => requests.add(call),
          onTurnDone: (_) => turnDone++,
        ),
      );
      final warm = session.ensureWarm();
      await Future<void>.value();
      await Future<void>.value();
      socketFactory.open();
      socketFactory.message(jsonEncode({'setupComplete': <String, dynamic>{}}));
      await warm;
      session.beginTurn(const HubBeginTurnOptions(turnId: tid, responseId: rid));

      socketFactory.message(jsonEncode(toolCall('c1')));
      socketFactory.message(jsonEncode(_serverContent({'turnComplete': true})));
      expect(turnDone, 0, reason: 'the deferred call is already pending — the turn must not close under it');
      clock.fireDuration(grace);
      expect(requests, hasLength(1));
      session.sendToolResult('c1', 'ask_claude', 'ok');
      socketFactory.message(jsonEncode(_serverContent({'turnComplete': true})));
      expect(turnDone, 1);
    });

    test('a finished assistant reply resets the buffer — the next call does not inherit old speech', () async {
      final clock = _FakeHubClock();
      final h = await freeForm(clock);
      h.socketFactory.message(jsonEncode(transcript('старый вопрос')));
      h.socketFactory.message(jsonEncode(_serverContent(_audioPart('a1'))));
      h.socketFactory.message(jsonEncode(_serverContent({'turnComplete': true})));

      h.socketFactory.message(jsonEncode(toolCall('c1')));
      expect(h.toolRequests, isEmpty, reason: 'buffer is empty again, so the call waits');
      h.socketFactory.message(jsonEncode(transcript('новый вопрос')));
      clock.fireDuration(settle);
      expect(h.toolRequests.single.userTranscript, 'новый вопрос');
    });

    test('emitting a call consumes the buffer: a later call in the same turn starts from scratch', () async {
      final clock = _FakeHubClock();
      final h = await freeForm(clock);
      h.socketFactory.message(jsonEncode(transcript('вопрос раз')));
      h.socketFactory.message(jsonEncode(toolCall('c1')));
      h.socketFactory.message(jsonEncode(toolCall('c2')));
      clock.fireDuration(grace);

      expect(h.toolRequests.map((r) => r.callId), ['c1', 'c2']);
      expect(h.toolRequests[0].userTranscript, 'вопрос раз');
      expect(h.toolRequests[1].userTranscript, isNull);
    });

    test('interrupted drops the old speech and any deferred call', () async {
      final clock = _FakeHubClock();
      final h = await freeForm(clock);
      h.socketFactory.message(jsonEncode(transcript('перебитая речь')));
      h.socketFactory.message(jsonEncode(_serverContent({'interrupted': true})));
      h.socketFactory.message(jsonEncode(toolCall('c1')));
      expect(h.toolRequests, isEmpty);
      h.socketFactory.message(jsonEncode(_serverContent({'interrupted': true})));
      // The interrupted call was cancelled, not emitted — and its grace timer
      // went with it, so there is nothing left to fire.
      expect(h.toolRequests, isEmpty);
      expect(() => clock.fireDuration(grace), throwsStateError);
      // A fresh utterance after the barge-in starts from a clean buffer.
      h.socketFactory.message(jsonEncode(transcript('новая реплика')));
      h.socketFactory.message(jsonEncode(toolCall('c2')));
      expect(h.toolRequests.single.userTranscript, 'новая реплика');
    });

    test('manual mode: a new press starts a fresh buffer; the committed turn\'s transcript rides the call', () async {
      final clock = _FakeHubClock();
      final h = _Harness(tools: askClaude, clock: clock);
      await _connect(h);
      h.session.beginTurn(const HubBeginTurnOptions(turnId: tid, responseId: rid));
      h.socketFactory.message(jsonEncode(transcript('первое нажатие')));
      h.session.commitTurn();
      h.socketFactory.message(jsonEncode(_serverContent({'turnComplete': true})));

      h.session.beginTurn(const HubBeginTurnOptions(turnId: 't2', responseId: 'r2'));
      h.session.commitTurn();
      h.socketFactory.message(jsonEncode(transcript('второе нажатие')));
      h.socketFactory.message(jsonEncode(toolCall('c1')));

      expect(h.toolRequests.single.userTranscript, 'второе нажатие');
    });

    test('transcriptGrace: zero disables the wait — the call goes out at once without a transcript', () async {
      final clock = _FakeHubClock();
      final socketFactory = _RecordingSocketFactory();
      final requests = <HubToolCallRequest>[];
      final session = GeminiHubSession(
        token: 'auth_tokens/x',
        instructions: 'INSTR',
        socketFactory: socketFactory.factory,
        playerFactory: (spec) async => _FakeVoicePlayer(),
        clock: clock,
        freeFormMode: true,
        tools: askClaude,
        transcriptGrace: Duration.zero,
        events: HubSessionEvents(onToolRequest: (call, _) => requests.add(call)),
      );
      final warm = session.ensureWarm();
      await Future<void>.value();
      await Future<void>.value();
      socketFactory.open();
      socketFactory.message(jsonEncode({'setupComplete': <String, dynamic>{}}));
      await warm;
      session.beginTurn(const HubBeginTurnOptions(turnId: tid, responseId: rid));

      socketFactory.message(jsonEncode(toolCall('c1')));
      expect(requests, hasLength(1));
      expect(requests.single.userTranscript, isNull);
    });
  });

  // goAway — the server's warning that it is about to hang up. Measured
  // 24.08 (`marathon/probes/lane5-goaway.py`, design doc §11): a socket
  // carrying no traffic is closed outright at ~151s with 1008 and NO
  // warning, so this path only ever runs for a socket in use. The parsing
  // is deliberately shape-tolerant: the warning is worth more than the
  // deadline, and losing the whole frame to an unexpected encoding of a
  // protobuf Duration would be the expensive half of the trade.
  group('goAway', () {
    test('a named deadline reaches the host as a Duration', () async {
      final h = _Harness();
      await _connect(h);
      h.socketFactory.message(jsonEncode({
        'goAway': {'timeLeft': '10s'}
      }));
      expect(h.goAways, [const Duration(seconds: 10)]);
    });

    test('fractional seconds survive (protobuf writes "1.5s", not milliseconds)', () async {
      final h = _Harness();
      await _connect(h);
      h.socketFactory.message(jsonEncode({
        'goAway': {'timeLeft': '1.5s'}
      }));
      expect(h.goAways, [const Duration(milliseconds: 1500)]);
    });

    test('the object form of a Duration is understood too', () async {
      final h = _Harness();
      await _connect(h);
      h.socketFactory.message(jsonEncode({
        'goAway': {
          'timeLeft': {'seconds': 3, 'nanos': 500000000}
        }
      }));
      expect(h.goAways, [const Duration(milliseconds: 3500)]);
    });

    test('a deadline-less warning is still reported (null, not dropped)', () async {
      final h = _Harness();
      await _connect(h);
      h.socketFactory.message(jsonEncode({'goAway': <String, dynamic>{}}));
      expect(h.goAways, [null]);
    });

    test('an unparseable deadline degrades to null instead of losing the warning', () async {
      final h = _Harness();
      await _connect(h);
      h.socketFactory.message(jsonEncode({
        'goAway': {'timeLeft': 'soon'}
      }));
      expect(h.goAways, [null]);
    });

    test('the warning is not an error and does not end the session', () async {
      final h = _Harness();
      await _connect(h);
      h.socketFactory.message(jsonEncode({
        'goAway': {'timeLeft': '5s'}
      }));
      expect(h.errors, isEmpty);
      expect(h.session.isWarm(), isTrue);
      // The socket still works: a handle offered after the warning is still
      // passed on — that handle is exactly what the rebuild will use.
      h.socketFactory.message(jsonEncode({
        'sessionResumptionUpdate': {'newHandle': 'H1'}
      }));
      expect(h.resumptionHandles, ['H1']);
    });
  });
}
