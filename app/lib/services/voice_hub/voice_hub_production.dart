// Production wiring for the realtime voice hub — the "host" seam every
// prior tick in this series left explicitly open (design doc
// `~/omi-jarvis/docs/hub-port-design.md` §8 step 5; see e.g.
// `voice_turn_driver.dart`'s own header, `ask_claude_tool.dart`'s header).
// Every collaborator assembled here already exists as an injected seam —
// this file is pure assembly, no new capture/session/tool logic:
//   * `mintGeminiHubToken` — `HubMintToken`, `POST /v2/realtime/session`
//     per lane2's contract (lane2-log.md, 21.08 22:05, ~line 1424): Bearer
//     auth is added automatically by `makeApiCall`'s `buildHeaders`, same
//     as every other authenticated endpoint in this app — no separate auth
//     wiring needed here.
//   * `buildProductionHubInstructions` — `HubBuildInstructions`. Static
//     prose, not a port: the desktop TS source this whole series ports
//     from has no `desktop/` symlink in this worktree to copy verbatim.
//   * `fetchHubTools` — `HubFetchTools`. Today's catalog is exactly the one
//     tool this app declares, `askClaudeToolDeclaration`
//     (`ask_claude_tool.dart`).
//   * `createProductionVoiceHubTurnDriver` — assembles a real
//     `VoiceHubTurnDriver`: `HubController` (real mint/instructions/tools),
//     `GeminiHubSession` via `nativeVoicePlayerFactory`, mic capture via
//     `nativeMicHubCaptureFactory`, and `AskClaudeToolExecutor` wired to
//     `VoiceHubTurnDriverDeps.toolExecutor` (the seam this same tick added
//     to `voice_turn_driver.dart` — see that file's header for why the
//     defensive "tools not available" fallback alone isn't enough once a
//     real catalog is declared).
//
// NOT auto-invoked: nothing calls `createProductionVoiceHubTurnDriver` yet.
// Constructing it once at app bootstrap and assigning the result to
// `CaptureController().hubTurnDriver` (gated by `pttHubEnabled`, see that
// field's own doc comment) — plus the chat-screen UI toggle for
// `freeFormMode` — is deliberately left to a follow-up tick, same
// "additive, unconnected until explicitly wired" discipline the whole
// `voice_hub/` series has used throughout.
//
// Formerly a known gap (flagged by the tick that wrote `ask_claude_tool.dart`,
// its header, "Auth: NOT handled here"): `AskClaudeBridgeClient` needs a
// `http.Client` that stamps CF-Access-Client-Id/Secret, and this worktree
// (`feat/android-realtime-hub`) had no such client — the app's actual CF-Access
// wiring (`buildHeaders` in `backend/http/shared.dart`) lived only on lane2's
// `private` branch. Closed by two changes:
//   1. Cherry-picked `400c74b5d8` ("Cloudflare Access headers for the
//      self-host tunnel") from `private` into this branch — brings in
//      `Env.cfAccessClientId`/`cfAccessClientSecret`, the two dart-defines
//      everything else here reads.
//   2. `CfAccessHttpClient` (`cf_access_http_client.dart`) — a small
//      `http.Client` decorator built for this seam specifically, since
//      `buildHeaders` itself is a header-builder consumed by `makeApiCall`
//      and friends, not an injectable client (there was never a generic
//      intercepting client to reuse, contrary to `ask_claude_tool.dart`'s
//      original header comment — that assumption was wrong; see this
//      file's own header note there for the correction).
// `bridgeHttpClient` is therefore optional now, defaulting to
// `CfAccessHttpClient()`; a caller can still inject a bare `http.Client()`
// (or a fake) for tests or a non-tunnel deployment.
import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';

import 'package:omi/backend/http/shared.dart';
import 'package:omi/env/env.dart';
import 'package:omi/services/services.dart' show ServiceManager;

import 'ask_claude_tool.dart';
import 'cf_access_http_client.dart';
import 'earcon.dart';
import 'end_conversation_tool.dart';
import 'escalation_level.dart';
import 'free_form_voice_mode.dart';
import 'gemini_hub_session.dart';
import 'hub_controller.dart';
import 'hub_ptt_capture.dart';
import 'hub_session.dart' show VoiceToolDeclaration, VoicePlayerFactory;
import 'native_voice_player.dart';
import 'voice_output_envelope.dart';
import 'voice_output_tap.dart';
import 'voice_turn_coordinator.dart' show VoiceTurnPresenter;
import 'voice_turn_driver.dart';

/// Thrown by [mintGeminiHubToken] on a transport failure, a non-200, or a
/// 200 body missing the `token` field.
class HubTokenMintException implements Exception {
  final String message;
  const HubTokenMintException(this.message);
  @override
  String toString() => 'HubTokenMintException: $message';
}

/// Production [HubMintToken]. Contract (lane2-log.md, 21.08 22:05):
/// `POST v2/realtime/session`, body `{"provider": "gemini"}` ->
/// `200 {"provider", "token", "expires_at"}`. Only `token` is consumed —
/// `expires_at` isn't used proactively; `HubController.mintToken` is
/// called fresh on every warm, so an early re-mint isn't needed.
Future<String> mintGeminiHubToken() async {
  final res = await makeApiCall(
    url: '${Env.apiBaseUrl}v2/realtime/session',
    headers: const {'Content-Type': 'application/json'},
    body: jsonEncode(const {'provider': 'gemini'}),
    method: 'POST',
  );
  if (res == null) {
    throw const HubTokenMintException('no response (transport error)');
  }
  if (res.statusCode != 200) {
    throw HubTokenMintException('HTTP ${res.statusCode}: ${res.body}');
  }
  final dynamic decoded = jsonDecode(res.body);
  final token = decoded is Map ? decoded['token'] : null;
  if (token is! String || token.isEmpty) {
    throw const HubTokenMintException('200 response missing "token"');
  }
  return token;
}

/// Production [HubBuildInstructions]. Static system prompt — no
/// per-user/context templating yet (a future tick that wants that plugs it
/// in here; the seam is a `String Function()`, not a constant, precisely so
/// this can grow that later without touching `hub_controller.dart`).
/// Инструкции сессии — теперь функция от ползунка эскалации (просьба Игоря
/// 24.08, см. `escalation_level.dart`). Читается `HubController`-ом при каждом
/// открытии сессии, поэтому смена уровня применяется со следующего запуска
/// голосового режима.
String buildProductionHubInstructions() => hubInstructionsForLevel(currentClaudeEscalationLevel());

/// Production [HubFetchTools]: каталог зависит от того же ползунка — на
/// крайнем левом уровне (чистый Gemini Live) инструмента ask_claude в сессии
/// нет вовсе, это структурная гарантия, а не промпт.
///
/// Промпт-константа полосы 5 (`_kHubInstructions`) здесь не воскрешается: её
/// текст переехал в `escalation_level.dart`, который собирает инструкции по
/// уровню. Правило «один филлер на ход» из того же коммита перенесено туда же.
Future<List<VoiceToolDeclaration>> fetchHubTools() async => hubToolsForLevel(currentClaudeEscalationLevel());

/// Assembles a real, network-backed [VoiceHubTurnDriver] — see file header
/// for exactly what's wired and what's deliberately still not (bootstrap
/// call site, chat UI toggle).
///
/// [applyProjection] and [pttHubEnabled] are passed straight through to
/// [VoiceHubTurnDriverDeps] (same contract, see that class's doc comments).
/// [bridgeHttpClient] defaults to [CfAccessHttpClient] — see file header's
/// "Formerly a known gap" note; pass a bare `http.Client()` or a fake to
/// override (e.g. tests, a non-tunnel deployment). [freeFormMode] defaults
/// to always-off (today's manual-VAD/PTT behavior, unchanged) so a caller
/// that hasn't wired the free-form preference yet gets the old behavior,
/// not a crash.
VoiceHubTurnDriver createProductionVoiceHubTurnDriver({
  required VoiceTurnPresenter applyProjection,
  required bool Function() pttHubEnabled,
  http.Client? bridgeHttpClient,
  bool Function() freeFormMode = _defaultFreeFormModeOff,
}) {
  // Assigned synchronously inside `createHub` below, before the
  // `VoiceHubTurnDriver` constructor returns — `toolExecutor`'s closure is
  // only ever invoked later (a real tool call arriving over the warm
  // socket), strictly after that assignment, so this `late final` is safe.
  late final HubController hub;

  final askClaudeExecutor = AskClaudeToolExecutor(
    // Voice asks for a BOUNDED agent, unlike chat — but deliberately does NOT
    // pick a model: that is the bridge's call (ASK_CLAUDE_MODEL on mini, Opus 5
    // per Игорь's standing rule), so the brain is chosen in one place instead of
    // being silently downgraded from here.
    //
    // What actually cost 90s of silence on 23.08 was an UNBOUNDED agent: the
    // same memory question ran 12 turns and the client gave up first. Capped at
    // 6 turns it answers in ~19s on Opus (~16s on Sonnet — the model was never
    // the problem, the turn count was).
    client: AskClaudeBridgeClient(
      httpClient: bridgeHttpClient ?? CfAccessHttpClient(),
      // Ten, not six: six cut the agent off mid tool call
      // (`stop_reason=tool_use`), the bridge returned empty text, and from
      // outside that was indistinguishable from an assistant gone silent.
      maxTurns: 10,
      // This IS the voice channel — see `AskClaudeBridgeClient.voice`: it buys
      // the spoken-answer style (two sentences, no markdown) and the bridge's
      // warm path, and skipping it was measured as 38.6s and an empty answer.
      voice: true,
    ),
    sendToolResult: (callId, name, output) => hub.sendToolResult(callId, name, output),
    // Non-blocking delivery: the model is released the moment it asks and keeps
    // the conversation going, and the real answer arrives here as a spoken-in
    // line. Without this the whole round trip is dead air — 44s of it, measured
    // 23.08, which the user read as the assistant having died mid-sentence.
    announce: (text) => hub.sendUserText(text),
    // …кроме высоких уровней ползунка эскалации: там доставка блокирующая —
    // модель молчит до ответа (идея 1, WORKLOG 24.08). Уровень читается на
    // каждом вызове, поэтому ползунок действует без пересоздания драйвера.
    blockingDelivery: () => currentClaudeEscalationLevel().blockingDelivery,
    // Подтверждение «услышал, думаю» в блокирующем режиме — звук (файл Игоря),
    // а не фраза «секунду, уточню» (см. earcon.dart).
    onBlockingCallStart: () => unawaited(thinkingEarcon.play()),
    // Тишина после сигнала дольше ~5 с читается как поломка — фраза о том,
    // чем мозг занят СЕЙЧАС (тип — из событий progress моста: «читаю файл»,
    // «спрашиваю память»…), и дальше каждые ~12 с, пока ответа нет (см.
    // earcon.dart: ProgressVoice). Разброс ±3 с — чтобы не метроном.
    onBlockingWait: (activity, _) => unawaited(progressVoice.play(activity)),
    blockingWaitJitter: const Duration(seconds: 3),
  );

  return VoiceHubTurnDriver(VoiceHubTurnDriverDeps(
    createHub: (events) {
      hub = HubController(
        events: events,
        buildInstructions: buildProductionHubInstructions,
        mintToken: mintGeminiHubToken,
        createSession: (spec) => buildProductionGeminiSession(spec, freeFormMode: freeFormMode()),
        fetchTools: fetchHubTools,
      );
      return hub;
    },
    startCapture: productionHubCaptureFactory(),
    applyProjection: applyProjection,
    pttHubEnabled: pttHubEnabled,
    toolExecutor: (call) {
      if (call.name == endConversationToolName) {
        // PTT-режим поход-ходовой: «разговора», который можно закончить, тут
        // нет, но незакрытый вызов подвесил бы ход модели — отвечаем no-op.
        hub.sendToolResult(call.callId, call.name, 'В этом режиме нечего выключать — продолжай.');
        return;
      }
      askClaudeExecutor.handle(call);
    },
  ));
}

/// The one place a production Gemini session is built out of the spec
/// `HubController` hands its `createSession`. Both production factories go
/// through it — they used to hand-list the same six arguments each, and the
/// two lists drifted: NEITHER passed `spec.resumptionHandle`.
///
/// That field is how a conversation survives its socket (design doc §10). The
/// controller keeps the latest handle across a teardown and offers it in the
/// spec precisely so the next socket continues the same conversation; dropping
/// it here made every rebuild silently blank — including the drop recovery,
/// which reconnects and then asks the model out loud to "продолжай с того
/// места, где мы остановились" (`CaptureController.recoverFreeFormVoiceMode`).
/// The model had never heard that place. The controller-level fix for exactly
/// this ("keeps the conversation, so the model really can continue it") was
/// tested against a fake session, so nothing caught that production threw the
/// handle away on the way to the real one.
GeminiHubSession buildProductionGeminiSession(
  HubSessionSpec spec, {
  required bool freeFormMode,
  // Обёрнутая фабрика (`envelopeTappedPlayerFactory`) снимает громкость с
  // исходящего голоса для живой иконки. По умолчанию — голый нативный плеер,
  // чтобы вызывающие, которым иконка не нужна, ничего не знали об огибающей.
  VoicePlayerFactory? playerFactory,
}) {
  return GeminiHubSession(
    token: spec.token,
    instructions: spec.instructions,
    playerFactory: playerFactory ?? nativeVoicePlayerFactory,
    events: spec.events,
    tools: spec.tools,
    resumptionHandle: spec.resumptionHandle,
    freeFormMode: freeFormMode,
  );
}

bool _defaultFreeFormModeOff() => false;

/// Assembles a real, network-backed [FreeFormVoiceMode] — the free-form
/// (server-VAD) sibling of [createProductionVoiceHubTurnDriver], same "not
/// auto-invoked" discipline (see file header): nothing calls this yet.
///
/// Deliberately built on its OWN [HubController], not the one inside a
/// [VoiceHubTurnDriver] built by [createProductionVoiceHubTurnDriver] —
/// investigated and rejected sharing one instance between the two modes
/// (lane5-log.md, tick after 503ad1ed0c): `VoiceHubTurnDriver` wires
/// `HubControllerEvents` internally against its own private `_hub` and its
/// own `_turnId` field (`voice_turn_driver.dart`'s `_hubEvents()` — e.g.
/// `onInputTranscript` bails out whenever `_turnId == null`); a turn opened
/// by [FreeFormVoiceMode] under its own minted id would drive that same
/// `HubController` while the driver's `_turnId` stays null, so every
/// transcript/speaking/tool event would be silently dropped by the driver's
/// own guards rather than routed anywhere. Splitting the controller avoids
/// that dead-drop entirely, at the cost of two independent warm sockets
/// (each mints its own token) if a caller ever ran both modes at once — an
/// accepted cost because the two modes are mutually exclusive by design
/// (one voice-input surface active at a time; the eventual UI toggle is
/// expected to tear one down before starting the other, not run both).
///
/// [events] receives every hub event the PTT driver would otherwise
/// consume (connect/error/transcript/speaking/turn-done) — required, no
/// no-op default (same discipline as `applyProjection` above: an unwired
/// sink should be visible in the caller's dependency list, not silently
/// swallowed here). `onToolRequest` on the [HubControllerEvents] you pass in
/// is never read — this factory always owns tool execution itself (real
/// `ask_claude` wiring, same as the PTT driver), exactly like
/// [createProductionVoiceHubTurnDriver] never lets a caller override that
/// either. `onCascadeHandoff` will never fire on this controller: that event
/// exists only for the PTT driver's warm-wait race
/// (`HubController.handoffWarmWaitToCascade`), which nothing here ever
/// calls — free-form mode has no warm-wait/cascade concept.
/// The mic both hub paths capture through: the app's SHARED recorder, taken
/// from [ServiceManager] rather than constructed here.
///
/// Named (instead of inlined at the two call sites) so the rule is stated
/// once and testable: a hub that builds a `NativeMicRecorderService` of its
/// own detaches conversation capture from the native event stream for the
/// rest of the process, and its arbiter handle is what makes the two
/// consumers exclusive (`arbitratedPhoneMicHandles`).
HubStartCapture productionHubCaptureFactory() =>
    nativeMicHubCaptureFactory(() => ServiceManager.instance().voiceHubMic);

FreeFormVoiceMode createProductionFreeFormVoiceMode({
  required HubControllerEvents events,
  http.Client? bridgeHttpClient,
  Duration? Function()? resolveIdleTimeout,
  void Function()? onIdleTimeout,
  void Function(bool interrupted)? onMicInterruption,
  // Модель сама заканчивает разговор инструментом end_conversation (просьба
  // Игоря 24.08). В production сюда приходит CaptureController.stopFreeFormVoiceMode
  // (стоп + сброс UI + досылка диалога в чат); без него гасим только сам режим.
  void Function()? onConversationEnd,
  // Живая иконка голосового режима дышит по громкости ответа; без огибающей
  // она просто держит темп фазы.
  VoiceOutputEnvelope? outputEnvelope,
}) {
  late final HubController hub;
  // Same `late final` idiom as `hub` above and in
  // `createProductionVoiceHubTurnDriver`: assigned below before this function
  // returns, and only ever read from a callback the live socket fires later.
  late final FreeFormVoiceMode mode;
  late final EndConversationToolHandler endHandler;

  final askClaudeExecutor = AskClaudeToolExecutor(
    // Voice asks for a BOUNDED agent, unlike chat — but deliberately does NOT
    // pick a model: that is the bridge's call (ASK_CLAUDE_MODEL on mini, Opus 5
    // per Игорь's standing rule), so the brain is chosen in one place instead of
    // being silently downgraded from here.
    //
    // What actually cost 90s of silence on 23.08 was an UNBOUNDED agent: the
    // same memory question ran 12 turns and the client gave up first. Capped at
    // 6 turns it answers in ~19s on Opus (~16s on Sonnet — the model was never
    // the problem, the turn count was).
    client: AskClaudeBridgeClient(
      httpClient: bridgeHttpClient ?? CfAccessHttpClient(),
      // Ten, not six: six cut the agent off mid tool call
      // (`stop_reason=tool_use`), the bridge returned empty text, and from
      // outside that was indistinguishable from an assistant gone silent.
      maxTurns: 10,
      // This IS the voice channel — see `AskClaudeBridgeClient.voice`: it buys
      // the spoken-answer style (two sentences, no markdown) and the bridge's
      // warm path, and skipping it was measured as 38.6s and an empty answer.
      voice: true,
    ),
    sendToolResult: (callId, name, output) => hub.sendToolResult(callId, name, output),
    // Non-blocking delivery: the model is released the moment it asks and keeps
    // the conversation going, and the real answer arrives here as a spoken-in
    // line. Without this the whole round trip is dead air — 44s of it, measured
    // 23.08, which the user read as the assistant having died mid-sentence.
    announce: (text) => hub.sendUserText(text),
    // …кроме высоких уровней ползунка эскалации: там доставка блокирующая —
    // модель молчит до ответа (идея 1, WORKLOG 24.08). Уровень читается на
    // каждом вызове, поэтому ползунок действует без пересоздания драйвера.
    blockingDelivery: () => currentClaudeEscalationLevel().blockingDelivery,
    // Подтверждение «услышал, думаю» в блокирующем режиме — звук (файл Игоря),
    // а не фраза «секунду, уточню» (см. earcon.dart).
    onBlockingCallStart: () => unawaited(thinkingEarcon.play()),
    // Тишина после сигнала дольше ~5 с читается как поломка — фраза о том,
    // чем мозг занят СЕЙЧАС (тип — из событий progress моста: «читаю файл»,
    // «спрашиваю память»…), и дальше каждые ~12 с, пока ответа нет (см.
    // earcon.dart: ProgressVoice). Разброс ±3 с — чтобы не метроном.
    onBlockingWait: (activity, _) => unawaited(progressVoice.play(activity)),
    blockingWaitJitter: const Duration(seconds: 3),
  );

  // Wrapped so every content event rearms the silence-timeout clock: the
  // timeout is there to stop billing for an ABANDONED session, and without
  // this wrapper nothing called `noteActivity()` in production at all, so a
  // live conversation was cut off a fixed interval after `start()` (see
  // `freeFormActivityEvents`).
  hub = HubController(
    events: freeFormActivityEvents(
      // copyWith, not a hand-listed copy: the only event this wiring owns is
      // the tool call (it goes to the `ask_claude` executor instead of the
      // host); everything else must reach the host untouched, including
      // events added after this line was written. Ровно этим и лечится
      // потерянный проброс onInterrupted (разметка «[прервано]» в истории,
      // 7e17880a5e): ручной список её терял, copyWith — нет.
      events.copyWith(onToolRequest: (call, identity) {
        // Модель закончила разговор сама — это не вопрос к Claude.
        if (endHandler.handle(call)) return;
        askClaudeExecutor.handle(call);
      }),
      () => mode.noteActivity(),
    ),
    buildInstructions: buildProductionHubInstructions,
    mintToken: mintGeminiHubToken,
    createSession: (spec) => buildProductionGeminiSession(
      spec,
      freeFormMode: true,
      playerFactory:
          outputEnvelope == null ? null : envelopeTappedPlayerFactory(nativeVoicePlayerFactory, outputEnvelope),
    ),
    fetchTools: fetchHubTools,
    // Анти-зомби 24.08: хаб сам себя пересоздавал через цикл «idle-close 1008
    // → re-warm» ещё полчаса после выключения режима — жёг поминутный биллинг
    // и перехватывал нативный плеер у новых сессий (повторные запуски играли
    // в закрытый трек = тишина). Тёплый сокет свободного режима имеет смысл
    // ТОЛЬКО пока сам режим работает.
    shouldStayWarm: () => mode.isRunning,
  );

  endHandler = EndConversationToolHandler(
    sendToolResult: (callId, name, output) => hub.sendToolResult(callId, name, output),
    stopMode: () => (onConversationEnd ?? mode.stop)(),
    schedule: (delay, run) => Timer(delay, run),
  );

  mode = FreeFormVoiceMode(
    hub: hub,
    startCapture: productionHubCaptureFactory(),
    mintTurnId: () => const Uuid().v4(),
    resolveIdleTimeout: resolveIdleTimeout,
    onIdleTimeout: onIdleTimeout,
    onMicInterruption: onMicInterruption,
  );
  return mode;
}
