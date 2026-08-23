import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:omi/backend/schema/transcript_segment.dart';
import 'package:omi/services/vox_transcript_poller.dart';

/// Answers a scripted sequence and records every request, so a test can assert on what
/// the poller ASKED for (the cursor) and not only on what it did with the answer.
class _ScriptedClient extends http.BaseClient {
  _ScriptedClient(this.script, {this.repeatLast = false});

  final List<http.Response Function(http.BaseRequest request)> script;

  /// Once the script runs out, answer "nothing changed" — that is what the real adapter
  /// does for a cursor it has already served. Repeating the last page instead would hand
  /// the poller the same segments forever and test a server that does not exist.
  final bool repeatLast;
  final List<Uri> requests = [];
  final List<Map<String, String>> headers = [];
  int _index = 0;
  Completer<void>? gate;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request.url);
    headers.add(Map<String, String>.from(request.headers));
    if (gate != null) await gate!.future;
    final exhausted = _index >= script.length;
    final step = exhausted && !repeatLast ? ((_) => _page()) : script[exhausted ? script.length - 1 : _index];
    _index++;
    final response = step(request);
    return http.StreamedResponse(
      Stream.value(response.bodyBytes),
      response.statusCode,
      headers: response.headers,
    );
  }
}

http.Response _page({
  List<Map<String, dynamic>> segments = const [],
  List<String> deleted = const [],
  int cursor = 0,
  int dropped = 0,
  String status = 'active',
  bool reset = false,
}) {
  // Bytes, and a charset-less content type — exactly what the adapter sends. Building
  // this with `http.Response(String, ...)` would quietly latin1-encode it and test a
  // server we do not have.
  return http.Response.bytes(
    utf8.encode(jsonEncode({
      'call_id': 'c1',
      'status': status,
      'cursor': cursor,
      'segments': segments,
      'deleted': deleted,
      'dropped': dropped,
      'reset': reset,
    })),
    200,
    headers: {'content-type': 'application/json'},
  );
}

Map<String, dynamic> _segment(String id, String text, {double start = 0, double end = 1}) => {
      'id': id,
      'text': text,
      'speaker': 'SPEAKER_00',
      'speaker_id': 0,
      'is_user': true,
      'person_id': null,
      'start': start,
      'end': end,
      'seq': 1,
    };

VoxTranscriptPoller _poller(
  _ScriptedClient client, {
  Duration interval = const Duration(milliseconds: 10),
  int maxConsecutiveFailures = 5,
}) {
  return VoxTranscriptPoller(
    baseUrl: 'https://vox.example',
    client: client,
    authHeader: () async => 'Bearer test-token',
    interval: interval,
    maxConsecutiveFailures: maxConsecutiveFailures,
  );
}

void main() {
  group('VoxTranscriptPage', () {
    test('reads the adapter answer', () {
      final page = VoxTranscriptPage.fromJson(
        jsonDecode(_page(segments: [_segment('a', 'привет')], deleted: ['b'], cursor: 7, dropped: 2).body)
            as Map<String, dynamic>,
      );

      expect(page.segments.single.text, 'привет');
      expect(page.deleted, ['b']);
      expect(page.cursor, 7);
      expect(page.dropped, 2);
      expect(page.status, 'active');
    });

    test('Russian text survives an answer with no charset in the content type', () async {
      // The adapter answers `application/json` with no charset, and package:http then
      // decodes as latin1 — read via `response.body`, every Russian word would arrive
      // as mojibake and nothing would report an error.
      final client = _ScriptedClient([
        (_) => _page(segments: [_segment('a', 'алло, слышно?')], cursor: 1)
      ]);
      final delivered = <String>[];
      final poller = _poller(client, interval: const Duration(seconds: 30))
        ..onSegments = (s) => delivered.addAll(s.map((e) => e.text));

      poller.start('c1');
      await Future<void>.delayed(const Duration(milliseconds: 40));
      await poller.stop();

      expect(delivered, ['алло, слышно?']);
    });

    test('a malformed answer yields nothing instead of throwing', () {
      final page = VoxTranscriptPage.fromJson(
        jsonDecode('{"segments": "не список", "cursor": "не число"}') as Map<String, dynamic>,
      );

      expect(page.segments, isEmpty);
      expect(page.cursor, 0);
    });
  });

  group('VoxTranscriptPoller', () {
    test('a build with no adapter URL polls nothing at all', () async {
      final client = _ScriptedClient([(_) => _page()]);
      final poller = VoxTranscriptPoller(
        baseUrl: '   ',
        client: client,
        authHeader: () async => 'Bearer test-token',
      );

      expect(poller.configured, isFalse);
      poller.start('c1');
      await Future<void>.delayed(const Duration(milliseconds: 40));

      expect(client.requests, isEmpty);
      await poller.stop();
    });

    test('carries only Authorization — never the Cloudflare Access service token', () async {
      final client = _ScriptedClient([(_) => _page(cursor: 1)]);
      final poller = _poller(client);

      poller.start('c1');
      await Future<void>.delayed(const Duration(milliseconds: 40));
      await poller.stop();

      expect(client.headers.first['Authorization'], 'Bearer test-token');
      expect(client.headers.first.keys.map((k) => k.toLowerCase()), isNot(contains('cf-access-client-id')));
      expect(client.headers.first.keys.map((k) => k.toLowerCase()), isNot(contains('cf-access-client-secret')));
    });

    test('the cursor moves forward so the same text is never delivered twice', () async {
      final client = _ScriptedClient([
        (_) => _page(segments: [_segment('a', 'первая')], cursor: 3),
        (_) => _page(segments: [_segment('b', 'вторая')], cursor: 5),
      ]);
      final delivered = <String>[];
      final poller = _poller(client)..onSegments = (s) => delivered.addAll(s.map((e) => e.text));

      poller.start('c1');
      await Future<void>.delayed(const Duration(milliseconds: 80));
      await poller.stop();

      expect(delivered, ['первая', 'вторая']);
      expect(client.requests[0].queryParameters['since'], '0');
      expect(client.requests[1].queryParameters['since'], '3');
      expect(client.requests[2].queryParameters['since'], '5');
    });

    test('an answer that rewinds the cursor does not replay text already on screen', () async {
      final client = _ScriptedClient([
        (_) => _page(segments: [_segment('a', 'первая')], cursor: 9),
        (_) => _page(cursor: 2),
      ]);
      final poller = _poller(client);

      poller.start('c1');
      await Future<void>.delayed(const Duration(milliseconds: 80));
      await poller.stop();

      expect(poller.cursor, 9);
      expect(client.requests.last.queryParameters['since'], '9');
    });

    test('a restarted adapter rewinds the cursor instead of freezing the screen', () async {
      // The adapter's buffer lives in one call session: a leg back after the grace expired,
      // or a restart, numbers from one again. Forward-only would leave our cursor above
      // anything that buffer will ever issue, and the rest of the call would arrive as
      // "nothing changed" — HTTP 200, no error anywhere, the screen simply stops.
      final client = _ScriptedClient([
        (_) => _page(segments: [_segment('a', 'до перезапуска')], cursor: 40),
        (_) => _page(segments: [_segment('b', 'после перезапуска')], cursor: 1, reset: true),
      ]);
      final seen = <String>[];
      final poller = _poller(client)..onSegments = (s) => seen.addAll(s.map((e) => e.text));

      poller.start('c1');
      await Future<void>.delayed(const Duration(milliseconds: 80));
      await poller.stop();

      expect(seen, ['до перезапуска', 'после перезапуска']);
      expect(poller.cursor, 1);
      // The point of the whole test: the NEXT question is one the new buffer can answer.
      expect(client.requests.last.queryParameters['since'], '1');
    });

    test('a rewind is only accepted when the adapter says so', () async {
      // Same shape as above minus the flag — an out-of-order answer must not make us
      // re-ask for text the screen already shows.
      final client = _ScriptedClient([
        (_) => _page(segments: [_segment('a', 'первая')], cursor: 40),
        (_) => _page(segments: [_segment('b', 'вторая')], cursor: 1),
      ]);
      final poller = _poller(client);

      poller.start('c1');
      await Future<void>.delayed(const Duration(milliseconds: 80));
      await poller.stop();

      expect(poller.cursor, 40);
      expect(client.requests.last.queryParameters['since'], '40');
    });

    test('an adapter that never mentions reset is handled like before', () async {
      // The field is new on the server side; a build talking to an older adapter must not
      // read a missing flag as "everything restarted".
      final page = VoxTranscriptPage.fromJson({
        'call_id': 'c1',
        'status': 'active',
        'cursor': 7,
        'segments': [_segment('a', 'первая')],
        'deleted': <String>[],
        'dropped': 0,
      });

      expect(page.reset, isFalse);
      expect(page.cursor, 7);
    });

    test('404 early in a call is normal and keeps the poller going', () async {
      final client = _ScriptedClient([
        (_) => http.Response('{"error": "unknown call"}', 404),
        (_) => http.Response('{"error": "unknown call"}', 404),
        (_) => _page(segments: [_segment('a', 'наконец')], cursor: 1),
      ]);
      final delivered = <String>[];
      final poller = _poller(client, maxConsecutiveFailures: 2)
        ..onSegments = (s) => delivered.addAll(s.map((e) => e.text));

      poller.start('c1');
      await Future<void>.delayed(const Duration(milliseconds: 120));
      await poller.stop();

      // Had 404 counted as a failure, maxConsecutiveFailures: 2 would have stopped the
      // poller before the adapter ever had a session to answer with.
      expect(delivered, ['наконец']);
    });

    test('a wall of real failures stops the poller instead of hammering a public endpoint', () async {
      final client = _ScriptedClient([(_) => http.Response('nope', 500)], repeatLast: true);
      final poller = _poller(client, maxConsecutiveFailures: 3);

      poller.start('c1');
      await Future<void>.delayed(const Duration(milliseconds: 120));
      final afterGivingUp = client.requests.length;
      await Future<void>.delayed(const Duration(milliseconds: 60));

      expect(afterGivingUp, 3);
      expect(client.requests.length, afterGivingUp, reason: 'после отказа опрос не возобновляется сам');
      await poller.stop();
    });

    test('a slow poll does not stack requests on top of each other', () async {
      final client = _ScriptedClient([(_) => _page(cursor: 1)]);
      client.gate = Completer<void>();
      final poller = _poller(client);

      poller.start('c1');
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(client.requests.length, 1, reason: 'таймер не должен ставить второй запрос поверх висящего');

      client.gate!.complete();
      await Future<void>.delayed(const Duration(milliseconds: 40));
      await poller.stop();
    });

    test('stop() means stop', () async {
      final client = _ScriptedClient([(_) => _page(cursor: 1)]);
      final poller = _poller(client);

      poller.start('c1');
      await Future<void>.delayed(const Duration(milliseconds: 40));
      await poller.stop();
      final afterStop = client.requests.length;
      await Future<void>.delayed(const Duration(milliseconds: 60));

      expect(client.requests.length, afterStop);
    });

    test('drain() reads the tail once after the call ended', () async {
      final client = _ScriptedClient([
        (_) => _page(cursor: 1),
        (_) => _page(segments: [_segment('z', 'последнее слово')], cursor: 2, status: 'finished'),
      ]);
      final delivered = <String>[];
      final poller = _poller(client, interval: const Duration(seconds: 30))
        ..onSegments = (s) => delivered.addAll(s.map((e) => e.text));

      poller.start('c1');
      await Future<void>.delayed(const Duration(milliseconds: 40));
      await poller.drain();
      final afterDrain = client.requests.length;
      await Future<void>.delayed(const Duration(milliseconds: 40));

      expect(delivered, ['последнее слово']);
      expect(client.requests.length, afterDrain, reason: 'дочитали хвост — и на этом всё');
    });

    test('a gap in the buffer is reported, not swallowed', () async {
      final client = _ScriptedClient([(_) => _page(cursor: 1, dropped: 4)]);
      var reported = 0;
      final poller = _poller(client, interval: const Duration(seconds: 30))..onGap = (n) => reported = n;

      poller.start('c1');
      await Future<void>.delayed(const Duration(milliseconds: 40));
      await poller.stop();

      expect(reported, 4);
    });

    test('deleted segments are passed on so the screen can drop them', () async {
      final client = _ScriptedClient([
        (_) => _page(deleted: ['a', 'b'], cursor: 1)
      ]);
      final removed = <String>[];
      final poller = _poller(client, interval: const Duration(seconds: 30))..onDeleted = removed.addAll;

      poller.start('c1');
      await Future<void>.delayed(const Duration(milliseconds: 40));
      await poller.stop();

      expect(removed, ['a', 'b']);
    });
  });

  group('segments from the adapter', () {
    test('parse into the same model the socket path uses', () {
      final segment = TranscriptSegment.fromJson(_segment('a', 'привет', start: 1.5, end: 3.25));

      expect(segment.id, 'a');
      expect(segment.isUser, isTrue);
      expect(segment.start, 1.5);
      expect(segment.end, 3.25);
    });
  });
}
