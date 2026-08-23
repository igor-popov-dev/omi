// Maps the `HubControllerEvents` a running `FreeFormVoiceMode`'s
// `HubController` emits onto the same `VoiceTurnUiProjection` the PTT
// `HubVoiceStatusIndicator` already renders (see that widget). The two modes
// are mutually exclusive by design (`voice_hub_production.dart`'s
// `createProductionFreeFormVoiceMode` header: "one voice-input surface
// active at a time"), so feeding both into one projection sink is safe and
// avoids a second status-indicator widget.
//
// Deliberately simpler than `VoiceHubTurnDriver`'s own `_hubEvents()`:
// free-form mode has no PTT reducer (no turn ids/locks/follow-ups/deadlines
// to track), so this is a direct, stateless event->projection mapping, not a
// state-machine port.
import 'hub_controller.dart';
import 'voice_turn_coordinator.dart' show VoiceTurnPresenter;
import 'voice_turn_machine.dart' show VoiceTurnUiProjection;

const VoiceTurnUiProjection _listeningProjection = VoiceTurnUiProjection(
  isListening: true,
  isLocked: false,
  isFollowUp: false,
  transcript: '',
  hint: '',
  isThinking: false,
  isResponseWaiting: false,
  isResponseActive: false,
);

// The user is talking right now (server VAD said SPEECH). Same "listening"
// family as above — the mode has not changed state, the phone has simply
// started picking speech up — but the indicator can now say so out loud,
// which is the difference between "is this thing even on?" and knowing it
// heard you.
const VoiceTurnUiProjection _hearingProjection = VoiceTurnUiProjection(
  isListening: true,
  isLocked: false,
  isFollowUp: false,
  transcript: '',
  hint: '',
  isThinking: false,
  isResponseWaiting: false,
  isResponseActive: false,
  isHearingUser: true,
);

// The user just stopped talking and the reply has not started yet. Measured
// on the live wire (design doc §9): for a plain question this lasts ~10ms and
// is barely a flicker, but when the model reaches for `ask_claude` it is
// seconds of complete silence — the exact gap the spoken filler exists to
// cover. Showing "Думаю…" there is the visual half of the same fix.
const VoiceTurnUiProjection _thinkingProjection = VoiceTurnUiProjection(
  isListening: false,
  isLocked: false,
  isFollowUp: false,
  transcript: '',
  hint: '',
  isThinking: true,
  isResponseWaiting: false,
  isResponseActive: false,
);

const VoiceTurnUiProjection _speakingProjection = VoiceTurnUiProjection(
  isListening: false,
  isLocked: false,
  isFollowUp: false,
  transcript: '',
  hint: '',
  isThinking: false,
  isResponseWaiting: false,
  isResponseActive: true,
);

/// Builds the `HubControllerEvents` a `createProductionFreeFormVoiceMode`
/// call should be given so a running mode's listening/speaking state reaches
/// [applyProjection] (typically the setter for `CaptureController.hubProjection`,
/// same sink the PTT driver writes to). [onDisconnected] fires on the hub's
/// `onError`, carrying the error itself so the caller can log the cause and
/// decide what to do — recover the session or stop the mode (see
/// `CaptureController.recoverFreeFormVoiceMode`). Self-host patch: the error
/// used to be dropped here, which is why a drop ended the conversation with
/// nothing said and nothing logged.
/// [onSocketExpiring] fires on the provider's `goAway` — its warning that the
/// socket is about to be closed (measured 24.08: it lands ~9 minutes into a
/// live session with 50 seconds to spare, design doc §11). The mode owns the
/// mic and the begin frame, so the hub cannot rebuild under it on its own;
/// the caller is expected to `restart()` the mode, which keeps the
/// conversation and spends the notice instead of taking the drop.
HubControllerEvents freeFormModeProjectionEvents({
  required VoiceTurnPresenter applyProjection,
  required void Function(Object error) onDisconnected,
  required void Function() onSocketExpiring,
}) {
  return HubControllerEvents(
    onConnected: (_) => applyProjection(_listeningProjection),
    onError: (error) => onDisconnected(error),
    onGoAway: (_) => onSocketExpiring(),
    // Server VAD is the only source of utterance boundaries here, so it is
    // also the only honest source for the indicator. Note what is NOT wired:
    // `onTurnDone`. `turnComplete` arrives ~2.5s before the queued audio has
    // actually finished playing (design doc §9), so resetting the indicator
    // on it would show "Слушаю…" over a still-speaking assistant;
    // `onSpeakingEnd` (the player draining) is the audible truth.
    onUserSpeechState: (isSpeaking) => applyProjection(isSpeaking ? _hearingProjection : _thinkingProjection),
    onSpeakingStart: () => applyProjection(_speakingProjection),
    onSpeakingEnd: () => applyProjection(_listeningProjection),
    onInputTranscript: (text, isFinal, identity) {
      if (text.isEmpty) return;
      // A transcript lands together with the VAD's end-of-utterance verdict
      // (measured: same 10ms), and by then `onUserSpeechState(false)` has
      // already moved the indicator to "thinking" — so this must NOT drag it
      // back to plain listening. Kept as an explicit no-op instead of being
      // deleted: the handler documents that the transcript arrives here and
      // is deliberately not projected.
    },
  );
}
