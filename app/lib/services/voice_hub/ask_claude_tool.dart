// The `ask_claude` voice tool: declaration + HTTP executor against the
// "мост" bridge (`marathon/ask_claude_bridge.py` on mini), per the contract
// lane2 documented in `~/omi-jarvis/docs/ask-claude-bridge.md`
// §"Внешний доступ для голосового хаба" (22.08) — lane5.md
// §"ГЛАВНЫЙ ПРИОРИТЕТ 22.08" step 3, the first real tool this hub declares.
//
// Contract (see the doc section above for the full write-up):
//   POST https://omi-bridge.peshkomdomoy.online/ask
//   {"question": "...", "context": "" (opt.), "model": "sonnet" (opt.),
//    "tools_enabled": true|false (opt., default false),
//    "voice": true|false (opt., default false)}
//   -> text/event-stream, "data: {...}\n\n" per line:
//        {"type": "delta", "text": "..."}  (repeated)
//        {"type": "done", "text": "<full answer>"}
//        {"type": "error", "code": "...", "message": "..."}  (instead of done)
//
// Auth: NOT handled here. Per lane2-log.md ("наружу через туннель", 21.08
// вечер) the bridge sits behind the same Cloudflare Access application as
// the rest of the self-host tunnel, gated on the same two headers,
// CF-Access-Client-Id/Secret. Correction to an earlier version of this
// comment: there is no *generic intercepting* `http.Client` anywhere in
// this app to inject — `buildHeaders` (backend/http/shared.dart) is a
// header-builder consumed by `makeApiCall` and friends, each constructing
// its own `http.Request`, not a wrapped client. Production wiring
// (`voice_hub_production.dart`) constructs `AskClaudeBridgeClient` with
// `CfAccessHttpClient` (`cf_access_http_client.dart`), a small decorator
// built for this seam that reads the same `Env.cfAccessClientId`/
// `cfAccessClientSecret` dart-defines `buildHeaders` does. This port has no
// `~/.secrets` access story and must not duplicate credential logic
// (night-task.md: secrets only via `~/bin/secret`, never re-implemented —
// dart-defines are build-time config, not a secrets store, same as every
// other credential this app already ships this way). A bare client is fine
// for tests (fake, no network).
//
// `tools_enabled` on the bridge gates MCP (memory/mempalace/web search) for
// this one call — per the doc, true is for an explicit user command only;
// ambient/background use must stay false. The caller (whatever wires
// `AskClaudeToolExecutor` into a live turn) decides this per-call via the
// model-supplied `use_tools` argument — NOT a fixed default here, so the
// gate reflects THIS invocation, not just "the hub always/never wants it".
import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'package:omi/utils/logger.dart';

import 'hub_session.dart' show HubToolCallRequest, VoiceToolDeclaration;

/// The name Gemini must call to reach the bridge — matches
/// [askClaudeToolDeclaration.name] and the argument shape both the setup
/// frame and [AskClaudeToolExecutor] agree on.
const String askClaudeToolName = 'ask_claude';

/// The tool declaration to include in a hub's `tools` catalog
/// (`HubController(fetchTools: ...)` / `BaseHubSession.tools`). Plain JSON
/// Schema — `gemini_tool_schema.dart` projects it onto Gemini's wire subset.
const VoiceToolDeclaration askClaudeToolDeclaration = VoiceToolDeclaration(
  name: askClaudeToolName,
  description: 'Задай сложный вопрос "умной модели" (Claude Opus на подписке Игоря) через '
      'приватный мост — используй для многошаговых рассуждений, разбора кода, доступа к '
      'памяти (omi/mempalace) или веб-поиска, которые ты сам сделать не можешь. Вызывай '
      'ТОЛЬКО по явной просьбе пользователя в этом же ходе разговора, никогда фоново/сам '
      'по себе. СНАЧАЛА вслух скажи ровно "секунду, уточню" и ТОЛЬКО ПОТОМ вызывай '
      'инструмент — вызов занимает несколько секунд, и фраза, сказанная после результата, '
      'бесполезна: пользователь уже отсидел паузу в тишине.',
  parameters: {
    'type': 'object',
    'properties': {
      'question': {
        'type': 'string',
        'description': 'Вопрос пользователя дословно или перефразированный, с нужным контекстом.',
      },
      'use_tools': {
        'type': 'boolean',
        'description': 'По умолчанию true: с ним у "умной модели" есть память (omi/mempalace) '
            'и веб-поиск. Ставь false ТОЛЬКО для чистого рассуждения, которому не нужны ни '
            'факты о пользователе, ни что-либо из интернета — без инструментов модель не '
            'знает о пользователе ничего.',
      },
    },
    'required': ['question'],
  },
);

const List<String> _ruWeekdays = [
  'понедельник',
  'вторник',
  'среда',
  'четверг',
  'пятница',
  'суббота',
  'воскресенье',
];

const List<String> _ruMonthsGenitive = [
  'января',
  'февраля',
  'марта',
  'апреля',
  'мая',
  'июня',
  'июля',
  'августа',
  'сентября',
  'октября',
  'ноября',
  'декабря',
];

String _two(int value) => value.toString().padLeft(2, '0');

/// The one fact the bridge cannot look up: what time it is for the user.
///
/// Measured live on 23.08 against the real bridge: asked «который час и что у
/// меня в памяти про kadrio?» — the exact question Игорь named as the
/// acceptance check for voice mode — the brain answered «точное время сказать
/// не могу … известна только дата из контекста» and burned ~20s on memory
/// tools. Handed the same question with this line in `context` it answered
/// «19:37, воскресенье, 23 августа 2026 (UTC+03:00)» in 4s. The clock has to
/// come from the client: the bridge process has no notion of where the user
/// is, and `claude -p` has no shell in that sandbox to ask.
///
/// Deliberately self-describing («Время на устройстве пользователя: …»)
/// because the bridge wraps whatever it gets under the header «Контекст из
/// памяти omi:» (`ask_claude_bridge.py` `build_prompt`) — the sentence has to
/// read correctly under a header that calls it memory.
///
/// Formatted by hand rather than through `intl`: this string is built on a
/// voice turn, where a missing `initializeDateFormatting` locale would throw
/// mid-call, and the vocabulary needed is two fixed lists.
String deviceClockContext(DateTime local) {
  final offset = local.timeZoneOffset;
  final sign = offset.isNegative ? '-' : '+';
  final absolute = offset.abs();
  final utcOffset = 'UTC$sign${_two(absolute.inHours)}:${_two(absolute.inMinutes.remainder(60))}';
  return 'Время на устройстве пользователя: '
      '${_ruWeekdays[local.weekday - 1]}, '
      '${local.day} ${_ruMonthsGenitive[local.month - 1]} ${local.year}, '
      '${_two(local.hour)}:${_two(local.minute)} ($utcOffset).';
}

class AskClaudeBridgeException implements Exception {
  final String message;
  const AskClaudeBridgeException(this.message);
  @override
  String toString() => 'AskClaudeBridgeException: $message';
}

/// Talks the bridge's `/ask` SSE contract. Injectable [httpClient] +
/// [endpoint] so tests never touch the network; production passes a
/// `CfAccessHttpClient` (see file header).
class AskClaudeBridgeClient {
  final Uri endpoint;
  final http.Client httpClient;

  /// Bridge-side default is `opus` (mini plist `ASK_CLAUDE_MODEL`); the doc
  /// explicitly calls out overriding to something cheaper (e.g. `sonnet`)
  /// for a hub's more frequent calls — left null (bridge default) unless a
  /// caller opts in.
  final String? model;

  /// Ceiling on the agent's turns for one answer. A conversation cannot wait
  /// out an unbounded agent: measured 23.08, an unlimited memory question ran
  /// 12 turns / 90s on Opus, while the same question capped at 6 turns on
  /// Sonnet answered in 16s. Null keeps the bridge's own (unbounded) default.
  ///
  /// Note (measured 24.08): the bridge's WARM path — the one [voice] selects —
  /// caps turns per long-lived client (`ASK_CLAUDE_WARM_MAX_TURNS`, default 10)
  /// and ignores this per-request field. It still travels, because any warm
  /// failure falls back to the cold `claude -p`, which does honour it.
  final int? maxTurns;

  /// Declares this call as the VOICE channel, which the bridge treats as its
  /// own path — not a cosmetic flag (`ask_claude_bridge.py`: `warm_eligible`,
  /// `VOICE_STYLE`). Without it a spoken answer gets neither half of what the
  /// bridge built for voice, and both halves are load-bearing here:
  ///
  ///  * Style. The answer is read out loud, so `VOICE_STYLE` caps it at two
  ///    sentences / 50 words and bans markdown, lists and links. Without the
  ///    flag the brain answers in chat shape — Charon reads bullet points and
  ///    headings out loud, and the wait is measured in sentences the user did
  ///    not ask for.
  ///  * Latency. Only `tools_enabled && voice` reaches the warm
  ///    `ClaudeSDKClient`, where the process and every MCP server are already
  ///    up. Measured 24.08 against the live bridge with the same question and
  ///    context: warm answered in 21.7s, the cold path burned 38.6s and
  ///    returned an EMPTY answer.
  ///
  /// Default false so the class stays honest for any non-voice caller; the
  /// hub's production wiring (`voice_hub_production.dart`) passes true.
  final bool voice;

  AskClaudeBridgeClient({
    required this.httpClient,
    Uri? endpoint,
    this.model,
    this.maxTurns,
    this.voice = false,
  }) : endpoint = endpoint ?? Uri.parse('https://omi-bridge.peshkomdomoy.online/ask');

  /// Sends one question, collects the streamed SSE reply, and returns the
  /// final `done` text (falling back to the concatenated `delta`s if a
  /// `done` event never arrives — defensive, the bridge always sends one).
  ///
  /// Throws [AskClaudeBridgeException] on a non-200 response, on the bridge's
  /// own `error` event, and on an empty answer; a network/decode failure
  /// propagates as-is (the caller — [AskClaudeToolExecutor] — turns any of
  /// them into a tool-result error string, never lets it crash the turn).
  ///
  /// The last two are not defensive padding — both were reproduced live on
  /// 24.08. The bridge answers a failed run with a 200 and
  /// `{"type": "error", "code": "cli_failed", "message": "claude -p завершился
  /// с кодом 1"}` — which happens whenever the agent hits its turn cap mid-work
  /// — and this loop used to skip that event for having no `text`, hand back an
  /// empty string, and let the model speak on top of a tool result that said
  /// nothing at all. An empty answer is treated the same way and for the same
  /// reason: the point of this call is words to say out loud, and zero of them
  /// is a failure the user must hear about, not silence to paper over.
  Future<String> ask({
    required String question,
    String context = '',
    bool toolsEnabled = false,
  }) async {
    final request = http.Request('POST', endpoint)
      ..headers['Content-Type'] = 'application/json'
      ..body = jsonEncode({
        'question': question,
        if (context.isNotEmpty) 'context': context,
        if (model != null) 'model': model,
        if (maxTurns != null) 'max_turns': maxTurns,
        'tools_enabled': toolsEnabled,
        if (voice) 'voice': true,
      });
    final streamed = await httpClient.send(request);
    if (streamed.statusCode != 200) {
      final body = await streamed.stream.bytesToString();
      throw AskClaudeBridgeException('bridge HTTP ${streamed.statusCode}: $body');
    }
    final deltaBuffer = StringBuffer();
    String? doneText;
    String? bridgeError;
    final lines = streamed.stream.transform(utf8.decoder).transform(const LineSplitter());
    await for (final line in lines) {
      if (!line.startsWith('data: ')) continue;
      final jsonStr = line.substring('data: '.length);
      if (jsonStr.isEmpty) continue;
      Object? event;
      try {
        event = jsonDecode(jsonStr);
      } catch (_) {
        continue; // a malformed/partial line — same fail-open spirit as the bridge's own NDJSON parsing
      }
      if (event is! Map<String, dynamic>) continue;
      if (event['type'] == 'error') {
        // Kept, not thrown on the spot: the bridge may still have streamed
        // partial deltas before failing, and those are worth speaking. Only
        // an error with nothing to say becomes the throw below.
        final code = event['code'];
        final message = event['message'];
        bridgeError = [
          if (code is String && code.isNotEmpty) code,
          if (message is String && message.isNotEmpty) message,
        ].join(': ');
        continue;
      }
      final text = event['text'];
      if (text is! String) continue;
      switch (event['type']) {
        case 'delta':
          deltaBuffer.write(text);
        case 'done':
          doneText = text;
      }
    }
    final answer = doneText ?? deltaBuffer.toString();
    if (answer.isNotEmpty) return answer;
    throw AskClaudeBridgeException(
        bridgeError == null ? 'bridge returned an empty answer' : 'bridge error: $bridgeError');
  }
}

/// Wires `HubToolCallRequest`/`HubController.sendToolResult` to
/// [AskClaudeBridgeClient] for exactly the `ask_claude` tool. Any other tool
/// name is ignored (a future second tool gets its own executor — this one
/// stays single-purpose, matching how `sanitizeGeminiToolSchema` and the
/// declaration above are also `ask_claude`-specific today).
class AskClaudeToolExecutor {
  final AskClaudeBridgeClient client;

  /// Typically `HubController.sendToolResult` — kept as a plain function
  /// seam (not a `HubController` reference) so this class is testable
  /// without constructing one.
  final void Function(String callId, String name, String output) sendToolResult;

  /// Deadline for one bridge round trip.
  ///
  /// A voice turn cannot wait indefinitely: until a tool result arrives the
  /// model stays silent, so a bridge that hangs reads to the user as the
  /// assistant having died mid-sentence, with no way out but killing the
  /// session. On expiry we answer the call ourselves with an error result —
  /// the model gets its turn back and can say what happened out loud.
  ///
  /// Sized against measured calls, not a guess: a memory-backed answer runs
  /// ~16s once the bridge is asked for a bounded agent (Sonnet, capped turns),
  /// and the previous 45s ceiling was itself hit live on 23.08 by an unbounded
  /// 90s call. The headroom is for a cold start, not for waiting out an agent
  /// that forgot to stop — that is what the bridge-side turn cap is for.
  final Duration timeout;

  /// Клок устройства — сюда, чтобы тесты не зависели от настоящего времени.
  /// Production leaves the default: the phone's own clock is the user's real
  /// time and timezone, which is exactly what [deviceClockContext] states.
  final DateTime Function() now;

  AskClaudeToolExecutor({
    required this.client,
    required this.sendToolResult,
    this.timeout = const Duration(seconds: 60),
    this.now = DateTime.now,
  });

  /// Feed this directly to `HubControllerEvents.onToolRequest` /
  /// `HubSessionEvents.onToolRequest`. Fire-and-forget by design — a hub
  /// tool call must not block the turn machine waiting on the HTTP round
  /// trip; the result reaches the model later via [sendToolResult], same as
  /// every other async tool-execution path in this app
  /// (`voiceToolExecute`'s TS analogue never throws either).
  void handle(HubToolCallRequest call) {
    if (call.name != askClaudeToolName) return;
    unawaited(_run(call));
  }

  Future<void> _run(HubToolCallRequest call) async {
    // Self-host patch: this round trip used to be invisible. When it failed the
    // model simply went quiet and the mode died, and logcat showed nothing at
    // all — no way to tell a network drop from a call that was never made
    // (reported 23.08). Timings and outcome are logged; the question and the
    // answer are not, they are user content.
    final startedAt = DateTime.now();
    Logger.debug('[ask_claude] запрос ${call.callId} -> ${client.endpoint}');
    final output = await _resolve(call);
    final elapsed = DateTime.now().difference(startedAt);
    final failed = output.startsWith('Error:');
    final summary = '[ask_claude] ${call.callId} ${failed ? 'ОШИБКА' : 'ответ'} '
        'за ${elapsed.inMilliseconds} мс, ${output.length} символов';
    failed ? Logger.error('$summary: $output') : Logger.debug(summary);
    sendToolResult(call.callId, call.name, output);
  }

  Future<String> _resolve(HubToolCallRequest call) async {
    final Map<String, dynamic> args;
    try {
      final decoded = jsonDecode(call.argumentsJson);
      args = decoded is Map<String, dynamic> ? decoded : const {};
    } catch (e) {
      return 'Error: could not parse ask_claude arguments: $e';
    }
    final question = args['question'];
    if (question is! String || question.isEmpty) {
      return 'Error: ask_claude called without a question';
    }
    // Default ON, not off: without tools the bridge starts Claude with no MCP servers at
    // all, so it knows nothing about the user and answers "I have no memory tools" — the
    // exact failure this tool exists to avoid. Only an explicit false opts out.
    final useTools = args['use_tools'] != false;
    try {
      return await client
          .ask(question: question, context: deviceClockContext(now()), toolsEnabled: useTools)
          .timeout(timeout);
    } on TimeoutException {
      // Phrased as an instruction, not a bare error: this string is what the
      // model reads before speaking, and silence is the failure we are fixing.
      return 'Error: ask_claude did not answer within ${timeout.inSeconds} seconds. '
          'Tell the user briefly that the lookup is taking too long, then answer from '
          'what you already know if you can.';
    } catch (e) {
      // Same shape as the timeout above and for the same reason: the model
      // reads this before speaking, so it has to say what to DO, not just
      // what broke. The raw cause stays in it for the log — Logger.error in
      // [_run] prints exactly this string.
      return 'Error: ask_claude bridge call failed: $e. Tell the user briefly that '
          'the lookup failed, then answer from what you already know if you can.';
    }
  }
}
