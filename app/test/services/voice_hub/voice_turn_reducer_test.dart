// A 1:1-in-spirit port of the desktop (Electron/TS) reducer test suite at
// `desktop/windows/src/renderer/src/lib/voice/turn/voiceTurnMachine.test.ts`
// (itself carried over from macOS `VoiceTurnReducerTests.swift`, 38 cases,
// plus 3 TS-only "port guard" cases pinning traps a naive translation gets
// wrong). Test names are kept verbatim where they exist upstream — each one
// documents an invariant of the turn model, and a renamed test is an
// invariant nobody can trace back to the reference.
//
// No network, no dart:io, no timers — `reduceVoiceTurn` is a pure function
// of (model, event); every "deadline fired" here is a hand-constructed
// event, not a real Timer.
import 'package:flutter_test/flutter_test.dart';

import 'package:omi/services/voice_hub/voice_turn_machine.dart';
import 'package:omi/services/voice_hub/voice_turn_reducer.dart';

// ---- fixtures --------------------------------------------------------------
// The reducer never mints IDs; tests do (as the coordinator will).

int _seq = 0;
VoiceTurnId _newTurnId() => 'turn-${++_seq}';
VoiceSessionId _newSessionId() => 'session-${++_seq}';
VoiceLeaseId _newLeaseId() => 'lease-${++_seq}';
VoiceCaptureId _capture(int n) => n;
VoiceResponseId _responseOf(String s) => s;
VoiceToolCallId _toolOf(String s) => s;

const VoiceTurnModel _idle = idleVoiceTurnModel;

VoiceTurnReduction _reduce(VoiceTurnModel model, VoiceTurnEvent event) => reduceVoiceTurn(model, event);

bool _isTerminalEffect(VoiceTurnEffect e) => e is VoiceTurnEffectTerminal;

VoiceOutputLease _lease(VoiceTurnId turnId, VoiceOutputLane lane) =>
    VoiceOutputLease(id: _newLeaseId(), turnId: turnId, lane: lane);

VoiceTurnRoute _hub(VoiceSessionId? sessionId) => VoiceTurnRouteHub(sessionId);

/// A deep-enough snapshot of a [VoiceTurn] for equality assertions. `VoiceTurn`
/// itself deliberately has no `operator==` (see `voice_turn_machine.dart`
/// header — it's a mutable-draft/frozen-immutable pair, not a value type
/// meant for whole-object comparison); every field it holds DOES have value
/// equality, so a field-by-field Map comparison gives the same guarantee the
/// TS test gets for free from `toEqual`.
Map<String, Object?>? _snapshot(VoiceTurn? t) {
  if (t == null) return null;
  return {
    'id': t.id,
    'intent': t.intent,
    'phase': t.phase,
    'route': t.route,
    'captureId': t.captureId,
    'sessionId': t.sessionId,
    'responseId': t.responseId,
    'pendingToolCallIds': t.pendingToolCallIds,
    'activeLease': t.activeLease,
    'providerFinished': t.providerFinished,
    'deadlines': t.deadlines,
    'projection': t.projection,
    'terminalReason': t.terminalReason,
  };
}

/// The Swift/TS fixture: a hub turn parked in `awaitingResponse` after a
/// commit.
({VoiceTurnModel model, VoiceTurnId turnId, VoiceSessionId sessionId, VoiceResponseId responseId})
    _awaitingHubResponse() {
  final turnId = _newTurnId();
  final sessionId = _newSessionId();
  final responseId = _responseOf('response');
  var model = _reduce(_idle, VoiceTurnEventStart(turnId: turnId, intent: VoiceTurnIntent.hold)).model;
  model = _reduce(model, VoiceTurnEventSelectRoute(turnId: turnId, route: _hub(sessionId))).model;
  model = _reduce(model, VoiceTurnEventFinalize(turnId: turnId)).model;
  model = _reduce(model, VoiceTurnEventHubCommitAccepted(turnId: turnId, sessionId: sessionId, responseId: responseId))
      .model;
  return (model: model, turnId: turnId, sessionId: sessionId, responseId: responseId);
}

List<VoiceTurnModel> _representativeActiveModels() {
  final turnId = _newTurnId();
  final sessionId = _newSessionId();
  final responseId = _responseOf('response');
  final recording = _reduce(_idle, VoiceTurnEventStart(turnId: turnId, intent: VoiceTurnIntent.hold)).model;
  final pending = _reduce(recording, VoiceTurnEventOpenLockWindow(turnId: turnId)).model;
  final locked = _reduce(recording, VoiceTurnEventLock(turnId: turnId)).model;
  final finalizing = _reduce(recording, VoiceTurnEventFinalize(turnId: turnId)).model;
  var awaiting = _reduce(recording, VoiceTurnEventSelectRoute(turnId: turnId, route: _hub(sessionId))).model;
  awaiting = _reduce(awaiting, VoiceTurnEventFinalize(turnId: turnId)).model;
  awaiting = _reduce(
    awaiting,
    VoiceTurnEventHubCommitAccepted(turnId: turnId, sessionId: sessionId, responseId: responseId),
  ).model;
  final tools = _reduce(awaiting, VoiceTurnEventToolStarted(turnId: turnId, callId: _toolOf('tool'))).model;
  final playing = _reduce(
    awaiting,
    VoiceTurnEventPlaybackStarted(turnId: turnId, lease: _lease(turnId, VoiceOutputLane.nativeRealtime)),
  ).model;
  return [recording, pending, locked, finalizing, awaiting, tools, playing];
}

// ---- tests ------------------------------------------------------------------

void main() {
  group('VoiceTurnReducer', () {
    test('testHappyHubTurnTransitionsThroughPlaybackAndTerminatesExactlyOnce', () {
      final turnId = _newTurnId();
      final captureId = _capture(7);
      final sessionId = _newSessionId();
      final responseId = _responseOf('response-1');
      final activeLease = _lease(turnId, VoiceOutputLane.nativeRealtime);
      var model = _idle;

      model = _reduce(model, VoiceTurnEventStart(turnId: turnId, intent: VoiceTurnIntent.hold)).model;
      expect(model.turn?.phase, const VoiceTurnPhaseRecording());
      expect(model.turn?.projection.isListening, isTrue);

      model = _reduce(model, VoiceTurnEventCaptureStarted(turnId: turnId, captureId: captureId)).model;
      model = _reduce(model, VoiceTurnEventSelectRoute(turnId: turnId, route: _hub(sessionId))).model;
      model = _reduce(model, VoiceTurnEventFinalize(turnId: turnId)).model;
      expect(model.turn?.phase, const VoiceTurnPhaseFinalizing());

      model =
          _reduce(model, VoiceTurnEventHubCommitAccepted(turnId: turnId, sessionId: sessionId, responseId: responseId))
              .model;
      expect(model.turn?.phase, const VoiceTurnPhaseAwaitingResponse());
      expect(model.turn?.projection.isResponseWaiting, isTrue);

      model = _reduce(
        model,
        VoiceTurnEventProviderResponseStarted(turnId: turnId, sessionId: sessionId, responseId: responseId),
      ).model;
      expect(model.turn?.projection.isThinking, isFalse);

      model = _reduce(model, VoiceTurnEventPlaybackStarted(turnId: turnId, lease: activeLease)).model;
      expect(model.turn?.phase, const VoiceTurnPhasePlaying(VoiceOutputLane.nativeRealtime));
      expect(model.turn?.activeLease, activeLease);

      model = _reduce(
        model,
        VoiceTurnEventProviderTurnFinished(turnId: turnId, sessionId: sessionId, responseId: responseId),
      ).model;

      final drained = _reduce(model, VoiceTurnEventPlaybackDrained(turnId: turnId, leaseId: activeLease.id));
      expect(drained.model.turn?.phase, const VoiceTurnPhaseTerminal(VoiceTurnTerminalReason.success));
      expect(
        drained.model.lastTerminal,
        VoiceTurnTerminalRecord(turnId: turnId, reason: VoiceTurnTerminalReason.success, route: _hub(sessionId)),
      );
      expect(drained.effects.where(_isTerminalEffect), hasLength(1));

      final duplicate =
          _reduce(drained.model, VoiceTurnEventFinish(turnId: turnId, reason: VoiceTurnTerminalReason.success));
      expect(duplicate.model.duplicateTerminalCount, 1);
      expect(duplicate.effects.any(_isTerminalEffect), isFalse);
    });

    test('testQuickTapLockWindowCanBecomeLockedRecording', () {
      final turnId = _newTurnId();
      var model = _reduce(_idle, VoiceTurnEventStart(turnId: turnId, intent: VoiceTurnIntent.hold)).model;

      model = _reduce(model, VoiceTurnEventOpenLockWindow(turnId: turnId)).model;
      expect(model.turn?.phase, const VoiceTurnPhasePendingLockDecision());
      expect(model.turn?.deadlines.contains(VoiceTurnDeadline.lockDecision), isTrue);

      final locked = _reduce(model, VoiceTurnEventLock(turnId: turnId));
      expect(locked.model.turn?.phase, const VoiceTurnPhaseLockedRecording());
      expect(locked.model.turn?.intent, VoiceTurnIntent.locked);
      expect(locked.model.turn?.projection.isLocked, isTrue);
      expect(
        locked.effects,
        contains(VoiceTurnEffectCancelDeadline(turnId: turnId, deadline: VoiceTurnDeadline.lockDecision)),
      );
    });

    test('testLockWindowDeadlineFinalizesAndStopsCapture', () {
      final turnId = _newTurnId();
      final captureId = _capture(8);
      var model = _reduce(_idle, VoiceTurnEventStart(turnId: turnId, intent: VoiceTurnIntent.hold)).model;
      model = _reduce(model, VoiceTurnEventCaptureStarted(turnId: turnId, captureId: captureId)).model;
      model = _reduce(model, VoiceTurnEventOpenLockWindow(turnId: turnId)).model;

      final result =
          _reduce(model, VoiceTurnEventDeadlineFired(turnId: turnId, deadline: VoiceTurnDeadline.lockDecision));

      expect(result.model.turn?.phase, const VoiceTurnPhaseFinalizing());
      expect(result.effects, contains(VoiceTurnEffectStopCapture(turnId: turnId, captureId: captureId)));
    });

    test('testLateCaptureStartAfterFinalizationIsStoppedAndCannotResurrectTurn', () {
      final turnId = _newTurnId();
      var model = _reduce(_idle, VoiceTurnEventStart(turnId: turnId, intent: VoiceTurnIntent.hold)).model;
      model = _reduce(model, VoiceTurnEventFinalize(turnId: turnId)).model;
      final lateCaptureId = _capture(99);

      final result = _reduce(model, VoiceTurnEventCaptureStarted(turnId: turnId, captureId: lateCaptureId));

      expect(result.model.turn?.phase, const VoiceTurnPhaseFinalizing());
      expect(result.model.turn?.captureId, isNull);
      expect(result.model.staleEventCount, 1);
      expect(result.effects, contains(VoiceTurnEffectStopCapture(turnId: turnId, captureId: lateCaptureId)));
    });

    test('testOldTurnEventsAreDroppedAfterBargeInStartsNewTurn', () {
      final oldTurnId = _newTurnId();
      final newTurn = _newTurnId();
      var model = _reduce(_idle, VoiceTurnEventStart(turnId: oldTurnId, intent: VoiceTurnIntent.hold)).model;

      final bargeIn = _reduce(model, VoiceTurnEventStart(turnId: newTurn, intent: VoiceTurnIntent.hold));
      model = bargeIn.model;
      expect(model.turn?.id, newTurn);
      expect(
        model.lastTerminal,
        VoiceTurnTerminalRecord(
          turnId: oldTurnId,
          reason: VoiceTurnTerminalReason.interruptedByBargeIn,
          route: const VoiceTurnRouteUndecided(),
        ),
      );

      final stale = _reduce(model, VoiceTurnEventTranscriptionFinal(turnId: oldTurnId, text: 'old'));
      expect(stale.model.turn?.id, newTurn);
      expect(stale.model.turn?.projection.transcript, '');
      expect(stale.model.staleEventCount, 1);
    });

    test('testHubBargeInPreservesProviderRuntimeForAtomicHandoff', () {
      final oldTurnId = _newTurnId();
      final newTurn = _newTurnId();
      final sessionId = _newSessionId();
      var model = _reduce(_idle, VoiceTurnEventStart(turnId: oldTurnId, intent: VoiceTurnIntent.hold)).model;
      model = _reduce(model, VoiceTurnEventSelectRoute(turnId: oldTurnId, route: _hub(sessionId))).model;

      final result = _reduce(model, VoiceTurnEventStart(turnId: newTurn, intent: VoiceTurnIntent.hold));

      expect(result.model.lastTerminal?.route, _hub(sessionId));
      expect(
        result.effects,
        isNot(contains(VoiceTurnEffectCancelHub(turnId: oldTurnId, route: _hub(sessionId)))),
      );
      expect(
        result.effects.any((e) => e is VoiceTurnEffectStopPlayback && e.turnId == oldTurnId),
        isFalse,
      );
    });

    test('testHubWarmTimeoutFallsBackWithoutTerminatingOrDroppingTurn', () {
      final turnId = _newTurnId();
      var model = _reduce(_idle, VoiceTurnEventStart(turnId: turnId, intent: VoiceTurnIntent.hold)).model;
      model = _reduce(model, VoiceTurnEventSelectRoute(turnId: turnId, route: const VoiceTurnRouteHubWarmWait())).model;
      model = _reduce(model, VoiceTurnEventFinalize(turnId: turnId)).model;

      final timedOut = _reduce(model, VoiceTurnEventDeadlineFired(turnId: turnId, deadline: VoiceTurnDeadline.hubWarm));

      expect(timedOut.model.turn?.route, const VoiceTurnRouteDeepgramBatch());
      expect(timedOut.model.turn?.phase, const VoiceTurnPhaseFinalizing());
      expect(timedOut.model.turn?.terminalReason, isNull);
      expect(
        timedOut.effects,
        contains(
            VoiceTurnEffectFallbackToTranscription(turnId: turnId, reason: VoiceTurnTerminalReason.hubWarmTimeout)),
      );
    });

    test('testHubReadyCancelsWarmDeadlineAndPreservesRecording', () {
      final turnId = _newTurnId();
      final sessionId = _newSessionId();
      var model = _reduce(_idle, VoiceTurnEventStart(turnId: turnId, intent: VoiceTurnIntent.hold)).model;
      model = _reduce(model, VoiceTurnEventSelectRoute(turnId: turnId, route: const VoiceTurnRouteHubWarmWait())).model;

      final ready = _reduce(model, VoiceTurnEventHubReady(turnId: turnId, sessionId: sessionId));

      expect(ready.model.turn?.route, _hub(sessionId));
      expect(ready.model.turn?.sessionId, sessionId);
      expect(ready.model.turn?.phase, const VoiceTurnPhaseRecording());
      expect(
          ready.effects, contains(VoiceTurnEffectCancelDeadline(turnId: turnId, deadline: VoiceTurnDeadline.hubWarm)));
    });

    test('testDeferredCommitTimeoutTerminatesWithTypedReason', () {
      final turnId = _newTurnId();
      final sessionId = _newSessionId();
      var model = _reduce(_idle, VoiceTurnEventStart(turnId: turnId, intent: VoiceTurnIntent.hold)).model;
      model = _reduce(model, VoiceTurnEventSelectRoute(turnId: turnId, route: _hub(sessionId))).model;
      model = _reduce(model, VoiceTurnEventFinalize(turnId: turnId)).model;
      model = _reduce(model, VoiceTurnEventHubCommitDeferred(turnId: turnId)).model;

      final result =
          _reduce(model, VoiceTurnEventDeadlineFired(turnId: turnId, deadline: VoiceTurnDeadline.deferredCommit));

      expect(result.model.turn?.phase, const VoiceTurnPhaseTerminal(VoiceTurnTerminalReason.deferredCommitTimeout));
      expect(result.model.lastTerminal?.reason, VoiceTurnTerminalReason.deferredCommitTimeout);
    });

    test('testBargeInReplacementCommitHasDistinctDeadlineAndCanResumeOnFreshSession', () {
      final turnId = _newTurnId();
      final oldSessionId = _newSessionId();
      final replacementSessionId = _newSessionId();
      var model = _reduce(_idle, VoiceTurnEventStart(turnId: turnId, intent: VoiceTurnIntent.hold)).model;
      model = _reduce(model, VoiceTurnEventSelectRoute(turnId: turnId, route: _hub(oldSessionId))).model;
      model = _reduce(model, VoiceTurnEventFinalize(turnId: turnId)).model;

      final deferred = _reduce(model, VoiceTurnEventHubCommitDeferredForReplacement(turnId: turnId));
      expect(deferred.model.turn?.phase, const VoiceTurnPhaseAwaitingResponse());
      expect(deferred.model.turn?.deadlines.contains(VoiceTurnDeadline.bargeInReplacement), isTrue);
      expect(deferred.model.turn?.deadlines.contains(VoiceTurnDeadline.deferredCommit), isFalse);

      // `selectRoute` set the route's sessionId but never the TURN's
      // sessionId, so the fence still admits a fresh replacement session.
      final accepted = _reduce(
        deferred.model,
        VoiceTurnEventHubCommitAccepted(turnId: turnId, sessionId: replacementSessionId, responseId: null),
      );
      expect(accepted.model.turn?.sessionId, replacementSessionId);
      expect(accepted.model.turn?.deadlines.contains(VoiceTurnDeadline.bargeInReplacement), isFalse);
      expect(accepted.model.turn?.deadlines.contains(VoiceTurnDeadline.providerResponse), isTrue);
      expect(
        accepted.effects,
        contains(VoiceTurnEffectCancelDeadline(turnId: turnId, deadline: VoiceTurnDeadline.bargeInReplacement)),
      );
    });

    test('testBargeInReplacementDeadlineTerminatesWithTypedReason', () {
      final turnId = _newTurnId();
      var model = _reduce(_idle, VoiceTurnEventStart(turnId: turnId, intent: VoiceTurnIntent.hold)).model;
      model = _reduce(model, VoiceTurnEventSelectRoute(turnId: turnId, route: _hub(null))).model;
      model = _reduce(model, VoiceTurnEventFinalize(turnId: turnId)).model;
      model = _reduce(model, VoiceTurnEventHubCommitDeferredForReplacement(turnId: turnId)).model;

      final result =
          _reduce(model, VoiceTurnEventDeadlineFired(turnId: turnId, deadline: VoiceTurnDeadline.bargeInReplacement));

      expect(
        result.model.turn?.phase,
        const VoiceTurnPhaseTerminal(VoiceTurnTerminalReason.bargeInReplacementTimeout),
      );
      expect(result.model.lastTerminal?.reason, VoiceTurnTerminalReason.bargeInReplacementTimeout);
    });

    test('testProviderNoResponseDeadlineTerminatesAndShowsActionableHint', () {
      final fixture = _awaitingHubResponse();

      final result = _reduce(
        fixture.model,
        VoiceTurnEventDeadlineFired(turnId: fixture.turnId, deadline: VoiceTurnDeadline.providerResponse),
      );

      expect(result.model.turn?.phase, const VoiceTurnPhaseTerminal(VoiceTurnTerminalReason.providerNoResponse));
      expect(result.model.turn?.projection.isListening, isFalse);
      expect(result.model.turn?.projection.isThinking, isFalse);
      expect(result.model.turn?.projection.isResponseActive, isFalse);
      expect(result.model.turn?.projection.hint, 'Voice response failed — try again');
      expect(result.model.turn?.deadlines.contains(VoiceTurnDeadline.hintVisibility), isTrue);
    });

    test('testProviderEventFromReplacedSessionIsDropped', () {
      final fixture = _awaitingHubResponse();
      final staleSession = _newSessionId();

      final result = _reduce(
        fixture.model,
        VoiceTurnEventProviderResponseStarted(
            turnId: fixture.turnId, sessionId: staleSession, responseId: fixture.responseId),
      );

      expect(result.model.turn?.phase, const VoiceTurnPhaseAwaitingResponse());
      expect(result.model.staleEventCount, 1);
    });

    test('testProviderEventFromReplacedResponseIsDropped', () {
      final fixture = _awaitingHubResponse();

      final result = _reduce(
        fixture.model,
        VoiceTurnEventProviderResponseStarted(
          turnId: fixture.turnId,
          sessionId: fixture.sessionId,
          responseId: _responseOf('stale'),
        ),
      );

      expect(result.model.turn?.phase, const VoiceTurnPhaseAwaitingResponse());
      expect(result.model.staleEventCount, 1);
    });

    // THE nil-identity fence. A callback that lost its identity is stale,
    // NOT accepted.
    test('testProviderCallbackMissingKnownIdentityIsDropped', () {
      final fixture = _awaitingHubResponse();

      final started = _reduce(
        fixture.model,
        VoiceTurnEventProviderResponseStarted(turnId: fixture.turnId, sessionId: null, responseId: null),
      );
      final finished = _reduce(
        fixture.model,
        VoiceTurnEventProviderTurnFinished(turnId: fixture.turnId, sessionId: null, responseId: null),
      );

      expect(started.model.turn?.phase, const VoiceTurnPhaseAwaitingResponse());
      expect(started.model.staleEventCount, 1);
      expect(finished.model.turn?.phase, const VoiceTurnPhaseAwaitingResponse());
      expect(finished.model.staleEventCount, 1);
    });

    test('testProviderCanFinishSuccessfullyWithoutStartingPlayback', () {
      final fixture = _awaitingHubResponse();

      final result = _reduce(
        fixture.model,
        VoiceTurnEventProviderTurnFinished(
            turnId: fixture.turnId, sessionId: fixture.sessionId, responseId: fixture.responseId),
      );

      expect(result.model.turn?.phase, const VoiceTurnPhaseTerminal(VoiceTurnTerminalReason.success));
      expect(result.model.lastTerminal?.reason, VoiceTurnTerminalReason.success);
    });

    test('testToolCompletionKeepsTurnOpenUntilEveryToolFinishes', () {
      final fixture = _awaitingHubResponse();
      var model = _reduce(
        fixture.model,
        VoiceTurnEventProviderResponseStarted(
            turnId: fixture.turnId, sessionId: fixture.sessionId, responseId: fixture.responseId),
      ).model;
      final first = _toolOf('first');
      final second = _toolOf('second');
      model = _reduce(model, VoiceTurnEventToolStarted(turnId: fixture.turnId, callId: first)).model;
      model = _reduce(model, VoiceTurnEventToolStarted(turnId: fixture.turnId, callId: second)).model;

      model = _reduce(model, VoiceTurnEventToolFinished(turnId: fixture.turnId, callId: first)).model;
      expect(model.turn?.phase, const VoiceTurnPhaseAwaitingTools());
      expect(model.turn?.pendingToolCallIds, {second});

      final finished = _reduce(model, VoiceTurnEventToolFinished(turnId: fixture.turnId, callId: second));
      expect(finished.model.turn?.phase, const VoiceTurnPhaseAwaitingResponse());
      expect(finished.model.turn?.pendingToolCallIds, isEmpty);
      expect(
        finished.effects,
        contains(VoiceTurnEffectCancelDeadline(turnId: fixture.turnId, deadline: VoiceTurnDeadline.pendingTools)),
      );
      expect(finished.model.turn?.deadlines.contains(VoiceTurnDeadline.providerResponse), isTrue);
    });

    test('testProviderFinishDuringToolWaitTerminatesAfterLastToolAndOnlyThen', () {
      final fixture = _awaitingHubResponse();
      final callId = _toolOf('pending');
      var model = _reduce(
        fixture.model,
        VoiceTurnEventProviderResponseStarted(
            turnId: fixture.turnId, sessionId: fixture.sessionId, responseId: fixture.responseId),
      ).model;
      model = _reduce(model, VoiceTurnEventToolStarted(turnId: fixture.turnId, callId: callId)).model;

      final providerFinished = _reduce(
        model,
        VoiceTurnEventProviderTurnFinished(
            turnId: fixture.turnId, sessionId: fixture.sessionId, responseId: fixture.responseId),
      );
      expect(providerFinished.model.turn?.phase, const VoiceTurnPhaseAwaitingTools());
      expect(providerFinished.model.lastTerminal, isNull);

      final toolFinished =
          _reduce(providerFinished.model, VoiceTurnEventToolFinished(turnId: fixture.turnId, callId: callId));
      expect(toolFinished.model.turn?.phase, const VoiceTurnPhaseTerminal(VoiceTurnTerminalReason.success));
      expect(toolFinished.model.lastTerminal?.reason, VoiceTurnTerminalReason.success);
    });

    test('testToolAndPlaybackCanDrainInEitherOrderWithoutClosingEarly', () {
      final fixture = _awaitingHubResponse();
      final callId = _toolOf('tool');
      final activeLease = _lease(fixture.turnId, VoiceOutputLane.nativeRealtime);
      var model = _reduce(
        fixture.model,
        VoiceTurnEventProviderResponseStarted(
            turnId: fixture.turnId, sessionId: fixture.sessionId, responseId: fixture.responseId),
      ).model;
      model = _reduce(model, VoiceTurnEventPlaybackStarted(turnId: fixture.turnId, lease: activeLease)).model;
      model = _reduce(model, VoiceTurnEventToolStarted(turnId: fixture.turnId, callId: callId)).model;
      model = _reduce(
        model,
        VoiceTurnEventProviderTurnFinished(
            turnId: fixture.turnId, sessionId: fixture.sessionId, responseId: fixture.responseId),
      ).model;

      final drained = _reduce(model, VoiceTurnEventPlaybackDrained(turnId: fixture.turnId, leaseId: activeLease.id));
      expect(drained.model.turn?.phase, const VoiceTurnPhaseAwaitingTools());
      expect(drained.model.lastTerminal, isNull);

      final finished = _reduce(drained.model, VoiceTurnEventToolFinished(turnId: fixture.turnId, callId: callId));
      expect(finished.model.turn?.phase, const VoiceTurnPhaseTerminal(VoiceTurnTerminalReason.success));
    });

    test('testProviderOutputCannotMutateRecordingTurnBeforeCommit', () {
      final turnId = _newTurnId();
      final activeLease = _lease(turnId, VoiceOutputLane.nativeRealtime);
      final recording = _reduce(_idle, VoiceTurnEventStart(turnId: turnId, intent: VoiceTurnIntent.hold)).model;

      final started = _reduce(
        recording,
        VoiceTurnEventProviderResponseStarted(turnId: turnId, sessionId: _newSessionId(), responseId: null),
      );
      final playback = _reduce(recording, VoiceTurnEventPlaybackStarted(turnId: turnId, lease: activeLease));

      expect(started.model.turn?.phase, const VoiceTurnPhaseRecording());
      expect(started.model.invalidTransitionCount, 1);
      expect(playback.model.turn?.phase, const VoiceTurnPhaseRecording());
      expect(playback.model.turn?.activeLease, isNull);
      expect(playback.model.invalidTransitionCount, 1);
    });

    test('testPendingToolDeadlineTerminates', () {
      final fixture = _awaitingHubResponse();
      var model = _reduce(
        fixture.model,
        VoiceTurnEventProviderResponseStarted(
            turnId: fixture.turnId, sessionId: fixture.sessionId, responseId: fixture.responseId),
      ).model;
      model = _reduce(model, VoiceTurnEventToolStarted(turnId: fixture.turnId, callId: _toolOf('slow'))).model;

      final result =
          _reduce(model, VoiceTurnEventDeadlineFired(turnId: fixture.turnId, deadline: VoiceTurnDeadline.pendingTools));

      expect(result.model.turn?.phase, const VoiceTurnPhaseTerminal(VoiceTurnTerminalReason.toolTimeout));
    });

    test('testCaptureTranscriptionAndPlaybackDeadlinesHaveDistinctTerminalReasons', () {
      final captureTurnId = _newTurnId();
      final capturing = _reduce(_idle, VoiceTurnEventStart(turnId: captureTurnId, intent: VoiceTurnIntent.hold)).model;
      expect(
        _reduce(capturing, VoiceTurnEventDeadlineFired(turnId: captureTurnId, deadline: VoiceTurnDeadline.captureStart))
            .model
            .turn
            ?.phase,
        const VoiceTurnPhaseTerminal(VoiceTurnTerminalReason.captureFailed),
      );

      final transcriptionTurnId = _newTurnId();
      var transcribing =
          _reduce(_idle, VoiceTurnEventStart(turnId: transcriptionTurnId, intent: VoiceTurnIntent.hold)).model;
      transcribing = _reduce(
        transcribing,
        VoiceTurnEventSelectRoute(turnId: transcriptionTurnId, route: const VoiceTurnRouteDeepgramBatch()),
      ).model;
      transcribing = _reduce(transcribing, VoiceTurnEventFinalize(turnId: transcriptionTurnId)).model;
      transcribing = _reduce(transcribing, VoiceTurnEventTranscriptionStarted(turnId: transcriptionTurnId)).model;
      expect(
        _reduce(
          transcribing,
          VoiceTurnEventDeadlineFired(turnId: transcriptionTurnId, deadline: VoiceTurnDeadline.transcription),
        ).model.turn?.phase,
        const VoiceTurnPhaseTerminal(VoiceTurnTerminalReason.transcriptionFailed),
      );

      final fixture = _awaitingHubResponse();
      final activeLease = _lease(fixture.turnId, VoiceOutputLane.nativeRealtime);
      final playing =
          _reduce(fixture.model, VoiceTurnEventPlaybackStarted(turnId: fixture.turnId, lease: activeLease)).model;
      expect(
        _reduce(playing, VoiceTurnEventDeadlineFired(turnId: fixture.turnId, deadline: VoiceTurnDeadline.playbackDrain))
            .model
            .turn
            ?.phase,
        const VoiceTurnPhaseTerminal(VoiceTurnTerminalReason.playbackFailed),
      );
    });

    test('testPlaybackFailureRequiresMatchingLeaseAndShowsErrorHint', () {
      final fixture = _awaitingHubResponse();
      final activeLease = _lease(fixture.turnId, VoiceOutputLane.selectedVoiceFallback);
      final playing =
          _reduce(fixture.model, VoiceTurnEventPlaybackStarted(turnId: fixture.turnId, lease: activeLease)).model;

      final stale = _reduce(
        playing,
        VoiceTurnEventPlaybackFailed(turnId: fixture.turnId, leaseId: _newLeaseId(), message: 'stale'),
      );
      expect(stale.model.turn?.phase, const VoiceTurnPhasePlaying(VoiceOutputLane.selectedVoiceFallback));
      expect(stale.model.staleEventCount, 1);

      final failed = _reduce(
        playing,
        VoiceTurnEventPlaybackFailed(turnId: fixture.turnId, leaseId: activeLease.id, message: 'fixture'),
      );
      expect(failed.model.turn?.phase, const VoiceTurnPhaseTerminal(VoiceTurnTerminalReason.playbackFailed));
      expect(failed.model.turn?.projection.hint, 'Audio playback failed');
    });

    test('testCompetingPlaybackLeaseIsRejectedAsInvalidTransition', () {
      final fixture = _awaitingHubResponse();
      var model = _reduce(
        fixture.model,
        VoiceTurnEventProviderResponseStarted(
            turnId: fixture.turnId, sessionId: fixture.sessionId, responseId: fixture.responseId),
      ).model;
      final native = _lease(fixture.turnId, VoiceOutputLane.nativeRealtime);
      final fallback = _lease(fixture.turnId, VoiceOutputLane.selectedVoiceFallback);
      model = _reduce(model, VoiceTurnEventPlaybackStarted(turnId: fixture.turnId, lease: native)).model;

      final result = _reduce(model, VoiceTurnEventPlaybackStarted(turnId: fixture.turnId, lease: fallback));

      expect(result.model.turn?.activeLease, native);
      expect(result.model.invalidTransitionCount, 1);
    });

    test('testStalePlaybackDrainCannotFinishCurrentLease', () {
      final fixture = _awaitingHubResponse();
      var model = _reduce(
        fixture.model,
        VoiceTurnEventProviderResponseStarted(
            turnId: fixture.turnId, sessionId: fixture.sessionId, responseId: fixture.responseId),
      ).model;
      final activeLease = _lease(fixture.turnId, VoiceOutputLane.nativeRealtime);
      model = _reduce(model, VoiceTurnEventPlaybackStarted(turnId: fixture.turnId, lease: activeLease)).model;

      final result = _reduce(model, VoiceTurnEventPlaybackDrained(turnId: fixture.turnId, leaseId: _newLeaseId()));

      expect(result.model.turn?.phase, const VoiceTurnPhasePlaying(VoiceOutputLane.nativeRealtime));
      expect(result.model.turn?.activeLease, activeLease);
      expect(result.model.staleEventCount, 1);
    });

    test('testProviderTurnDoneWaitsForMatchingPlaybackDrain', () {
      final fixture = _awaitingHubResponse();
      var model = _reduce(
        fixture.model,
        VoiceTurnEventProviderResponseStarted(
            turnId: fixture.turnId, sessionId: fixture.sessionId, responseId: fixture.responseId),
      ).model;
      final activeLease = _lease(fixture.turnId, VoiceOutputLane.nativeRealtime);
      model = _reduce(model, VoiceTurnEventPlaybackStarted(turnId: fixture.turnId, lease: activeLease)).model;

      final providerDone = _reduce(
        model,
        VoiceTurnEventProviderTurnFinished(
            turnId: fixture.turnId, sessionId: fixture.sessionId, responseId: fixture.responseId),
      );

      expect(providerDone.model.turn?.phase, const VoiceTurnPhasePlaying(VoiceOutputLane.nativeRealtime));
      expect(providerDone.model.turn?.providerFinished, isTrue);
      expect(providerDone.model.lastTerminal, isNull);

      final drained = _reduce(
        providerDone.model,
        VoiceTurnEventPlaybackDrained(turnId: fixture.turnId, leaseId: activeLease.id),
      );
      expect(drained.model.turn?.phase, const VoiceTurnPhaseTerminal(VoiceTurnTerminalReason.success));
    });

    test('testPlaybackDrainBeforeProviderDoneReturnsToAwaitingResponse', () {
      final fixture = _awaitingHubResponse();
      var model = _reduce(
        fixture.model,
        VoiceTurnEventProviderResponseStarted(
            turnId: fixture.turnId, sessionId: fixture.sessionId, responseId: fixture.responseId),
      ).model;
      final activeLease = _lease(fixture.turnId, VoiceOutputLane.nativeRealtime);
      model = _reduce(model, VoiceTurnEventPlaybackStarted(turnId: fixture.turnId, lease: activeLease)).model;

      final drained = _reduce(model, VoiceTurnEventPlaybackDrained(turnId: fixture.turnId, leaseId: activeLease.id));

      expect(drained.model.turn?.phase, const VoiceTurnPhaseAwaitingResponse());
      expect(drained.model.lastTerminal, isNull);
      expect(drained.model.turn?.deadlines.contains(VoiceTurnDeadline.providerResponse), isTrue);
    });

    test('testCleanupFromEveryNonIdlePhaseConvergesToTerminalThenReset', () {
      for (final model in _representativeActiveModels()) {
        final cleaned = _reduce(model, const VoiceTurnEventCleanup());
        expect(cleaned.model.turn?.phase, const VoiceTurnPhaseTerminal(VoiceTurnTerminalReason.cleanup));
        expect(cleaned.model.turn?.projection, idleVoiceTurnProjection);
        expect(cleaned.effects.any(_isTerminalEffect), isTrue);

        final reset = _reduce(cleaned.model, const VoiceTurnEventReset());
        expect(reset.model.turn, isNull);
        expect(reset.model.lastTerminal?.reason, VoiceTurnTerminalReason.cleanup);
      }
    });

    test('testInvalidTransitionDoesNotMutateTurn', () {
      final turnId = _newTurnId();
      final model = _reduce(_idle, VoiceTurnEventStart(turnId: turnId, intent: VoiceTurnIntent.hold)).model;

      final result = _reduce(
        model,
        VoiceTurnEventHubCommitAccepted(
            turnId: turnId, sessionId: _newSessionId(), responseId: _responseOf('unexpected')),
      );

      expect(_snapshot(result.model.turn), _snapshot(model.turn));
      expect(result.model.invalidTransitionCount, 1);
    });

    test('testDeferredCommitCannotSkipFinalization', () {
      final turnId = _newTurnId();
      var recording = _reduce(_idle, VoiceTurnEventStart(turnId: turnId, intent: VoiceTurnIntent.hold)).model;
      recording = _reduce(recording, VoiceTurnEventSelectRoute(turnId: turnId, route: _hub(null))).model;

      final generic = _reduce(recording, VoiceTurnEventHubCommitDeferred(turnId: turnId));
      final replacement = _reduce(recording, VoiceTurnEventHubCommitDeferredForReplacement(turnId: turnId));

      expect(generic.model.turn?.phase, const VoiceTurnPhaseRecording());
      expect(generic.model.invalidTransitionCount, 1);
      expect(replacement.model.turn?.phase, const VoiceTurnPhaseRecording());
      expect(replacement.model.invalidTransitionCount, 1);
    });

    test('testHubTerminalCleanupCarriesOldRouteInEffectPayload', () {
      final turnId = _newTurnId();
      final route = _hub(_newSessionId());
      var model = _reduce(_idle, VoiceTurnEventStart(turnId: turnId, intent: VoiceTurnIntent.hold)).model;
      model = _reduce(model, VoiceTurnEventSelectRoute(turnId: turnId, route: route)).model;

      final cancelled = _reduce(model, VoiceTurnEventCancel(turnId: turnId, reason: VoiceTurnTerminalReason.cancelled));

      expect(cancelled.effects, contains(VoiceTurnEffectCancelHub(turnId: turnId, route: route)));
      expect(routeMatchesHub(route), isTrue);
      expect(routeMatchesHub(const VoiceTurnRouteDeepgramBatch()), isFalse);
    });

    test('testHintDeadlineOnlyClearsTheCurrentTurnHint', () {
      final turnId = _newTurnId();
      var model = _reduce(_idle, VoiceTurnEventStart(turnId: turnId, intent: VoiceTurnIntent.hold)).model;
      model = _reduce(model, VoiceTurnEventHintChanged(turnId: turnId, text: 'Hold longer')).model;

      final cleared =
          _reduce(model, VoiceTurnEventDeadlineFired(turnId: turnId, deadline: VoiceTurnDeadline.hintVisibility));

      expect(cleared.model.turn?.projection.hint, '');
    });

    test('testTerminalHintDeadlineClearsHintWithoutResurrectingTurn', () {
      final turnId = _newTurnId();
      var model = _reduce(_idle, VoiceTurnEventStart(turnId: turnId, intent: VoiceTurnIntent.hold)).model;
      model = _reduce(model, VoiceTurnEventFinish(turnId: turnId, reason: VoiceTurnTerminalReason.tooShort)).model;
      expect(model.turn?.projection.hint, 'Hold longer to record');

      final cleared =
          _reduce(model, VoiceTurnEventDeadlineFired(turnId: turnId, deadline: VoiceTurnDeadline.hintVisibility));

      expect(cleared.model.turn?.phase, const VoiceTurnPhaseTerminal(VoiceTurnTerminalReason.tooShort));
      expect(cleared.model.turn?.projection.hint, '');
    });

    test('testSemanticPresentationEventsUpdateProjectionWithoutOwningIO', () {
      final fixture = _awaitingHubResponse();
      var model = _reduce(fixture.model, VoiceTurnEventTranscriptChanged(turnId: fixture.turnId, text: 'hello')).model;
      model = _reduce(model, VoiceTurnEventHintChanged(turnId: fixture.turnId, text: 'working')).model;
      model = _reduce(model, VoiceTurnEventResponseWaitingChanged(turnId: fixture.turnId, active: true)).model;
      expect(model.turn?.projection.transcript, 'hello');
      expect(model.turn?.projection.hint, 'working');
      expect(model.turn?.projection.isThinking, isTrue);

      model = _reduce(model, VoiceTurnEventResponseActiveChanged(turnId: fixture.turnId, active: true)).model;
      expect(model.turn?.projection.isResponseActive, isTrue);
      expect(model.turn?.projection.isResponseWaiting, isFalse);
      expect(model.turn?.projection.isThinking, isFalse);

      final cleared = _reduce(model, VoiceTurnEventHintChanged(turnId: fixture.turnId, text: ''));
      expect(cleared.model.turn?.projection.hint, '');
      expect(
        cleared.effects,
        contains(VoiceTurnEffectCancelDeadline(turnId: fixture.turnId, deadline: VoiceTurnDeadline.hintVisibility)),
      );
    });

    test('testRandomizedStaleEventsNeverChangeActiveTurnIdentityOrTerminalizeIt', () {
      final activeTurnId = _newTurnId();
      var model = _reduce(_idle, VoiceTurnEventStart(turnId: activeTurnId, intent: VoiceTurnIntent.hold)).model;
      final initialStaleCount = model.staleEventCount;

      for (var index = 0; index < 250; index++) {
        final staleId = _newTurnId();
        final VoiceTurnEvent event;
        switch (index % 5) {
          case 0:
            event = VoiceTurnEventFinalize(turnId: staleId);
            break;
          case 1:
            event = VoiceTurnEventTranscriptionFinal(turnId: staleId, text: 'stale');
            break;
          case 2:
            event = VoiceTurnEventToolFinished(turnId: staleId, callId: _toolOf('$index'));
            break;
          case 3:
            event = VoiceTurnEventPlaybackDrained(turnId: staleId, leaseId: _newLeaseId());
            break;
          default:
            event = VoiceTurnEventDeadlineFired(turnId: staleId, deadline: VoiceTurnDeadline.providerResponse);
        }
        model = _reduce(model, event).model;
        expect(model.turn?.id, activeTurnId);
        expect(model.turn?.phase is VoiceTurnPhaseTerminal, isFalse);
      }

      expect(model.staleEventCount, initialStaleCount + 250);
    });

    test('testClearPresentationIsARealReducerTransition', () {
      final turnId = _newTurnId();
      var model = _reduce(_idle, VoiceTurnEventStart(turnId: turnId, intent: VoiceTurnIntent.hold)).model;
      model = _reduce(model, VoiceTurnEventTranscriptChanged(turnId: turnId, text: 'private words')).model;
      model = _reduce(model, VoiceTurnEventResponseActiveChanged(turnId: turnId, active: true)).model;

      final cleared = _reduce(model, VoiceTurnEventClearPresentation(turnId: turnId));

      expect(cleared.model.turn?.projection, idleVoiceTurnProjection);
      expect(cleared.model.turn?.phase, const VoiceTurnPhaseRecording());
    });

    test('testDiagnosticLabelsNeverContainSpeechOrErrorPayloads', () {
      const marker = 'secret-marker-9381';
      final turnId = _newTurnId();
      final events = <VoiceTurnEvent>[
        VoiceTurnEventTranscriptChanged(turnId: turnId, text: marker),
        VoiceTurnEventTranscriptionFinal(turnId: turnId, text: marker),
        VoiceTurnEventPlaybackFailed(turnId: turnId, leaseId: null, message: marker),
        VoiceTurnEventCaptureFailed(turnId: turnId, captureId: null, message: marker),
      ];

      for (final event in events) {
        expect(diagnosticLabel(event), isNot(contains(marker)));
        final stale = _reduce(_idle, event);
        final last = stale.effects.last;
        expect(last, isA<VoiceTurnEffectStaleEventDropped>());
        final label = (last as VoiceTurnEffectStaleEventDropped).event;
        expect(label, diagnosticLabel(event));
        expect(label, isNot(contains(marker)));
      }
    });

    test('testNewTurnResetsPerTurnAnomalyCounters', () {
      final turnA = _newTurnId();
      var model = _reduce(_idle, VoiceTurnEventStart(turnId: turnA, intent: VoiceTurnIntent.hold)).model;
      model = _reduce(model, VoiceTurnEventFinalize(turnId: _newTurnId())).model;
      model = _reduce(
        model,
        VoiceTurnEventHubCommitAccepted(turnId: turnA, sessionId: _newSessionId(), responseId: null),
      ).model;
      expect(model.staleEventCount, 1);
      expect(model.invalidTransitionCount, 1);

      final turnB = _newTurnId();
      model = _reduce(model, VoiceTurnEventStart(turnId: turnB, intent: VoiceTurnIntent.hold)).model;

      expect(model.turn?.id, turnB);
      expect(model.staleEventCount, 0);
      expect(model.invalidTransitionCount, 0);
      expect(model.duplicateTerminalCount, 0);
    });

    // --- PORT GUARD (beyond the Swift 38) -----------------------------------
    // `_cancel` emits only when the deadline `Set` actually removed
    // something. A port that emits unconditionally produces spurious
    // `cancelDeadline` effects for deadlines that were never held. Pinned
    // here at the layer that owns it (mirrors the TS source's own port-guard
    // test of the same name).
    test('cancelEmitsNothingForADeadlineTheTurnDoesNotHold', () {
      final turnId = _newTurnId();
      // `finalize` cancels BOTH lockDecision and captureStart, but a plain
      // hold only ever armed captureStart.
      final model = _reduce(_idle, VoiceTurnEventStart(turnId: turnId, intent: VoiceTurnIntent.hold)).model;
      expect(model.turn?.deadlines.contains(VoiceTurnDeadline.lockDecision), isFalse);
      expect(model.turn?.deadlines.contains(VoiceTurnDeadline.captureStart), isTrue);

      final finalized = _reduce(model, VoiceTurnEventFinalize(turnId: turnId));

      final cancels = finalized.effects.whereType<VoiceTurnEffectCancelDeadline>().toList();
      expect(cancels, [VoiceTurnEffectCancelDeadline(turnId: turnId, deadline: VoiceTurnDeadline.captureStart)]);
    });

    // The mutable draft's `terminate()` reads the ALREADY-MUTATED
    // `model.turn`, not a pre-event snapshot — `playbackDrained` nulls
    // `activeLease` BEFORE calling `_terminate`, so a successful drain must
    // emit NO `stopPlayback` (the lease already drained itself; stopping it
    // again would tear down the next turn's playback). A port that
    // snapshots the lease pre-event emits a spurious one. No Swift reducer
    // test pins this; pinned here (mirrors the TS source's own port-guard
    // test of the same name).
    test('successfulPlaybackDrainTerminatesWithoutEmittingStopPlayback', () {
      final fixture = _awaitingHubResponse();
      var model = _reduce(
        fixture.model,
        VoiceTurnEventProviderResponseStarted(
            turnId: fixture.turnId, sessionId: fixture.sessionId, responseId: fixture.responseId),
      ).model;
      final activeLease = _lease(fixture.turnId, VoiceOutputLane.nativeRealtime);
      model = _reduce(model, VoiceTurnEventPlaybackStarted(turnId: fixture.turnId, lease: activeLease)).model;
      model = _reduce(
        model,
        VoiceTurnEventProviderTurnFinished(
            turnId: fixture.turnId, sessionId: fixture.sessionId, responseId: fixture.responseId),
      ).model;

      final drained = _reduce(model, VoiceTurnEventPlaybackDrained(turnId: fixture.turnId, leaseId: activeLease.id));

      expect(drained.model.turn?.phase, const VoiceTurnPhaseTerminal(VoiceTurnTerminalReason.success));
      expect(drained.effects.whereType<VoiceTurnEffectStopPlayback>(), isEmpty);

      // Control: a lease that is STILL active at terminate time DOES get
      // stopped.
      final cancelled =
          _reduce(model, VoiceTurnEventCancel(turnId: fixture.turnId, reason: VoiceTurnTerminalReason.cancelled));
      expect(
        cancelled.effects,
        contains(VoiceTurnEffectStopPlayback(turnId: fixture.turnId, leaseId: activeLease.id)),
      );
    });

    // Effect emission ORDER inside `_terminate` is load-bearing: `stopCapture`
    // must precede `cancelHub`, or a trailing PCM chunk can revive the
    // socket the reducer just asked the host to tear down. Order is
    // invisible to `contains`, so it needs its own assertion.
    test('terminateEmitsStopCaptureBeforeCancelHub', () {
      final turnId = _newTurnId();
      final captureId = _capture(11);
      var model = _reduce(_idle, VoiceTurnEventStart(turnId: turnId, intent: VoiceTurnIntent.hold)).model;
      model = _reduce(model, VoiceTurnEventCaptureStarted(turnId: turnId, captureId: captureId)).model;
      model = _reduce(model, VoiceTurnEventSelectRoute(turnId: turnId, route: _hub(_newSessionId()))).model;

      final cancelled = _reduce(model, VoiceTurnEventCancel(turnId: turnId, reason: VoiceTurnTerminalReason.cancelled));

      final order = cancelled.effects
          .where((e) => e is VoiceTurnEffectStopCapture || e is VoiceTurnEffectCancelHub)
          .map((e) => e.runtimeType)
          .toList();
      expect(order, [VoiceTurnEffectStopCapture, VoiceTurnEffectCancelHub]);
    });
  });
}
