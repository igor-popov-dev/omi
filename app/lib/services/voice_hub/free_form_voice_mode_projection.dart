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
import 'dart:async';

import 'hub_controller.dart';
import 'voice_chat_log.dart';
import 'voice_turn_coordinator.dart' show VoiceTurnPresenter;
import 'voice_turn_machine.dart' show VoiceTurnUiProjection;

/// The mode is live, the wire is open, and nobody is talking on it — the
/// resting state of a running free-form session. Public because the host
/// paints it back by hand after a state the hub itself never emits an event
/// for (`CaptureController.applyFreeFormMicInterruption`).
const VoiceTurnUiProjection freeFormListeningProjection = VoiceTurnUiProjection(
  isListening: true,
  isLocked: false,
  isFollowUp: false,
  transcript: '',
  hint: '',
  isThinking: false,
  isResponseWaiting: false,
  isResponseActive: false,
);

/// The mic is not ours right now — a phone call took the audio mode, or
/// another app preempted the input (`PhoneMicController.kt`). Not a listening
/// state and not a thinking one: nothing the user says is reaching anybody,
/// and the honest thing to show is exactly that. Until this existed the
/// indicator kept saying "Слушаю…" through a whole call.
const VoiceTurnUiProjection freeFormMicBusyProjection = VoiceTurnUiProjection(
  isListening: false,
  isLocked: false,
  isFollowUp: false,
  transcript: '',
  hint: 'Микрофон занят — не слышу вас',
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

/// Пауза между концом речи (по VAD) и сигналом «думаю». Короче — сигнал
/// лезет в паузы внутри фразы; длиннее — теряется смысл «услышал сразу».
const Duration thinkingSignalDebounce = Duration(milliseconds: 250);

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
///
/// [onSocketExpiring] fires on the provider's `goAway` — its warning that the
/// socket is about to be closed (measured 24.08: it lands ~9 minutes into a
/// live session with 50 seconds to spare, design doc §11). The mode owns the
/// mic and the begin frame, so the hub cannot rebuild under it on its own;
/// the caller is expected to `restart()` the mode, which keeps the
/// conversation and spends the notice instead of taking the drop.
///
/// [onThinkingStart] — звук «услышал, думаю» (production: `thinkingEarcon`).
/// Срабатывает через [thinkingSignalDebounce] после конца речи пользователя
/// (server VAD), если за это время речь не возобновилась и ассистент не начал
/// (и не продолжает) говорить. Колбэк, а не плеер: это чистое отображение
/// событий, ему незачем знать про just_audio, а тестам — про платформенные
/// каналы (тот же приём, что `CaptureController.onVoiceModeStartSound`).
HubControllerEvents freeFormModeProjectionEvents({
  required VoiceTurnPresenter applyProjection,
  required void Function(Object error) onDisconnected,
  required void Function() onSocketExpiring,
  VoiceChatLog? chatLog,
  void Function()? onThinkingStart,
}) {
  final userSaid = StringBuffer();
  final assistantSaid = StringBuffer();

  // Сигнал «думаю» — по концу речи пользователя, а не по решению Gemini
  // вызвать ask_claude (баг Игоря: тот срабатывал только на высоких уровнях
  // ползунка и с задержкой на само решение модели — после фразы обычно была
  // тишина). Дебаунс нужен потому, что VAD режет речь и на паузах внутри
  // фразы: без него сигнал звучал бы посреди предложения. Возобновившаяся
  // речь или начавшийся ответ снимают таймер; на фоне говорящего ассистента
  // (ложное срабатывание VAD, реплика поверх ответа без barge-in) сигнал не
  // играет — он звучал бы поверх голоса.
  Timer? thinkingSignal;
  var assistantSpeaking = false;

  void cancelThinkingSignal() {
    thinkingSignal?.cancel();
    thinkingSignal = null;
  }

  void armThinkingSignal() {
    if (onThinkingStart == null) return;
    cancelThinkingSignal();
    thinkingSignal = Timer(thinkingSignalDebounce, () {
      thinkingSignal = null;
      if (assistantSpeaking) return;
      onThinkingStart();
    });
  }

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
    onConnected: (_) => applyProjection(freeFormListeningProjection),
    onError: (error) {
      cancelThinkingSignal();
      assistantSpeaking = false;
      // Flush what was already spoken before the drop: it happened, so it
      // belongs in history even though the session did not survive.
      commitUser();
      commitAssistant();
      onDisconnected(error);
    },
    onGoAway: (_) => onSocketExpiring(),
    // Server VAD is the only source of utterance boundaries here, so it is
    // also the only honest source for the indicator. Note what is NOT wired:
    // `onTurnDone`. `turnComplete` arrives ~2.5s before the queued audio has
    // actually finished playing (design doc §9), so resetting the indicator
    // on it would show "Слушаю…" over a still-speaking assistant;
    // `onSpeakingEnd` (the player draining) is the audible truth.
    onUserSpeechState: (isSpeaking) {
      isSpeaking ? cancelThinkingSignal() : armThinkingSignal();
      applyProjection(isSpeaking ? _hearingProjection : _thinkingProjection);
    },
    onSpeakingStart: () {
      // Ответ пошёл раньше дебаунса — сигнал «думаю» уже не к месту.
      cancelThinkingSignal();
      assistantSpeaking = true;
      // The user's utterance is over the moment the model starts answering.
      commitUser();
      // Звук может пойти раньше первого фрагмента транскрипта — начало
      // реплики ассистента честнее считать отсюда.
      assistantStartedAt ??= DateTime.now();
      applyProjection(_speakingProjection);
    },
    onSpeakingEnd: () {
      assistantSpeaking = false;
      applyProjection(freeFormListeningProjection);
    },
    onInterrupted: () {
      // Ответ оборван — следующий конец речи пользователя снова достоин сигнала.
      assistantSpeaking = false;
      // The user talked over the reply: close the line as partially spoken and
      // drop nothing else — whatever the model generates after this belongs to
      // the next turn, not to the one that was cut.
      commitAssistant(interrupted: true);
      applyProjection(freeFormListeningProjection);
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
      // The indicator is deliberately NOT touched here. A transcript lands
      // together with the VAD's end-of-utterance verdict (measured: same
      // 10ms), and by then `onUserSpeechState(false)` has already moved it to
      // "thinking" — projecting plain listening again would drag it back.
      // The text itself is still accumulated: chat history needs the words
      // even though the indicator does not.
      if (text.isEmpty) {
        if (isFinal) commitUser();
        return;
      }
      userStartedAt ??= DateTime.now();
      userSaid.write(text);
    },
  );
}
