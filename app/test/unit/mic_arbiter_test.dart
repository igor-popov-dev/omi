import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:omi/services/mic/mic_arbiter.dart';
import 'package:omi/services/services.dart';

class FakeMic implements IMicRecorderService {
  int startCalls = 0;
  int startBatchCalls = 0;
  int stopCalls = 0;
  bool failNextStart = false;
  bool failNextStartBatch = false;
  Function()? capturedOnStop;

  @override
  Future<void> start({
    required Function(Uint8List bytes) onByteReceived,
    Function()? onRecording,
    Function()? onStop,
    Function()? onInitializing,
    Function()? onStalled,
    Function(bool began)? onInterruption,
  }) async {
    startCalls++;
    if (failNextStart) {
      failNextStart = false;
      throw Exception('recorder failed to start');
    }
    capturedOnStop = onStop;
  }

  @override
  Future<void> startBatch({
    Function()? onStop,
    Function(bool began)? onInterruption,
    Function()? onBatchStalled,
    Function(String code, String message)? onError,
  }) async {
    startBatchCalls++;
    if (failNextStartBatch) {
      failNextStartBatch = false;
      throw Exception('batch recorder failed to start');
    }
    capturedOnStop = onStop;
  }

  @override
  void stop() {
    stopCalls++;
    capturedOnStop?.call();
    capturedOnStop = null;
  }

  @override
  void probeStallAfterForeground() {}
}

void main() {
  group('MicArbiter', () {
    test('same owner can re-acquire, different owner cannot', () {
      final arbiter = MicArbiter();
      expect(arbiter.tryAcquire('a'), isTrue);
      expect(arbiter.tryAcquire('a'), isTrue);
      expect(arbiter.tryAcquire('b'), isFalse);
      arbiter.release('a');
      expect(arbiter.tryAcquire('b'), isTrue);
    });

    test('release by non-owner is ignored', () {
      final arbiter = MicArbiter();
      arbiter.tryAcquire('a');
      arbiter.release('b');
      expect(arbiter.owner, 'a');
    });
  });

  // An in-app call is the third contender for the microphone and the only one that does
  // not go through this arbiter at all: its SDK takes the mic natively. Left unrecorded,
  // the arbiter keeps handing the mic to recorders that then capture silence next to a
  // live call — and report success.
  group('MicArbiter — an in-app call', () {
    test('a call refuses the microphone even when no recorder holds it', () {
      final arbiter = MicArbiter();
      arbiter.holdForCall();
      expect(arbiter.tryAcquire('mic'), isFalse);
      expect(arbiter.owner, isNull, reason: 'a refused claim must not take the token');
    });

    test('a call refuses even the stack that already held the token', () {
      final arbiter = MicArbiter();
      expect(arbiter.tryAcquire('conversation'), isTrue);
      arbiter.holdForCall();
      expect(arbiter.tryAcquire('conversation'), isFalse,
          reason: 'no stack gets to renew its hold while a call is running');
    });

    // Exactly what the ambient-capture pause does: it releases the token MID-call.
    // Were the veto stored as ownership, that release would end it.
    test("a paused recorder's release does not lift the veto", () {
      final arbiter = MicArbiter();
      arbiter.tryAcquire('conversation');
      arbiter.holdForCall();
      arbiter.release('conversation');
      expect(arbiter.callHolds, isTrue);
      expect(arbiter.tryAcquire('mic'), isFalse);
    });

    test('releasing the call hands the microphone back', () {
      final arbiter = MicArbiter();
      arbiter.holdForCall();
      arbiter.releaseCall();
      expect(arbiter.tryAcquire('conversation'), isTrue);
    });

    // One call reports its state more than once; a veto that counted them would need as
    // many releases as it got holds, and the phone would stay deaf after the first call.
    test('the hold is idempotent — one release is enough', () {
      final arbiter = MicArbiter();
      arbiter.holdForCall();
      arbiter.holdForCall();
      arbiter.releaseCall();
      expect(arbiter.tryAcquire('mic'), isTrue);
    });

    test('the refusal names the call, and leaves the old wording alone', () {
      final arbiter = MicArbiter();
      arbiter.holdForCall();
      expect(arbiter.holder, 'an in-app call');
      arbiter.releaseCall();
      arbiter.tryAcquire('conversation');
      expect(arbiter.holder, 'conversation');
    });
  });

  group('ArbitratedMic', () {
    late MicArbiter arbiter;
    late FakeMic micA;
    late FakeMic micB;
    late ArbitratedMic a;
    late ArbitratedMic b;

    setUp(() {
      arbiter = MicArbiter();
      micA = FakeMic();
      micB = FakeMic();
      a = ArbitratedMic(inner: micA, arbiter: arbiter, owner: 'conversation');
      b = ArbitratedMic(inner: micB, arbiter: arbiter, owner: 'mic');
    });

    Future<void> startMic(ArbitratedMic mic) => mic.start(onByteReceived: (_) {});

    test('second stack contends while first holds the mic', () async {
      await startMic(a);
      expect(() => startMic(b), throwsStateError);
      expect(micB.startCalls, 0);
    });

    test('stop releases so the other stack can start', () async {
      await startMic(a);
      a.stop();
      await startMic(b);
      expect(micB.startCalls, 1);
    });

    test('start failure releases the arbiter and rethrows', () async {
      micA.failNextStart = true;
      await expectLater(startMic(a), throwsException);
      await startMic(b);
      expect(micB.startCalls, 1);
    });

    test('natural stop (inner onStop) releases without an explicit stop()', () async {
      var stopped = false;
      await a.start(onByteReceived: (_) {}, onStop: () => stopped = true);
      // Simulate the recorder retiring itself (e.g. watchdog kill).
      micA.capturedOnStop!.call();
      expect(stopped, isTrue);
      await startMic(b);
      expect(micB.startCalls, 1);
    });

    test('startBatch contends while the other stack holds the mic', () async {
      await startMic(b);
      expect(() => a.startBatch(), throwsStateError);
      expect(micA.startBatchCalls, 0);
    });

    test('startBatch failure releases the arbiter and rethrows', () async {
      micA.failNextStartBatch = true;
      await expectLater(a.startBatch(), throwsException);
      await startMic(b);
      expect(micB.startCalls, 1);
    });

    test('stop after startBatch releases so the other stack can start', () async {
      await a.startBatch();
      expect(micA.startBatchCalls, 1);
      a.stop();
      await startMic(b);
      expect(micB.startCalls, 1);
    });

    test('natural stop from batch onStop releases the arbiter', () async {
      await a.startBatch();
      // Native terminal stop wired through the wrapped onStop.
      micA.capturedOnStop!.call();
      await startMic(b);
      expect(micB.startCalls, 1);
    });

    test('a voice memo started during a call is refused, not handed silence', () async {
      arbiter.holdForCall();
      await expectLater(startMic(b), throwsStateError);
      expect(micB.startCalls, 0, reason: 'the recorder must not run beside a live call');
      arbiter.releaseCall();
      await startMic(b);
      expect(micB.startCalls, 1);
    });

    test('batch capture is refused during a call too', () async {
      arbiter.holdForCall();
      await expectLater(a.startBatch(), throwsStateError);
      expect(micA.startBatchCalls, 0);
    });

    // '(held by null)' is what this would read as otherwise, sending whoever reads the
    // log looking for a recorder that never existed.
    test('the contention message names the call', () async {
      arbiter.holdForCall();
      await expectLater(
        startMic(b),
        throwsA(isA<StateError>().having((e) => e.message, 'message', contains('an in-app call'))),
      );
    });
  });
}
