// The reducer: `reduceVoiceTurn(model, event) -> (model, effects)`. A 1:1
// port of `reduceVoiceTurn` in
// `desktop/windows/src/renderer/src/lib/voice/turn/voiceTurnMachine.ts`
// (TS lines 641-1145 in the source read for this port). Types live in
// `voice_turn_machine.dart`; this file is pure logic only — no timers, no
// clock, no I/O, no randomness, no ID minting. The coordinator (a later
// step, see design doc §8 point 4 onward — NOT part of this change) owns
// all of that.
//
// Structural note vs. TS: TS mutates a `MutableModel`/`MutableTurn` draft
// cloned from the frozen input, then returns it as the (structurally
// identical, TS has no separate mutable/immutable types) output. Dart's
// `VoiceTurn`/`VoiceTurnModel` in the sibling file are immutable value
// classes, so this file introduces private `_MutableTurn`/`_MutableModel`
// working copies purely as an implementation detail, frozen back into the
// public immutable types on every return. This mirrors the TS source's own
// "Swift binds `guard var turn = model.turn` — a VALUE COPY" port note:
// every GUARD below reads the frozen pre-event `turn` (`current.turn`);
// every WRITE goes through the mutable `draft`. Never read `draft` where the
// original reads `turn`.

import 'package:collection/collection.dart';

import 'voice_turn_machine.dart';

class VoiceTurnReduction {
  final VoiceTurnModel model;
  final List<VoiceTurnEffect> effects;
  const VoiceTurnReduction({required this.model, required this.effects});
}

// ---------------------------------------------------------------------------
// MARK: - Mutable draft (the Dart stand-in for TS's `MutableModel`, which is
// distinct from the frozen `turn` value read by guards)
// ---------------------------------------------------------------------------

class _MutableProjection {
  bool isListening;
  bool isLocked;
  bool isFollowUp;
  String transcript;
  String hint;
  bool isThinking;
  bool isResponseWaiting;
  bool isResponseActive;

  _MutableProjection({
    required this.isListening,
    required this.isLocked,
    required this.isFollowUp,
    required this.transcript,
    required this.hint,
    required this.isThinking,
    required this.isResponseWaiting,
    required this.isResponseActive,
  });

  factory _MutableProjection.from(VoiceTurnUiProjection p) => _MutableProjection(
        isListening: p.isListening,
        isLocked: p.isLocked,
        isFollowUp: p.isFollowUp,
        transcript: p.transcript,
        hint: p.hint,
        isThinking: p.isThinking,
        isResponseWaiting: p.isResponseWaiting,
        isResponseActive: p.isResponseActive,
      );

  VoiceTurnUiProjection freeze() => VoiceTurnUiProjection(
        isListening: isListening,
        isLocked: isLocked,
        isFollowUp: isFollowUp,
        transcript: transcript,
        hint: hint,
        isThinking: isThinking,
        isResponseWaiting: isResponseWaiting,
        isResponseActive: isResponseActive,
      );
}

class _MutableTurn {
  final VoiceTurnId id;
  VoiceTurnIntent intent;
  VoiceTurnPhase phase;
  VoiceTurnRoute route;
  VoiceCaptureId? captureId;
  VoiceSessionId? sessionId;
  VoiceResponseId? responseId;
  Set<VoiceToolCallId> pendingToolCallIds;
  VoiceOutputLease? activeLease;
  bool providerFinished;
  Set<VoiceTurnDeadline> deadlines;
  _MutableProjection projection;
  VoiceTurnTerminalReason? terminalReason;

  _MutableTurn({
    required this.id,
    required this.intent,
    required this.phase,
    required this.route,
    required this.captureId,
    required this.sessionId,
    required this.responseId,
    required this.pendingToolCallIds,
    required this.activeLease,
    required this.providerFinished,
    required this.deadlines,
    required this.projection,
    required this.terminalReason,
  });

  VoiceTurn freeze() => VoiceTurn(
        id: id,
        intent: intent,
        phase: phase,
        route: route,
        captureId: captureId,
        sessionId: sessionId,
        responseId: responseId,
        pendingToolCallIds: UnmodifiableSetView(Set.of(pendingToolCallIds)),
        activeLease: activeLease,
        providerFinished: providerFinished,
        deadlines: UnmodifiableSetView(Set.of(deadlines)),
        projection: projection.freeze(),
        terminalReason: terminalReason,
      );
}

_MutableTurn _cloneTurn(VoiceTurn turn) => _MutableTurn(
      id: turn.id,
      intent: turn.intent,
      phase: turn.phase,
      route: turn.route,
      captureId: turn.captureId,
      sessionId: turn.sessionId,
      responseId: turn.responseId,
      pendingToolCallIds: Set.of(turn.pendingToolCallIds),
      activeLease: turn.activeLease,
      providerFinished: turn.providerFinished,
      deadlines: Set.of(turn.deadlines),
      projection: _MutableProjection.from(turn.projection),
      terminalReason: turn.terminalReason,
    );

_MutableTurn _newVoiceTurn(VoiceTurnId id, VoiceTurnIntent intent) {
  final locked = intent == VoiceTurnIntent.locked;
  final followUp = intent == VoiceTurnIntent.agentFollowUp;
  return _MutableTurn(
    id: id,
    intent: intent,
    phase: locked ? const VoiceTurnPhaseLockedRecording() : const VoiceTurnPhaseRecording(),
    route: followUp ? const VoiceTurnRouteAgentFollowUp() : const VoiceTurnRouteUndecided(),
    captureId: null,
    sessionId: null,
    responseId: null,
    pendingToolCallIds: <VoiceToolCallId>{},
    activeLease: null,
    providerFinished: false,
    deadlines: <VoiceTurnDeadline>{},
    projection: _MutableProjection(
      isListening: true,
      isLocked: locked,
      isFollowUp: followUp,
      transcript: '',
      hint: '',
      isThinking: false,
      isResponseWaiting: false,
      isResponseActive: false,
    ),
    terminalReason: null,
  );
}

class _MutableModel {
  _MutableTurn? turn;
  VoiceTurnTerminalRecord? lastTerminal;
  int staleEventCount;
  int invalidTransitionCount;
  int duplicateTerminalCount;

  _MutableModel({
    required this.turn,
    required this.lastTerminal,
    required this.staleEventCount,
    required this.invalidTransitionCount,
    required this.duplicateTerminalCount,
  });

  VoiceTurnModel freeze() => VoiceTurnModel(
        turn: turn?.freeze(),
        lastTerminal: lastTerminal,
        staleEventCount: staleEventCount,
        invalidTransitionCount: invalidTransitionCount,
        duplicateTerminalCount: duplicateTerminalCount,
      );
}

// ---------------------------------------------------------------------------
// MARK: - Identity fencing
// ---------------------------------------------------------------------------

/// `stored == null -> accept (and incoming becomes the new stored). stored
/// != null -> incoming MUST match exactly; a null incoming here is ALSO
/// stale.` This is NOT `incoming != null && incoming != stored` — that
/// naive rewrite silently accepts a callback that lost its identity. See the
/// design doc §5 "Identity fencing" and the TS source's own warning at
/// `voiceTurnMachine.ts:443-450`. Two deliberate exceptions to this general
/// rule live inline in `hubCommitAccepted` and `captureFailed` below, not
/// here.
bool _fenceId<T>(T? stored, T? incoming) {
  if (stored == null) return true;
  return incoming == stored;
}

// ---------------------------------------------------------------------------
// MARK: - Deadline bookkeeping
// ---------------------------------------------------------------------------

/// ALWAYS inserts and ALWAYS emits — re-scheduling a held deadline resets
/// the timer (the coordinator cancels the old handle first). `hintChanged`
/// relies on this.
void _schedule(VoiceTurnDeadline deadline, double after, _MutableModel model, List<VoiceTurnEffect> effects) {
  final turn = model.turn;
  if (turn == null) return;
  turn.deadlines.add(deadline);
  effects.add(VoiceTurnEffectScheduleDeadline(turnId: turn.id, deadline: deadline, after: after));
}

/// Emits `cancelDeadline` ONLY if the deadline was actually held (`Set`
/// removal returning true). Unconditional emission breaks exactly-once
/// effect counting.
void _cancel(VoiceTurnDeadline deadline, _MutableModel model, List<VoiceTurnEffect> effects) {
  final turn = model.turn;
  if (turn == null) return;
  if (!turn.deadlines.remove(deadline)) return;
  effects.add(VoiceTurnEffectCancelDeadline(turnId: turn.id, deadline: deadline));
}

void _stale(_MutableModel model, VoiceTurnEvent event, List<VoiceTurnEffect> effects) {
  model.staleEventCount += 1;
  effects.add(VoiceTurnEffectStaleEventDropped(turnId: turnIdOf(event), event: diagnosticLabel(event)));
}

void _invalid(_MutableModel model, VoiceTurnEvent event, List<VoiceTurnEffect> effects) {
  model.invalidTransitionCount += 1;
  effects.add(
    VoiceTurnEffectInvalidTransition(turnId: turnIdOf(event), event: diagnosticLabel(event), phase: model.turn?.phase),
  );
}

/// The single terminal path. Effect emission ORDER is load-bearing:
/// `stopCapture` BEFORE `cancelHub`, or a trailing PCM chunk revives the
/// socket the reducer just asked the host to tear down.
void _terminate(
  _MutableModel model,
  VoiceTurnTerminalReason reason,
  List<VoiceTurnEffect> effects,
  VoiceTurnDeadlines deadlines,
) {
  final turn = model.turn;
  if (turn == null) return;
  if (isTerminal(turn.phase)) {
    model.duplicateTerminalCount += 1;
    return;
  }

  final record = VoiceTurnTerminalRecord(turnId: turn.id, reason: reason, route: turn.route);

  if (turn.captureId != null || isRecording(turn.phase) || turn.phase is VoiceTurnPhaseFinalizing) {
    effects.add(VoiceTurnEffectStopCapture(turnId: turn.id, captureId: turn.captureId));
  }

  // THE warm-hub feature: a barge-in that supersedes a turn on the hub
  // route hands the live socket to the successor — no cancelHub, no
  // stopPlayback.
  final preservesHubForBargeInHandoff =
      reason == VoiceTurnTerminalReason.interruptedByBargeIn && turn.route is VoiceTurnRouteHub;

  if (!preservesHubForBargeInHandoff) {
    effects.add(VoiceTurnEffectCancelHub(turnId: turn.id, route: turn.route));
  }
  if (turn.activeLease != null && !preservesHubForBargeInHandoff) {
    effects.add(VoiceTurnEffectStopPlayback(turnId: turn.id, leaseId: turn.activeLease!.id));
  }
  effects.add(VoiceTurnEffectCancelAllDeadlines(turnId: turn.id));
  effects.add(VoiceTurnEffectTerminal(record: record));

  turn.deadlines.clear();
  turn.pendingToolCallIds.clear();
  turn.activeLease = null;
  turn.terminalReason = reason;
  turn.phase = VoiceTurnPhaseTerminal(reason);
  turn.projection = _MutableProjection.from(idleVoiceTurnProjection);

  final hint = terminalHint(reason);
  if (hint != null) {
    turn.projection.hint = hint;
    // Inserted DIRECTLY, not via `_schedule()`.
    turn.deadlines.add(VoiceTurnDeadline.hintVisibility);
    effects.add(
      VoiceTurnEffectScheduleDeadline(
        turnId: turn.id,
        deadline: VoiceTurnDeadline.hintVisibility,
        after: deadlines.hintVisibility,
      ),
    );
  }

  model.lastTerminal = record;
}

// ---------------------------------------------------------------------------
// MARK: - The reducer
// ---------------------------------------------------------------------------

VoiceTurnReduction reduceVoiceTurn(
  VoiceTurnModel current,
  VoiceTurnEvent event, {
  VoiceTurnDeadlines deadlines = defaultVoiceTurnDeadlines,
}) {
  final model = _MutableModel(
    turn: current.turn == null ? null : _cloneTurn(current.turn!),
    lastTerminal: current.lastTerminal,
    staleEventCount: current.staleEventCount,
    invalidTransitionCount: current.invalidTransitionCount,
    duplicateTerminalCount: current.duplicateTerminalCount,
  );
  final effects = <VoiceTurnEffect>[];

  // Level 0 — turn-independent events, before any guard.

  if (event is VoiceTurnEventStart) {
    final active = model.turn;
    if (active != null && !isTerminal(active.phase)) {
      _terminate(model, VoiceTurnTerminalReason.interruptedByBargeIn, effects, deadlines);
    } else if (active != null && active.deadlines.isNotEmpty) {
      effects.add(VoiceTurnEffectCancelAllDeadlines(turnId: active.id));
    }
    model.turn = _newVoiceTurn(event.turnId, event.intent);
    model.staleEventCount = 0;
    model.invalidTransitionCount = 0;
    model.duplicateTerminalCount = 0;
    _schedule(VoiceTurnDeadline.captureStart, deadlines.captureStart, model, effects);
    return VoiceTurnReduction(model: model.freeze(), effects: effects);
  }

  if (event is VoiceTurnEventCleanup) {
    if (model.turn != null) {
      _terminate(model, VoiceTurnTerminalReason.cleanup, effects, deadlines);
    }
    return VoiceTurnReduction(model: model.freeze(), effects: effects);
  }

  if (event is VoiceTurnEventReset) {
    final turn = model.turn;
    if (turn == null || isTerminal(turn.phase)) {
      if (turn != null && turn.deadlines.isNotEmpty) {
        effects.add(VoiceTurnEffectCancelAllDeadlines(turnId: turn.id));
      }
      model.turn = null;
    } else {
      _invalid(model, event, effects);
    }
    return VoiceTurnReduction(model: model.freeze(), effects: effects);
  }

  // Level 1 — turn guard. `turn` is the PRE-EVENT snapshot (Swift/TS's
  // value copy); every guard below reads it, never `model.turn`/`draft`.
  //
  // `event` is cast to the sealed `VoiceTurnScopedEvent` here (not merely
  // promoted — Dart's flow analysis does not narrow a sealed type by
  // elimination across separate `if (x is T) return;` statements the way
  // TypeScript's control-flow analysis does): the three checks above only
  // proved, at runtime, that `event` is not `start`/`cleanup`/`reset`. The
  // cast is safe precisely because of that runtime proof, and switching on
  // `scoped` below is what makes the Level-3 switch exhaustive over exactly
  // the 29 turn-scoped leaves instead of all 31 `VoiceTurnEvent` variants.
  final turn = current.turn;
  if (turn == null) {
    _stale(model, event, effects);
    return VoiceTurnReduction(model: model.freeze(), effects: effects);
  }
  final scoped = event as VoiceTurnScopedEvent;
  if (scoped.turnId != turn.id) {
    _stale(model, event, effects);
    return VoiceTurnReduction(model: model.freeze(), effects: effects);
  }

  // The mutable twin of `turn` — every WRITE goes here, every GUARD reads
  // `turn`.
  final draft = model.turn!;

  // Level 2 — a terminal turn accepts exactly one event.
  if (isTerminal(turn.phase)) {
    if (event is VoiceTurnEventDeadlineFired &&
        event.deadline == VoiceTurnDeadline.hintVisibility &&
        turn.deadlines.contains(VoiceTurnDeadline.hintVisibility)) {
      draft.deadlines.remove(VoiceTurnDeadline.hintVisibility);
      draft.projection.hint = '';
      return VoiceTurnReduction(model: model.freeze(), effects: effects);
    }
    if (event is VoiceTurnEventFinish || event is VoiceTurnEventCancel) {
      model.duplicateTerminalCount += 1;
    } else {
      _stale(model, event, effects);
    }
    return VoiceTurnReduction(model: model.freeze(), effects: effects);
  }

  // Level 3 — per-event guards.

  switch (scoped) {
    case VoiceTurnEventOpenLockWindow():
      if (turn.phase is! VoiceTurnPhaseRecording) {
        _invalid(model, event, effects);
        break;
      }
      draft.phase = const VoiceTurnPhasePendingLockDecision();
      draft.projection.isListening = true;
      draft.projection.isLocked = false;
      _schedule(VoiceTurnDeadline.lockDecision, deadlines.lockDecision, model, effects);
      break;

    case VoiceTurnEventLock():
      if (turn.phase is! VoiceTurnPhaseRecording && turn.phase is! VoiceTurnPhasePendingLockDecision) {
        _invalid(model, event, effects);
        break;
      }
      _cancel(VoiceTurnDeadline.lockDecision, model, effects);
      draft.phase = const VoiceTurnPhaseLockedRecording();
      draft.intent = VoiceTurnIntent.locked;
      draft.projection.isListening = true;
      draft.projection.isLocked = true;
      break;

    case VoiceTurnEventFinalize():
      if (!isRecording(turn.phase)) {
        _invalid(model, event, effects);
        break;
      }
      _cancel(VoiceTurnDeadline.lockDecision, model, effects);
      _cancel(VoiceTurnDeadline.captureStart, model, effects);
      draft.phase = const VoiceTurnPhaseFinalizing();
      draft.projection.isListening = false;
      draft.projection.isLocked = false;
      draft.projection.isThinking = true;
      effects.add(VoiceTurnEffectStopCapture(turnId: turn.id, captureId: turn.captureId));
      break;

    case VoiceTurnEventCaptureStarted():
      if (!isRecording(turn.phase)) {
        // Kill the orphan capture — it can never reach this turn.
        _stale(model, event, effects);
        effects.add(VoiceTurnEffectStopCapture(turnId: turn.id, captureId: scoped.captureId));
        return VoiceTurnReduction(model: model.freeze(), effects: effects);
      }
      _cancel(VoiceTurnDeadline.captureStart, model, effects);
      draft.captureId = scoped.captureId;
      break;

    case VoiceTurnEventCaptureFailed():
      // Asymmetric on purpose: BOTH ids must be non-null to be stale. A
      // failure before capture ever started (null captureId) is ACCEPTED.
      if (turn.captureId != null && scoped.captureId != null && turn.captureId != scoped.captureId) {
        _stale(model, event, effects);
        break;
      }
      _terminate(model, VoiceTurnTerminalReason.captureFailed, effects, deadlines);
      break;

    case VoiceTurnEventSelectRoute():
      if (!isRecording(turn.phase) && turn.phase is! VoiceTurnPhaseFinalizing) {
        _invalid(model, event, effects);
        break;
      }
      draft.route = scoped.route;
      if (scoped.route is VoiceTurnRouteHubWarmWait) {
        _schedule(VoiceTurnDeadline.hubWarm, deadlines.hubWarm, model, effects);
      }
      break;

    case VoiceTurnEventHubReady():
      if (turn.route is! VoiceTurnRouteHubWarmWait) {
        _stale(model, event, effects);
        break;
      }
      _cancel(VoiceTurnDeadline.hubWarm, model, effects);
      draft.route = VoiceTurnRouteHub(scoped.sessionId);
      draft.sessionId = scoped.sessionId;
      break;

    case VoiceTurnEventHubCommitAccepted():
      final isDeferredCommit = turn.phase is VoiceTurnPhaseAwaitingResponse &&
          (turn.deadlines.contains(VoiceTurnDeadline.deferredCommit) ||
              turn.deadlines.contains(VoiceTurnDeadline.bargeInReplacement));
      if (!((turn.phase is VoiceTurnPhaseFinalizing || isDeferredCommit) && routeMatchesHub(turn.route))) {
        _invalid(model, event, effects);
        break;
      }
      // Asymmetric on purpose: the event's sessionId is non-optional here,
      // so this is a plain equality fence, not `_fenceId`.
      if (!(turn.sessionId == null || turn.sessionId == scoped.sessionId)) {
        _stale(model, event, effects);
        break;
      }
      draft.route = VoiceTurnRouteHub(scoped.sessionId);
      draft.sessionId = scoped.sessionId;
      draft.responseId = scoped.responseId;
      draft.phase = const VoiceTurnPhaseAwaitingResponse();
      draft.projection.isThinking = true;
      draft.projection.isResponseWaiting = true;
      _cancel(VoiceTurnDeadline.deferredCommit, model, effects);
      _cancel(VoiceTurnDeadline.bargeInReplacement, model, effects);
      _schedule(VoiceTurnDeadline.providerResponse, deadlines.providerResponse, model, effects);
      break;

    case VoiceTurnEventHubCommitDeferred():
      if (turn.phase is! VoiceTurnPhaseFinalizing || !routeMatchesHub(turn.route)) {
        _invalid(model, event, effects);
        break;
      }
      draft.phase = const VoiceTurnPhaseAwaitingResponse();
      draft.projection.isThinking = true;
      draft.projection.isResponseWaiting = true;
      _schedule(VoiceTurnDeadline.deferredCommit, deadlines.deferredCommit, model, effects);
      break;

    case VoiceTurnEventHubCommitDeferredForReplacement():
      if (turn.phase is! VoiceTurnPhaseFinalizing || !routeMatchesHub(turn.route)) {
        _invalid(model, event, effects);
        break;
      }
      draft.phase = const VoiceTurnPhaseAwaitingResponse();
      draft.projection.isThinking = true;
      draft.projection.isResponseWaiting = true;
      _schedule(VoiceTurnDeadline.bargeInReplacement, deadlines.bargeInReplacement, model, effects);
      break;

    case VoiceTurnEventTranscriptionStarted():
      if (turn.phase is! VoiceTurnPhaseFinalizing) {
        _invalid(model, event, effects);
        break;
      }
      draft.projection.isThinking = true;
      draft.projection.transcript = 'Transcribing…';
      _schedule(VoiceTurnDeadline.transcription, deadlines.transcription, model, effects);
      break;

    case VoiceTurnEventTranscriptionFinal():
      if (turn.phase is! VoiceTurnPhaseFinalizing) {
        _stale(model, event, effects);
        break;
      }
      _cancel(VoiceTurnDeadline.transcription, model, effects);
      draft.phase = const VoiceTurnPhaseAwaitingResponse();
      draft.projection.transcript = scoped.text;
      draft.projection.isThinking = true;
      draft.projection.isResponseWaiting = true;
      _schedule(VoiceTurnDeadline.providerResponse, deadlines.providerResponse, model, effects);
      break;

    case VoiceTurnEventTranscriptionFailed():
      _terminate(model, VoiceTurnTerminalReason.transcriptionFailed, effects, deadlines);
      break;

    case VoiceTurnEventProviderResponseStarted():
      if (!acceptsProviderOutput(turn.phase)) {
        _invalid(model, event, effects);
        break;
      }
      if (!_fenceId(turn.sessionId, scoped.sessionId) || !_fenceId(turn.responseId, scoped.responseId)) {
        _stale(model, event, effects);
        break;
      }
      _cancel(VoiceTurnDeadline.providerResponse, model, effects);
      _cancel(VoiceTurnDeadline.deferredCommit, model, effects);
      _cancel(VoiceTurnDeadline.bargeInReplacement, model, effects);
      draft.sessionId = scoped.sessionId ?? turn.sessionId;
      draft.responseId = scoped.responseId ?? turn.responseId;
      draft.projection.isThinking = false;
      draft.projection.isResponseWaiting = false;
      draft.projection.isResponseActive = true;
      // Phase deliberately unchanged.
      break;

    case VoiceTurnEventProviderTurnFinished():
      if (!acceptsProviderOutput(turn.phase)) {
        _invalid(model, event, effects);
        break;
      }
      if (!_fenceId(turn.sessionId, scoped.sessionId) || !_fenceId(turn.responseId, scoped.responseId)) {
        _stale(model, event, effects);
        break;
      }
      draft.providerFinished = true;
      _cancel(VoiceTurnDeadline.providerResponse, model, effects);
      _cancel(VoiceTurnDeadline.deferredCommit, model, effects);
      _cancel(VoiceTurnDeadline.bargeInReplacement, model, effects);
      if (turn.activeLease == null && turn.pendingToolCallIds.isEmpty) {
        _terminate(model, VoiceTurnTerminalReason.success, effects, deadlines);
      }
      break;

    case VoiceTurnEventToolStarted():
      if (!acceptsProviderOutput(turn.phase)) {
        _invalid(model, event, effects);
        break;
      }
      draft.pendingToolCallIds.add(scoped.callId);
      // Even from `playing` — and `activeLease` is kept.
      draft.phase = const VoiceTurnPhaseAwaitingTools();
      _schedule(VoiceTurnDeadline.pendingTools, deadlines.pendingTools, model, effects);
      break;

    case VoiceTurnEventToolFinished():
      if (!turn.pendingToolCallIds.contains(scoped.callId)) {
        _stale(model, event, effects);
        break;
      }
      draft.pendingToolCallIds.remove(scoped.callId);
      if (draft.pendingToolCallIds.isEmpty) {
        _cancel(VoiceTurnDeadline.pendingTools, model, effects);
        if (turn.providerFinished && turn.activeLease == null) {
          _terminate(model, VoiceTurnTerminalReason.success, effects, deadlines);
        } else if (turn.activeLease != null) {
          draft.phase = VoiceTurnPhasePlaying(turn.activeLease!.lane);
        } else {
          draft.phase = const VoiceTurnPhaseAwaitingResponse();
          _schedule(VoiceTurnDeadline.providerResponse, deadlines.providerResponse, model, effects);
        }
      }
      break;

    case VoiceTurnEventPlaybackStarted():
      if (!acceptsProviderOutput(turn.phase)) {
        _invalid(model, event, effects);
        break;
      }
      if (scoped.lease.turnId != turn.id) {
        _stale(model, event, effects);
        break;
      }
      // A DIFFERENT already-active lease is a real bug, not staleness.
      if (turn.activeLease != null && !leasesEqual(turn.activeLease!, scoped.lease)) {
        _invalid(model, event, effects);
        break;
      }
      _cancel(VoiceTurnDeadline.providerResponse, model, effects);
      draft.activeLease = scoped.lease;
      draft.phase = VoiceTurnPhasePlaying(scoped.lease.lane);
      draft.projection.isThinking = false;
      draft.projection.isResponseWaiting = false;
      draft.projection.isResponseActive = true;
      _schedule(VoiceTurnDeadline.playbackDrain, deadlines.playbackDrain, model, effects);
      break;

    case VoiceTurnEventPlaybackDrained():
      if (turn.activeLease == null || turn.activeLease!.id != scoped.leaseId) {
        _stale(model, event, effects);
        break;
      }
      _cancel(VoiceTurnDeadline.playbackDrain, model, effects);
      draft.activeLease = null;
      if (turn.providerFinished && turn.pendingToolCallIds.isEmpty) {
        _terminate(model, VoiceTurnTerminalReason.success, effects, deadlines);
      } else if (turn.pendingToolCallIds.isNotEmpty) {
        draft.phase = const VoiceTurnPhaseAwaitingTools();
        draft.projection.isResponseActive = false;
        draft.projection.isResponseWaiting = false;
      } else {
        draft.phase = const VoiceTurnPhaseAwaitingResponse();
        draft.projection.isResponseActive = false;
        draft.projection.isResponseWaiting = true;
        _schedule(VoiceTurnDeadline.providerResponse, deadlines.providerResponse, model, effects);
      }
      break;

    case VoiceTurnEventPlaybackFailed():
      // A null leaseId always applies.
      if (scoped.leaseId != null && turn.activeLease?.id != scoped.leaseId) {
        _stale(model, event, effects);
        break;
      }
      _terminate(model, VoiceTurnTerminalReason.playbackFailed, effects, deadlines);
      break;

    case VoiceTurnEventTranscriptChanged():
      draft.projection.transcript = scoped.text;
      break;

    case VoiceTurnEventHintChanged():
      draft.projection.hint = scoped.text;
      if (scoped.text == '') {
        _cancel(VoiceTurnDeadline.hintVisibility, model, effects);
      } else {
        _schedule(VoiceTurnDeadline.hintVisibility, deadlines.hintVisibility, model, effects);
      }
      break;

    case VoiceTurnEventResponseWaitingChanged():
      draft.projection.isResponseWaiting = scoped.active;
      draft.projection.isThinking = scoped.active;
      break;

    case VoiceTurnEventResponseActiveChanged():
      draft.projection.isResponseActive = scoped.active;
      if (scoped.active) {
        draft.projection.isThinking = false;
        draft.projection.isResponseWaiting = false;
      }
      break;

    case VoiceTurnEventClearPresentation():
      draft.projection = _MutableProjection.from(idleVoiceTurnProjection);
      _cancel(VoiceTurnDeadline.hintVisibility, model, effects);
      break;

    case VoiceTurnEventDeadlineFired():
      if (!turn.deadlines.contains(scoped.deadline)) {
        _stale(model, event, effects);
        break;
      }
      draft.deadlines.remove(scoped.deadline);
      switch (scoped.deadline) {
        case VoiceTurnDeadline.lockDecision:
          if (turn.phase is! VoiceTurnPhasePendingLockDecision) {
            _stale(model, event, effects);
            break;
          }
          draft.phase = const VoiceTurnPhaseFinalizing();
          draft.projection.isListening = false;
          draft.projection.isThinking = true;
          effects.add(VoiceTurnEffectStopCapture(turnId: turn.id, captureId: turn.captureId));
          break;
        case VoiceTurnDeadline.captureStart:
          _terminate(model, VoiceTurnTerminalReason.captureFailed, effects, deadlines);
          break;
        case VoiceTurnDeadline.hubWarm:
          // NON-TERMINAL. The turn continues on the cascade.
          effects.add(
            VoiceTurnEffectFallbackToTranscription(turnId: turn.id, reason: VoiceTurnTerminalReason.hubWarmTimeout),
          );
          draft.route = const VoiceTurnRouteDeepgramBatch();
          if (turn.phase is VoiceTurnPhaseFinalizing) {
            _schedule(VoiceTurnDeadline.transcription, deadlines.transcription, model, effects);
          }
          break;
        case VoiceTurnDeadline.transcription:
          _terminate(model, VoiceTurnTerminalReason.transcriptionFailed, effects, deadlines);
          break;
        case VoiceTurnDeadline.providerResponse:
          _terminate(model, VoiceTurnTerminalReason.providerNoResponse, effects, deadlines);
          break;
        case VoiceTurnDeadline.pendingTools:
          _terminate(model, VoiceTurnTerminalReason.toolTimeout, effects, deadlines);
          break;
        case VoiceTurnDeadline.deferredCommit:
          _terminate(model, VoiceTurnTerminalReason.deferredCommitTimeout, effects, deadlines);
          break;
        case VoiceTurnDeadline.bargeInReplacement:
          _terminate(model, VoiceTurnTerminalReason.bargeInReplacementTimeout, effects, deadlines);
          break;
        case VoiceTurnDeadline.playbackDrain:
          _terminate(model, VoiceTurnTerminalReason.playbackFailed, effects, deadlines);
          break;
        case VoiceTurnDeadline.hintVisibility:
          draft.projection.hint = '';
          break;
      }
      break;

    case VoiceTurnEventFinish():
      _terminate(model, scoped.reason, effects, deadlines);
      break;

    case VoiceTurnEventCancel():
      _terminate(model, scoped.reason, effects, deadlines);
      break;

    // Unreachable — `start` is handled at Level 0 and always returns before
    // this switch is reached; kept as an explicit throwing case (rather than
    // a catch-all `default`) so this switch stays exhaustive over exactly
    // `VoiceTurnScopedEvent`'s 29 leaves (see the cast above the Level-1
    // turn guard) and still fails the build if a leaf is added without
    // updating this switch — mirroring the TS source's
    // `const unhandled: never = event` guard. `cleanup`/`reset` are NOT
    // listed here: they are not `VoiceTurnScopedEvent` subtypes at all, so
    // including them would be a compile-time "pattern can never match"
    // error, not a safety net.
    case VoiceTurnEventStart():
      throw StateError('unreachable: ${scoped.runtimeType} is handled at Level 0');
  }

  return VoiceTurnReduction(model: model.freeze(), effects: effects);
}
