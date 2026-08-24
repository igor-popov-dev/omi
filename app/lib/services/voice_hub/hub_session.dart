// Warm-hub provider session lane — a 1:1 port of the injectable-seam half of
// `desktop/windows/src/renderer/src/lib/voice/hub/hubSession.ts`
// (`BaseHubSession`). Owns ONE persistent WebSocket to a realtime provider
// and drives the per-turn frame choreography (warm/teardown, 180s idle
// release, 10s warm timeout, pre-open PCM buffering, spoken-audio playback)
// that is common to every provider. Provider wire frames themselves
// (`connectSpec`/`sessionSetupFrame`/`handleProviderMessage`/...) are NOT
// here — they belong to the concrete subclass (`gemini_hub_session.dart`,
// design doc §8 step 2, not yet written).
//
// Design doc: `~/omi-jarvis/docs/hub-port-design.md` §2, §4. Per §3, only the
// Gemini provider lane is ever built on top of this — the OpenAI variant
// from the TS source (and its cross-provider failover) is deliberately not
// modeled here at all, not even as dead branches.
//
// UNLIKE the sibling files in this package (`voice_turn_machine.dart`,
// `voice_output_coordinator.dart`, `ptt_gate.dart`), this file is NOT
// zero-I/O: per design doc §4's table, this is the layer that legitimately
// owns the socket. `web_socket_channel` (already a `pubspec.yaml`
// dependency, used the same way for the existing Gemini Live STT path in
// `app/lib/services/sockets/pure_streaming_stt.dart`) is the real transport;
// `HubSocket`/`HubClock`/`VoicePlayer` stay injectable so the turn
// choreography below is still unit-testable with fakes and no network.
//
// One deliberate scope cut vs. the TS source, explained in the design doc
// and NOT filled in with a placeholder here:
//   * No `sinkId` / output-device routing. That is a Web Audio concept
//     (`AudioContext.setSinkId`); the Android player is a native
//     `AudioTrack` behind a platform channel (design doc §7, step 3, not yet
//     written) with no equivalent seam yet.
//
// `tools` (TS `VoiceToolDeclaration[]`, PR-C) WAS cut here (empty catalog
// only) but is now wired — lane5.md §"ГЛАВНЫЙ ПРИОРИТЕТ 22.08" step 3
// (`ask_claude`, the first real tool). See `BaseHubSession.tools` below and
// `gemini_hub_session.dart`'s `sessionSetupFrame()`.
//
// Dart-vs-TS visibility note: TS's `protected` members (`socket`, `isOpen`,
// `activeIdentity`, `pendingCommit`, `instructions`, `token`, `send`,
// `flushPendingAudio`, `playAudio`, `clearPlayback`, `flushPlayback`,
// `emit*`, `markReady`, and the abstract provider hooks) are read or called
// directly by `GeminiHubSession` in the TS source. Dart has no cross-file
// `protected` — privacy is per-library (per-file), not per-class-hierarchy —
// so every member a future same-package subclass needs stays a plain public
// (non-underscore) member here, documented as "subclass-facing" rather than
// enforced by the compiler. Members TS marks `private` (never touched by
// `GeminiHubSession`) stay underscore-private as usual.
//
// Port notes (ordering/idempotency traps carried over verbatim from the TS
// source's own comments):
//   * `ensureWarm()` is idempotent: already-open → resolved immediately;
//     already-warming → the same in-flight future is returned.
//   * `markReady()` order is load-bearing: `onProviderReady()` (subclass
//     flush of anything deferred until the socket was ready) THEN
//     `flushPendingAudio()` THEN a deferred `commitTurnNow()` THEN resolve
//     the warm future THEN `onConnected` THEN `touchIdle()`.
//   * `teardown()` order is load-bearing: cancel timers, detach+null the
//     socket reference BEFORE calling `resetProviderState()` (a subclass
//     must never see a live `socket` field while resetting), close the
//     detached socket, close the player, and only THEN fail a still-pending
//     warm future — a `teardown()` mid-connect must not hang its caller.
//   * `send()` drops a control frame that races a socket still CONNECTING
//     (readyState != OPEN) instead of throwing — a slow-warm barge-in
//     cancel can fire before the socket has finished opening; dropping is
//     safe because nothing was ever sent on that socket to begin with.
//   * A fake `HubSocket` that leaves `readyState` `null` (most test doubles)
//     is treated as always-sendable, matching the TS source's `undefined`
//     case.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:omi/utils/logger.dart';
import 'package:uuid/uuid.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'voice_turn_machine.dart' show VoiceResponseId, VoiceSessionId, VoiceTurnId;

// ---------------------------------------------------------------------------
// MARK: - Provider identity (TS `HubProvider` / `HubBargeInStrategy`)
// ---------------------------------------------------------------------------

/// TS union was `'openai' | 'gemini'`; per design doc §3 the OpenAI lane is
/// not ported at all, so this is a single-value enum today. Kept as an enum
/// (not a bare `const`) because `provider` is still a meaningful reported
/// capability on [HubSession], not a vestige of multi-provider support.
enum HubProvider { gemini }

/// Mirrors Swift `bargeInStrategy`: OpenAI can cancel an in-flight reply
/// in-session; Gemini cannot cleanly cancel a streaming reply, so its
/// barge-in is a fresh session (the controller's job, design doc §6). Only
/// `freshSession` is ever produced by a lane in this port.
enum HubBargeInStrategy { inSessionCancel, freshSession }

// ---------------------------------------------------------------------------
// MARK: - Event identity (TS `HubEventIdentity`)
// ---------------------------------------------------------------------------

/// Identity a hub event belongs to, threaded through so a future host can
/// map an incoming provider callback back to the reducer's turn/response
/// fencing (`voice_turn_machine.dart`'s `VoiceTurnId`/`VoiceResponseId`).
class HubEventIdentity {
  final VoiceTurnId turnId;
  final VoiceResponseId responseId;

  const HubEventIdentity({required this.turnId, required this.responseId});

  @override
  bool operator ==(Object other) =>
      other is HubEventIdentity && other.turnId == turnId && other.responseId == responseId;
  @override
  int get hashCode => Object.hash(turnId, responseId);
  @override
  String toString() => 'HubEventIdentity(turnId: $turnId, responseId: $responseId)';
}

/// A provider-neutral tool declaration the session should advertise (TS
/// `VoiceToolDeclaration`, `shared/types.ts`). `parameters` is plain JSON
/// Schema — a Gemini-specific lane projects it onto Gemini's OpenAPI-3.0
/// `Schema` subset itself (`gemini_tool_schema.dart`), so this type stays
/// provider-agnostic.
class VoiceToolDeclaration {
  final String name;
  final String description;
  final Map<String, dynamic> parameters;

  const VoiceToolDeclaration({required this.name, required this.description, required this.parameters});
}

/// A provider tool-call request surfaced to the host. Tool EXECUTION is a
/// host concern; the lane only relays the request.
class HubToolCallRequest {
  final String name;
  final String callId;
  final String argumentsJson;

  const HubToolCallRequest({required this.name, required this.callId, required this.argumentsJson});

  @override
  bool operator ==(Object other) =>
      other is HubToolCallRequest &&
      other.name == name &&
      other.callId == callId &&
      other.argumentsJson == argumentsJson;
  @override
  int get hashCode => Object.hash(name, callId, argumentsJson);
  @override
  String toString() => 'HubToolCallRequest(name: $name, callId: $callId, argumentsJson: $argumentsJson)';
}

// ---------------------------------------------------------------------------
// MARK: - Events (TS `HubSessionEvents`)
// ---------------------------------------------------------------------------

/// Everything a hub session emits. Audio itself is played internally through
/// the injected [VoicePlayer] (see [BaseHubSession.playAudio]); the audible
/// output signal surfaces as [onSpeakingStart]/[onSpeakingEnd], which is
/// what the echo gate and the voice-output lease need.
class HubSessionEvents {
  /// Socket handshake complete, config applied, audio can flow.
  final void Function(VoiceSessionId sessionId)? onConnected;

  /// User speech STT from the provider (input transcription).
  final void Function(String text, bool isFinal, HubEventIdentity? identity)? onInputTranscript;

  /// Assistant reply text (for the on-screen bubble / logging).
  final void Function(String text, bool isFinal, HubEventIdentity? identity)? onAssistantText;

  /// Spoken audio began audibly playing (echo gate: activate).
  final void Function()? onSpeakingStart;

  /// Spoken audio drained / was interrupted (echo gate: start release).
  final void Function()? onSpeakingEnd;

  /// Self-host patch, not for upstream: the user talked over the reply.
  ///
  /// Everything generated after this point was never heard, and even the
  /// current sentence was cut mid-air. A listener that records history must
  /// treat the accumulated reply as *partially spoken* — otherwise the model's
  /// own transcript claims it said things the user never heard, and the next
  /// turn is built on that fiction.
  final void Function()? onInterrupted;

  /// The model requested a tool call.
  final void Function(HubToolCallRequest call, HubEventIdentity? identity)? onToolRequest;

  /// The model finished this turn (spoken reply complete).
  final void Function(HubEventIdentity? identity)? onTurnDone;

  /// The session cannot continue (handshake failed or a fatal mid-session
  /// drop). [closeCode] is the WS close code when the drop came from a
  /// socket close; null for non-close faults (a provider error frame, an
  /// audio-init failure).
  final void Function(String message, bool retryable, int? closeCode)? onError;

  const HubSessionEvents({
    this.onConnected,
    this.onInputTranscript,
    this.onAssistantText,
    this.onSpeakingStart,
    this.onSpeakingEnd,
    this.onInterrupted,
    this.onToolRequest,
    this.onTurnDone,
    this.onError,
  });
}

// ---------------------------------------------------------------------------
// MARK: - Injectable seams (player / socket / clock)
// ---------------------------------------------------------------------------

/// Spoken-audio player contract (TS `VoicePlayer`, `pcmPlayer.ts` — not read
/// in this port). The real implementation is the Kotlin `AudioTrack` bridge
/// from design doc §7/§4 (step 3, not yet written); this seam lets the turn
/// choreography below be tested without it.
abstract class VoicePlayer {
  /// Enqueue raw 16-bit little-endian PCM bytes (the Gemini wire format).
  void enqueuePcm16(Uint8List bytes);

  /// End of turn: play any queued sub-cushion tail instead of withholding it.
  void flush();

  /// Barge-in: drop everything buffered, immediately.
  void clear();

  /// Idempotent teardown.
  void close();
}

class VoicePlayerStartSpec {
  final void Function() onStarted;
  final void Function() onDrained;

  /// Fires once if the player permanently lost Android audio focus (see
  /// `NativeVoicePlayer.onAudioFocusLost`'s doc) — optional so existing/fake
  /// players that don't model focus at all (most tests) need not supply it.
  final void Function()? onAudioFocusLost;

  const VoicePlayerStartSpec({required this.onStarted, required this.onDrained, this.onAudioFocusLost});
}

typedef VoicePlayerFactory = Future<VoicePlayer> Function(VoicePlayerStartSpec spec);

/// Minimal socket surface the sessions use — a real WebSocket-backed
/// implementation ([defaultHubSocketFactory]) in production, a
/// frame-recording fake in tests. Frames are always JSON text (spoken audio
/// rides as base64 inside JSON).
abstract class HubSocket {
  void send(String data);
  void close();

  /// 0 CONNECTING · 1 OPEN · 2 CLOSING · 3 CLOSED, mirroring
  /// `WebSocket.readyState`. Null means "unknown" — a minimal test fake may
  /// omit it, and an unknown readyState is treated as always-sendable.
  int? get readyState;
}

/// `WebSocket.OPEN` as a bare literal, identical to the platform constant.
const int webSocketOpenReadyState = 1;

class HubSocketOpenSpec {
  final String url;
  final List<String>? protocols;
  final void Function() onOpen;
  final void Function(String data) onMessage;
  final void Function(int code, String reason) onClose;
  final void Function(String message) onError;

  const HubSocketOpenSpec({
    required this.url,
    this.protocols,
    required this.onOpen,
    required this.onMessage,
    required this.onClose,
    required this.onError,
  });
}

typedef HubSocketFactory = HubSocket Function(HubSocketOpenSpec spec);

/// Injectable timer so the 180s idle release and 10s warm timeout are
/// testable with fake clocks, without depending on Flutter's `fake_async`
/// harness at the type level.
abstract class HubClock {
  Object setTimer(Duration duration, void Function() fire);
  void clearTimer(Object handle);
}

class DefaultHubClock implements HubClock {
  const DefaultHubClock();

  @override
  Object setTimer(Duration duration, void Function() fire) => Timer(duration, fire);

  @override
  void clearTimer(Object handle) => (handle as Timer).cancel();
}

/// D4: release a warm socket after this much idle time.
const Duration hubIdleReleaseDuration = Duration(milliseconds: 180000);

/// Bound on a single warm attempt (see file header `markReady` port note for
/// why this exists independently of the idle release).
const Duration hubWarmTimeoutDuration = Duration(milliseconds: 10000);

// MARK: Default socket factory (real WebSocket, via web_socket_channel)

/// Wraps an [IOWebSocketChannel] to satisfy [HubSocket], deriving
/// `readyState` from the connect lifecycle ourselves — `web_socket_channel`'s
/// `dart:io` adapter does not expose a raw `readyState` int the way a
/// browser `WebSocket` (and the TS source's `defaultSocketFactory`) does.
class _IoHubSocket implements HubSocket {
  final WebSocketChannel _channel;
  int _readyState = 0;

  _IoHubSocket(this._channel);

  void markOpen() => _readyState = 1;
  void markClosed() => _readyState = 3;

  @override
  void send(String data) => _channel.sink.add(data);

  @override
  void close() {
    _readyState = 2;
    unawaited(_channel.sink.close());
  }

  @override
  int? get readyState => _readyState;
}

/// Decodes one incoming WebSocket frame to text. Gemini Live delivers
/// control frames (incl. the `setupComplete` readiness signal) as BINARY;
/// a plain string frame (Gemini `serverContent`, or any other provider)
/// passes through unchanged. Returns null for a frame shape neither
/// covers — dropped, same as the TS source's binary-frame handling. Pure
/// and side-effect-free on purpose: this is the one piece of
/// [defaultHubSocketFactory] that can be unit-tested without a real socket.
String? decodeIncomingHubFrame(Object? data) {
  if (data is String) return data;
  if (data is List<int>) return utf8.decode(data);
  return null;
}

/// Real-socket factory (production default). Decode-to-text precedent for
/// this same endpoint already proven live in
/// `app/lib/services/sockets/pure_streaming_stt.dart`.
HubSocket defaultHubSocketFactory(HubSocketOpenSpec spec) {
  final channel = IOWebSocketChannel.connect(Uri.parse(spec.url), protocols: spec.protocols);
  final socket = _IoHubSocket(channel);
  channel.ready.then(
    (_) {
      socket.markOpen();
      spec.onOpen();
    },
    onError: (Object e, StackTrace st) {
      socket.markClosed();
      spec.onError(e.toString());
    },
  );
  channel.stream.listen(
    (data) {
      final text = decodeIncomingHubFrame(data);
      if (text != null) spec.onMessage(text);
    },
    onError: (Object e, StackTrace st) {
      socket.markClosed();
      spec.onError(e.toString());
    },
    onDone: () {
      socket.markClosed();
      spec.onClose(channel.closeCode ?? 1005, channel.closeReason ?? '');
    },
    cancelOnError: true,
  );
  return socket;
}

// ---------------------------------------------------------------------------
// MARK: - Public contract (TS `type HubSession`)
// ---------------------------------------------------------------------------

class HubConnectSpec {
  final String url;
  final List<String>? protocols;
  const HubConnectSpec({required this.url, this.protocols});
}

/// `beginTurn` options (TS's inline `{turnID?; responseID?; interrupting?}`).
class HubBeginTurnOptions {
  final VoiceTurnId? turnId;
  final VoiceResponseId? responseId;
  final bool interrupting;

  const HubBeginTurnOptions({this.turnId, this.responseId, this.interrupting = false});
}

/// The four per-turn primitives (plus warm/teardown) every provider lane
/// implements.
abstract class HubSession {
  HubProvider get provider;

  /// Mic PCM16 input rate the caller must resample to (Gemini wants 16k).
  int get requiredInputSampleRate;
  HubBargeInStrategy get bargeInStrategy;

  /// Open (or reuse) the warm socket and apply session config. Idempotent.
  Future<void> ensureWarm();
  bool isWarm();

  /// Start a PTT turn. Gemini opens a fresh speech-activity window every
  /// turn (design doc §6 — barge-in is a fresh session, not this call).
  void beginTurn([HubBeginTurnOptions opts = const HubBeginTurnOptions()]);

  /// Feed one mic PCM16 frame at [requiredInputSampleRate] (buffered
  /// pre-open).
  void appendAudio(Uint8List pcm);

  /// End the held turn and ask the model to respond.
  void commitTurn();

  /// Abandon the current turn without a reply, keeping the warm socket
  /// (silent tap / cancel / barge-in).
  void cancelTurn();

  /// Return a tool result to the model so it can continue speaking.
  void sendToolResult(String callId, String name, String output);

  /// Self-host patch, not for upstream: hand the model a line of text as if the
  /// user had said it. Used to make a recovered session explain itself out loud
  /// — after a reconnect the model has no memory of the drop, so without this
  /// the user hears silence resume mid-conversation with no explanation.
  void sendUserText(String text);

  /// Barge-in seam (design doc §6, added for `voice_turn_driver.dart`):
  /// immediately drop everything the spoken-audio player has already
  /// buffered. Gemini's own barge-in strategy is a fresh session, not an
  /// in-session cancel (`bargeInStrategy` above), so silencing already-
  /// enqueued PCM on a new press is the turn driver's job, not something the
  /// wire protocol does. A concrete session already has this exact action
  /// for the server-reported `interrupted` case
  /// (`GeminiHubSession.handleProviderMessage` -> `clearPlayback()`); this
  /// just exposes it on the public contract so `HubController` (and the
  /// driver above it) can trigger it directly, without an upcast to
  /// `BaseHubSession`.
  void clearPlayback();

  /// Close the socket. The object stays reusable — `ensureWarm()`
  /// re-establishes it.
  void teardown();
}

// ---------------------------------------------------------------------------
// MARK: - Shared base (TS `BaseHubSession`)
// ---------------------------------------------------------------------------

/// Everything every provider lane shares: connect/teardown, the 180s idle
/// timer, the pre-open PCM buffer, spoken-audio playback through the
/// injected [VoicePlayer], and the emit helpers. Provider subclasses
/// (`GeminiHubSession`, design doc §8 step 2) supply the wire frames and
/// message parsing via the abstract hooks at the bottom of this class.
abstract class BaseHubSession implements HubSession {
  final String token;
  final String instructions;
  final HubSessionEvents events;
  final HubSocketFactory socketFactory;
  final HubClock clock;
  final VoiceSessionId Function() mintSessionId;
  final Duration idleRelease;
  final Duration warmTimeout;
  final VoicePlayerFactory createPlayer;

  /// Subclass-facing (see file header): the provider-neutral tool catalog
  /// this session advertises (TS `BaseHubSession.tools`, PR-C). Host-derived
  /// and fetched fresh by `HubController` at each warm — empty when no tool
  /// is wired, same as before this seam existed.
  final List<VoiceToolDeclaration> tools;

  /// Subclass-facing (see file header): the live socket, or null when torn
  /// down / not yet connected.
  HubSocket? socket;

  /// Subclass-facing: provider "ready" (session.created / setupComplete)
  /// flipped this true; see [markReady].
  bool isOpen = false;

  VoiceSessionId? sessionId;

  /// Subclass-facing: identity of the turn currently held, set by
  /// [beginTurn].
  HubEventIdentity? activeIdentity;

  /// Subclass-facing: a `commitTurn()` arrived before the provider could
  /// accept input; flushed in [markReady].
  bool pendingCommit = false;

  /// Mic PCM (base64) captured before the socket/activity window is ready.
  final List<String> _pendingAudio = [];

  VoicePlayer? _player;
  Object? _idleHandle;
  Object? _warmTimeoutHandle;
  Completer<void>? _warmCompleter;
  bool _errored = false;

  BaseHubSession({
    required this.token,
    required this.instructions,
    this.events = const HubSessionEvents(),
    HubSocketFactory? socketFactory,
    required VoicePlayerFactory playerFactory,
    HubClock? clock,
    VoiceSessionId Function()? mintSessionId,
    this.idleRelease = hubIdleReleaseDuration,
    this.warmTimeout = hubWarmTimeoutDuration,
    this.tools = const [],
  })  : socketFactory = socketFactory ?? defaultHubSocketFactory,
        createPlayer = playerFactory,
        clock = clock ?? const DefaultHubClock(),
        mintSessionId = mintSessionId ?? (() => const Uuid().v4());

  // MARK: Warm / teardown (shared)

  @override
  Future<void> ensureWarm() {
    touchIdle();
    if (isOpen) return Future.value();
    final inFlight = _warmCompleter;
    if (inFlight != null) return inFlight.future;
    _errored = false;
    sessionId = mintSessionId();
    final completer = Completer<void>();
    _warmCompleter = completer;
    _armWarmTimeout();
    unawaited(_openConnection());
    return completer.future;
  }

  /// Bound the warm attempt: if the provider never signals readiness (the
  /// socket opens but no ready frame arrives, or it never opens at all),
  /// fail fast instead of hanging until the 180s idle teardown.
  void _armWarmTimeout() {
    _clearWarmTimeout();
    _warmTimeoutHandle = clock.setTimer(warmTimeout, () {
      _warmTimeoutHandle = null;
      if (!isOpen) _handleError('hub warm timeout', true);
    });
  }

  void _clearWarmTimeout() {
    final handle = _warmTimeoutHandle;
    if (handle != null) {
      clock.clearTimer(handle);
      _warmTimeoutHandle = null;
    }
  }

  @override
  bool isWarm() => isOpen;

  Future<void> _openConnection() async {
    VoicePlayer player;
    try {
      player = await createPlayer(VoicePlayerStartSpec(
        onStarted: () => events.onSpeakingStart?.call(),
        onDrained: () => events.onSpeakingEnd?.call(),
        // Not retryable: another app (or an incoming call) holding audio focus
        // would very likely re-trigger the same loss on an immediate retry —
        // end the session cleanly instead, same as any other fatal drop.
        onAudioFocusLost: () => _handleError('audio focus lost', false),
      ));
    } catch (_) {
      _handleError('audio player init failed', true);
      return;
    }
    // A teardown() during the await voids this connection attempt.
    if (_warmCompleter == null) {
      player.close();
      return;
    }
    _player = player;
    final spec = connectSpec();
    socket = socketFactory(HubSocketOpenSpec(
      url: spec.url,
      protocols: spec.protocols,
      onOpen: _onSocketOpen,
      onMessage: _onSocketMessage,
      onClose: (code, reason) => _handleError(
        'websocket closed ($code)${reason.isNotEmpty ? ' $reason' : ''}',
        true,
        code,
      ),
      onError: (message) => _handleError(message, true),
    ));
  }

  void _onSocketOpen() => send(sessionSetupFrame());

  void _onSocketMessage(String data) {
    touchIdle(); // any socket traffic (incl. a long reply) keeps the socket warm
    final Object? decoded;
    try {
      decoded = jsonDecode(data);
    } catch (_) {
      return;
    }
    if (decoded is! Map<String, dynamic>) return;
    handleProviderMessage(decoded);
  }

  /// Called by the subclass when the provider signals the session is ready.
  /// Order is load-bearing — see file header port notes.
  void markReady() {
    if (isOpen) return;
    isOpen = true;
    _clearWarmTimeout(); // handshake completed within the bound
    onProviderReady(); // subclass: e.g. Gemini opens a deferred activity window
    flushPendingAudio();
    if (pendingCommit && canAcceptInput()) {
      pendingCommit = false;
      commitTurnNow();
    }
    _warmCompleter?.complete();
    _warmCompleter = null;
    final sid = sessionId;
    if (sid != null) events.onConnected?.call(sid);
    touchIdle();
  }

  @override
  void teardown() {
    _clearWarmTimeout();
    final idle = _idleHandle;
    if (idle != null) {
      clock.clearTimer(idle);
      _idleHandle = null;
    }
    final s = socket;
    socket = null;
    isOpen = false;
    _pendingAudio.clear();
    pendingCommit = false;
    resetProviderState();
    try {
      s?.close();
    } catch (_) {
      /* already gone */
    }
    _player?.close();
    _player = null;
    // A warm() in flight torn down before it opened must not hang its caller.
    final completer = _warmCompleter;
    _warmCompleter = null;
    if (completer != null && !completer.isCompleted) {
      completer.completeError(StateError('hub session torn down before ready'));
    }
  }

  // MARK: Idle release (D4)

  void touchIdle() {
    final handle = _idleHandle;
    if (handle != null) clock.clearTimer(handle);
    _idleHandle = clock.setTimer(idleRelease, () {
      _idleHandle = null;
      teardown(); // silent release — ensureWarm() re-establishes on the next press
    });
  }

  // MARK: Per-turn primitives (delegate to subclass frames)

  @override
  void beginTurn([HubBeginTurnOptions opts = const HubBeginTurnOptions()]) {
    touchIdle();
    final turnId = opts.turnId;
    final responseId = opts.responseId;
    activeIdentity =
        (turnId != null && responseId != null) ? HubEventIdentity(turnId: turnId, responseId: responseId) : null;
    onBeginTurn(opts.interrupting);
  }

  @override
  void appendAudio(Uint8List pcm) {
    touchIdle();
    final b64 = base64Encode(pcm);
    if (!canAcceptInput()) {
      _pendingAudio.add(b64);
      return;
    }
    appendAudioFrame(b64);
  }

  @override
  void commitTurn() {
    touchIdle();
    if (!canAcceptInput()) {
      pendingCommit = true;
      return;
    }
    commitTurnNow();
  }

  @override
  void cancelTurn() {
    touchIdle();
    _pendingAudio.clear();
    pendingCommit = false;
    activeIdentity = null;
    onCancelTurn();
  }

  @override
  void sendToolResult(String callId, String name, String output) {
    touchIdle();
    onSendToolResult(callId, name, output);
  }

  @override
  void sendUserText(String text) {
    touchIdle();
    onSendUserText(text);
  }

  // MARK: Emit helpers (subclass-facing — see file header; never log PII)

  /// Drops a control frame that races a socket still CONNECTING instead of
  /// throwing — see file header port notes.
  void send(Map<String, dynamic> json) {
    final s = socket;
    if (s == null) return;
    final readyState = s.readyState;
    if (readyState != null && readyState != webSocketOpenReadyState) return;
    s.send(jsonEncode(json));
  }

  void flushPendingAudio() {
    if (!canAcceptInput()) return;
    final buffered = List<String>.of(_pendingAudio);
    _pendingAudio.clear();
    for (final b64 in buffered) {
      appendAudioFrame(b64);
    }
  }

  /// Decode base64 spoken PCM and play through the injected [VoicePlayer].
  void playAudio(String b64) {
    if (b64.isEmpty) return;
    final player = _player;
    // Диагностика «слышу текст, не слышу голос» (24.08): каждый потерянный
    // чанк обязан оставлять след. Первый чанк и каждый 25-й — тоже, чтобы по
    // логу было видно, что тракт жив.
    if (player == null) {
      Logger.debug('[hub-audio] аудио-чанк ПОТЕРЯН: плеер отсутствует (_player == null)');
      return;
    }
    _audioChunksPlayed += 1;
    if (_audioChunksPlayed == 1 || _audioChunksPlayed % 25 == 0) {
      Logger.debug('[hub-audio] чанк №$_audioChunksPlayed -> нативный плеер');
    }
    player.enqueuePcm16(base64Decode(b64));
  }

  int _audioChunksPlayed = 0;

  /// Barge-in: drop everything buffered in the player immediately.
  @override
  void clearPlayback() => _player?.clear();

  /// Turn boundary: play any queued sub-cushion tail instead of withholding it.
  void flushPlayback() => _player?.flush();

  void emitInputTranscript(String text, bool isFinal, [HubEventIdentity? identity]) {
    events.onInputTranscript?.call(text, isFinal, identity ?? activeIdentity);
  }

  void emitAssistantText(String text, bool isFinal, [HubEventIdentity? identity]) {
    if (text.isEmpty && !isFinal) return;
    events.onAssistantText?.call(text, isFinal, identity ?? activeIdentity);
  }

  void emitToolRequest(HubToolCallRequest call, [HubEventIdentity? identity]) {
    events.onToolRequest?.call(call, identity ?? activeIdentity);
  }

  void emitTurnDone([HubEventIdentity? identity]) {
    events.onTurnDone?.call(identity ?? activeIdentity);
  }

  void _handleError(String message, bool retryable, [int? closeCode]) {
    if (_errored) return;
    _errored = true;
    final completer = _warmCompleter;
    _warmCompleter = null;
    events.onError?.call(message, retryable, closeCode);
    teardown(); // closes the socket/player; the `_errored` guard prevents re-entrancy
    if (completer != null && !completer.isCompleted) {
      completer.completeError(StateError(message));
    }
  }

  // MARK: Provider hooks (implemented by e.g. `GeminiHubSession`)

  @override
  HubProvider get provider;
  @override
  int get requiredInputSampleRate;
  @override
  HubBargeInStrategy get bargeInStrategy;

  /// Connection URL + WS subprotocols.
  HubConnectSpec connectSpec();

  /// The one-time session-config frame sent right after socket open.
  Map<String, dynamic> sessionSetupFrame();

  /// Parse one decoded provider message. Call `markReady`/emit helpers.
  void handleProviderMessage(Map<String, dynamic> obj);

  /// Whether the provider can accept mic input right now (Gemini needs its
  /// activity window open).
  bool canAcceptInput();

  /// Send one mic PCM frame (already base64). Precondition: [canAcceptInput].
  void appendAudioFrame(String b64);

  /// Provider `beginTurn` frames (e.g. Gemini activityStart).
  void onBeginTurn(bool interrupting);

  /// Provider `commit` frames. Precondition: [canAcceptInput].
  void commitTurnNow();

  /// Provider `cancel`/abandon frames (keep the socket).
  void onCancelTurn();

  /// Provider tool-result frames.
  void onSendToolResult(String callId, String name, String output);

  /// Provider frame carrying a line of user text (see [sendUserText]).
  void onSendUserText(String text);

  /// Provider-specific flush at `markReady` (e.g. Gemini deferred
  /// activityStart).
  void onProviderReady();

  /// Clear all per-connection provider flags on teardown.
  void resetProviderState();
}
