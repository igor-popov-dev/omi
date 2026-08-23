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
//   * The silence-timeout auto-stop: `resolveIdleTimeout` (default 3 minutes,
//     `null` disables it) restarts every time `noteActivity()` is called and
//     calls `stop()` plus `onIdleTimeout` when it elapses untouched. It is a
//     RESOLVER, not a fixed `Duration`, because the setting behind it is
//     user-editable at runtime (`freeFormVoiceIdleTimeoutMinutes`, Developer →
//     Experimental) while this object is built once at app bootstrap
//     (`main.dart`) and never rebuilt — reading it per arm is what makes a
//     changed setting apply to the next session instead of the next launch.
//
// WHO calls `noteActivity()` — answered at the bottom of this file by
// `freeFormActivityEvents`, which wraps the `HubControllerEvents` the mode's
// host hands to `HubController` so every content event rearms the clock.
// Until that existed nothing called `noteActivity()` in production at all, so
// the mode auto-stopped a fixed interval after `start()` no matter how much
// the user was talking (see that function's own doc comment).
//
// Deliberately NOT owned here — all three now exist elsewhere, this file just
// isn't where they live:
//   * Android audio focus and the mic's foreground service — native, on the
//     other side of the platform channels this file never touches
//     (`AudioFocusCoordinator.kt`; `PhoneMicController` starts
//     `PhoneMicForegroundService` for every capture, so the continuous capture
//     `start()` opens is background-safe without anything extra here).
//   * The UI toggle (`free_form_voice_mode_button.dart`) and the `ask_claude`
//     tool (`ask_claude_tool.dart`, wired in `voice_hub_production.dart`).
import 'dart:async';

import 'free_form_voice_timeout.dart';
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
  /// auto-stops, re-read every time the timer is armed. Returning `null`
  /// disables the timer entirely (the mode then only stops via an explicit
  /// [stop] call).
  final Duration? Function() resolveIdleTimeout;

  /// Fired right before the idle-timeout auto-[stop] runs, so a host can
  /// e.g. surface a notification. NOT fired on an explicit [stop] call.
  final void Function()? onIdleTimeout;

  FreeFormVoiceMode({
    required this.hub,
    required this.startCapture,
    required this.mintTurnId,
    HubClock? clock,
    int Function()? now,
    Duration? Function()? resolveIdleTimeout,
    this.onIdleTimeout,
  })  : clock = clock ?? const DefaultHubClock(),
        now = now ?? _defaultNow,
        resolveIdleTimeout = resolveIdleTimeout ?? _defaultIdleTimeout;

  static Duration? _defaultIdleTimeout() => freeFormIdleTimeoutFromMinutes(kDefaultFreeFormVoiceIdleTimeoutMinutes);

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
  ///
  /// An explicit stop also ENDS THE CONVERSATION
  /// ([HubController.forgetConversation]), while the silence auto-stop does
  /// not. The hub can now resume a conversation across sockets (design doc
  /// §10), so the two stops stopped being the same thing: switching the mode
  /// off by hand reads as "we're done", whereas falling out on silence is the
  /// mode saving money on an abandoned session — coming back to that within
  /// the handle's lifetime should pick the conversation up, not open a blank
  /// one the user has to re-explain themselves to.
  void stop() => _stop(endsConversation: true);

  void _stop({required bool endsConversation}) {
    final turnId = _turnId;
    if (turnId == null) return;
    _cancelIdleTimer();
    _capture?.dispose();
    _capture = null;
    _turnId = null;
    hub.cancelTurn(turnId);
    if (endsConversation) hub.forgetConversation();
  }

  /// Self-host patch, not for upstream: hand the live session a line of text as
  /// if the user had said it, so the model speaks it back in its own voice.
  ///
  /// Used after a recovered drop: a reconnected session has no memory of the
  /// error, so without this the conversation just resumes and the user is left
  /// guessing whether anything was heard. No-op while not running — there is no
  /// socket to speak through.
  void announce(String text) {
    if (_turnId == null || text.isEmpty) return;
    hub.sendUserText(text);
  }

  /// Restarts the silence-timeout clock. No-op while not running. See file
  /// header for who is expected to call this once the mode host exists.
  void noteActivity() {
    if (_turnId == null) return;
    _armIdleTimer();
  }

  void _armIdleTimer() {
    _cancelIdleTimer();
    final timeout = resolveIdleTimeout();
    if (timeout == null) return;
    _idleHandle = clock.setTimer(timeout, () {
      _idleHandle = null;
      onIdleTimeout?.call();
      _stop(endsConversation: false);
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

/// Wraps [inner] so every hub CONTENT event also restarts the silence-timeout
/// clock through [note] (i.e. [FreeFormVoiceMode.noteActivity]).
///
/// This closes the "WHO calls noteActivity()" hole this file's header opened:
/// until it was wired, nothing in production called it at all, so the mode
/// auto-stopped exactly [FreeFormVoiceMode.resolveIdleTimeout] after `start()`
/// — mid-conversation, however much the user was actually talking. The timeout
/// exists to stop billing for an ABANDONED session (priority-22.08 step 6), not
/// to cap a live one.
///
/// "Content" is the set that can only happen because someone is talking:
/// transcripts either way, the reply's speaking start/end, a tool request, and
/// the turn's completion. Connect/error/cascade-handoff are deliberately NOT
/// activity — a socket that reconnects itself in an empty room must still time
/// out. Live wire evidence for the set (lane5 harness against real Gemini Live,
/// 23.08): server VAD reports `speechState: SPEECH` ~0.2s after speech onset
/// and streams `inputTranscription` for it, so a talking user rearms the clock
/// well inside any sane timeout; `turnComplete` trails the reply's last audio
/// chunk by ~2.5s, which is why the arm is not left to it alone.
///
/// Callbacks that are null on [inner] are still armed here — [note] must fire
/// whether or not the host happens to listen to that particular event.
HubControllerEvents freeFormActivityEvents(HubControllerEvents inner, void Function() note) {
  return HubControllerEvents(
    onConnected: inner.onConnected,
    onError: inner.onError,
    onCascadeHandoff: inner.onCascadeHandoff,
    onInputTranscript: (text, isFinal, identity) {
      note();
      inner.onInputTranscript?.call(text, isFinal, identity);
    },
    onAssistantText: (text, isFinal, identity) {
      note();
      inner.onAssistantText?.call(text, isFinal, identity);
    },
    // The earliest activity signal there is: the server VAD calls speech
    // 0.24s after the first syllable, whereas the transcript of the same
    // utterance only lands ~1.2s after the user stops (measured 23.08,
    // design doc §9). Someone mid-sentence when the idle timer is about to
    // fire is exactly who must not be cut off.
    onUserSpeechState: (isSpeaking) {
      note();
      inner.onUserSpeechState?.call(isSpeaking);
    },
    onSpeakingStart: () {
      note();
      inner.onSpeakingStart?.call();
    },
    onSpeakingEnd: () {
      note();
      inner.onSpeakingEnd?.call();
    },
    onToolRequest: (call, identity) {
      note();
      inner.onToolRequest?.call(call, identity);
    },
    onTurnDone: (identity) {
      note();
      inner.onTurnDone?.call(identity);
    },
  );
}
