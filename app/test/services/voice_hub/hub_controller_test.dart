// A 1:1-in-spirit port of the desktop (Electron/TS) test suite at
// `desktop/windows/src/renderer/src/lib/voice/hub/hubController.test.ts`.
// Test names are kept verbatim where they exist upstream. The upstream
// `describe` block for cross-provider failover (item D) is NOT ported —
// `hub_controller.dart`'s file header documents the cut (no second provider
// to fail over to). The PR-C tool-catalog loop (`fetchTools`,
// `HubSessionSpec.tools`) WAS cut for the same reason at the time, but is now
// wired (lane5.md §"ГЛАВНЫЙ ПРИОРИТЕТ 22.08" step 3) — see its own group
// below, mirroring the mint-step M1 teardown-race tests for the fetch await
// point. Everything else — warm/idempotent ensureWarm, the warm-wait buffer,
// the four turn primitives, requestSessionRefresh, the M1 teardown race, the
// connect/error surface, and the full A7c reconnect policy (strike budget +
// circuit breaker + idle-teardown survival) — is covered here.
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:omi/services/voice_hub/hub_close.dart';
import 'package:omi/services/voice_hub/hub_controller.dart';
import 'package:omi/services/voice_hub/hub_session.dart';
import 'package:omi/services/voice_hub/voice_turn_machine.dart' show VoiceSessionId, VoiceTurnId;

// ---- fixtures --------------------------------------------------------------

/// A fake provider session: records every frame-level call and lets the test
/// drive the connect/error edges deterministically. Buffering is the
/// controller's job, so `appendAudio` here only ever sees post-connect
/// frames (the controller withholds during warm-wait) — mirrors the TS
/// source's `FakeSession`.
class _FakeSession implements HubSession {
  @override
  HubProvider get provider => HubProvider.gemini;
  @override
  int get requiredInputSampleRate => 16000;
  @override
  HubBargeInStrategy get bargeInStrategy => HubBargeInStrategy.freshSession;

  final VoiceSessionId sessionId;
  final HubSessionEvents events;

  _FakeSession(this.sessionId, this.events);

  bool warm = false;
  final List<Uint8List> appended = [];
  int committed = 0;
  int cancelled = 0;
  final List<bool> begun = [];
  int toreDown = 0;
  final List<({String callId, String output})> toolResults = [];
  int cleared = 0;

  Completer<void>? _warmCompleter;

  @override
  Future<void> ensureWarm() {
    if (warm) return Future.value();
    final completer = Completer<void>();
    _warmCompleter = completer;
    return completer.future;
  }

  /// Test-only: marks ready, fires onConnected (controller flushes here),
  /// resolves the pending warm.
  void connect() {
    warm = true;
    events.onConnected?.call(sessionId);
    _warmCompleter?.complete();
    _warmCompleter = null;
  }

  /// Test-only: a fatal mid-session error. [closeCode] mirrors a real WS
  /// close code, so the A7c classifier sees a genuine 1008. Rejects the
  /// pending warm future exactly like `BaseHubSession`'s error path, so the
  /// controller's in-flight warm clears and a re-warm can rebuild.
  void fail(String message, [bool retryable = true, int? closeCode]) {
    warm = false;
    events.onError?.call(message, retryable, closeCode);
    _warmCompleter?.completeError(StateError(message));
    _warmCompleter = null;
  }

  @override
  bool isWarm() => warm;

  @override
  void beginTurn([HubBeginTurnOptions opts = const HubBeginTurnOptions()]) {
    begun.add(opts.interrupting);
  }

  @override
  void appendAudio(Uint8List pcm) => appended.add(pcm);

  @override
  void commitTurn() => committed += 1;

  @override
  void cancelTurn() => cancelled += 1;

  @override
  void sendToolResult(String callId, String name, String output) {
    toolResults.add((callId: callId, output: output));
  }

  @override
  void sendUserText(String text) => userTexts.add(text);

  final List<String> userTexts = [];

  @override
  void clearPlayback() {
    cleared += 1;
  }

  @override
  void teardown() {
    toreDown += 1;
    warm = false;
  }
}

Future<void> _tick() => Future<void>.delayed(Duration.zero);

const VoiceTurnId t1 = 'turn-1';
const VoiceTurnId t2 = 'turn-2';
const VoiceSessionId sid = 'sess-1';
Uint8Array frame(int n) => Uint8List.fromList([n]);
// Local alias so the port reads close to the TS `Uint8Array` naming without
// actually introducing a second type.
typedef Uint8Array = Uint8List;

class _EventLog {
  VoiceSessionId? connectedId;
  int connectedCalls = 0;
  HubControllerError? lastError;
  int errorCalls = 0;
  final List<({String text, bool isFinal})> assistantText = [];
  final List<({String text, bool isFinal})> inputTranscript = [];
  final List<bool> userSpeechStates = [];
  int speakingStart = 0;
  int speakingEnd = 0;
  int turnDoneCalls = 0;
  final List<HubCascadeHandoff> cascadeHandoffs = [];

  HubControllerEvents get events => HubControllerEvents(
        onConnected: (id) {
          connectedId = id;
          connectedCalls += 1;
        },
        onError: (e) {
          lastError = e;
          errorCalls += 1;
        },
        onAssistantText: (text, isFinal, identity) => assistantText.add((text: text, isFinal: isFinal)),
        onInputTranscript: (text, isFinal, identity) => inputTranscript.add((text: text, isFinal: isFinal)),
        onUserSpeechState: (isSpeaking) => userSpeechStates.add(isSpeaking),
        onSpeakingStart: () => speakingStart += 1,
        onSpeakingEnd: () => speakingEnd += 1,
        onTurnDone: (identity) => turnDoneCalls += 1,
        onCascadeHandoff: (h) => cascadeHandoffs.add(h),
      );
}

/// Injected fake timer for the A7c reconnect backoff — never auto-fires, so
/// tests are deterministic and no real timer leaks between cases.
/// `_scheduleReWarm` coalesces on `_reconnectPending`, so at most one is
/// armed at a time.
class _FakeReconnectClock implements HubClock {
  final Map<int, void Function()> _timers = {};
  int _seq = 0;

  @override
  Object setTimer(Duration duration, void Function() fire) {
    final id = ++_seq;
    _timers[id] = fire;
    return id;
  }

  @override
  void clearTimer(Object handle) => _timers.remove(handle as int);

  bool get pending => _timers.isNotEmpty;

  void fire() {
    if (_timers.isEmpty) throw StateError('no pending reconnect timer');
    final entry = _timers.entries.first;
    _timers.remove(entry.key);
    entry.value();
  }
}

class _Harness {
  late HubController controller;
  final _EventLog log = _EventLog();
  int mintCalls = 0;
  int createCalls = 0;
  _FakeSession? _session;
  List<VoiceToolDeclaration>? lastSpecTools;

  /// Handle each built session was handed, in build order (nulls included).
  final List<String?> specHandles = [];
  final _now = _NowBox(1000);
  final _FakeReconnectClock clock = _FakeReconnectClock();
  Future<String> Function() mintTokenImpl = () async => 'ek_token';

  _Harness({String instructions = 'INSTRUCTIONS+CARD', HubFetchTools? fetchTools}) {
    controller = HubController(
      events: log.events,
      buildInstructions: () => instructions,
      mintToken: () {
        mintCalls += 1;
        return mintTokenImpl();
      },
      createSession: (spec) {
        createCalls += 1;
        lastSpecTools = spec.tools;
        specHandles.add(spec.resumptionHandle);
        _session = _FakeSession(sid, spec.events);
        return _session!;
      },
      clock: clock,
      now: () => _now.value,
      fetchTools: fetchTools,
    );
  }

  _FakeSession get session {
    final s = _session;
    if (s == null) throw StateError('session not created yet');
    return s;
  }

  set nowMs(int v) => _now.value = v;
  int get nowMs => _now.value;
}

class _NowBox {
  int value;
  _NowBox(this.value);
}

/// Warms the controller fully: mint -> create -> connect -> resolved.
Future<void> _warmed(_Harness h) async {
  final p = h.controller.ensureWarm();
  await _tick(); // past the mint await -> session created
  h.session.connect();
  await p;
}

/// Fails the in-flight (connecting, never-connected) warm attempt and lets
/// the reject settle so the controller's `_warming` clears before the next
/// re-warm fires.
Future<void> _failBeforeConnect(_Harness h, [int closeCode = 1008]) async {
  h.session.fail('websocket closed ($closeCode)', true, closeCode);
  await _tick();
}

void main() {
  group('HubController — ensureWarm', () {
    test('mints a token and builds the session with the injected instructions', () async {
      final h = _Harness(instructions: 'PERSONA + <about_user>…');
      final p = h.controller.ensureWarm();
      await _tick();
      h.session.connect();
      final resolvedSid = await p;

      expect(h.mintCalls, 1);
      expect(h.createCalls, 1);
      expect(resolvedSid, sid);
      expect(h.controller.isWarm(), isTrue);
      expect(h.log.connectedId, sid);
    });

    test('is idempotent — a second warm reuses the session, and concurrent warms coalesce', () async {
      final h = _Harness();
      final a = h.controller.ensureWarm();
      final b = h.controller.ensureWarm(); // concurrent -> same in-flight future
      await _tick();
      h.session.connect();
      await Future.wait([a, b]);

      final resolvedSid = await h.controller.ensureWarm();
      expect(resolvedSid, sid);
      expect(h.mintCalls, 1);
      expect(h.createCalls, 1);
    });
  });

  group('HubController — tool catalog (PR-C, lane5.md §"ГЛАВНЫЙ ПРИОРИТЕТ 22.08" step 3)', () {
    const tool = VoiceToolDeclaration(name: 'ask_claude', description: 'd', parameters: {'type': 'object'});

    test('fetches the catalog fresh at warm and passes it into HubSessionSpec.tools', () async {
      var fetchCalls = 0;
      final h = _Harness(fetchTools: () async {
        fetchCalls += 1;
        return [tool];
      });
      final p = h.controller.ensureWarm();
      await _tick(); // past the mint await
      await _tick(); // past the fetchTools await
      h.session.connect();
      await p;

      expect(fetchCalls, 1);
      expect(h.lastSpecTools, [tool]);
    });

    test('no fetchTools seam wired ⇒ tools stays empty (today\'s default, unchanged)', () async {
      final h = _Harness();
      final p = h.controller.ensureWarm();
      await _tick();
      h.session.connect();
      await p;

      expect(h.lastSpecTools, isEmpty);
    });

    test('a fetch failure warms tool-less rather than failing the whole session', () async {
      final h = _Harness(fetchTools: () async => throw StateError('catalog unavailable'));
      final p = h.controller.ensureWarm();
      await _tick();
      await _tick();
      h.session.connect();
      final resolvedSid = await p;

      expect(resolvedSid, sid);
      expect(h.createCalls, 1);
      expect(h.lastSpecTools, isEmpty);
    });

    test('a teardownSession during the tool fetch discards the warm — no orphaned session is installed', () async {
      final resolver = Completer<List<VoiceToolDeclaration>>();
      final h = _Harness(fetchTools: () => resolver.future);
      final p = h.controller.ensureWarm();
      unawaited(p.catchError((Object _) => sid));
      await _tick(); // past the mint await
      await _tick(); // parked on the fetchTools await, before any session is constructed

      h.controller.teardownSession();
      resolver.complete([tool]); // the in-flight fetch finally resolves…
      await _tick();

      // …and the warm bails BEFORE constructing a session.
      expect(h.createCalls, 0);
      expect(h.controller.isAvailable(), isFalse);
      await expectLater(p, throwsA(isA<HubWarmAbortedError>()));
    });
  });

  group('HubController — warm-wait buffer', () {
    test('withholds PCM during warm-wait and flushes it (in order) into the session on hub-ready', () async {
      final h = _Harness();
      h.controller.beginTurn(t1);
      await _tick(); // session object created (still connecting)
      h.controller.appendAudio(t1, frame(1));
      h.controller.appendAudio(t1, frame(2));
      h.controller.commitTurn(t1);

      final s = h.session;
      expect(s.appended, isEmpty);
      expect(s.committed, 0);

      s.connect(); // hub wins the race
      expect(s.appended, [frame(1), frame(2)]);
      expect(s.committed, 1);
      expect(h.log.cascadeHandoffs, isEmpty);
    });

    test('hands the buffer to the cascade on the hubWarm timeout — the turn SURVIVES (socket kept)', () async {
      final h = _Harness();
      h.controller.beginTurn(t1);
      await _tick();
      h.controller.appendAudio(t1, frame(1));
      h.controller.appendAudio(t1, frame(2));
      h.controller.commitTurn(t1);

      h.controller.handoffWarmWaitToCascade(t1);

      expect(h.log.cascadeHandoffs, hasLength(1));
      expect(h.log.cascadeHandoffs.single.frames, [frame(1), frame(2)]);
      expect(h.log.cascadeHandoffs.single.committed, isTrue);

      final s = h.session;
      // Turn survives: the warm socket is KEPT (only the hub side of the
      // turn is abandoned) and nothing terminated the turn.
      expect(s.toreDown, 0);
      expect(s.cancelled, 1);
      expect(h.controller.isAvailable(), isTrue);

      // A second hand-off (or a late connect) does nothing more.
      h.controller.handoffWarmWaitToCascade(t1);
      s.connect();
      expect(h.log.cascadeHandoffs, hasLength(1));
      expect(s.appended, isEmpty);
      expect(s.committed, 0);
    });

    test('discards the buffer on cancel — nothing is flushed and no hand-off fires', () async {
      final h = _Harness();
      h.controller.beginTurn(t1);
      await _tick();
      h.controller.appendAudio(t1, frame(1));

      h.controller.cancelTurn(t1);
      final s = h.session;
      expect(s.cancelled, 1);

      s.connect(); // a late connect must not resurrect the discarded audio
      expect(s.appended, isEmpty);
      expect(s.committed, 0);
      expect(h.log.cascadeHandoffs, isEmpty);
    });
  });

  group('HubController — turn lifecycle', () {
    test('voiceTurnDidTerminate releases per-turn state but KEEPS the warm socket for the next turn', () async {
      final h = _Harness();
      await _warmed(h);
      final s = h.session;

      h.controller.beginTurn(t1); // already warm -> straight through
      h.controller.appendAudio(t1, frame(1));
      h.controller.commitTurn(t1);
      expect(s.appended, [frame(1)]);
      expect(s.committed, 1);

      h.controller.voiceTurnDidTerminate(t1);
      expect(s.toreDown, 0);
      expect(h.controller.isWarm(), isTrue);

      // The next turn reuses the SAME warm session (no re-mint, no new session).
      h.controller.beginTurn(t2);
      h.controller.appendAudio(t2, frame(2));
      expect(s.appended, [frame(1), frame(2)]);
      expect(h.createCalls, 1);
      expect(h.mintCalls, 1);
    });

    test('the four turn primitives are turn-ID fenced — a stale-turn call is a no-op', () async {
      final h = _Harness();
      await _warmed(h);
      final s = h.session;
      h.controller.beginTurn(t1);

      // Every primitive carrying the WRONG (superseded) turn id is inert.
      h.controller.appendAudio(t2, frame(9));
      h.controller.commitTurn(t2);
      h.controller.cancelTurn(t2);
      h.controller.handoffWarmWaitToCascade(t2);
      h.controller.voiceTurnDidTerminate(t2);

      expect(s.appended, isEmpty);
      expect(s.committed, 0);
      expect(s.cancelled, 0);
      expect(h.log.cascadeHandoffs, isEmpty);

      // The active turn still works after the stale calls were dropped.
      h.controller.appendAudio(t1, frame(1));
      h.controller.commitTurn(t1);
      expect(s.appended, [frame(1)]);
      expect(s.committed, 1);
    });

    test('a barge-in begin forwards the interrupting flag to the provider session', () async {
      final h = _Harness();
      await _warmed(h);
      final s = h.session;
      h.controller.beginTurn(t1);
      h.controller.voiceTurnDidTerminate(t1);
      h.controller.beginTurn(t2, interrupting: true);
      expect(s.begun, [false, true]);
    });
  });

  group('HubController — requestSessionRefresh (A7c wake / zombie-session refresh)', () {
    test('idle + warm: drops the possibly-dead socket and re-warms a fresh session', () async {
      final h = _Harness();
      await _warmed(h);
      final stale = h.session;
      expect(stale.isWarm(), isTrue);

      h.controller.requestSessionRefresh('system_wake');

      // The zombie socket is dropped immediately (teardown), not reused as
      // "already warm".
      expect(stale.toreDown, 1);
      expect(h.controller.isWarm(), isFalse);

      // A fresh session is minted + connected so the NEXT press lands on a
      // warm socket.
      await _tick();
      final fresh = h.session;
      expect(identical(fresh, stale), isFalse);
      fresh.connect();
      expect(h.mintCalls, 2);
      expect(h.createCalls, 2);
      expect(h.controller.isWarm(), isTrue);
    });

    test('mid-turn: defers (never tears down a live turn) and re-warms once the turn terminates', () async {
      final h = _Harness();
      await _warmed(h);
      final stale = h.session;
      h.controller.beginTurn(t1); // already warm -> an ACTIVE turn is in flight

      h.controller.requestSessionRefresh('system_wake');

      // Deferred: the live turn's socket is untouched — no teardown, no re-mint.
      expect(stale.toreDown, 0);
      expect(h.controller.isWarm(), isTrue);
      expect(h.mintCalls, 1);

      // The turn ends -> the deferred refresh fires: stale socket dropped, fresh warm.
      h.controller.voiceTurnDidTerminate(t1);
      expect(stale.toreDown, 1);
      await _tick();
      h.session.connect();
      expect(h.mintCalls, 2);
      expect(h.createCalls, 2);
      expect(h.controller.isWarm(), isTrue);
    });

    test('no warm session: is a no-op — wake never force-warms a disabled / signed-out hub', () {
      final h = _Harness();
      // Never warmed (kill-switch off / signed out) -> no session to refresh.
      h.controller.requestSessionRefresh('system_wake');
      expect(h.mintCalls, 0);
      expect(h.createCalls, 0);
      expect(h.controller.isWarm(), isFalse);
      expect(h.controller.isAvailable(), isFalse);
    });

    test('mid-connect: is a no-op — an in-flight warm is already building a fresh socket', () async {
      final h = _Harness();
      final p = h.controller.ensureWarm(); // warm in flight (session created, still connecting)
      await _tick();
      final connecting = h.session;

      h.controller.requestSessionRefresh('system_wake');

      // The in-flight warm is left to finish — not torn down, no second mint
      // that would race it.
      expect(connecting.toreDown, 0);
      expect(h.mintCalls, 1);

      connecting.connect();
      await p;
      expect(h.controller.isWarm(), isTrue);
      expect(h.createCalls, 1);
    });
  });

  group('HubController — ensureWarm teardown race (M1: cancelable warm)', () {
    test('a teardownSession while the token is minting discards the warm — no orphaned session is installed', () async {
      final resolver = Completer<String>();
      final h = _Harness();
      h.mintTokenImpl = () => resolver.future;

      final p = h.controller.ensureWarm();
      unawaited(p.catchError((Object _) => sid)); // aborted warm rejects — swallow
      await _tick(); // parked on the mint await, before any session is constructed

      // The hub is explicitly dropped (kill-switch off / sign-out) mid-mint.
      h.controller.teardownSession();

      resolver.complete('ek_token'); // the in-flight mint finally resolves…
      await _tick();

      // …and the warm bails BEFORE constructing a session: no orphaned socket
      // to re-warm.
      expect(h.createCalls, 0);
      expect(h.controller.isAvailable(), isFalse);
      expect(h.controller.isWarm(), isFalse);
      await expectLater(p, throwsA(isA<HubWarmAbortedError>()));
    });

    test('a teardownSession after the warm resolves but before it installs discards the session (no leak)', () async {
      final h = _Harness();
      final p = h.controller.ensureWarm();
      unawaited(p.catchError((Object _) => sid));
      await _tick(); // session constructed, connecting
      final s = h.session;

      // The socket connects (markReady -> onConnected -> warm resolves),
      // then — before the ensureWarm continuation runs — the hub is
      // explicitly dropped. The generation guard is what stops this
      // resolved-then-dropped session from being installed as the live hub.
      s.connect();
      h.controller.teardownSession();
      await _tick(); // the ensureWarm continuation runs and aborts on the moved generation

      expect(h.controller.isAvailable(), isFalse);
      expect(h.controller.isWarm(), isFalse);
      expect(s.toreDown, greaterThanOrEqualTo(1)); // the created socket was closed, not leaked
      await expectLater(p, throwsA(isA<HubWarmAbortedError>()));
    });

    test('overlapping warms WITHOUT a teardown still coalesce to a single warm (no regression)', () async {
      final h = _Harness();
      final a = h.controller.ensureWarm();
      final b = h.controller.ensureWarm(); // straddles the same in-flight warm
      await _tick();
      h.session.connect();

      final results = await Future.wait([a, b]);
      expect(results, [sid, sid]);
      expect(h.mintCalls, 1);
      expect(h.createCalls, 1);
    });
  });

  group('HubController — connect/error surface (A7c seam)', () {
    test('passes provider content events straight through to the host', () async {
      final h = _Harness();
      await _warmed(h);
      h.session.events.onAssistantText?.call('hello', false, null);
      h.session.events.onTurnDone?.call(null);
      expect(h.log.assistantText, [(text: 'hello', isFinal: false)]);
      expect(h.log.turnDoneCalls, 1);
    });

    test('passes the server-VAD speech state through to the host', () async {
      final h = _Harness();
      await _warmed(h);
      h.session.events.onUserSpeechState?.call(true);
      h.session.events.onUserSpeechState?.call(false);
      expect(h.log.userSpeechStates, [true, false]);
    });

    test('surfaces a session error with aliveForMs and drops the handle so ensureWarm rebuilds', () async {
      final h = _Harness();
      await _warmed(h);
      h.nowMs = 6000; // connected at 1000 -> alive 5000 ms

      h.session.fail('socket closed (1006)', true);
      expect(h.log.lastError?.reason, 'socket closed (1006)');
      expect(h.log.lastError?.retryable, isTrue);
      expect(h.log.lastError?.aliveForMs, 5000);
      expect(h.controller.isWarm(), isFalse);
      expect(h.controller.isAvailable(), isFalse);

      // A fresh warm mints again and builds a new session.
      final p = h.controller.ensureWarm();
      await _tick();
      h.session.connect();
      await p;
      expect(h.mintCalls, 2);
      expect(h.createCalls, 2);
    });
  });

  group('HubController — A7c reconnect policy (B: strike-bounded re-warm)', () {
    test('a genuine failure arms a backoff and re-warms itself so the NEXT press is warm', () async {
      final h = _Harness();
      await _warmed(h); // connected at now=1000
      h.nowMs = 5000; // alive 4s (< idle window) -> a real failure, not an idle close

      h.session.fail('websocket closed (1011)', true, 1011);
      expect(h.controller.isAvailable(), isFalse);
      expect(h.clock.pending, isTrue);

      // The backoff elapses -> the controller re-warms itself with NO user press.
      h.clock.fire();
      await _tick();
      h.session.connect();
      expect(h.controller.isWarm(), isTrue);
      expect(h.mintCalls, 2);
    });

    test('caps re-warm attempts at the strike budget when the socket keeps failing before it connects', () async {
      final h = _Harness();
      final p = h.controller.ensureWarm();
      unawaited(p.catchError((Object _) => sid));
      await _tick(); // first session connecting

      var reWarms = 0;
      for (var i = 0; i < 12; i++) {
        await _failBeforeConnect(h); // never connected -> aliveForMs 0 -> a policy_fast strike
        if (!h.clock.pending) break;
        h.clock.fire();
        await _tick();
        reWarms++;
      }
      // MAX_RECONNECT_STRIKES = 5 re-warms allowed, then a dead endpoint stops
      // being hammered.
      expect(reWarms, 5);
      expect(h.clock.pending, isFalse);
    });

    test('does NOT keep re-warming forever once the strike budget runs out', () async {
      final h = _Harness();
      await _warmed(h); // socket connected at now=1000

      // A completed turn proves this is POST-COMMIT (and resets the strike
      // budget to 0), then the warm socket dies and the re-warm keeps
      // rebuilding and losing FAST (each attempt alive < the idle window),
      // so nothing resets the budget.
      h.session.events.onTurnDone?.call(null);

      var reWarms = 0;
      h.session.fail('websocket closed (1006)', true, 1006); // aliveForMs 0 -> a fast strike
      for (var i = 0; i < 12; i++) {
        if (!h.clock.pending) break; // budget exhausted -> re-warm stopped
        h.clock.fire();
        await _tick(); // next session connecting
        reWarms++;
        await _failBeforeConnect(h, 1006); // …and it dies before connecting -> another strike
      }

      expect(reWarms, 5);
      expect(h.clock.pending, isFalse);
    });

    test('a completed turn resets the strike budget (a bare connect does NOT)', () async {
      final h = _Harness();
      final p = h.controller.ensureWarm();
      unawaited(p.catchError((Object _) => sid));
      await _tick();

      // Bank 4 strikes via fail-before-connect.
      for (var i = 0; i < 4; i++) {
        await _failBeforeConnect(h);
        h.clock.fire();
        await _tick();
      }
      // Connecting alone must NOT refresh the budget; a completed turn must.
      h.session.connect();
      h.session.events.onTurnDone?.call(null);

      // Budget refreshed -> a fresh failure run gets the full 5 re-warms
      // again (would be only 1 if the 4 banked strikes had survived).
      var reWarms = 0;
      for (var i = 0; i < 12; i++) {
        await _failBeforeConnect(h);
        if (!h.clock.pending) break;
        h.clock.fire();
        await _tick();
        reWarms++;
      }
      expect(reWarms, 5);
    });

    test('a socket that survives past the idle window refreshes the strike budget', () async {
      final h = _Harness();
      final p = h.controller.ensureWarm();
      unawaited(p.catchError((Object _) => sid));
      await _tick();
      // Bank 4 strikes.
      for (var i = 0; i < 4; i++) {
        await _failBeforeConnect(h);
        h.clock.fire();
        await _tick();
      }
      // This attempt CONNECTS and survives past the idle window before
      // failing -> the long-lived socket proved the endpoint works, so the
      // budget resets (then spends 1).
      h.session.connect(); // connectedAt = now (1000)
      h.nowMs = 1000 + hubIdleTeardownThresholdMs + 1;
      h.session.fail('websocket closed (1011)', true, 1011);
      if (h.clock.pending) {
        h.clock.fire();
        await _tick();
      }
      // 4 more re-warms remain (a full budget of 5 minus the 1 just spent).
      var reWarms = 0;
      for (var i = 0; i < 12; i++) {
        await _failBeforeConnect(h);
        if (!h.clock.pending) break;
        h.clock.fire();
        await _tick();
        reWarms++;
      }
      expect(reWarms, 4);
    });
  });

  group('HubController — A7c reconnect policy (C: idle-teardown survival)', () {
    test('an expected idle-close proactively re-warms so isAvailable() is true BEFORE the next press', () async {
      final h = _Harness();
      await _warmed(h); // connected at now=1000
      h.nowMs = 1000 + hubIdleTeardownThresholdMs + 1; // long-lived, no active turn
      h.session.fail('websocket closed (1008)', true, 1008); // -> expectedIdleTeardown

      // The socket is gone, but the controller has armed a proactive re-warm
      // (no press).
      expect(h.controller.isAvailable(), isFalse);
      expect(h.clock.pending, isTrue);

      h.clock.fire();
      await _tick();
      // A session object now exists again BEFORE any press.
      expect(h.controller.isAvailable(), isTrue);
      h.session.connect();
      expect(h.controller.isWarm(), isTrue);
      expect(h.mintCalls, 2);
    });

    test('an idle teardown re-warms WITHOUT spending a strike (the failure budget stays full)', () async {
      final h = _Harness();
      await _warmed(h); // connected at now=1000
      // aliveFor EXACTLY the threshold: an idle teardown (classify uses
      // >=), but the >60s strike RESET (uses strict >) does NOT fire.
      h.nowMs = 1000 + hubIdleTeardownThresholdMs;
      h.session.fail('websocket closed (1008)', true, 1008);
      expect(h.clock.pending, isTrue);
      h.clock.fire();
      await _tick(); // session connecting (never connected -> no reset)

      // The idle close spent no strike, so the full failure budget of 5
      // remains.
      var reWarms = 0;
      for (var i = 0; i < 12; i++) {
        await _failBeforeConnect(h);
        if (!h.clock.pending) break;
        h.clock.fire();
        await _tick();
        reWarms++;
      }
      expect(reWarms, 5);
    });
  });

  group('HubController — circuit recovery (cooldown re-warm)', () {
    /// Drives the controller to strike exhaustion so the re-warm circuit
    /// trips OPEN. Returns the mint count at the moment it tripped.
    Future<int> tripCircuit(_Harness h) async {
      final p = h.controller.ensureWarm();
      unawaited(p.catchError((Object _) => sid));
      await _tick();
      // 5 fast re-warms are allowed, then the 6th fast death trips the circuit.
      for (var i = 0; i < 6; i++) {
        await _failBeforeConnect(h, 1006); // never connected -> aliveForMs 0 -> a strike
        if (h.clock.pending) {
          h.clock.fire();
          await _tick();
        }
      }
      return h.mintCalls;
    }

    test('opens the circuit when the strike budget is spent, then blocks warms during the cooldown', () async {
      final h = _Harness();
      await tripCircuit(h);

      // Tripped: nothing is re-warming.
      expect(h.clock.pending, isFalse);

      // During the cooldown a warm trigger is a no-op — the dead endpoint is
      // NOT rebuilt, so no new mint fires.
      await expectLater(h.controller.ensureWarm(), throwsA(isA<HubCircuitOpenError>()));
      expect(h.controller.isAvailable(), isFalse);
    });

    test('after the cooldown elapses, the next trigger attempts exactly ONE re-warm; a good probe closes the circuit',
        () async {
      final h = _Harness();
      final mintsAtTrip = await tripCircuit(h);

      // Cooldown elapses -> the next warm is allowed through as a single
      // half-open probe.
      h.nowMs += HubController.circuitCooldownMs;
      final p = h.controller.ensureWarm();
      unawaited(p.catchError((Object _) => sid));
      await _tick();
      expect(h.mintCalls, mintsAtTrip + 1); // exactly one re-warm

      // The probe connects and completes a turn -> strikes reset, circuit closed.
      h.session.connect();
      await p;
      h.session.events.onTurnDone?.call(null);
      expect(h.controller.isWarm(), isTrue);

      // A subsequent warm is a normal reuse now (circuit closed, no re-mint).
      final resolvedSid = await h.controller.ensureWarm();
      expect(resolvedSid, sid);
      expect(h.mintCalls, mintsAtTrip + 1);
    });

    test('a failed probe re-arms the cooldown for another cycle (no hot-loop)', () async {
      final h = _Harness();
      final mintsAtTrip = await tripCircuit(h);

      // First probe after the cooldown…
      h.nowMs += HubController.circuitCooldownMs;
      final p = h.controller.ensureWarm();
      unawaited(p.catchError((Object _) => sid));
      await _tick();
      expect(h.mintCalls, mintsAtTrip + 1);

      // …dies fast before connecting -> strikes still maxed -> circuit
      // re-opens WITHOUT arming an auto-reconnect (no hot-loop).
      await _failBeforeConnect(h, 1006);
      expect(h.clock.pending, isFalse);
      await expectLater(h.controller.ensureWarm(), throwsA(isA<HubCircuitOpenError>()));
      expect(h.mintCalls, mintsAtTrip + 1);

      // The new cooldown elapses -> exactly one more probe is allowed.
      h.nowMs += HubController.circuitCooldownMs;
      final q = h.controller.ensureWarm();
      unawaited(q.catchError((Object _) => sid));
      await _tick();
      expect(h.mintCalls, mintsAtTrip + 2);
    });

    test('an explicit teardownSession clears the open circuit so a later warm is unblocked', () async {
      final h = _Harness();
      await tripCircuit(h);

      // Sign-out / kill-switch off then back on: the circuit must not linger.
      h.controller.teardownSession();
      final before = h.mintCalls;
      final p = h.controller.ensureWarm(); // no cooldown wait — the circuit was reset
      unawaited(p.catchError((Object _) => sid));
      await _tick();
      expect(h.mintCalls, before + 1);
    });
  });

  group('HubControllerEvents.copyWith', () {
    // Guards the production wiring in `voice_hub_production.dart`, which
    // swaps ONE handler (tool calls go to the ask_claude executor) and must
    // pass the rest through. Hand-listing the fields there silently dropped
    // `onUserSpeechState` the day it was added — every other test still
    // passed, and only the on-screen indicator was dead.
    test('replaces onToolRequest and keeps every other handler alive', () {
      final seen = <String>[];
      final original = HubControllerEvents(
        onConnected: (sid) => seen.add('connected:$sid'),
        onError: (e) => seen.add('error:${e.reason}'),
        onInputTranscript: (t, f, i) => seen.add('in:$t'),
        onAssistantText: (t, f, i) => seen.add('out:$t'),
        onUserSpeechState: (speaking) => seen.add('vad:$speaking'),
        onSpeakingStart: () => seen.add('speak-start'),
        onSpeakingEnd: () => seen.add('speak-end'),
        onToolRequest: (call, i) => seen.add('tool-original:${call.name}'),
        onTurnDone: (i) => seen.add('turn-done'),
        onCascadeHandoff: (h) => seen.add('cascade'),
      );

      final copied = original.copyWith(onToolRequest: (call, i) => seen.add('tool-replaced:${call.name}'));

      copied.onConnected!('s1');
      copied.onError!(const HubControllerError(reason: 'boom', retryable: false, aliveForMs: 0));
      copied.onInputTranscript!('привет', false, null);
      copied.onAssistantText!('здравствуй', false, null);
      copied.onUserSpeechState!(true);
      copied.onSpeakingStart!();
      copied.onSpeakingEnd!();
      copied.onToolRequest!(const HubToolCallRequest(name: 'ask_claude', callId: 'c1', argumentsJson: '{}'), null);
      copied.onTurnDone!(null);
      copied.onCascadeHandoff!(const HubCascadeHandoff(frames: [], committed: false));

      expect(seen, [
        'connected:s1',
        'error:boom',
        'in:привет',
        'out:здравствуй',
        'vad:true',
        'speak-start',
        'speak-end',
        'tool-replaced:ask_claude',
        'turn-done',
        'cascade',
      ]);
    });

    test('without arguments it is a faithful copy — the original tool handler survives', () {
      final seen = <String>[];
      final original = HubControllerEvents(onToolRequest: (call, i) => seen.add('tool:${call.name}'));

      original.copyWith().onToolRequest!(
          const HubToolCallRequest(name: 'ask_claude', callId: 'c1', argumentsJson: '{}'), null);

      expect(seen, ['tool:ask_claude']);
    });
  });

  // Conversation resumption (design doc §10). What the controller owns is
  // narrow but load-bearing: the handle must outlive the SOCKET (that is the
  // whole point of the 180s idle release case) without outliving the
  // CONVERSATION, and a handle the server rejects must not keep poisoning
  // every retry.
  group('HubController — conversation resumption', () {
    test('the first session is built with no handle; a handle offered later reaches the next one', () async {
      final h = _Harness();
      await _warmed(h);
      expect(h.specHandles, [null]);

      h.session.events.onResumptionHandle?.call('H1');
      // The socket goes away (idle release) — the conversation must not.
      h.controller.teardownSession();
      await _warmed(h);
      expect(h.specHandles, [null, 'H1']);
    });

    test('a withdrawn handle (model was mid-reply) is not used', () async {
      final h = _Harness();
      await _warmed(h);
      h.session.events.onResumptionHandle?.call('H1');
      h.session.events.onResumptionHandle?.call(null);
      h.controller.teardownSession();
      await _warmed(h);
      expect(h.specHandles, [null, null]);
      expect(h.controller.canResumeConversation, isFalse);
    });

    test('a handle older than the TTL is dropped rather than resumed into', () async {
      final h = _Harness();
      await _warmed(h);
      h.session.events.onResumptionHandle?.call('H1');
      h.controller.teardownSession();
      h.nowMs = h.nowMs + HubController.resumptionHandleTtlMs + 1;
      await _warmed(h);
      expect(h.specHandles, [null, null]);
    });

    test('a handle just inside the TTL is still used', () async {
      final h = _Harness();
      await _warmed(h);
      h.session.events.onResumptionHandle?.call('H1');
      h.controller.teardownSession();
      h.nowMs = h.nowMs + HubController.resumptionHandleTtlMs - 1;
      await _warmed(h);
      expect(h.specHandles, [null, 'H1']);
    });

    test('a session that dies BEFORE connecting discards the handle it carried', () async {
      // Measured 24.08: a handle the server no longer knows closes the socket
      // with 1008 "session not found" at handshake. Keeping it would fail
      // every re-warm identically until the circuit opened.
      final h = _Harness();
      await _warmed(h);
      h.session.events.onResumptionHandle?.call('H1');
      h.controller.teardownSession();

      final p = h.controller.ensureWarm();
      unawaited(p.catchError((Object _) => sid));
      await _tick();
      expect(h.specHandles, [null, 'H1']); // built with the handle...
      await _failBeforeConnect(h);
      expect(h.controller.canResumeConversation, isFalse);

      await _warmed(h);
      expect(h.specHandles, [null, 'H1', null]); // ...and the retry goes blank
    });

    test('a session that dies AFTER connecting keeps the handle — the drop is not the handle\'s fault', () async {
      final h = _Harness();
      await _warmed(h);
      h.session.events.onResumptionHandle?.call('H1');
      h.controller.teardownSession();
      await _warmed(h); // connected fine while carrying H1
      h.session.events.onResumptionHandle?.call('H2');
      h.session.fail('mid-session drop', true, 1011);
      await _tick();
      expect(h.controller.canResumeConversation, isTrue);
      await _warmed(h);
      expect(h.specHandles.last, 'H2');
    });

    test('forgetConversation() ends the conversation, unlike teardownSession()', () async {
      final h = _Harness();
      await _warmed(h);
      h.session.events.onResumptionHandle?.call('H1');
      expect(h.controller.canResumeConversation, isTrue);
      h.controller.forgetConversation();
      expect(h.controller.canResumeConversation, isFalse);
      h.controller.teardownSession();
      await _warmed(h);
      expect(h.specHandles, [null, null]);
    });
  });
}
