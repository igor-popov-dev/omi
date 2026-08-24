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
import 'voice_chat_log.dart';
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
/// [chatLog], when given, records the spoken exchange into chat history (see
/// `voice_chat_log.dart`). Transcripts arrive in fragments with `isFinal` false
/// and are closed by an empty final event, so both sides are accumulated here
/// and committed once — a per-fragment write would store a bubble per syllable.
HubControllerEvents freeFormModeProjectionEvents({
  required VoiceTurnPresenter applyProjection,
  required void Function(Object error) onDisconnected,
  VoiceChatLog? chatLog,
}) {
  final userSaid = StringBuffer();
  final assistantSaid = StringBuffer();

  // Реплика штампуется временем НАЧАЛА речи, а не временем коммита (баг Игоря
  // 24.08: фрагменты диалога в чате не в том порядке). Коммиты происходят
  // сильно позже речи и парами (`onTurnDone` коммитит пользователя ПЕРЕД
  // ассистентом): следующая реплика пользователя, начатая во время ответа,
  // получала метку РАНЬШЕ этого ответа, а парные коммиты — одинаковые метки,
  // и сортировка чата по created_at их тасовала. Момент первого фрагмента —
  // честная хронология: она у реплик строго возрастает.
  DateTime? userStartedAt;
  DateTime? assistantStartedAt;

  void commitUser() {
    if (chatLog == null || userSaid.isEmpty) return;
    // Gemini размечает не-речь токеном <noise> в транскрипте — это служебная
    // метка, а не сказанное; пузырь «<noise>» в чате (скрин Игоря 24.08)
    // выглядит как мусор. Токен вырезается, реплика из одного шума не пишется.
    final said = userSaid.toString().replaceAll('<noise>', ' ');
    final startedAt = userStartedAt;
    userSaid.clear();
    userStartedAt = null;
    chatLog.addUserTurn(said, at: startedAt);
  }

  void commitAssistant({bool interrupted = false}) {
    if (chatLog == null || assistantSaid.isEmpty) return;
    // Self-host patch: history must record what the user HEARD, not what the
    // model generated. On barge-in the tail was cut mid-air, so the line is
    // marked as such — otherwise the next turn is built on the fiction that
    // the whole reply landed, and the model refers back to things nobody heard.
    //
    // The cut is marked, not measured: the transcript arrives as the model
    // speaks, and without word-level timings from the player there is no honest
    // way to say WHERE it stopped. A marker the model can reason about beats a
    // guessed offset that looks precise and is wrong.
    final spoken = assistantSaid.toString().trimRight();
    chatLog.addAssistantTurn(interrupted ? '$spoken… [прервано]' : spoken, at: assistantStartedAt);
    assistantSaid.clear();
    assistantStartedAt = null;
  }

  return HubControllerEvents(
    onConnected: (_) => applyProjection(_listeningProjection),
    onError: (error) {
      // Flush what was already spoken before the drop: it happened, so it
      // belongs in history even though the session did not survive.
      commitUser();
      commitAssistant();
      onDisconnected(error);
    },
    onSpeakingStart: () {
      // The user's utterance is over the moment the model starts answering.
      commitUser();
      // Звук может пойти раньше первого фрагмента транскрипта — начало
      // реплики ассистента честнее считать отсюда.
      assistantStartedAt ??= DateTime.now();
      applyProjection(_speakingProjection);
    },
    onSpeakingEnd: () => applyProjection(_listeningProjection),
    onInterrupted: () {
      // The user talked over the reply: close the line as partially spoken and
      // drop nothing else — whatever the model generates after this belongs to
      // the next turn, not to the one that was cut.
      commitAssistant(interrupted: true);
      applyProjection(_listeningProjection);
    },
    onAssistantText: (text, isFinal, identity) {
      if (text.isNotEmpty) {
        assistantStartedAt ??= DateTime.now();
        assistantSaid.write(text);
      }
      if (isFinal) commitAssistant();
    },
    onTurnDone: (_) {
      commitUser();
      commitAssistant();
    },
    onInputTranscript: (text, isFinal, identity) {
      if (text.isEmpty) {
        if (isFinal) commitUser();
        return;
      }
      userStartedAt ??= DateTime.now();
      userSaid.write(text);
      // Still listening/capturing while the user talks — no separate
      // "thinking" phase to project: unlike PTT, there's no explicit
      // end-of-utterance commit here (server VAD owns that), so the first
      // externally-visible state change after a transcript is always the
      // model starting to speak (`onSpeakingStart` above).
      applyProjection(_listeningProjection);
    },
  );
}
