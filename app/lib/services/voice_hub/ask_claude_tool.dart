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
      'по себе. Прежде чем вызвать инструмент, ОБЯЗАТЕЛЬНО вслух скажи короткую фразу вроде '
      '"секунду, уточню" — вызов может занять несколько секунд, и без этой фразы будет '
      'немая пауза.',
  parameters: {
    'type': 'object',
    'properties': {
      'question': {
        'type': 'string',
        'description': 'Вопрос пользователя дословно или перефразированный, с нужным контекстом.',
      },
      'use_tools': {
        'type': 'boolean',
        'description': 'true, только если пользователь явно просит проверить память/факты/'
            'найти что-то в интернете; false для обычного рассуждения без побочных вызовов. '
            'По умолчанию false.',
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

  AskClaudeBridgeClient({
    required this.httpClient,
    Uri? endpoint,
    this.model,
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

  AskClaudeToolExecutor({required this.client, required this.sendToolResult});

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
    final output = await _resolve(call);
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
    final useTools = args['use_tools'] == true;
    try {
      return await client.ask(question: question, toolsEnabled: useTools);
    } catch (e) {
      return 'Error: ask_claude bridge call failed: $e';
    }
  }
}
