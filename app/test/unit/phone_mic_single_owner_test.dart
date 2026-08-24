// The app has exactly ONE native mic recorder, held through two arbiter
// owners (`arbitratedPhoneMicHandles`): conversation capture and the realtime
// voice hub.
//
// Self-host patch, not for upstream: the voice hub used to mint a
// `NativeMicRecorderService` of its own for every capture. The first test
// below is what that cost — the constructor registers the instance as THE
// `PhoneMicFlutterApi` handler, a single global message handler per channel,
// so the newcomer detaches whoever held it. The rest pin the fix.
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:omi/gen/phone_mic_pigeon.g.dart';
import 'package:omi/services/mic/mic_arbiter.dart';
import 'package:omi/services/mic/native_mic_recorder_service.dart';
import 'package:omi/services/services.dart';

class _FakeHostApi extends PhoneMicHostApi {
  int startCalls = 0;
  int stopCalls = 0;

  @override
  Future<void> start(PhoneMicCaptureMode mode, int sessionId) async => startCalls += 1;

  @override
  Future<void> stop() async => stopCalls += 1;

  @override
  Future<bool> isRecording() async => false;
}

/// Stands in for the one native recorder both handles wrap.
class _FakeNativeMic implements IMicRecorderService {
  int startCalls = 0;
  int stopCalls = 0;
  Function()? onStop;

  @override
  Future<void> start({
    required Function(Uint8List bytes) onByteReceived,
    Function()? onRecording,
    Function()? onStop,
    Function()? onInitializing,
    Function()? onStalled,
    Function(bool began)? onInterruption,
  }) async {
    startCalls += 1;
    this.onStop = onStop;
  }

  @override
  Future<void> startBatch({
    Function()? onStop,
    Function(bool began)? onInterruption,
    Function()? onBatchStalled,
    Function(String code, String message)? onError,
  }) async =>
      throw UnsupportedError('not used here');

  @override
  void stop() => stopCalls += 1;

  @override
  void probeStallAfterForeground() {}
}

Future<void> _emitFrame(int sessionId) =>
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.handlePlatformMessage(
      'dev.flutter.pigeon.omi_phone_mic.PhoneMicFlutterApi.onAudioFrame',
      PhoneMicFlutterApi.pigeonChannelCodec.encodeMessage(<Object?>[
        Uint8List.fromList(const [9, 9]),
        sessionId,
      ]),
      (_) {},
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Why sharing is not an optimization. Two consumers, two instances: the
  // second one's constructor takes the channel, and because session ids are
  // minted PER INSTANCE — both starting at 1 — the identity gate that exists
  // to keep sessions apart reads the other consumer's audio as its own. So
  // conversation capture went deaf AND its microphone ended up on the hub's
  // socket.
  test('a second NativeMicRecorderService takes the channel from the first', () async {
    final first = NativeMicRecorderService(hostApi: _FakeHostApi());
    final firstFrames = <Uint8List>[];
    await first.start(onByteReceived: firstFrames.add);

    final second = NativeMicRecorderService(hostApi: _FakeHostApi());
    final secondFrames = <Uint8List>[];
    await second.start(onByteReceived: secondFrames.add);

    await _emitFrame(1); // the FIRST consumer's session

    expect(firstFrames, isEmpty, reason: 'первый экземпляр отцеплен от канала');
    expect(secondFrames, hasLength(1), reason: 'и его кадр достался второму');

    first.stop();
    second.stop();
    PhoneMicFlutterApi.setUp(null);
  });

  group('arbitratedPhoneMicHandles', () {
    late _FakeNativeMic native;
    late MicArbiter arbiter;
    late IMicRecorderService conversation;
    late IMicRecorderService voiceHub;

    setUp(() {
      native = _FakeNativeMic();
      arbiter = MicArbiter();
      final handles = arbitratedPhoneMicHandles(native: native, arbiter: arbiter);
      conversation = handles.conversation;
      voiceHub = handles.voiceHub;
    });

    test('both handles drive the same recorder', () async {
      await conversation.start(onByteReceived: (_) {});
      conversation.stop();
      await voiceHub.start(onByteReceived: (_) {});

      expect(native.startCalls, 2, reason: 'один и тот же нативный рекордер');
    });

    // The loser finds out. Before this, the hub simply started a recorder of
    // its own and conversation capture was left holding a dead channel.
    test('the voice hub cannot take the mic from conversation capture', () async {
      await conversation.start(onByteReceived: (_) {});

      await expectLater(voiceHub.start(onByteReceived: (_) {}), throwsStateError);
      expect(native.startCalls, 1);
      expect(arbiter.owner, kConversationMicOwner);
    });

    test('and conversation capture cannot take it from the voice hub', () async {
      await voiceHub.start(onByteReceived: (_) {});

      await expectLater(conversation.start(onByteReceived: (_) {}), throwsStateError);
      expect(arbiter.owner, kVoiceHubMicOwner);
    });

    test('releasing one handle lets the other in', () async {
      await voiceHub.start(onByteReceived: (_) {});
      voiceHub.stop();

      await conversation.start(onByteReceived: (_) {});

      expect(native.startCalls, 2);
      expect(arbiter.owner, kConversationMicOwner);
    });
  });
}
