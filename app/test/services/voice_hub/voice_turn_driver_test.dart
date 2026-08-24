// A 1:1-in-spirit port of the desktop (Electron/TS) test suite at
// `desktop/windows/src/renderer/src/lib/voice/turn/voiceHubTurnDriver.test.ts`
// (1168 lines), scoped to what `voice_turn_driver.dart` actually ported — see
// that file's own header for the full, individually-justified list of cuts.
// This file does NOT invent tests for code that was never ported. Per that
// file's header comment, the driver is exercised with a REAL `HubController`
// around a fake `createSession` (same pattern as `hub_controller_test.dart`'s
// own harness) so the controller's own warm-wait/reconnect logic runs for
// real, not re-mocked here.
//
// TS `describe` blocks NOT ported here, and why (all documented in
// `voice_turn_driver.dart`'s own header, not re-litigated):
//   * "orb projection (main -> bar)" — no `orbLevel`/levels-lane/bar-IPC
//     plumbing in this port; `VoiceTurnUiProjection` (already covered by
//     `voice_turn_reducer_test.dart`/`voice_turn_coordinator_test.dart`) has
//     no such field to project.
//   * "chat recording" (`onRecordTurn`/`onFinalText`/INV-CHAT-1) — no
//     chat-kernel seam; PLAN.md §3 defers it to a later session.
//   * "system-audio duck" (A4) — no Android analog.
//   * "cascade route (omniSTT)" / "warm-wait -> cascade fallback" / the
//     cascade half of "cascade release gate" — no second STT lane owned by
//     this driver (Android's GigaAM cascade is a separate stack); a
//     non-hub-route `begin()` cancels immediately instead (see the "flag off
//     / hub unavailable" group below, which covers that branch directly).
//   * "PR-C: the hub tool loop" richer scenarios (parallel calls, the
//     turn-epoch stale-result gate) — no tool catalog is ever declared to
//     the provider (`gemini_hub_session.dart`), so only the TS suite's own
//     "no executor wired" fallback case has a live analog here (ported
//     below as "hub tool loop (defensive fallback)").
//   * "release watchdog" — closed structurally by
//     `VoiceTurnCoordinator._contain` (already ported + tested), per that
//     file's header.
//   * "single-audible-owner (audibleOutputArbiter)" — no separate TTS output
//     in this driver's world to arbitrate against.
//   * `resamplePcm16`/`pcmPeakLevel`/`concatInt16`/`pcm16ToBytes` — none of
//     these helpers exist in the Dart file (no resampling, no orb loudness,
//     no cascade buffer); only `pcm16FromBytes` was ported, and is covered
//     below.
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:omi/services/voice_hub/hub_controller.dart';
import 'package:omi/services/voice_hub/hub_ptt_capture.dart';
import 'package:omi/services/voice_hub/hub_session.dart';
import 'package:omi/services/voice_hub/voice_turn_coordinator.dart';
import 'package:omi/services/voice_hub/voice_turn_driver.dart';
import 'package:omi/services/voice_hub/voice_turn_machine.dart';

// ---- fixtures ---------------------------------------------------------------

Future<void> _tick() => Future<void>.delayed(Duration.zero);

/// Manual deadline scheduler — same pattern as
/// `voice_turn_coordinator_test.dart`'s `ManualVoiceTurnScheduler` — so the
/// reducer's own bounded deadlines (`hintVisibility`, ...) fire on command
/// instead of a real timer.
class _ScheduledEntry {
  final VoiceTurnDeadline deadline;
  final void Function() fire;
  bool cancelled = false;
  _ScheduledEntry(this.deadline, this.fire);
}

class _ManualScheduler implements VoiceTurnDeadlineScheduling {
  final List<_ScheduledEntry> _scheduled = [];

  @override
  VoiceTurnDeadlineHandle schedule(VoiceTurnDeadline deadline, double afterSeconds, void Function() fire) {
    final entry = _ScheduledEntry(deadline, fire);
    _scheduled.add(entry);
    return VoiceTurnDeadlineHandle(() => entry.cancelled = true);
  }

  void fire(VoiceTurnDeadline deadline) {
    final index = _scheduled.indexWhere((e) => e.deadline == deadline && !e.cancelled);
    if (index < 0) return;
    final entry = _scheduled.removeAt(index);
    entry.fire();
  }
}

/// A fake provider session — mirrors `hub_controller_test.dart`'s own
/// `_FakeSession` (kept independent rather than shared, matching this
/// package's existing convention of one self-contained fixture set per test
/// file).
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
  int cleared = 0;
  int muted = 0;
  final List<({String callId, String output})> toolResults = [];

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

  @override
  bool isWarm() => warm;

  @override
  void beginTurn([HubBeginTurnOptions opts = const HubBeginTurnOptions()]) => begun.add(opts.interrupting);

  @override
  void appendAudio(Uint8List pcm) => appended.add(pcm);

  @override
  void commitTurn() => committed += 1;

  @override
  void cancelTurn() => cancelled += 1;

  @override
  void sendToolResult(String callId, String name, String output) => toolResults.add((callId: callId, output: output));

  @override
  void sendUserText(String text) {}

  @override
  void clearPlayback() => cleared += 1;

  @override
  void muteCurrentResponse() => muted += 1;

  @override
  void teardown() {
    toreDown += 1;
    warm = false;
  }
}

/// A fake mic capture handle: records whether `dispose()` was called.
class _FakeCapture implements HubPttCapture {
  bool disposed = false;
  @override
  void dispose() => disposed = true;
}

/// The `HubStartCapture` seam — records every capture started and lets the
/// test feed PCM16 chunks as raw little-endian bytes, mirroring
/// `NativeMicRecorderService.start(onByteReceived: ...)`.
class _CaptureHarness {
  void Function(Uint8List pcm)? onChunk;
  final List<_FakeCapture> started = [];

  HubStartCapture get start => (options) {
        onChunk = options.onChunk;
        final cap = _FakeCapture();
        started.add(cap);
        return Future.value(cap);
      };

  void feed(Int16List pcm) => onChunk?.call(pcm.buffer.asUint8List());
}

/// 1s of fully-voiced 16kHz PCM — passes the release gate (total >= 0.35s,
/// voiced >= 0.2s, peak above the dead-mic floor). Mirrors the TS suite's
/// `voiced1s()`.
Int16List _voiced1s() => Int16List.fromList(List.filled(16000, 8000));

/// A handful of loud samples — far under `minTotalAudioSec`, so any capture
/// always finalizes `tooShort`. Mirrors the TS suite's `loud()`.
Int16List _loud() => Int16List.fromList([0, 16000, -16000, 8000]);

/// 1s of low-level "room noise": total/peak clear the dead-mic floor, but
/// nothing crosses the voiced RMS threshold — a real hold with no speech.
Int16List _roomNoise() => Int16List.fromList(List.filled(16000, 100));

class _Harness {
  late final VoiceHubTurnDriver driver;
  late final HubController hub;
  final _CaptureHarness capture = _CaptureHarness();
  final _ManualScheduler scheduler = _ManualScheduler();
  final List<VoiceTurnUiProjection> projections = [];
  _FakeSession? _session;
  int _turnSeq = 0;
  int _captureSeq = 0;

  /// The live kill-switch pref, mirrors the TS harness's `pttHubEnabled`.
  bool pttHubEnabled;

  /// Overridable so "warm() swallows a rejected ensureWarm" can fail the
  /// mint without touching production wiring.
  Future<String> Function() mintTokenImpl = () async => 'ek_token';

  /// Injected `VoiceHubTurnDriverDeps.toolExecutor` — null by default so
  /// every existing test keeps exercising the defensive fallback
  /// unchanged; the "real executor wired" group below sets this.
  final void Function(HubToolCallRequest call)? toolExecutor;

  _Harness({this.pttHubEnabled = true, this.toolExecutor}) {
    driver = VoiceHubTurnDriver(VoiceHubTurnDriverDeps(
      createHub: (events) {
        final h = HubController(
          events: events,
          buildInstructions: () => 'INSTRUCTIONS',
          mintToken: () => mintTokenImpl(),
          createSession: (spec) {
            _session = _FakeSession('sess-1', spec.events);
            return _session!;
          },
        );
        hub = h;
        return h;
      },
      startCapture: capture.start,
      applyProjection: (p) => projections.add(p),
      pttHubEnabled: () => pttHubEnabled,
      toolExecutor: toolExecutor,
      scheduler: scheduler,
      mintTurnId: () => 'turn-${++_turnSeq}',
      mintCaptureId: () => ++_captureSeq,
    ));
  }

  _FakeSession get session {
    final s = _session;
    if (s == null) throw StateError('session not created yet');
    return s;
  }
}

/// Warms the driver's hub fully: `warm()` -> session created -> connected.
/// Mirrors the TS suite's `h.hub.setAvailability(true)` (a hub that is both
/// available AND warm).
Future<void> _warmed(_Harness h) async {
  h.driver.warm();
  await _tick();
  h.session.connect();
  await _tick();
}

/// Leaves the hub in the `hubWarmWait` shape: a session object exists
/// (`isAvailable()` true) but has not connected yet (`isWarm()` false).
/// Mirrors the TS suite's `h.hub.setAvailability(false, true)`.
Future<void> _sessionCreatedButNotConnected(_Harness h) async {
  h.driver.warm();
  await _tick();
}

/// Warms the underlying `HubController` DIRECTLY (bypassing
/// `driver.warm()`'s own `pttHubEnabled` gate) so a "flag off" test can prove
/// the kill-switch bypasses an ALREADY-warm hub, not merely a hub the driver
/// never bothered to warm.
Future<void> _warmedBypassingKillSwitch(_Harness h) async {
  unawaited(h.hub.ensureWarm());
  await _tick();
  h.session.connect();
  await _tick();
}

// ---- tests ------------------------------------------------------------------

void main() {
  group('kill-switch (flag off / hub unavailable)', () {
    test('with the flag off, begin() cancels immediately — no hub touched, no capture started', () async {
      final h = _Harness(pttHubEnabled: false);
      await _warmedBypassingKillSwitch(h); // even a warm hub must be bypassed when the flag is off
      h.driver.begin();

      expect(h.session.begun, isEmpty);
      // No cascade lane owns capture in this port (see file header) — a
      // non-hub route cancels the turn instead of starting a capture it
      // doesn't own.
      expect(h.capture.started, isEmpty);
      expect(h.driver.activeTurnId, isNull);
    });

    test('hub unavailable (never warmed) cancels immediately even with the flag on', () {
      final h = _Harness(pttHubEnabled: true);
      h.driver.begin();

      expect(h.capture.started, isEmpty);
      expect(h.driver.activeTurnId, isNull);
    });

    test('warm() is inert when the flag is off', () {
      final h = _Harness(pttHubEnabled: false);
      h.driver.warm();
      expect(h.hub.isAvailable(), isFalse);
    });

    test('warm() swallows a rejected ensureWarm (no unhandled rejection)', () async {
      // Eager warm is fire-and-forget; a mint failure must not leak as an
      // unhandled rejection — if warm() floated it, flutter_test would fail
      // this test outright (or the whole suite, via a stray zone error).
      final h = _Harness(pttHubEnabled: true);
      h.mintTokenImpl = () => Future<String>.error(StateError('mint failed'));
      h.driver.warm();
      await _tick();
      await _tick();
      expect(h.hub.isWarm(), isFalse);
    });
  });

  group('begin (flag on, hub warm)', () {
    test('starts a main-owned hub turn: capture issued here, hub.beginTurn called, orb listening', () async {
      final h = _Harness();
      await _warmed(h);
      h.driver.begin();

      expect(h.capture.started, hasLength(1));
      expect(h.session.begun, [false]);
      expect(h.projections.last.isListening, isTrue);

      await _tick();
      h.capture.feed(_loud());
      expect(h.session.appended, hasLength(1));
    });

    test('runs the full warm-hub turn through to a success terminal', () async {
      final h = _Harness();
      await _warmed(h);
      h.driver.begin();
      await _tick();
      h.capture.feed(_voiced1s()); // a real utterance — passes the hub release gate
      h.driver.end(); // finalize + commit
      expect(h.session.committed, 1);

      final ev = h.session.events;
      ev.onSpeakingStart?.call();
      ev.onTurnDone?.call(null);
      ev.onSpeakingEnd?.call(); // playbackDrained -> terminal(success)

      expect(h.driver.activeTurnId, isNull);
      expect(h.projections.last.isListening, isFalse);
    });
  });

  group('barge-in', () {
    test('every begin() unconditionally clears whatever the hub player has buffered', () async {
      final h = _Harness();
      await _warmed(h);
      h.driver.begin();
      expect(h.session.cleared, 1);
    });

    test('a superseding hold begins the hub turn interrupting:true, and clears again', () async {
      final h = _Harness();
      await _warmed(h);
      h.driver.begin();
      await _tick();
      h.driver.begin(); // a second hold while the first still owns the turn
      expect(h.session.begun, [false, true]);
      expect(h.session.cleared, 2);
    });
  });

  group('cold warm-wait: connecting later replays the deferred commit', () {
    test('a cold press defers the commit until the hub connects, then reaches success', () async {
      final h = _Harness();
      await _sessionCreatedButNotConnected(h); // hubWarmWait route
      h.driver.begin();
      await _tick();
      h.capture.feed(_voiced1s());
      h.driver.end(); // hubCommitDeferred (not warm yet)
      expect(h.session.committed, 0);

      h.session.connect(); // onConnected -> hubReady -> replays the deferred commit
      expect(h.session.committed, 1);

      final ev = h.session.events;
      ev.onSpeakingStart?.call();
      ev.onTurnDone?.call(null);
      ev.onSpeakingEnd?.call();
      expect(h.driver.activeTurnId, isNull);
      expect(h.projections.last.isListening, isFalse);
    });
  });

  // ---- hub release gate (the 2026-07-18 short-press wedge) ------------------
  // A 220-350ms press (or a release that beat capture spin-up) must ALWAYS
  // finalize deterministically at release, never commit a near-empty turn
  // the provider may never answer. Ported verbatim from the TS suite's own
  // "hub release gate" group — this is the ONE release-gate lane this port
  // has (see file header: the cascade lane's half of this TS group is cut).
  group('hub release gate (short/empty hub-owned captures)', () {
    test('a too-short hub press never commits: tooShort terminal, socket kept, next press fresh', () async {
      final h = _Harness();
      await _warmed(h);
      h.driver.begin();
      await _tick();
      h.capture.feed(_loud()); // 4 samples << MIN_TOTAL_AUDIO_SEC
      h.driver.end();

      // Never committed to the provider; the hub turn was abandoned (socket
      // kept) and per-turn ownership released.
      expect(h.session.committed, 0);
      expect(h.session.cancelled, 1); // cancelHub effect -> hub.cancelTurn
      expect(h.driver.activeTurnId, isNull);
      expect(h.projections.last.hint, 'Hold longer to record');
      expect(h.projections.last.isListening, isFalse);

      // The machine is free: the next press starts a fresh hub turn immediately.
      h.driver.begin();
      expect(h.session.begun, [false, false]);
      expect(h.projections.last.isListening, isTrue);
    });

    test('release racing capture spin-up (zero samples) finalizes tooShort and disposes the orphan mic', () async {
      final h = _Harness();
      await _warmed(h);
      h.driver.begin();
      // Release BEFORE the capture promise resolves — the exact wedged-press shape.
      h.driver.end();

      expect(h.session.committed, 0);
      expect(h.projections.last.hint, 'Hold longer to record');
      expect(h.projections.last.isListening, isFalse);

      // The late-resolving capture is an orphan and must be disposed, not leaked.
      await _tick();
      expect(h.capture.started.single.disposed, isTrue);

      // Next press starts fresh.
      h.driver.begin();
      expect(h.session.begun, [false, false]);
      expect(h.projections.last.isListening, isTrue);
    });

    test('a real hub hold with no speech is discarded quietly (silentRejected, no hint)', () async {
      final h = _Harness();
      await _warmed(h);
      h.driver.begin();
      await _tick();
      // 1s of low-level room noise: total >= 0.35s, peak above the dead-mic
      // floor, but nothing voiced.
      h.capture.feed(_roomNoise());
      h.driver.end();

      expect(h.session.committed, 0);
      expect(h.projections.every((p) => p.hint == ''), isTrue);
      expect(h.driver.activeTurnId, isNull);
    });

    test('a voiced hub press still commits (no regression on real speech)', () async {
      final h = _Harness();
      await _warmed(h);
      h.driver.begin();
      await _tick();
      h.capture.feed(_voiced1s());
      h.driver.end();
      expect(h.session.committed, 1);
    });
  });

  group('cancel', () {
    test('cancel terminates the turn and idles', () async {
      final h = _Harness();
      await _warmed(h);
      h.driver.begin();
      await _tick();
      h.driver.cancel();
      expect(h.session.cancelled, 1); // reducer cancelHub -> host -> hub.cancelTurn
      expect(h.driver.activeTurnId, isNull);
      expect(h.projections.last.isListening, isFalse);
    });

    test('cancel with no active turn is a no-op', () {
      final h = _Harness();
      // The coordinator's `configure()` already published one idle projection
      // at construction time (`VoiceTurnCoordinator.configure` — see that
      // file) — a no-op cancel() must not publish a second one.
      final countBeforeCancel = h.projections.length;
      expect(() => h.driver.cancel(), returnsNormally);
      expect(h.projections, hasLength(countBeforeCancel));
    });
  });

  // ---- post-commit provider death (A7c follow-up #1) -------------------------
  // A committed hub turn whose provider dies mid-reply must not end silently:
  // the reducer's terminal hint has to reach the projection (there is no
  // separate bar-state struct in this port — `applyProjection` IS the
  // reducer's own `VoiceTurnUiProjection`, `hint` field included), and it
  // auto-clears on the reducer's own `hintVisibility` deadline.
  group('post-commit provider death (A7c follow-up #1)', () {
    Future<void> driveToProviderDeath(_Harness h) async {
      await _warmed(h);
      h.driver.begin();
      await _tick();
      h.capture.feed(_voiced1s());
      h.driver.end();
      h.session.events.onError?.call('websocket closed (1008)', true, 1008);
    }

    test("projects the reducer's terminal hint (not a silent idle)", () async {
      final h = _Harness();
      await driveToProviderDeath(h);

      final last = h.projections.last;
      expect(last.isListening, isFalse);
      expect(last.hint, 'Voice response failed — try again');
      expect(h.driver.activeTurnId, isNull);
    });

    test("clears the hint when the reducer's hintVisibility deadline fires (auto-dismiss)", () async {
      final h = _Harness();
      await driveToProviderDeath(h);
      expect(h.projections.last.hint, 'Voice response failed — try again');

      h.scheduler.fire(VoiceTurnDeadline.hintVisibility);
      expect(h.projections.last.hint, '');
    });
  });

  // ---- hub tool loop (defensive fallback) -------------------------------------
  // No tool catalog is ever declared to the provider (`gemini_hub_session.dart`
  // — see its own header), so `onToolRequest` is dead in practice. It is
  // still wired defensively, exactly like the TS driver's "no executor
  // wired" fallback: reply with an error string immediately, never dispatch
  // `toolStarted`, so a hypothetical future stray call can never hang a turn.
  group('hub tool loop (defensive fallback)', () {
    test('a spoken tool request is answered immediately with an error and never blocks the turn', () async {
      final h = _Harness();
      await _warmed(h);
      h.driver.begin();
      await _tick();
      h.capture.feed(_voiced1s());
      h.driver.end();

      h.session.events.onToolRequest?.call(
        const HubToolCallRequest(name: 'list_agent_sessions', callId: 'call-1', argumentsJson: '{}'),
        null,
      );
      expect(h.session.toolResults, [(callId: 'call-1', output: 'Error: tools are not available')]);

      // The turn is not stuck awaiting a tool result — it completes normally.
      final ev = h.session.events;
      ev.onSpeakingStart?.call();
      ev.onTurnDone?.call(null);
      ev.onSpeakingEnd?.call();
      expect(h.driver.activeTurnId, isNull);
    });
  });

  // ---- hub tool loop (real executor wired) ------------------------------------
  // `VoiceHubTurnDriverDeps.toolExecutor` — a production caller that DOES
  // declare a real tool catalog (`fetchTools`) wires this to something that
  // actually resolves the call (e.g. `AskClaudeToolExecutor.handle`,
  // `ask_claude_tool.dart`). The defensive fallback above must NOT also fire
  // — that would send two results for the same `callId`.
  group('hub tool loop (real executor wired)', () {
    test('a spoken tool request is handed to the injected executor instead of the defensive fallback', () async {
      final calls = <HubToolCallRequest>[];
      final h = _Harness(toolExecutor: calls.add);
      await _warmed(h);
      h.driver.begin();
      await _tick();
      h.capture.feed(_voiced1s());
      h.driver.end();

      const call = HubToolCallRequest(name: 'ask_claude', callId: 'call-1', argumentsJson: '{"question":"hi"}');
      h.session.events.onToolRequest?.call(call, null);

      expect(calls, [call]);
      expect(h.session.toolResults, isEmpty);
    });

    test('the executor, not the driver, is responsible for eventually calling sendToolResult', () async {
      late final _Harness h;
      h = _Harness(toolExecutor: (call) => h.hub.sendToolResult(call.callId, call.name, 'real answer'));
      await _warmed(h);
      h.driver.begin();
      await _tick();
      h.capture.feed(_voiced1s());
      h.driver.end();

      h.session.events.onToolRequest?.call(
        const HubToolCallRequest(name: 'ask_claude', callId: 'call-1', argumentsJson: '{"question":"hi"}'),
        null,
      );

      expect(h.session.toolResults, [(callId: 'call-1', output: 'real answer')]);
    });
  });

  // ---- dispose (resetVoicePlane) ----------------------------------------------
  group('dispose (resetVoicePlane)', () {
    test('mid-recording: releases capture + socket, publishes idle, and is inert after', () async {
      final h = _Harness();
      await _warmed(h);
      h.driver.begin();
      await _tick();
      h.capture.feed(_voiced1s());

      h.driver.dispose();

      expect(h.capture.started.single.disposed, isTrue);
      expect(h.session.toreDown, 1);
      final last = h.projections.last;
      expect(last.isListening, isFalse);

      // A disposed driver never runs again: no new capture, no warm.
      h.driver.begin();
      expect(h.capture.started, hasLength(1));
      h.driver.warm();
      expect(h.hub.isAvailable(), isFalse);
    });

    test('mid-reply (playing): the stopPlayback effect still clears the hub player, then everything releases',
        () async {
      final h = _Harness();
      await _warmed(h);
      h.driver.begin();
      await _tick();
      h.capture.feed(_voiced1s());
      h.driver.end();
      h.session.events.onSpeakingStart?.call();

      final clearedBefore = h.session.cleared;
      h.driver.dispose();

      // The cleanup terminal's stopPlayback effect reached the same
      // clearPlayback seam begin() uses (no separate TTS player in this port).
      expect(h.session.cleared, greaterThan(clearedBefore));
      expect(h.session.toreDown, 1);
      expect(h.driver.activeTurnId, isNull);
    });

    test('idle: dispose is safe and idempotent', () {
      final h = _Harness();
      expect(() {
        h.driver.dispose();
        h.driver.dispose();
      }, returnsNormally);
      expect(() => h.session, throwsA(isA<StateError>())); // never warmed -> never created
    });

    test('after a reset, a FRESH driver runs a full turn to success (working plane)', () async {
      final old = _Harness();
      await _warmed(old);
      old.driver.begin();
      await _tick();
      old.driver.dispose();

      // The host swaps in a fresh driver (mirrors VoiceHubDriverHost.onVoicePlaneReset).
      final h = _Harness();
      await _warmed(h);
      h.driver.begin();
      await _tick();
      h.capture.feed(_voiced1s());
      h.driver.end();
      final ev = h.session.events;
      ev.onSpeakingStart?.call();
      ev.onTurnDone?.call(null);
      ev.onSpeakingEnd?.call();
      expect(h.driver.activeTurnId, isNull);
      expect(h.projections.last.isListening, isFalse);
    });
  });

  // ---- pure PCM helper --------------------------------------------------------
  group('pcm16FromBytes', () {
    test('reinterprets little-endian PCM16 bytes as samples', () {
      final src = Int16List.fromList([1, -1, 1000, -1000]);
      final bytes = src.buffer.asUint8List();
      expect(pcm16FromBytes(bytes), orderedEquals(src));
    });

    test('drops a trailing odd byte instead of throwing', () {
      // 5 bytes -> samples [1, 2] (little-endian) + one orphan byte dropped.
      final bytes = Uint8List.fromList([1, 0, 2, 0, 0xFF]);
      final result = pcm16FromBytes(bytes);
      expect(result, orderedEquals(Int16List.fromList([1, 2])));
    });
  });
}
