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

  // Без toString() каждый лог обрыва печатал бесполезное
  // «Instance of 'HubControllerError'» — причину первого обрыва 24.08 так и
  // не узнали (логкат 03:31:28). Причина обязана быть видна в логе.
  @override
  String toString() => 'HubControllerError(reason: $reason, retryable: $retryable, aliveForMs: $aliveForMs)';
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

  /// Server-VAD's "user is / is not speaking" verdict — see
  /// [HubSessionEvents.onUserSpeechState] for what it does and does not mean.
  final void Function(bool isSpeaking)? onUserSpeechState;
  final void Function()? onSpeakingStart;
  final void Function()? onSpeakingEnd;

  /// Self-host patch: barge-in — см. [HubSessionEvents.onInterrupted].
  final void Function()? onInterrupted;
  final void Function(HubToolCallRequest call, HubEventIdentity? identity)? onToolRequest;
  final void Function(HubEventIdentity? identity)? onTurnDone;
  final void Function(HubCascadeHandoff handoff)? onCascadeHandoff;

  /// The provider warned that the socket is about to close (see
  /// [HubSessionEvents.onGoAway]), delivered at a moment when rebuilding is
  /// safe — never mid-reply.
  ///
  /// A host with no long-lived turn need not do anything: the controller
  /// rebuilds the socket itself in that case. It is load-bearing for a host
  /// that holds ONE turn open for a whole session (free-form voice mode,
  /// whose "turn" is the entire mode), because there the controller must not
  /// tear down alone — the host owns mic capture and the begin frame, so only
  /// it can rebuild without leaving a socket that ignores everything.
  final void Function(Duration? timeLeft)? onGoAway;

  const HubControllerEvents({
    this.onConnected,
    this.onError,
    this.onInputTranscript,
    this.onAssistantText,
    this.onUserSpeechState,
    this.onSpeakingStart,
    this.onSpeakingEnd,
    this.onInterrupted,
    this.onToolRequest,
    this.onTurnDone,
    this.onCascadeHandoff,
    this.onGoAway,
  });

  /// Same handlers with individual ones swapped out. Exists so callers that
  /// only want to intercept ONE event (production wiring routes
  /// [onToolRequest] to the `ask_claude` executor) don't hand-copy the other
  /// eight — a copy that silently drops whatever the copy was written before.
  /// That is not hypothetical: [onUserSpeechState] was added 23.08 and every
  /// unit test passed while the production path quietly discarded it, because
  /// the wiring listed fields by name.
  HubControllerEvents copyWith({
    void Function(HubToolCallRequest call, HubEventIdentity? identity)? onToolRequest,
  }) {
    return HubControllerEvents(
      onConnected: onConnected,
      onError: onError,
      onInputTranscript: onInputTranscript,
      onAssistantText: onAssistantText,
      onUserSpeechState: onUserSpeechState,
      onSpeakingStart: onSpeakingStart,
      onSpeakingEnd: onSpeakingEnd,
      onToolRequest: onToolRequest ?? this.onToolRequest,
      onTurnDone: onTurnDone,
      onCascadeHandoff: onCascadeHandoff,
      onGoAway: onGoAway,
    );
  }
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

  /// Resume the conversation the previous socket was having instead of
  /// starting blank (design doc §10). Null == a fresh conversation, which is
  /// every session before this seam existed.
  final String? resumptionHandle;

  const HubSessionSpec({
    required this.token,
    required this.instructions,
    required this.events,
    this.tools = const [],
    this.resumptionHandle,
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

  /// Gate on the SELF-driven re-warm after a socket close. When set and
  /// returning `false`, the controller stays cold instead of rebuilding the
  /// session on its own — an explicit `ensureWarm` still works. Null keeps
  /// the historical always-re-warm behavior (the PTT driver's contract).
  ///
  /// Exists because of the 24.08 zombie: the free-form mode's hub kept
  /// resurrecting itself through the Gemini idle-close (1008) -> re-warm ->
  /// idle-close loop every ~2.5 min for half an hour after the user thought
  /// the mode was off — burning per-minute input billing and replacing the
  /// native player under any NEWER session the user started (which is why
  /// repeat launches played silence). The mode's liveness is the only
  /// authority on whether staying warm is worth money.
  final bool Function()? shouldStayWarm;

  HubController({
    this.events = const HubControllerEvents(),
    required this.buildInstructions,
    required this.mintToken,
    required this.createSession,
    HubClock? clock,
    int Function()? now,
    this.fetchTools,
    this.shouldStayWarm,
  })  : clock = clock ?? const DefaultHubClock(),
        now = now ?? _defaultNow;

  static int _defaultNow() => DateTime.now().millisecondsSinceEpoch;

  /// After this many consecutive FAILURE re-warms with no surviving session,
  /// stop re-warming so a dead endpoint (revoked token, provider outage)
  /// isn't hammered. Expected idle teardowns never spend a strike.
  static const int maxReconnectStrikes = 5;

  /// Backoff before a scheduled re-warm.
  static const Duration reconnectBackoff = Duration(milliseconds: 1500);

  /// How long a resumption handle is considered to belong to "the current
  /// conversation". A product cut, not an API limit: coming back after a long
  /// gap should feel like a new conversation, not a silent continuation of
  /// one the user has forgotten. The server may well expire handles sooner —
  /// that path is handled too (see [_handleInFlight]).
  static const int resumptionHandleTtlMs = 15 * 60 * 1000;

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

  // Conversation resumption (design doc §10) ------------------------------
  /// The handle the NEXT session should resume from, or null when the last
  /// thing the dying session said was "not safe to resume right now" (it was
  /// mid-reply — see [HubSessionEvents.onResumptionHandle]). Deliberately
  /// survives [teardownSession]: the 120s idle release is the case this
  /// exists for — the socket goes away, the conversation should not.
  String? _resumptionHandle;

  /// When [_resumptionHandle] was captured (via [now]), for the staleness cut.
  int? _resumptionHandleAt;

  /// Set while the provider is producing a reply, i.e. exactly while the
  /// session says resuming would be unsafe. Derived from the handle
  /// WITHDRAWAL (`onResumptionHandle(null)`), which a session emits only when
  /// a generation starts — see [HubSessionEvents.onResumptionHandle]. Used to
  /// keep a `goAway` rebuild out of the middle of a reply.
  bool _replyGenerating = false;

  /// A `goAway` warning that is still waiting for a safe moment to act on.
  bool _goAwayPending = false;

  /// How much time the `goAway` said was left, carried to the host with the
  /// deferred warning (null when the server named no deadline).
  Duration? _goAwayTimeLeft;

  /// The user is speaking RIGHT NOW, per the provider's own VAD
  /// ([HubSessionEvents.onUserSpeechState]). A `goAway` rebuild waits this
  /// out: the rebuild takes the microphone down with the socket, so firing it
  /// mid-sentence drops whatever the user was saying — silently, since they
  /// have no way to know they were not being heard.
  bool _userSpeaking = false;

  /// Deadline timer that spends a `goAway` even if no safe moment ever
  /// arrives. Without it a user who keeps talking through the whole warning
  /// window gets the very drop the warning existed to avoid.
  Object? _goAwayDeadlineHandle;

  /// The `goAway` runway ran out. Only [_toolCallInFlight] yields to it: the
  /// socket is about to be closed by the server either way, and a rebuild we
  /// chose (handle in hand, conversation carried over, the late answer
  /// relayed by [_deliverOrphanedToolResult]) beats the drop we did not.
  /// A withdrawn handle — [_replyGenerating] — is NOT overridden here: there
  /// the rebuild would resume from nothing, so it stays the worse trade.
  bool _goAwayDeadlineExpired = false;

  /// Tool calls the model has asked for and nobody has answered yet, mapped
  /// to the socket that asked (`callId` -> [sessionId] at request time).
  ///
  /// Measured against live Gemini 24.08 (`marathon/probes/lane5-toolcall-seam.py`),
  /// and the reason this map exists at all: the server hands out a resumption
  /// handle 0.3s AFTER the `toolCall` frame, while the call is still
  /// unanswered. [_replyGenerating] is derived from exactly that handle, so
  /// without this the whole `ask_claude` round trip — 7-40s of it, measured —
  /// looks to [_actOnGoAwayIfSafe] like a quiet moment, and the rebuild lands
  /// in the middle of it. See [_toolCallInFlight].
  final Map<String, VoiceSessionId?> _toolCallOrigin = {};

  /// Watchdog for a turn that went silent after the tool answered. Armed the
  /// moment the LAST outstanding call of a batch is answered, disarmed by any
  /// sign of life. See [_armToolStallWatchdog].
  Object? _toolStallHandle;

  /// What the watchdog would re-deliver if it fires — the answer the model
  /// already has and is not speaking.
  String? _stalledToolName;
  String? _stalledToolOutput;

  /// A tool result that came back for a socket that no longer exists, waiting
  /// for the next one to speak it. See [_deliverOrphanedToolResult].
  final List<String> _orphanedToolResults = [];

  /// Cap on both of the above. A tool result always arrives (the executor
  /// turns a timeout into an error string), so these drain on their own; the
  /// cap is only so a pathological host cannot grow them without bound.
  static const int _toolBookkeepingCap = 8;

  /// The handle handed to the session currently being built. Lets a session
  /// that dies BEFORE ever connecting blame — and discard — the handle it was
  /// built with. Measured 24.08: a handle the server no longer knows does not
  /// degrade gracefully, it closes the socket with 1008 "BidiGenerateContent
  /// session not found" before setupComplete. Without this, one stale handle
  /// would keep failing every warm until the strike budget opened the circuit.
  String? _handleInFlight;

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

      // Mint LATE and open SOON. An ephemeral Gemini token carries a
      // `newSessionExpireTime`: past it the token can no longer OPEN a
      // session, and the server does not refuse the handshake — it accepts
      // the socket and closes it a beat later with `1011
      // new_session_expire_time deadline exceeded`. Measured 24.08 on mini
      // (`marathon/probes/lane5-concurrent-sockets.py`): a token used 62s
      // after minting still opened, one used 122s later did not.
      //
      // Everything between this line and `ensureWarm()` below therefore eats
      // into that window. Today it is safe — `fetchTools` is a constant list,
      // not a request (`voice_hub_production.dart:126`). The day the catalog
      // becomes a real fetch, move the mint below it (or bound the fetch well
      // under a minute), or a slow backend will turn into a voice mode that
      // connects and dies with no obvious cause.
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
      final resume = _usableResumptionHandle();
      _handleInFlight = resume;
      final newSession = createSession(HubSessionSpec(
        token: token,
        instructions: instructions,
        events: _sessionEvents(),
        tools: tools,
        resumptionHandle: resume,
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
      // Only the warm that still owns the slot may clear it: a
      // `teardownSession()` condemned this one and a newer warm may already
      // have taken its place.
      if (_warmGeneration == gen) _warming = null;
    }
  }

  /// The handle to build the next session with: the last one offered, unless
  /// it has aged past [resumptionHandleTtlMs] (in which case it is forgotten
  /// here rather than lingering).
  String? _usableResumptionHandle() {
    final handle = _resumptionHandle;
    final at = _resumptionHandleAt;
    if (handle == null || at == null) return null;
    if (now() - at > resumptionHandleTtlMs) {
      _resumptionHandle = null;
      _resumptionHandleAt = null;
      return null;
    }
    return handle;
  }

  /// Whether the next warm would continue the current conversation. Exposed
  /// for tests and for hosts that want to show "continuing" vs "new".
  bool get canResumeConversation => _usableResumptionHandle() != null;

  /// End the conversation, not just the socket: the next session starts
  /// blank. For the host to call when the USER closed the conversation
  /// (leaving voice mode), as opposed to the socket merely dropping —
  /// [teardownSession] deliberately keeps the handle.
  void forgetConversation() {
    _resumptionHandle = null;
    _resumptionHandleAt = null;
    _handleInFlight = null;
    // The conversation these belonged to is over — an answer to a question
    // nobody remembers asking would arrive as a non sequitur.
    _toolCallOrigin.clear();
    _orphanedToolResults.clear();
    // Including the answer the stall watchdog is holding: firing it after the
    // mode ended would speak into the next conversation instead.
    _cancelToolStallWatchdog();
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
    // Release the coalescing slot as well as bumping the generation. The warm
    // in flight is now condemned — it will throw `HubWarmAbortedError` at its
    // next generation check — and `ensureWarm()` hands the in-flight future
    // straight back to its next caller. Leaving it in place made the very
    // next `ensureWarm()` (the goAway rebuild is exactly this: teardown, then
    // warm) inherit that guaranteed failure instead of opening a fresh
    // socket. The condemned warm's `finally` no longer clears this slot, so
    // it cannot take the replacement down with it.
    _warming = null;
    _cancelReconnect();
    _reconnectStrikes = 0;
    _circuitOpenUntil = null;
    // An explicit drop also cancels any wake refresh deferred behind a
    // turn — re-warming a hub that was just told to close is wrong.
    _pendingRefreshReason = null;
    // The goAway belonged to the socket being dropped; a new one starts with
    // a clean lifetime.
    _clearGoAway();
    _cancelToolStallWatchdog();
    _replyGenerating = false;
    _userSpeaking = false;
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

  // MARK: goAway (provider-announced socket close)

  /// The provider says it is about to hang up. Unlike a drop, this arrives
  /// while the socket still works, so it can be spent on rebuilding at a
  /// quiet moment — with the resumption handle the conversation carries over
  /// and the user never hears the seam.
  ///
  /// Two things it deliberately does NOT do. It does not rebuild mid-reply:
  /// that would both cut the reply off and land on a withdrawn handle, i.e.
  /// lose the conversation to save the socket. And it does not rebuild under
  /// a host-owned long turn (free-form mode) — see [HubControllerEvents.onGoAway].
  void _handleGoAway(Duration? timeLeft) {
    final firstWarning = !_goAwayPending;
    _goAwayPending = true;
    _goAwayTimeLeft = timeLeft;
    // Arm the deadline off the FIRST warning only: the server sends the frame
    // twice, 0.4s apart (measured 24.08), and re-arming on the duplicate
    // would quietly push the deadline out by that much.
    if (firstWarning) _armGoAwayDeadline(timeLeft);
    _actOnGoAwayIfSafe();
  }

  /// Spends the warning at the last safe instant even if the conversation
  /// never goes quiet. [timeLeft] is what the server named; when it named
  /// nothing we assume the measured 50s (design doc §11) rather than wait
  /// forever, and keep [goAwayRebuildReserve] back to actually do the rebuild.
  void _armGoAwayDeadline(Duration? timeLeft) {
    _cancelGoAwayDeadline();
    final runway = timeLeft ?? goAwayAssumedRunway;
    final wait = runway - goAwayRebuildReserve;
    _goAwayDeadlineHandle = clock.setTimer(wait.isNegative ? Duration.zero : wait, () {
      _goAwayDeadlineHandle = null;
      _goAwayDeadlineExpired = true;
      // Past the point of politeness: cutting a sentence short beats the
      // provider hanging up on it, which costs the same words PLUS the
      // spoken apology the drop recovery makes.
      _userSpeaking = false;
      _actOnGoAwayIfSafe();
    });
  }

  void _cancelGoAwayDeadline() {
    final handle = _goAwayDeadlineHandle;
    if (handle != null) {
      clock.clearTimer(handle);
      _goAwayDeadlineHandle = null;
    }
  }

  /// Spends a pending `goAway` if this is a safe moment; otherwise leaves it
  /// armed for the next one (a handle offer or a finished turn).
  void _actOnGoAwayIfSafe() {
    if (!_goAwayPending) return;
    // The socket already went away, or was replaced. Nothing to pre-empt:
    // whatever comes next is a fresh socket with its own lifetime.
    if (session == null) {
      _clearGoAway();
      return;
    }
    // A rebuild is already under way, so this warning belongs to the socket
    // being replaced. Measured 24.08: the server sends goAway TWICE, 0.4s
    // apart — without this the duplicate would tear down the socket built in
    // response to the first one.
    if (_warming != null) {
      _clearGoAway();
      return;
    }
    if (_replyGenerating) return;
    // A tool call is out. Rebuilding here silently eats its answer: the
    // replacement socket accepts the `toolResponse` for a call it never made
    // WITHOUT an error and then says nothing at all (measured 24.08 — the
    // user hears "секунду, уточню" and then silence until the idle timeout).
    // The deadline armed in [_handleGoAway] still forces the rebuild if the
    // call never comes back, and [_deliverOrphanedToolResult] catches the
    // answer that lands after it.
    if (_toolCallInFlight && !_goAwayDeadlineExpired) return;
    // The user is mid-sentence. The rebuild disposes mic capture along with
    // the socket (`FreeFormVoiceMode.restart`), so acting here would swallow
    // the rest of what they are saying. Handles arrive about once a second
    // while audio streams (measured 24.08, design doc §11.3), so the retry
    // this defers to is moments away — and the deadline armed in
    // [_handleGoAway] covers the case where it never comes.
    if (_userSpeaking) return;
    final timeLeft = _goAwayTimeLeft;
    _clearGoAway();
    events.onGoAway?.call(timeLeft);
    // Mid-turn the rebuild waits for the turn to end, through the same
    // deferral a wake refresh uses. Two different hosts land here:
    //   * PTT — the turn is one press, so the rebuild happens moments later,
    //     on its own, and the warning is not wasted;
    //   * free-form — the turn is the WHOLE mode, so the deferral would wait
    //     for a stop that may never come. That host acts on the event above
    //     instead (restarting the mode, which cancels and re-begins the turn
    //     around a fresh socket); the deferral is then just a no-op left
    //     behind. Tearing the socket down from HERE would be the wrong fix:
    //     the replacement would never get its begin frame and would ignore
    //     everything the user said into it.
    requestSessionRefresh('goAway');
  }

  void _clearGoAway() {
    _goAwayPending = false;
    _goAwayTimeLeft = null;
    _goAwayDeadlineExpired = false;
    _cancelGoAwayDeadline();
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
  /// Self-host patch: speak-through seam for recovery messages — see
  /// [HubSession.sendUserText].
  void sendUserText(String text) => session?.sendUserText(text);

  void sendToolResult(String callId, String name, String output) {
    final origin = _toolCallOrigin.remove(callId);
    final s = session;
    // The socket that asked is still the one listening — the ordinary path.
    if (s != null && origin == sessionId) {
      s.sendToolResult(callId, name, output);
      // The call was the last thing holding a `goAway` back; this is a safe
      // moment now.
      _actOnGoAwayIfSafe();
      _armToolStallWatchdog(name, output);
      return;
    }
    // It is not. A `toolResponse` carrying a callId this socket never issued
    // is accepted and then ignored (measured 24.08), so the answer has to
    // reach the model as something it will actually read.
    _deliverOrphanedToolResult(name, output);
    _actOnGoAwayIfSafe();
  }

  /// Whether any tool call is still waiting on an answer FROM THIS SOCKET.
  /// Calls left over from an earlier socket do not hold a rebuild back —
  /// their answers take the orphan path either way.
  bool get _toolCallInFlight => _toolCallOrigin.values.any((origin) => origin == sessionId);

  void _noteToolCallOut(String callId) {
    // The model asked for something else — it is alive, and the answer it is
    // waiting on now is not the one the watchdog is holding.
    _cancelToolStallWatchdog();
    if (_toolCallOrigin.length >= _toolBookkeepingCap) {
      _toolCallOrigin.remove(_toolCallOrigin.keys.first);
    }
    _toolCallOrigin[callId] = sessionId;
  }

  /// Speaks a tool result whose socket is gone, as user text — the same seam
  /// the drop recovery uses ([sendUserText]). Phrased as an instruction
  /// because that is what the model reads before it opens its mouth; the
  /// error strings in `ask_claude_tool.dart` are written the same way and
  /// were measured 24.08 not to leak into speech.
  ///
  /// The "do NOT call it again" is not decoration — it is the whole
  /// difference between speaking and re-asking. The wording was picked by
  /// measurement (`marathon/probes/lane5-orphan-wording.py`, live Gemini
  /// 24.08): handed the answer WITHOUT that clause, the model said
  /// "секунду, уточню" and called `ask_claude` a second time — another 7-40s
  /// of waiting and another charge against the subscription for an answer
  /// already in hand. With it, both a Russian and an English phrasing had it
  /// relay the answer, no second call.
  ///
  /// With no socket at all (the gap between teardown and the replacement),
  /// the result waits for the next connect rather than being dropped.
  void _deliverOrphanedToolResult(String name, String output) {
    final failed = output.startsWith('Error:');
    final text = failed
        ? '(system) The $name lookup for the user\'s last question failed and no answer is '
            'coming. Do NOT call $name again for it. Tell the user briefly that the lookup '
            'failed, then answer from what you already know if you can. Details: $output'
        : '(system) $name has ALREADY answered the user\'s last question and the answer is '
            'below. Do NOT call $name again for it. Say this answer out loud to the user now, '
            'briefly, in the language they were speaking: $output';
    final s = session;
    if (s != null) {
      s.sendUserText(text);
      return;
    }
    if (_orphanedToolResults.length >= _toolBookkeepingCap) {
      _orphanedToolResults.removeAt(0);
    }
    _orphanedToolResults.add(text);
  }

  /// Arms the stall watchdog once the answer the model was waiting on is on
  /// the wire. Only when the batch is COMPLETE: Gemini sends several calls in
  /// one frame and says nothing until every one of them is answered (measured
  /// 24.08, `marathon/probes/lane5-parallel-toolcalls.py`), so arming on the
  /// first answer of a pair would fire the watchdog at a server that is
  /// behaving perfectly.
  void _armToolStallWatchdog(String name, String output) {
    if (_toolCallInFlight) return;
    _cancelToolStallWatchdog();
    _stalledToolName = name;
    _stalledToolOutput = output;
    _toolStallHandle = clock.setTimer(toolResultStallGrace, () {
      _toolStallHandle = null;
      final stalledName = _stalledToolName;
      final stalledOutput = _stalledToolOutput;
      _stalledToolName = null;
      _stalledToolOutput = null;
      if (stalledName == null || stalledOutput == null) return;
      // Another call went out in the meantime is already covered by the
      // disarm on [_noteToolCallOut]; getting here means the turn produced
      // nothing at all.
      _deliverOrphanedToolResult(stalledName, stalledOutput);
    });
  }

  /// Any sign the turn is alive disarms the watchdog: speech, a text chunk,
  /// another tool call, a finished turn, the user talking over it, or the
  /// socket going away. The cost of a false fire is a repeated answer in the
  /// user's ear, so the disarms are deliberately generous.
  void _cancelToolStallWatchdog() {
    final handle = _toolStallHandle;
    if (handle != null) {
      clock.clearTimer(handle);
      _toolStallHandle = null;
    }
    _stalledToolName = null;
    _stalledToolOutput = null;
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

  /// Ручной barge-in из UI — см. [HubSession.muteCurrentResponse].
  void muteCurrentResponse() => session?.muteCurrentResponse();

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
  /// of a warm hub; only the 120s idle timer or an explicit
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
    // A host-owned long turn just ended — that is the safe moment a deferred
    // goAway was waiting for.
    _actOnGoAwayIfSafe();
  }

  // MARK: Session event wiring (pass-through + connect/error enrichment)

  HubSessionEvents _sessionEvents() {
    return HubSessionEvents(
      onConnected: (sid) => _handleConnected(sid),
      onError: (message, retryable, closeCode) => _handleError(message, retryable, closeCode),
      onInputTranscript: (text, isFinal, identity) => events.onInputTranscript?.call(text, isFinal, identity),
      onAssistantText: (text, isFinal, identity) {
        _cancelToolStallWatchdog();
        events.onAssistantText?.call(text, isFinal, identity);
      },
      onUserSpeechState: (isSpeaking) {
        // Only recorded, never used as a trigger: a rebuild fired the instant
        // speech ends would land BEFORE the reply to it starts generating,
        // i.e. lose the very sentence it just waited out. The safe moments
        // stay what they were — a handle offer or a finished turn.
        _userSpeaking = isSpeaking;
        // The user talking over the gap owns the turn now; a nudge here would
        // land on top of them.
        if (isSpeaking) _cancelToolStallWatchdog();
        events.onUserSpeechState?.call(isSpeaking);
      },
      onSpeakingStart: () {
        _cancelToolStallWatchdog();
        events.onSpeakingStart?.call();
      },
      onSpeakingEnd: () => events.onSpeakingEnd?.call(),
      onInterrupted: () => events.onInterrupted?.call(),
      onToolRequest: (call, identity) {
        _noteToolCallOut(call.callId);
        events.onToolRequest?.call(call, identity);
      },
      onGoAway: (timeLeft) => _handleGoAway(timeLeft),
      onResumptionHandle: (handle) {
        _resumptionHandle = handle;
        _resumptionHandleAt = handle == null ? null : now();
        // A withdrawal means "a reply generation just started"; an offer
        // means it closed. A pending goAway waits for exactly that.
        _replyGenerating = handle == null;
        if (handle != null) _actOnGoAwayIfSafe();
      },
      onTurnDone: (identity) {
        // A completed turn proves the hub works — reset the strike budget
        // and close any open circuit.
        _reconnectStrikes = 0;
        _circuitOpenUntil = null;
        // Also the safe moment a deferred goAway is waiting for. Checked
        // here as well as on the handle offer, because a conversation the
        // server never handed a handle for (a first turn that produced none)
        // would otherwise never see one.
        _replyGenerating = false;
        _cancelToolStallWatchdog();
        _actOnGoAwayIfSafe();
        events.onTurnDone?.call(identity);
      },
    );
  }

  void _handleConnected(VoiceSessionId sid) {
    sessionId = sid;
    connectedAt = now();
    // The handle (if any) was accepted — it is no longer on trial.
    _handleInFlight = null;
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
    // A tool answer that came back while there was no socket to say it on
    // (the gap a rebuild opens). Speaking it late beats swallowing it.
    if (_orphanedToolResults.isNotEmpty) {
      final pending = List<String>.from(_orphanedToolResults);
      _orphanedToolResults.clear();
      for (final text in pending) {
        session?.sendUserText(text);
      }
    }
    events.onConnected?.call(sid);
  }

  void _handleError(String message, bool retryable, int? closeCode) {
    final connected = connectedAt;
    final aliveForMs = connected != null ? math.max(0, now() - connected) : 0;
    // Died before ever connecting while carrying a resumption handle: the
    // handle is the prime suspect (an expired one is rejected at handshake —
    // 1008 "session not found"), and keeping it would fail every retry the
    // same way. Drop it so the re-warm starts a blank conversation instead of
    // burning the strike budget on a corpse. A session that DID connect is
    // not evidence against its handle, so this only fires pre-connect.
    if (connected == null && _handleInFlight != null) {
      _resumptionHandle = null;
      _resumptionHandleAt = null;
    }
    _handleInFlight = null;
    // The warning has been overtaken by the drop it warned about.
    _clearGoAway();
    _cancelToolStallWatchdog();
    _replyGenerating = false;
    _userSpeaking = false;
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
    // Checked BOTH here and at fire time: the mode can be switched off
    // during the backoff window, and a warm socket for a mode nobody is
    // running is billed dead air (see [shouldStayWarm]).
    if (!(shouldStayWarm?.call() ?? true)) return;
    if (_reconnectPending) return;
    _reconnectPending = true;
    _reconnectHandle = clock.setTimer(reconnectBackoff, () {
      _reconnectHandle = null;
      _reconnectPending = false;
      // A failed re-warm (e.g. a still-dead mint) is expected on this
      // path — swallow the rejection so it never surfaces as an unhandled
      // error; the next press (or a socket close from a partial connect)
      // drives the next attempt.
      if (session == null && (shouldStayWarm?.call() ?? true)) _fireAndForgetWarm();
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
