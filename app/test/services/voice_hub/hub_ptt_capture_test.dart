// Tests for the production half of `hub_ptt_capture.dart` —
// `nativeMicHubCaptureFactory`, the only place where the hub's capture
// contract meets a real `IMicRecorderService`.
//
// Worth its own file because this seam is pure hand-written forwarding, and a
// callback that reaches `HubPttCaptureOptions` but is never handed to the
// recorder fails exactly the way the mic-interruption work was chasing: no
// error, no log, just a signal that silently never arrives.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:omi/services/services.dart';
import 'package:omi/services/voice_hub/hub_ptt_capture.dart';

class _FakeRecorder implements IMicRecorderService {
  int startCalls = 0;
  int stopCalls = 0;
  Function(Uint8List bytes)? onByteReceived;
  Function(bool began)? onInterruption;

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
    this.onByteReceived = onByteReceived;
    this.onInterruption = onInterruption;
  }

  @override
  Future<void> startBatch({
    Function()? onStop,
    Function(bool began)? onInterruption,
    Function()? onBatchStalled,
    Function(String code, String message)? onError,
  }) async =>
      throw UnsupportedError('the hub never batches');

  @override
  void stop() => stopCalls += 1;

  @override
  void probeStallAfterForeground() {}
}

void main() {
  group('nativeMicHubCaptureFactory', () {
    late _FakeRecorder recorder;
    late HubStartCapture factory;

    setUp(() {
      recorder = _FakeRecorder();
      factory = nativeMicHubCaptureFactory(() => recorder);
    });

    test('mic frames reach the options tee', () async {
      final chunks = <Uint8List>[];
      await factory(HubPttCaptureOptions(onChunk: chunks.add));

      recorder.onByteReceived!(Uint8List.fromList([1, 2, 3]));

      expect(recorder.startCalls, 1);
      expect(chunks.single, [1, 2, 3]);
    });

    // The signal a continuous consumer cannot infer: with the mic taken away
    // the wire looks exactly like a person who stopped talking.
    test('mic interruptions reach the options handler', () async {
      final events = <bool>[];
      await factory(HubPttCaptureOptions(onInterruption: events.add));

      recorder.onInterruption!(true);
      recorder.onInterruption!(false);

      expect(events, [true, false]);
    });

    // Null, not an empty closure: `NativeMicRecorderService` reads a null
    // handler as "nobody is listening", which is the truth for the PTT driver
    // — it starts a capture per button press and has no use for the state.
    test('a caller that wants no interruptions passes none to the recorder', () async {
      await factory(const HubPttCaptureOptions());

      expect(recorder.onInterruption, isNull);
    });

    test('dispose() stops the recorder once, however many times it is called', () async {
      final capture = await factory(const HubPttCaptureOptions());

      capture.dispose();
      capture.dispose();

      expect(recorder.stopCalls, 1);
    });
  });
}
