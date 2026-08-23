// Start/stop orchestration for the free-form (server-VAD) voice mode —
// priority-22.08 step 2 ("пусковой контракт... метод «start/stop voice
// mode»") and step 6 (configurable silence-timeout auto-off), design doc
// `~/omi-jarvis/docs/hub-port-design.md` §7/§8.
//
// No TS source to port: the desktop hub is PTT-only end to end (see
// `gemini_hub_session.dart`'s own header) — the whole notion of a
// mode that runs continuously across many replies, rather than one turn per
// button press, is new for this priority. This file is the disconnected
// capability layer for it, same pattern as `GeminiHubSession.freeFormMode`
// itself (tick 28): built and tested against `HubController`, not wired to
// any screen or button yet.
//
// What this owns:
//   * `start()` — mints ONE turn id, opens it on the hub
//     (`HubController.beginTurn`, matching how `GeminiHubSession` in
//     freeFormMode expects a single `beginTurn()` for the whole mode, not
//     per utterance — see that file's header), and starts a single
//     continuous mic capture whose chunks feed `HubController.appendAudio`
//     under that turn id for as long as the mode runs.
//   * `stop()` — tears the capture down and calls `HubController.cancelTurn`,
//     which `GeminiHubSession.freeFormMode` already re-interprets as "turn
//     the mode off" (tick 28: stops accepting input, no `activityEnd` frame
//     sent — there is no manual window to close).
//   * The silence-timeout auto-stop: `idleTimeout` (default 3 minutes, `null`
//     disables it) restarts every time `noteActivity()` is called and calls
//     `stop()` plus `onIdleTimeout` when it elapses untouched.
//
// Deliberately NOT owned here (open, tracked in the lane journal):
//   * WHO calls `noteActivity()`. The natural driver is every
//     `HubController` content event (input transcript, speaking start/end,
//     turn done) — but `HubController` takes a single `HubControllerEvents`
//     at construction, owned by the not-yet-written per-turn driver /
//     mode host (design doc §8 step 5). Wiring that fan-out is that host's
//     job, not this file's; `noteActivity()` is the seam it will call.
//   * Android audio focus (`AudioManager.requestAudioFocus`) — no Dart seam
//     exists for it yet; native foreground-service work, not this file.
//   * The UI toggle / notification (priority-22.08 step 5) and the
//     `ask_claude` tool (step 3, blocked on lane2's bridge contract) —
//     both out of scope here.
import 'dart:async';

import 'hub_controller.dart';
import 'hub_ptt_capture.dart';
import 'hub_session.dart' show HubClock, DefaultHubClock;
import 'voice_turn_machine.dart' show VoiceTurnId;

class FreeFormVoiceMode {
  final HubController hub;
  final HubStartCapture startCapture;
  final VoiceTurnId Function() mintTurnId;
  final HubClock clock;
  final int Function() now;

  /// How long the mode may run with no [noteActivity] call before it
  /// auto-stops. `null` disables the timer entirely (the mode then only
  /// stops via an explicit [stop] call).
  final Duration? idleTimeout;

  /// Fired right before the idle-timeout auto-[stop] runs, so a host can
  /// e.g. surface a notification. NOT fired on an explicit [stop] call.
  final void Function()? onIdleTimeout;

  FreeFormVoiceMode({
    required this.hub,
    required this.startCapture,
    required this.mintTurnId,
    HubClock? clock,
    int Function()? now,
    this.idleTimeout = const Duration(minutes: 3),
    this.onIdleTimeout,
  })  : clock = clock ?? const DefaultHubClock(),
        now = now ?? _defaultNow;

  static int _defaultNow() => DateTime.now().millisecondsSinceEpoch;

  VoiceTurnId? _turnId;
  HubPttCapture? _capture;
  Object? _idleHandle;

  bool get isRunning => _turnId != null;

  /// Idempotent: a [start] while already running is a no-op.
  Future<void> start() async {
    if (_turnId != null) return;
    final turnId = mintTurnId();
    _turnId = turnId;
    // Mirrors the PTT driver's own begin-of-press barge-in call (design doc
    // §6 step 1) — silences whatever a prior PTT reply had buffered before
    // this continuous turn claims the player.
    hub.clearPlayback();
    hub.beginTurn(turnId);
    try {
      _capture = await startCapture(HubPttCaptureOptions(
        onChunk: (pcm) => hub.appendAudio(turnId, pcm),
      ));
    } catch (_) {
      hub.cancelTurn(turnId);
      _turnId = null;
      rethrow;
    }
    _armIdleTimer();
  }

  /// Idempotent: a [stop] while not running is a no-op. Does NOT fire
  /// [onIdleTimeout] — that only fires when the timer itself elapses.
  void stop() {
    final turnId = _turnId;
    if (turnId == null) return;
    _cancelIdleTimer();
    _capture?.dispose();
    _capture = null;
    _turnId = null;
    hub.cancelTurn(turnId);
  }

  /// Restarts the silence-timeout clock. No-op while not running. See file
  /// header for who is expected to call this once the mode host exists.
  void noteActivity() {
    if (_turnId == null) return;
    _armIdleTimer();
  }

  void _armIdleTimer() {
    _cancelIdleTimer();
    final timeout = idleTimeout;
    if (timeout == null) return;
    _idleHandle = clock.setTimer(timeout, () {
      _idleHandle = null;
      onIdleTimeout?.call();
      stop();
    });
  }

  void _cancelIdleTimer() {
    final handle = _idleHandle;
    if (handle != null) {
      clock.clearTimer(handle);
      _idleHandle = null;
    }
  }
}
