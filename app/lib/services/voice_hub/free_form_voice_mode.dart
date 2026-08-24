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

  /// Fired when the mic is taken away (`true`) and given back (`false`) while
  /// the mode runs — see [micInterrupted] for why the mode cares.
  final void Function(bool interrupted)? onMicInterruption;

  FreeFormVoiceMode({
    required this.hub,
    required this.startCapture,
    required this.mintTurnId,
    HubClock? clock,
    int Function()? now,
    Duration? Function()? resolveIdleTimeout,
    this.onIdleTimeout,
    this.onMicInterruption,
  })  : clock = clock ?? const DefaultHubClock(),
        now = now ?? _defaultNow,
        resolveIdleTimeout = resolveIdleTimeout ?? _defaultIdleTimeout;

  static Duration? _defaultIdleTimeout() => freeFormIdleTimeoutFromMinutes(kDefaultFreeFormVoiceIdleTimeoutMinutes);

  static int _defaultNow() => DateTime.now().millisecondsSinceEpoch;

  VoiceTurnId? _turnId;
  HubPttCapture? _capture;
  Object? _idleHandle;
  int _inputFrames = 0;
  bool _micInterrupted = false;

  bool get isRunning => _turnId != null;

  /// Whether a single mic frame has reached the hub since the CURRENT socket
  /// generation started (reset by every [start], including the one inside
  /// [restart]).
  ///
  /// The question it answers is "would rebuilding this socket help?". A drop
  /// recovery is worth paying for when the mic is feeding a socket that died;
  /// it is pure loss when the mic itself is what stopped, because the fresh
  /// socket gets the same silence and dies the same way — and each rebuild
  /// speaks a recovery line out loud and rearms the silence auto-off, so the
  /// loop sustains itself instead of timing out. The everyday cause is a
  /// phone call (see `BaseHubSession.canIdleRelease`).
  bool get hasHeardInput => _inputFrames > 0;

  /// Whether the mic is currently taken away from us — a phone call, or
  /// another app preempting the input (`HubPttCaptureOptions.onInterruption`).
  ///
  /// [hasHeardInput] answers the same question by inference, one dead socket
  /// later; this is the native side saying so at the moment it happens. The
  /// difference matters because the inference costs a spoken recovery line
  /// over the top of the call it is describing: a session that HAD heard the
  /// mic before the call started looks recoverable when its socket dies
  /// mid-call, so it gets rebuilt and announced, and only the socket after
  /// that one is caught. With this flag the first drop is already known to be
  /// unrecoverable.
  bool get micInterrupted => _micInterrupted;

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
    _inputFrames = 0;
    _micInterrupted = false;
    try {
      _capture = await startCapture(HubPttCaptureOptions(
        onChunk: (pcm) {
          _inputFrames += 1;
          hub.appendAudio(turnId, pcm);
        },
        // Turn-scoped like `onChunk`: a late event from the capture this
        // start() replaced belongs to a mic session that is already stopped,
        // and acting on it would flip the state of the live one.
        onInterruption: (began) => _noteMicInterruption(turnId, began),
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

  /// Stops the mode WITHOUT ending the conversation — for every path where
  /// the mode gave up ON ITS OWN rather than the user switching it off.
  ///
  /// The rule this completes: only the button means "we're done". Everything
  /// else — a phone call taking the mic, drops the retry budget could not
  /// absorb, the silence auto-off — is the mode standing down around a user
  /// who never said anything of the sort, so the next [start] within the
  /// handle's 15-minute life ([HubController.resumptionHandleTtlMs]) should
  /// pick the conversation up instead of opening a blank one they have to
  /// re-explain themselves to.
  ///
  /// The silence auto-off already worked this way (see [stop]'s own comment
  /// for why); the call path did not, which is the odd one out — a call is
  /// the LEAST ambiguous case of "the user did not end this".
  void suspend() => _stop(endsConversation: false);

  void _stop({required bool endsConversation}) {
    final turnId = _turnId;
    if (turnId == null) return;
    _cancelIdleTimer();
    _capture?.dispose();
    _capture = null;
    _turnId = null;
    // Silently, without [onMicInterruption]: the flag describes a mic we are
    // holding, and we have just let go of it. A host told "the mic came back"
    // here would paint a listening indicator over a mode that stopped.
    _micInterrupted = false;
    hub.cancelTurn(turnId);
    if (endsConversation) hub.forgetConversation();
  }

  /// Rebuilds the socket WITHOUT ending the conversation: stop capture, drop
  /// the turn, start again. The hub keeps its resumption handle across the
  /// two, so the new socket picks the conversation up where the old one left
  /// it (design doc §10).
  ///
  /// Two callers, one shape. A recovered drop
  /// (`CaptureController.recoverFreeFormVoiceMode`) — which used to call the
  /// public [stop], i.e. told the hub the USER had ended the conversation, so
  /// the "continue where we left off" line it then spoke was a lie: the
  /// reconnected model had been handed a blank session. And a `goAway`
  /// warning ([HubControllerEvents.onGoAway]), where the point is to spend the
  /// notice on a rebuild BEFORE the socket dies, so nothing is lost at all.
  ///
  /// Ends with the mode RUNNING even if it was not running when called — the
  /// recovery path leans on that: by the time it runs, a failed rebuild may
  /// already have left the mode stopped, and a polite no-op there would leave
  /// the user looking at a live "voice mode on" button with no session behind
  /// it. Callers that only want to rebuild something already live check
  /// [isRunning] first (`CaptureController.rebuildFreeFormVoiceModeSocket`).
  Future<void> restart() async {
    _stop(endsConversation: false);
    // The socket itself, not just the turn: [_stop] only cancels the turn, so
    // without this the "rebuild" would restart mic capture around the very
    // socket it was called to replace — invisible from the outside and
    // useless. `teardownSession` deliberately KEEPS the resumption handle
    // (design doc §10), which is what makes the next socket a continuation.
    // On the recovery path the session is already gone and this is a no-op.
    hub.teardownSession();
    // Wait for the replacement socket BEFORE capture resumes. `start()` alone
    // does not: it fires the warm and returns, leaving the reducer's
    // warm-wait buffer to cover the latency. That is right for a cold start
    // and wrong here — the callers of this method speak into the session
    // immediately afterwards (the recovery line), and text handed to a hub
    // with no socket is dropped, not queued.
    await hub.ensureWarm();
    await start();
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

  void _noteMicInterruption(VoiceTurnId turnId, bool began) {
    if (_turnId != turnId) return;
    if (_micInterrupted == began) return;
    _micInterrupted = began;
    // Deliberately NOT `noteActivity()`: losing the mic is the opposite of
    // the user still being there, and rearming the silence auto-off on it
    // would keep an unusable session billing for another full timeout.
    onMicInterruption?.call(began);
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
