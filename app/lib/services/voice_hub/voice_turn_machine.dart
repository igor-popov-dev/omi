// Pure, event-sourced voice-turn state machine — a 1:1 port of the desktop
// (Electron/TS) reducer at
// `desktop/windows/src/renderer/src/lib/voice/turn/voiceTurnMachine.ts`
// (itself a port of macOS `VoiceTurnStateMachine.swift` / `VoiceTurnReducer`).
// One turn is the unit of identity: every capture, hub session, provider
// response, tool call and audio lease is scoped to it, so a superseded
// turn's late callbacks are inert.
//
// This file holds ONLY the types (phases, routes, events, effects, model) and
// the small pure predicates/helpers that operate on them. The reducer itself
// (`reduceVoiceTurn`) lives in `voice_turn_reducer.dart`.
//
// Ground rule for the whole voice_hub/ package (design doc
// `~/omi-jarvis/docs/hub-port-design.md` §8): ZERO imports of Flutter,
// dart:io, or networking here. `package:collection` is a pure-Dart
// dependency already used elsewhere in this app (see pubspec.yaml) and is
// used below only for read-only Set views — it does not violate that rule.
//
// Naming note (deviation from the TS source, deliberate): TS identifiers use
// `ID` (`turnID`, `sessionID`); this port uses Dart's idiomatic `Id`
// (`turnId`, `sessionId`) throughout. Sealed-class variant names are
// prefixed (`VoiceTurnPhaseRecording`, not bare `Recording`) to avoid
// collisions with common English words already used elsewhere in this large
// app (`Idle`, `Recording`, `Finalizing`, ...) — the design doc's sketch used
// bare names, but this repo is a shared namespace, not an isolated module.
//
// Port notes (the traps a "natural" Dart translation gets wrong — carried
// over verbatim from the TS source's own port notes, which were themselves
// carried over from the Swift original):
//   * Identity fencing (`_fenceId` in the reducer file) is NOT
//     `incoming != null && incoming != stored`. Once a turn KNOWS an id, an
//     event carrying `null` is ALSO stale. See the two deliberate asymmetric
//     exceptions (`hubCommitAccepted`, `captureFailed`) in the reducer.
//   * `hubWarm` is NON-terminal: it falls back to transcription and the turn
//     CONTINUES.
//   * `terminate()` skips BOTH `cancelHub` and `stopPlayback` when a
//     barge-in supersedes a hub turn, so the successor inherits the live
//     warm socket. Effect emission order is load-bearing: `stopCapture`
//     before `cancelHub`.
//   * `cancel(deadline)` emits only if the deadline was actually held;
//     `schedule(deadline)` always inserts and always emits.

import 'package:collection/collection.dart';

// ---------------------------------------------------------------------------
// MARK: - Typed identities
//
// TS uses branded string/number types (`Branded<'VoiceTurnID'>`) for
// nominal-typing safety with zero runtime cost. Dart 3 extension types could
// do the same, but they require language version >=3.3 while this package's
// `pubspec.yaml` only guarantees `sdk: ">=3.0.0"` — plain typedefs are the
// pragmatic, dependency-free choice that still documents intent at call
// sites.
// ---------------------------------------------------------------------------

/// Swift/TS: `UUID` / `VoiceTurnID`.
typedef VoiceTurnId = String;

/// Swift/TS: `UInt64` / `VoiceCaptureID`.
typedef VoiceCaptureId = int;

/// Swift/TS: `UUID` / `VoiceSessionID`.
typedef VoiceSessionId = String;

/// Swift/TS: provider-supplied `String` / `VoiceResponseID`.
typedef VoiceResponseId = String;

/// Swift/TS: provider-supplied `String` / `VoiceToolCallID`.
typedef VoiceToolCallId = String;

/// Swift/TS: `UUID` / `VoiceLeaseID`.
typedef VoiceLeaseId = String;

// ---------------------------------------------------------------------------
// MARK: - State
// ---------------------------------------------------------------------------

enum VoiceTurnIntent { hold, locked, agentFollowUp, automation }

/// Orthogonal to phase. `VoiceTurnRouteHub.sessionId` is nullable — the host
/// emits `hub(sessionId: null)` when the hub is already active.
sealed class VoiceTurnRoute {
  const VoiceTurnRoute();
}

final class VoiceTurnRouteUndecided extends VoiceTurnRoute {
  const VoiceTurnRouteUndecided();
  @override
  bool operator ==(Object other) => other is VoiceTurnRouteUndecided;
  @override
  int get hashCode => (VoiceTurnRouteUndecided).hashCode;
  @override
  String toString() => 'VoiceTurnRouteUndecided()';
}

final class VoiceTurnRouteHubWarmWait extends VoiceTurnRoute {
  const VoiceTurnRouteHubWarmWait();
  @override
  bool operator ==(Object other) => other is VoiceTurnRouteHubWarmWait;
  @override
  int get hashCode => (VoiceTurnRouteHubWarmWait).hashCode;
  @override
  String toString() => 'VoiceTurnRouteHubWarmWait()';
}

final class VoiceTurnRouteHub extends VoiceTurnRoute {
  final VoiceSessionId? sessionId;
  const VoiceTurnRouteHub(this.sessionId);
  @override
  bool operator ==(Object other) => other is VoiceTurnRouteHub && other.sessionId == sessionId;
  @override
  int get hashCode => Object.hash(VoiceTurnRouteHub, sessionId);
  @override
  String toString() => 'VoiceTurnRouteHub(sessionId: $sessionId)';
}

final class VoiceTurnRouteOmniStt extends VoiceTurnRoute {
  const VoiceTurnRouteOmniStt();
  @override
  bool operator ==(Object other) => other is VoiceTurnRouteOmniStt;
  @override
  int get hashCode => (VoiceTurnRouteOmniStt).hashCode;
  @override
  String toString() => 'VoiceTurnRouteOmniStt()';
}

final class VoiceTurnRouteDeepgramBatch extends VoiceTurnRoute {
  const VoiceTurnRouteDeepgramBatch();
  @override
  bool operator ==(Object other) => other is VoiceTurnRouteDeepgramBatch;
  @override
  int get hashCode => (VoiceTurnRouteDeepgramBatch).hashCode;
  @override
  String toString() => 'VoiceTurnRouteDeepgramBatch()';
}

final class VoiceTurnRouteDeepgramLive extends VoiceTurnRoute {
  const VoiceTurnRouteDeepgramLive();
  @override
  bool operator ==(Object other) => other is VoiceTurnRouteDeepgramLive;
  @override
  int get hashCode => (VoiceTurnRouteDeepgramLive).hashCode;
  @override
  String toString() => 'VoiceTurnRouteDeepgramLive()';
}

final class VoiceTurnRouteAgentFollowUp extends VoiceTurnRoute {
  const VoiceTurnRouteAgentFollowUp();
  @override
  bool operator ==(Object other) => other is VoiceTurnRouteAgentFollowUp;
  @override
  int get hashCode => (VoiceTurnRouteAgentFollowUp).hashCode;
  @override
  String toString() => 'VoiceTurnRouteAgentFollowUp()';
}

enum VoiceOutputLane {
  nativeRealtime('native_realtime'),
  selectedVoiceFallback('selected_voice_fallback'),
  deterministicAgentAck('deterministic_agent_ack'),
  filler('filler'),
  systemVoiceFallback('system_voice_fallback');

  /// The telemetry string (Swift raw value).
  final String rawValue;
  const VoiceOutputLane(this.rawValue);
}

class VoiceOutputLease {
  final VoiceLeaseId id;
  final VoiceTurnId turnId;
  final VoiceOutputLane lane;

  const VoiceOutputLease({required this.id, required this.turnId, required this.lane});

  @override
  bool operator ==(Object other) =>
      other is VoiceOutputLease && other.id == id && other.turnId == turnId && other.lane == lane;
  @override
  int get hashCode => Object.hash(id, turnId, lane);
  @override
  String toString() => 'VoiceOutputLease(id: $id, turnId: $turnId, lane: $lane)';
}

enum VoiceTurnTerminalReason {
  success('success'),
  tooShort('too_short'),
  silentRejected('silent_rejected'),
  cancelled('cancelled'),
  interruptedByBargeIn('interrupted_by_barge_in'),
  permissionDenied('permission_denied'),
  captureFailed('capture_failed'),
  transcriptionFailed('transcription_failed'),
  providerFailed('provider_failed'),
  providerNoResponse('provider_no_response'),
  hubWarmTimeout('hub_warm_timeout'),
  deferredCommitTimeout('deferred_commit_timeout'),
  bargeInReplacementTimeout('barge_in_replacement_timeout'),
  toolTimeout('tool_timeout'),
  playbackFailed('playback_failed'),
  cleanup('cleanup');

  /// The telemetry string (Swift raw value).
  final String rawValue;
  const VoiceTurnTerminalReason(this.rawValue);
}

sealed class VoiceTurnPhase {
  const VoiceTurnPhase();
}

/// NOT constructed by the reducer at runtime — `model.turn == null` IS idle.
/// Kept for structural parity with the TS union (see design doc §5) and so a
/// future host-layer projection can still switch exhaustively over
/// `VoiceTurnPhase` including this case.
final class VoiceTurnPhaseIdle extends VoiceTurnPhase {
  const VoiceTurnPhaseIdle();
  @override
  bool operator ==(Object other) => other is VoiceTurnPhaseIdle;
  @override
  int get hashCode => (VoiceTurnPhaseIdle).hashCode;
  @override
  String toString() => 'VoiceTurnPhaseIdle()';
}

final class VoiceTurnPhasePendingLockDecision extends VoiceTurnPhase {
  const VoiceTurnPhasePendingLockDecision();
  @override
  bool operator ==(Object other) => other is VoiceTurnPhasePendingLockDecision;
  @override
  int get hashCode => (VoiceTurnPhasePendingLockDecision).hashCode;
  @override
  String toString() => 'VoiceTurnPhasePendingLockDecision()';
}

final class VoiceTurnPhaseRecording extends VoiceTurnPhase {
  const VoiceTurnPhaseRecording();
  @override
  bool operator ==(Object other) => other is VoiceTurnPhaseRecording;
  @override
  int get hashCode => (VoiceTurnPhaseRecording).hashCode;
  @override
  String toString() => 'VoiceTurnPhaseRecording()';
}

final class VoiceTurnPhaseLockedRecording extends VoiceTurnPhase {
  const VoiceTurnPhaseLockedRecording();
  @override
  bool operator ==(Object other) => other is VoiceTurnPhaseLockedRecording;
  @override
  int get hashCode => (VoiceTurnPhaseLockedRecording).hashCode;
  @override
  String toString() => 'VoiceTurnPhaseLockedRecording()';
}

final class VoiceTurnPhaseFinalizing extends VoiceTurnPhase {
  const VoiceTurnPhaseFinalizing();
  @override
  bool operator ==(Object other) => other is VoiceTurnPhaseFinalizing;
  @override
  int get hashCode => (VoiceTurnPhaseFinalizing).hashCode;
  @override
  String toString() => 'VoiceTurnPhaseFinalizing()';
}

final class VoiceTurnPhaseAwaitingResponse extends VoiceTurnPhase {
  const VoiceTurnPhaseAwaitingResponse();
  @override
  bool operator ==(Object other) => other is VoiceTurnPhaseAwaitingResponse;
  @override
  int get hashCode => (VoiceTurnPhaseAwaitingResponse).hashCode;
  @override
  String toString() => 'VoiceTurnPhaseAwaitingResponse()';
}

final class VoiceTurnPhaseAwaitingTools extends VoiceTurnPhase {
  const VoiceTurnPhaseAwaitingTools();
  @override
  bool operator ==(Object other) => other is VoiceTurnPhaseAwaitingTools;
  @override
  int get hashCode => (VoiceTurnPhaseAwaitingTools).hashCode;
  @override
  String toString() => 'VoiceTurnPhaseAwaitingTools()';
}

final class VoiceTurnPhasePlaying extends VoiceTurnPhase {
  final VoiceOutputLane lane;
  const VoiceTurnPhasePlaying(this.lane);
  @override
  bool operator ==(Object other) => other is VoiceTurnPhasePlaying && other.lane == lane;
  @override
  int get hashCode => Object.hash(VoiceTurnPhasePlaying, lane);
  @override
  String toString() => 'VoiceTurnPhasePlaying(lane: $lane)';
}

final class VoiceTurnPhaseTerminal extends VoiceTurnPhase {
  final VoiceTurnTerminalReason reason;
  const VoiceTurnPhaseTerminal(this.reason);
  @override
  bool operator ==(Object other) => other is VoiceTurnPhaseTerminal && other.reason == reason;
  @override
  int get hashCode => Object.hash(VoiceTurnPhaseTerminal, reason);
  @override
  String toString() => 'VoiceTurnPhaseTerminal(reason: $reason)';
}

enum VoiceTurnDeadline {
  lockDecision('lock_decision'),
  captureStart('capture_start'),
  hubWarm('hub_warm'),
  transcription('transcription'),
  providerResponse('provider_response'),
  pendingTools('pending_tools'),
  deferredCommit('deferred_commit'),
  bargeInReplacement('barge_in_replacement'),
  playbackDrain('playback_drain'),
  hintVisibility('hint_visibility');

  /// The telemetry string (Swift raw value).
  final String rawValue;
  const VoiceTurnDeadline(this.rawValue);
}

/// The ONLY thing the UI may read.
class VoiceTurnUiProjection {
  final bool isListening;
  final bool isLocked;
  final bool isFollowUp;
  final String transcript;
  final String hint;
  final bool isThinking;
  final bool isResponseWaiting;
  final bool isResponseActive;

  /// Free-form mode only: the provider's VAD hears the user talking right
  /// now (`HubSessionEvents.onUserSpeechState`). Distinguishes "the mic is
  /// open" from "it is picking you up" — the PTT path never sets it, hence
  /// the default instead of a required parameter.
  final bool isHearingUser;

  const VoiceTurnUiProjection({
    required this.isListening,
    required this.isLocked,
    required this.isFollowUp,
    required this.transcript,
    required this.hint,
    required this.isThinking,
    required this.isResponseWaiting,
    required this.isResponseActive,
    this.isHearingUser = false,
  });

  @override
  bool operator ==(Object other) =>
      other is VoiceTurnUiProjection &&
      other.isListening == isListening &&
      other.isLocked == isLocked &&
      other.isFollowUp == isFollowUp &&
      other.transcript == transcript &&
      other.hint == hint &&
      other.isThinking == isThinking &&
      other.isResponseWaiting == isResponseWaiting &&
      other.isResponseActive == isResponseActive &&
      other.isHearingUser == isHearingUser;

  @override
  int get hashCode => Object.hash(
        isListening,
        isLocked,
        isFollowUp,
        transcript,
        hint,
        isThinking,
        isResponseWaiting,
        isResponseActive,
        isHearingUser,
      );

  @override
  String toString() => 'VoiceTurnUiProjection(isListening: $isListening, isLocked: $isLocked, '
      'isFollowUp: $isFollowUp, transcript: $transcript, hint: $hint, '
      'isThinking: $isThinking, isResponseWaiting: $isResponseWaiting, '
      'isResponseActive: $isResponseActive, isHearingUser: $isHearingUser)';
}

const VoiceTurnUiProjection idleVoiceTurnProjection = VoiceTurnUiProjection(
  isListening: false,
  isLocked: false,
  isFollowUp: false,
  transcript: '',
  hint: '',
  isThinking: false,
  isResponseWaiting: false,
  isResponseActive: false,
);

class VoiceTurn {
  final VoiceTurnId id;
  final VoiceTurnIntent intent;
  final VoiceTurnPhase phase;
  final VoiceTurnRoute route;
  final VoiceCaptureId? captureId;
  final VoiceSessionId? sessionId;
  final VoiceResponseId? responseId;
  final Set<VoiceToolCallId> pendingToolCallIds;
  final VoiceOutputLease? activeLease;
  final bool providerFinished;
  final Set<VoiceTurnDeadline> deadlines;
  final VoiceTurnUiProjection projection;
  final VoiceTurnTerminalReason? terminalReason;

  const VoiceTurn({
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
}

class VoiceTurnTerminalRecord {
  final VoiceTurnId turnId;
  final VoiceTurnTerminalReason reason;
  final VoiceTurnRoute route;

  const VoiceTurnTerminalRecord({required this.turnId, required this.reason, required this.route});

  @override
  bool operator ==(Object other) =>
      other is VoiceTurnTerminalRecord && other.turnId == turnId && other.reason == reason && other.route == route;
  @override
  int get hashCode => Object.hash(turnId, reason, route);
  @override
  String toString() => 'VoiceTurnTerminalRecord(turnId: $turnId, reason: $reason, route: $route)';
}

class VoiceTurnModel {
  final VoiceTurn? turn;
  final VoiceTurnTerminalRecord? lastTerminal;
  final int staleEventCount;
  final int invalidTransitionCount;
  final int duplicateTerminalCount;

  const VoiceTurnModel({
    required this.turn,
    required this.lastTerminal,
    required this.staleEventCount,
    required this.invalidTransitionCount,
    required this.duplicateTerminalCount,
  });
}

const VoiceTurnModel idleVoiceTurnModel = VoiceTurnModel(
  turn: null,
  lastTerminal: null,
  staleEventCount: 0,
  invalidTransitionCount: 0,
  duplicateTerminalCount: 0,
);

// ---------------------------------------------------------------------------
// MARK: - Events
// ---------------------------------------------------------------------------

sealed class VoiceTurnEvent {
  const VoiceTurnEvent();
}

/// Every event except `cleanup`/`reset` is scoped to a turn.
sealed class VoiceTurnScopedEvent extends VoiceTurnEvent {
  const VoiceTurnScopedEvent();
  VoiceTurnId get turnId;
}

final class VoiceTurnEventStart extends VoiceTurnScopedEvent {
  @override
  final VoiceTurnId turnId;
  final VoiceTurnIntent intent;
  const VoiceTurnEventStart({required this.turnId, required this.intent});
}

final class VoiceTurnEventOpenLockWindow extends VoiceTurnScopedEvent {
  @override
  final VoiceTurnId turnId;
  const VoiceTurnEventOpenLockWindow({required this.turnId});
}

final class VoiceTurnEventLock extends VoiceTurnScopedEvent {
  @override
  final VoiceTurnId turnId;
  const VoiceTurnEventLock({required this.turnId});
}

final class VoiceTurnEventFinalize extends VoiceTurnScopedEvent {
  @override
  final VoiceTurnId turnId;
  const VoiceTurnEventFinalize({required this.turnId});
}

final class VoiceTurnEventCaptureStarted extends VoiceTurnScopedEvent {
  @override
  final VoiceTurnId turnId;
  final VoiceCaptureId captureId;
  const VoiceTurnEventCaptureStarted({required this.turnId, required this.captureId});
}

final class VoiceTurnEventCaptureFailed extends VoiceTurnScopedEvent {
  @override
  final VoiceTurnId turnId;
  final VoiceCaptureId? captureId;
  final String message;
  const VoiceTurnEventCaptureFailed({required this.turnId, required this.captureId, required this.message});
}

final class VoiceTurnEventSelectRoute extends VoiceTurnScopedEvent {
  @override
  final VoiceTurnId turnId;
  final VoiceTurnRoute route;
  const VoiceTurnEventSelectRoute({required this.turnId, required this.route});
}

final class VoiceTurnEventHubReady extends VoiceTurnScopedEvent {
  @override
  final VoiceTurnId turnId;
  final VoiceSessionId sessionId;
  const VoiceTurnEventHubReady({required this.turnId, required this.sessionId});
}

final class VoiceTurnEventHubCommitAccepted extends VoiceTurnScopedEvent {
  @override
  final VoiceTurnId turnId;
  final VoiceSessionId sessionId;
  final VoiceResponseId? responseId;
  const VoiceTurnEventHubCommitAccepted({required this.turnId, required this.sessionId, required this.responseId});
}

final class VoiceTurnEventHubCommitDeferred extends VoiceTurnScopedEvent {
  @override
  final VoiceTurnId turnId;
  const VoiceTurnEventHubCommitDeferred({required this.turnId});
}

final class VoiceTurnEventHubCommitDeferredForReplacement extends VoiceTurnScopedEvent {
  @override
  final VoiceTurnId turnId;
  const VoiceTurnEventHubCommitDeferredForReplacement({required this.turnId});
}

final class VoiceTurnEventTranscriptionStarted extends VoiceTurnScopedEvent {
  @override
  final VoiceTurnId turnId;
  const VoiceTurnEventTranscriptionStarted({required this.turnId});
}

final class VoiceTurnEventTranscriptionFinal extends VoiceTurnScopedEvent {
  @override
  final VoiceTurnId turnId;
  final String text;
  const VoiceTurnEventTranscriptionFinal({required this.turnId, required this.text});
}

final class VoiceTurnEventTranscriptionFailed extends VoiceTurnScopedEvent {
  @override
  final VoiceTurnId turnId;
  final String message;
  const VoiceTurnEventTranscriptionFailed({required this.turnId, required this.message});
}

final class VoiceTurnEventProviderResponseStarted extends VoiceTurnScopedEvent {
  @override
  final VoiceTurnId turnId;
  final VoiceSessionId? sessionId;
  final VoiceResponseId? responseId;
  const VoiceTurnEventProviderResponseStarted({
    required this.turnId,
    required this.sessionId,
    required this.responseId,
  });
}

final class VoiceTurnEventProviderTurnFinished extends VoiceTurnScopedEvent {
  @override
  final VoiceTurnId turnId;
  final VoiceSessionId? sessionId;
  final VoiceResponseId? responseId;
  const VoiceTurnEventProviderTurnFinished({
    required this.turnId,
    required this.sessionId,
    required this.responseId,
  });
}

final class VoiceTurnEventToolStarted extends VoiceTurnScopedEvent {
  @override
  final VoiceTurnId turnId;
  final VoiceToolCallId callId;
  const VoiceTurnEventToolStarted({required this.turnId, required this.callId});
}

final class VoiceTurnEventToolFinished extends VoiceTurnScopedEvent {
  @override
  final VoiceTurnId turnId;
  final VoiceToolCallId callId;
  const VoiceTurnEventToolFinished({required this.turnId, required this.callId});
}

final class VoiceTurnEventPlaybackStarted extends VoiceTurnScopedEvent {
  @override
  final VoiceTurnId turnId;
  final VoiceOutputLease lease;
  const VoiceTurnEventPlaybackStarted({required this.turnId, required this.lease});
}

final class VoiceTurnEventPlaybackDrained extends VoiceTurnScopedEvent {
  @override
  final VoiceTurnId turnId;
  final VoiceLeaseId leaseId;
  const VoiceTurnEventPlaybackDrained({required this.turnId, required this.leaseId});
}

final class VoiceTurnEventPlaybackFailed extends VoiceTurnScopedEvent {
  @override
  final VoiceTurnId turnId;
  final VoiceLeaseId? leaseId;
  final String message;
  const VoiceTurnEventPlaybackFailed({required this.turnId, required this.leaseId, required this.message});
}

final class VoiceTurnEventTranscriptChanged extends VoiceTurnScopedEvent {
  @override
  final VoiceTurnId turnId;
  final String text;
  const VoiceTurnEventTranscriptChanged({required this.turnId, required this.text});
}

final class VoiceTurnEventHintChanged extends VoiceTurnScopedEvent {
  @override
  final VoiceTurnId turnId;
  final String text;
  const VoiceTurnEventHintChanged({required this.turnId, required this.text});
}

final class VoiceTurnEventResponseWaitingChanged extends VoiceTurnScopedEvent {
  @override
  final VoiceTurnId turnId;
  final bool active;
  const VoiceTurnEventResponseWaitingChanged({required this.turnId, required this.active});
}

final class VoiceTurnEventResponseActiveChanged extends VoiceTurnScopedEvent {
  @override
  final VoiceTurnId turnId;
  final bool active;
  const VoiceTurnEventResponseActiveChanged({required this.turnId, required this.active});
}

final class VoiceTurnEventClearPresentation extends VoiceTurnScopedEvent {
  @override
  final VoiceTurnId turnId;
  const VoiceTurnEventClearPresentation({required this.turnId});
}

final class VoiceTurnEventDeadlineFired extends VoiceTurnScopedEvent {
  @override
  final VoiceTurnId turnId;
  final VoiceTurnDeadline deadline;
  const VoiceTurnEventDeadlineFired({required this.turnId, required this.deadline});
}

final class VoiceTurnEventFinish extends VoiceTurnScopedEvent {
  @override
  final VoiceTurnId turnId;
  final VoiceTurnTerminalReason reason;
  const VoiceTurnEventFinish({required this.turnId, required this.reason});
}

final class VoiceTurnEventCancel extends VoiceTurnScopedEvent {
  @override
  final VoiceTurnId turnId;
  final VoiceTurnTerminalReason reason;
  const VoiceTurnEventCancel({required this.turnId, required this.reason});
}

/// Turn-independent.
final class VoiceTurnEventCleanup extends VoiceTurnEvent {
  const VoiceTurnEventCleanup();
}

/// Turn-independent.
final class VoiceTurnEventReset extends VoiceTurnEvent {
  const VoiceTurnEventReset();
}

/// `cleanup` and `reset` are turn-independent.
VoiceTurnId? turnIdOf(VoiceTurnEvent event) => switch (event) {
      VoiceTurnEventCleanup() => null,
      VoiceTurnEventReset() => null,
      VoiceTurnScopedEvent e => e.turnId,
    };

/// A bounded diagnostics label that never includes transcript, hint, or
/// error payloads.
String diagnosticLabel(VoiceTurnEvent event) => switch (event) {
      VoiceTurnEventStart() => 'start',
      VoiceTurnEventOpenLockWindow() => 'open_lock_window',
      VoiceTurnEventLock() => 'lock',
      VoiceTurnEventFinalize() => 'finalize',
      VoiceTurnEventCaptureStarted() => 'capture_started',
      VoiceTurnEventCaptureFailed() => 'capture_failed',
      VoiceTurnEventSelectRoute() => 'select_route',
      VoiceTurnEventHubReady() => 'hub_ready',
      VoiceTurnEventHubCommitAccepted() => 'hub_commit_accepted',
      VoiceTurnEventHubCommitDeferred() => 'hub_commit_deferred',
      VoiceTurnEventHubCommitDeferredForReplacement() => 'hub_commit_deferred_for_replacement',
      VoiceTurnEventTranscriptionStarted() => 'transcription_started',
      VoiceTurnEventTranscriptionFinal() => 'transcription_final',
      VoiceTurnEventTranscriptionFailed() => 'transcription_failed',
      VoiceTurnEventProviderResponseStarted() => 'provider_response_started',
      VoiceTurnEventProviderTurnFinished() => 'provider_turn_finished',
      VoiceTurnEventToolStarted() => 'tool_started',
      VoiceTurnEventToolFinished() => 'tool_finished',
      VoiceTurnEventPlaybackStarted() => 'playback_started',
      VoiceTurnEventPlaybackDrained() => 'playback_drained',
      VoiceTurnEventPlaybackFailed() => 'playback_failed',
      VoiceTurnEventTranscriptChanged() => 'transcript_changed',
      VoiceTurnEventHintChanged() => 'hint_changed',
      VoiceTurnEventResponseWaitingChanged() => 'response_waiting_changed',
      VoiceTurnEventResponseActiveChanged() => 'response_active_changed',
      VoiceTurnEventClearPresentation() => 'clear_presentation',
      VoiceTurnEventDeadlineFired() => 'deadline_fired',
      VoiceTurnEventFinish() => 'finish',
      VoiceTurnEventCancel() => 'cancel',
      VoiceTurnEventCleanup() => 'cleanup',
      VoiceTurnEventReset() => 'reset',
    };

// ---------------------------------------------------------------------------
// MARK: - Effects
// ---------------------------------------------------------------------------

sealed class VoiceTurnEffect {
  const VoiceTurnEffect();
}

final class VoiceTurnEffectScheduleDeadline extends VoiceTurnEffect {
  final VoiceTurnId turnId;
  final VoiceTurnDeadline deadline;

  /// Seconds (Swift `TimeInterval`).
  final double after;
  const VoiceTurnEffectScheduleDeadline({required this.turnId, required this.deadline, required this.after});
  @override
  bool operator ==(Object other) =>
      other is VoiceTurnEffectScheduleDeadline &&
      other.turnId == turnId &&
      other.deadline == deadline &&
      other.after == after;
  @override
  int get hashCode => Object.hash(VoiceTurnEffectScheduleDeadline, turnId, deadline, after);
  @override
  String toString() => 'ScheduleDeadline(turnId: $turnId, deadline: $deadline, after: $after)';
}

final class VoiceTurnEffectCancelDeadline extends VoiceTurnEffect {
  final VoiceTurnId turnId;
  final VoiceTurnDeadline deadline;
  const VoiceTurnEffectCancelDeadline({required this.turnId, required this.deadline});
  @override
  bool operator ==(Object other) =>
      other is VoiceTurnEffectCancelDeadline && other.turnId == turnId && other.deadline == deadline;
  @override
  int get hashCode => Object.hash(VoiceTurnEffectCancelDeadline, turnId, deadline);
  @override
  String toString() => 'CancelDeadline(turnId: $turnId, deadline: $deadline)';
}

final class VoiceTurnEffectCancelAllDeadlines extends VoiceTurnEffect {
  final VoiceTurnId turnId;
  const VoiceTurnEffectCancelAllDeadlines({required this.turnId});
  @override
  bool operator ==(Object other) => other is VoiceTurnEffectCancelAllDeadlines && other.turnId == turnId;
  @override
  int get hashCode => Object.hash(VoiceTurnEffectCancelAllDeadlines, turnId);
  @override
  String toString() => 'CancelAllDeadlines(turnId: $turnId)';
}

final class VoiceTurnEffectStopCapture extends VoiceTurnEffect {
  final VoiceTurnId turnId;
  final VoiceCaptureId? captureId;
  const VoiceTurnEffectStopCapture({required this.turnId, required this.captureId});
  @override
  bool operator ==(Object other) =>
      other is VoiceTurnEffectStopCapture && other.turnId == turnId && other.captureId == captureId;
  @override
  int get hashCode => Object.hash(VoiceTurnEffectStopCapture, turnId, captureId);
  @override
  String toString() => 'StopCapture(turnId: $turnId, captureId: $captureId)';
}

/// Carries the PRE-terminal route — the host needs to know which transport
/// to tear down.
final class VoiceTurnEffectCancelHub extends VoiceTurnEffect {
  final VoiceTurnId turnId;
  final VoiceTurnRoute route;
  const VoiceTurnEffectCancelHub({required this.turnId, required this.route});
  @override
  bool operator ==(Object other) => other is VoiceTurnEffectCancelHub && other.turnId == turnId && other.route == route;
  @override
  int get hashCode => Object.hash(VoiceTurnEffectCancelHub, turnId, route);
  @override
  String toString() => 'CancelHub(turnId: $turnId, route: $route)';
}

final class VoiceTurnEffectFallbackToTranscription extends VoiceTurnEffect {
  final VoiceTurnId turnId;
  final VoiceTurnTerminalReason reason;
  const VoiceTurnEffectFallbackToTranscription({required this.turnId, required this.reason});
  @override
  bool operator ==(Object other) =>
      other is VoiceTurnEffectFallbackToTranscription && other.turnId == turnId && other.reason == reason;
  @override
  int get hashCode => Object.hash(VoiceTurnEffectFallbackToTranscription, turnId, reason);
  @override
  String toString() => 'FallbackToTranscription(turnId: $turnId, reason: $reason)';
}

final class VoiceTurnEffectStopPlayback extends VoiceTurnEffect {
  final VoiceTurnId turnId;
  final VoiceLeaseId? leaseId;
  const VoiceTurnEffectStopPlayback({required this.turnId, required this.leaseId});
  @override
  bool operator ==(Object other) =>
      other is VoiceTurnEffectStopPlayback && other.turnId == turnId && other.leaseId == leaseId;
  @override
  int get hashCode => Object.hash(VoiceTurnEffectStopPlayback, turnId, leaseId);
  @override
  String toString() => 'StopPlayback(turnId: $turnId, leaseId: $leaseId)';
}

final class VoiceTurnEffectTerminal extends VoiceTurnEffect {
  final VoiceTurnTerminalRecord record;
  const VoiceTurnEffectTerminal({required this.record});
  @override
  bool operator ==(Object other) => other is VoiceTurnEffectTerminal && other.record == record;
  @override
  int get hashCode => Object.hash(VoiceTurnEffectTerminal, record);
  @override
  String toString() => 'Terminal(record: $record)';
}

final class VoiceTurnEffectStaleEventDropped extends VoiceTurnEffect {
  final VoiceTurnId? turnId;
  final String event;
  const VoiceTurnEffectStaleEventDropped({required this.turnId, required this.event});
  @override
  bool operator ==(Object other) =>
      other is VoiceTurnEffectStaleEventDropped && other.turnId == turnId && other.event == event;
  @override
  int get hashCode => Object.hash(VoiceTurnEffectStaleEventDropped, turnId, event);
  @override
  String toString() => 'StaleEventDropped(turnId: $turnId, event: $event)';
}

final class VoiceTurnEffectInvalidTransition extends VoiceTurnEffect {
  final VoiceTurnId? turnId;
  final String event;
  final VoiceTurnPhase? phase;
  const VoiceTurnEffectInvalidTransition({required this.turnId, required this.event, required this.phase});
  @override
  bool operator ==(Object other) =>
      other is VoiceTurnEffectInvalidTransition &&
      other.turnId == turnId &&
      other.event == event &&
      other.phase == phase;
  @override
  int get hashCode => Object.hash(VoiceTurnEffectInvalidTransition, turnId, event, phase);
  @override
  String toString() => 'InvalidTransition(turnId: $turnId, event: $event, phase: $phase)';
}

// ---------------------------------------------------------------------------
// MARK: - Deadlines (a config struct, not constants — mirrors TS
// `VoiceTurnDeadlines`, a route-aware object the coordinator may override)
// ---------------------------------------------------------------------------

class VoiceTurnDeadlines {
  final double lockDecision;
  final double captureStart;
  final double hubWarm;
  final double transcription;
  final double providerResponse;
  final double pendingTools;
  final double deferredCommit;
  final double bargeInReplacement;
  final double playbackDrain;
  final double hintVisibility;

  const VoiceTurnDeadlines({
    required this.lockDecision,
    required this.captureStart,
    required this.hubWarm,
    required this.transcription,
    required this.providerResponse,
    required this.pendingTools,
    required this.deferredCommit,
    required this.bargeInReplacement,
    required this.playbackDrain,
    required this.hintVisibility,
  });
}

/// SECONDS (Swift `TimeInterval`). Calibrated for real Gemini Live UX —
/// carry over as-is, do not re-tune during the port.
const VoiceTurnDeadlines defaultVoiceTurnDeadlines = VoiceTurnDeadlines(
  lockDecision: 0.4,
  captureStart: 3,
  hubWarm: 1,
  transcription: 12,
  providerResponse: 20,
  pendingTools: 30,
  deferredCommit: 8,
  bargeInReplacement: 8,
  playbackDrain: 30,
  hintVisibility: 2,
);

// ---------------------------------------------------------------------------
// MARK: - Derived predicates
// ---------------------------------------------------------------------------

bool isRecording(VoiceTurnPhase phase) =>
    phase is VoiceTurnPhaseRecording ||
    phase is VoiceTurnPhaseLockedRecording ||
    phase is VoiceTurnPhasePendingLockDecision;

bool isTerminal(VoiceTurnPhase phase) => phase is VoiceTurnPhaseTerminal;

/// The guard that stops a stray provider callback from mutating a turn that
/// is still capturing mic audio.
bool acceptsProviderOutput(VoiceTurnPhase phase) =>
    phase is VoiceTurnPhaseAwaitingResponse || phase is VoiceTurnPhaseAwaitingTools || phase is VoiceTurnPhasePlaying;

bool routeMatchesHub(VoiceTurnRoute route) => route is VoiceTurnRouteHub || route is VoiceTurnRouteHubWarmWait;

/// Pure — ported verbatim. NOTE: `permissionDenied` deliberately gets NO
/// hint (mirrors macOS/TS); do not "fix" it here.
String? terminalHint(VoiceTurnTerminalReason reason) => switch (reason) {
      VoiceTurnTerminalReason.tooShort => 'Hold longer to record',
      VoiceTurnTerminalReason.captureFailed => 'Microphone unavailable — try again',
      VoiceTurnTerminalReason.transcriptionFailed => "Couldn't transcribe that — try again",
      VoiceTurnTerminalReason.providerFailed => 'Voice response failed — try again',
      VoiceTurnTerminalReason.providerNoResponse => 'Voice response failed — try again',
      VoiceTurnTerminalReason.deferredCommitTimeout => 'Voice response failed — try again',
      VoiceTurnTerminalReason.bargeInReplacementTimeout => 'Voice response failed — try again',
      VoiceTurnTerminalReason.toolTimeout => 'Voice response failed — try again',
      VoiceTurnTerminalReason.playbackFailed => 'Audio playback failed',
      VoiceTurnTerminalReason.success => null,
      VoiceTurnTerminalReason.silentRejected => null,
      VoiceTurnTerminalReason.cancelled => null,
      VoiceTurnTerminalReason.interruptedByBargeIn => null,
      VoiceTurnTerminalReason.permissionDenied => null,
      VoiceTurnTerminalReason.hubWarmTimeout => null,
      VoiceTurnTerminalReason.cleanup => null,
    };

VoiceTurnUiProjection projectionOf(VoiceTurnModel model) => model.turn?.projection ?? idleVoiceTurnProjection;

// ---------------------------------------------------------------------------
// MARK: - Structural equality (re-exported for callers that need it, mirrors
// TS `phasesEqual`/`routesEqual`/`leasesEqual` — here they're thin wrappers
// over `==` since every variant above already implements value equality).
// ---------------------------------------------------------------------------

bool phasesEqual(VoiceTurnPhase a, VoiceTurnPhase b) => a == b;
bool routesEqual(VoiceTurnRoute a, VoiceTurnRoute b) => a == b;
bool leasesEqual(VoiceOutputLease a, VoiceOutputLease b) => a == b;

/// Deep equality helper for the read-only `Set<T>` fields on [VoiceTurn]
/// (`pendingToolCallIds`, `deadlines`) — plain `Set.==` is identity-based in
/// Dart, unlike TS's structural `ReadonlySet` comparisons in tests.
bool voiceTurnSetsEqual<T>(Set<T> a, Set<T> b) => const SetEquality().equals(a, b);
