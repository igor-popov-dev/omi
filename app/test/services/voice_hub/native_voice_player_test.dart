import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:omi/gen/streaming_pcm_player_pigeon.g.dart';
import 'package:omi/services/voice_hub/hub_session.dart';
import 'package:omi/services/voice_hub/native_voice_player.dart';

// Same idiom as FakePhoneMicHostApi in native_mic_recorder_service_test.dart:
// pigeon HostApi client classes are plain overridable Dart classes, so a fake
// subclass swaps in for the real channel without any platform-channel
// plumbing in the test.
class FakeStreamingPcmPlayerHostApi extends StreamingPcmPlayerHostApi {
  int startCalls = 0;
  int? lastStartSessionId;
  Object? startError;

  final enqueued = <(Uint8List, int)>[];
  final flushed = <int>[];
  final cleared = <int>[];
  final closed = <int>[];

  @override
  Future<void> start(int sessionId) async {
    startCalls++;
    lastStartSessionId = sessionId;
    if (startError != null) throw startError!;
  }

  @override
  Future<void> enqueuePcm16(Uint8List bytes, int sessionId) async {
    enqueued.add((bytes, sessionId));
  }

  @override
  Future<void> flush(int sessionId) async {
    flushed.add(sessionId);
  }

  @override
  Future<void> clear(int sessionId) async {
    cleared.add(sessionId);
  }

  @override
  Future<void> close(int sessionId) async {
    closed.add(sessionId);
  }
}

void main() {
  late FakeStreamingPcmPlayerHostApi host;
  int startedCount = 0;
  int drainedCount = 0;

  VoicePlayerStartSpec spec() => VoicePlayerStartSpec(
        onStarted: () => startedCount++,
        onDrained: () => drainedCount++,
      );

  setUp(() {
    host = FakeStreamingPcmPlayerHostApi();
    startedCount = 0;
    drainedCount = 0;
  });

  Future<NativeVoicePlayer> create() => NativeVoicePlayer.create(spec(), hostApi: host, registerFlutterApi: false);

  test('create calls native start with a fresh session id', () async {
    final player = await create();
    expect(host.startCalls, 1);
    expect(host.lastStartSessionId, player.sessionId);
  });

  test('create rethrows the native start failure (mirrors createPlayer catch in hub_session)', () async {
    host.startError = Exception('boom');
    await expectLater(create(), throwsException);
  });

  test('enqueuePcm16/flush/clear forward the exact bytes and session id, fire-and-forget', () async {
    final player = await create();
    final bytes = Uint8List.fromList([1, 2, 3, 4]);

    player.enqueuePcm16(bytes);
    player.flush();
    player.clear();

    // Fire-and-forget: the native Future isn't awaited by VoicePlayer's sync
    // API, but the underlying call happens synchronously in this fake (no
    // real async gap), so it's already recorded.
    expect(host.enqueued, [(bytes, player.sessionId)]);
    expect(host.flushed, [player.sessionId]);
    expect(host.cleared, [player.sessionId]);
  });

  test('close forwards the session id to native', () async {
    final player = await create();
    player.close();
    expect(host.closed, [player.sessionId]);
  });

  test('onStarted/onDrained for the current session id reach the spec callbacks', () async {
    final player = await create();
    player.onStarted(player.sessionId);
    player.onDrained(player.sessionId);
    expect(startedCount, 1);
    expect(drainedCount, 1);
  });

  test('onStarted/onDrained for a stale session id are dropped', () async {
    final player = await create();
    player.onStarted(player.sessionId + 999);
    player.onDrained(player.sessionId + 999);
    expect(startedCount, 0);
    expect(drainedCount, 0);
  });

  test('events after close are dropped — a race with a fresh create does not clobber it', () async {
    final first = await create();
    first.close();

    // A stale native callback for the just-closed session must not fire,
    // even though nothing else has replaced it yet.
    first.onStarted(first.sessionId);
    expect(startedCount, 0);

    // A fresh session's own events still work normally.
    int secondStarted = 0;
    final second = await NativeVoicePlayer.create(
      VoicePlayerStartSpec(onStarted: () => secondStarted++, onDrained: () {}),
      hostApi: host,
      registerFlutterApi: false,
    );
    second.onStarted(second.sessionId);
    expect(secondStarted, 1);
    // The stale first session's id can never match the new active session.
    first.onStarted(first.sessionId);
    expect(startedCount, 0);
  });

  test('onAudioFocusLost for the current session id reaches the spec callback', () async {
    int lostCount = 0;
    final player = await NativeVoicePlayer.create(
      VoicePlayerStartSpec(onStarted: () {}, onDrained: () {}, onAudioFocusLost: () => lostCount++),
      hostApi: host,
      registerFlutterApi: false,
    );
    player.onAudioFocusLost(player.sessionId);
    expect(lostCount, 1);
  });

  test('onAudioFocusLost for a stale session id is dropped', () async {
    int lostCount = 0;
    final player = await NativeVoicePlayer.create(
      VoicePlayerStartSpec(onStarted: () {}, onDrained: () {}, onAudioFocusLost: () => lostCount++),
      hostApi: host,
      registerFlutterApi: false,
    );
    player.onAudioFocusLost(player.sessionId + 999);
    expect(lostCount, 0);
  });

  test('onAudioFocusLost is a no-op when the spec did not supply a callback', () async {
    final player = await create();
    // Must not throw despite the spec omitting onAudioFocusLost entirely.
    player.onAudioFocusLost(player.sessionId);
  });

  test('successive sessions mint strictly increasing ids', () async {
    final a = await create();
    final b = await create();
    expect(b.sessionId, greaterThan(a.sessionId));
  });
}
