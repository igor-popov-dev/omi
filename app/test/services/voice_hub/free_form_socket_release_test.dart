// What happens to the SOCKET when a free-form voice session is abandoned —
// the one seam neither `free_form_voice_mode_test.dart` (fake session, no
// socket) nor `hub_session_test.dart` (bare session, no mode) can see: the
// mode's silence auto-off and the session's D4 idle release are two timers
// owned by two different objects, and only their composition answers "how
// long does an abandoned session keep a socket open".
//
// Assembled production-shape on purpose: a real `GeminiHubSession`
// (freeFormMode) under a real `HubController` under `FreeFormVoiceMode`,
// with only the socket, the player and the mic faked. Everything runs on
// `fakeAsync`'s single timeline through `DefaultHubClock`, so the mode's
// 3-minute silence timer and the session's 90s idle release race each other
// exactly as they do on a phone.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:omi/services/voice_hub/free_form_voice_mode.dart';
import 'package:omi/services/voice_hub/gemini_hub_session.dart';
import 'package:omi/services/voice_hub/hub_controller.dart';
import 'package:omi/services/voice_hub/hub_ptt_capture.dart';
import 'package:omi/services/voice_hub/hub_session.dart';

// ---- fixtures ---------------------------------------------------------

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
}

/// Keeps EVERY socket it built, not just the last one — the re-enable test
/// has to tell "the old socket was released" from "a new one was opened".
class _SocketFactory {
  final List<_RecordingHubSocket> sockets = [];
  final List<HubSocketOpenSpec> specs = [];

  HubSocket factory(HubSocketOpenSpec spec) {
    specs.add(spec);
    final socket = _RecordingHubSocket();
    sockets.add(socket);
    return socket;
  }

  _RecordingHubSocket get last => sockets.last;

  /// Open the newest socket and let Gemini answer the setup frame.
  void connect() {
    last.setReadyState(webSocketOpenReadyState);
    specs.last.onOpen();
    specs.last.onMessage(jsonEncode({'setupComplete': <String, dynamic>{}}));
  }
}

class _FakeCapture implements HubPttCapture {
  int disposeCalls = 0;
  @override
  void dispose() => disposeCalls += 1;
}

/// The mode + hub + a real Gemini session over a fake socket.
class _Stack {
  final _SocketFactory socketFactory = _SocketFactory();
  late final HubController hub;
  late final FreeFormVoiceMode mode;

  int mintCalls = 0;
  int turnIds = 0;
  int idleTimeoutCalls = 0;
  final List<_FakeCapture> captures = [];
  void Function(Uint8List)? onChunk;

  _Stack({Duration silenceTimeout = const Duration(minutes: 3)}) {
    hub = HubController(
      buildInstructions: () => 'INSTRUCTIONS',
      mintToken: () async {
        mintCalls += 1;
        return 'ek_token';
      },
      createSession: (spec) => GeminiHubSession(
        token: spec.token,
        instructions: spec.instructions,
        events: spec.events,
        playerFactory: (_) async => _NoopVoicePlayer(),
        socketFactory: socketFactory.factory,
        tools: spec.tools,
        resumptionHandle: spec.resumptionHandle,
        freeFormMode: true,
      ),
    );
    mode = FreeFormVoiceMode(
      hub: hub,
      startCapture: (options) async {
        onChunk = options.onChunk;
        final capture = _FakeCapture();
        captures.add(capture);
        return capture;
      },
      mintTurnId: () => 'turn-${++turnIds}',
      resolveIdleTimeout: () => silenceTimeout,
      onIdleTimeout: () => idleTimeoutCalls += 1,
    );
  }

  /// One mic frame, exactly as `NativeMicHubPttCapture` would tee it.
  void speakFrame() => onChunk?.call(Uint8List.fromList(const [1, 2, 3, 4]));

  /// The mode is on and the socket is live and accepting audio.
  void startAndConnect(FakeAsync async) {
    unawaited(mode.start());
    async.elapse(const Duration(milliseconds: 10)); // mint + createSession + startCapture
    socketFactory.connect();
    async.elapse(const Duration(milliseconds: 10));
  }
}

void main() {
  // The continuous mic is what keeps a live free-form session off the idle
  // release: `appendAudio` touches the idle timer on every frame, and the
  // capture streams whether or not anyone is talking. Without that the 90s
  // release would tear the socket out from under a user who simply paused —
  // the mode's own auto-off is 3 minutes precisely because a pause is not an
  // abandonment.
  test('a running free-form session outlives the idle release while the mic streams', () {
    fakeAsync((async) {
      final stack = _Stack();
      stack.startAndConnect(async);
      expect(stack.hub.isWarm(), isTrue);

      // Silence, but the mic keeps streaming: 2.5 minutes at 20 frames/s,
      // well past both the 90s release and the used-socket window it beats.
      for (var i = 0; i < 150; i++) {
        stack.speakFrame();
        async.elapse(const Duration(seconds: 1));
      }

      expect(stack.socketFactory.last.closed, isFalse);
      expect(stack.hub.isWarm(), isTrue);
      expect(stack.idleTimeoutCalls, 0); // the mic is not activity; nothing rearmed it either
      expect(stack.socketFactory.sockets, hasLength(1));
    });
  });

  // The question this file was written for: after the silence auto-off the
  // mode deliberately does NOT end the conversation (so coming back resumes
  // it), and nothing in `FreeFormVoiceMode` closes the socket. The session's
  // own D4 release is what bounds it — 90s after the last frame, which is the
  // auto-off itself (`cancelTurn` touches the idle timer). So an abandoned
  // free-form session costs at most `3min + 90s` of open socket, and no
  // explicit close is needed on the auto-off path.
  test('the silence auto-off leaves the socket to the D4 idle release, which closes it', () {
    fakeAsync((async) {
      final stack = _Stack();
      stack.startAndConnect(async);

      // The mic streams for the whole 3 minutes — that is what production
      // does, the capture is only disposed BY the auto-off.
      for (var i = 0; i < 180; i++) {
        stack.speakFrame();
        async.elapse(const Duration(seconds: 1));
      }
      expect(stack.idleTimeoutCalls, 1);
      expect(stack.mode.isRunning, isFalse);
      expect(stack.captures.single.disposeCalls, 1);

      // The socket is still open at that instant — the release runs from the
      // auto-off, not from the last mic frame before it.
      expect(stack.socketFactory.last.closed, isFalse);

      async.elapse(hubIdleReleaseDuration - const Duration(seconds: 1));
      expect(stack.socketFactory.last.closed, isFalse);
      async.elapse(const Duration(seconds: 2));
      expect(stack.socketFactory.last.closed, isTrue);
      expect(stack.hub.isWarm(), isFalse);

      // And it stays closed: a silent release must not trigger the proactive
      // re-warm an expected server-side idle close does, or an abandoned
      // session would cycle mint/connect/close forever on a phone in a
      // pocket.
      async.elapse(const Duration(minutes: 10));
      expect(stack.socketFactory.sockets, hasLength(1));
      expect(stack.mintCalls, 1);
    });
  });

  // The mirror case, and the one that was broken: the mode is STILL ON and
  // the mic goes quiet because something took it away. A phone call is the
  // everyday version — the native controller treats a stalled mic under a
  // call mode as an interruption and waits it out rather than rebuilding
  // (`PhoneMicController.kt` Rule 2), so no frames reach the hub for the
  // length of the call.
  //
  // Releasing the socket there was silent: `teardown()` emits nothing, so the
  // host kept showing "voice mode on" while every frame after the call landed
  // in a torn-down session's pending buffer. The user talks, nothing answers,
  // and the only thing that ever ends it is the silence auto-off.
  test('a call that silences the mic does not silently release the socket under a live mode', () {
    fakeAsync((async) {
      final stack = _Stack();
      stack.startAndConnect(async);
      stack.speakFrame();

      // A two-minute call: no mic frames, mode still on. Past the 90s release
      // and past the shortest server-side window we have measured.
      async.elapse(const Duration(minutes: 2));
      expect(stack.mode.isRunning, isTrue);
      expect(stack.socketFactory.last.closed, isFalse);
      expect(stack.hub.isWarm(), isTrue);

      // The call ends, the mic resumes: audio reaches the wire, not a
      // pending buffer nobody flushes.
      final before = stack.socketFactory.last.sent.length;
      stack.speakFrame();
      async.elapse(const Duration(milliseconds: 10));
      expect(stack.socketFactory.last.sent.length, greaterThan(before));

      // Once the mode does end, the release is back in play — the guard
      // delays the release, it does not disable it.
      stack.mode.stop();
      async.elapse(hubIdleReleaseDuration + const Duration(seconds: 1));
      expect(stack.socketFactory.last.closed, isTrue);
    });
  });

  // Coming back after the release: the hub is cold, so the next start pays a
  // fresh mint + socket. It must actually get one — the released session
  // object is still installed on the controller, and a re-warm that reused it
  // would begin a turn on a torn-down socket (no reply, no error).
  test('re-enabling the mode after the release opens a fresh socket', () {
    fakeAsync((async) {
      final stack = _Stack();
      stack.startAndConnect(async);
      for (var i = 0; i < 180; i++) {
        stack.speakFrame();
        async.elapse(const Duration(seconds: 1)); // mic streams up to the auto-off
      }
      async.elapse(hubIdleReleaseDuration + const Duration(seconds: 1)); // release
      expect(stack.socketFactory.sockets, hasLength(1));

      unawaited(stack.mode.start());
      async.elapse(const Duration(milliseconds: 10));
      stack.socketFactory.connect();
      async.elapse(const Duration(milliseconds: 10));

      expect(stack.mintCalls, 2);
      expect(stack.socketFactory.sockets, hasLength(2));
      expect(stack.hub.isWarm(), isTrue);
      expect(stack.socketFactory.last.closed, isFalse);

      // Input reaches the wire on the new socket (i.e. the mode really is
      // live again, not just "warm"): free-form audio goes out as a
      // realtimeInput frame, no manual activity window.
      stack.speakFrame();
      async.elapse(const Duration(milliseconds: 10));
      final frames = stack.socketFactory.last.sent.map((s) => jsonDecode(s) as Map<String, dynamic>);
      expect(frames.where((f) => f.containsKey('realtimeInput')), isNotEmpty);
    });
  });
}
