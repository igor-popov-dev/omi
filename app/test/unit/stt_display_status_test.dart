import 'package:flutter_test/flutter_test.dart';
import 'package:omi/services/capture/stt_display_status.dart';

void main() {
  final now = DateTime(2026, 8, 23, 12, 0, 0);

  SttDisplayStatus compute({
    bool isPaused = false,
    bool hasTerminalFailure = false,
    Duration? bufferingFor,
    bool transportHealthy = true,
    DateTime? lastSegmentAt,
  }) {
    return computeSttDisplayStatus(
      isPaused: isPaused,
      hasTerminalFailure: hasTerminalFailure,
      bufferingFor: bufferingFor,
      transportHealthy: transportHealthy,
      lastSegmentAt: lastSegmentAt,
      now: now,
    );
  }

  test('paused wins over everything else', () {
    expect(
      compute(
        isPaused: true,
        hasTerminalFailure: true,
        bufferingFor: const Duration(minutes: 2),
        transportHealthy: false,
        lastSegmentAt: now,
      ),
      SttDisplayStatus.paused,
    );
  });

  test('terminal failure wins over buffering and activity', () {
    expect(
      compute(hasTerminalFailure: true, bufferingFor: const Duration(minutes: 2), lastSegmentAt: now),
      SttDisplayStatus.failed,
    );
  });

  test('offline buffering wins over recent segments', () {
    expect(
      compute(bufferingFor: const Duration(seconds: 30), lastSegmentAt: now.subtract(const Duration(seconds: 5))),
      SttDisplayStatus.offlineBuffering,
    );
  });

  test('a dead transport is disconnected, never "waiting for speech"', () {
    expect(compute(transportHealthy: false), SttDisplayStatus.disconnected);
    // Even with a recent segment: the socket is gone NOW.
    expect(
      compute(transportHealthy: false, lastSegmentAt: now.subtract(const Duration(seconds: 5))),
      SttDisplayStatus.disconnected,
    );
  });

  test('recent recognized segments read as live, stale ones decay to waiting', () {
    expect(compute(lastSegmentAt: now.subtract(sttLiveActivityWindow)), SttDisplayStatus.live);
    expect(
      compute(lastSegmentAt: now.subtract(sttLiveActivityWindow + const Duration(seconds: 1))),
      SttDisplayStatus.waitingForSpeech,
    );
  });

  test('healthy transport with no segments at all is waiting for speech, not live', () {
    expect(compute(), SttDisplayStatus.waitingForSpeech);
  });
}
