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
HubControllerEvents freeFormModeProjectionEvents({
  required VoiceTurnPresenter applyProjection,
  required void Function(Object error) onDisconnected,
}) {
  return HubControllerEvents(
    onConnected: (_) => applyProjection(_listeningProjection),
    onError: (error) => onDisconnected(error),
    onSpeakingStart: () => applyProjection(_speakingProjection),
    onSpeakingEnd: () => applyProjection(_listeningProjection),
    onInputTranscript: (text, isFinal, identity) {
      if (text.isEmpty) return;
      // Still listening/capturing while the user talks — no separate
      // "thinking" phase to project: unlike PTT, there's no explicit
      // end-of-utterance commit here (server VAD owns that), so the first
      // externally-visible state change after a transcript is always the
      // model starting to speak (`onSpeakingStart` above).
      applyProjection(_listeningProjection);
    },
  );
}
