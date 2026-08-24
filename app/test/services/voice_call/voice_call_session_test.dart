import 'package:flutter_test/flutter_test.dart';

import 'package:omi/gen/voice_call_session_pigeon.g.dart';
import 'package:omi/services/voice_call/voice_call_session.dart';

// Same trick as native_voice_player_test.dart: pigeon HostApi client classes
// are plain overridable Dart classes, so a fake subclass swaps in for the real
// channel without any platform-channel plumbing in the test.
class _FakeVoiceCallSessionHostApi extends VoiceCallSessionHostApi {
  final started = <int>[];
  final ended = <int>[];
  bool startResult = true;
  Object? startError;

  @override
  Future<bool> start(int sessionId) async {
    started.add(sessionId);
    if (startError != null) throw startError!;
    return startResult;
  }

  @override
  Future<void> end(int sessionId) async {
    ended.add(sessionId);
  }
}

void main() {
  late _FakeVoiceCallSessionHostApi host;
  late VoiceCallSession session;
  int systemEnds = 0;

  setUp(() {
    host = _FakeVoiceCallSessionHostApi();
    session = VoiceCallSession(hostApi: host, registerFlutterApi: false);
    systemEnds = 0;
    session.onEndedBySystem = () => systemEnds++;
  });

  test('start places the call and end tears the same session down', () async {
    await session.start();
    expect(host.started, hasLength(1));

    await session.end();
    expect(host.ended, [host.started.single]);
  });

  test('end without a session is a no-op; a second end does not repeat', () async {
    await session.end();
    expect(host.ended, isEmpty);

    await session.start();
    await session.end();
    await session.end();
    expect(host.ended, hasLength(1));
  });

  test('fail-open: a platform error on start neither throws nor blocks end', () async {
    host.startError = StateError('MissingPluginException stand-in');
    await session.start(); // must not throw

    await session.end();
    expect(host.ended, hasLength(1), reason: 'the session id still ends (native end is a no-op there)');
  });

  test('native end for the live session fires onEndedBySystem once', () async {
    await session.start();

    session.onEnded(host.started.single, 'notification_hang_up');
    expect(systemEnds, 1);

    // The follow-up Dart-side end (wired through resetFreeFormVoiceModeUi)
    // must not double back into native for an already-ended session.
    await session.end();
    expect(host.ended, isEmpty);
  });

  test('fencing: a stale native end never reaches the newer session', () async {
    await session.start();
    final staleId = host.started.single;
    await session.end();
    await session.start();

    session.onEnded(staleId, 'telecom_disconnect');
    expect(systemEnds, 0);
  });
}
