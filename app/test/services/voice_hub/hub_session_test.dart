// A 1:1-in-spirit port of the desktop (Electron/TS) test suite at
// `desktop/windows/src/renderer/src/lib/voice/hub/hubSession.test.ts`. Test
// names are kept verbatim where they exist upstream.
//
// The upstream `describe('defaultSocketFactory — binary frame decoding')`
// block is NOT ported as-is: it works by swapping `globalThis.WebSocket`
// for a fake constructor, which has no Dart equivalent (`IOWebSocketChannel`
// owns real `dart:io` socket construction with no injection seam at that
// level). `hub_session.dart` extracts the actual decode logic into a pure
// top-level function (`decodeIncomingHubFrame`) precisely so this same
// regression — Gemini's BINARY `setupComplete` readiness frame being
// dropped — stays covered without a real socket; see the first group below.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:omi/services/voice_hub/hub_session.dart';

// ---- fixtures --------------------------------------------------------------

/// A player that does nothing — the base only needs it to exist.
class _NoopVoicePlayer implements VoicePlayer {
  @override
  void enqueuePcm16(Uint8List bytes) {}
  @override
  void clear() {}
  @override
  void flush() {}
  @override
  void close() {}
}

Future<VoicePlayer> _noopPlayerFactory(VoicePlayerStartSpec spec) async => _NoopVoicePlayer();

/// A player factory that captures the [VoicePlayerStartSpec] passed by
/// `_openConnection`, so a test can invoke `spec.onAudioFocusLost` directly —
/// the real trigger (native `AudioFocusPolicy` STOP) has no Dart-level fake
/// to drive it through, unlike the socket/clock seams above.
class _CapturingPlayerFactory {
  VoicePlayerStartSpec? spec;

  Future<VoicePlayer> factory(VoicePlayerStartSpec spec) async {
    this.spec = spec;
    return _NoopVoicePlayer();
  }
}

/// A controllable socket whose `send` throws when not OPEN, exactly like a
/// real `WebSocket` — so a missing guard in `BaseHubSession.send` would
/// surface as a thrown error, and the guard's presence as a silently-dropped
/// frame.
class _ControllableHubSocket implements HubSocket {
  int _readyState = 0; // CONNECTING
  final List<String> sent = [];

  @override
  void send(String data) {
    if (_readyState != webSocketOpenReadyState) throw StateError('InvalidStateError');
    sent.add(data);
  }

  @override
  void close() => _readyState = 3;

  @override
  int? get readyState => _readyState;

  void setReadyState(int state) => _readyState = state;
}

class _ControllableSocketFactory {
  _ControllableHubSocket? socket;
  HubSocketOpenSpec? spec;

  HubSocket factory(HubSocketOpenSpec spec) {
    this.spec = spec;
    return socket = _ControllableHubSocket();
  }

  /// Move to OPEN and fire the open handshake (sends the setup frame).
  void open() {
    socket?.setReadyState(webSocketOpenReadyState);
    spec?.onOpen();
  }

  /// Deliver a server→client frame (drives `handleProviderMessage`).
  void message(String data) => spec?.onMessage(data);
}

/// A fake clock that records each armed timer with its delay so a test can
/// fire a specific one (the ~10s warm timeout vs. the 180s idle release)
/// without waiting real time — same injected-clock seam as the TS source's
/// `HubClock`.
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

  /// Fire (and consume) the single pending timer armed for [duration].
  void fireDuration(Duration duration) {
    final timer = _timers.firstWhere(
      (t) => t.duration == duration,
      orElse: () => throw StateError('no pending timer for $duration'),
    );
    _timers.remove(timer);
    timer.fire();
  }

  bool pendingFor(Duration duration) => _timers.any((t) => t.duration == duration);
}

class _FakeTimer {
  final Duration duration;
  final void Function() fire;
  _FakeTimer({required this.duration, required this.fire});
}

/// Minimal concrete session that routes `cancelTurn` to a base `send()` so
/// the readyState guard is exercised through the real per-turn primitive
/// path, and counts append/commit calls so buffering tests can assert on
/// them — mirrors the TS source's `TestHubSession`.
class _TestHubSession extends BaseHubSession {
  _TestHubSession({
    required super.token,
    required super.instructions,
    required super.socketFactory,
    required super.playerFactory,
    super.clock,
    super.events,
  });

  final List<String> appendedFrames = [];
  int commitCount = 0;

  @override
  HubProvider get provider => HubProvider.gemini;
  @override
  int get requiredInputSampleRate => 24000;
  @override
  HubBargeInStrategy get bargeInStrategy => HubBargeInStrategy.freshSession;

  @override
  HubConnectSpec connectSpec() => const HubConnectSpec(url: 'wss://test.invalid/realtime');

  @override
  Map<String, dynamic> sessionSetupFrame() => {'type': 'session.setup'};

  @override
  void handleProviderMessage(Map<String, dynamic> obj) {
    if (obj['type'] == 'ready') markReady();
  }

  @override
  bool canAcceptInput() => isOpen;

  @override
  void appendAudioFrame(String b64) => appendedFrames.add(b64);

  @override
  void onBeginTurn(bool interrupting) {}

  @override
  void commitTurnNow() => commitCount++;

  @override
  void onCancelTurn() {
    // A control frame — the exact shape that races a not-yet-open socket.
    send({'type': 'input_audio_buffer.clear'});
  }

  @override
  void onSendToolResult(String callId, String name, String output) {}

  @override
  void onSendUserText(String text) => sentUserTexts.add(text);

  final List<String> sentUserTexts = [];

  @override
  void onProviderReady() {}

  @override
  void resetProviderState() {}
}

class _WarmedSession {
  final _ControllableSocketFactory sockFactory;
  final _TestHubSession session;
  _WarmedSession(this.sockFactory, this.session);
}

Future<_WarmedSession> _warmedSession({HubClock? clock, HubSessionEvents? events}) async {
  final sockFactory = _ControllableSocketFactory();
  final session = _TestHubSession(
    token: 'tok',
    instructions: 'instr',
    socketFactory: sockFactory.factory,
    playerFactory: _noopPlayerFactory,
    clock: clock,
    events: events ?? const HubSessionEvents(),
  );
  // The warm timeout test deliberately lets this future reject; swallow it
  // here (once, uniformly) so a rejection never surfaces as an unhandled
  // async error — mirrors the TS source's `warm.catch(() => {})`.
  unawaited(session.ensureWarm().catchError((_) {}));
  // _openConnection awaits the player factory before creating the socket.
  await Future<void>.value();
  await Future<void>.value();
  return _WarmedSession(sockFactory, session);
}

void main() {
  group('decodeIncomingHubFrame — binary/text frame decoding', () {
    // Regression for the Gemini binary-frame drop that would otherwise ship
    // silently: Gemini Live delivers control frames (incl. the
    // `{"setupComplete":{}}` readiness signal) as BINARY. Without decoding,
    // the readiness frame never reaches `handleProviderMessage`, the Gemini
    // session never warms, and every hub turn silently cascades.
    test('decodes a BINARY readiness frame to text', () {
      final binary = utf8.encode('{"setupComplete":{}}');
      expect(decodeIncomingHubFrame(binary), '{"setupComplete":{}}');
    });

    test('passes a normal string frame through unchanged', () {
      expect(decodeIncomingHubFrame('{"serverContent":{}}'), '{"serverContent":{}}');
    });

    test('drops a frame shape it does not understand', () {
      expect(decodeIncomingHubFrame(42), isNull);
    });
  });

  group('BaseHubSession.send — non-OPEN socket guard', () {
    test('drops a control frame on a CONNECTING socket without throwing', () async {
      final warmed = await _warmedSession();
      // Socket exists but is still CONNECTING (no open handshake yet).
      expect(() => warmed.session.cancelTurn(), returnsNormally);
      expect(warmed.sockFactory.socket!.sent, isEmpty);
    });

    test('sends the control frame once the socket is OPEN', () async {
      final warmed = await _warmedSession();
      warmed.sockFactory.open(); // OPEN + fires the setup frame
      expect(warmed.sockFactory.socket!.sent, [
        jsonEncode({'type': 'session.setup'})
      ]);
      warmed.session.cancelTurn();
      expect(warmed.sockFactory.socket!.sent, [
        jsonEncode({'type': 'session.setup'}),
        jsonEncode({'type': 'input_audio_buffer.clear'}),
      ]);
    });

    test('drops a control frame on a CLOSING socket without throwing', () async {
      final warmed = await _warmedSession();
      warmed.sockFactory.open();
      warmed.sockFactory.socket!.setReadyState(2); // CLOSING
      expect(() => warmed.session.cancelTurn(), returnsNormally);
      // Only the setup frame from open() — the CLOSING control frame was dropped.
      expect(warmed.sockFactory.socket!.sent, [
        jsonEncode({'type': 'session.setup'})
      ]);
    });
  });

  group('BaseHubSession.ensureWarm — connect/setup timeout', () {
    /// Build a warming session whose socket has opened but has NOT yet
    /// signaled readiness (no `{type:'ready'}` frame), with an injected
    /// fake clock.
    Future<
        ({
          _ControllableSocketFactory sockFactory,
          _FakeHubClock clock,
          _TestHubSession session,
          List<({String message, bool retryable})> errors,
        })> connectingSession() async {
      final clock = _FakeHubClock();
      final errors = <({String message, bool retryable})>[];
      final warmed = await _warmedSession(
        clock: clock,
        events: HubSessionEvents(
          onError: (message, retryable, closeCode) => errors.add((message: message, retryable: retryable)),
        ),
      );
      return (sockFactory: warmed.sockFactory, clock: clock, session: warmed.session, errors: errors);
    }

    test('fails fast when the socket opens but the provider never signals readiness', () async {
      final s = await connectingSession();
      s.sockFactory.open(); // socket OPEN + setup frame sent, but no readiness frame ever arrives
      expect(s.session.isWarm(), isFalse);

      // The ~10s warm timeout fires (NOT the 180s idle release) → a clean fast failure.
      s.clock.fireDuration(hubWarmTimeoutDuration);
      expect(s.session.isWarm(), isFalse);
      // Surfaced through onError as retryable so the controller's strike
      // accounting sees it.
      expect(s.errors, [(message: 'hub warm timeout', retryable: true)]);
    });

    test('does NOT fire once the provider signals readiness — the healthy warm path is unchanged', () async {
      final s = await connectingSession();
      s.sockFactory.open();
      s.sockFactory.message('{"type":"ready"}'); // provider ready within the bound → markReady
      expect(s.session.isWarm(), isTrue);
      // The warm timeout was cleared on markReady; only the 180s idle release remains.
      expect(s.clock.pendingFor(hubWarmTimeoutDuration), isFalse);
      expect(s.clock.pendingFor(hubIdleReleaseDuration), isTrue);
    });
  });

  group('BaseHubSession — pending audio / deferred commit buffering (design doc §2)', () {
    test('buffers appendAudio before the provider can accept input and flushes on markReady', () async {
      final warmed = await _warmedSession();
      warmed.sockFactory.open();
      // TestHubSession.canAcceptInput() == isOpen, which is still false pre-ready.
      warmed.session.appendAudio(Uint8List.fromList([1, 2, 3]));
      expect(warmed.session.appendedFrames, isEmpty);

      warmed.sockFactory.message('{"type":"ready"}');
      expect(warmed.session.appendedFrames, [
        base64Encode([1, 2, 3])
      ]);
    });

    test('a commitTurn() before readiness is deferred and fires exactly once at markReady', () async {
      final warmed = await _warmedSession();
      warmed.sockFactory.open();
      warmed.session.commitTurn();
      expect(warmed.session.commitCount, 0);

      warmed.sockFactory.message('{"type":"ready"}');
      expect(warmed.session.commitCount, 1);
    });
  });

  group('BaseHubSession — idle release (D4)', () {
    test('teardown() after the 180s idle timer fires releases the warm socket', () {
      fakeAsync((async) {
        final sockFactory = _ControllableSocketFactory();
        final session = _TestHubSession(
          token: 'tok',
          instructions: 'instr',
          socketFactory: sockFactory.factory,
          playerFactory: _noopPlayerFactory,
          clock: const DefaultHubClock(),
        );
        unawaited(session.ensureWarm());
        async.elapse(const Duration(milliseconds: 1));
        sockFactory.open();
        sockFactory.message('{"type":"ready"}');
        expect(session.isWarm(), isTrue);

        async.elapse(hubIdleReleaseDuration + const Duration(seconds: 1));
        expect(session.isWarm(), isFalse);
      });
    });
  });

  group('BaseHubSession — audio focus loss (native AudioFocusPolicy STOP)', () {
    test('onAudioFocusLost surfaces as a non-retryable session error and tears the session down', () async {
      final capture = _CapturingPlayerFactory();
      final sockFactory = _ControllableSocketFactory();
      final errors = <({String message, bool retryable})>[];
      final session = _TestHubSession(
        token: 'tok',
        instructions: 'instr',
        socketFactory: sockFactory.factory,
        playerFactory: capture.factory,
        events: HubSessionEvents(
          onError: (message, retryable, closeCode) => errors.add((message: message, retryable: retryable)),
        ),
      );
      unawaited(session.ensureWarm().catchError((_) {}));
      // _openConnection awaits the player factory before creating the socket.
      await Future<void>.value();
      await Future<void>.value();
      sockFactory.open();
      sockFactory.message('{"type":"ready"}');
      expect(session.isWarm(), isTrue);

      capture.spec!.onAudioFocusLost!();

      expect(errors, [(message: 'audio focus lost', retryable: false)]);
      expect(session.isWarm(), isFalse);
    });
  });
}
