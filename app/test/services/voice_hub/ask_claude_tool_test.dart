// Tests for `ask_claude_tool.dart` — the bridge HTTP client (SSE contract per
// `~/omi-jarvis/docs/ask-claude-bridge.md` §"Внешний доступ для голосового
// хаба") and the `HubToolCallRequest` -> `sendToolResult` executor.
import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:omi/services/voice_hub/ask_claude_tool.dart';
import 'package:omi/services/voice_hub/hub_session.dart';

String _sse(List<Map<String, dynamic>> events) => events.map((e) => 'data: ${jsonEncode(e)}\n\n').join();

/// `http.Response`'s string constructor defaults to latin1 unless the
/// content-type header says otherwise — matches this port's real traffic
/// (the bridge's `text/event-stream` responses carry non-ASCII Russian
/// text), so tests with Cyrillic response bodies need this header.
const _utf8EventStreamHeaders = {'content-type': 'text/event-stream; charset=utf-8'};

typedef _ToolResult = ({String callId, String name, String output});

/// A [sendToolResult] callback wired to a completer, so executor tests can
/// `await` the async HTTP round trip instead of guessing a fixed tick count.
({void Function(String, String, String) callback, Future<_ToolResult> result}) _toolResultRecorder() {
  final completer = Completer<_ToolResult>();
  void callback(String callId, String name, String output) {
    if (!completer.isCompleted) completer.complete((callId: callId, name: name, output: output));
  }

  return (callback: callback, result: completer.future);
}

void main() {
  group('AskClaudeBridgeClient', () {
    test('POSTs the documented JSON contract to the configured endpoint', () async {
      http.Request? captured;
      final client = AskClaudeBridgeClient(
        endpoint: Uri.parse('https://omi-bridge.example/ask'),
        model: 'sonnet',
        httpClient: MockClient((request) async {
          captured = request;
          return http.Response(
              _sse([
                {'type': 'done', 'text': 'ok'}
              ]),
              200);
        }),
      );

      await client.ask(question: 'который час?', context: 'CTX', toolsEnabled: true);

      expect(captured, isNotNull);
      expect(captured!.method, 'POST');
      expect(captured!.url, Uri.parse('https://omi-bridge.example/ask'));
      expect(captured!.headers['Content-Type'], 'application/json');
      expect(jsonDecode(captured!.body), {
        'question': 'который час?',
        'context': 'CTX',
        'model': 'sonnet',
        'tools_enabled': true,
      });
    });

    test('defaults to the documented production endpoint when none injected', () async {
      http.Request? captured;
      final client = AskClaudeBridgeClient(
        httpClient: MockClient((request) async {
          captured = request;
          return http.Response(
              _sse([
                {'type': 'done', 'text': 'ok'}
              ]),
              200);
        }),
      );
      await client.ask(question: 'q');
      expect(captured!.url, Uri.parse('https://omi-bridge.peshkomdomoy.online/ask'));
    });

    test('omits context/model/tools_enabled defaults from the body when not overridden', () async {
      http.Request? captured;
      final client = AskClaudeBridgeClient(
        httpClient: MockClient((request) async {
          captured = request;
          return http.Response(
              _sse([
                {'type': 'done', 'text': 'ok'}
              ]),
              200);
        }),
      );
      await client.ask(question: 'q');
      final body = jsonDecode(captured!.body) as Map<String, dynamic>;
      expect(body.containsKey('context'), isFalse);
      expect(body.containsKey('model'), isFalse);
      expect(body['tools_enabled'], false);
    });

    test('returns the final "done" text, ignoring interleaved "delta" events', () async {
      final client = AskClaudeBridgeClient(
        httpClient: MockClient((request) async {
          return http.Response(
            _sse([
              {'type': 'delta', 'text': 'Т'},
              {'type': 'delta', 'text': 'ест'},
              {'type': 'done', 'text': 'Тест'},
            ]),
            200,
            headers: _utf8EventStreamHeaders,
          );
        }),
      );
      expect(await client.ask(question: 'q'), 'Тест');
    });

    test('falls back to the concatenated deltas if no "done" event ever arrives (defensive)', () async {
      final client = AskClaudeBridgeClient(
        httpClient: MockClient((request) async {
          return http.Response(
            _sse([
              {'type': 'delta', 'text': 'a'},
              {'type': 'delta', 'text': 'b'},
            ]),
            200,
          );
        }),
      );
      expect(await client.ask(question: 'q'), 'ab');
    });

    test('ignores non-"data: " lines and malformed JSON payloads', () async {
      final client = AskClaudeBridgeClient(
        httpClient: MockClient((request) async {
          return http.Response(
              '\n: comment\nnot-a-data-line\ndata: {not json}\n${_sse([
                    {'type': 'done', 'text': 'ok'}
                  ])}',
              200);
        }),
      );
      expect(await client.ask(question: 'q'), 'ok');
    });

    test('throws AskClaudeBridgeException on a non-200 response', () async {
      final client = AskClaudeBridgeClient(
        httpClient: MockClient((request) async => http.Response('unauthorized', 401)),
      );
      await expectLater(
        client.ask(question: 'q'),
        throwsA(isA<AskClaudeBridgeException>()),
      );
    });
  });

  group('AskClaudeToolExecutor', () {
    test('ignores a tool call whose name is not ask_claude', () async {
      var calls = 0;
      final client = AskClaudeBridgeClient(httpClient: MockClient((r) async {
        calls += 1;
        return http.Response(
            _sse([
              {'type': 'done', 'text': 'x'}
            ]),
            200);
      }));
      final results = <({String callId, String name, String output})>[];
      final executor = AskClaudeToolExecutor(
        client: client,
        sendToolResult: (callId, name, output) => results.add((callId: callId, name: name, output: output)),
      );

      executor.handle(const HubToolCallRequest(name: 'other_tool', callId: 'c1', argumentsJson: '{}'));
      await Future<void>.value();

      expect(calls, 0);
      expect(results, isEmpty);
    });

    test('parses question/use_tools and relays the bridge answer via sendToolResult', () async {
      http.Request? captured;
      final client = AskClaudeBridgeClient(httpClient: MockClient((r) async {
        captured = r;
        return http.Response(
            _sse([
              {'type': 'done', 'text': 'ANSWER'}
            ]),
            200);
      }));
      final recorder = _toolResultRecorder();
      final executor = AskClaudeToolExecutor(client: client, sendToolResult: recorder.callback);

      executor.handle(HubToolCallRequest(
        name: askClaudeToolName,
        callId: 'call-1',
        argumentsJson: jsonEncode({'question': 'который час?', 'use_tools': true}),
      ));
      final result = await recorder.result;

      expect(jsonDecode(captured!.body)['tools_enabled'], true);
      expect(result, (callId: 'call-1', name: askClaudeToolName, output: 'ANSWER'));
    });

    test('a missing/empty question never calls the bridge and returns an error result', () async {
      var calls = 0;
      final client = AskClaudeBridgeClient(httpClient: MockClient((r) async {
        calls += 1;
        return http.Response('', 200);
      }));
      final results = <({String callId, String name, String output})>[];
      final executor = AskClaudeToolExecutor(
        client: client,
        sendToolResult: (callId, name, output) => results.add((callId: callId, name: name, output: output)),
      );

      executor.handle(HubToolCallRequest(name: askClaudeToolName, callId: 'c1', argumentsJson: jsonEncode({})));
      await Future<void>.value();
      await Future<void>.value();

      expect(calls, 0);
      expect(results.single.output, contains('Error'));
    });

    test('malformed argumentsJson never throws — surfaces as an error tool result', () async {
      final client = AskClaudeBridgeClient(httpClient: MockClient((r) async => http.Response('', 200)));
      final results = <({String callId, String name, String output})>[];
      final executor = AskClaudeToolExecutor(
        client: client,
        sendToolResult: (callId, name, output) => results.add((callId: callId, name: name, output: output)),
      );

      executor.handle(const HubToolCallRequest(name: askClaudeToolName, callId: 'c1', argumentsJson: 'not json'));
      await Future<void>.value();
      await Future<void>.value();

      expect(results.single.output, contains('Error'));
    });

    test('a bridge failure never throws — surfaces as an error tool result so the model can recover', () async {
      final client = AskClaudeBridgeClient(httpClient: MockClient((r) async => http.Response('boom', 500)));
      final recorder = _toolResultRecorder();
      final executor = AskClaudeToolExecutor(client: client, sendToolResult: recorder.callback);

      executor.handle(HubToolCallRequest(
        name: askClaudeToolName,
        callId: 'c1',
        argumentsJson: jsonEncode({'question': 'q'}),
      ));
      final result = await recorder.result;

      expect(result.output, contains('Error'));
    });

    test('a hung bridge still answers the call — the model never sits in silence forever', () async {
      // Never completes: the failure this guards is a bridge that accepts the
      // request and then goes quiet, which used to leave the turn hanging with
      // no tool result and no speech.
      final client = AskClaudeBridgeClient(httpClient: MockClient((r) => Completer<http.Response>().future));
      final recorder = _toolResultRecorder();
      final executor = AskClaudeToolExecutor(
        client: client,
        sendToolResult: recorder.callback,
        timeout: const Duration(milliseconds: 20),
      );

      executor.handle(HubToolCallRequest(
        name: askClaudeToolName,
        callId: 'c1',
        argumentsJson: jsonEncode({'question': 'q'}),
      ));
      final result = await recorder.result;

      expect(result.callId, 'c1');
      expect(result.output, contains('Error'));
      // The result doubles as a speaking instruction, so the model says
      // something instead of just swallowing an error code.
      expect(result.output, contains('Tell the user'));
    });
  });
}
