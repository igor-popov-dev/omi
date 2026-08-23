import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:omi/backend/preferences.dart';
import 'package:omi/models/stt_result.dart';
import 'package:omi/services/sockets/pure_polling.dart';
import 'package:omi/services/sockets/pure_socket.dart';

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await SharedPreferencesUtil.init();
  });

  test('a failed transcribe keeps the audio buffered and does not tear the socket down', () async {
    final provider = _FakeSttProvider();
    provider.enqueueError(Exception('connection refused'));
    provider.enqueueSuccess(SttTranscriptionResult(segments: [SttSegment(text: 'hi', start: 0, end: 1)]));

    final socket = PurePollingSocket(config: const AudioPollingConfig(minBufferSizeBytes: 1), sttProvider: provider);
    final listener = _FakeListener();
    socket.setListener(listener);

    expect(await socket.connect(), isTrue);

    socket.send(Uint8List.fromList([1, 2, 3]));
    await socket.flushNow();

    // The failed attempt must not be reported as a fatal socket error/close —
    // that used to tear down the whole composite (including the healthy
    // secondary/raw-audio socket) on every transient STT hiccup.
    expect(listener.errors, isEmpty);
    expect(listener.closes, isEmpty);
    expect(socket.status, PureSocketStatus.connected);
    expect(socket.isBuffering, isTrue);
    expect(socket.bufferingSince, isNotNull);

    // More audio arrives while still "offline".
    provider.enqueueSuccess(SttTranscriptionResult(segments: [SttSegment(text: 'again', start: 1, end: 2)]));
    socket.send(Uint8List.fromList([4, 5, 6]));
    await socket.flushNow();
    await socket.flushNow();

    // After a failure the flush window shrinks, so the requeued audio and the
    // newly captured audio drain as separate (oldest-first) chunks — but
    // nothing was dropped while offline.
    expect(provider.receivedCalls.skip(1).expand((c) => c), [1, 2, 3, 4, 5, 6]);
    expect(listener.messages, hasLength(2));
    expect(socket.isBuffering, isFalse);
    expect(socket.bufferingSince, isNull);
  });

  test('a null transcribe result (terminal HTTP failure) keeps the audio buffered too', () async {
    final provider = _FakeSttProvider();
    // SchemaBasedSttProvider returns null (not an exception) for a final
    // non-200 — e.g. a rejected auth token or a misconfigured URL. This used
    // to take the success path: the frames were dropped and bufferingSince
    // was reset, so the audio window was lost with no offline indicator.
    provider.enqueueNull();
    provider.enqueueSuccess(SttTranscriptionResult(segments: [SttSegment(text: 'hi', start: 0, end: 1)]));

    final socket = PurePollingSocket(config: const AudioPollingConfig(minBufferSizeBytes: 1), sttProvider: provider);
    final listener = _FakeListener();
    socket.setListener(listener);
    await socket.connect();

    socket.send(Uint8List.fromList([1, 2, 3]));
    await socket.flushNow();

    expect(listener.errors, isEmpty);
    expect(socket.status, PureSocketStatus.connected);
    expect(socket.isBuffering, isTrue);
    expect(socket.consecutiveFailures, 1);
    expect(socket.lastSuccessAt, isNull);

    provider.enqueueSuccess(SttTranscriptionResult(segments: []));
    socket.send(Uint8List.fromList([4]));
    await socket.flushNow();
    await socket.flushNow();

    // The retries drained the requeued audio plus what arrived since (in
    // shrunken, oldest-first chunks) — nothing lost.
    expect(provider.receivedCalls.skip(1).expand((c) => c), [1, 2, 3, 4]);
    expect(socket.isBuffering, isFalse);
    expect(socket.lastSuccessAt, isNotNull);
  });

  test('a successful flush records lastSuccessAt as a positive liveness signal', () async {
    final provider = _FakeSttProvider();
    provider.enqueueSuccess(SttTranscriptionResult(segments: []));

    final socket = PurePollingSocket(config: const AudioPollingConfig(minBufferSizeBytes: 1), sttProvider: provider);
    socket.setListener(_FakeListener());
    await socket.connect();

    expect(socket.lastSuccessAt, isNull);
    final before = DateTime.now();
    socket.send(Uint8List.fromList([1]));
    await socket.flushNow();

    expect(socket.lastSuccessAt, isNotNull);
    expect(socket.lastSuccessAt!.isBefore(before), isFalse);
  });

  test('keeps retrying on every subsequent flush while the endpoint stays down', () async {
    final provider = _FakeSttProvider()..alwaysThrow(Exception('still down'));

    final socket = PurePollingSocket(config: const AudioPollingConfig(minBufferSizeBytes: 1), sttProvider: provider);
    socket.setListener(_FakeListener());
    await socket.connect();

    socket.send(Uint8List.fromList([1]));
    await socket.flushNow();
    socket.send(Uint8List.fromList([2]));
    await socket.flushNow();
    socket.send(Uint8List.fromList([3]));
    await socket.flushNow();

    // With the adaptive window floored after the first failure, every retry
    // re-attempts the OLDEST chunk (never a merged, ever-growing payload —
    // that re-send-the-same-plus-more pattern is what wedged a slow uplink),
    // and everything stays buffered.
    expect(provider.receivedCalls, [
      [1],
      [1],
      [1],
    ]);
    expect(socket.bufferedBytes, 3);
  });

  test('a failed flush halves the window; successes grow it back (adaptive backlog drain)', () async {
    final provider = _FakeSttProvider();
    provider.enqueueError(Exception('timeout'));
    provider.alwaysSucceedEmpty();

    final socket = PurePollingSocket(
      config: const AudioPollingConfig(minBufferSizeBytes: 1, maxFlushBytes: 8),
      sttProvider: provider,
    );
    socket.setListener(_FakeListener());
    await socket.connect();

    // 8 one-byte frames — a "backlog" the full window would send at once.
    for (final byte in [1, 2, 3, 4, 5, 6, 7, 8]) {
      socket.send(Uint8List.fromList([byte]));
    }

    await socket.flushNow(); // 8 bytes, fails → window halves to 4
    expect(socket.adaptiveFlushBytes, 4);

    await socket.flushNow(); // [1,2,3,4] succeeds → window grows back to 8
    expect(socket.adaptiveFlushBytes, 8);

    await socket.flushNow(); // remaining [5,6,7,8]

    expect(provider.receivedCalls, [
      [1, 2, 3, 4, 5, 6, 7, 8],
      [1, 2, 3, 4],
      [5, 6, 7, 8],
    ]);
    expect(socket.bufferedBytes, 0);
  });

  test('flushes at most maxFlushBytes per request and drains the backlog progressively', () async {
    final provider = _FakeSttProvider();
    provider.enqueueError(Exception('outage'));
    provider.enqueueSuccess(SttTranscriptionResult(segments: []));
    provider.enqueueSuccess(SttTranscriptionResult(segments: []));

    final socket = PurePollingSocket(
      config: const AudioPollingConfig(minBufferSizeBytes: 1, maxFlushBytes: 3),
      sttProvider: provider,
    );
    socket.setListener(_FakeListener());
    await socket.connect();

    // 5 bytes accumulate during the outage (first flush of [1,2,3] fails and
    // requeues), then the endpoint recovers.
    socket.send(Uint8List.fromList([1, 2, 3]));
    await socket.flushNow();
    socket.send(Uint8List.fromList([4, 5]));

    await socket.flushNow();
    await socket.flushNow();

    // Recovery drains in capped chunks — never the whole backlog in one
    // request (which would outgrow the request timeout and never complete).
    expect(provider.receivedCalls, [
      [1, 2, 3],
      [1, 2, 3],
      [4, 5],
    ]);
    expect(socket.bufferedBytes, 0);
  });

  test('a single frame larger than maxFlushBytes still flushes alone', () async {
    final provider = _FakeSttProvider();
    provider.enqueueSuccess(SttTranscriptionResult(segments: []));

    final socket = PurePollingSocket(
      config: const AudioPollingConfig(minBufferSizeBytes: 1, maxFlushBytes: 2),
      sttProvider: provider,
    );
    socket.setListener(_FakeListener());
    await socket.connect();

    socket.send(Uint8List.fromList([1, 2, 3, 4]));
    await socket.flushNow();

    expect(provider.receivedCalls, [
      [1, 2, 3, 4],
    ]);
    expect(socket.bufferedBytes, 0);
  });

  test('trims the oldest buffered audio once past the configured cap', () async {
    final provider = _FakeSttProvider()..alwaysThrow(Exception('still down'));

    final socket = PurePollingSocket(
      config: const AudioPollingConfig(minBufferSizeBytes: 1, maxBufferBytes: 5),
      sttProvider: provider,
    );
    socket.setListener(_FakeListener());
    await socket.connect();

    for (final byte in [1, 2, 3, 4, 5, 6, 7]) {
      socket.send(Uint8List.fromList([byte]));
      await socket.flushNow();
    }

    expect(socket.bufferedBytes, lessThanOrEqualTo(5));
    // The adaptive window floors during the outage, so each retry attempts the
    // then-oldest byte; the cap trims oldest-first on requeue (newest audio
    // survives): the final attempt still saw byte 2, after which the requeue
    // trimmed it, leaving [3..7] (5 bytes) buffered.
    expect(provider.receivedCalls.last, [2]);
    expect(socket.bufferedBytes, 5);
  });
}

class _FakeSttProvider implements ISttProvider {
  final List<List<int>> receivedCalls = [];
  final _behaviors = <Future<SttTranscriptionResult?> Function()>[];
  Future<SttTranscriptionResult?> Function()? _default;

  void enqueueError(Object error) => _behaviors.add(() => Future<SttTranscriptionResult?>.error(error));
  void enqueueSuccess(SttTranscriptionResult result) => _behaviors.add(() async => result);
  void enqueueNull() => _behaviors.add(() async => null);
  void alwaysSucceedEmpty() => _default = () async => SttTranscriptionResult(segments: []);
  void alwaysThrow(Object error) => _default = () => Future<SttTranscriptionResult?>.error(error);

  @override
  Future<SttTranscriptionResult?> transcribe(Uint8List audioData, {double audioOffsetSeconds = 0}) {
    receivedCalls.add(audioData.toList());
    final behavior = _behaviors.isNotEmpty ? _behaviors.removeAt(0) : (_default ?? () async => null);
    return behavior();
  }

  @override
  void dispose() {}
}

class _FakeListener implements IPureSocketListener {
  final List<Object> errors = [];
  final List<int?> closes = [];
  final List<dynamic> messages = [];
  int connects = 0;

  @override
  void onConnected() => connects++;

  @override
  void onMessage(dynamic message) => messages.add(message);

  @override
  void onClosed([int? closeCode]) => closes.add(closeCode);

  @override
  void onError(Object err, StackTrace trace) => errors.add(err);
}
