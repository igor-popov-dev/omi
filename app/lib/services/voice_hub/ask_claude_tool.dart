// The `ask_claude` voice tool: declaration + HTTP executor against the
// "мост" bridge (`marathon/ask_claude_bridge.py` on mini), per the contract
// lane2 documented in `~/omi-jarvis/docs/ask-claude-bridge.md`
// §"Внешний доступ для голосового хаба" (22.08) — lane5.md
// §"ГЛАВНЫЙ ПРИОРИТЕТ 22.08" step 3, the first real tool this hub declares.
//
// Contract (see the doc section above for the full write-up):
//   POST https://omi-bridge.peshkomdomoy.online/ask
//   {"question": "...", "context": "" (opt.), "model": "sonnet" (opt.),
//    "tools_enabled": true|false (opt., default false)}
//   -> text/event-stream, "data: {...}\n\n" per line:
//        {"type": "delta", "text": "..."}  (repeated)
//        {"type": "done", "text": "<full answer>"}
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
  final int? maxTurns;

  AskClaudeBridgeClient({
    required this.httpClient,
    Uri? endpoint,
    this.model,
    this.maxTurns,
  }) : endpoint = endpoint ?? Uri.parse('https://omi-bridge.peshkomdomoy.online/ask');

  /// Sends one question, collects the streamed SSE reply, and returns the
  /// final `done` text (falling back to the concatenated `delta`s if a
  /// `done` event never arrives — defensive, the bridge always sends one).
  /// Throws [AskClaudeBridgeException] on a non-200 response; a network/
  /// decode failure propagates as-is (the caller — [AskClaudeToolExecutor] —
  /// turns either into a tool-result error string, never lets it crash the
  /// turn).
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
        // Ответ пойдёт в озвучку: мост включает правила устного стиля (короче
        // двух фраз, без списков) — в речи структура не читается, а секунды стоит.
        'voice': true,
        'tools_enabled': toolsEnabled,
      });
    final streamed = await httpClient.send(request);
    if (streamed.statusCode != 200) {
      final body = await streamed.stream.bytesToString();
      throw AskClaudeBridgeException('bridge HTTP ${streamed.statusCode}: $body');
    }
    final deltaBuffer = StringBuffer();
    String? doneText;
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
      final text = event['text'];
      if (text is! String) continue;
      switch (event['type']) {
        case 'delta':
          deltaBuffer.write(text);
        case 'done':
          doneText = text;
      }
    }
    return doneText ?? deltaBuffer.toString();
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

  /// Speaks a line into the live session (typically `HubController.sendUserText`).
  ///
  /// When present, the tool stops BLOCKING the conversation: the model is
  /// released immediately with a short "it's coming" result and keeps talking,
  /// and the real answer is delivered here whenever it lands. Without it the
  /// executor keeps the old behaviour — the model waits in silence for the
  /// round trip, which measured 44s on 23.08 and read to the user as a dead
  /// assistant.
  final void Function(String text)? announce;

  AskClaudeToolExecutor({
    required this.client,
    required this.sendToolResult,
    this.announce,
    this.timeout = const Duration(seconds: 60),
  });

  /// Handed to the model the instant it asks, so it can carry the conversation
  /// instead of standing still. Deliberately an instruction, not data: a bare
  /// "pending" string got read out loud as if it were the answer.
  static const String _pendingResult =
      'Запрос отправлен умной модели. Ответа пока НЕТ — не выдумывай его и не пересказывай. '
      'Продолжай разговор обычным образом; готовый ответ придёт отдельной репликой, '
      'и тогда ты озвучишь его.';

  /// Prefix for the delivered answer. Tells the model this is material to voice,
  /// not a new question from the user.
  static const String _answerPrefix =
      'Пришёл ответ от умной модели на твой запрос. Озвучь его своими словами, коротко, '
      'вклинившись в разговор естественно (например «так, ответ есть»). Вот он: ';

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
    final deliverOutOfBand = announce;
    if (deliverOutOfBand != null) {
      // Release the turn first: everything after this happens while the model
      // is free to keep talking.
      sendToolResult(call.callId, call.name, _pendingResult);
    }
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
    if (deliverOutOfBand != null) {
      deliverOutOfBand(failed ? output : '$_answerPrefix$output');
      return;
    }
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
      return await client.ask(question: question, toolsEnabled: useTools).timeout(timeout);
    } on TimeoutException {
      // Phrased as an instruction, not a bare error: this string is what the
      // model reads before speaking, and silence is the failure we are fixing.
      return 'Error: ask_claude did not answer within ${timeout.inSeconds} seconds. '
          'Tell the user briefly that the lookup is taking too long, then answer from '
          'what you already know if you can.';
    } catch (e) {
      return 'Error: ask_claude bridge call failed: $e';
    }
  }
}
