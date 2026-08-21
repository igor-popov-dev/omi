// A 1:1-in-spirit port of the desktop (Electron/TS) test suite at
// `desktop/windows/src/renderer/src/lib/voice/hub/geminiHubSession.test.ts`.
// Test names/groupings are kept close to upstream where they apply.
//
// The upstream suite's tool-catalog/sanitizer tests (`GeminiHubSession —
// warm config` block beyond the base "no catalog wired" case, and the
// cross-lane-isolation test against `OpenAiHubSession`) are NOT ported: per
// `gemini_hub_session.dart`'s file header, this port has no `tools` seam at
// all (design doc §3 defers it, and there is no OpenAI lane in this port to
// begin with — design doc §3). Only the empty-catalog shape of the setup
// frame is asserted here.
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

  _Harness._(this.session, this.socketFactory, this.player);

  factory _Harness({HubClock? clock}) {
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
      events: HubSessionEvents(
        onConnected: (sid) => h.connected.add(sid),
        onError: (message, retryable, closeCode) =>
            h.errors.add((message: message, retryable: retryable, closeCode: closeCode)),
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
      // No catalog seam exists in this port ⇒ an empty (but faithful)
      // functionDeclarations frame, always.
      expect(setup['tools'], [
        {'functionDeclarations': <Map<String, dynamic>>[]}
      ]);
      h.socketFactory.message(jsonEncode({'setupComplete': <String, dynamic>{}}));
      await Future<void>.value();
      expect(h.connected, ['sess-1']);
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
}
