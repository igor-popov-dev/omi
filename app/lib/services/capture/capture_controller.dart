import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:omi/utils/platform/platform_manager.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'package:collection/collection.dart';
import 'package:flutter_provider_utilities/flutter_provider_utilities.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

import 'package:omi/backend/http/api/conversations.dart';
import 'package:omi/backend/preferences.dart';
import 'package:omi/services/auth_service.dart';
import 'package:omi/services/bridges/ble_bridge.dart';
import 'package:omi/backend/schema/bt_device/bt_device.dart';
import 'package:omi/backend/schema/conversation.dart';
import 'package:omi/backend/schema/message.dart';
import 'package:omi/backend/schema/person.dart';
import 'package:omi/backend/schema/structured.dart';
import 'package:omi/backend/schema/transcript_segment.dart';
import 'package:omi/env/env.dart';
import 'package:omi/models/custom_stt_config.dart';
import 'package:omi/providers/device_onboarding_provider.dart';
import 'package:omi/services/capture/capture_external_actions.dart';
import 'package:omi/services/capture/capture_metrics_tracker.dart';
import 'package:omi/services/capture/stt_display_status.dart';
import 'package:omi/services/capture/conversation_source_for_device.dart';
import 'package:omi/services/capture/conversation_location_capture.dart';
import 'package:omi/services/capture/freemium_threshold_tracker.dart';
import 'package:omi/services/connectivity_service.dart';
import 'package:omi/services/services.dart';
import 'package:omi/services/voice_hub/free_form_voice_mode.dart';
import 'package:omi/services/voice_hub/free_form_voice_mode_projection.dart'
    show freeFormListeningProjection, freeFormMicBusyProjection;
import 'package:omi/services/voice_hub/voice_turn_driver.dart';
import 'package:omi/services/voice_hub/voice_chat_log.dart';
import 'package:omi/services/voice_hub/voice_output_envelope.dart';
import 'package:omi/services/voice_hub/voice_turn_machine.dart' show VoiceTurnUiProjection, idleVoiceTurnProjection;
import 'package:omi/services/voice_playback/omi_voice_playback_service.dart';
import 'package:omi/services/sockets/transcription_service.dart';
import 'package:omi/services/audio_sources/audio_source.dart';
import 'package:omi/services/audio_sources/ble_device_source.dart';
import 'package:omi/services/devices/connectors/limitless_connection.dart';
import 'package:omi/services/devices/models.dart';
import 'package:omi/services/audio_sources/phone_mic_source.dart';
import 'package:omi/services/wals.dart';
import 'package:omi/utils/alerts/app_snackbar.dart';
import 'package:omi/utils/batch_recording.dart';
import 'package:omi/utils/enums.dart';
import 'package:omi/utils/image/image_utils.dart';
import 'package:omi/utils/l10n_extensions.dart';
import 'package:omi/services/battery_widget_service.dart';
import 'package:omi/utils/logger.dart';
import 'package:omi/app_globals.dart';

import 'package:omi/backend/schema/message_event.dart'
    show
        MessageEvent,
        MessageServiceStatusEvent,
        ConversationProcessingStartedEvent,
        ConversationEvent,
        LastConversationEvent,
        SpeakerLabelSuggestionEvent,
        TranslationEvent,
        PhotoProcessingEvent,
        PhotoDescribedEvent,
        FreemiumThresholdReachedEvent,
        SegmentsDeletedEvent;

class CaptureController extends ChangeNotifier
    with MessageNotifierMixin
    implements ITransctiptSegmentSocketServiceListener {
  static const MethodChannel _nativeBleTranscriptChannel = MethodChannel('com.friend.ios/native_ble_transcript');
  // 12 attempts * 5s keeps the same ~1min give-up window as before, but at a
  // third of the request rate: this poll is a Firestore read on our self-host
  // backend, and 2s was aggressive enough that, combined with frequent socket
  // reconnects, it once accounted for 68% of the backend's traffic and
  // exhausted the project's daily Firestore quota.
  static const int _maxInProgressConversationRefreshAttempts = 12;
  static const Duration _inProgressConversationRefreshInterval = Duration(seconds: 5);

  final ConversationLocationCapture _conversationLocationCapture;
  final Future<void> Function()? _inProgressConversationLoader;
  final Future<BleAudioCodec> Function(String deviceId)? _audioCodecLoader;

  /// Test seam for the forced Firebase token refresh a 4001 close asks for.
  final Future<void> Function()? _authTokenRefresher;

  // Close codes the backend uses to explain a refused socket, as opposed to a
  // connection that dropped. See backend/utils/other/endpoints.py.
  static const int _wsCloseTokenRefreshRequired = 4001;
  static const int _wsCloseReloginRequired = 4004;
  static const int _wsCloseAccountDeleting = 4005;

  CaptureExternalActions externalActions;
  DeviceOnboardingProvider? deviceOnboardingProvider;

  // Optional, settable dependency wiring pendant single-tap gestures to the
  // new realtime voice hub. Nullable and unset by production wiring unless
  // the `pttHubEnabled` flag is on, so existing call sites that never set
  // this are 100% unaffected. Additive/parallel to the legacy STT pipeline
  // for now — see `voice_turn_driver.dart`'s file header (~line 73) for the
  // intended contract this will eventually replace.
  VoiceHubTurnDriver? hubTurnDriver;

  /// Live listening/thinking/speaking projection from `hubTurnDriver`, fed
  /// by whatever `applyProjection` callback production wiring gave the
  /// driver (see `voice_hub_production.dart`). Stays at
  /// [idleVoiceTurnProjection] whenever `hubTurnDriver` is unset or no hub
  /// turn is active — a UI consumer can watch this unconditionally without
  /// checking `hubTurnDriver`/`pttHubEnabled` itself.
  final ValueNotifier<VoiceTurnUiProjection> hubProjection = ValueNotifier(idleVoiceTurnProjection);

  /// Громкость речи ассистента 0..1 для живой иконки (`OmiVoiceOrb`).
  /// Наполняется обёрткой плеера (`envelopeTappedPlayerFactory`) в
  /// production-сборке; в тестах и без неё остаётся нулём, и иконка тогда
  /// живёт одним темпом фазы.
  final VoiceOutputEnvelope voiceOutputEnvelope = VoiceOutputEnvelope();

  // Optional, settable dependency for the hands-free (server-VAD) voice
  // mode toggle (ДОПОЛНЕНИЕ 22.08 п.1). Nullable and unset by production
  // wiring unless the `freeFormMode` dev flag's button is even reachable —
  // see `voice_hub_production.dart`'s `createProductionFreeFormVoiceMode`
  // for why this is a SEPARATE `HubController` from [hubTurnDriver]'s, not
  // shared. Safe to construct always (no I/O until [startFreeFormVoiceMode]
  // actually calls `start()`), same discipline as `hubTurnDriver`.
  FreeFormVoiceMode? freeFormVoiceMode;

  /// Whether [freeFormVoiceMode] is currently running — the toggle button's
  /// source of truth (`FreeFormVoiceMode.isRunning` itself isn't listenable).
  final ValueNotifier<bool> freeFormModeActive = ValueNotifier(false);

  /// Self-host: звук «голосовой режим включён» — подключается в main.dart
  /// (thinkingEarcon), в тестах остаётся null.
  void Function()? onVoiceModeStartSound;

  /// Telecom call shell for the voice mode (self-managed call + CallStyle
  /// notification, ~/omi-jarvis/docs/voice-call-mode-design.md). Wired in
  /// main.dart to `VoiceCallSession.start`/`end`; null in tests and on
  /// platforms without the native peer. Start is awaited BEFORE the mode's
  /// own start so the call (and the mic legality it grants) exists before
  /// capture opens; both are fail-open and never throw.
  Future<void> Function()? onVoiceModeCallStart;
  Future<void> Function()? onVoiceModeCallEnd;

  /// Self-host patch: records the spoken exchange into chat history, so voice
  /// and chat share one conversation (see `voice_chat_log.dart`).
  final VoiceChatLog voiceChatLog = VoiceChatLog();

  /// Starts [freeFormVoiceMode] (a real network call: mints a token, opens a
  /// socket, starts continuous mic capture) and flips [freeFormModeActive].
  /// No-op if [freeFormVoiceMode] is unset or already running. On a start
  /// failure, resets both [freeFormModeActive] and [hubProjection] back to
  /// idle and rethrows so a caller (the toggle button) can surface the error.
  Future<void> startFreeFormVoiceMode() async {
    final mode = freeFormVoiceMode;
    if (mode == null || freeFormModeActive.value) return;
    // The mirror of the gate in `handleSingleTapButtonEvent`: the PTT hub
    // keeps its socket WARM for 90s after a turn (`hubIdleReleaseDuration`),
    // so a question asked with the pendant half a minute ago still holds one
    // when the user opens this mode. Sockets on one key do coexist — measured
    // 24.08, both idle and both mid-conversation — so this is not about a
    // server-side ceiling. It is the same reasoning as the tap gate above:
    // two live sockets are two microphones on one room, and the warm one the
    // user is walking away from bills for nothing. Releasing it is also just correct: the user
    // is switching voice paths, and a warm socket nobody will press costs
    // money for nothing.
    hubTurnDriver?.teardown();
    freeFormModeActive.value = true;
    try {
      // Call shell first: the mic must already be inside an active telecom
      // call before capture opens, or a background/lock-screen start records
      // silence (Android 12+ background-mic restriction).
      await onVoiceModeCallStart?.call();
      // Stop-during-start guard (the same race FreeFormVoiceMode.start guards
      // for its capture): stopFreeFormVoiceMode during the await above already
      // reset the UI and ended the call shell — starting the mode now would
      // leave it running headless with the toggle showing off.
      if (!freeFormModeActive.value) return;
      await mode.start();
      // Звук «голосовой режим включён» (просьба Игоря 24.08) — ПОСЛЕ удачного
      // старта, чтобы сигнал не звучал перед ошибкой. Колбэк, а не плеер:
      // контроллеру незачем знать про just_audio, а тестам — про платформенные
      // каналы (main.dart подключает thinkingEarcon).
      onVoiceModeStartSound?.call();
    } catch (_) {
      resetFreeFormVoiceModeUi();
      rethrow;
    }
  }

  /// Stops [freeFormVoiceMode] (idempotent, matches `FreeFormVoiceMode.stop`)
  /// and resets the UI state.
  void stopFreeFormVoiceMode() {
    freeFormVoiceMode?.stop();
    // ПОЛНЫЙ teardown, а не только отмена хода: тёплый сокет после остановки
    // продолжал жить вместе со своим плеером и коммуникационным аудиорежимом —
    // другие приложения не могли играть звук, а поздние события сессии
    // перещёлкивали индикатор обратно в «слушаю» при выключенном режиме
    // (баг Игоря 24.08). Цена — следующий старт платит переподключение ~1–2 с.
    freeFormVoiceMode?.hub.teardownSession();
    resetFreeFormVoiceModeUi();
  }

  /// The provider warned that the socket is about to close (`goAway` —
  /// measured 24.08: ~9 minutes into a live session, 50 seconds of notice,
  /// design doc §11). Rebuilds it NOW, while the old one still works, so the
  /// drop never lands in the middle of the conversation. The conversation
  /// itself carries over on the resumption handle, and nothing is said out
  /// loud: unlike a recovered drop, there is nothing to apologise for.
  ///
  /// A rebuild that fails is handed to the ordinary drop recovery — that path
  /// owns the retry budget and the "give up and stop" decision, so failing
  /// here must not invent a second policy.
  Future<void> rebuildFreeFormVoiceModeSocket() async {
    final mode = freeFormVoiceMode;
    if (mode == null || !freeFormModeActive.value || !mode.isRunning) return;
    Logger.debug('[VoiceMode] сервер предупредил о закрытии сокета — пересобираю заранее');
    try {
      await mode.restart();
    } catch (e) {
      Logger.error('[VoiceMode] упреждающая пересборка не удалась: $e');
      await recoverFreeFormVoiceMode(e);
    }
  }

  /// The native capture reported the mic taken away (`interrupted: true`) or
  /// given back (`false`) while the free-form mode runs —
  /// `HubPttCaptureOptions.onInterruption`, driven by `PhoneMicController`'s
  /// `INTERRUPTED`/`RUNNING` transitions (a phone call taking the audio mode,
  /// or another app preempting the input).
  ///
  /// All this does is tell the truth on screen. The mode keeps running and the
  /// socket is deliberately left open — the native side resumes the capture by
  /// itself when the call ends, and for a short interruption that means the
  /// conversation simply continues. What it replaces is an indicator that said
  /// "Слушаю…" for the entire length of a call while nothing could possibly
  /// reach the model.
  void applyFreeFormMicInterruption(bool interrupted) {
    if (!freeFormModeActive.value) return;
    Logger.debug(
      interrupted
          ? '[VoiceMode] микрофон отобрали (звонок или другое приложение) — режим ждёт'
          : '[VoiceMode] микрофон вернулся — продолжаю слушать',
    );
    hubProjection.value = interrupted ? freeFormMicBusyProjection : freeFormListeningProjection;
  }

  /// Ручной barge-in: пользователь ткнул в живую иконку, пока ассистент
  /// говорил. Три вещи разом — замолчать (и не доиграть остаток, см.
  /// [HubSession.muteCurrentResponse]), погасить уровень в иконке, вернуть
  /// индикатор в «слушаю».
  ///
  /// Проекцию двигаем сами: нативный `clear()` буфер сбрасывает, но
  /// `onDrained` при этом не шлёт, а значит `onSpeakingEnd` не придёт и
  /// иконка осталась бы в фазе речи над замолчавшим ассистентом.
  ///
  /// Возвращает `false`, если прерывать было нечего — вызывающий тогда
  /// трактует нажатие как обычное (выключение режима).
  bool interruptAssistantSpeech() {
    final mode = freeFormVoiceMode;
    if (mode == null || !freeFormModeActive.value) return false;
    if (!hubProjection.value.isResponseActive) return false;

    mode.hub.muteCurrentResponse();
    voiceOutputEnvelope.clear();
    hubProjection.value = freeFormListeningProjection;
    // Прерывание — это активность: без отметки авто-выключение по тишине
    // отсчитывало бы паузу с последней реплики, а разговор только что
    // продолжился.
    mode.noteActivity();
    return true;
  }

  /// Resets [freeFormModeActive]/[hubProjection] to idle WITHOUT calling
  /// `FreeFormVoiceMode.stop()` — for callers where the mode has already
  /// stopped itself (the hub-level `onError` handler wired in production,
  /// and `createProductionFreeFormVoiceMode`'s `onIdleTimeout`, which calls
  /// `stop()` internally right after firing that callback).
  void resetFreeFormVoiceModeUi() {
    freeFormModeActive.value = false;
    hubProjection.value = idleVoiceTurnProjection;
    // Единая точка (см. ниже): сюда сходятся все пути завершения — значит,
    // и звонок-оболочка гасится ровно здесь. Идемпотентно и fail-open на
    // стороне VoiceCallSession; при завершении, начатом самим звонком
    // (красная кнопка / настоящий вызов), native уже всё снёс — end() no-op.
    unawaited(onVoiceModeCallEnd?.call() ?? Future<void>.value());
    // Реплики уходят в чат по одной сразу после произнесения (onStored выше
    // перечитывает чат после каждой); здесь — только хвост, если последняя
    // запись ещё в пути, плюс контрольная перечитка. flush() не шлёт уже
    // отправленное повторно. Записи и раньше долетали до сервера, но чат их
    // не перечитывал — разговор «не появлялся», пока экран не переоткроют
    // (жалоба Игоря 24.08 ~02:45). Единая точка: сюда приходят и ручная
    // остановка, и idle-timeout, и обрыв.
    unawaited(voiceChatLog.flush().then((_) => externalActions.refreshChatMessages()));
  }

  /// Self-host: смена уровня эскалации (ползунок Gemini ↔ Claude) должна
  /// действовать со СЛЕДУЮЩЕГО разговора, даже если тёплый сокет ещё жив —
  /// тёплая сессия несёт инструкции и каталог инструментов СТАРОГО уровня
  /// (stop() сознательно оставляет сокет тёплым ради быстрого рестарта).
  /// Живой разговор не рвём — уровень доедет при следующем старте после
  /// остановки. PTT-хаб не трогаем: его тёплая сессия пересобирается своим
  /// драйвером, а рвать её отсюда значило бы лезть в его внутренности.
  void invalidateWarmVoiceSessions() {
    if (freeFormModeActive.value) return;
    freeFormVoiceMode?.hub.teardownSession();
  }

  // Self-host patch, not for upstream: a dropped socket used to end the
  // conversation in silence. Reported 23.08 — "спросил, повисел, выключился",
  // with nothing said and nothing logged, so the user could not tell a crash
  // from being ignored.
  static const int _maxVoiceRecoveries = 3;
  static const Duration _voiceRecoveryWindow = Duration(minutes: 2);
  final List<DateTime> _voiceRecoveries = [];

  /// What the recovered session says out loud. Phrased as an instruction, not a
  /// transcript line: the model reads it as the user speaking and answers in its
  /// own voice, in whatever language the conversation is in.
  static const String _voiceRecoveryPrompt =
      'Связь прервалась и только что восстановилась. Скажи мне об этом одной короткой фразой '
      'и продолжай разговор с того места, где мы остановились.';

  /// Recovers the free-form session after a hub error instead of shutting the
  /// mode down: logs the cause, reconnects, and has the model say out loud that
  /// it dropped. Falls back to a clean stop when recovery itself fails or when
  /// drops keep coming — reconnecting forever would burn per-minute billing on a
  /// session that cannot hold.
  ///
  /// ПОЛНЫЙ цикл через единый путь, а не ре-коннект «на месте» (баг Игоря
  /// 24.08 ~16:08): прежний `mode.stop(); mode.start()` восстанавливал сессию
  /// В ОБХОД звонка-оболочки — звонок к тому моменту уже был снят, а
  /// воскресшая сессия жила без него: держала микрофон бесконечно и отбирала
  /// аудиофокус у любого другого приложения (Яндекс.Музыка играла полсекунды
  /// и глохла). Теперь обрыв проходит те же двери, что и человек: полный
  /// стоп (режим, хаб, звонок, микрофон) → полный старт (звонок → режим).
  Future<void> recoverFreeFormVoiceMode(Object error) async {
    final mode = freeFormVoiceMode;
    Logger.error('[VoiceMode] сессия оборвалась: $error');
    if (mode == null || !freeFormModeActive.value) {
      resetFreeFormVoiceModeUi();
      return;
    }

    // Two ways to know a rebuild is pointless, one conclusion. The direct one
    // is the native capture saying the mic is not ours right now
    // ([FreeFormVoiceMode.micInterrupted]); it catches the case the inference
    // below cannot — a session that DID hear the user before the call started,
    // whose socket then dies mid-call looking perfectly recoverable, so it
    // gets rebuilt and announces itself out loud over the call.
    //
    // A socket that never heard the mic cannot be recovered by rebuilding it:
    // the replacement gets the same silence and dies the same way. The
    // everyday cause is a phone call — the native capture treats a stalled mic
    // under a call mode as an interruption and waits it out, so the hub sits
    // on a mute wire until the provider hangs up (see
    // `BaseHubSession.canIdleRelease`).
    //
    // Left to the retry budget below this would never stop: the drops arrive
    // ~2.5 minutes apart (the provider's own idle close), so they fall outside
    // [_voiceRecoveryWindow] and never accumulate to [_maxVoiceRecoveries],
    // while each recovery speaks its line out loud — which counts as activity
    // and rearms the 3-minute silence auto-off that would otherwise end the
    // mode. A long call would therefore hold the mode open indefinitely,
    // rebuilding and talking over itself. Stop instead; the user turns the
    // mode back on when they have the mic again.
    if (mode.micInterrupted || !mode.hasHeardInput) {
      Logger.error(
        mode.micInterrupted
            ? '[VoiceMode] микрофон отобран прямо сейчас — выключаю режим, а не пересобираю'
            : '[VoiceMode] микрофон молчал всю сессию (звонок?) — выключаю режим, а не пересобираю',
      );
      _voiceRecoveries.clear();
      // suspend(), not stop(): a call is not the user saying "we're done".
      // The conversation stays on the resumption handle, so switching the
      // mode back on when the call ends carries on where it broke off
      // instead of opening a blank session (design doc §10).
      mode.suspend();
      resetFreeFormVoiceModeUi();
      return;
    }

    final now = DateTime.now();
    _voiceRecoveries.removeWhere((at) => now.difference(at) > _voiceRecoveryWindow);
    if (_voiceRecoveries.length >= _maxVoiceRecoveries) {
      Logger.error('[VoiceMode] ${_voiceRecoveries.length} обрывов подряд — выключаю режим');
      _voiceRecoveries.clear();
      // Same rule: the mode gave up, the user did not. What could not hold
      // here is the socket, and the handle is not tied to it.
      mode.suspend();
      // ...но тёплый сокет отпускаем, как это делает stopFreeFormVoiceMode:
      // suspend() освобождает только микрофон, а живой сокет продолжал держать
      // плеер и коммуникационный аудиорежим (другие приложения без звука —
      // баг Игоря 24.08). teardownSession() рвёт сокет и НЕ трогает
      // resumption handle, так что разговор всё равно помнится.
      mode.hub.teardownSession();
      resetFreeFormVoiceModeUi();
      return;
    }
    _voiceRecoveries.add(now);

    // Здесь НЕ stopFreeFormVoiceMode(): его публичный stop() означает «это
    // пользователь закончил разговор» и заставляет хаб забыть сессию — восста-
    // новление через него отдавало новому сокету пустой разговор, и фраза
    // «продолжай с того места» становилась ложью. suspend() отпускает микрофон,
    // не трогая resumption handle; teardownSession() рвёт сокет вместе с его
    // плеером и аудиорежимом; resetFreeFormVoiceModeUi() снимает звонок-оболочку.
    // Полный цикл звонка обязателен: восстановленная в обход него сессия жила
    // без звонка, держала микрофон и отбирала аудиофокус (регресс 24.08 ~16:08).
    mode.suspend();
    mode.hub.teardownSession();
    resetFreeFormVoiceModeUi();
    hubProjection.value = const VoiceTurnUiProjection(
      isListening: false,
      isLocked: false,
      isFollowUp: false,
      transcript: '',
      hint: 'Связь прервалась, восстанавливаю…',
      isThinking: true,
      isResponseWaiting: false,
      isResponseActive: false,
    );

    try {
      // Через startFreeFormVoiceMode, а не mode.start(): режим обязан снова
      // жить внутри звонка-оболочки. Разговор при этом цел — выше был
      // suspend(), а не stop(), так что новый сокет поднимется на прежнем
      // resumption handle и строка ниже действительно ему по силам.
      await startFreeFormVoiceMode();
      // Восстановление могло быть молча отменено (стоп во время await) —
      // тогда пользователь выключил режим сам, и объявлять «связь
      // восстановлена» некому.
      if (!freeFormModeActive.value) return;
      Logger.debug('[VoiceMode] сессия восстановлена, попытка ${_voiceRecoveries.length}');
      mode.announce(_voiceRecoveryPrompt);
    } catch (e) {
      Logger.error('[VoiceMode] восстановить не удалось: $e');
      resetFreeFormVoiceModeUi();
    }
  }

  // Cache refresh for backend-created persons
  Future<void>? _peopleRefreshFuture;

  TranscriptSegmentSocketService? _socket;
  Timer? _keepAliveTimer;
  DateTime? _keepAliveLastExecutedAt;
  Timer? _inProgressConversationRefreshTimer;
  int _inProgressConversationRefreshAttempts = 0;
  bool _isRefreshingInProgressConversation = false;

  IWalService get _wal => ServiceManager.instance().wal;

  AudioSource? _activeSource;

  bool _isWalSupported = false;

  bool get isWalSupported => _isWalSupported;

  StreamSubscription<bool>? _connectionStateListener;
  bool _isConnected = ConnectivityService().isConnected;

  get isConnected => _isConnected;

  String? microphoneName;
  double microphoneLevel = 0.0;

  bool get outOfCredits => externalActions.isOutOfCredits ?? false;

  String? get topConversationId => externalActions.topConversationId;

  final FreemiumThresholdTracker _freemiumThreshold = FreemiumThresholdTracker();

  bool get freemiumThresholdReached => _freemiumThreshold.reached;
  int get freemiumRemainingSeconds => _freemiumThreshold.remainingSeconds;

  /// Whether user needs to take action (e.g., setup on-device STT)
  bool get freemiumRequiresUserAction => _freemiumThreshold.requiresUserAction;

  List<MessageEvent> _transcriptionServiceStatuses = [];
  List<MessageEvent> get transcriptionServiceStatuses => _transcriptionServiceStatuses;
  MessageServiceStatusEvent? _terminalTranscriptionFailure;
  MessageServiceStatusEvent? get terminalTranscriptionFailure => _terminalTranscriptionFailure;

  // Self-host patch: when custom STT is configured, its polling socket keeps
  // buffering audio locally and retrying instead of tearing the transcription
  // socket down on every failure (see PurePollingSocket). Surface that local
  // state here so the recording UI can show "offline, buffering" instead of
  // silently showing "Listening" while nothing is actually being transcribed.
  PurePollingSocket? get _activeCustomSttPollingSocket {
    final socket = _socket?.socket;
    if (socket is CompositeTranscriptionSocket) {
      final primary = socket.primarySocket;
      return primary is PurePollingSocket ? primary : null;
    }
    return socket is PurePollingSocket ? socket : null;
  }

  /// How long the custom STT endpoint has been unreachable, or null if it is
  /// not in use or is currently healthy.
  Duration? get customSttBufferingDuration {
    final since = _activeCustomSttPollingSocket?.bufferingSince;
    return since == null ? null : DateTime.now().difference(since);
  }

  /// When the custom STT endpoint last answered successfully, or null if custom
  /// STT is not in use or has not succeeded yet on the current socket.
  DateTime? get customSttLastSuccessAt => _activeCustomSttPollingSocket?.lastSuccessAt;

  // Self-host patch: positive "recognition is actually delivering" signal for
  // the recording UI, complementing the negative bufferingSince one. Segments
  // arrive on both the omi-ws and the custom STT paths, so this covers both.
  DateTime? _lastSegmentReceivedAt;
  DateTime? get lastSegmentReceivedAt => _lastSegmentReceivedAt;

  /// Whether an audio source is actually producing frames right now — a
  /// connected recording device, or an active phone-mic/system-audio session.
  bool get _audioSourceActive =>
      havingRecordingDevice ||
      recordingState == RecordingState.record ||
      recordingState == RecordingState.systemAudioRecord ||
      recordingState == RecordingState.initialising;

  /// What the recording UI should say about transcription right now. Shared by
  /// the capture page and the home capture card so the two cannot disagree.
  SttDisplayStatus get sttDisplayStatus {
    return computeSttDisplayStatus(
      isPaused: isPaused || recordingState == RecordingState.interrupted,
      hasTerminalFailure: terminalTranscriptionFailure != null,
      bufferingFor: customSttBufferingDuration,
      transportHealthy: transcriptServiceReady && _audioSourceActive,
      lastSegmentAt: _lastSegmentReceivedAt,
      now: DateTime.now(),
    );
  }

  // Phone mic WAL: buffer for splitting variable-sized PCM chunks into fixed-size frames
  bool _phoneMicWalActive = false;

  // True while a phone-mic Transcribe Later (batch) session is running: the
  // native recorder writes .bin files directly, so no socket/WAL/AudioSource is
  // active. Distinct from the Live phone-mic path (_phoneMicWalActive).
  bool _phoneMicBatchActive = false;

  bool get isPhoneMicBatchRecording => _phoneMicBatchActive;

  bool _isLoadingInProgressConversation = false;

  late final CaptureMetricsTracker _metrics = CaptureMetricsTracker(onNotify: notifyListeners);

  double get bleReceiveRateKbps => _metrics.bleReceiveRateKbps;
  double get wsSendRateKbps => _metrics.wsSendRateKbps;
  int get lifetimeBleBytesReceived => _metrics.lifetimeBleBytesReceived;
  int get lifetimeWsSocketBytesSent => _metrics.lifetimeWsSocketBytesSent;

  /// Call this in initState of a widget that needs BLE/WS metrics
  void addMetricsListener() {
    _metrics.addMetricsListener();
  }

  /// Call this in dispose of a widget that uses BLE/WS metrics
  void removeMetricsListener() {
    _metrics.removeMetricsListener();
  }

  void setMetricsAppActive(bool active) {
    _metrics.setAppActive(active);
  }

  /// Check if any segment has a personId not in local cache.
  /// Uses Set difference for O(N+M) complexity instead of O(N*M).
  bool _hasMissingPerson(List<TranscriptSegment> segments) {
    final cachedIds = SharedPreferencesUtil().cachedPeople.map((p) => p.id).toSet();
    final segmentPersonIds = segments.map((s) => s.personId).whereType<String>().toSet();
    return segmentPersonIds.difference(cachedIds).isNotEmpty;
  }

  CaptureController({
    CaptureExternalActions? externalActions,
    ConversationLocationCapture? conversationLocationCapture,
    Future<void> Function()? inProgressConversationLoader,
    Future<BleAudioCodec> Function(String deviceId)? audioCodecLoader,
    Future<void> Function()? authTokenRefresher,
  }) : externalActions = externalActions ?? const NoopCaptureExternalActions(),
       _conversationLocationCapture = conversationLocationCapture ?? ConversationLocationCapture(),
       _inProgressConversationLoader = inProgressConversationLoader,
       _audioCodecLoader = audioCodecLoader,
       _authTokenRefresher = authTokenRefresher {
    // Restore a persisted device mute so it survives an app kill/restart. When
    // the device reconnects, streamDeviceRecording() reads _isPaused as
    // `wasPaused` and re-applies the mute instead of silently resuming.
    _isPaused = SharedPreferencesUtil().deviceMuted;
    _connectionStateListener = ConnectivityService().onConnectionChange.listen((bool isConnected) {
      onConnectionStateChanged(isConnected);
    });
    BleBridge.instance.addBatchRecordingFinalizedListener(_onOfflineRecordingFinalized);
    // Self-host patch (02.09): каждая записанная реплика голосового режима
    // сразу уходит на сервер (см. voice_chat_log.dart) — и чат перечитывается
    // тут же, а не по завершении режима. Читаем `externalActions` в момент
    // вызова, а не захватываем: он подменяется через updateExternalActions
    // (`this.` — параметр конструктора с тем же именем затеняет поле).
    voiceChatLog.onStored = () => unawaited(
      this.externalActions.refreshChatMessages().catchError(
        (Object e) => Logger.debug('[VoiceChatLog] чат не перечитан после реплики: $e'),
      ),
    );
  }

  // True while the audio session is interrupted (phone call, Siri, alarm).
  // On iOS the native recorder detects and recovers interruptions itself and
  // reports them via onInterruption; Dart only mirrors the state so the UI and
  // the socket keepalive stay in sync — it never restarts capture for them.
  bool _micInterrupted = false;

  void _onMicInterruption(bool began) {
    // Live phone mic drives an AudioSource; batch has none (_activeSource stays
    // null) but still needs its interruption state mirrored.
    if (_activeSource is! PhoneMicSource && !_phoneMicBatchActive) return;
    _micInterrupted = began;
    if (began) {
      updateRecordingState(RecordingState.interrupted);
    } else if (_phoneMicBatchActive) {
      // Batch has no onRecording callback to restore the state; native already
      // resumed, so flip back to record here.
      updateRecordingState(RecordingState.record);
    }
    // On end (Live), native capture has already resumed; onRecording restores
    // RecordingState.record once frames flow again.
    notifyListeners();
  }

  // True while THIS app's own call owns the microphone. Deliberately separate from
  // [_micInterrupted]: that one mirrors an interruption the OS reported and the OS will
  // end, while this one is ours to end. Keeping them apart matters on the resume side —
  // a real interruption can begin and end inside our call, and its `end` must not be
  // mistaken for permission to put ambient capture back while the call is still running.
  bool _inAppCallHoldsMic = false;

  bool get inAppCallHoldsMic => _inAppCallHoldsMic;

  /// Hush ambient phone-mic capture for the duration of an in-app call.
  ///
  /// Without this the phone keeps streaming the same conversation into `v4/listen`
  /// while the cloud streams both legs of the call under its own call_id, and the
  /// backend de-duplicates nothing: one call becomes TWO conversations, one holding
  /// our side and one the other party's (measured, lane 6 tick 22,
  /// marathon/tools/vox-dual-session-probe.py, case `ambient`). On Android the two
  /// captures also fight over the microphone, and the loser records silence.
  ///
  /// The mic arbiter cannot do this part. It can refuse a NEW claim (a call takes its
  /// veto — MicArbiter.holdForCall), but it cannot stop a capture already running, and
  /// the call SDK takes the microphone natively without asking it either.
  Future<void> pauseForInAppCall() async {
    if (_inAppCallHoldsMic) return;
    // Nothing is capturing — take the flag anyway. The call may outlive this check
    // (the user can start recording mid-call), and the flag is what refuses that.
    _inAppCallHoldsMic = true;
    if (_activeSource is! PhoneMicSource && !_phoneMicBatchActive) return;
    _onMicInterruption(true);
    ServiceManager.instance().phoneMic.stop();
  }

  /// Give the microphone back after the call. Idempotent: several exits report the end
  /// of one call, and a second resume must not start a session the user never asked for.
  Future<void> resumeAfterInAppCall() async {
    if (!_inAppCallHoldsMic) return;
    // Cleared first: the restart paths below refuse to run while it is set.
    _inAppCallHoldsMic = false;
    try {
      if (_activeSource is PhoneMicSource) {
        // Preserves the socket and the segments captured before the call.
        await _resumeMicRecording();
      } else if (_phoneMicBatchActive) {
        await _restartPhoneMicBatchAfterCall();
      }
    } catch (e, st) {
      // The restart can be refused outright: a chat voice memo that was already recording
      // when the call began still holds the mic arbiter, and its stack is not ours to
      // stop. Without this the throw escapes past _onMicInterruption(false) and the
      // capture card stays on `interrupted` with nothing running — the same deaf phone
      // the hold exists to prevent, only quieter. Fail visibly instead.
      Logger.error('[CaptureProvider] resume after in-app call failed: $e\n$st');
      _activeSource = null;
      _phoneMicWalActive = false;
      _micInterrupted = false;
      updateRecordingState(RecordingState.stop);
      await _socket?.stop(reason: 'resume after in-app call failed');
      notifyListeners();
      return;
    }
    _onMicInterruption(false);
  }

  /// Batch has no resume — a session is a run of files, and the watchdog restarts it the
  /// same way. Kept separate from [_onBatchStalled] only because that one refuses to run
  /// while a restart is in flight, which is exactly the state a call leaves behind.
  Future<void> _restartPhoneMicBatchAfterCall() async {
    if (_phoneMicBatchRestartInFlight) return;
    _phoneMicBatchRestartInFlight = true;
    try {
      await _startPhoneMicBatch(auto: SharedPreferencesUtil().phoneBatchAuto);
    } catch (e, st) {
      Logger.error('[CaptureProvider] batch restart after in-app call failed: $e\n$st');
    } finally {
      _phoneMicBatchRestartInFlight = false;
    }
  }

  bool _phoneMicRestartInFlight = false;
  bool _phoneMicBatchRestartInFlight = false;

  Future<void> _restartPhoneMicRecording() async {
    if (_phoneMicRestartInFlight) return;
    // A restart already in flight when the call started would otherwise hand the mic
    // straight back — the pause would hold for exactly as long as this await.
    if (_inAppCallHoldsMic) return;
    _phoneMicRestartInFlight = true;
    try {
      ServiceManager.instance().phoneMic.stop();
      // Re-assert interrupted so the recorder's stop callback doesn't overwrite it.
      updateRecordingState(RecordingState.interrupted);
      // _activeSource is cleared if the user manually stopped — bail in that case.
      if (_activeSource is! PhoneMicSource) return;
      // Use _resumeMicRecording (not streamRecording) to preserve existing socket/segments.
      await _resumeMicRecording();
    } catch (e, st) {
      Logger.error('[CaptureProvider] _restartPhoneMicRecording failed: $e\n$st');
    } finally {
      _phoneMicRestartInFlight = false;
    }
  }

  // Restarts mic only — preserves existing socket and conversation segments.
  Future<void> _resumeMicRecording() async {
    updateRecordingState(RecordingState.initialising);
    _activeSource = PhoneMicSource();
    _phoneMicWalActive = true;
    await ServiceManager.instance().phoneMic.start(
      onByteReceived: (bytes) {
        final frames = _activeSource?.processBytes(bytes) ?? [];
        for (final frame in frames) {
          _wal.getSyncs().phone.onFrameCaptured(frame);
          if (_socket?.state == SocketServiceState.connected) {
            _socket?.send(frame.payload);
            _wal.getSyncs().phone.markFrameSynced(frame.syncKey);
          }
        }
      },
      onRecording: () {
        updateRecordingState(RecordingState.record);
      },
      onStop: () {
        if (!_micInterrupted) {
          updateRecordingState(RecordingState.stop);
        }
      },
      onInitializing: () {
        updateRecordingState(RecordingState.initialising);
      },
      onStalled: _onMicStalled,
      onInterruption: _onMicInterruption,
    );
  }

  void _onMicStalled() {
    if (_activeSource is! PhoneMicSource) return;
    if (_micInterrupted) return; // silence during an interruption is expected
    if (recordingState == RecordingState.record ||
        recordingState == RecordingState.initialising ||
        recordingState == RecordingState.stop) {
      updateRecordingState(RecordingState.interrupted);
    }
    if (recordingState == RecordingState.interrupted) {
      _restartPhoneMicRecording();
    }
  }

  /// Foreground return hook for phone-mic capture (#4706).
  ///
  /// Native `appBecameActive` owns dead-engine rebuild. Dart only soft-rearms
  /// the stall clock so suspended timers don't false-trigger stop→start (which
  /// would race native recovery and restart a healthy session).
  void onAppResumed() {
    if (_activeSource is! PhoneMicSource && !_phoneMicBatchActive) return;
    if (_micInterrupted || _phoneMicRestartInFlight) return;
    ServiceManager.instance().phoneMic.probeStallAfterForeground();
  }

  void updateExternalActions(CaptureExternalActions? actions) {
    externalActions = actions ?? const NoopCaptureExternalActions();
    notifyListeners();
  }

  BtDevice? _recordingDevice;

  String? _getConversationSourceFromDevice() {
    return conversationSourceForDeviceType(_recordingDevice?.type);
  }

  ServerConversation? _conversation;
  List<TranscriptSegment> segments = [];
  List<ConversationPhoto> photos = [];

  /// Unix timestamp (seconds) when the current capture session started.
  /// Used to scope WAL queries to only this session's audio.
  int _sessionStartSeconds = 0;

  /// Stable identity for the active live-capture session. Unlike a transcript
  /// segment ID, this does not change when the backend revises or deletes
  /// segments during the capture.
  String? get activeCaptureSessionId => _sessionStartSeconds == 0 ? null : 'live-$_sessionStartSeconds';

  @visibleForTesting
  set testSessionStartSeconds(int v) => _sessionStartSeconds = v;

  /// Unix timestamp (seconds) when the current offline/batch device-recording
  /// session started. Set only in offline mode (the websocket path that sets
  /// [_sessionStartSeconds] is skipped there); drives the "captured so far"
  /// timer on the offline capture card. 0 when not offline-recording.
  int _offlineSessionStartSeconds = 0;
  int? get offlineRecordingStartedAt => _offlineSessionStartSeconds == 0 ? null : _offlineSessionStartSeconds;

  /// Wall-clock seconds when the current recording was muted, or null when not
  /// muted — the "captured so far" timer freezes at this point.
  int? _offlineMuteStartedAt;

  bool get offlineMuted => SharedPreferencesUtil().batchMuted;

  /// Elapsed seconds of the *current* recording for the capture-card timer:
  /// frozen while muted, and reset on each cut (manual or the 15-min rotation).
  int? get offlineRecordingElapsedSeconds {
    if (_offlineSessionStartSeconds == 0) return null;
    final end = _offlineMuteStartedAt ?? (DateTime.now().millisecondsSinceEpoch ~/ 1000);
    final secs = end - _offlineSessionStartSeconds;
    return secs < 0 ? 0 : secs;
  }

  int get _nowSeconds => DateTime.now().millisecondsSinceEpoch ~/ 1000;

  /// Mute/unmute Transcribe Later capture. The native writer drops packets while
  /// muted and resumes into the same recording; the card timer freezes meanwhile.
  void toggleOfflineMute() {
    if (SharedPreferencesUtil().batchMuted) {
      if (_offlineMuteStartedAt != null) {
        _offlineSessionStartSeconds += _nowSeconds - _offlineMuteStartedAt!;
        _offlineMuteStartedAt = null;
      }
      SharedPreferencesUtil().batchMuted = false;
    } else {
      _offlineMuteStartedAt = _nowSeconds;
      SharedPreferencesUtil().batchMuted = true;
    }
    notifyListeners();
  }

  /// Manually finalize the current recording and start a fresh one. The native
  /// writer cuts on the next packet; the timer resets immediately for feedback.
  void startNewOfflineRecording() {
    SharedPreferencesUtil().batchCutRequested = true;
    if (SharedPreferencesUtil().batchMuted) SharedPreferencesUtil().batchMuted = false;
    _offlineSessionStartSeconds = _nowSeconds;
    _offlineMuteStartedAt = null;
    notifyListeners();
  }

  void _onOfflineRecordingFinalized(String _) {
    if (_offlineSessionStartSeconds == 0) return;
    _offlineSessionStartSeconds = _nowSeconds;
    _offlineMuteStartedAt = SharedPreferencesUtil().batchMuted ? _nowSeconds : null;
    notifyListeners();
  }

  /// Preserved session start for auto-sync after socket-driven conversation completion.
  /// Set before _resetStateVariables() clears _sessionStartSeconds, consumed on ConversationEvent.
  int _pendingAutoSyncSessionStart = 0;

  /// Fallback timer that fires if ConversationEvent doesn't arrive within 30s.
  Timer? _autoSyncFallbackTimer;

  /// The conversation ID from ConversationProcessingStartedEvent, kept for fallback sync.
  String? _pendingAutoSyncConversationId;

  /// Future tracking the in-progress _finalizeAndStampSession(), so the next
  /// coordinated transfer wake cannot run before the durable stamp is ready.
  Future<void>? _pendingFinalizeAndStamp;

  /// Set in onClosed() when the socket drops during active device recording.
  /// Consumed in _initiateWebsocket() to trigger onNetworkSocketReconnected()
  /// on the device connection (e.g. Limitless re-sends enable-data-stream).
  bool _socketReconnectPending = false;

  /// How many transcription socket attempts are running, per configuration.
  /// The keep-alive timer's callback is async, so a tick could start the same
  /// attempt again before the previous one finished and open a duplicate
  /// /v4/listen session (issue #11305). Only an identical repeat is dropped:
  /// an attempt with different parameters is a new intent (starting phone mic,
  /// a codec change), and a forced one replaces the socket outright.
  final Map<String, int> _websocketInitInFlight = {};

  /// Returns unsynced WALs belonging to the current capture session.
  /// Empty when all frames have been streamed successfully (clean UI).
  List<Wal> get unsyncedSessionWals {
    if (_sessionStartSeconds == 0) return [];
    return _wal.getSyncs().phone.getSessionUnsyncedWals(_sessionStartSeconds);
  }

  /// Seconds of audio still in memory buffer (not yet chunked/flushed to disk).
  int get inFlightAudioSeconds => _wal.getSyncs().phone.getInFlightSeconds();

  // Version counter for segments/photos content changes. Incremented on in-place mutations
  // (e.g., translation updates, photo description changes) to signal UI rebuilds when
  // list length and last-text remain unchanged.
  int _segmentsPhotosVersion = 0;
  int get segmentsPhotosVersion => _segmentsPhotosVersion;
  Map<String, SpeakerLabelSuggestionEvent> suggestionsBySegmentId = {};
  List<String> taggingSegmentIds = [];

  bool hasTranscripts = false;

  StreamSubscription? _bleBytesStream;
  StreamSubscription? _blePhotoStream;

  get bleBytesStream => _bleBytesStream;

  StreamSubscription? _bleButtonStream;
  DateTime? _voiceCommandSession;
  List<List<int>> _commandBytes = [];
  bool _isProcessingButtonEvent = false; // Guard to prevent overlapping button operations
  Timer? _voiceCommandTimeoutTimer; // 30s auto-end timer for voice questions
  bool _voiceSessionStartedByLegacyLongPress =
      false; // Track if session was started by legacy long press (3) vs new toggle (1), TODO: remove this flag later

  StreamSubscription? _storageStream;

  get storageStream => _storageStream;

  RecordingState recordingState = RecordingState.stop;

  bool _isPaused = false;
  bool get isPaused => _isPaused;
  bool get isCallActive => _micInterrupted;

  // Flag to star the conversation when it ends
  bool _starOngoingConversation = false;
  bool get isConversationMarkedForStarring => _starOngoingConversation;

  void markConversationForStarring() {
    _starOngoingConversation = true;
    notifyListeners();
  }

  void unmarkConversationForStarring() {
    _starOngoingConversation = false;
    notifyListeners();
  }

  bool _transcriptServiceReady = false;

  // The transcript service readiness is driven solely by the socket lifecycle
  // (set true on subscribe, false on close). The `&& _isConnected` gate was
  // removed (#6311): ConnectivityService can flicker false during a WiFi↔cellular
  // handoff or a brief DNS hiccup even while the WebSocket is alive and segments
  // are flowing, which made the UI show "Recording, reconnecting" over healthy
  // transcription. The socket is the authoritative connectivity signal.
  bool get transcriptServiceReady => _transcriptServiceReady;

  // having a connected device or using the phone's mic for recording.
  // Includes `interrupted` so the keep-alive/reconnect path keeps running
  // while the phone mic is in a transiently-broken state (e.g., iOS audio
  // session interruption after an incoming call).
  bool get recordingDeviceServiceReady =>
      _recordingDevice != null ||
      recordingState == RecordingState.record ||
      recordingState == RecordingState.interrupted ||
      recordingState == RecordingState.systemAudioRecord;

  bool get havingRecordingDevice => _recordingDevice != null;

  BtDevice? get recordingDevice => _recordingDevice;

  void setHasTranscripts(bool value) {
    hasTranscripts = value;
    notifyListeners();
  }

  void setConversationCreating(bool value) {
    Logger.debug('set Conversation creating $value');
    // ConversationCreating = value;
    notifyListeners();
  }

  void _updateRecordingDevice(BtDevice? device) {
    Logger.debug('connected device changed from ${_recordingDevice?.id} to ${device?.id}');
    _recordingDevice = device;
    if (device == null) _endOfflineSession();
    notifyListeners();
  }

  void updateRecordingDevice(BtDevice? device) {
    _updateRecordingDevice(device);
  }

  Future _resetStateVariables() async {
    _stopInProgressConversationRefresh();
    segments = [];
    photos = [];
    hasTranscripts = false;
    _lastSegmentReceivedAt = null;
    suggestionsBySegmentId = {};
    _conversation = null;
    taggingSegmentIds = [];
    _sessionStartSeconds = 0;
    _endOfflineSession();
    notifyListeners();
  }

  void _endOfflineSession() {
    _offlineSessionStartSeconds = 0;
    _offlineMuteStartedAt = null;
    if (SharedPreferencesUtil().batchMuted) SharedPreferencesUtil().batchMuted = false;
    if (SharedPreferencesUtil().batchCutRequested) SharedPreferencesUtil().batchCutRequested = false;
  }

  Future<void> onRecordProfileSettingChanged() async {
    await _resetState();
  }

  static bool supportsTranscribeLater(DeviceType? type) {
    return type == DeviceType.omi ||
        type == DeviceType.openglass ||
        type == DeviceType.friendPendant ||
        type == DeviceType.limitless;
  }

  bool get deviceSupportsTranscribeLater => supportsTranscribeLater(_recordingDevice?.type);

  // The phone microphone can capture Transcribe Later (batch) audio where a
  // native recorder module exists — iOS (AVAudioEngine) and Android (AudioRecord).
  static bool get phoneMicSupportsTranscribeLater => Platform.isIOS || Platform.isAndroid;

  Future<bool> setBatchMode(bool enabled) async {
    if (SharedPreferencesUtil().batchModeEnabled == enabled) return true;
    // With batch on the realtime socket is suppressed for every device type, so a
    // device without a batch capture path would record nothing at all.
    if (enabled && _recordingDevice != null && !deviceSupportsTranscribeLater) {
      Logger.debug('[setBatchMode] refused: ${_recordingDevice?.type} has no Transcribe Later support');
      return false;
    }
    SharedPreferencesUtil().batchModeEnabled = enabled;
    PlatformManager.instance.analytics.transcribeLaterToggled(enabled: enabled);
    final docs = await getApplicationDocumentsDirectory();
    await SharedPreferencesUtil().saveString('batchAudioDir', docs.path);
    // Only re-enable native streaming when turning batch OFF, a device with a
    // native BLE route is connected, and background mode is opted in.
    final enableNativeStreaming = _shouldEnableNativeBackgroundStreaming;
    await SharedPreferencesUtil().saveBool('nativeBleStreamingEnabled', enableNativeStreaming);
    await _applyLimitlessRealtimeSuppression(enabled);
    notifyListeners();
    // A phone-mic session's mode is fixed at start, so a mid-session toggle
    // must roll the session into a fresh one — otherwise _resetState() tears
    // the socket down under a still-running Live session (no transcript, audio
    // silently diverted to the offline WAL) and the UI keeps the Live card.
    final phoneMicSessionActive = _phoneMicBatchActive || _activeSource is PhoneMicSource;
    if (phoneMicSessionActive) {
      try {
        await stopStreamRecording();
        await streamRecording();
      } catch (e, st) {
        Logger.error('[CaptureProvider] mode-switch session roll failed: $e\n$st');
      }
      return true;
    }
    try {
      await onRecordProfileSettingChanged();
    } catch (_) {}
    return true;
  }

  Future<void> _applyLimitlessRealtimeSuppression(bool suppressed) async {
    final device = _recordingDevice;
    if (device == null || device.type != DeviceType.limitless) return;
    try {
      final connection = await ServiceManager.instance().device.ensureConnection(device.id);
      if (connection is LimitlessDeviceConnection) {
        await connection.setRealtimeAudioSuppressed(suppressed);
      }
    } catch (e) {
      Logger.debug('[batch] limitless realtime suppression toggle failed: $e');
    }
  }

  // Interactive device onboarding needs the realtime transcript + voice paths, which Transcribe
  // Later (batch mode) disables. Flipping batchModeEnabled off also re-opens the native->Dart audio
  // forward — the native BatchAudioWriter gate reads this same pref — so BLE audio reaches Dart again.
  // Skips the transcribeLaterToggled analytic on purpose; the persisted flag drives a crash-safe restore.
  Future<void> suspendBatchModeForOnboarding() async {
    if (SharedPreferencesUtil().batchModeSuspendedForOnboarding) return;
    if (!SharedPreferencesUtil().batchModeEnabled) return;
    SharedPreferencesUtil().batchModeSuspendedForOnboarding = true;
    SharedPreferencesUtil().batchModeEnabled = false;
    await _applyLimitlessRealtimeSuppression(false);
    notifyListeners();
    try {
      await onRecordProfileSettingChanged();
    } catch (_) {}
  }

  Future<void> restoreBatchModeAfterOnboarding() async {
    if (!SharedPreferencesUtil().batchModeSuspendedForOnboarding) return;
    SharedPreferencesUtil().batchModeSuspendedForOnboarding = false;
    SharedPreferencesUtil().batchModeEnabled = true;
    await _applyLimitlessRealtimeSuppression(true);
    notifyListeners();
    try {
      await onRecordProfileSettingChanged();
    } catch (_) {}
  }

  /// Called when transcription settings are changed (e.g., custom STT provider)
  /// This resets the socket connection to use the new configuration
  Future<void> onTranscriptionSettingsChanged() async {
    Logger.debug("Transcription settings changed, refreshing socket connection...");
    await _reconcileNativeBackgroundStreamingPolicy();

    // Handle device recording
    if (_recordingDevice != null) {
      await _socket?.stop(reason: 'transcription settings changed');
      BleAudioCodec codec = await _getAudioCodec(_recordingDevice!.id);
      await _initiateWebsocket(audioCodec: codec, force: true, source: _getConversationSourceFromDevice());
      return;
    }

    // Handle phone mic recording
    if (recordingState == RecordingState.record) {
      await _socket?.stop(reason: 'transcription settings changed');
      await _initiateWebsocket(
        audioCodec: BleAudioCodec.pcm16,
        sampleRate: 16000,
        force: true,
        source: ConversationSource.phone.name,
      );
      return;
    }
  }

  Future<void> changeAudioRecordProfile({
    required BleAudioCodec audioCodec,
    int? sampleRate,
    int? channels,
    bool? isPcm,
    String? source,
  }) async {
    await _resetState();
    await _initiateWebsocket(
      audioCodec: audioCodec,
      sampleRate: sampleRate,
      channels: channels,
      isPcm: isPcm,
      source: source,
    );
  }

  Future<void> _initiateWebsocket({
    required BleAudioCodec audioCodec,
    int? sampleRate,
    int? channels,
    bool? isPcm,
    bool force = false,
    String? source,
  }) async {
    // Resolve the defaults here so two callers that spell the same
    // configuration differently (null vs the value it defaults to) share a key.
    final effectiveSampleRate = sampleRate ?? mapCodecToSampleRate(audioCodec);
    final effectiveChannels =
        channels ?? ((audioCodec == BleAudioCodec.pcm16 || audioCodec == BleAudioCodec.pcm8) ? 1 : 2);
    final attemptKey = '$audioCodec|$effectiveSampleRate|$effectiveChannels|$isPcm|$source';

    // A new attempt is reaching for fresh credentials, so let it run; if the
    // server refuses again, onClosed re-arms the block on its own.
    _transcriptionAuthRejection = null;

    if (!force && _websocketInitInFlight.containsKey(attemptKey)) {
      Logger.debug('initiateWebsocket skipped - an identical connection attempt is already in flight');
      return;
    }
    // Counted, because a forced attempt can share the key of the non-forced one
    // it is replacing; whichever finishes first must not ungate the other.
    _websocketInitInFlight.update(attemptKey, (running) => running + 1, ifAbsent: () => 1);
    try {
      await _connectTranscriptionSocket(
        audioCodec: audioCodec,
        sampleRate: effectiveSampleRate,
        channels: effectiveChannels,
        isPcm: isPcm,
        force: force,
        source: source,
      );
    } finally {
      final running = (_websocketInitInFlight[attemptKey] ?? 1) - 1;
      if (running > 0) {
        _websocketInitInFlight[attemptKey] = running;
      } else {
        _websocketInitInFlight.remove(attemptKey);
      }
    }
  }

  /// Opens the transcription socket. Overridden in tests to control the timing
  /// of an attempt; production always goes through the socket service pool.
  @visibleForTesting
  Future<TranscriptSegmentSocketService?> openConversationSocket({
    required BleAudioCodec codec,
    required int sampleRate,
    required String language,
    required bool force,
    String? source,
    CustomSttConfig? customSttConfig,
  }) {
    return ServiceManager.instance().socket.conversation(
      codec: codec,
      sampleRate: sampleRate,
      language: language,
      force: force,
      source: source,
      customSttConfig: customSttConfig,
    );
  }

  Future<void> _connectTranscriptionSocket({
    required BleAudioCodec audioCodec,
    required int sampleRate,
    required int channels,
    bool? isPcm,
    bool force = false,
    String? source,
  }) async {
    Logger.debug('initiateWebsocket in capture_provider');

    // Batch (offline) mode: never open the realtime transcription socket. The
    // native layer stores incoming BLE audio to local .bin files instead, and
    // the user uploads recordings later. See _saveNativeBleStreamConfig.
    if (SharedPreferencesUtil().batchModeEnabled) {
      Logger.debug('Batch mode enabled — skipping transcription websocket');
      return;
    }

    BleAudioCodec codec = audioCodec;

    Logger.debug('is ws null: ${_socket == null}');
    Logger.debug('Initiating WebSocket with: codec=$codec, sampleRate=$sampleRate, channels=$channels, isPcm=$isPcm');

    // Get language and custom STT config
    String language = SharedPreferencesUtil().hasSetPrimaryLanguage
        ? SharedPreferencesUtil().userPrimaryLanguage
        : "multi";
    final customSttConfig = SharedPreferencesUtil().customSttConfig;

    Logger.debug('Custom STT enabled: ${customSttConfig.isEnabled}, provider: ${customSttConfig.provider}');

    // Check codec compatibility for custom STT - fallback to default if incompatible
    CustomSttConfig? effectiveConfig = customSttConfig.isEnabled ? customSttConfig : null;
    if (effectiveConfig != null && !TranscriptSocketServiceFactory.isCodecSupportedForCustomStt(codec)) {
      if (TranscriptSocketServiceFactory.shouldBlockUnsupportedCodecFallback(codec, effectiveConfig)) {
        Logger.warning(
          '[CustomSTT] Codec $codec is unsupported; refusing Omi fallback because raw audio forwarding is disabled',
        );
        final previousSocket = _socket;
        _socket = null;
        _transcriptServiceReady = false;
        try {
          await previousSocket?.stop(reason: 'unsupported custom STT codec with raw audio forwarding disabled');
        } catch (e, stack) {
          Logger.error('[CustomSTT] Failed to stop the previous socket after blocking Omi fallback: $e\n$stack');
        }
        await _reconcileNativeBackgroundStreamingPolicy();
        notifyListeners();
        _startKeepAliveServices();
        return;
      }
      Logger.debug('[CustomSTT] Codec $codec not supported, falling back to Omi');
      effectiveConfig = null;
    }

    // Connect to the transcript socket
    _socket = await openConversationSocket(
      codec: codec,
      sampleRate: sampleRate,
      language: language,
      force: force,
      source: source,
      customSttConfig: effectiveConfig,
    );
    if (_socket == null) {
      _startKeepAliveServices();
      Logger.debug("Can not create new conversation socket");
      return;
    }
    _socket?.subscribe(this, this);
    _transcriptServiceReady = true;
    // A fresh socket has produced nothing yet — don't let segments from before
    // the reconnect/config change keep the "live transcription" status green.
    _lastSegmentReceivedAt = null;
    if (_sessionStartSeconds == 0) {
      _sessionStartSeconds = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    }

    // Notify the device connection that the socket reconnected after a network
    // outage so it can re-enable streaming if needed (e.g. Limitless pendant).
    // Guard on deviceRecord: skip if the user has paused — no point waking the
    // device when _bleBytesStream is cancelled and audio would just be dropped.
    if (_socketReconnectPending && _recordingDevice != null && recordingState == RecordingState.deviceRecord) {
      _socketReconnectPending = false;
      final conn = await ServiceManager.instance().device.ensureConnection(_recordingDevice!.id);
      await conn?.onNetworkSocketReconnected();
    }

    await _loadInProgressConversation();
    await _drainNativeBleTranscriptMessages();
    _startInProgressConversationRefresh();

    notifyListeners();
  }

  void _processVoiceCommandBytes(String deviceId, List<List<int>> data) async {
    if (data.isEmpty) {
      Logger.debug("voice frames is empty");
      return;
    }

    if (_recordingDevice == null) {
      Logger.debug("Recording device is null, cannot process voice command");
      return;
    }

    BleAudioCodec codec = await _getAudioCodec(_recordingDevice!.id);
    await externalActions.sendVoiceMessageStreamToServer(
      data,
      onFirstChunkRecived: () {
        _playSpeakerHaptic(deviceId, 2);
      },
      codec: codec,
      // Device-button voice → speak the reply aloud (BG/lock-screen safe).
      // Gated by SharedPreferencesUtil().voiceResponseEnabled inside the service.
      playResponseAudio: true,
    );
  }

  // Start a 15s timeout timer for voice commands - auto-ends if user forgets to tap again
  void _startVoiceCommandTimeout(String deviceId) {
    _voiceCommandTimeoutTimer?.cancel();
    _voiceCommandTimeoutTimer = Timer(const Duration(seconds: 15), () {
      debugPrint("Voice command timeout - auto-ending session after 15s");
      if (_voiceCommandSession != null) {
        _endVoiceCommandSession(deviceId);
      }
    });
  }

  // End voice command session and process the collected audio
  void _endVoiceCommandSession(String deviceId) {
    _voiceCommandTimeoutTimer?.cancel();
    _voiceCommandTimeoutTimer = null;
    _voiceCommandSession = null;
    _voiceSessionStartedByLegacyLongPress = false; // Reset flag
    var data = List<List<int>>.from(_commandBytes);
    _commandBytes = [];
    _processVoiceCommandBytes(deviceId, data);
    if (SharedPreferencesUtil().pttHubEnabled && hubTurnDriver != null) {
      hubTurnDriver!.end();
    }
  }

  // Single tap (buttonState == 1) - toggle voice question mode.
  // Tap once to start, tap again to end. Extracted from the BLE button
  // listener closure so it's directly unit-testable without a real BLE
  // stream (see `capture_controller_hub_test.dart`).
  @visibleForTesting
  void handleSingleTapButtonEvent(String deviceId) {
    debugPrint("Single tap detected");
    // Self-host (просьба Игоря 24.08): одиночное нажатие настраивается — как
    // двойное. Вариант 1 = свободный голосовой режим (тот же тумблер, что у
    // doubleTapAction=3): прежний «голосовой вопрос Omi» Игорь не использует,
    // а конфликт «хотел двойной тап — сработал одиночный» при этом исчезает:
    // оба жеста делают одно и то же.
    if (SharedPreferencesUtil().singleTapAction == 1) {
      HapticFeedback.mediumImpact();
      if (freeFormModeActive.value) {
        PlatformManager.instance.analytics.omiDoubleTap(feature: 'voice_mode_stop_single_tap');
        stopFreeFormVoiceMode();
      } else {
        PlatformManager.instance.analytics.omiDoubleTap(feature: 'voice_mode_start_single_tap');
        startFreeFormVoiceMode().catchError((Object e) {
          Logger.error('[VoiceMode] запуск с кулона (одиночный тап) не удался: $e');
        });
      }
      return;
    }
    if (_voiceCommandSession == null) {
      // Start voice question session (new toggle mode)
      debugPrint("Starting voice question session (toggle mode)");
      // Cut off any in-flight voice playback from a prior reply so the
      // new recording starts clean.
      if (OmiVoicePlaybackService.instance.isSpeaking) {
        OmiVoicePlaybackService.instance.interrupt();
      }
      _voiceCommandSession = DateTime.now();
      _commandBytes = [];
      _voiceSessionStartedByLegacyLongPress = false; // New toggle mode
      _startVoiceCommandTimeout(deviceId);
      _playSpeakerHaptic(deviceId, 1);
      // NOT while the free-form voice mode is running. The two paths own
      // SEPARATE `HubController`s (see `hubTurnDriver`/`freeFormVoiceMode`
      // above), so starting a hub turn here would open a SECOND Gemini Live
      // socket on top of the conversation already in progress. Two sockets
      // are two microphones and two brains hearing the same room, answering
      // over each other, and billed twice — that alone is reason enough, and
      // it is the whole reason. The gate does NOT rest on the server killing
      // one of them.
      //
      // Worth stating because the first version of this comment said it did.
      // On 24.08 a second socket twice appeared on this key by accident and
      // the server closed the longer-lived one with 1011 "Resource has been
      // exhausted", which read like a rule. It is not one: the probe written
      // to check it (`marathon/probes/lane5-concurrent-sockets.py`) ran two
      // sockets on one key both idle (540s) and both holding a real spoken
      // conversation with server VAD (360s, the model answering 8 and 7 times
      // respectively) — nothing was evicted either time. Whatever the two
      // accidents were, they are not "a second socket hangs up the first". Even where both survive, it is two
      // microphones and two brains hearing the same room, billed twice.
      //
      // The tap is not swallowed: the legacy voice-command session above
      // still starts, exactly as it does when the hub route is off. Only the
      // second socket is withheld. `end()` below stays unconditional — a turn
      // begun BEFORE the mode was switched on must still be closed, and
      // `VoiceHubTurnDriver.end()` is a no-op with no turn in flight.
      if (SharedPreferencesUtil().pttHubEnabled && hubTurnDriver != null && !freeFormModeActive.value) {
        hubTurnDriver!.begin();
      }
    } else if (!_voiceSessionStartedByLegacyLongPress) {
      // Only end on second tap if session was started by toggle mode (not legacy)
      debugPrint("Ending voice question session (toggle mode)");
      _endVoiceCommandSession(deviceId);
    }
  }

  Future streamButton(String deviceId) async {
    Logger.debug('streamButton in capture_provider');
    _bleButtonStream?.cancel();
    _bleButtonStream = await _getBleButtonListener(
      deviceId,
      onButtonReceived: (List<int> value) {
        final snapshot = List<int>.from(value);
        if (snapshot.isEmpty || snapshot.length < 4) return;
        var buttonState = ByteData.view(Uint8List.fromList(snapshot.sublist(0, 4).reversed.toList()).buffer)
            .getUint32(0);
        Logger.debug("device button $buttonState");

        // Intercept for interactive device onboarding
        if (deviceOnboardingProvider?.isOnboardingActive == true) {
          deviceOnboardingProvider!.onButtonEvent(buttonState);
          // For step 1 (ask question), let single-tap fall through to normal voice command handling
          if (deviceOnboardingProvider!.currentStep == 1 && buttonState == 1) {
            // Fall through to normal single-tap handling below
          } else {
            return;
          }
        }

        // double tap
        if (buttonState == 2) {
          Logger.debug("Double tap detected");

          // Guard: ignore if already processing a button event
          if (_isProcessingButtonEvent) {
            Logger.debug("Double tap: already processing, ignoring");
            return;
          }

          int doubleTapAction = SharedPreferencesUtil().doubleTapAction;

          if (doubleTapAction == 1) {
            // Pause/resume recording
            Logger.debug("Double tap: toggling pause/mute");
            _isProcessingButtonEvent = true;
            if (_isPaused) {
              PlatformManager.instance.analytics.omiDoubleTap(feature: 'unmute');
              resumeDeviceRecording()
                  .then((_) {
                    _isProcessingButtonEvent = false;
                  })
                  .catchError((e) {
                    Logger.debug("Error resuming device recording: $e");
                    _isProcessingButtonEvent = false;
                  });
            } else {
              PlatformManager.instance.analytics.omiDoubleTap(feature: 'mute');
              pauseDeviceRecording()
                  .then((_) {
                    _isProcessingButtonEvent = false;
                  })
                  .catchError((e) {
                    Logger.debug("Error pausing device recording: $e");
                    _isProcessingButtonEvent = false;
                  });
            }
          } else if (doubleTapAction == 2) {
            // Star ongoing conversation (doesn't end it)
            Logger.debug("Double tap: marking conversation for starring");
            if (!_starOngoingConversation) {
              markConversationForStarring();
              PlatformManager.instance.analytics.omiDoubleTap(feature: 'star_conversation');
              // Haptic feedback to confirm
              HapticFeedback.mediumImpact();
            } else {
              // Toggle off if already marked
              unmarkConversationForStarring();
              PlatformManager.instance.analytics.omiDoubleTap(feature: 'unstar_conversation');
              HapticFeedback.lightImpact();
            }
          } else if (doubleTapAction == 3) {
            // Self-host (просьба Игоря 24.08): двойной тап = голосовой режим —
            // начать разговор с кулона, не доставая телефон. Работает и с
            // заблокированным экраном: событие приходит по BLE в живой
            // foreground-сервис, микрофонный FGS-тип в манифесте есть, звук
            // идёт через гарнитуру (VoiceRouteCoordinator). Выключение — сам
            // (end_conversation по «пока»), сторожем тишины или повторным
            // двойным тапом.
            Logger.debug("Double tap: toggling free-form voice mode");
            HapticFeedback.mediumImpact();
            if (freeFormModeActive.value) {
              PlatformManager.instance.analytics.omiDoubleTap(feature: 'voice_mode_stop');
              stopFreeFormVoiceMode();
            } else {
              PlatformManager.instance.analytics.omiDoubleTap(feature: 'voice_mode_start');
              startFreeFormVoiceMode().catchError((Object e) {
                Logger.error('[VoiceMode] запуск с кулона не удался: $e');
              });
            }
          } else if (doubleTapAction == 4) {
            // Self-host (просьба Игоря 24.08): аварийная кнопка «Завершить
            // голосовой режим» — выключить разговор, НЕ прощаясь с нейронкой.
            // Только стоп: если режим не активен, ничего не делает.
            Logger.debug("Double tap: force-stopping free-form voice mode");
            if (freeFormModeActive.value) {
              HapticFeedback.mediumImpact();
              PlatformManager.instance.analytics.omiDoubleTap(feature: 'voice_mode_force_stop');
              stopFreeFormVoiceMode();
            }
          } else {
            // End conversation and process (default)
            Logger.debug("Double tap: processing conversation");
            PlatformManager.instance.analytics.omiDoubleTap(feature: 'process_conversation');
            forceProcessingCurrentConversation();
          }
          return;
        }

        // Single tap (buttonState == 1) - toggle voice question mode
        // Tap once to start, tap again to end
        if (buttonState == 1) {
          handleSingleTapButtonEvent(deviceId);
          return;
        }

        // Legacy support: start long press (for voice commands) - older firmware
        if (buttonState == 3 && _voiceCommandSession == null) {
          debugPrint("Legacy: Long press start detected");
          _voiceCommandSession = DateTime.now();
          _commandBytes = [];
          _voiceSessionStartedByLegacyLongPress = true; // Legacy hold-to-talk mode
          _startVoiceCommandTimeout(deviceId);
          _playSpeakerHaptic(deviceId, 1);
        }

        // Legacy support: release (end voice command) - older firmware
        // Only end on release if session was started by legacy long press (buttonState 3)
        if (buttonState == 5 && _voiceCommandSession != null && _voiceSessionStartedByLegacyLongPress) {
          debugPrint("Legacy: Release detected - ending voice command");
          _endVoiceCommandSession(deviceId);
        }
      },
    );
  }

  Future<bool> streamAudioToWs(String deviceId, BleAudioCodec codec) async {
    Logger.debug('streamAudioToWs in capture_provider');
    _bleBytesStream?.cancel();
    _startMetricsTracking();
    final subscription = await _getBleAudioBytesListener(
      deviceId,
      onAudioBytesReceived: (List<int> value) {
        final snapshot = List<int>.from(value);
        if (snapshot.isEmpty || snapshot.length < 3) return;

        // Track bytes received from BLE
        _metrics.addBleBytes(snapshot.length);

        // Command button triggered
        bool voiceCommandSupported = _recordingDevice != null
            ? (_recordingDevice?.type == DeviceType.omi || _recordingDevice?.type == DeviceType.openglass)
            : false;
        if (_voiceCommandSession != null && voiceCommandSupported) {
          final payload = _activeSource?.getSocketPayload(snapshot) ?? snapshot.sublist(3);
          _commandBytes.add(payload);
        }

        // Local storage syncs. In batch mode the native layer owns writing the
        // .bin files, so the Dart WAL writer must stay off to avoid double-writes.
        var checkWalSupported =
            !SharedPreferencesUtil().batchModeEnabled &&
            (_recordingDevice?.type == DeviceType.omi || _recordingDevice?.type == DeviceType.openglass) &&
            codec.isOpusSupported() &&
            (_socket?.state != SocketServiceState.connected || SharedPreferencesUtil().unlimitedLocalStorageEnabled);
        if (checkWalSupported != _isWalSupported) {
          setIsWalSupported(checkWalSupported);
        }

        // Process bytes through audio source and feed to WAL
        final frames = _activeSource?.processBytes(snapshot) ?? [];
        if (_isWalSupported) {
          for (final frame in frames) {
            _wal.getSyncs().phone.onFrameCaptured(frame);
          }
        }

        // Send WS
        if (_socket?.state == SocketServiceState.connected) {
          final socketPayload = _activeSource?.getSocketPayload(snapshot) ?? snapshot;
          _socket?.send(socketPayload);

          // Track bytes sent to websocket
          _metrics.addSocketBytes(socketPayload.length);

          // Mark frames as synced
          if (_isWalSupported) {
            for (final frame in frames) {
              _wal.getSyncs().phone.markFrameSynced(frame.syncKey);
            }
          }
        }
      },
    );
    _bleBytesStream = subscription;
    notifyListeners();
    return subscription != null;
  }

  Future<void> _resetState() async {
    Logger.debug('resetState');
    await _cleanupCurrentState();

    // Always try to stream audio if a device is present
    await _ensureDeviceSocketConnection();
    await _initiateDeviceAudioStreaming();

    // Additionally, stream photos if the device supports it
    if (_recordingDevice != null) {
      var connection = await ServiceManager.instance().device.ensureConnection(_recordingDevice!.id);
      if (connection != null && await connection.hasPhotoStreamingCharacteristic()) {
        await _initiateDevicePhotoStreaming();
      }
    }

    notifyListeners();
  }

  Future _cleanupCurrentState({bool disableNativeBackground = false}) async {
    _socketReconnectPending = false;
    _stopInProgressConversationRefresh();
    await _closeBleStream(disableNativeBackground: disableNativeBackground);
    _activeSource = null;
    notifyListeners();
  }

  Future<BleAudioCodec> _getAudioCodec(String deviceId) async {
    if (_audioCodecLoader != null) return _audioCodecLoader!(deviceId);
    var connection = await ServiceManager.instance().device.ensureConnection(deviceId);
    if (connection == null) {
      return BleAudioCodec.pcm8;
    }
    return connection.getAudioCodec();
  }

  Future<bool> _playSpeakerHaptic(String deviceId, int level) async {
    var connection = await ServiceManager.instance().device.ensureConnection(deviceId);
    if (connection == null) {
      return false;
    }
    return connection.performPlayToSpeakerHaptic(level);
  }

  Future<StreamSubscription?> _getBleAudioBytesListener(
    String deviceId, {
    required void Function(List<int>) onAudioBytesReceived,
  }) async {
    var connection = await ServiceManager.instance().device.ensureConnection(deviceId);
    if (connection == null) {
      return Future.value(null);
    }
    return connection.getBleAudioBytesListener(onAudioBytesReceived: onAudioBytesReceived);
  }

  Future<StreamSubscription?> _getBleButtonListener(
    String deviceId, {
    required void Function(List<int>) onButtonReceived,
  }) async {
    var connection = await ServiceManager.instance().device.ensureConnection(deviceId);
    if (connection == null) {
      return Future.value(null);
    }
    return connection.getBleButtonListener(onButtonReceived: onButtonReceived);
  }

  Future<void> _ensureDeviceSocketConnection() async {
    if (_recordingDevice == null) {
      return;
    }
    BleAudioCodec codec = await _getAudioCodec(_recordingDevice!.id);
    var language = SharedPreferencesUtil().hasSetPrimaryLanguage
        ? SharedPreferencesUtil().userPrimaryLanguage
        : "multi";
    final customSttConfig = SharedPreferencesUtil().customSttConfig;
    final sttConfigId = customSttConfig.sttConfigId;

    if (language != _socket?.language ||
        codec != _socket?.codec ||
        _socket?.state != SocketServiceState.connected ||
        _socket?.sttConfigId != sttConfigId) {
      await _initiateWebsocket(audioCodec: codec, force: true, source: _getConversationSourceFromDevice());
    }
  }

  Future<void> _initiateDeviceAudioStreaming() async {
    final device = _recordingDevice;
    if (device == null) {
      return;
    }
    final deviceId = device.id;
    if (deviceId.isEmpty) {
      return;
    }
    final connection = await ServiceManager.instance().device.ensureConnection(deviceId);
    if (connection == null) return;
    final codec = await _getAudioCodec(deviceId);
    await _wal.getSyncs().phone.onAudioCodecChanged(codec);
    await _saveNativeBleStreamConfig(device, codec);

    // Create audio source for BLE device
    final pd = await device.getDeviceInfo(connection);
    final deviceModel = pd.modelNumber.isNotEmpty ? pd.modelNumber : "Omi";
    if (device.type == DeviceType.omi || device.type == DeviceType.openglass) {
      _activeSource = BleDeviceSource(codec: codec, deviceId: deviceId, deviceModel: deviceModel);
    }
    _wal.getSyncs().phone.setDeviceInfo(deviceId, deviceModel);

    await streamButton(deviceId);
    final foregroundAudioReady = await streamAudioToWs(deviceId, codec);
    if (foregroundAudioReady) {
      await SharedPreferencesUtil().saveBool('nativeBleForegroundReady', true);
    }

    // Update state (limitless is excluded: the pendant records on-device, so the
    // capture card is driven by its stored-page count, not a live phone timer)
    if (SharedPreferencesUtil().batchModeEnabled &&
        _recordingDevice?.type != DeviceType.limitless &&
        _offlineSessionStartSeconds == 0) {
      _offlineSessionStartSeconds = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      _offlineMuteStartedAt = null;
      if (SharedPreferencesUtil().batchMuted) SharedPreferencesUtil().batchMuted = false;
    }
    updateRecordingState(RecordingState.deviceRecord);
    notifyListeners();
  }

  Future<void> _saveNativeBleStreamConfig(BtDevice device, BleAudioCodec codec) async {
    final audioTarget = _nativeBleAudioTarget(device);
    if (audioTarget == null) {
      // No native route — clear all background/streaming state and stale config.
      Logger.debug(
        '[saveNativeBleStreamConfig] no native BLE route for device ${device.id} type=${device.type} — clearing state',
      );
      await SharedPreferencesUtil().saveBool('nativeBleForegroundReady', false);
      await SharedPreferencesUtil().saveBool('nativeBleStreamingEnabled', false);
      SharedPreferencesUtil().backgroundModeEnabled = false;
      await SharedPreferencesUtil().remove('nativeBleStreamConfig');
      return;
    }

    await SharedPreferencesUtil().saveString(
      'nativeBleStreamConfig',
      jsonEncode({
        'deviceId': device.id,
        'codec': codec.toString(),
        'sampleRate': mapCodecToSampleRate(codec),
        'source': _getConversationSourceFromDevice(),
        'apiBaseUrl': Env.apiBaseUrl ?? 'https://api.omiapi.com/',
        'serviceUuid': audioTarget.key,
        'characteristicUuid': audioTarget.value,
        'deviceType': device.type.name,
      }),
    );
    // Batch (offline) capture: tell the native writer where to store .bin files
    // and ensure the native realtime socket is disabled while batch mode is on
    // (batch mode takes precedence over background streaming).
    final batchMode = SharedPreferencesUtil().batchModeEnabled;
    final docsDir = await getApplicationDocumentsDirectory();
    await SharedPreferencesUtil().saveString('batchAudioDir', docsDir.path);

    await SharedPreferencesUtil().saveBool('nativeBleForegroundReady', false);
    await SharedPreferencesUtil().saveBool('nativeBleStreamingEnabled', _shouldEnableNativeBackgroundStreaming);
    Logger.debug(
      '[batch] config saved: batchMode=$batchMode dir=${docsDir.path} '
      'deviceId=${device.id} svc=${audioTarget.key} char=${audioTarget.value} type=${device.type.name}',
    );
  }

  MapEntry<String, String>? _nativeBleAudioTarget(BtDevice device) {
    switch (device.type) {
      case DeviceType.omi:
      case DeviceType.openglass:
        return const MapEntry(omiServiceUuid, audioDataStreamCharacteristicUuid);
      case DeviceType.friendPendant:
        return const MapEntry(friendPendantServiceUuid, friendPendantAudioCharacteristicUuid);
      case DeviceType.limitless:
        return const MapEntry(limitlessServiceUuid, limitlessRxCharUuid);
      case DeviceType.appleWatch:
      case DeviceType.bee:
      case DeviceType.fieldy:
      case DeviceType.plaud:
      // Ray-Ban Meta audio is bridged from the platform HFP route, so there is
      // no native BLE GATT target; capture runs on the foreground Dart path.
      case DeviceType.raybanMeta:
        return null;
    }
  }

  /// Whether the currently-connected recording device has a concrete native BLE
  /// audio route that the Background Mode / native streaming layer can use.
  /// Returns false for device types with no native route (Apple Watch, Bee,
  /// Fieldy, Limitless, Plaud) and for empty-device-id sentinel entries
  /// that may linger in preferences from stale state.
  @visibleForTesting
  bool get hasNativeBleAudioRoute {
    final device = _recordingDevice;
    if (device == null) return false;
    if (device.id.isEmpty) return false;
    return _nativeBleAudioTarget(device) != null;
  }

  /// Background Mode's native realtime streamer supports a subset of the routed
  /// devices: limitless has a route for batch capture (flash drain), but its
  /// background streaming lands with the native drain engine follow-up.
  bool get hasNativeBackgroundStreamRoute => hasNativeBleAudioRoute && _recordingDevice?.type != DeviceType.limitless;

  bool get _nativeOmiRawAudioAllowed {
    final config = SharedPreferencesUtil().customSttConfig;
    return !config.isEnabled || config.sendRawAudioToOmi;
  }

  bool get _shouldEnableNativeBackgroundStreaming =>
      !SharedPreferencesUtil().batchModeEnabled &&
      hasNativeBackgroundStreamRoute &&
      SharedPreferencesUtil().backgroundModeEnabled &&
      _nativeOmiRawAudioAllowed;

  Future<void> _reconcileNativeBackgroundStreamingPolicy() async {
    await SharedPreferencesUtil().saveBool('nativeBleStreamingEnabled', _shouldEnableNativeBackgroundStreaming);
  }

  /// Enable or disable Background Mode through CaptureProvider so the provider
  /// can validate against the actual native BLE route before committing prefs.
  ///
  /// Returns `true` if the change was accepted, `false` if rejected (e.g. no
  /// connected device or the device lacks a native BLE audio route).
  ///
  /// When disabling: clears `backgroundModeEnabled`, `nativeBleStreamingEnabled`,
  /// and `nativeBleForegroundReady`. It keeps `nativeBleStreamConfig` only when
  /// batch mode is still enabled and the current device has a valid native route,
  /// because native batch writers use the same config for offline capture.
  ///
  /// When enabling with no concrete device or no native route: rejects the
  /// change and leaves all prefs false / removes stale config.
  ///
  /// When enabling with a valid route: sets global opt-in and enables effective
  /// native streaming only when batch mode is off.
  Future<bool> setBackgroundModeEnabled(bool requested) async {
    if (!requested) {
      // Disable realtime background streaming. Preserve nativeBleStreamConfig
      // whenever Transcribe Later remains enabled; batch capture uses the same
      // config for offline audio and may need it even while no route is
      // currently live. Reconnect/setup paths will refresh it when needed.
      final keepBatchConfig = SharedPreferencesUtil().batchModeEnabled;
      SharedPreferencesUtil().backgroundModeEnabled = false;
      await SharedPreferencesUtil().saveBool('nativeBleStreamingEnabled', false);
      await SharedPreferencesUtil().saveBool('nativeBleForegroundReady', false);
      if (!keepBatchConfig) {
        await SharedPreferencesUtil().remove('nativeBleStreamConfig');
      }
      Logger.debug('[BackgroundMode] disabled — keepBatchConfig=$keepBatchConfig');
      notifyListeners();
      return true;
    }

    // Enable: must have a concrete device the native streamer supports.
    if (!hasNativeBackgroundStreamRoute) {
      Logger.debug(
        '[BackgroundMode] enable rejected — no device with native BLE route '
        '(device=${_recordingDevice?.id}, type=${_recordingDevice?.type})',
      );
      // Defensive: ensure prefs stay false and remove any stale config.
      SharedPreferencesUtil().backgroundModeEnabled = false;
      await SharedPreferencesUtil().saveBool('nativeBleStreamingEnabled', false);
      await SharedPreferencesUtil().saveBool('nativeBleForegroundReady', false);
      await SharedPreferencesUtil().remove('nativeBleStreamConfig');
      notifyListeners();
      return false;
    }

    // Valid route — enable and recreate the native config immediately. A user
    // can toggle Background Mode off and back on without reconnecting; in that
    // case the disable/reject paths may have removed nativeBleStreamConfig and
    // the native background streamer cannot start from nativeBleStreamingEnabled
    // alone.
    SharedPreferencesUtil().backgroundModeEnabled = true;
    final device = _recordingDevice!;
    final codec = await _getAudioCodec(device.id);
    final wasForegroundReady = SharedPreferencesUtil().getBool('nativeBleForegroundReady');
    await _saveNativeBleStreamConfig(device, codec);
    if (wasForegroundReady) {
      await SharedPreferencesUtil().saveBool('nativeBleForegroundReady', true);
    }
    Logger.debug(
      '[BackgroundMode] enabled — device ${device.id} '
      'type=${device.type}, batchMode=${SharedPreferencesUtil().batchModeEnabled}',
    );
    notifyListeners();
    return true;
  }

  Future<void> _initiateDevicePhotoStreaming() async {
    if (_recordingDevice == null) return;
    final deviceId = _recordingDevice!.id;
    var connection = await ServiceManager.instance().device.ensureConnection(deviceId);
    if (connection == null) return;

    await connection.performCameraStartPhotoController();
    _blePhotoStream = await connection.performGetImageListener(
      onImageReceived: (orientedImage) async {
        final rotatedImageBytes = rotateImage(orientedImage);
        final String tempId = 'temp_img_${DateTime.now().millisecondsSinceEpoch}';
        final String base64Image = base64Encode(rotatedImageBytes);

        // Add placeholder to UI for immediate feedback
        photos.add(ConversationPhoto(id: tempId, base64: base64Image, createdAt: DateTime.now()));
        photos = List.from(photos);
        _segmentsPhotosVersion++;
        notifyListeners();

        // Chunking Logic
        const int chunkSize = 8192; // 8KB chunks
        final totalChunks = (base64Image.length / chunkSize).ceil();

        for (int i = 0; i < totalChunks; i++) {
          final start = i * chunkSize;
          final end = (start + chunkSize > base64Image.length) ? base64Image.length : start + chunkSize;
          final chunk = base64Image.substring(start, end);

          final payload = jsonEncode({
            'type': 'image_chunk',
            'id': tempId,
            'index': i,
            'total': totalChunks,
            'data': chunk,
          });

          if (_socket?.state == SocketServiceState.connected) {
            _socket?.send(payload); // Send the JSON string
          }
          await Future.delayed(const Duration(milliseconds: 20)); // Small delay to prevent flooding
        }
      },
    );
    notifyListeners();
  }

  void clearTranscripts() {
    segments = [];
    hasTranscripts = false;
    notifyListeners();
  }

  void clearUserData() {
    segments = [];
    photos = [];
    hasTranscripts = false;
    _transcriptionServiceStatuses = [];
    _terminalTranscriptionFailure = null;
    suggestionsBySegmentId = {};
    taggingSegmentIds = [];
    notifyListeners();
  }

  void _startMetricsTracking() {
    _metrics.start();
  }

  void _stopMetricsTracking() {
    _metrics.stop();
  }

  /// Triggers a metrics calculation for testing.
  /// This allows verifying that notifyListeners is gated by _metricsNotifyEnabled.
  @visibleForTesting
  void calculateMetricsForTesting() {
    _metrics.calculateForTesting();
  }

  Future _closeBleStream({bool disableNativeBackground = false}) async {
    await _bleBytesStream?.cancel();
    await _blePhotoStream?.cancel();
    await _bleButtonStream?.cancel();
    _stopMetricsTracking();
    if (disableNativeBackground) {
      await SharedPreferencesUtil().saveBool('nativeBleForegroundReady', false);
      await SharedPreferencesUtil().saveBool('nativeBleStreamingEnabled', false);
    } else {
      await SharedPreferencesUtil().saveBool('nativeBleForegroundReady', false);
    }
    if (_recordingDevice != null) {
      var connection = await ServiceManager.instance().device.ensureConnection(_recordingDevice!.id);
      if (connection != null && await connection.hasPhotoStreamingCharacteristic()) {
        await connection.performCameraStopPhotoController();
      }
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _bleBytesStream?.cancel();
    _blePhotoStream?.cancel();
    _bleButtonStream?.cancel();
    _socket?.unsubscribe(this);
    _keepAliveTimer?.cancel();
    _inProgressConversationRefreshTimer?.cancel();
    _connectionStateListener?.cancel();
    _metrics.dispose();
    _autoSyncFallbackTimer?.cancel();
    _peopleRefreshFuture = null; // Clear in-flight tracker
    BleBridge.instance.removeBatchRecordingFinalizedListener(_onOfflineRecordingFinalized);
    hubProjection.dispose();
    freeFormVoiceMode?.stop();
    freeFormModeActive.dispose();

    super.dispose();
  }

  void updateRecordingState(RecordingState state) {
    recordingState = state;
    notifyListeners();
  }

  streamRecording() async {
    // The backend snapshots its cached location when finalizing a conversation.
    // Complete this bounded update before any live or batch capture path can
    // create/finalize that conversation.
    await _conversationLocationCapture.captureAndUpload();

    // Mode is fixed for the whole session at start. On iOS and Android the phone
    // mic can capture Transcribe Later (batch) audio: explicitly when the user
    // enabled it, or automatically as an offline fallback when there is no
    // network. Both write .bin files natively instead of opening the realtime socket.
    final mode = selectPhoneMicSessionMode(
      supportsBatch: phoneMicSupportsTranscribeLater,
      batchModeEnabled: SharedPreferencesUtil().batchModeEnabled,
      hasNetwork: ConnectivityService().isConnected,
    );
    if (mode != PhoneMicSessionMode.live) {
      await _startPhoneMicBatch(auto: mode == PhoneMicSessionMode.batchAuto);
      return;
    }

    updateRecordingState(RecordingState.initialising);
    final micPermission = await Permission.microphone.request();
    if (!micPermission.isGranted) {
      Logger.error('[CaptureProvider] microphone permission denied, not starting phone mic');
      updateRecordingState(RecordingState.stop);
      return;
    }

    // prepare
    await changeAudioRecordProfile(audioCodec: BleAudioCodec.pcm16, sampleRate: 16000);

    // Initialize WAL for phone mic recording
    _activeSource = PhoneMicSource();
    _phoneMicWalActive = true;
    await _wal.getSyncs().phone.onAudioCodecChanged(BleAudioCodec.pcm16);
    _wal.getSyncs().phone.setDeviceInfo('phone-mic', 'Phone Microphone');
    setIsWalSupported(true);

    // record
    try {
      await ServiceManager.instance().phoneMic.start(
        onByteReceived: (bytes) {
          // Process through AudioSource for frame splitting and sync key generation
          final frames = _activeSource?.processBytes(bytes) ?? [];

          for (final frame in frames) {
            _wal.getSyncs().phone.onFrameCaptured(frame);

            if (_socket?.state == SocketServiceState.connected) {
              _socket?.send(frame.payload);
              _wal.getSyncs().phone.markFrameSynced(frame.syncKey);
            }
          }
        },
        onRecording: () {
          updateRecordingState(RecordingState.record);
        },
        onStop: () {
          if (!_micInterrupted) {
            updateRecordingState(RecordingState.stop);
          }
        },
        onInitializing: () {
          updateRecordingState(RecordingState.initialising);
        },
        onStalled: _onMicStalled,
        onInterruption: _onMicInterruption,
      );
    } catch (e, st) {
      // Typed native failures (permission_denied, engine_start_failed, ...) or
      // mic contention — fail visibly instead of recording silence.
      Logger.error('[CaptureProvider] phone mic start failed: $e\n$st');
      _activeSource = null;
      _phoneMicWalActive = false;
      updateRecordingState(RecordingState.stop);
      await _socket?.stop(reason: 'phone mic start failed');
    }
  }

  stopStreamRecording() async {
    // Batch (Transcribe Later) phone-mic session: no WAL flush or socket to
    // close. Native stop() finalizes the current .bin before it resolves; the
    // recordings list refreshes from onBatchRecordingFinalized.
    if (_phoneMicBatchActive) {
      _micInterrupted = false;
      ServiceManager.instance().phoneMic.stop();
      _endOfflineSession();
      await _cleanupCurrentState();
      _phoneMicBatchActive = false;
      updateRecordingState(RecordingState.stop);
      return;
    }

    // Flush remaining phone mic WAL buffer before stopping
    if (_phoneMicWalActive) {
      final flushed = _activeSource?.flush() ?? [];
      for (final frame in flushed) {
        _wal.getSyncs().phone.onFrameCaptured(frame);
        if (_socket?.state == SocketServiceState.connected) {
          _socket?.send(frame.payload);
          _wal.getSyncs().phone.markFrameSynced(frame.syncKey);
        }
      }
      _phoneMicWalActive = false;
    }
    await _cleanupCurrentState(disableNativeBackground: true);
    _micInterrupted = false;
    ServiceManager.instance().phoneMic.stop();
    updateRecordingState(RecordingState.stop);
    await _socket?.stop(reason: 'stop stream recording');
  }

  /// Start a phone-mic Transcribe Later (batch) session. Native opus-encodes and
  /// writes WAL-compatible .bin files; no socket, WAL, or AudioSource is used
  /// (_activeSource stays null). [auto] selects the file marker: false = explicit
  /// Transcribe Later, true = automatic offline fallback.
  Future<void> _startPhoneMicBatch({required bool auto}) async {
    updateRecordingState(RecordingState.initialising);
    final micPermission = await Permission.microphone.request();
    if (!micPermission.isGranted) {
      Logger.error('[CaptureProvider] microphone permission denied, not starting phone mic batch');
      updateRecordingState(RecordingState.stop);
      return;
    }

    await _cleanupCurrentState();

    // batchAudioDir may never have been written if batch was chosen via the
    // offline auto-switch (setBatchMode was never called with batch on).
    final docs = await getApplicationDocumentsDirectory();
    await SharedPreferencesUtil().saveString('batchAudioDir', docs.path);
    await SharedPreferencesUtil().saveBool('phoneBatchAuto', auto);
    if (SharedPreferencesUtil().batchMuted) SharedPreferencesUtil().batchMuted = false;
    if (SharedPreferencesUtil().batchCutRequested) SharedPreferencesUtil().batchCutRequested = false;

    _phoneMicBatchActive = true;
    // Offline-session bookkeeping drives the capture-card timer (mirrors
    // _initiateDeviceAudioStreaming); _onOfflineRecordingFinalized resets it on
    // each native file rotation.
    _offlineSessionStartSeconds = _nowSeconds;
    _offlineMuteStartedAt = null;

    updateRecordingState(RecordingState.record);
    try {
      await ServiceManager.instance().phoneMic.startBatch(
        onStop: () {
          if (!_micInterrupted && !_phoneMicBatchRestartInFlight) {
            updateRecordingState(RecordingState.stop);
          }
        },
        onInterruption: _onMicInterruption,
        onBatchStalled: _onBatchStalled,
        onError: _onBatchCaptureError,
      );
    } catch (e, st) {
      // No socket to clean in batch — fail visibly instead of recording nothing.
      Logger.error('[CaptureProvider] phone mic batch start failed: $e\n$st');
      _phoneMicBatchActive = false;
      _endOfflineSession();
      updateRecordingState(RecordingState.stop);
    }
  }

  /// Batch liveness watchdog escalation: the native progress feed went silent, so
  /// tear the session down and start a fresh one. Never routes through the Live
  /// restart path (_restartPhoneMicRecording), which assumes a socket/WAL.
  Future<void> _onBatchStalled() async {
    if (!_phoneMicBatchActive || _phoneMicBatchRestartInFlight) return;
    // Silence during our own call is not a stall — it is the pause working.
    if (_inAppCallHoldsMic) return;
    _phoneMicBatchRestartInFlight = true;
    try {
      ServiceManager.instance().phoneMic.stop();
      if (!_phoneMicBatchActive) return; // user stopped while restarting
      await _startPhoneMicBatch(auto: SharedPreferencesUtil().phoneBatchAuto);
    } catch (e, st) {
      Logger.error('[CaptureProvider] _onBatchStalled restart failed: $e\n$st');
    } finally {
      _phoneMicBatchRestartInFlight = false;
    }
  }

  Future<void> _onBatchCaptureError(String code, String message) async {
    Logger.error('[CaptureProvider] batch capture error $code: $message');
    if (code == 'batch_storage_full') {
      // The flag is written natively; reload so the Dart prefs cache sees it
      // before the UI re-reads it on notify.
      await SharedPreferencesUtil.reload();
      notifyListeners();
    }
  }

  Future streamDeviceRecording({BtDevice? device}) async {
    Logger.debug("streamDeviceRecording $device");
    if (deviceOnboardingProvider == null && SharedPreferencesUtil().batchModeSuspendedForOnboarding) {
      await restoreBatchModeAfterOnboarding();
    }
    if (device != null) _updateRecordingDevice(device);

    bool wasPaused = _isPaused;

    // Ensure even very short device recordings have a location in Redis before
    // the backend is able to finalize their conversation.
    await _conversationLocationCapture.captureAndUpload();

    await _resetStateVariables();
    await _resetState();

    if (wasPaused) {
      await pauseDeviceRecording();
    }
  }

  Future stopStreamDeviceRecording({bool cleanDevice = false}) async {
    await _cleanupCurrentState(disableNativeBackground: true);
    if (cleanDevice) {
      _updateRecordingDevice(null);
    }
    updateRecordingState(RecordingState.stop);
    _keepAliveTimer?.cancel();
    _keepAliveTimer = null;
    await _socket?.stop(reason: 'stop stream device recording');
  }

  @override
  void onClosed([int? closeCode]) {
    _transcriptionServiceStatuses = [];
    _transcriptServiceReady = false;

    if (closeCode == 4002) {
      externalActions.markAsOutOfCreditsAndRefresh();
    }

    // An auth rejection is not a dropped connection, and reconnecting on the
    // same 15s cadence answers it with the same credential the server just
    // refused. 4001 says the token is stale and a refreshed one would be
    // accepted, so refresh it before the keepalive tries again; 4004 and 4005
    // say no credential this session can present will be accepted, so the loop
    // has to stop and say why instead of retrying until the user gives up.
    if (closeCode == _wsCloseTokenRefreshRequired) {
      unawaited(_refreshAuthToken());
    }
    if (closeCode == _wsCloseReloginRequired || closeCode == _wsCloseAccountDeleting) {
      _transcriptionAuthRejection = closeCode;
    }

    // Reflect the transcription pipeline break in recordingState. Before this
    // change the UI kept reading "record" while the socket was dead, which
    // looked like active capture to the user (issue #6499). Only flip when we
    // were actively phone-mic recording — device/system-audio flows have their
    // own state lanes.
    final ctx = globalNavigatorKey.currentContext;
    if (recordingState == RecordingState.record) {
      updateRecordingState(RecordingState.interrupted);
      // "reconnecting" would be a lie after a rejection nothing retries past;
      // that case gets its own notice below, whatever the recording state was.
      if (ctx != null && _transcriptionAuthRejection == null) {
        AppSnackbar.showSnackbar(ctx.l10n.transcriptionPausedReconnecting, duration: const Duration(seconds: 3));
      }
    }

    // Mark that a device-recording session was interrupted by a network drop.
    // _initiateWebsocket() will call onNetworkSocketReconnected() on the device
    // connection so it can re-enable streaming (e.g. Limitless re-sends the
    // enable-data-stream command after its BLE audio times out).
    if (recordingState == RecordingState.deviceRecord) {
      _socketReconnectPending = true;
    }

    if (_transcriptionAuthRejection != null) {
      _keepAliveTimer?.cancel();
      _keepAliveTimer = null;
      if (ctx != null) {
        // Both codes mean the same thing to the user: the credential this
        // session holds will not be accepted again, and signing in is the only
        // way forward — for a deleting account that surfaces the deletion
        // through the normal sign-in path instead of a silent retry loop.
        AppSnackbar.showSnackbar(ctx.l10n.sessionExpiredSignInAgain, duration: const Duration(seconds: 5));
      }
      notifyListeners();
      return;
    }

    notifyListeners();
    _startKeepAliveServices();
  }

  /// The socket was refused for a reason no retry can resolve (4004 re-login,
  /// 4005 account deletion). Cleared by the next explicit connection attempt,
  /// which is allowed to fail again and re-arm this.
  int? _transcriptionAuthRejection;

  Future<void> _refreshAuthToken() async {
    final refresher = _authTokenRefresher;
    if (refresher != null) {
      await refresher();
      return;
    }
    await AuthService.instance.refreshIdToken();
  }

  bool get _shouldReconnectTranscriptionSocket {
    // A refused credential is not something the keepalive can fix by trying
    // once more; without this the loop reconnects every 15s indefinitely.
    if (_transcriptionAuthRejection != null) return false;
    final activeDeviceCapture = _recordingDevice != null && recordingState == RecordingState.deviceRecord && !_isPaused;
    final activePhoneOrSystemCapture =
        recordingState == RecordingState.record ||
        recordingState == RecordingState.interrupted ||
        recordingState == RecordingState.systemAudioRecord;
    return activeDeviceCapture || activePhoneOrSystemCapture;
  }

  @visibleForTesting
  bool get keepAliveScheduledForTesting => _keepAliveTimer?.isActive ?? false;

  void _startKeepAliveServices() {
    _keepAliveTimer?.cancel();
    _keepAliveTimer = null;
    if (!_shouldReconnectTranscriptionSocket) return;
    _keepAliveTimer = Timer.periodic(const Duration(seconds: 15), (t) async {
      Logger.debug("[Provider] keep alive");
      if (!_shouldReconnectTranscriptionSocket) {
        t.cancel();
        _keepAliveTimer = null;
        return;
      }
      // rate 1/15s
      if (_keepAliveLastExecutedAt != null &&
          DateTime.now().subtract(const Duration(seconds: 15)).isBefore(_keepAliveLastExecutedAt!)) {
        Logger.debug("[Provider] keep alive - hitting rate limits 1/15s");
        return;
      }

      _keepAliveLastExecutedAt = DateTime.now();
      if (!recordingDeviceServiceReady || _socket?.state == SocketServiceState.connected) {
        t.cancel();
        _keepAliveTimer = null;
        return;
      }

      if (!AuthService.instance.isSignedIn()) {
        Logger.debug("[Provider] keep alive - user not signed in, cancelling reconnect");
        t.cancel();
        _keepAliveTimer = null;
        return;
      }

      await _reconnectActiveCapture();
    });
  }

  Future<void> _reconnectActiveCapture() async {
    final device = _recordingDevice;
    if (device != null && recordingState == RecordingState.deviceRecord && !_isPaused) {
      final codec = await _getAudioCodec(device.id);
      if (!_shouldReconnectTranscriptionSocket || _recordingDevice?.id != device.id) return;
      await _initiateWebsocket(audioCodec: codec, source: _getConversationSourceFromDevice());
      return;
    }
    if (recordingState == RecordingState.record ||
        recordingState == RecordingState.interrupted ||
        recordingState == RecordingState.systemAudioRecord) {
      await _initiateWebsocket(
        audioCodec: BleAudioCodec.pcm16,
        sampleRate: 16000,
        source: ConversationSource.phone.name,
      );
    }
  }

  @visibleForTesting
  Future<void> reconnectActiveCaptureForTesting() => _reconnectActiveCapture();

  @override
  void onError(Object err) {
    _transcriptionServiceStatuses = [];
    _transcriptServiceReady = false;

    notifyListeners();
    _startKeepAliveServices();
  }

  @override
  void onConnected() {
    _transcriptServiceReady = true;
    // Restart mic on reconnect if interrupted (skip during active call).
    if (recordingState == RecordingState.interrupted && !_micInterrupted) {
      if (_activeSource is PhoneMicSource) {
        _restartPhoneMicRecording();
      } else {
        updateRecordingState(RecordingState.record);
      }
    }
    notifyListeners();
  }

  Future refreshInProgressConversations() async {
    _loadInProgressConversation();
  }

  bool get _canRefreshInProgressConversation =>
      recordingDeviceServiceReady ||
      recordingState == RecordingState.initialising ||
      recordingState == RecordingState.interrupted ||
      recordingState == RecordingState.pause ||
      recordingState == RecordingState.deviceRecord;

  void _startInProgressConversationRefresh() {
    if (!_canRefreshInProgressConversation || segments.isNotEmpty || photos.isNotEmpty) return;
    // A socket reconnect calls this on every attempt. If a poll cycle is already
    // running, leave it alone instead of resetting the attempt counter — otherwise
    // a flaky connection (reconnecting more often than the ~1min cap) keeps this
    // polling GET /v1/conversations indefinitely instead of ever hitting the cap
    // (each poll is a Firestore read; this starved the whole backend's quota once).
    if (_inProgressConversationRefreshTimer?.isActive ?? false) return;

    _inProgressConversationRefreshAttempts = 0;
    _inProgressConversationRefreshTimer = Timer.periodic(_inProgressConversationRefreshInterval, (_) {
      _refreshInProgressConversationTick();
    });
  }

  @visibleForTesting
  void startInProgressConversationRefreshForTesting() => _startInProgressConversationRefresh();

  @visibleForTesting
  bool get inProgressConversationRefreshActiveForTesting => _inProgressConversationRefreshTimer?.isActive ?? false;

  @visibleForTesting
  int get inProgressConversationRefreshAttemptsForTesting => _inProgressConversationRefreshAttempts;

  void _stopInProgressConversationRefresh() {
    _inProgressConversationRefreshTimer?.cancel();
    _inProgressConversationRefreshTimer = null;
    _inProgressConversationRefreshAttempts = 0;
    _isRefreshingInProgressConversation = false;
  }

  Future<void> _refreshInProgressConversationTick() async {
    if (_isRefreshingInProgressConversation) return;
    if (!_canRefreshInProgressConversation ||
        segments.isNotEmpty ||
        photos.isNotEmpty ||
        _inProgressConversationRefreshAttempts >= _maxInProgressConversationRefreshAttempts) {
      _stopInProgressConversationRefresh();
      return;
    }

    _inProgressConversationRefreshAttempts++;
    _isRefreshingInProgressConversation = true;
    try {
      await _drainNativeBleTranscriptMessages();
      if (segments.isEmpty && photos.isEmpty) {
        if (_inProgressConversationLoader != null) {
          await _inProgressConversationLoader!();
        } else {
          await _loadInProgressConversation();
        }
      }
    } finally {
      _isRefreshingInProgressConversation = false;
    }

    if (segments.isNotEmpty ||
        photos.isNotEmpty ||
        _inProgressConversationRefreshAttempts >= _maxInProgressConversationRefreshAttempts) {
      _stopInProgressConversationRefresh();
    }
  }

  Future<void> _drainNativeBleTranscriptMessages() async {
    if (!Platform.isAndroid) return;

    List<String>? messages;
    try {
      messages = await _nativeBleTranscriptChannel.invokeListMethod<String>('drain');
    } on MissingPluginException {
      return;
    } catch (e) {
      Logger.debug('Failed to drain native BLE transcript messages: $e');
      return;
    }

    if (messages == null || messages.isEmpty) return;
    Logger.debug('Draining ${messages.length} native BLE transcript messages');

    for (final message in messages) {
      await _handleNativeBleTranscriptMessage(message);
    }
  }

  Future<void> _handleNativeBleTranscriptMessage(String message) async {
    dynamic jsonEvent;
    try {
      jsonEvent = jsonDecode(message);
    } catch (e) {
      Logger.debug('Failed to decode native BLE transcript message: $e');
      return;
    }

    if (jsonEvent is List) {
      final newSegments = jsonEvent.map((e) => TranscriptSegment.fromJson(e)).toList();
      await _processNewSegmentReceived(newSegments);
      return;
    }

    if (jsonEvent is Map && jsonEvent.containsKey('type')) {
      onMessageEventReceived(MessageEvent.fromJson(Map<String, dynamic>.from(jsonEvent)));
    }
  }

  Future _loadInProgressConversation() async {
    var convos = await getConversations(statuses: [ConversationStatus.in_progress], limit: 1);
    _conversation = convos.isNotEmpty ? convos.first : null;
    if (_conversation != null) {
      segments = _conversation!.transcriptSegments;
      // Merge server photos with locally-captured temp photos to avoid losing
      // photos that haven't been processed server-side yet.
      final serverPhotos = _conversation!.photos;
      final localTempPhotos = photos.where((p) => p.id.startsWith('temp_img_')).toList();
      final serverPhotoIds = serverPhotos.map((p) => p.id).toSet();
      // Keep local temp photos that aren't already on the server
      final mergedPhotos = List<ConversationPhoto>.from(serverPhotos);
      for (final local in localTempPhotos) {
        if (!serverPhotoIds.contains(local.id)) {
          mergedPhotos.add(local);
        }
      }
      photos = mergedPhotos;
    } else {
      segments = [];
      photos = [];
    }
    _segmentsPhotosVersion++; // Bump version so Selector rebuilds
    setHasTranscripts(segments.isNotEmpty);
    notifyListeners();
  }

  @override
  void onMessageEventReceived(MessageEvent event) {
    if (event is ConversationProcessingStartedEvent) {
      externalActions.addProcessingConversation(event.memory);
      _pendingAutoSyncSessionStart = _sessionStartSeconds;
      _pendingAutoSyncConversationId = event.memory.id;

      // Force-drain tail buffer, stamp WALs with conversation ID, then clear state.
      // Store the future so the coordinated transfer wake waits for the stamp.
      _pendingFinalizeAndStamp = _finalizeAndStampSession(_sessionStartSeconds, event.memory.id);

      _resetStateVariables();

      // Start 30s fallback timer in case ConversationEvent never arrives (WS disconnect)
      _autoSyncFallbackTimer?.cancel();
      _autoSyncFallbackTimer = Timer(const Duration(seconds: 30), () {
        if (_pendingAutoSyncSessionStart > 0 && _pendingAutoSyncConversationId != null) {
          final convId = _pendingAutoSyncConversationId!;
          _pendingAutoSyncSessionStart = 0;
          _pendingAutoSyncConversationId = null;
          Logger.debug('Auto-sync fallback timer fired — syncing WALs to conversation $convId');
          _autoSyncSessionWals();
        }
      });
      return;
    }

    if (event is ConversationEvent) {
      event.memory.isNew = true;
      externalActions.removeProcessingConversation(event.memory.id);
      _processConversationCreated(event.memory, event.messages.cast<ServerMessage>());
      _autoSyncFallbackTimer?.cancel();
      if (_pendingAutoSyncSessionStart > 0) {
        _pendingAutoSyncSessionStart = 0;
        _pendingAutoSyncConversationId = null;
        _autoSyncSessionWals();
      }
      return;
    }

    if (event is LastConversationEvent) {
      _handleLastConvoEvent(event.memoryId);
      return;
    }

    if (event is SpeakerLabelSuggestionEvent) {
      _handleSpeakerLabelSuggestionEvent(event);
      return;
    }

    if (event is TranslationEvent) {
      _handleTranslationEvent(event.segments);
      return;
    }

    if (event is SegmentsDeletedEvent) {
      _handleSegmentsDeletedEvent(event);
      return;
    }

    if (event is MessageServiceStatusEvent) {
      // Handle freemium threshold event via status field
      if (event.status == 'freemium_threshold_reached') {
        // Parse as FreemiumThresholdReachedEvent for consistent handling
        final thresholdEvent = FreemiumThresholdReachedEvent.fromJson({'status_text': event.statusText});
        _handleFreemiumThresholdReached(thresholdEvent);
        return;
      }

      // The backend sends stt_failed immediately before it closes the socket.
      // Keep this terminal state separate from the connection-scoped status
      // list so the user can see the outage while the reconnect loop runs.
      if (event.status == 'stt_failed') {
        _terminalTranscriptionFailure = event;
      } else if (event.status == 'ready') {
        _terminalTranscriptionFailure = null;
      }

      _transcriptionServiceStatuses.add(event);
      _transcriptionServiceStatuses = List.from(_transcriptionServiceStatuses);
      notifyListeners();
      return;
    }

    if (event is FreemiumThresholdReachedEvent) {
      _handleFreemiumThresholdReached(event);
      return;
    }

    if (event is PhotoProcessingEvent) {
      final tempId = event.tempId;
      final permanentId = event.photoId;
      final photoIndex = photos.indexWhere((p) => p.id == tempId);
      if (photoIndex != -1) {
        photos[photoIndex].id = permanentId;
        _segmentsPhotosVersion++;
        notifyListeners();
      }
      return;
    }

    if (event is PhotoDescribedEvent) {
      final photoId = event.photoId;
      final description = event.description;
      final discarded = event.discarded;
      final photoIndex = photos.indexWhere((p) => p.id == photoId);
      if (photoIndex != -1) {
        photos[photoIndex].description = description;
        photos[photoIndex].discarded = discarded;
        _segmentsPhotosVersion++;
        notifyListeners();
      }
      return;
    }
  }

  Future<void> forceProcessingCurrentConversation() async {
    final sessionStart = _sessionStartSeconds;

    // Force-drain tail buffer before clearing state
    final phoneSync = _wal.getSyncs().phone;
    await phoneSync.finalizeCurrentSession();

    _resetStateVariables();
    externalActions.addProcessingConversation(
      ServerConversation(
        id: '0',
        createdAt: DateTime.now(),
        structured: Structured('', ''),
        status: ConversationStatus.processing,
      ),
    );
    processInProgressConversation().then((result) async {
      if (result == null || result.conversation == null) {
        externalActions.removeProcessingConversation('0');
        return;
      }
      externalActions.removeProcessingConversation('0');
      result.conversation!.isNew = true;
      _processConversationCreated(result.conversation, result.messages);

      // Stamp WALs with conversation ID and auto-sync
      if (sessionStart > 0 && result.conversation != null) {
        await phoneSync.stampConversationId(sessionStart, result.conversation!.id);
        _autoSyncSessionWals();
      }
    });

    return;
  }

  /// Force-drain tail buffer and stamp all session WALs with conversation ID.
  /// Called from synchronous onMessageEventReceived — fire-and-forget async.
  Future<void> _finalizeAndStampSession(int sessionStartSeconds, String conversationId) async {
    try {
      final phoneSync = _wal.getSyncs().phone;
      await phoneSync.finalizeCurrentSession();
      if (sessionStartSeconds > 0) {
        await phoneSync.stampConversationId(sessionStartSeconds, conversationId);
      }
    } catch (e) {
      Logger.debug('_finalizeAndStampSession error: $e');
    }
  }

  Future<void> _autoSyncSessionWals() async {
    // Wait for finalize+stamp to complete so tail buffer WALs are on disk before querying.
    if (_pendingFinalizeAndStamp != null) {
      await _pendingFinalizeAndStamp;
      _pendingFinalizeAndStamp = null;
    }
    // The stamped conversation id stays on the WAL; the single transfer owner
    // will reconcile first and then offer retryable bytes through `syncAll`.
    await RecordingTransferCoordinator.instance.wake(WakeTrigger.cooldownElapsed);
  }

  Future<void> _processConversationCreated(ServerConversation? conversation, List<ServerMessage> messages) async {
    if (conversation == null) return;

    // Star the conversation if it was marked for starring
    if (_starOngoingConversation) {
      Logger.debug("Conversation was marked for starring, applying star");
      _starOngoingConversation = false; // Reset the flag
      conversation.starred = true;
      // Call API to star the conversation
      await setConversationStarred(conversation.id, true);
    }

    externalActions.upsertConversation(conversation);
    PlatformManager.instance.analytics.conversationCreated(conversation);
  }

  Future<void> _handleLastConvoEvent(String memoryId) async {
    bool conversationExists = externalActions.hasConversation(memoryId);
    if (conversationExists) {
      return;
    }
    ServerConversation? conversation = await getConversationById(memoryId);
    if (conversation != null) {
      Logger.debug("Adding last conversation to conversations: $memoryId");
      externalActions.upsertConversation(conversation);
    } else {
      Logger.debug("Failed to fetch last conversation: $memoryId");
    }
  }

  void _handleTranslationEvent(List<TranscriptSegment> translatedSegments) {
    try {
      if (translatedSegments.isEmpty) return;

      Logger.debug("Received ${translatedSegments.length} translated segments");

      // Update the segments with the translated ones
      var remainSegments = TranscriptSegment.updateSegments(segments, translatedSegments);
      if (remainSegments.isNotEmpty) {
        Logger.debug("Adding ${remainSegments.length} new translated segments");
      }

      _segmentsPhotosVersion++;
      notifyListeners();
    } catch (e) {
      Logger.debug("Error handling translation event: $e");
    }
  }

  void _handleSegmentsDeletedEvent(SegmentsDeletedEvent event) {
    if (event.segmentIds.isEmpty) return;

    segments.removeWhere((segment) => event.segmentIds.contains(segment.id));
    suggestionsBySegmentId.removeWhere((key, value) => event.segmentIds.contains(key));
    taggingSegmentIds.removeWhere((id) => event.segmentIds.contains(id));
    hasTranscripts = segments.isNotEmpty;
    _segmentsPhotosVersion++;
    notifyListeners();
  }

  void _handleSpeakerLabelSuggestionEvent(SpeakerLabelSuggestionEvent event) {
    // Tagging
    if (taggingSegmentIds.contains(event.segmentId)) {
      return;
    }
    // If segment already exists, check if it's assigned. If so, ignore suggestion.
    var segment = segments.firstWhereOrNull((s) => s.id == event.segmentId);
    if (segment != null && segment.id.isNotEmpty && (segment.personId != null || segment.isUser)) {
      return;
    }

    // Add backend-created person to local cache for UI display (backward compatibility)
    final isUser = event.personId == 'user';
    if (!isUser && event.personId.isNotEmpty && SharedPreferencesUtil().getPersonById(event.personId) == null) {
      SharedPreferencesUtil().addCachedPerson(
        Person(id: event.personId, name: event.personName, createdAt: DateTime.now(), updatedAt: DateTime.now()),
      );
    }

    // Auto-apply assignment if backend provided personId (speaker_auto_assign=enabled)
    if (event.personId.isNotEmpty) {
      for (var seg in segments) {
        if (seg.speakerId == event.speakerId) {
          seg.isUser = isUser;
          seg.personId = isUser ? null : event.personId;
        }
      }
      _segmentsPhotosVersion++; // Trigger UI rebuild after auto-apply
    }
    notifyListeners();
  }

  Future<void> assignSpeakerToConversation(
    int speakerId,
    String personId,
    String personName,
    List<String> segmentIds,
  ) async {
    if (segmentIds.isEmpty) return;

    taggingSegmentIds = List.from(segmentIds);
    notifyListeners();

    try {
      String finalPersonId = personId;

      // Create person if new (old app path - calls idempotent API)
      if (finalPersonId.isEmpty) {
        Person? newPerson = await externalActions.createPerson(personName);
        if (newPerson != null) {
          finalPersonId = newPerson.id;
        }
      }

      // Add person to local cache if not exists (backward compatibility for old apps)
      if (finalPersonId.isNotEmpty &&
          finalPersonId != 'user' &&
          SharedPreferencesUtil().getPersonById(finalPersonId) == null) {
        SharedPreferencesUtil().addCachedPerson(
          Person(id: finalPersonId, name: personName, createdAt: DateTime.now(), updatedAt: DateTime.now()),
        );
      }

      // Find conversation id
      if (_conversation == null) return;

      final isAssigningToUser = finalPersonId == 'user';

      // Update all segments with this speakerId for UI consistency
      for (var segment in segments) {
        if (segment.speakerId == speakerId) {
          segment.isUser = isAssigningToUser;
          segment.personId = isAssigningToUser ? null : finalPersonId;
        }
      }
      _segmentsPhotosVersion++; // Bump version so Selector rebuilds

      // Persist change
      await assignBulkConversationTranscriptSegments(
        _conversation!.id,
        segmentIds,
        isUser: isAssigningToUser,
        personId: isAssigningToUser ? null : finalPersonId,
      );

      // Notify backend session
      if (_socket?.state == SocketServiceState.connected) {
        final payload = jsonEncode({
          'type': 'speaker_assigned',
          'speaker_id': speakerId,
          'person_id': finalPersonId,
          'person_name': personName,
          'segment_ids': segmentIds,
        });
        _socket?.send(payload);
      }

      // Remove all suggestions for this speakerId
      suggestionsBySegmentId.removeWhere((key, value) => value.speakerId == speakerId);
    } finally {
      taggingSegmentIds = [];
      notifyListeners();
    }
  }

  @override
  void onSegmentReceived(List<TranscriptSegment> newSegments) {
    // Forward to interactive device onboarding if active on transcription step
    if (deviceOnboardingProvider?.isOnboardingActive == true && deviceOnboardingProvider!.currentStep == 0) {
      deviceOnboardingProvider!.onTranscriptSegments(newSegments);
    }
    _processNewSegmentReceived(newSegments);
  }

  Future<void> _processNewSegmentReceived(List<TranscriptSegment> newSegments) async {
    if (newSegments.isEmpty) return;

    if (segments.isEmpty && !_isLoadingInProgressConversation) {
      _isLoadingInProgressConversation = true;
      // Refresh the location at the first transcript without relying on the
      // long-lived foreground-task isolate. This is fail-open and does not
      // delay segment processing.
      unawaited(_conversationLocationCapture.captureAndUpload());
      try {
        if (_inProgressConversationLoader != null) {
          await _inProgressConversationLoader!();
        } else {
          await _loadInProgressConversation();
        }
      } finally {
        _isLoadingInProgressConversation = false;
      }
    }

    final remainSegments = TranscriptSegment.updateSegments(segments, newSegments);
    segments.addAll(remainSegments);

    // Refresh people cache if we see unknown personIds (backend-created persons)
    // Check all newSegments, not just remainSegments, to catch updates to existing segments
    if (_peopleRefreshFuture == null && _hasMissingPerson(newSegments)) {
      _peopleRefreshFuture = externalActions.refreshPeople().whenComplete(() {
        _peopleRefreshFuture = null;
      });
    }

    _segmentsPhotosVersion++; // Bump version so Selector rebuilds
    hasTranscripts = true;
    _lastSegmentReceivedAt = DateTime.now();
    notifyListeners();
  }

  void onConnectionStateChanged(bool isConnected) {
    _isConnected = isConnected;
    notifyListeners();
  }

  // ============== Freemium: Threshold Notification ==============

  /// Handle freemium threshold reached: Notify user based on required action
  void _handleFreemiumThresholdReached(FreemiumThresholdReachedEvent event) {
    if (!_freemiumThreshold.handle(event)) return;

    // Update usage provider to reflect approaching limit
    externalActions.refreshSubscription();

    notifyListeners();
  }

  /// Callback for external components to reset their freemium session state
  VoidCallback? onFreemiumSessionReset;

  /// Reset freemium threshold state (e.g., when credits reset or on new session)
  void resetFreemiumThresholdState() {
    _freemiumThreshold.reset();
    // Notify external handlers (e.g., FreemiumSwitchHandler)
    onFreemiumSessionReset?.call();
    notifyListeners();
  }

  /// Check if credits were restored and reset threshold state
  Future<void> checkCreditsAndResetThresholdIfNeeded() async {
    await externalActions.fetchSubscription();
    if (externalActions.isOutOfCredits == false && _freemiumThreshold.reached) {
      Logger.debug('[Freemium] Credits restored! Resetting threshold state.');
      resetFreemiumThresholdState();
    }
  }

  void setIsWalSupported(bool value) {
    _isWalSupported = value;
    notifyListeners();
  }

  Future<void> pauseDeviceRecording() async {
    if (_recordingDevice == null) return;

    // Write mute state first — before BLE cancel which may fire other events
    await BatteryWidgetService().updateMuteState(true);
    // Pause the BLE stream but keep the device connection
    await _bleBytesStream?.cancel();
    await SharedPreferencesUtil().saveBool('nativeBleForegroundReady', false);
    await SharedPreferencesUtil().saveBool('nativeBleStreamingEnabled', false);
    _isPaused = true;
    // Persist so the mute survives an app kill/restart, not just a reconnect.
    SharedPreferencesUtil().deviceMuted = true;
    updateRecordingState(RecordingState.pause);
    _keepAliveTimer?.cancel();
    _keepAliveTimer = null;
    notifyListeners();
  }

  Future<void> resumeDeviceRecording() async {
    if (_recordingDevice == null) return;
    _isPaused = false;
    // Clear the persisted mute so we don't re-mute on the next restart.
    SharedPreferencesUtil().deviceMuted = false;
    // Update widget immediately — don't wait for streaming setup
    BatteryWidgetService().updateMuteState(false);
    // Resume streaming from the device
    await _initiateDeviceAudioStreaming();

    updateRecordingState(RecordingState.deviceRecord);
    notifyListeners();
  }
}
