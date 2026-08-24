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
        // No `voice` here on purpose: this client was built without the flag,
        // and the spoken-channel declaration has its own test below ('declares
        // the voice channel when asked'). Keeping it out of the base contract
        // is what stops a non-voice caller from being silently reshaped into
        // a voice one.
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
      expect(body.containsKey('voice'), isFalse);
      expect(body['tools_enabled'], false);
    });

    test('declares the voice channel when asked — the bridge routes on this flag', () async {
      // Not cosmetic: `voice` is what selects the bridge's warm path AND the
      // spoken-answer style. Measured live 24.08 with the same question and
      // context — with the flag 21.7s and 22 words, without it 38.6s and an
      // empty answer.
      http.Request? captured;
      final client = AskClaudeBridgeClient(
        voice: true,
        httpClient: MockClient((request) async {
          captured = request;
          return http.Response(
              _sse([
                {'type': 'done', 'text': 'ok'}
              ]),
              200);
        }),
      );

      await client.ask(question: 'q', toolsEnabled: true);

      expect(jsonDecode(captured!.body)['voice'], true);
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

    test('an "error" event with nothing spoken becomes a throw, not an empty answer', () async {
      // Reproduced live 24.08: an agent that hits its turn cap makes the bridge
      // answer 200 + {"type":"error","code":"cli_failed",...}. This loop used
      // to skip that event for having no `text` and hand back "" — the model
      // then spoke on top of a tool result that said nothing at all.
      final client = AskClaudeBridgeClient(
        httpClient: MockClient((request) async {
          return http.Response(
            _sse([
              {'type': 'error', 'code': 'cli_failed', 'message': 'claude -p завершился с кодом 1'}
            ]),
            200,
            headers: _utf8EventStreamHeaders,
          );
        }),
      );
      await expectLater(
        client.ask(question: 'q'),
        throwsA(isA<AskClaudeBridgeException>()
            .having((e) => e.message, 'message', allOf(contains('cli_failed'), contains('код')))),
      );
    });

    test('deltas already streamed survive a late "error" event — words beat the error', () async {
      final client = AskClaudeBridgeClient(
        httpClient: MockClient((request) async {
          return http.Response(
            _sse([
              {'type': 'delta', 'text': 'Половина ответа'},
              {'type': 'error', 'code': 'cli_failed', 'message': 'boom'},
            ]),
            200,
            headers: _utf8EventStreamHeaders,
          );
        }),
      );
      expect(await client.ask(question: 'q'), 'Половина ответа');
    });

    test('an HTML rejection names Cloudflare Access instead of a bare status code', () async {
      // Measured 24.08: a call without CF-Access credentials is not answered
      // 403 — Access redirects to its login page, the client follows, and the
      // app sees an HTML 404 from a host that works fine seconds later.
      final client = AskClaudeBridgeClient(
        httpClient: MockClient((request) async =>
            http.Response('<html>${'x' * 5000}</html>', 404, headers: {'content-type': 'text/html; charset=UTF-8'})),
      );
      await expectLater(
        client.ask(question: 'q'),
        throwsA(isA<AskClaudeBridgeException>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('404'),
              contains('Cloudflare Access'),
              // The page body must not ride along into the model's context.
              predicate<String>((m) => m.length < 400, 'is truncated'),
            ))),
      );
    });

    test('an empty answer is a failure, not silence to pass along', () async {
      final client = AskClaudeBridgeClient(
        httpClient: MockClient((request) async {
          return http.Response(
              _sse([
                {'type': 'done', 'text': ''}
              ]),
              200);
        }),
      );
      await expectLater(
        client.ask(question: 'q'),
        throwsA(isA<AskClaudeBridgeException>().having((e) => e.message, 'message', contains('empty'))),
      );
    });

    test('an empty bridge answer reaches the model as a speaking instruction', () async {
      final client = AskClaudeBridgeClient(
        httpClient: MockClient((request) async {
          return http.Response(
              _sse([
                {'type': 'error', 'code': 'cli_failed', 'message': 'boom'}
              ]),
              200);
        }),
      );
      final recorder = _toolResultRecorder();
      final executor = AskClaudeToolExecutor(client: client, sendToolResult: recorder.callback);

      executor.handle(HubToolCallRequest(
        name: askClaudeToolName,
        callId: 'c1',
        argumentsJson: jsonEncode({'question': 'q'}),
      ));
      final result = await recorder.result;

      expect(result.output, contains('Error'));
      expect(result.output, contains('Tell the user'));
      expect(result.output, contains('cli_failed'));
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

  group('deviceClockContext', () {
    test('states the device clock in Russian, self-describing under the bridge memory header', () {
      // 23.08.2026 — воскресенье; the offset suffix depends on the machine's
      // timezone, so only the deterministic prefix is pinned here (UTC offset
      // formatting has its own test below).
      final text = deviceClockContext(DateTime(2026, 8, 23, 19, 37));

      expect(text, startsWith('Время на устройстве пользователя: воскресенье, 23 августа 2026, 19:37 (UTC'));
      expect(text, endsWith(').'));
    });

    test('pads single-digit hours and minutes', () {
      expect(deviceClockContext(DateTime(2026, 1, 5, 9, 4)), contains('понедельник, 5 января 2026, 09:04'));
    });

    test('formats the UTC offset with sign and padding', () {
      // A UTC DateTime has a zero timeZoneOffset on every machine — the one
      // offset value a test can pin without depending on the host timezone.
      expect(deviceClockContext(DateTime.utc(2026, 8, 23, 19, 37)), endsWith('(UTC+00:00).'));
    });
  });

  group('AskClaudeToolExecutor', () {
    test('answers a tool call it does not own instead of dropping it', () async {
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

      expect(calls, 0, reason: 'an unknown tool must never reach the bridge');
      // Silence here would hang the whole turn: Gemini batches several calls
      // into one frame and waits for every response before it speaks (live
      // measurement 24.08).
      expect(results, hasLength(1));
      expect(results.single.callId, 'c1');
      expect(results.single.name, 'other_tool');
      expect(results.single.output, startsWith('Error:'));
      expect(results.single.output, contains('other_tool'));
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

    test('sends the device clock as context on every call', () async {
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
      final executor = AskClaudeToolExecutor(
        client: client,
        sendToolResult: recorder.callback,
        now: () => DateTime(2026, 8, 23, 19, 37),
      );

      executor.handle(HubToolCallRequest(
        name: askClaudeToolName,
        callId: 'call-clock',
        argumentsJson: jsonEncode({'question': 'который час?'}),
      ));
      await recorder.result;

      expect(jsonDecode(captured!.body)['context'], deviceClockContext(DateTime(2026, 8, 23, 19, 37)));
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

    test('tools are on unless the model explicitly opts out', () async {
      // The bridge loads MCP servers only when tools_enabled is true, so a call
      // that omits use_tools used to reach Claude with no memory at all — it
      // answered "I have no memory tools" and went hunting through the file
      // system instead (observed live, 23.08).
      Future<http.Response> respond(http.Request r) async => http.Response(
            _sse([
              {'type': 'done', 'text': 'ANSWER'}
            ]),
            200,
          );

      for (final entry in {
        {'question': 'q'}: true, // omitted -> on
        {'question': 'q', 'use_tools': true}: true,
        {'question': 'q', 'use_tools': false}: false, // explicit opt-out honoured
      }.entries) {
        http.Request? captured;
        final client = AskClaudeBridgeClient(httpClient: MockClient((r) {
          captured = r;
          return respond(r);
        }));
        final recorder = _toolResultRecorder();
        final executor = AskClaudeToolExecutor(client: client, sendToolResult: recorder.callback);

        executor.handle(HubToolCallRequest(
          name: askClaudeToolName,
          callId: 'c',
          argumentsJson: jsonEncode(entry.key),
        ));
        await recorder.result;

        expect(jsonDecode(captured!.body)['tools_enabled'], entry.value, reason: 'args: ${entry.key}');
      }
    });

    test('with announce: the model is freed immediately and the answer arrives spoken-in', () async {
      // The whole point of non-blocking delivery: until a tool result lands the
      // model must stay silent, so a 44s round trip (measured 23.08) was 44s of
      // dead air. Now the turn is released at once and the answer is voiced in
      // when it arrives.
      final client = AskClaudeBridgeClient(
          httpClient: MockClient((r) async => http.Response(
                _sse([
                  {'type': 'done', 'text': 'сорок два'}
                ]),
                200,
                headers: _utf8EventStreamHeaders,
              )));
      final recorder = _toolResultRecorder();
      final announced = <String>[];
      final executor = AskClaudeToolExecutor(
        client: client,
        sendToolResult: recorder.callback,
        announce: announced.add,
      );

      executor.handle(HubToolCallRequest(
        name: askClaudeToolName,
        callId: 'c1',
        argumentsJson: jsonEncode({'question': 'q'}),
      ));
      final released = await recorder.result;

      // Released with a placeholder, not with the answer.
      expect(released.output, contains('Ответа пока НЕТ'));
      expect(released.output, isNot(contains('сорок два')));

      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(announced.single, contains('сорок два'));
      // Framed as material to voice, so the model does not treat it as a new
      // question from the user.
      expect(announced.single, contains('Озвучь'));
    });

    test('with announce: a failure is spoken in too, not swallowed', () async {
      final client = AskClaudeBridgeClient(httpClient: MockClient((r) async => http.Response('boom', 500)));
      final recorder = _toolResultRecorder();
      final announced = <String>[];
      final executor = AskClaudeToolExecutor(
        client: client,
        sendToolResult: recorder.callback,
        announce: announced.add,
      );

      executor.handle(HubToolCallRequest(
        name: askClaudeToolName,
        callId: 'c1',
        argumentsJson: jsonEncode({'question': 'q'}),
      ));
      await recorder.result;
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(announced.single, contains('Error'));
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
