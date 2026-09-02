// Gemini Live hub lane over WebSocket — a 1:1 port of
// `desktop/windows/src/renderer/src/lib/voice/hub/geminiHubSession.ts`
// (`GeminiHubSession`), design doc `~/omi-jarvis/docs/hub-port-design.md` §8
// step 2. Gemini uses MANUAL activity detection
// (`automaticActivityDetection.disabled: true`): each PTT turn is bracketed
// `activityStart` … `activityEnd`, sent every turn on the warm socket
// (sending it once at connect makes turns 2+ arrive with no speech window).
// Gemini has no reliable in-session cancel of a streaming reply, so
// barge-in is a fresh session at the controller boundary (design doc §6,
// not this file); `_responsePending` gates BOTH audio playback and turn
// completion to the current turn so an interrupted/abandoned turn's
// trailing audio can't leak.
//
// freeFormMode (added for the "свободный голосовой режим" priority,
// `~/omi-jarvis/marathon/lanes/lane5.md` §"ГЛАВНЫЙ ПРИОРИТЕТ 22.08" step 1 —
// no TS analog to port from; the desktop hub is manual-VAD-only). Default
// `false` keeps every existing branch byte-for-byte identical to before this
// flag existed (Igor's explicit requirement — the flag-off path must not
// change). When `true`:
//   * `automaticActivityDetection.disabled` flips to `false` in the setup
//     frame — Gemini's own VAD decides where an utterance starts/ends
//     instead of the client bracketing it with activityStart/activityEnd.
//   * `beginTurn()` (called once, when free-form mode is switched ON —
//     NOT once per utterance) opens continuous input (`_streamingActive`)
//     instead of a single PTT window; mic frames are meant to flow
//     continuously for as long as the mode stays on. No `activityStart`
//     frame is sent (the API contract for automatic detection is that the
//     client does not send manual activity signals at all).
//   * `commitTurn()` has nothing to do — the server ends each detected
//     utterance's turn on its own (still surfaces as `serverContent.
//     turnComplete`, same wire shape as manual mode) — it is a no-op here.
//     A correctly wired free-form driver should not call it; the no-op is
//     just a safe fallback.
//   * `cancelTurn()` is repurposed as "switch free-form mode off": it stops
//     accepting input (`_streamingActive = false`) without sending an
//     `activityEnd` frame (nothing to close — there was never a manual
//     window).
//   * Each server-detected utterance completing (`turnComplete`) still
//     plays its audio and fires `onTurnDone`, but — unlike manual mode —
//     does NOT close input: the session keeps `_streamingActive` true so
//     the next utterance is accepted without another `beginTurn()` call.
//   * Barge-in (`serverContent.interrupted`) still clears playback exactly
//     as in manual mode; it does not touch `_streamingActive`, since the
//     free-form session has no per-turn window to reopen.
// This only teaches the session layer the new wire shape and turn
// bookkeeping — it is NOT wired into `voice_turn_driver.dart`, the
// controller, or any UI yet (later steps of the same priority list:
// start/stop contract + foreground service, `ask_claude` tool, UI toggle).
//
// Tool-catalog assembly (lane5.md §"ГЛАВНЫЙ ПРИОРИТЕТ 22.08" step 3): the TS
// source projects `BaseHubSession.tools` through `sanitizeGeminiToolSchema`
// into `functionDeclarations` on every setup frame — ported verbatim below.
// `tools` is still just a plain injected list (see `hub_session.dart`); this
// file only owns the Gemini-specific wire projection.
//
// sessionResumption (design doc §10, measured on the live wire 24.08 —
// `marathon/probes/lane5-session-resumption.py` and
// `…-resumption-bargein.py`; there is no TS analog to port). Without it every
// dropped socket — including the 120s idle release and Gemini's fresh-session
// barge-in — starts a blank conversation. The setup frame therefore always
// carries `sessionResumption` (an empty map when there is nothing to restore:
// the server only offers handles when the key is present at all), and
// `sessionResumptionUpdate` frames are surfaced to the host.
// The measured trap that shapes the code: a handle captured while the model
// was MID-REPLY makes the resumed session replay that abandoned reply — and
// it arrives glued in front of the answer to the user's next question, inside
// a single `turnComplete`, so no client-side filter can separate them (27s of
// unwanted monologue in the probe). Hence `_replyInFlight`: the handle is
// withdrawn (`onResumptionHandle(null)`) the moment a generation starts and
// re-offered only at its `turnComplete`.
//
// Дословная речь для ask_claude (self-host патч 02.09, TS-аналога нет).
// Наблюдение Игоря: в аргумент `question` инструмента Gemini кладёт СВОЙ
// пересказ сказанного, и часть фраз до Claude не доходит. Сессия поэтому
// копит `serverContent.inputTranscription` (STT самого Gemini, включён в
// setup-фрейме) за текущий ход пользователя — все сегменты с момента
// последнего завершённого ответа ассистента / предыдущего tool-call — и
// прикладывает накопленное к каждому `HubToolCallRequest.userTranscript`;
// `AskClaudeToolExecutor` подставляет его вместо пересказа модели.
// Буфер сбрасывается на: новую PTT-активность (`beginTurn`), `interrupted`
// (перебивание — речь до него принадлежит старому ходу), `turnComplete`,
// который мы засчитываем (ответ ассистента закончен), выдачу tool-call'ов
// (склейка «с последнего toolCall»), отмену хода и сброс сессии.
// Гонка: транскрипция за ход и toolCall идут почти одновременно (замер
// 23.08: финальный транскрипт и первое аудио ответа в 10 мс друг от друга),
// и порядок не гарантирован. Если toolCall пришёл при ПУСТОМ буфере, его
// выдача откладывается на [transcriptGrace] в ожидании транскрипта; первый
// пришедший кусок даёт ещё [transcriptSettle] на хвост (не больше
// [_maxSettleRounds] раз), после чего вызов уходит с тем, что накопилось —
// либо вовсе без транскрипта (executor тогда берёт пересказ модели). Пока
// вызов отложен, его id уже в `_pendingToolCallIds`, так что `turnComplete`
// ждёт результата ровно как раньше.
//
// One scope cut carried over from `hub_session.dart` (already decided
// there, not re-litigated here): no `setSinkId` — not a TS concern in this
// file to begin with.
import 'dart:convert';

import 'package:omi/utils/logger.dart';

import 'gemini_tool_schema.dart';
import 'hub_session.dart';

/// Was `desktop/windows/.../voice/tokenMint.ts`'s `GEMINI_LIVE_MODEL`
/// (`gemini-3.1-flash-live-preview`) — self-host diverges deliberately
/// (24.08): that preview started refusing every Live handshake with WS 1011
/// "Internal error encountered." (reproduced from a desktop probe with the
/// exact setup frame below; the key, quota, and mint were all healthy). The
/// `-latest` alias tracks Google's current native-audio Live model, which is
/// exactly the protection a pinned preview lacked. The ephemeral-token mint
/// does not pin a model, so this constant is the single switch.
const String geminiLiveModel = 'models/gemini-2.5-flash-native-audio-latest';

class GeminiHubSession extends BaseHubSession {
  GeminiHubSession({
    required super.token,
    required super.instructions,
    required super.playerFactory,
    super.events,
    super.socketFactory,
    super.clock,
    super.mintSessionId,
    super.idleRelease,
    super.warmTimeout,
    super.tools,
    super.resumptionHandle,
    this.freeFormMode = false,
    this.transcriptGrace = const Duration(milliseconds: 700),
    this.transcriptSettle = const Duration(milliseconds: 300),
  });

  /// See file header. Default `false` == today's manual-VAD/PTT behavior,
  /// unchanged.
  final bool freeFormMode;

  /// Сколько ждать транскрипцию хода, если toolCall пришёл раньше неё (см.
  /// шапку файла, «Дословная речь для ask_claude»). `Duration.zero` — не
  /// ждать вовсе (вызов уходит сразу, без транскрипта).
  final Duration transcriptGrace;

  /// После первого куска транскрипта, пришедшего в окно [transcriptGrace] —
  /// пауза на возможный хвост (многосегментная фраза).
  final Duration transcriptSettle;
  static const int _maxSettleRounds = 4;

  @override
  HubProvider get provider => HubProvider.gemini;
  @override
  int get requiredInputSampleRate => 16000;
  @override
  HubBargeInStrategy get bargeInStrategy => HubBargeInStrategy.freshSession;

  // Manual-VAD: a turn's speech window is open between activityStart and
  // activityEnd.
  bool _activityOpen = false;
  bool _pendingActivityStart = false;

  // freeFormMode: continuous input is accepted for as long as this is true
  // (set by beginTurn() when the mode is switched on, cleared by
  // cancelTurn() when it's switched off, or by resetProviderState() on
  // teardown). Unlike `_activityOpen`, this is NOT cleared per-utterance —
  // see file header.
  bool _streamingActive = false;

  // A committed turn is awaiting its spoken reply. Gates audio + turnComplete
  // to the CURRENT turn (set on activityEnd/commit; cleared on this turn's
  // turnComplete, a server `interrupted`, or a barge-in beginTurn).
  bool _responsePending = false;

  /// Ручной barge-in: пользователь ткнул в иконку, чтобы ассистент замолчал.
  ///
  /// Сервер об этом не знает — в Gemini Live прерывание инициирует ЕГО VAD,
  /// программной отмены генерации у нас нет. Значит остаток ответа продолжит
  /// приходить, и без этого флага он просто заиграл бы снова сразу после
  /// `clearPlayback()`, то есть тап дал бы полусекундную паузу вместо тишины.
  /// Снимается на `turnComplete` — следующий ответ звучит как обычно.
  bool _responseMuted = false;
  final Set<String> _pendingToolCallIds = {};
  int _syntheticToolCallCounter = 0;

  // Дословная речь пользователя за текущий ход (см. шапку файла). Куски
  // `inputTranscription` — дельты, склеиваются как есть; `_userSpeechBoundary`
  // помечает границу сегмента (сервер увидел новую речь после паузы), чтобы
  // сегменты не слиплись в одно слово.
  final StringBuffer _userTranscript = StringBuffer();
  bool _userSpeechBoundary = false;
  List<HubToolCallRequest>? _deferredToolCalls;
  Object? _deferredToolCallsTimer;
  int _deferredSettleRounds = 0;

  // Session resumption (design doc §10, measured 24.08). `_latestHandle` is
  // the freshest token the server offered; `_replyInFlight` is true while the
  // server has an unfinished reply generation, which is exactly when that
  // handle must NOT be used — resuming it replays the abandoned reply.
  String? _latestHandle;
  bool _replyInFlight = false;

  @override
  HubConnectSpec connectSpec() {
    // Managed (ephemeral) path: the Constrained endpoint on v1alpha with
    // ?access_token= (TS/Swift `.ephemeral`). BYOK (?key=, v1beta) is a host
    // concern not needed for the managed flow — deferred.
    const base = 'wss://generativelanguage.googleapis.com/ws/'
        'google.ai.generativelanguage.v1alpha.GenerativeService.BidiGenerateContentConstrained';
    return HubConnectSpec(url: '$base?access_token=${Uri.encodeQueryComponent(token)}');
  }

  @override
  Map<String, dynamic> sessionSetupFrame() {
    // AUDIO modality, manual activity detection, Charon voice, sliding-window
    // context compression, empty (unwired) tool catalog — see file header.
    return {
      'setup': {
        'model': geminiLiveModel,
        'generationConfig': {
          'responseModalities': ['AUDIO'],
          'temperature': 0.3,
          'mediaResolution': 'MEDIA_RESOLUTION_HIGH',
          // Thinking выключен (24.08, после перехода на 2.5-native-audio):
          // модель молча «думала» перед ответом — в эфире это длинные паузы,
          // а её английские thought-саммари утекали текстом в чат («Testing
          // Response Generation…»). Для живого разговора скорость важнее
          // цепочек рассуждений: сложное и так эскалируется в ask_claude.
          // Сетап с thinkingBudget=0 проверен пробой (setupComplete, 24.08).
          'thinkingConfig': {'thinkingBudget': 0},
          'speechConfig': {
            'voiceConfig': {
              'prebuiltVoiceConfig': {'voiceName': 'Charon'},
            },
          },
        },
        'systemInstruction': {
          'parts': [
            {'text': instructions},
          ],
        },
        'tools': [
          {
            'functionDeclarations': tools
                .map((t) => {
                      'name': t.name,
                      'description': t.description,
                      'parameters': sanitizeGeminiToolSchema(t.parameters),
                    })
                .toList(),
          },
        ],
        'inputAudioTranscription': {},
        'outputAudioTranscription': {},
        'realtimeInputConfig': {
          'automaticActivityDetection': {'disabled': !freeFormMode},
          'turnCoverage': 'TURN_INCLUDES_AUDIO_ACTIVITY_AND_ALL_VIDEO',
        },
        'contextWindowCompression': {'slidingWindow': {}},
        // Session resumption. An empty map = "no conversation to restore, but
        // do hand me handles" — the server only emits `sessionResumptionUpdate`
        // when this key is present at all. With a handle, this socket picks up
        // the conversation a previous one was having.
        'sessionResumption': resumptionHandle == null ? <String, dynamic>{} : {'handle': resumptionHandle},
      },
    };
  }

  @override
  bool canAcceptInput() => isOpen && (freeFormMode ? _streamingActive : _activityOpen);

  /// A turn is open (see [BaseHubSession.canIdleRelease] for why that blocks
  /// the release). Free-form mode has exactly one turn for the whole mode, so
  /// `_streamingActive` IS "the mode is on"; manual mode counts both halves of
  /// a press — the activity window while the user holds the button, and the
  /// wait for the reply after they let go.
  @override
  bool get canIdleRelease => !(freeFormMode ? _streamingActive : (_activityOpen || _responsePending));

  @override
  void appendAudioFrame(String b64) {
    send({
      'realtimeInput': {
        'audio': {'data': b64, 'mimeType': 'audio/pcm;rate=16000'},
      },
    });
  }

  @override
  void onBeginTurn(bool interrupting) {
    if (interrupting) {
      // Local gate for abandoned/stale events before the fresh-session
      // replacement.
      _responsePending = false;
      _pendingToolCallIds.clear();
      _dropDeferredToolCalls();
    }
    if (freeFormMode) {
      // One call switches the mode ON for the whole session — not one call
      // per utterance (see file header). No activityStart frame: the API
      // contract for automatic detection is that the client sends none.
      if (_streamingActive) return;
      _streamingActive = true;
      if (isOpen) {
        flushPendingAudio();
      } else {
        _pendingActivityStart = true; // flushed (without a frame) in onProviderReady
      }
      return;
    }
    if (_activityOpen) return;
    _activityOpen = true;
    // Новое нажатие — новый ход пользователя: речь предыдущего хода к этому
    // вызову не относится.
    _resetUserTranscript();
    if (isOpen) {
      send({
        'realtimeInput': {'activityStart': {}},
      });
      flushPendingAudio();
      if (pendingCommit) {
        pendingCommit = false;
        commitTurnNow();
      }
    } else {
      _pendingActivityStart = true;
    }
  }

  @override
  void commitTurnNow() {
    if (freeFormMode) {
      // The server ends each detected utterance's turn on its own
      // (handleProviderMessage's turnComplete branch) — there is no manual
      // commit frame to send. A correctly wired free-form driver should not
      // be calling commitTurn() at all; this is just a safe no-op if it is.
      return;
    }
    send({
      'realtimeInput': {'activityEnd': {}},
    });
    _activityOpen = false;
    _responsePending = true;
    // Gemini auto-responds at activityEnd; no explicit response request.
  }

  @override
  void onCancelTurn() {
    if (freeFormMode) {
      // Repurposed as "switch free-form mode off": stop accepting input.
      // Nothing to close on the wire — there was never a manual window.
      _streamingActive = false;
      _pendingActivityStart = false;
      _pendingToolCallIds.clear();
      _dropDeferredToolCalls();
      _resetUserTranscript();
      return;
    }
    // Abandon (silent tap / cancel), keeping the warm socket.
    _responsePending = false;
    _pendingToolCallIds.clear();
    _dropDeferredToolCalls();
    _resetUserTranscript();
    _pendingActivityStart = false;
    if (_activityOpen && isOpen) {
      send({
        'realtimeInput': {'activityEnd': {}},
      });
    }
    _activityOpen = false;
  }

  @override
  void onSendToolResult(String callId, String name, String output) {
    _pendingToolCallIds.remove(callId);
    send({
      'toolResponse': {
        'functionResponses': [
          {
            'id': callId,
            'name': name,
            'response': {'result': output},
          },
        ],
      },
    });
  }

  @override
  void onSendUserText(String text) {
    send({
      'clientContent': {
        'turns': [
          {
            'role': 'user',
            'parts': [
              {'text': text},
            ],
          },
        ],
        'turnComplete': true,
      },
    });
  }

  @override
  void onProviderReady() {
    // Open the speech window if a turn started before we connected.
    if (_pendingActivityStart) {
      _pendingActivityStart = false;
      // freeFormMode never sends this frame — see file header.
      if (!freeFormMode) {
        send({
          'realtimeInput': {'activityStart': {}},
        });
      }
    }
  }

  @override
  void resetProviderState() {
    _activityOpen = false;
    _pendingActivityStart = false;
    _responsePending = false;
    _pendingToolCallIds.clear();
    _dropDeferredToolCalls();
    _resetUserTranscript();
    _streamingActive = false;
    // NOT cleared: `_latestHandle`/`_replyInFlight` are about the CONVERSATION,
    // which outlives this socket — that is the whole point of resumption. The
    // handle already reached the host via [emitResumptionHandle]; wiping it
    // here would only make a re-warm on this same object forget it.
  }

  /// Hand the host the current handle, unless a reply generation is in
  /// flight — see [HubSessionEvents.onResumptionHandle].
  void _offerResumptionHandle() {
    if (_replyInFlight) return;
    final handle = _latestHandle;
    if (handle != null) emitResumptionHandle(handle);
  }

  /// A protobuf Duration as it arrives over JSON: normally the string form
  /// ("10s", "1.5s"), but the object form ({seconds, nanos}) and a bare
  /// number are accepted too. Null when there is nothing parseable — a
  /// deadline-less warning is still a warning worth passing on.
  static Duration? _parseProtoDuration(dynamic raw) {
    if (raw is num) return Duration(microseconds: (raw * 1000000).round());
    if (raw is Map) {
      final seconds = raw['seconds'];
      final nanos = raw['nanos'];
      if (seconds == null && nanos == null) return null;
      final s = seconds is num ? seconds.toDouble() : double.tryParse('${seconds ?? 0}') ?? 0;
      final n = nanos is num ? nanos.toDouble() : double.tryParse('${nanos ?? 0}') ?? 0;
      return Duration(microseconds: (s * 1000000 + n / 1000).round());
    }
    if (raw is String) {
      final seconds = double.tryParse(raw.endsWith('s') ? raw.substring(0, raw.length - 1) : raw);
      if (seconds == null) return null;
      return Duration(microseconds: (seconds * 1000000).round());
    }
    return null;
  }

  /// The server started producing a reply. Withdraw the handle until this
  /// generation closes: a socket that dies right now must NOT be resumed.
  void _markReplyInFlight() {
    if (_replyInFlight) return;
    _replyInFlight = true;
    emitResumptionHandle(null);
  }

  @override
  void muteCurrentResponse() {
    _responseMuted = true;
    clearPlayback();
  }

  /// The gate `handleProviderMessage` uses to accept tool calls / reply
  /// audio / turn completion. Manual mode gates on the per-turn commit
  /// (`_responsePending`); free-form mode gates on the mode still being on
  /// (`_streamingActive`) — see file header.
  bool get _turnGateOpen => freeFormMode ? _streamingActive : _responsePending;

  // MARK: Verbatim user transcript for tool calls (see file header)

  void _resetUserTranscript() {
    _userTranscript.clear();
    _userSpeechBoundary = false;
  }

  void _appendUserTranscript(String text) {
    if (text.isEmpty) return;
    if (_userSpeechBoundary && _userTranscript.isNotEmpty) {
      final soFar = _userTranscript.toString();
      if (!soFar.endsWith(' ') && !text.startsWith(' ')) _userTranscript.write(' ');
    }
    _userSpeechBoundary = false;
    _userTranscript.write(text);
    // A tool call was waiting for exactly this; give the tail a moment to land.
    if (_deferredToolCalls != null) _rearmDeferredToolCalls(settle: true);
  }

  /// Snapshot of the current turn's verbatim speech, `null` when nothing came.
  String? get _userTranscriptOrNull {
    final text = _userTranscript.toString().trim();
    return text.isEmpty ? null : text;
  }

  void _emitToolRequests(List<HubToolCallRequest> requests) {
    final transcript = _userTranscriptOrNull;
    if (transcript == null) {
      Logger.debug('[hub-tool] tool-call без транскрипта хода — executor возьмёт пересказ модели');
    }
    for (final request in requests) {
      emitToolRequest(HubToolCallRequest(
        name: request.name,
        callId: request.callId,
        argumentsJson: request.argumentsJson,
        userTranscript: transcript,
      ));
    }
    // «С момента последнего toolCall»: следующий вызов в том же ходе получит
    // только то, что сказано после этого.
    _resetUserTranscript();
  }

  void _deferToolCalls(List<HubToolCallRequest> requests) {
    _deferredToolCalls = [...?_deferredToolCalls, ...requests];
    _deferredSettleRounds = 0;
    _rearmDeferredToolCalls(settle: false);
  }

  void _rearmDeferredToolCalls({required bool settle}) {
    final handle = _deferredToolCallsTimer;
    if (handle != null) clock.clearTimer(handle);
    _deferredToolCallsTimer = null;
    if (settle && ++_deferredSettleRounds > _maxSettleRounds) {
      _flushDeferredToolCalls();
      return;
    }
    _deferredToolCallsTimer = clock.setTimer(settle ? transcriptSettle : transcriptGrace, _flushDeferredToolCalls);
  }

  void _flushDeferredToolCalls() {
    final handle = _deferredToolCallsTimer;
    if (handle != null) clock.clearTimer(handle);
    _deferredToolCallsTimer = null;
    final requests = _deferredToolCalls;
    _deferredToolCalls = null;
    _deferredSettleRounds = 0;
    if (requests == null) return;
    _emitToolRequests(requests);
  }

  /// Turn abandoned/interrupted/torn down: the calls never reach the host,
  /// exactly like their ids are dropped from `_pendingToolCallIds` on the
  /// same paths (Gemini cancels a function call it interrupted itself).
  void _dropDeferredToolCalls() {
    final handle = _deferredToolCallsTimer;
    if (handle != null) clock.clearTimer(handle);
    _deferredToolCallsTimer = null;
    _deferredToolCalls = null;
    _deferredSettleRounds = 0;
  }

  // MARK: Receive

  @override
  void handleProviderMessage(Map<String, dynamic> obj) {
    if (obj.containsKey('setupComplete')) {
      markReady();
      return;
    }
    final resumption = obj['sessionResumptionUpdate'] as Map<String, dynamic>?;
    if (resumption != null) {
      // Measured cadence (design doc §10): the first handle lands ~1.2s after
      // the first turn's activity, NOT on a timer — an idle socket that never
      // carried a turn is handed nothing, so an early drop simply has no
      // conversation worth restoring. `resumable: false` is the server saying
      // this point is not resumable; keep the previous handle rather than
      // downgrading to a bad one.
      final handle = resumption['newHandle'];
      final resumable = resumption['resumable'];
      if (handle is String && handle.isNotEmpty && resumable != false) {
        _latestHandle = handle;
        _offerResumptionHandle();
      }
      return;
    }
    final goAway = obj['goAway'];
    if (goAway != null) {
      // The server is about to hang up (session/token lifetime reached). It
      // keeps serving until it does, so this is a chance to rebuild the
      // socket at a quiet moment instead of dropping mid-sentence — the host
      // decides when, we only report it. `timeLeft` is a protobuf Duration,
      // which JSON-encodes as a string ("10s", "1.5s"); tolerate the other
      // shapes rather than lose the warning to a format surprise.
      emitGoAway(goAway is Map<String, dynamic> ? _parseProtoDuration(goAway['timeLeft']) : null);
      return;
    }
    // usageMetadata (client-reported billing) is a host concern — deferred,
    // same as the TS source.
    final toolCall = obj['toolCall'] as Map<String, dynamic>?;
    if (toolCall != null) {
      final calls = (toolCall['functionCalls'] as List<dynamic>?) ?? const [];
      // An abandoned/discarded turn still reaches Gemini (we send
      // activityEnd to close the window); without this guard it acts on
      // half-heard audio.
      if (!_turnGateOpen) return;
      final requests = <HubToolCallRequest>[];
      for (final callRaw in calls) {
        final call = callRaw as Map<String, dynamic>;
        final name = call['name'] is String ? call['name'] as String : '';
        final callId = call['id'] is String ? call['id'] as String : _nextSyntheticToolCallId(name);
        _pendingToolCallIds.add(callId);
        final args = (call['args'] as Map<String, dynamic>?) ?? const {};
        final argsJson = jsonEncode(args);
        if (name.isNotEmpty) {
          requests.add(HubToolCallRequest(name: name, callId: callId, argumentsJson: argsJson));
        }
      }
      if (requests.isEmpty) return;
      // Транскрипт хода ещё не пришёл — подождать его (см. шапку файла), а
      // не отдавать Claude пересказ модели.
      if (_userTranscript.isEmpty && transcriptGrace > Duration.zero) {
        _deferToolCalls(requests);
      } else {
        _emitToolRequests(requests);
      }
      return;
    }
    final sc = obj['serverContent'] as Map<String, dynamic>?;
    if (sc == null) return;
    if (sc['interrupted'] == true) {
      // Barge-in: drop the pending reply so its trailing audio + bookkeeping
      // turnComplete are ignored, and flush queued playback immediately.
      // freeFormMode leaves `_streamingActive` alone — there is no per-turn
      // window to reopen, the session just keeps listening (see file
      // header).
      if (!freeFormMode) _responsePending = false;
      _responseMuted = false;
      _pendingToolCallIds.clear();
      _dropDeferredToolCalls();
      // Речь, накопленная до перебивания, — старый ход; новая реплика
      // пользователя (её транскрипт ещё в пути) начнёт буфер заново.
      _resetUserTranscript();
      clearPlayback();
      // Self-host patch: tell the host the reply was cut mid-air, so history
      // records what was actually heard instead of what was generated.
      events.onInterrupted?.call();
    }
    // Server-VAD verdict (free-form mode only; manual mode never sends it).
    // Unknown values are ignored rather than guessed at: a future third state
    // must not silently read as "user stopped talking".
    final speechState = sc['speechState'];
    if (speechState == 'SPEECH') {
      _userSpeechBoundary = true;
      emitUserSpeechState(true);
    } else if (speechState == 'NON_SPEECH') {
      emitUserSpeechState(false);
    }
    final it = sc['inputTranscription'] as Map<String, dynamic>?;
    if (it != null && it['text'] is String) {
      _appendUserTranscript(it['text'] as String);
      emitInputTranscript(it['text'] as String, false);
    }
    final ot = sc['outputTranscription'] as Map<String, dynamic>?;
    if (ot != null && ot['text'] is String) {
      _markReplyInFlight();
      emitAssistantText(ot['text'] as String, false);
    }
    final modelTurn = sc['modelTurn'] as Map<String, dynamic>?;
    final parts = (modelTurn?['parts'] as List<dynamic>?) ?? const [];
    // Deliberately NOT gated by `_turnGateOpen`: audio we ignore locally
    // (abandoned turn) is still a generation the SERVER considers unfinished,
    // and that is what would be replayed on resume. The gate below decides
    // what we play; this decides whether the conversation is safe to resume.
    if (parts.isNotEmpty) _markReplyInFlight();
    for (final partRaw in parts) {
      final part = partRaw as Map<String, dynamic>;
      // Страховка к thinkingBudget=0 выше: если модель всё же прислала
      // thought-часть (динамический thinking, смена модели за алиасом),
      // это её внутренний монолог, а не сказанное — в транскрипт и чат
      // ему нельзя.
      if (part['thought'] == true) continue;
      if (part['text'] is String) emitAssistantText(part['text'] as String, false);
      final inline = part['inlineData'] as Map<String, dynamic>?;
      final mime = inline?['mimeType'] is String ? inline!['mimeType'] as String : '';
      final data = inline?['data'] is String ? inline!['data'] as String : '';
      if (mime.contains('audio/pcm') && data.isNotEmpty) {
        if (_turnGateOpen) {
          // заглушённый вручную ответ доигрывать нечем — байты просто
          // выбрасываются, гейт и учёт хода при этом работают как обычно
          if (!_responseMuted) playAudio(data); // gated: only the live turn's reply
        } else {
          // Диагностика «слышу текст, не слышу голос» (24.08): если аудио
          // Gemini дошло, но гейт закрыт — это должно быть видно в логе, а
          // не пропадать молча.
          Logger.debug('[hub-audio] аудио-чанк отброшен гейтом (streaming=$_streamingActive)');
        }
      }
    }
    if (sc['turnComplete'] == true) {
      // The server closed this generation — nothing left to replay, so the
      // handle is safe to offer again. Done BEFORE the gated branches below,
      // which return early on turns we ignore locally: the server finished
      // regardless of whether we wanted the audio. `interrupted` deliberately
      // does not do this — it arrives ~0.1s BEFORE its own turnComplete
      // (design doc §9), so waiting costs nothing and never latches.
      _replyInFlight = false;
      _responseMuted = false;
      _offerResumptionHandle();
      if (_pendingToolCallIds.isNotEmpty) return; // defer until tool results are in
      if (freeFormMode) {
        // A completion that arrives after the mode was switched off
        // (`_streamingActive` false) belongs to a dead generation — ignore
        // it, same spirit as the manual-mode guard below.
        if (!_streamingActive) return;
        flushPlayback();
        emitAssistantText('', true);
        emitTurnDone();
        _resetUserTranscript(); // ответ ассистента закончен — следующий ход с чистого листа
        // `_streamingActive` stays true: unlike manual mode, this does NOT
        // close input — the next server-detected utterance is accepted
        // without another beginTurn() call (see file header).
        return;
      }
      // Only finish the turn we're actually awaiting a reply for. A
      // turnComplete that closes an interrupted/abandoned generation
      // (pending=false) is ignored.
      if (_responsePending) {
        _responsePending = false;
        flushPlayback();
        emitAssistantText('', true);
        emitTurnDone();
        _resetUserTranscript();
      }
    }
  }

  String _nextSyntheticToolCallId(String name) {
    _syntheticToolCallCounter += 1;
    return '$name:$_syntheticToolCallCounter';
  }
}
