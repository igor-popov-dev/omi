// A 1:1-in-spirit port of the desktop (Electron/TS) test suite at
// `desktop/windows/src/renderer/src/lib/voice/turn/voiceTurnCoordinator.test.ts`
// (itself a port of macOS `VoiceTurnCoordinatorTests.swift`, 14 cases, plus
// Windows-only additions for route-aware deadlines, the production
// `Timer`-backed scheduler, and drain-robustness/timeline-tap coverage).
// Test names/descriptions are kept as close to the upstream text as
// possible — each one documents an invariant of the drain/timer model, and
// a renamed test is an invariant nobody can trace back to the reference.
//
// Three deliberate adaptations vs. the TS source, all driven by cuts already
// made (and documented) in `voice_turn_coordinator.dart` itself — this file
// does NOT invent tests for code that was never ported:
//   * `expandsBarForVoice` does not exist in the Dart port (no desktop
//     overlay pill on Android — see that file's header "scope cuts").
//     `testPresenterDerivesConsistentListeningThinkingAndTerminalUI` asserts
//     the same underlying condition (`isListening || hint != ''`) directly
//     instead of calling a ported helper.
//   * `VoiceTurnPresenter` is a bare `void Function(VoiceTurnUiProjection)`
//     here, not a TS-style `{apply(projection)}` object, so
//     `RecordingPresenter` below exposes a plain method torn off at the call
//     site instead of an object literal.
//   * The "production scheduler" group uses `package:fake_async`
//     (`fakeAsync`/`async.elapse`) in place of `vi.useFakeTimers()` /
//     `vi.advanceTimersByTime()` — the Dart-idiomatic way to drive a real
//     `Timer`-backed scheduler deterministically. `TimerVoiceTurnScheduler`
//     wraps `dart:async`'s `Timer`, so no extra seam is needed for this.
//
// No throwing-handler test needs a `console.error` spy: `_contain()` in the
// Dart coordinator does not log to begin with (it only optionally reports to
// an injected `VoiceTurnDiagnostics`), so there is nothing to suppress.
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:omi/services/voice_hub/voice_turn_coordinator.dart';
import 'package:omi/services/voice_hub/voice_turn_machine.dart';

// ---- fixtures --------------------------------------------------------------

int _seq = 0;
VoiceTurnId _newTurnId() => 'turn-${++_seq}';
VoiceSessionId _newSessionId() => 'session-${++_seq}';
VoiceCaptureId _capture(int n) => n;

/// Port of Swift's `ManualVoiceTurnScheduler` — the fake clock.
class _ScheduledEntry {
  final VoiceTurnDeadline deadline;
  final double afterSeconds;
  final void Function() fire;
  bool cancelled = false;
  _ScheduledEntry(this.deadline, this.afterSeconds, this.fire);
}

class ManualVoiceTurnScheduler implements VoiceTurnDeadlineScheduling {
  final List<_ScheduledEntry> _scheduled = [];

  @override
  VoiceTurnDeadlineHandle schedule(VoiceTurnDeadline deadline, double afterSeconds, void Function() fire) {
    final entry = _ScheduledEntry(deadline, afterSeconds, fire);
    _scheduled.add(entry);
    return VoiceTurnDeadlineHandle(() => entry.cancelled = true);
  }

  int get activeCount => _scheduled.where((e) => !e.cancelled).length;

  /// Fires the oldest live timer for this deadline; a no-op if it was
  /// cancelled (or never scheduled).
  void fire(VoiceTurnDeadline deadline) {
    final index = _scheduled.indexWhere((e) => e.deadline == deadline && !e.cancelled);
    if (index < 0) return;
    final entry = _scheduled.removeAt(index);
    entry.fire();
  }

  double? delayFor(VoiceTurnDeadline deadline) {
    for (final e in _scheduled) {
      if (e.deadline == deadline && !e.cancelled) return e.afterSeconds;
    }
    return null;
  }
}

({ManualVoiceTurnScheduler scheduler, VoiceTurnCoordinator coordinator}) _manual() {
  final scheduler = ManualVoiceTurnScheduler();
  return (scheduler: scheduler, coordinator: VoiceTurnCoordinator(scheduler: scheduler, mintTurnId: _newTurnId));
}

/// A fake bar store: the presenter port, recording every projection it is
/// given.
class RecordingPresenter {
  final List<VoiceTurnUiProjection> projections = [];
  void apply(VoiceTurnUiProjection projection) => projections.add(projection);
  VoiceTurnUiProjection get last => projections.last;
}

/// Port of `RealtimeHubWarmWaitResolutionGate` (macOS
/// `PushToTalkManager.swift:40`) — inlined here exactly as the TS test
/// inlines it, purely as test-fixture plumbing for
/// `testHubReadyTransitionIsConsumedBeforeReentrantSnapshot`.
class RealtimeHubWarmWaitResolutionGate {
  VoiceTurnRoute? route;
  bool observe(VoiceTurnRoute? nextRoute) {
    final wasWaitingForHub = route is VoiceTurnRouteHubWarmWait;
    route = nextRoute;
    return wasWaitingForHub && nextRoute is VoiceTurnRouteHub;
  }
}

List<VoiceTurnTerminalRecord> _terminalsOf(List<VoiceTurnEffect> effects) =>
    effects.whereType<VoiceTurnEffectTerminal>().map((e) => e.record).toList();

// ---- ported Swift cases -----------------------------------------------------

void main() {
  group('VoiceTurnCoordinator (port of VoiceTurnCoordinatorTests.swift)', () {
    test('testFakeClockDrivesLockDeadlineAndRealStopCaptureEffect', () {
      final m = _manual();
      final effects = <VoiceTurnEffect>[];
      m.coordinator.setEffectHandler(effects.add);
      final turnId = m.coordinator.begin(VoiceTurnIntent.hold);
      m.coordinator.send(VoiceTurnEventCaptureStarted(turnId: turnId, captureId: _capture(1)));
      m.coordinator.send(VoiceTurnEventOpenLockWindow(turnId: turnId));

      m.scheduler.fire(VoiceTurnDeadline.lockDecision);

      expect(m.coordinator.model.turn?.phase, const VoiceTurnPhaseFinalizing());
      expect(effects, contains(VoiceTurnEffectStopCapture(turnId: turnId, captureId: _capture(1))));
    });

    test('testCancelledDeadlineCannotMutateLaterTurn', () {
      final m = _manual();
      final oldTurn = m.coordinator.begin(VoiceTurnIntent.hold);
      m.coordinator.send(VoiceTurnEventOpenLockWindow(turnId: oldTurn));
      final newTurn = m.coordinator.begin(VoiceTurnIntent.hold);

      m.scheduler.fire(VoiceTurnDeadline.lockDecision);

      expect(m.coordinator.activeTurnId, newTurn);
      expect(m.coordinator.model.turn?.phase, const VoiceTurnPhaseRecording());
    });

    test('testTimelineReconstructsTurnAndIsBounded', () {
      final coordinator = VoiceTurnCoordinator(
        scheduler: ManualVoiceTurnScheduler(),
        mintTurnId: _newTurnId,
        timelineLimit: 4,
      );
      final turnId = coordinator.begin(VoiceTurnIntent.hold);
      coordinator.send(VoiceTurnEventCaptureStarted(turnId: turnId, captureId: _capture(1)));
      coordinator.send(VoiceTurnEventSelectRoute(turnId: turnId, route: const VoiceTurnRouteDeepgramBatch()));
      coordinator.send(VoiceTurnEventFinalize(turnId: turnId));
      coordinator.send(VoiceTurnEventTranscriptionStarted(turnId: turnId));

      final timeline = coordinator.timelineSnapshot();
      expect(timeline.length, 4);
      expect(timeline.last.turnId, turnId);
      expect(timeline.last.phaseAfter, const VoiceTurnPhaseFinalizing());
      expect(timeline.last.route, const VoiceTurnRouteDeepgramBatch());
    });

    // Adapted (see file header): no ported `expandsBarForVoice` on Android —
    // asserts the same underlying condition (macOS's expand rule,
    // `isListening || hint != ''`) directly against the projection instead.
    test('testPresenterDerivesConsistentListeningThinkingAndTerminalUI', () {
      final m = _manual();
      final presenter = RecordingPresenter();
      m.coordinator.configure(presenter.apply);
      final turnId = m.coordinator.begin(VoiceTurnIntent.hold);
      expect(presenter.last.isListening, isTrue);
      expect(presenter.last.isThinking, isFalse);

      m.coordinator.send(VoiceTurnEventSelectRoute(turnId: turnId, route: const VoiceTurnRouteDeepgramBatch()));
      m.coordinator.send(VoiceTurnEventFinalize(turnId: turnId));
      m.coordinator.send(VoiceTurnEventTranscriptionStarted(turnId: turnId));
      expect(presenter.last.isListening, isFalse);
      expect(presenter.last.isThinking, isTrue);
      expect(presenter.last.transcript, 'Transcribing…');

      m.coordinator.send(VoiceTurnEventTranscriptionFailed(turnId: turnId, message: 'fixture'));
      // The capture/listening phase is over, but the pill's would-be expand
      // rule keeps the terminal hint visible long enough for the user to see
      // it.
      expect(presenter.last.isListening || presenter.last.hint != '', isTrue);
      expect(presenter.last.isListening, isFalse);
      expect(presenter.last.isThinking, isFalse);
      expect(presenter.last.isResponseActive, isFalse);
      expect(presenter.last.hint, "Couldn't transcribe that — try again");
    });

    test('testTerminalEffectAndCleanupAreExactlyOnce', () {
      final m = _manual();
      final terminals = <VoiceTurnTerminalRecord>[];
      m.coordinator.setEffectHandler((effect) {
        if (effect is VoiceTurnEffectTerminal) terminals.add(effect.record);
      });
      final turnId = m.coordinator.begin(VoiceTurnIntent.hold);

      m.coordinator.send(VoiceTurnEventCancel(turnId: turnId, reason: VoiceTurnTerminalReason.cancelled));
      m.coordinator.send(VoiceTurnEventFinish(turnId: turnId, reason: VoiceTurnTerminalReason.providerFailed));

      expect(terminals, [
        VoiceTurnTerminalRecord(
          turnId: turnId,
          reason: VoiceTurnTerminalReason.cancelled,
          route: const VoiceTurnRouteUndecided(),
        ),
      ]);
      expect(m.coordinator.model.duplicateTerminalCount, 1);
    });

    test('testUnscopedPlaybackUsesPresenterButCannotOverrideActivePTTTurn', () {
      final m = _manual();
      final presenter = RecordingPresenter();
      m.coordinator.configure(presenter.apply);

      m.coordinator.setUnscopedResponseActive(true);
      expect(presenter.last.isResponseActive, isTrue);
      m.coordinator.setUnscopedResponseActive(false);
      expect(presenter.last.isResponseActive, isFalse);

      final turnId = m.coordinator.begin(VoiceTurnIntent.hold);
      m.coordinator.send(VoiceTurnEventSelectRoute(turnId: turnId, route: const VoiceTurnRouteDeepgramBatch()));
      m.coordinator.send(VoiceTurnEventFinalize(turnId: turnId));
      m.coordinator.send(VoiceTurnEventTranscriptionStarted(turnId: turnId));
      m.coordinator.send(VoiceTurnEventTranscriptionFinal(turnId: turnId, text: 'hello'));
      m.coordinator.send(VoiceTurnEventProviderResponseStarted(turnId: turnId, sessionId: null, responseId: null));
      expect(presenter.last.isResponseActive, isTrue);

      m.coordinator.setUnscopedResponseActive(false);
      expect(presenter.last.isResponseActive, isTrue);
    });

    test('testSnapshotHandlerReceivesInitialAndSubsequentAuthoritativeModels', () {
      final m = _manual();
      final snapshots = <VoiceTurnModel>[];
      m.coordinator.setSnapshotHandler(snapshots.add);

      final turnId = m.coordinator.begin(VoiceTurnIntent.hold);
      m.coordinator.send(VoiceTurnEventLock(turnId: turnId));

      // `VoiceTurnModel` has no value equality (see voice_turn_machine.dart
      // header); the initial snapshot is literally the canonicalized
      // `idleVoiceTurnModel` const, so identity is the right — and stronger
      // — check here (mirrors the TS `toEqual(IDLE_VOICE_TURN_MODEL)`).
      expect(identical(snapshots.first, idleVoiceTurnModel), isTrue);
      expect(snapshots.last.turn?.phase, const VoiceTurnPhaseLockedRecording());
      expect(snapshots.length, 3);
    });

    test('testHubReadyTransitionIsConsumedBeforeReentrantSnapshot', () {
      final m = _manual();
      final sessionId = _newSessionId();
      final gate = RealtimeHubWarmWaitResolutionGate();
      var resolutions = 0;
      m.coordinator.setSnapshotHandler((model) {
        if (!gate.observe(model.turn?.route)) return;
        resolutions += 1;
        final activeTurnId = m.coordinator.activeTurnId;
        expect(activeTurnId, isNotNull, reason: 'hub-ready transition must retain its active turn');
        // The hub controller clears its response glow synchronously on
        // beginTurn, which publishes another snapshot. The consumed
        // transition must not run the warm-wait resolver again.
        m.coordinator.send(VoiceTurnEventResponseActiveChanged(turnId: activeTurnId!, active: false));
      });

      final turnId = m.coordinator.begin(VoiceTurnIntent.hold);
      m.coordinator.send(VoiceTurnEventSelectRoute(turnId: turnId, route: const VoiceTurnRouteHubWarmWait()));
      m.coordinator.send(VoiceTurnEventHubReady(turnId: turnId, sessionId: sessionId));

      expect(resolutions, 1);
      expect(gate.route, VoiceTurnRouteHub(sessionId));
    });

    test('testSnapshotReentrantEventsDrainFIFOWithoutRecursiveCallbacks', () {
      final m = _manual();
      var callbackDepth = 0;
      var maximumCallbackDepth = 0;
      var queuedRouteSelection = false;

      m.coordinator.setSnapshotHandler((model) {
        callbackDepth += 1;
        if (callbackDepth > maximumCallbackDepth) maximumCallbackDepth = callbackDepth;
        try {
          final turn = model.turn;
          if (queuedRouteSelection || turn == null || turn.phase is! VoiceTurnPhaseRecording) return;
          queuedRouteSelection = true;
          m.coordinator.send(VoiceTurnEventSelectRoute(turnId: turn.id, route: const VoiceTurnRouteDeepgramBatch()));

          expect(
            m.coordinator.model.turn?.route,
            const VoiceTurnRouteUndecided(),
            reason: 'a nested event must not mutate the model until the current snapshot returns',
          );
        } finally {
          callbackDepth -= 1;
        }
      });

      final turnId = m.coordinator.begin(VoiceTurnIntent.hold);

      expect(maximumCallbackDepth, 1);
      expect(m.coordinator.model.turn?.route, const VoiceTurnRouteDeepgramBatch());
      final timeline = m.coordinator.timelineSnapshot();
      expect(timeline.sublist(timeline.length - 2).map((e) => e.event).toList(), ['start', 'select_route']);
      expect(m.coordinator.activeTurnId, turnId);
    });

    test('testEffectReentrantTerminalEventRunsAfterCurrentEffectReturns', () {
      final m = _manual();
      final turnId = m.coordinator.begin(VoiceTurnIntent.hold);
      final captureId = _capture(91);
      m.coordinator.send(VoiceTurnEventCaptureStarted(turnId: turnId, captureId: captureId));

      var callbackDepth = 0;
      var maximumCallbackDepth = 0;
      var queuedCancellation = false;
      final effects = <VoiceTurnEffect>[];
      m.coordinator.setEffectHandler((effect) {
        callbackDepth += 1;
        if (callbackDepth > maximumCallbackDepth) maximumCallbackDepth = callbackDepth;
        effects.add(effect);
        try {
          final isStopCapture =
              effect is VoiceTurnEffectStopCapture && effect.turnId == turnId && effect.captureId == captureId;
          if (queuedCancellation || !isStopCapture) return;
          queuedCancellation = true;
          m.coordinator.send(VoiceTurnEventCancel(turnId: turnId, reason: VoiceTurnTerminalReason.cancelled));

          expect(
            m.coordinator.model.turn?.phase,
            const VoiceTurnPhaseFinalizing(),
            reason: 'a nested terminal event must wait until the current effect returns',
          );
        } finally {
          callbackDepth -= 1;
        }
      });

      m.coordinator.send(VoiceTurnEventFinalize(turnId: turnId));

      expect(maximumCallbackDepth, 1);
      expect(m.coordinator.model.turn?.phase, const VoiceTurnPhaseTerminal(VoiceTurnTerminalReason.cancelled));
      expect(_terminalsOf(effects), [
        VoiceTurnTerminalRecord(
          turnId: turnId,
          reason: VoiceTurnTerminalReason.cancelled,
          route: const VoiceTurnRouteUndecided(),
        ),
      ]);
      final timeline = m.coordinator.timelineSnapshot();
      expect(timeline.sublist(timeline.length - 2).map((e) => e.event).toList(), ['finalize', 'cancel']);
    });

    test('testResetCancelsOutstandingDeadlinesAndReturnsPresentationToIdle', () {
      final m = _manual();
      final presenter = RecordingPresenter();
      m.coordinator.configure(presenter.apply);
      m.coordinator.begin(VoiceTurnIntent.hold);
      expect(presenter.last.isListening, isTrue);
      expect(m.scheduler.activeCount, greaterThan(0));

      m.coordinator.reset();

      expect(m.coordinator.activeTurn, isNull);
      expect(m.coordinator.model.turn, isNull);
      expect(presenter.last.isListening, isFalse);
      expect(m.scheduler.activeCount, 0);
    });

    test('testStaleAndInvalidTransitionsRemainObservableEffects', () {
      final m = _manual();
      final effects = <VoiceTurnEffect>[];
      m.coordinator.setEffectHandler(effects.add);
      final turnId = m.coordinator.begin(VoiceTurnIntent.hold);

      m.coordinator.send(VoiceTurnEventFinalize(turnId: _newTurnId()));
      m.coordinator.send(VoiceTurnEventHubCommitAccepted(turnId: turnId, sessionId: _newSessionId(), responseId: null));

      expect(effects.any((effect) => effect is VoiceTurnEffectStaleEventDropped), isTrue);
      expect(effects.any((effect) => effect is VoiceTurnEffectInvalidTransition), isTrue);
      expect(m.coordinator.model.staleEventCount, 1);
      expect(m.coordinator.model.invalidTransitionCount, 1);
    });

    test('testDiagnosticLabelsAreStableAndLowCardinality', () {
      expect(voiceTurnPhaseLabel(const VoiceTurnPhaseIdle()), 'idle');
      expect(voiceTurnPhaseLabel(const VoiceTurnPhasePendingLockDecision()), 'pending_lock_decision');
      expect(voiceTurnPhaseLabel(const VoiceTurnPhaseRecording()), 'recording');
      expect(voiceTurnPhaseLabel(const VoiceTurnPhaseLockedRecording()), 'locked_recording');
      expect(voiceTurnPhaseLabel(const VoiceTurnPhaseFinalizing()), 'finalizing');
      expect(voiceTurnPhaseLabel(const VoiceTurnPhaseAwaitingResponse()), 'awaiting_response');
      expect(voiceTurnPhaseLabel(const VoiceTurnPhaseAwaitingTools()), 'awaiting_tools');
      expect(voiceTurnPhaseLabel(const VoiceTurnPhasePlaying(VoiceOutputLane.filler)), 'playing_filler');
      expect(
        voiceTurnPhaseLabel(const VoiceTurnPhaseTerminal(VoiceTurnTerminalReason.providerFailed)),
        'terminal_provider_failed',
      );

      expect(voiceTurnRouteLabel(const VoiceTurnRouteUndecided()), 'undecided');
      expect(voiceTurnRouteLabel(const VoiceTurnRouteHubWarmWait()), 'hub_warm_wait');
      expect(voiceTurnRouteLabel(VoiceTurnRouteHub(_newSessionId())), 'hub');
      expect(voiceTurnRouteLabel(const VoiceTurnRouteOmniStt()), 'omni_stt');
      expect(voiceTurnRouteLabel(const VoiceTurnRouteDeepgramBatch()), 'deepgram_batch');
      expect(voiceTurnRouteLabel(const VoiceTurnRouteDeepgramLive()), 'deepgram_live');
      expect(voiceTurnRouteLabel(const VoiceTurnRouteAgentFollowUp()), 'agent_follow_up');
    });

    test('testTimelineNeverStoresAssociatedSpeechPayloads', () {
      final m = _manual();
      const marker = 'secret-timeline-marker-442';
      final turnId = m.coordinator.begin(VoiceTurnIntent.hold);
      m.coordinator.send(VoiceTurnEventTranscriptChanged(turnId: turnId, text: marker));
      m.coordinator.send(VoiceTurnEventPlaybackFailed(turnId: _newTurnId(), leaseId: null, message: marker));

      final events = m.coordinator.timelineSnapshot().map((e) => e.event).toList();
      expect(events, contains('transcript_changed'));
      expect(events, contains('playback_failed'));
      expect(events.join(), isNot(contains(marker)));
      // No `JSON.stringify(timeline)` analogue: `VoiceTurnTimelineEntry`
      // holds no freeform string field besides the already-checked bounded
      // `event` label (turnId/phase/route/terminalReason/counts are all
      // closed enums or identifiers), so there is no second payload surface
      // to re-check here.
    });
  });

  group('VoiceTurnCoordinator — route-aware deadlines (decision D2)', () {
    test('gives the shipped omniSTT cascade its 20s transcription budget, not Mac 12s', () {
      expect(defaultVoiceTurnDeadlines.transcription, 12);
      expect(cascadeVoiceTurnDeadlines.transcription, 20);
      expect(identical(deadlinesForVoiceTurnRoute(const VoiceTurnRouteHub(null)), defaultVoiceTurnDeadlines), isTrue);
      expect(identical(deadlinesForVoiceTurnRoute(const VoiceTurnRouteOmniStt()), cascadeVoiceTurnDeadlines), isTrue);

      final m = _manual();
      final turnId = m.coordinator.begin(VoiceTurnIntent.hold);
      m.coordinator.send(VoiceTurnEventSelectRoute(turnId: turnId, route: const VoiceTurnRouteOmniStt()));
      m.coordinator.send(VoiceTurnEventFinalize(turnId: turnId));
      m.coordinator.send(VoiceTurnEventTranscriptionStarted(turnId: turnId));

      expect(m.scheduler.delayFor(VoiceTurnDeadline.transcription), 20);
    });

    test('arms the CASCADE transcription budget when hub-warm times out mid-turn', () {
      // The hubWarm deadline hands the buffered PCM to the cascade and the
      // turn SURVIVES — so the transcription deadline it arms in that same
      // reduce must be the cascade's 20s, not the hub route's 12s.
      final m = _manual();
      final effects = <VoiceTurnEffect>[];
      m.coordinator.setEffectHandler(effects.add);
      final turnId = m.coordinator.begin(VoiceTurnIntent.hold);
      m.coordinator.send(VoiceTurnEventSelectRoute(turnId: turnId, route: const VoiceTurnRouteHubWarmWait()));
      m.coordinator.send(VoiceTurnEventFinalize(turnId: turnId));

      m.scheduler.fire(VoiceTurnDeadline.hubWarm);

      expect(
        effects,
        contains(
          VoiceTurnEffectFallbackToTranscription(turnId: turnId, reason: VoiceTurnTerminalReason.hubWarmTimeout),
        ),
      );
      expect(m.coordinator.model.turn?.route, const VoiceTurnRouteDeepgramBatch());
      expect(m.coordinator.model.turn?.phase, const VoiceTurnPhaseFinalizing());
      expect(m.scheduler.delayFor(VoiceTurnDeadline.transcription), 20);
    });
  });

  group('VoiceTurnCoordinator — production scheduler', () {
    test('fires deadlineFired through a real Timer at the scheduled delay', () {
      fakeAsync((async) {
        final coordinator = VoiceTurnCoordinator(scheduler: const TimerVoiceTurnScheduler(), mintTurnId: _newTurnId);
        coordinator.begin(VoiceTurnIntent.hold); // arms captureStart at 3s

        async.elapse(const Duration(milliseconds: 2999));
        expect(coordinator.model.turn?.phase, const VoiceTurnPhaseRecording());

        async.elapse(const Duration(milliseconds: 1));
        expect(coordinator.model.turn?.phase, const VoiceTurnPhaseTerminal(VoiceTurnTerminalReason.captureFailed));
      });
    });

    test('re-arming a held deadline cancels the prior handle', () {
      // `hintChanged` re-schedules `hintVisibility` on every hint. If the
      // coordinator kept the old handle, it would fire 2s after the FIRST
      // hint — clearing the second hint early and delivering a
      // `deadlineFired` the reducer counts stale.
      fakeAsync((async) {
        final coordinator = VoiceTurnCoordinator(scheduler: const TimerVoiceTurnScheduler(), mintTurnId: _newTurnId);
        final turnId = coordinator.begin(VoiceTurnIntent.hold);
        coordinator.send(VoiceTurnEventCaptureStarted(turnId: turnId, captureId: _capture(3)));
        coordinator.send(VoiceTurnEventHintChanged(turnId: turnId, text: 'first'));

        async.elapse(const Duration(milliseconds: 1500));
        coordinator.send(VoiceTurnEventHintChanged(turnId: turnId, text: 'second'));
        async.elapse(const Duration(milliseconds: 1500)); // the first handle's 2s window has now elapsed

        expect(coordinator.projection.hint, 'second');
        expect(coordinator.model.staleEventCount, 0);

        async.elapse(const Duration(milliseconds: 500)); // 2s after the second hint
        expect(coordinator.projection.hint, '');
      });
    });

    test('a cancelled deadline never fires', () {
      fakeAsync((async) {
        final coordinator = VoiceTurnCoordinator(scheduler: const TimerVoiceTurnScheduler(), mintTurnId: _newTurnId);
        final turnId = coordinator.begin(VoiceTurnIntent.hold);
        coordinator.send(
          VoiceTurnEventCaptureStarted(turnId: turnId, captureId: _capture(7)),
        ); // cancels captureStart

        async.elapse(const Duration(seconds: 10));

        expect(coordinator.model.turn?.phase, const VoiceTurnPhaseRecording());
        expect(coordinator.activeTurnId, turnId);
      });
    });
  });

  group('VoiceTurnCoordinator — drain robustness', () {
    test(
        'a throwing effect handler is CONTAINED — deadlines still arm, presentation still publishes, '
        'the machine keeps working (2026-07-18 wedge fix)', () {
      // Before the fix, the throw escaped send(): the remaining effects of
      // the batch (deadline scheduling included) were skipped, queued
      // events were dropped, and the projection publish never ran — a turn
      // could freeze in a capture phase with no timer to ever free it (the
      // field "stuck on Listening" PTT wedge).
      final m = _manual();
      final presenter = RecordingPresenter();
      m.coordinator.configure(presenter.apply);
      m.coordinator.setEffectHandler((effect) {
        throw StateError('handler blew up');
      });

      // begin() must NOT throw, and the turn must be fully armed despite the
      // handler blowing up on every effect.
      final turnId = m.coordinator.begin(VoiceTurnIntent.hold);
      expect(m.coordinator.model.turn?.phase, const VoiceTurnPhaseRecording());
      expect(m.scheduler.delayFor(VoiceTurnDeadline.captureStart), defaultVoiceTurnDeadlines.captureStart);
      expect(presenter.last.isListening, isTrue);

      // The machine keeps working WITHOUT clearing the broken handler.
      m.coordinator.send(VoiceTurnEventLock(turnId: turnId));
      expect(m.coordinator.model.turn?.phase, const VoiceTurnPhaseLockedRecording());

      // And a still-armed deadline can terminate the turn as designed.
      m.scheduler.fire(VoiceTurnDeadline.captureStart);
      expect(m.coordinator.model.turn?.phase, const VoiceTurnPhaseTerminal(VoiceTurnTerminalReason.captureFailed));
      expect(m.coordinator.activeTurnId, isNull);
    });

    test('a throwing presenter does not block the snapshot handler or the drain', () {
      final m = _manual();
      final snapshots = <VoiceTurnModel>[];
      m.coordinator.configure((_) => throw StateError('presenter blew up'));
      m.coordinator.setSnapshotHandler(snapshots.add);

      final turnId = m.coordinator.begin(VoiceTurnIntent.hold);
      expect(m.coordinator.model.turn?.id, turnId);
      expect(snapshots.length, greaterThan(0));
      expect(snapshots.last.turn?.phase, const VoiceTurnPhaseRecording());
    });

    test('a terminated turn ignores late transport callbacks', () {
      final m = _manual();
      final effects = <VoiceTurnEffect>[];
      final turnId = m.coordinator.begin(VoiceTurnIntent.hold);
      m.coordinator.send(VoiceTurnEventCancel(turnId: turnId, reason: VoiceTurnTerminalReason.cancelled));
      m.coordinator.setEffectHandler(effects.add);

      m.coordinator.send(VoiceTurnEventTranscriptionFinal(turnId: turnId, text: 'too late'));
      m.coordinator.send(VoiceTurnEventPlaybackDrained(turnId: turnId, leaseId: 'l1'));

      expect(m.coordinator.activeTurnId, isNull);
      expect(m.coordinator.model.turn?.phase, const VoiceTurnPhaseTerminal(VoiceTurnTerminalReason.cancelled));
      expect(_terminalsOf(effects), isEmpty);
      expect(m.coordinator.model.staleEventCount, 2);
    });
  });

  group('onTimelineEntry tap (flight recorder)', () {
    test('streams every timeline append to the tap, in order', () {
      final scheduler = ManualVoiceTurnScheduler();
      final seen = <String>[];
      final coordinator = VoiceTurnCoordinator(
        scheduler: scheduler,
        mintTurnId: _newTurnId,
        onTimelineEntry: (entry) => seen.add(entry.event),
      );
      final turnId = coordinator.begin(VoiceTurnIntent.hold);
      coordinator.send(VoiceTurnEventCancel(turnId: turnId, reason: VoiceTurnTerminalReason.cancelled));
      expect(seen.length, coordinator.timelineSnapshot().length);
      expect(seen, coordinator.timelineSnapshot().map((e) => e.event).toList());
    });

    test('a throwing tap is contained — the machine keeps running', () {
      final scheduler = ManualVoiceTurnScheduler();
      final coordinator = VoiceTurnCoordinator(
        scheduler: scheduler,
        mintTurnId: _newTurnId,
        onTimelineEntry: (_) => throw StateError('tap boom'),
      );
      final turnId = coordinator.begin(VoiceTurnIntent.hold);
      coordinator.send(VoiceTurnEventCancel(turnId: turnId, reason: VoiceTurnTerminalReason.cancelled));
      expect(coordinator.activeTurnId, isNull);
      expect(coordinator.model.turn?.phase, const VoiceTurnPhaseTerminal(VoiceTurnTerminalReason.cancelled));
    });
  });
}
