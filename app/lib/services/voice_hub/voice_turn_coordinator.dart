// The VoiceTurn coordinator — a 1:1 port of
// `desktop/windows/src/renderer/src/lib/voice/turn/voiceTurnCoordinator.ts`
// (itself a port of macOS `VoiceTurnCoordinator.swift`), design doc
// `~/omi-jarvis/docs/hub-port-design.md` §8 step 6 (read together with the
// driver, per the doc's own note).
//
// It owns everything the reducer (`voice_turn_reducer.dart`) deliberately
// does not: turn-ID minting, the clock, deadline timers, the diagnostics
// timeline, and effect delivery. It performs no I/O of its own beyond
// timers — the real capture/hub/playback transports are driven by the
// injected effect handler (`voice_turn_host.dart`).
//
// Port notes (the traps a "natural" Dart translation gets wrong — carried
// over verbatim from the TS source's own comments):
//   * `send()` is FIFO and NON-REENTRANT. An event dispatched from inside an
//     effect/presenter/snapshot callback is APPENDED to the pending queue
//     and drained after the in-flight event has fully published — the call
//     stack never recurses. The index-based loop over a growing list IS the
//     mechanism.
//   * Collaborator callbacks are CONTAINED (2026-07-18 desktop wedge fix): a
//     throwing effect handler / presenter / snapshot handler is caught
//     per-call so the drain continues. State transitions and timers are the
//     coordinator's own and must never be hostage to a collaborator's
//     exception.
//   * `apply()` publishes one event atomically: reduce -> assign model ->
//     timeline -> effects (in emission order) -> presenter -> snapshot. No
//     event is ever reduced against a half-applied model.
//   * Deadline handles are keyed by (turnId, deadline), so a cancelled
//     handle can never fire into a later turn.
//   * Deadlines are ROUTE-AWARE (`deadlinesForVoiceTurnRoute`): the cascade
//     routes (`omniSTT`/`deepgramBatch`/`deepgramLive`) get a 20s
//     transcription budget (the shipped batch-STT timeout) instead of the
//     hub route's 12s default — porting 12s blindly would kill slow batch
//     transcriptions that succeed today.
//
// Two scope cuts vs. the TS source, both Windows-desktop-UI-specific with no
// Android surface wired up yet (see `voice_turn_driver.dart`'s own header
// for the broader UI-deferral rationale):
//   * `expandsBarForVoice` (the desktop overlay pill's expand/collapse rule)
//     — Android has no such bar; the reducer's `VoiceTurnUiProjection`
//     (already ported in `voice_turn_machine.dart`) is exposed as-is via
//     `projection`/the presenter seam for a future presenter to shape.
//   * `VoiceTurnPresenter` is a bare function typedef here, not a TS-style
//     `{apply(projection)}` object — Dart has no ergonomic reason to wrap a
//     single callback in an interface.
//
// Ground rule (design doc §8): ZERO Flutter imports here. `dart:async`'s
// `Timer` is core Dart (already used the same way in `hub_session.dart`'s
// `DefaultHubClock`), not Flutter-specific.

import 'dart:async';

import 'package:uuid/uuid.dart';

import 'voice_turn_machine.dart';
import 'voice_turn_reducer.dart';

// ---------------------------------------------------------------------------
// MARK: - Route-aware deadlines (Windows decision D2, carried over)
// ---------------------------------------------------------------------------

/// The shipped cascade's batch-transcription budget in seconds
/// (`BATCH_TIMEOUT_MS` in the TS `ptt/constants.ts` = 20000ms). The hub
/// route keeps [defaultVoiceTurnDeadlines]'s 12s.
const VoiceTurnDeadlines cascadeVoiceTurnDeadlines = VoiceTurnDeadlines(
  lockDecision: 0.4,
  captureStart: 3,
  hubWarm: 1,
  transcription: 20,
  providerResponse: 20,
  pendingTools: 30,
  deferredCommit: 8,
  bargeInReplacement: 8,
  playbackDrain: 30,
  hintVisibility: 2,
);

/// Cascade transports (all of them go through the batch/stream STT path) get
/// the cascade budget; the hub route (and everything else) gets the default.
VoiceTurnDeadlines deadlinesForVoiceTurnRoute(VoiceTurnRoute route) {
  if (route is VoiceTurnRouteOmniStt || route is VoiceTurnRouteDeepgramBatch || route is VoiceTurnRouteDeepgramLive) {
    return cascadeVoiceTurnDeadlines;
  }
  return defaultVoiceTurnDeadlines;
}

// ---------------------------------------------------------------------------
// MARK: - Injected ports
// ---------------------------------------------------------------------------

/// A live deadline timer handle. `cancel()` is idempotent by convention
/// (every scheduler implementation here and in tests treats a double-cancel
/// as a no-op, matching `Timer.cancel()`'s own semantics).
class VoiceTurnDeadlineHandle {
  final void Function() _cancel;
  const VoiceTurnDeadlineHandle(this._cancel);
  void cancel() => _cancel();
}

/// Tests inject a manual scheduler; production wraps [Timer].
abstract class VoiceTurnDeadlineScheduling {
  VoiceTurnDeadlineHandle schedule(VoiceTurnDeadline deadline, double afterSeconds, void Function() fire);
}

class TimerVoiceTurnScheduler implements VoiceTurnDeadlineScheduling {
  const TimerVoiceTurnScheduler();

  @override
  VoiceTurnDeadlineHandle schedule(VoiceTurnDeadline deadline, double afterSeconds, void Function() fire) {
    final timer = Timer(Duration(milliseconds: (afterSeconds * 1000).round()), fire);
    return VoiceTurnDeadlineHandle(timer.cancel);
  }
}

typedef VoiceTurnEffectHandler = void Function(VoiceTurnEffect effect);
typedef VoiceTurnSnapshotHandler = void Function(VoiceTurnModel model);

/// The presentation seam. See file header — a bare callback, not a TS-style
/// wrapper object.
typedef VoiceTurnPresenter = void Function(VoiceTurnUiProjection projection);

abstract class VoiceTurnDiagnostics {
  void recordVoiceTurnTerminal({
    required String reason,
    required String route,
    required int staleEventCount,
    required int invalidTransitionCount,
  });
  void recordVoiceTurnAnomaly({required String kind, required String phase, required String route});
}

typedef VoiceTurnOnTimelineEntry = void Function(VoiceTurnTimelineEntry entry);

// ---------------------------------------------------------------------------
// MARK: - Timeline
// ---------------------------------------------------------------------------

class VoiceTurnTimelineEntry {
  final int sequence;
  final VoiceTurnId? turnId;

  /// `diagnosticLabel(event)` — a bounded label, never a payload.
  final String event;
  final VoiceTurnPhase? phaseBefore;
  final VoiceTurnPhase? phaseAfter;
  final VoiceTurnRoute? route;
  final VoiceTurnTerminalReason? terminalReason;
  final int staleEventCount;
  final int invalidTransitionCount;

  const VoiceTurnTimelineEntry({
    required this.sequence,
    required this.turnId,
    required this.event,
    required this.phaseBefore,
    required this.phaseAfter,
    required this.route,
    required this.terminalReason,
    required this.staleEventCount,
    required this.invalidTransitionCount,
  });
}

String voiceTurnPhaseLabel(VoiceTurnPhase phase) => switch (phase) {
      VoiceTurnPhaseIdle() => 'idle',
      VoiceTurnPhasePendingLockDecision() => 'pending_lock_decision',
      VoiceTurnPhaseRecording() => 'recording',
      VoiceTurnPhaseLockedRecording() => 'locked_recording',
      VoiceTurnPhaseFinalizing() => 'finalizing',
      VoiceTurnPhaseAwaitingResponse() => 'awaiting_response',
      VoiceTurnPhaseAwaitingTools() => 'awaiting_tools',
      VoiceTurnPhasePlaying(:final lane) => 'playing_${lane.rawValue}',
      VoiceTurnPhaseTerminal(:final reason) => 'terminal_${reason.rawValue}',
    };

String voiceTurnRouteLabel(VoiceTurnRoute route) => switch (route) {
      VoiceTurnRouteUndecided() => 'undecided',
      VoiceTurnRouteHubWarmWait() => 'hub_warm_wait',
      VoiceTurnRouteHub() => 'hub',
      VoiceTurnRouteOmniStt() => 'omni_stt',
      VoiceTurnRouteDeepgramBatch() => 'deepgram_batch',
      VoiceTurnRouteDeepgramLive() => 'deepgram_live',
      VoiceTurnRouteAgentFollowUp() => 'agent_follow_up',
    };

// ---------------------------------------------------------------------------
// MARK: - Coordinator
// ---------------------------------------------------------------------------

String _deadlineKey(VoiceTurnId turnId, VoiceTurnDeadline deadline) => '$turnId ${deadline.name}';

class VoiceTurnCoordinator {
  final VoiceTurnDeadlineScheduling _scheduler;
  final int _timelineLimit;
  final VoiceTurnId Function() _mintTurnId;
  final VoiceTurnDiagnostics? _diagnostics;
  final VoiceTurnOnTimelineEntry? _onTimelineEntry;

  final Map<String, ({VoiceTurnId turnId, VoiceTurnDeadlineHandle handle})> _deadlineHandles = {};
  VoiceTurnPresenter? _presenter;
  VoiceTurnEffectHandler? _effectHandler;
  VoiceTurnSnapshotHandler? _snapshotHandler;
  List<VoiceTurnTimelineEntry> _timeline = [];
  int _timelineSequence = 0;
  final List<VoiceTurnEvent> _pendingEvents = [];
  bool _isDrainingEvents = false;

  VoiceTurnModel model;

  VoiceTurnCoordinator({
    VoiceTurnModel? model,
    VoiceTurnDeadlineScheduling? scheduler,
    int timelineLimit = 256,
    VoiceTurnId Function()? mintTurnId,
    VoiceTurnDiagnostics? diagnostics,
    VoiceTurnOnTimelineEntry? onTimelineEntry,
  })  : model = model ?? idleVoiceTurnModel,
        _scheduler = scheduler ?? const TimerVoiceTurnScheduler(),
        _timelineLimit = timelineLimit < 1 ? 1 : timelineLimit,
        _mintTurnId = mintTurnId ?? (() => const Uuid().v4()),
        _diagnostics = diagnostics,
        _onTimelineEntry = onTimelineEntry;

  /// `null` whenever the turn is terminal — hosts must never treat a
  /// terminal turn as active.
  VoiceTurnId? get activeTurnId {
    final turn = model.turn;
    return (turn != null && !isTerminal(turn.phase)) ? turn.id : null;
  }

  VoiceTurn? get activeTurn {
    final turn = model.turn;
    return (turn != null && !isTerminal(turn.phase)) ? turn : null;
  }

  VoiceTurnUiProjection get projection => projectionOf(model);

  void configure(VoiceTurnPresenter? presenter) {
    _presenter = presenter;
    _contain('presenter', () => presenter?.call(projection));
  }

  void setEffectHandler(VoiceTurnEffectHandler? handler) => _effectHandler = handler;

  void setSnapshotHandler(VoiceTurnSnapshotHandler? handler) {
    _snapshotHandler = handler;
    _contain('snapshot_handler', () => handler?.call(model));
  }

  /// The only place a [VoiceTurnId] is manufactured for a real PTT press.
  VoiceTurnId begin(VoiceTurnIntent intent, [VoiceTurnId? id]) {
    final turn = model.turn;
    if (turn != null && isTerminal(turn.phase)) {
      send(const VoiceTurnEventReset());
    }
    final resolvedId = id ?? _mintTurnId();
    send(VoiceTurnEventStart(turnId: resolvedId, intent: intent));
    return resolvedId;
  }

  /// FIFO, non-reentrant. A `send` from inside an effect/snapshot handler
  /// appends and returns immediately — the outer loop reaches it at the next
  /// index, so callback depth stays 1 and no event is reduced against a
  /// half-published transition.
  void send(VoiceTurnEvent event) {
    _pendingEvents.add(event);
    if (_isDrainingEvents) return;

    _isDrainingEvents = true;
    try {
      // Index-based on purpose: the list is EXPECTED to grow during
      // iteration.
      for (var index = 0; index < _pendingEvents.length; index += 1) {
        _apply(_pendingEvents[index]);
      }
    } finally {
      _pendingEvents.clear();
      _isDrainingEvents = false;
    }
  }

  List<VoiceTurnTimelineEntry> timelineSnapshot() => List.unmodifiable(_timeline);

  void refreshPresentation() => _contain('presenter', () => _presenter?.call(projection));

  /// Non-PTT playback shares a presenter but must not bypass the
  /// presentation owner: a late callback cannot clear an active turn's
  /// state.
  void setUnscopedResponseActive(bool active) {
    if (activeTurnId != null) return;
    final p = projection;
    _contain(
      'presenter',
      () => _presenter?.call(VoiceTurnUiProjection(
        isListening: p.isListening,
        isLocked: p.isLocked,
        isFollowUp: p.isFollowUp,
        transcript: p.transcript,
        hint: p.hint,
        isThinking: p.isThinking,
        isResponseWaiting: false,
        isResponseActive: active,
      )),
    );
  }

  void reset() {
    if (model.turn != null) {
      send(const VoiceTurnEventCleanup());
      send(const VoiceTurnEventReset());
    }
    for (final entry in _deadlineHandles.values) {
      entry.handle.cancel();
    }
    _deadlineHandles.clear();
    _contain('presenter', () => _presenter?.call(idleVoiceTurnProjection));
  }

  /// Applies one event atomically before any callback can advance the
  /// machine.
  void _apply(VoiceTurnEvent event) {
    final before = model;
    final reduction = reduceVoiceTurn(before, event, deadlines: deadlinesForVoiceTurnRoute(_routeFor(event)));
    model = reduction.model;
    _appendTimeline(event, before, model);
    _process(reduction.effects);
    _contain('presenter', () => _presenter?.call(projection));
    _contain('snapshot_handler', () => _snapshotHandler?.call(model));
  }

  /// Run one collaborator callback, containing any synchronous throw so it
  /// can never abort the drain (skip deadline scheduling / later effects /
  /// the projection publish) or drop queued events.
  void _contain(String kind, void Function() call) {
    try {
      call();
    } catch (_) {
      _diagnostics?.recordVoiceTurnAnomaly(
        kind: '${kind}_threw',
        phase: model.turn != null ? voiceTurnPhaseLabel(model.turn!.phase) : 'idle',
        route: model.turn != null ? voiceTurnRouteLabel(model.turn!.route) : 'none',
      );
    }
  }

  /// The route this event's deadlines belong to. `selectRoute` and a fired
  /// `hubWarm` (which hands the buffer to the cascade and arms its
  /// transcription deadline in the same reduce) change the route DURING the
  /// reduce, so the pre-event route would pick the wrong budget for exactly
  /// those two.
  VoiceTurnRoute _routeFor(VoiceTurnEvent event) {
    if (event is VoiceTurnEventSelectRoute) return event.route;
    if (event is VoiceTurnEventDeadlineFired && event.deadline == VoiceTurnDeadline.hubWarm) {
      return const VoiceTurnRouteDeepgramBatch();
    }
    return model.turn?.route ?? const VoiceTurnRouteUndecided();
  }

  /// Timers + diagnostics only. State transitions are the reducer's job.
  /// Every effect is then forwarded to the host — including the three timer
  /// effects, which a host must tolerate and ignore (see
  /// `voice_turn_host.dart`).
  void _process(List<VoiceTurnEffect> effects) {
    for (final effect in effects) {
      switch (effect) {
        case VoiceTurnEffectScheduleDeadline():
          _scheduleDeadline(effect.turnId, effect.deadline, effect.after);
        case VoiceTurnEffectCancelDeadline():
          _cancelDeadline(effect.turnId, effect.deadline);
        case VoiceTurnEffectCancelAllDeadlines():
          _cancelAllDeadlines(effect.turnId);
        case VoiceTurnEffectTerminal():
          _diagnostics?.recordVoiceTurnTerminal(
            reason: effect.record.reason.rawValue,
            route: voiceTurnRouteLabel(effect.record.route),
            staleEventCount: model.staleEventCount,
            invalidTransitionCount: model.invalidTransitionCount,
          );
        case VoiceTurnEffectStaleEventDropped():
          _diagnostics?.recordVoiceTurnAnomaly(
            kind: 'stale_event',
            phase: model.turn != null ? voiceTurnPhaseLabel(model.turn!.phase) : 'idle',
            route: model.turn != null ? voiceTurnRouteLabel(model.turn!.route) : 'none',
          );
        case VoiceTurnEffectInvalidTransition():
          _diagnostics?.recordVoiceTurnAnomaly(
            kind: 'invalid_transition',
            phase: effect.phase != null ? voiceTurnPhaseLabel(effect.phase!) : 'idle',
            route: model.turn != null ? voiceTurnRouteLabel(model.turn!.route) : 'none',
          );
        case VoiceTurnEffectStopCapture():
        case VoiceTurnEffectCancelHub():
        case VoiceTurnEffectFallbackToTranscription():
        case VoiceTurnEffectStopPlayback():
          break;
      }
      _contain('effect_handler', () => _effectHandler?.call(effect));
    }
  }

  void _scheduleDeadline(VoiceTurnId turnId, VoiceTurnDeadline deadline, double afterSeconds) {
    final key = _deadlineKey(turnId, deadline);
    // Re-scheduling a held deadline resets the timer — drop the old handle
    // first.
    _deadlineHandles.remove(key)?.handle.cancel();
    final handle = _scheduler.schedule(deadline, afterSeconds, () {
      _deadlineHandles.remove(key);
      send(VoiceTurnEventDeadlineFired(turnId: turnId, deadline: deadline));
    });
    _deadlineHandles[key] = (turnId: turnId, handle: handle);
  }

  void _cancelDeadline(VoiceTurnId turnId, VoiceTurnDeadline deadline) {
    final key = _deadlineKey(turnId, deadline);
    _deadlineHandles.remove(key)?.handle.cancel();
  }

  void _cancelAllDeadlines(VoiceTurnId turnId) {
    final keys = [
      for (final entry in _deadlineHandles.entries)
        if (entry.value.turnId == turnId) entry.key,
    ];
    for (final key in keys) {
      _deadlineHandles.remove(key)?.handle.cancel();
    }
  }

  void _appendTimeline(VoiceTurnEvent event, VoiceTurnModel before, VoiceTurnModel after) {
    _timelineSequence += 1;
    final eventTurnId = turnIdOf(event);
    // Deliberately DIFFERENT id expressions for the two uses below: the
    // terminal match has no `before` fallback, so a `reset` (which clears
    // the turn) does not re-stamp the old terminal reason.
    final turnId = eventTurnId ?? after.turn?.id ?? before.turn?.id;
    final terminalMatchId = eventTurnId ?? after.turn?.id;
    final entry = VoiceTurnTimelineEntry(
      sequence: _timelineSequence,
      turnId: turnId,
      event: diagnosticLabel(event),
      phaseBefore: before.turn?.phase,
      phaseAfter: after.turn?.phase,
      route: after.turn?.route,
      terminalReason:
          (after.lastTerminal != null && terminalMatchId != null && after.lastTerminal!.turnId == terminalMatchId)
              ? after.lastTerminal!.reason
              : null,
      staleEventCount: after.staleEventCount,
      invalidTransitionCount: after.invalidTransitionCount,
    );
    _timeline.add(entry);
    if (_timeline.length > _timelineLimit) {
      _timeline = _timeline.sublist(_timeline.length - _timelineLimit);
    }
    _contain('timeline_tap', () => _onTimelineEntry?.call(entry));
  }
}
