// Warm-hub controller — a 1:1 port of the surviving (post-cuts) half of
// `desktop/windows/src/renderer/src/lib/voice/hub/hubController.ts`
// (`HubController`), design doc `~/omi-jarvis/docs/hub-port-design.md` §2-§4,
// §8 step "hubController.ts" (the middle layer between the per-turn driver,
// design doc §8 step 5 — not yet written — and the single warm `HubSession`
// from `hub_session.dart`/`gemini_hub_session.dart`).
//
// What this owns (unchanged from the TS source, see its own header):
//   1. `ensureWarm()` — mint an ephemeral token, assemble the session
//      instructions, and warm the `HubSession`. Idempotent; eager-callable.
//   2. The controller-owned warm-wait PCM buffer + flush — DELIBERATELY
//      separate from `BaseHubSession`'s own pre-open buffer (see that file's
//      header): the controller withholds PCM entirely until it knows
//      whether the hub or the cascade wins the reducer's warm-wait race, so
//      a fallen-back turn's audio can never leak into the next hub turn.
//   3. The four per-turn primitives (begin/append/commit/cancel), turn-ID
//      fenced so a superseded turn's late call is inert.
//   4. `voiceTurnDidTerminate(turnId)` — release per-turn state but KEEP the
//      warm socket (the whole point of a warm hub).
//   5. The connect/error surface (A7c): `onConnected`/`onError` enriched
//      with `aliveForMs`, PLUS the actual A7c reconnect policy (strike-
//      bounded backoff + circuit breaker + idle-teardown survival) — the TS
//      source's own comment ("A5 builds the seam only") describes an
//      earlier PR; by the version read for this port A7c was already
//      implemented here, so it is ported in full.
//   6. The PR-C tool-catalog loop (`fetchTools`, `HubSessionSpec.tools`,
//      lane5.md §"ГЛАВНЫЙ ПРИОРИТЕТ 22.08" step 3): fetched fresh at each
//      warm, generation-checked exactly like the token mint (a
//      `teardownSession()` that straddles the fetch discards the warm), a
//      fetch failure warms tool-less rather than failing the session.
//
// Three scope cuts vs. the TS source, all forced by decisions already made
// in sibling files (NOT re-litigated here) and all documented at their cut
// site below rather than filled in with placeholders:
//   * Cross-provider failover (`fallbackProvider`, `pendingFailoverReason`,
//     `failoverOnMintFailure`, the mint-retry loop) — design doc §3: the
//     Gemini lane is the only provider (`HubProvider` in `hub_session.dart`
//     is a single-value enum), so there is nothing to fail over TO. A mint
//     failure just propagates.
//   * The PR-B continuity seed (`fetchSeed`, `seedContext`,
//     `knownSeedKeys`, `markSeedKeyProduced`, `refreshSeedContext`) — cut
//     because it depends on a kernel/typed-conversation bridge that has no
//     Android port at all (out of lane5's scope: this lane owns the
//     WebSocket/audio plumbing, not conversation persistence). `instructions`
//     stays a plain injected `buildInstructions()` seam with no seed
//     splicing.
//   * Desktop-only observability (`trackEvent` analytics, `recordVoiceFlight`
//     flight recorder) has no Android equivalent and is dropped; the
//     control-flow decisions they annotated in the TS source are preserved
//     verbatim, only the telemetry calls are gone.
//
// `resolveProvider`/`sinkId` are gone entirely for the same single-provider,
// no-Web-Audio reasons `hub_session.dart` already documents.

import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'hub_close.dart';
import 'hub_session.dart';
import 'voice_turn_machine.dart' show VoiceResponseId, VoiceSessionId, VoiceTurnId;

// ---------------------------------------------------------------------------
// MARK: - Public surface (TS `HubCascadeHandoff` / `HubControllerError` /
// `HubControllerEvents` / `HubSessionSpec`)
// ---------------------------------------------------------------------------

/// The PCM handed to the cascade when the hub loses the warm-wait race.
/// Frozen at the instant of hand-off; [committed] records whether the user
/// had already released (so the cascade knows to finalize rather than await
/// more audio).
class HubCascadeHandoff {
  final List<Uint8List> frames;
  final bool committed;
  const HubCascadeHandoff({required this.frames, required this.committed});
}

/// A fatal session error, enriched with [aliveForMs] — lets the reconnect
/// policy tell a flapping socket (strike) from a long-lived one (reset
/// strikes). 0 when the socket never finished connecting.
class HubControllerError {
  final String reason;
  final bool retryable;
  final int aliveForMs;
  const HubControllerError({required this.reason, required this.retryable, required this.aliveForMs});
}

/// Everything the controller surfaces to its host (the per-turn driver,
/// design doc §8 step 5). The content events are a straight pass-through of
/// the session's; connect/error are enriched; `onCascadeHandoff` is the
/// warm-wait -> cascade degradation.
class HubControllerEvents {
  final void Function(VoiceSessionId sessionId)? onConnected;
  final void Function(HubControllerError error)? onError;
  final void Function(String text, bool isFinal, HubEventIdentity? identity)? onInputTranscript;
  final void Function(String text, bool isFinal, HubEventIdentity? identity)? onAssistantText;
  final void Function()? onSpeakingStart;
  final void Function()? onSpeakingEnd;
  final void Function(HubToolCallRequest call, HubEventIdentity? identity)? onToolRequest;
  final void Function(HubEventIdentity? identity)? onTurnDone;
  final void Function(HubCascadeHandoff handoff)? onCascadeHandoff;

  const HubControllerEvents({
    this.onConnected,
    this.onError,
    this.onInputTranscript,
    this.onAssistantText,
    this.onSpeakingStart,
    this.onSpeakingEnd,
    this.onToolRequest,
    this.onTurnDone,
    this.onCascadeHandoff,
  });
}

/// How the controller builds the (Gemini-only) provider session — injected
/// so tests supply a fake and never touch a real WebSocket.
class HubSessionSpec {
  final String token;
  final String instructions;
  final HubSessionEvents events;

  /// The provider-neutral tool catalog this session should advertise (PR-C).
  /// Empty when no `fetchTools` seam is wired or its fetch failed.
  final List<VoiceToolDeclaration> tools;

  const HubSessionSpec({
    required this.token,
    required this.instructions,
    required this.events,
    this.tools = const [],
  });
}

typedef HubMintToken = Future<String> Function();
typedef HubBuildInstructions = String Function();
typedef HubCreateSession = HubSession Function(HubSessionSpec spec);

/// Read the provider-neutral tool catalog the session should advertise
/// (PR-C). Absent ⇒ no tools (today's default behavior, unchanged).
typedef HubFetchTools = Future<List<VoiceToolDeclaration>> Function();

// ---------------------------------------------------------------------------
// MARK: - Internal errors (TS `HubWarmAbortedError` / `HubCircuitOpenError`)
// ---------------------------------------------------------------------------

/// Thrown by the internal warm routine when a `teardownSession()` bumped the
/// warm generation while the warm was in flight: the result is discarded
/// (never installed) rather than left as an orphaned socket re-warming on a
/// now-disabled hub. Callers swallow it exactly like a reconnect reject — it
/// is not a surfaced error.
class HubWarmAbortedError implements Exception {
  @override
  String toString() => 'HubWarmAbortedError: hub warm aborted by teardown';
}

/// Thrown by [HubController.ensureWarm] when the reconnect circuit is OPEN
/// and still cooling down: the strike budget was spent, so a dead endpoint
/// is not rebuilt until the cooldown elapses (the press falls to the
/// cascade meanwhile). Swallowed by callers exactly like the reconnect /
/// teardown-abort rejects — it is not a surfaced error.
class HubCircuitOpenError implements Exception {
  @override
  String toString() => 'HubCircuitOpenError: hub warm suppressed: reconnect circuit open';
}

class _PendingBegin {
  final VoiceTurnId turnId;
  final VoiceResponseId? responseId;
  final bool interrupting;
  const _PendingBegin({required this.turnId, this.responseId, this.interrupting = false});
}

// ---------------------------------------------------------------------------
// MARK: - Controller
// ---------------------------------------------------------------------------

class HubController {
  final HubControllerEvents events;
  final HubBuildInstructions buildInstructions;
  final HubMintToken mintToken;
  final HubCreateSession createSession;
  final HubClock clock;
  final int Function() now;
  final HubFetchTools? fetchTools;

  HubController({
    this.events = const HubControllerEvents(),
    required this.buildInstructions,
    required this.mintToken,
    required this.createSession,
    HubClock? clock,
    int Function()? now,
    this.fetchTools,
  })  : clock = clock ?? const DefaultHubClock(),
        now = now ?? _defaultNow;

  static int _defaultNow() => DateTime.now().millisecondsSinceEpoch;

  /// After this many consecutive FAILURE re-warms with no surviving session,
  /// stop re-warming so a dead endpoint (revoked token, provider outage)
  /// isn't hammered. Expected idle teardowns never spend a strike.
  static const int maxReconnectStrikes = 5;

  /// Backoff before a scheduled re-warm.
  static const Duration reconnectBackoff = Duration(milliseconds: 1500);

  /// After the strike budget is spent the re-warm circuit OPENS for this
  /// cooldown instead of hammering a dead endpoint forever. See
  /// [ensureWarm] for the half-open probe semantics.
  static const int circuitCooldownMs = 60000;

  HubSession? session;
  VoiceSessionId? sessionId;
  int? connectedAt;

  /// In-flight [ensureWarm], so overlapping calls (summon + first press)
  /// coalesce.
  Future<VoiceSessionId>? _warming;

  /// Monotonic warm generation, bumped by every [teardownSession]. An
  /// in-flight warm captures it at the start and, at each commit point,
  /// discards its result if the generation moved.
  int _warmGeneration = 0;

  // A7c reconnect budget ------------------------------------------------
  int _reconnectStrikes = 0;
  bool _reconnectPending = false;
  Object? _reconnectHandle;

  /// Wall-clock deadline (via [now]) before which the open circuit rejects
  /// warms; null when the circuit is not tripped.
  int? _circuitOpenUntil;

  // A7c wake / zombie-session refresh ------------------------------------
  /// A wake/unlock refresh that arrived mid-turn is deferred here so we
  /// never tear down a live turn, then applied once the turn terminates.
  String? _pendingRefreshReason;

  // Per-turn state (all reset by voiceTurnDidTerminate) -------------------
  VoiceTurnId? _activeTurnId;

  /// Non-null => we are in the reducer's warm-wait and withholding PCM from
  /// the session (buffering it here for the hub-flush-or-cascade-handoff
  /// decision).
  List<Uint8List>? _warmBuffer;

  /// The user released while still warm-waiting — replay the commit after
  /// flush.
  bool _warmCommitted = false;

  /// The warm-wait buffer was handed to the cascade — the hub side is
  /// abandoned for this turn, so later primitives are inert until the next
  /// turn.
  bool _handedOff = false;

  /// A `beginTurn` that arrived before the session object existed (cold
  /// press with no prior summon); applied once [createSession] runs.
  _PendingBegin? _pendingBegin;

  // MARK: Warm (idempotent, eager-callable)

  /// Opens (or reuses) the warm hub socket. Idempotent: a no-op that
  /// resolves to the live session id when already warm, and coalesces with
  /// an in-flight warm.
  Future<VoiceSessionId> ensureWarm() {
    final inFlight = _warming;
    if (inFlight != null) return inFlight;
    final s = session;
    final sid = sessionId;
    if (s != null && s.isWarm() && sid != null) {
      return Future.value(sid);
    }
    // Circuit breaker (recovery). While the strike budget is spent the
    // circuit is OPEN: during the cooldown a warm trigger is rejected so we
    // don't rebuild a dead endpoint — every press falls to the cascade. When
    // the cooldown elapses the FIRST trigger is allowed through as a single
    // half-open probe, and the cooldown re-arms so a probe that fails waits
    // a full cooldown before the next attempt. A probe that proves good
    // resets the strikes (aliveFor>60 / a completed turn), closing the
    // circuit.
    if (_reconnectStrikes >= maxReconnectStrikes) {
      final openUntil = _circuitOpenUntil;
      if (openUntil != null && now() < openUntil) {
        return Future<VoiceSessionId>.error(HubCircuitOpenError());
      }
      _circuitOpenUntil = now() + circuitCooldownMs;
    }
    final future = _createAndWarm();
    _warming = future;
    return future;
  }

  Future<VoiceSessionId> _createAndWarm() async {
    // Capture the generation this warm belongs to. A teardownSession() that
    // runs at any await point below bumps it, and the commit-point checks
    // then discard this warm instead of installing an orphaned socket.
    final gen = _warmGeneration;
    try {
      // Tear down a stale session before minting a fresh token.
      final stale = session;
      if (stale != null) {
        session = null;
        connectedAt = null;
        stale.teardown();
      }

      final token = await mintToken();

      // A teardownSession() straddled the mint. Bail BEFORE building a
      // session: nothing was opened yet, so there is nothing to close, just
      // discard the token.
      if (_warmGeneration != gen) throw HubWarmAbortedError();

      // The tool catalog is host-derived. A fetch failure warms tool-less
      // rather than failing the whole session — voice conversation still
      // works, the model just can't call a tool this session.
      final fetch = fetchTools;
      List<VoiceToolDeclaration> tools = const [];
      if (fetch != null) {
        try {
          tools = await fetch();
        } catch (_) {
          tools = const [];
        }
      }

      // The catalog fetch is another await point — re-check the generation
      // so a teardown that straddled it discards this warm instead of
      // installing a socket on a now-torn-down hub, same as the mint check.
      if (_warmGeneration != gen) throw HubWarmAbortedError();

      final instructions = buildInstructions();
      final newSession = createSession(HubSessionSpec(
        token: token,
        instructions: instructions,
        events: _sessionEvents(),
        tools: tools,
      ));
      session = newSession;

      // A turn that began before the session existed (cold press, no
      // summon) now gets its provider begin frames.
      final pending = _pendingBegin;
      if (pending != null && pending.turnId == _activeTurnId) {
        _pendingBegin = null;
        newSession.beginTurn(HubBeginTurnOptions(
          turnId: pending.turnId,
          responseId: pending.responseId,
          interrupting: pending.interrupting,
        ));
      }

      await newSession.ensureWarm();
      // A teardownSession() interleaved between the warm resolving and this
      // continuation. Discard the just-connected session: close its socket
      // so it does not leak, and do NOT touch `session`/`sessionId` (already
      // cleared by the teardown; a newer warm would own them). `teardown()`
      // is idempotent, so a double close is safe.
      if (_warmGeneration != gen) {
        newSession.teardown();
        throw HubWarmAbortedError();
      }
      // onConnected (wired below) set `sessionId` synchronously inside
      // markReady, before this future resolves.
      final sid = sessionId;
      if (sid == null) throw StateError('hub session connected without a session id');
      return sid;
    } finally {
      _warming = null;
    }
  }

  bool isWarm() => session?.isWarm() ?? false;

  /// Whether a session object exists at all (warm or connecting).
  bool isAvailable() => session != null;

  /// PCM16 rate the host must resample mic frames to before [appendAudio].
  /// Null until a session exists.
  int? requiredInputSampleRate() => session?.requiredInputSampleRate;

  /// Drops the warm socket (idle release / wake refresh). A re-warm is
  /// [teardownSession] then [ensureWarm]; both are safe at any turn phase.
  /// Does NOT touch per-turn reducer state.
  void teardownSession() {
    // Invalidate any in-flight ensureWarm: a warm that was minting or
    // connecting when this explicit drop happened must discard its result
    // at its next commit point rather than install an orphaned socket.
    _warmGeneration += 1;
    _cancelReconnect();
    _reconnectStrikes = 0;
    _circuitOpenUntil = null;
    // An explicit drop also cancels any wake refresh deferred behind a
    // turn — re-warming a hub that was just told to close is wrong.
    _pendingRefreshReason = null;
    final s = session;
    session = null;
    sessionId = null;
    connectedAt = null;
    s?.teardown();
  }

  /// The OS suspended/locked and resumed: while suspended the underlying
  /// transport likely died, so the next PTT press would commit onto a
  /// zombie session (no reply, no fallback, hang). Proactively drops the
  /// possibly-dead socket and re-warms so the first press after wake is
  /// warm.
  ///
  /// Only acts when idle — a live session exists, no active turn, no
  /// connect already in flight — so it never interrupts a turn nor races
  /// an in-flight warm. Mid-turn it DEFERS the reason and re-warms once the
  /// turn terminates. It never force-warms a hub with no session (disabled
  /// / signed out).
  void requestSessionRefresh(String reason) {
    // Nothing to refresh when the hub isn't warm — never open a socket for
    // a disabled hub.
    if (session == null) return;
    // Mid-turn: defer to the turn's termination so we never tear down a
    // live turn.
    if (_activeTurnId != null) {
      _pendingRefreshReason = reason;
      return;
    }
    // Mid-connect: a warm is already in flight building a fresh socket —
    // let it finish rather than race it.
    if (_warming != null) return;
    // Idle + warm: drop the (possibly dead) socket and rebuild.
    teardownSession();
    _fireAndForgetWarm();
  }

  // MARK: The four per-turn primitives (turn-ID fenced)

  /// Starts a PTT turn on the warm hub. Supersedes any prior turn (a
  /// barge-in `interrupting` begin drives the provider's in-flight-reply
  /// cancel). Buffers PCM locally when the socket is not yet warm (the
  /// reducer's warm-wait).
  void beginTurn(VoiceTurnId turnId, {VoiceResponseId? responseId, bool interrupting = false}) {
    _activeTurnId = turnId;
    _handedOff = false;
    _warmCommitted = false;

    // Warm-wait iff the socket is not ready: withhold PCM so it can still
    // be handed to the cascade if the hub loses the race. When already
    // warm, audio streams straight through and `_warmBuffer` stays null.
    _warmBuffer = (session?.isWarm() ?? false) ? null : <Uint8List>[];

    // Idempotent safety; eager summon usually warmed already. Swallow the
    // reject like the reconnect path: this warm can reject on a mint
    // failure or a teardown-abort, and the reducer's warm-wait / cascade
    // timeout owns the degradation.
    _fireAndForgetWarm();

    final s = session;
    if (s != null) {
      s.beginTurn(HubBeginTurnOptions(turnId: turnId, responseId: responseId, interrupting: interrupting));
    } else {
      // No session object yet (cold press, no prior summon) — apply on
      // create.
      _pendingBegin = _PendingBegin(turnId: turnId, responseId: responseId, interrupting: interrupting);
    }
  }

  /// Feeds one mic PCM16 frame at `requiredInputSampleRate`. Buffered
  /// locally during warm-wait; inert once the turn has been handed to the
  /// cascade.
  void appendAudio(VoiceTurnId turnId, Uint8List pcm) {
    if (turnId != _activeTurnId || _handedOff) return;
    final buffer = _warmBuffer;
    if (buffer != null) {
      buffer.add(pcm);
      return;
    }
    session?.appendAudio(pcm);
  }

  /// Ends the held turn and asks the model to respond. During warm-wait the
  /// commit is deferred: it replays after the flush on hub-ready, or the
  /// cascade owns finalize after a hand-off.
  void commitTurn(VoiceTurnId turnId) {
    if (turnId != _activeTurnId || _handedOff) return;
    if (_warmBuffer != null) {
      _warmCommitted = true;
      return;
    }
    session?.commitTurn();
  }

  /// Abandons the current turn (silent tap / explicit cancel / non-
  /// preserving barge-in), keeping the warm socket. Discards any warm-wait
  /// buffer.
  void cancelTurn(VoiceTurnId turnId) {
    if (turnId != _activeTurnId) return;
    _warmBuffer = null;
    _warmCommitted = false;
    session?.cancelTurn();
  }

  /// Relays a tool result back to the warm provider session so the model
  /// can finish the turn. No-op when no session exists (a torn-down /
  /// barged-in turn). The driver applies the turn-epoch gate before calling
  /// this, so a stale turn's result never reaches the provider.
  void sendToolResult(String callId, String name, String output) {
    session?.sendToolResult(callId, name, output);
  }

  /// Barge-in seam (design doc §6 step 1, `voice_turn_driver.dart`):
  /// immediately silence whatever the warm session's player has already
  /// buffered. Safe no-op when there is no session (idle) or nothing is
  /// playing. The turn driver calls this UNCONDITIONALLY on every `begin()`
  /// — Gemini cannot cleanly cancel a streaming reply in-session, so muting
  /// the already-enqueued PCM locally is the only way to silence a barged-in
  /// reply — and wires it as the reducer's `stopPlayback` effect target too:
  /// this port has no separate cascade/TTS player to interrupt (see the
  /// driver's own header), so both paths converge on this one call.
  void clearPlayback() => session?.clearPlayback();

  /// The reducer's `hubWarm` deadline fired: the hub lost the race. Hands
  /// the buffered PCM to the batch cascade. The turn CONTINUES on the
  /// cascade — nothing here terminates it.
  void handoffWarmWaitToCascade(VoiceTurnId turnId) {
    if (turnId != _activeTurnId || _warmBuffer == null) return;
    final frames = _warmBuffer!;
    final committed = _warmCommitted;
    _warmBuffer = null;
    _handedOff = true;

    events.onCascadeHandoff?.call(HubCascadeHandoff(frames: frames, committed: committed));

    // Abandon the hub side of this turn cleanly (closes Gemini's activity
    // window) while KEEPING the warm socket for the next turn.
    session?.cancelTurn();
  }

  /// The turn terminated (any reason). Releases per-turn state so the next
  /// turn starts clean, but KEEPS the warm socket — that is the whole point
  /// of a warm hub; only the 180s idle timer or an explicit
  /// [teardownSession] closes it.
  void voiceTurnDidTerminate(VoiceTurnId turnId) {
    if (turnId != _activeTurnId) return;
    _activeTurnId = null;
    _warmBuffer = null;
    _warmCommitted = false;
    _handedOff = false;
    _pendingBegin = null;
    // A wake/refresh that arrived mid-turn was deferred; now idle, honor
    // it. requestSessionRefresh re-checks the gates before re-warming.
    final reason = _pendingRefreshReason;
    if (reason != null) {
      _pendingRefreshReason = null;
      requestSessionRefresh(reason);
    }
  }

  // MARK: Session event wiring (pass-through + connect/error enrichment)

  HubSessionEvents _sessionEvents() {
    return HubSessionEvents(
      onConnected: (sid) => _handleConnected(sid),
      onError: (message, retryable, closeCode) => _handleError(message, retryable, closeCode),
      onInputTranscript: (text, isFinal, identity) => events.onInputTranscript?.call(text, isFinal, identity),
      onAssistantText: (text, isFinal, identity) => events.onAssistantText?.call(text, isFinal, identity),
      onSpeakingStart: () => events.onSpeakingStart?.call(),
      onSpeakingEnd: () => events.onSpeakingEnd?.call(),
      onToolRequest: (call, identity) => events.onToolRequest?.call(call, identity),
      onTurnDone: (identity) {
        // A completed turn proves the hub works — reset the strike budget
        // and close any open circuit.
        _reconnectStrikes = 0;
        _circuitOpenUntil = null;
        events.onTurnDone?.call(identity);
      },
    );
  }

  void _handleConnected(VoiceSessionId sid) {
    sessionId = sid;
    connectedAt = now();
    // A live socket supersedes any pending reconnect backoff. NB:
    // connecting alone does NOT reset the strike budget — only a
    // proven-good signal does (a completed turn, or a socket that survives
    // past the idle window). A socket that connects then dies fast
    // repeatedly must still exhaust its budget and stop.
    _cancelReconnect();

    // Flush any PCM withheld during warm-wait into the now-ready session,
    // in order, then replay a deferred commit. The hub won the race.
    final buffer = _warmBuffer;
    final s = session;
    if (buffer != null && s != null) {
      _warmBuffer = null;
      for (final frame in buffer) {
        s.appendAudio(frame);
      }
      if (_warmCommitted) {
        _warmCommitted = false;
        s.commitTurn();
      }
    }
    events.onConnected?.call(sid);
  }

  void _handleError(String message, bool retryable, int? closeCode) {
    final connected = connectedAt;
    final aliveForMs = connected != null ? math.max(0, now() - connected) : 0;
    // Classify BEFORE forwarding: the forward drives the reducer's
    // terminal, which clears `_activeTurnId`, so the turn-at-close-time
    // must be captured first.
    final hadActiveTurn = _activeTurnId != null;
    // The session tore itself down on error; drop our handle so ensureWarm
    // rebuilds.
    session = null;
    connectedAt = null;
    final category = classifyHubClose(HubCloseInput(
      message: message,
      closeCode: closeCode,
      aliveForMs: aliveForMs,
      hasActiveTurn: hadActiveTurn,
    ));
    events.onError?.call(HubControllerError(reason: message, retryable: retryable, aliveForMs: aliveForMs));
    _scheduleReconnectForClose(category, aliveForMs);
  }

  // MARK: A7c reconnect policy (strike-bounded re-warm + idle-teardown survival)

  /// Decides whether/how to re-warm after a socket close. A socket that
  /// survived past the idle window proved the endpoint works, so it
  /// refreshes the strike budget. A genuine FAILURE re-warms bounded by the
  /// budget so a dead endpoint isn't hammered.
  void _scheduleReconnectForClose(HubCloseCategory category, int aliveForMs) {
    if (aliveForMs > hubIdleTeardownThresholdMs) {
      _reconnectStrikes = 0;
      _circuitOpenUntil = null;
    }
    if (consumesStrike(category)) {
      if (_reconnectStrikes >= maxReconnectStrikes) {
        // Budget spent: the re-warm circuit is now OPEN. Stop hammering a
        // dead endpoint for a cooldown; `ensureWarm` rejects warms until it
        // elapses, then lets ONE half-open probe through.
        _circuitOpenUntil = now() + circuitCooldownMs;
        return;
      }
      _reconnectStrikes += 1;
    }
    _scheduleReWarm();
  }

  /// Arms the one-shot backoff. Coalesced: a second close while one is
  /// pending is a no-op. Rebuilds only if nothing else re-warmed first.
  void _scheduleReWarm() {
    if (_reconnectPending) return;
    _reconnectPending = true;
    _reconnectHandle = clock.setTimer(reconnectBackoff, () {
      _reconnectHandle = null;
      _reconnectPending = false;
      // A failed re-warm (e.g. a still-dead mint) is expected on this
      // path — swallow the rejection so it never surfaces as an unhandled
      // error; the next press (or a socket close from a partial connect)
      // drives the next attempt.
      if (session == null) _fireAndForgetWarm();
    });
  }

  void _cancelReconnect() {
    final handle = _reconnectHandle;
    if (handle != null) {
      clock.clearTimer(handle);
      _reconnectHandle = null;
    }
    _reconnectPending = false;
  }

  void _fireAndForgetWarm() {
    unawaited(_warmSwallowingErrors());
  }

  Future<void> _warmSwallowingErrors() async {
    try {
      await ensureWarm();
    } catch (_) {
      // Swallowed — the warm-wait timeout / reconnect policy owns the
      // degradation; an unhandled rejection here would be a false crash
      // signal.
    }
  }
}
