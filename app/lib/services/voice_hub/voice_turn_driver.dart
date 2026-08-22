// The warm-hub PTT turn DRIVER — the finale of the Android realtime-hub port
// (design doc `~/omi-jarvis/docs/hub-port-design.md` §8). A 1:1-in-spirit
// port of `desktop/windows/src/renderer/src/lib/voice/turn/voiceHubTurnDriver.ts`
// (`VoiceHubTurnDriver`, 1085 lines) and its test suite
// (`voiceHubTurnDriver.test.ts`, 1168 lines).
//
// This is the ONLY file this tick adds; every collaborator it assembles
// (`voice_turn_machine.dart`, `voice_turn_reducer.dart`,
// `voice_turn_coordinator.dart`, `voice_turn_host.dart`, `hub_controller.dart`,
// `hub_session.dart`, `gemini_hub_session.dart`, `voice_output_coordinator.dart`,
// `ptt_gate.dart`, `hub_ptt_capture.dart`) already exists and is used as-is.
// What this file owns, per turn (mirrors the TS header):
//   * `coordinator.begin('hold')` -> the reducer `start` event; then
//     `selectPttRoute` (from `voice_turn_host.dart`) picks `hub` /
//     `hubWarmWait`; the driver dispatches `selectRoute`.
//   * Capture ownership: `startCapture` (the injected `HubStartCapture` from
//     `hub_ptt_capture.dart`) is called on every `begin()`; raw PCM16 chunks
//     feed `voicedStats` (release-gate accounting) and, on the hub route,
//     `HubController.appendAudio` directly — NO resampling, because the
//     capture is already 16 kHz (design doc §2 table: `PhoneMicSource` emits
//     16 kHz, `GeminiHubSession.requiredInputSampleRate` is 16000 — they
//     already match).
//   * Release -> `finalize` + `HubController.commitTurn` (hub route) or an
//     immediate gate-driven cancel (there is no other route in this port —
//     see the cut below).
//   * Hub session/provider events (wired through `HubController`) map back
//     to reducer events so the turn advances to `success`/a terminal.
//   * Barge-in: every `begin()` unconditionally clears whatever the hub's
//     own player has already buffered (`HubController.clearPlayback()`,
//     added to `hub_controller.dart`/`hub_session.dart` by this same change
//     — see those files' headers) BEFORE starting the new turn; a
//     superseding hold begins the hub turn `interrupting: true` so
//     `GeminiHubSession.onBeginTurn` locally gates the old turn's trailing
//     provider messages. The reducer's own `terminate()` (already ported)
//     supplies the other half of barge-in for free: a barge-in on an active
//     hub-route turn skips `cancelHub`/`stopPlayback` entirely
//     (`preservesHubForBargeInHandoff`) so the successor inherits the live
//     warm socket — no special-case code is needed here for that part.
//   * State projection outward: the coordinator's existing presenter seam
//     (`VoiceTurnHost.presenter` / `VoiceTurnCoordinator.configure`) is wired
//     straight to an injected callback — NOT a new bar/IPC surface. No
//     Android screen is subscribed to it yet (see the cut below); this tick
//     is plumbing, matching every prior file in this series.
//
// Every collaborator is an injected seam so the whole driver is exercised
// hermetically against fakes, same discipline as `hub_controller_test.dart` /
// `voice_turn_host_test.dart`.
//
// ---------------------------------------------------------------------------
// Conscious cuts (documented here, not silently filled in — same convention
// `hub_controller.dart`/`voice_turn_host.dart` already established):
//
//   * NO chat-kernel path (`onFinalText`/`onRecordTurn`/a "record this turn
//     into the chat timeline" callback). PLAN.md §3: "the brain in realtime
//     is inseparable from voice" is a SEPARATE tool-call path for a later
//     session, not this one. This driver's only externally visible signal is
//     the bare turn-lifecycle projection (`applyProjection`) — a caller that
//     wants a transcript/reply recorded builds that on top, later.
//
//   * NO cascade/batch-STT route (`omniSTT` / `deepgramBatch` / a
//     `transcribe()`+`onFinalText()` pair). This is the single-provider
//     (Gemini Live) Android port; Android/lane1/lane2 already own a
//     completely separate STT cascade (GigaAM) for the pendant's own
//     gestures — this driver is an ALTERNATIVE brain for those same
//     gestures, not a replacement, and re-implementing a second cascade here
//     would just duplicate that stack. Concretely: `selectPttRoute`
//     (`voice_turn_host.dart`) is still called — it is the one true
//     kill-switch choke point and is reused as-is — but if it ever resolves
//     to the non-hub `omniStt` route (the pref is off, or the hub is
//     completely unavailable), `begin()` does not attempt a cascade
//     transcription it doesn't own: it silently cancels the turn
//     (`VoiceTurnTerminalReason.cancelled`, no hint) and starts no capture.
//     A future integration (`capture_controller.dart`, explicitly out of
//     scope for this tick) is expected to gate invoking this driver's
//     `begin()` on hub availability in the first place, making this branch
//     rare in practice; it exists so `begin()` is total and never leaves the
//     coordinator in a stuck `recording` phase with nobody driving it.
//
//   * Tool execution (PR-C in the TS source) is an OPTIONAL injected seam
//     (`VoiceHubTurnDriverDeps.toolExecutor`), not built into this file.
//     Unset (the original default) behaves exactly as before this seam
//     existed: `gemini_hub_session.dart` declares an empty catalog unless a
//     production caller wires `HubController.fetchTools`, so `onToolRequest`
//     stays dead in practice and is satisfied defensively — reply with an
//     error string immediately — so a stray/unhandled tool call can never
//     hang a turn in `awaitingTools` forever. A caller that DOES declare a
//     catalog (e.g. `ask_claude_tool.dart`'s `askClaudeToolDeclaration` via
//     `fetchTools`) must also set `toolExecutor` to something that actually
//     resolves it (e.g. `AskClaudeToolExecutor.handle`) — otherwise a real
//     call from the model hits the same defensive error path, which is
//     honest but not useful.
//
//   * NO `audibleOutputArbiter` (the desktop single-audible-owner token
//     shared between the hub's realtime voice and a SEPARATE cascade/TTS
//     voice). There is no separate TTS output in this driver's world (see
//     the cascade cut above) — nothing competes with the hub's own player
//     for the speaker, so there is nothing to arbitrate.
//
//   * NO release watchdog (`RELEASE_WATCHDOG_MS` belt-and-braces force-
//     finalize). It existed on desktop to recover from a wedge class where a
//     throwing collaborator skipped a reducer-scheduled timer effect before
//     it could be armed. That wedge class is already closed structurally in
//     this port: `VoiceTurnCoordinator._contain` (already ported, see that
//     file) wraps every effect-handler/presenter/snapshot callback in a
//     try/catch, so a throwing collaborator can never abort the drain or
//     skip a deadline registration. The reducer's own bounded deadlines
//     (`providerResponse`/`deferredCommit`/`transcription`/... — all already
//     ported in `voice_turn_machine.dart`) are therefore sufficient on their
//     own to guarantee every turn reaches a terminal in bounded time.
//
//   * NO A4 system-audio duck / no `trackEvent` analytics / no
//     `recordVoiceFlight` flight recorder / no bar-IPC `VoiceHubBarState`
//     (`active`/`orbLevel`/`seq` presentation struct) or orb-loudness
//     projection (`pcmPeakLevel`, the capture's ~30 Hz levels lane). All
//     Windows-desktop-specific with no Android analog — same reasoning
//     `hub_controller.dart`/`voice_turn_host.dart` already gave for their own
//     versions of this cut. `VoiceTurnUiProjection` (already ported in
//     `voice_turn_machine.dart`) carries no `orbLevel` field at all — that
//     was purely bar-IPC UI plumbing.
//
//   * NO resampling (`resamplePcm16`). The TS driver resampled capture-rate
//     PCM to whatever the active provider wanted (16 k for Gemini, 24 k for
//     OpenAI). This port has exactly one provider and its capture source is
//     already pinned to that provider's required rate (see the file-level
//     comment above) — there is no second rate to convert to. If that ever
//     changes, `resamplePcm16`'s algorithm is preserved verbatim in the TS
//     source for a future port to copy.
//
// Ground rule for `voice_hub/` (design doc §8): this file DOES touch I/O —
// unlike the pure reducer/coordinator files, a turn driver's whole job is to
// own real capture + a real warm session. Every such touch is behind an
// injected seam (`VoiceHubTurnDriverDeps`), so this file is still fully
// unit-testable without a socket, a microphone, or Flutter itself.

import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'hub_controller.dart';
import 'hub_ptt_capture.dart';
import 'hub_session.dart' show HubToolCallRequest;
import 'ptt_gate.dart';
import 'voice_output_coordinator.dart';
import 'voice_turn_coordinator.dart';
import 'voice_turn_host.dart';
import 'voice_turn_machine.dart';

bool _defaultPttHubEnabled() => true;

const AudioStats _zeroAudioStats = AudioStats(totalSec: 0, voicedSec: 0, peak: 0);

/// Everything the driver needs injected. Every production default lives in
/// the app's future wiring (out of scope for this tick, same as every
/// sibling file in this series) — tests supply fakes for all of it.
class VoiceHubTurnDriverDeps {
  /// Build the warm-hub controller with the driver's event wiring.
  /// Production: `(events) => HubController(events: events, buildInstructions:
  /// ..., mintToken: ..., createSession: ...)`; tests pass a fake
  /// `createSession` into a REAL `HubController` (same pattern as
  /// `hub_controller_test.dart`'s own harness) so the controller's own
  /// warm-wait/reconnect logic is exercised for real, not re-mocked here.
  final HubController Function(HubControllerEvents events) createHub;

  /// Start the mic capture for one turn. Production wraps
  /// `nativeMicHubCaptureFactory` (`hub_ptt_capture.dart`); tests fake it.
  final HubStartCapture startCapture;

  /// Broadcast the reducer's UI projection. Wired straight to
  /// `VoiceTurnHost.presenter`/`VoiceTurnCoordinator.configure` — NOT a new
  /// bar/IPC surface (see file header). No-op-by-default is deliberately NOT
  /// offered: a caller with nothing to project should pass `(_) {}`
  /// explicitly, so an accidentally-unwired projection is visible in the
  /// dependency list rather than silently swallowed.
  final VoiceTurnPresenter applyProjection;

  /// The live hub kill-switch. Defaults to always-on: this driver exists
  /// specifically to be an opt-in alternative brain for the pendant's PTT
  /// gesture (PLAN.md §1), so "always try the hub when available" is the
  /// sane default absent a wired preference; a real integration overrides
  /// this with a live preference read, exactly like the TS source's
  /// `prefs: () => getPreferences()`.
  final bool Function() pttHubEnabled;

  /// Real tool execution (e.g. `AskClaudeToolExecutor.handle`,
  /// `ask_claude_tool.dart`), tried FIRST when a tool request arrives.
  /// `null` (the default) preserves the driver's original "no executor
  /// wired" behavior byte-for-byte: `_hubEvents().onToolRequest` sends the
  /// hardcoded "Error: tools are not available" result immediately (see
  /// the file-header cut this seam replaces). When set, that hardcoded
  /// error is skipped entirely — the executor owns the reply (typically
  /// async, via its own `sendToolResult` callback) so it must never be set
  /// without also declaring a tool catalog via `HubController.fetchTools`,
  /// or a real call will hang in `awaitingTools` with nobody ever calling
  /// `sendToolResult`.
  final void Function(HubToolCallRequest call)? toolExecutor;

  // --- test seams (mirror `VoiceTurnCoordinator`'s own optional ctor args) ---
  final VoiceTurnDeadlineScheduling? scheduler;
  final VoiceTurnId Function()? mintTurnId;
  final VoiceCaptureId Function()? mintCaptureId;
  final VoiceOutputCoordinator? output;

  const VoiceHubTurnDriverDeps({
    required this.createHub,
    required this.startCapture,
    required this.applyProjection,
    this.pttHubEnabled = _defaultPttHubEnabled,
    this.toolExecutor,
    this.scheduler,
    this.mintTurnId,
    this.mintCaptureId,
    this.output,
  });
}

// ---------------------------------------------------------------------------
// MARK: - Adapters (Dart needs nominal typing for these; TS's structural
// typing let `HubController`/`VoiceOutputCoordinator` satisfy
// `PttHubAvailability`/`VoiceTurnHubPort`/`VoiceTurnOutputPort` for free)
// ---------------------------------------------------------------------------

class _HubControllerAvailability implements PttHubAvailability {
  final HubController _hub;
  const _HubControllerAvailability(this._hub);
  @override
  bool isAvailable() => _hub.isAvailable();
  @override
  bool isWarm() => _hub.isWarm();
}

class _HubControllerPort implements VoiceTurnHubPort {
  final HubController _hub;
  const _HubControllerPort(this._hub);
  @override
  void cancelTurn(VoiceTurnId turnId) => _hub.cancelTurn(turnId);
  @override
  void handoffWarmWaitToCascade(VoiceTurnId turnId) => _hub.handoffWarmWaitToCascade(turnId);
  @override
  void voiceTurnDidTerminate(VoiceTurnId turnId) => _hub.voiceTurnDidTerminate(turnId);
}

class _OutputCoordinatorPort implements VoiceTurnOutputPort {
  final VoiceOutputCoordinator _output;
  const _OutputCoordinatorPort(this._output);
  @override
  bool endTurn(VoiceTurnId turnId) => _output.endTurn(turnId);
}

// ---------------------------------------------------------------------------
// MARK: - Driver
// ---------------------------------------------------------------------------

class VoiceHubTurnDriver {
  final VoiceHubTurnDriverDeps _deps;

  late final HubController _hub;
  late final VoiceOutputCoordinator _output;
  late final VoiceTurnHost _host;
  late final VoiceTurnCoordinator _coordinator;
  late final VoiceCaptureId Function() _mintCaptureId;
  int _captureSeq = 0;

  // Per-turn state --------------------------------------------------------
  VoiceTurnId? _turnId;
  VoiceCaptureId? _captureId;
  VoiceTurnRoute _route = const VoiceTurnRouteUndecided();
  VoiceSessionId? _sessionId;
  HubPttCapture? _capture;
  bool _committed = false;

  /// Running voiced-audio stats for THIS turn's captured PCM — the release
  /// gate (`gateDecision`) reads these at `end()`. Reset per turn.
  AudioStats _voiced = _zeroAudioStats;

  /// Set by `dispose()`: this instance is dead — a fresh driver replaces it.
  bool _disposed = false;

  VoiceHubTurnDriver(this._deps) {
    _output = _deps.output ?? VoiceOutputCoordinator();

    // The controller is constructed with the driver's event wiring so
    // provider/session lifecycle events map back into reducer events. The
    // closures below capture `this` and read `_hub`/`_output`/etc. lazily —
    // none of them run until the controller actually calls back, by which
    // point every field below is assigned (same ordering trick the TS
    // source uses for `this.hub = deps.createHub(this.hubEvents())`).
    _hub = _deps.createHub(_hubEvents());
    _mintCaptureId = _deps.mintCaptureId ?? (() => ++_captureSeq);

    final hostDeps = VoiceTurnHostDeps(
      disposeCapture: (turnId, captureId) => _disposeCapture(),
      hub: _HubControllerPort(_hub),
      interruptPlayback: (leaseId) => _hub.clearPlayback(),
      outputCoordinator: _OutputCoordinatorPort(_output),
      applyProjection: _deps.applyProjection,
    );
    _host = VoiceTurnHost(hostDeps);

    _coordinator = VoiceTurnCoordinator(
      scheduler: _deps.scheduler,
      mintTurnId: _deps.mintTurnId,
    );
    _coordinator.setEffectHandler(_host.effectHandler);
    _coordinator.configure(_host.presenter);
  }

  /// The turn currently owned by this driver, or null when idle/terminal.
  VoiceTurnId? get activeTurnId => _turnId;

  /// The reducer's current UI projection (idle when no turn is active).
  VoiceTurnUiProjection get projection => _coordinator.projection;

  // MARK: - Lifecycle (warm / teardown / dispose)

  /// Eagerly open the warm socket (e.g. a future capture_controller "about to
  /// press" hover/summon). Idempotent; a no-op when the kill-switch is off.
  void warm() {
    if (_disposed) return;
    if (!_deps.pttHubEnabled()) return;
    unawaited(_hub.ensureWarm().then((_) {}, onError: (_) {}));
  }

  /// A7c wake/unlock refresh — see `HubController.requestSessionRefresh`.
  void requestSessionRefresh(String reason) {
    if (_disposed) return;
    if (!_deps.pttHubEnabled()) return;
    _hub.requestSessionRefresh(reason);
  }

  /// Drop the warm socket without destroying the driver — a later `warm()`
  /// reconnects. Abandons any live turn first. Idempotent.
  void teardown() {
    if (_turnId != null) cancel();
    _hub.teardownSession();
  }

  /// Release everything this driver may hold, at any moment, and leave the
  /// instance inert. Idempotent.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    final turnId = _turnId;
    try {
      _coordinator.reset();
    } catch (_) {
      // The machinery may be the broken thing — fall through to manual cleanup.
    }
    try {
      _disposeCapture();
    } catch (_) {
      /* keep going — release everything we can */
    }
    if (turnId != null) {
      try {
        _output.endTurn(turnId);
      } catch (_) {
        /* keep going */
      }
      try {
        _hub.voiceTurnDidTerminate(turnId);
      } catch (_) {
        /* keep going */
      }
    }
    try {
      _hub.teardownSession();
    } catch (_) {
      /* keep going */
    }
    _turnId = null;
    _captureId = null;
    _route = const VoiceTurnRouteUndecided();
    _sessionId = null;
    _capture = null;
    _voiced = _zeroAudioStats;
  }

  // MARK: - PTT entry points (begin / end / cancel)

  /// A PTT hold started (flag on): barge-in, route selection, hub begin, and
  /// capture.
  void begin() {
    if (_disposed) return;

    // Barge-in seam (design doc §6 step 1): silence whatever the hub's own
    // player has already buffered, unconditionally and BEFORE anything else
    // — safe no-op when idle/nothing playing. This is the physical mute; the
    // reducer's own `terminate()` (already ported) separately decides
    // whether the OLD turn's hub session/lease is torn down or handed off
    // to this new one (`preservesHubForBargeInHandoff`) once `begin` below
    // sends `start`.
    _hub.clearPlayback();

    final superseding = _turnId != null;

    // `coordinator.begin` mints the id and sends `start`, which terminates
    // any prior turn first (as `interruptedByBargeIn` — a hub-route
    // predecessor's socket is preserved for this successor by the reducer,
    // not by anything here).
    final turnId = _coordinator.begin(VoiceTurnIntent.hold);
    _turnId = turnId;
    _captureId = _mintCaptureId();
    _output.beginTurn(turnId);
    _committed = false;
    _sessionId = null;
    _voiced = _zeroAudioStats;

    // The route is the host's job, not the reducer's — flag-gated
    // kill-switch (`selectPttRoute`, `voice_turn_host.dart`).
    final route = selectPttRoute(
      _HubControllerAvailability(_hub),
      pttHubEnabled: _deps.pttHubEnabled(),
    );
    _route = route;
    _dispatch(VoiceTurnEventSelectRoute(turnId: turnId, route: route));

    if (!routeMatchesHub(route)) {
      // Cut: no cascade/omniSTT lane in this port (see file header) — the
      // pref is off or the hub is entirely unavailable. Cancel immediately
      // rather than start a capture/transcription this driver doesn't own.
      _dispatch(VoiceTurnEventCancel(turnId: turnId, reason: VoiceTurnTerminalReason.cancelled));
      return;
    }

    _hub.beginTurn(turnId, interrupting: superseding);

    unawaited(_deps.startCapture(HubPttCaptureOptions(onChunk: (pcm) => _onCaptureChunk(pcm))).then((capture) {
      if (_turnId != turnId) {
        // The turn ended/cancelled while the mic spun up — drop the orphan.
        capture.dispose();
        return;
      }
      _capture = capture;
      _dispatch(VoiceTurnEventCaptureStarted(turnId: turnId, captureId: _captureId!));
    }, onError: (Object err) {
      if (_turnId != turnId) return;
      _dispatch(VoiceTurnEventCaptureFailed(turnId: turnId, captureId: null, message: err.toString()));
    }));
  }

  /// The PTT hold was released — finalize + resolve the turn.
  void end() {
    final turnId = _turnId;
    if (turnId == null) return;
    _committed = true;
    // `finalize` stops capture (the host disposes the mic) and enters
    // `finalizing`.
    _dispatch(VoiceTurnEventFinalize(turnId: turnId));

    if (!routeMatchesHub(_route)) {
      // Unreachable in practice: `begin()` already cancelled a non-hub route
      // before capture ever started, so `_turnId` would already be null
      // here. Kept as a guard, not a silent assumption.
      return;
    }

    // Release gate (2026-07-18 short-press wedge, ported from `ptt_gate.dart`):
    // decide from the captured PCM alone — BEFORE committing to the
    // provider — whether this turn is worth a hub response.
    //   tooShort / deadMic -> terminal `tooShort` ("Hold longer to record");
    //   silent (a real hold, live room, no speech) -> terminal
    //     `silentRejected` (quiet discard — never hand silence to the model).
    final hubGate = gateDecision(_voiced);
    if (hubGate == GateDecision.tooShort || hubGate == GateDecision.deadMic) {
      _dispatch(VoiceTurnEventFinish(turnId: turnId, reason: VoiceTurnTerminalReason.tooShort));
      return;
    }
    if (hubGate == GateDecision.silent) {
      _dispatch(VoiceTurnEventFinish(turnId: turnId, reason: VoiceTurnTerminalReason.silentRejected));
      return;
    }

    _hub.commitTurn(turnId);
    if (_hub.isWarm() && _sessionId != null) {
      // Warm hub: the commit is accepted now — advance to awaitingResponse.
      _dispatch(VoiceTurnEventHubCommitAccepted(turnId: turnId, sessionId: _sessionId!, responseId: null));
    } else {
      // Cold warm-wait: defer; `onConnected` (hubReady) + the controller's
      // replay drive acceptance, or the 1s `hubWarm` deadline degrades the
      // route (and, in this port, simply lets the turn time out — see the
      // cascade cut in the file header).
      _dispatch(VoiceTurnEventHubCommitDeferred(turnId: turnId));
    }
  }

  /// The PTT hold was aborted (gesture cancelled / focus loss).
  void cancel() {
    final turnId = _turnId;
    if (turnId == null) return;
    _dispatch(VoiceTurnEventCancel(turnId: turnId, reason: VoiceTurnTerminalReason.cancelled));
  }

  // MARK: - Capture

  void _onCaptureChunk(Uint8List pcmBytes) {
    final turnId = _turnId;
    if (turnId == null) return;

    // Accumulate this turn's voiced stats (capture-rate PCM) for the release gate.
    final pcm = pcm16FromBytes(pcmBytes);
    final stats = voicedStats(pcm);
    _voiced = AudioStats(
      totalSec: _voiced.totalSec + stats.totalSec,
      voicedSec: _voiced.voicedSec + stats.voicedSec,
      peak: math.max(_voiced.peak, stats.peak),
    );

    // Feed the hub. No resampling (see file header) — the capture is already
    // at the provider's required input rate.
    if (routeMatchesHub(_route)) {
      _hub.appendAudio(turnId, pcmBytes);
    }
  }

  void _disposeCapture() {
    _capture?.dispose();
    _capture = null;
  }

  // MARK: - Hub session/provider event -> reducer event mapping

  HubControllerEvents _hubEvents() {
    return HubControllerEvents(
      onConnected: (sessionId) {
        _sessionId = sessionId;
        final turnId = _turnId;
        if (turnId == null) return;
        if (_route is VoiceTurnRouteHubWarmWait) {
          _route = VoiceTurnRouteHub(sessionId);
          _dispatch(VoiceTurnEventHubReady(turnId: turnId, sessionId: sessionId));
          // The user released before the socket was ready (deferred commit):
          // the controller replays the commit on connect, so accept it.
          if (_committed) {
            _dispatch(VoiceTurnEventHubCommitAccepted(turnId: turnId, sessionId: sessionId, responseId: null));
          }
        }
      },
      onError: (error) {
        final turnId = _turnId;
        if (turnId != null) {
          _dispatch(VoiceTurnEventCancel(turnId: turnId, reason: VoiceTurnTerminalReason.providerFailed));
        }
      },
      onSpeakingStart: () {
        final turnId = _turnId;
        if (turnId == null) return;
        _dispatch(VoiceTurnEventProviderResponseStarted(turnId: turnId, sessionId: _sessionId, responseId: null));
        final decision = _output.acquire(VoiceOutputLane.nativeRealtime, turnId);
        if (decision is VoiceOutputDecisionAcquired) {
          _dispatch(VoiceTurnEventPlaybackStarted(turnId: turnId, lease: decision.lease));
        }
      },
      onSpeakingEnd: () {
        final turnId = _turnId;
        if (turnId == null) return;
        final lease = _output.snapshot().activeLease;
        if (lease != null) {
          _dispatch(VoiceTurnEventPlaybackDrained(turnId: turnId, leaseId: lease.id));
        }
      },
      onTurnDone: (identity) {
        final turnId = _turnId;
        if (turnId != null) {
          _dispatch(VoiceTurnEventProviderTurnFinished(turnId: turnId, sessionId: _sessionId, responseId: null));
        }
      },
      onInputTranscript: (text, isFinal, identity) {
        final turnId = _turnId;
        if (turnId == null || text.isEmpty) return;
        _dispatch(VoiceTurnEventTranscriptChanged(turnId: turnId, text: text));
      },
      onAssistantText: (text, isFinal, identity) {
        // Cut: no chat-kernel recording in this port (see file header) — the
        // reducer has no projection use for assistant text; only a future
        // "record this turn" seam would want it.
      },
      onToolRequest: (call, identity) {
        final executor = _deps.toolExecutor;
        if (executor != null) {
          executor(call);
          return;
        }
        // No executor wired (default): satisfy the provider defensively so
        // a declared-but-unhandled tool call can never hang a turn in
        // `awaitingTools` forever. See `VoiceHubTurnDriverDeps.toolExecutor`.
        _hub.sendToolResult(call.callId, call.name, 'Error: tools are not available');
      },
      onCascadeHandoff: (handoff) {
        // Cut: no cascade/batch-STT lane in this port (see file header) —
        // the hand-off frames are dropped. The reducer's own
        // `deferredCommit`/`transcription` deadlines (already ported,
        // `voice_turn_machine.dart`) terminate the turn with a hint a few
        // seconds later if the hub loses the warm-wait race, which is an
        // acceptable degrade: Android's separate GigaAM cascade already owns
        // voice capture entirely outside this driver.
      },
    );
  }

  // MARK: - Dispatch

  /// Every reducer event goes through here so terminal reconciliation
  /// (clearing the driver's per-turn state) happens exactly once, right
  /// after the send.
  void _dispatch(VoiceTurnEvent event) {
    _coordinator.send(event);
    if (_turnId != null && _coordinator.activeTurnId == null) {
      // Terminal reached: the host already ran stopCapture/cancelHub/
      // stopPlayback/endTurn via effects. Clear the driver's per-turn state.
      _turnId = null;
      _captureId = null;
      _route = const VoiceTurnRouteUndecided();
      _sessionId = null;
      _capture = null;
    }
  }
}

// ---------------------------------------------------------------------------
// MARK: - PCM helpers (pure, module-local)
// ---------------------------------------------------------------------------

/// Reinterprets raw little-endian PCM16 mic bytes as samples for
/// [voicedStats]. Copies into a fresh, zero-offset buffer first — a
/// [Uint8List] handed across a platform channel is not guaranteed to start
/// at an even buffer offset, and `Uint8List.buffer.asInt16List()` requires
/// 2-byte alignment; an odd trailing byte (should never happen for 16-bit
/// PCM, but is cheap to guard) is dropped rather than thrown on. Mirrors the
/// TS source's `bytesToPcm16`.
Int16List pcm16FromBytes(Uint8List bytes) {
  final evenLength = bytes.length - (bytes.length % 2);
  final aligned = Uint8List.fromList(evenLength == bytes.length ? bytes : bytes.sublist(0, evenLength));
  return aligned.buffer.asInt16List();
}
