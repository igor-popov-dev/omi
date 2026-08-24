// A 1:1 port of the desktop (Electron/TS) test suite at
// `desktop/windows/src/renderer/src/lib/ptt/gate.test.ts`. Test names and
// fixture shapes are kept as close to the TS originals as Dart naming
// conventions allow (camelCase `test()` descriptions match verbatim; the
// TS `it()` grouping under two `describe()` blocks is kept as two
// `group()`s below).
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:omi/services/voice_hub/ptt_gate.dart';

const int _sr = 16000;

Int16List _zeros(double ms) => Int16List((ms / 1000 * _sr).round());

Int16List _sine(double ms, double amplitude, {double freq = 440}) {
  final n = (ms / 1000 * _sr).round();
  final out = Int16List(n);
  for (var i = 0; i < n; i++) {
    out[i] = (amplitude * math.sin(2 * math.pi * freq * i / _sr)).round();
  }
  return out;
}

Int16List _concat(List<Int16List> parts) {
  final total = parts.fold<int>(0, (n, p) => n + p.length);
  final out = Int16List(total);
  var off = 0;
  for (final p in parts) {
    out.setAll(off, p);
    off += p.length;
  }
  return out;
}

void main() {
  group('voicedStats', () {
    test('measures silence as zero voiced', () {
      final s = voicedStats(_zeros(1000));
      expect(s.totalSec, closeTo(1.0, 1e-3));
      expect(s.voicedSec, 0);
    });

    test('measures a loud sine as fully voiced', () {
      final s = voicedStats(_sine(1000, 8000));
      expect(s.voicedSec, greaterThan(0.95));
      expect(s.voicedSec, lessThanOrEqualTo(1.0));
    });

    test('does not count low-level noise as voiced (RMS below threshold)', () {
      // sine RMS = amplitude/√2; amplitude 100 → RMS ≈ 71, far under 300.
      expect(voicedStats(_sine(1000, 100)).voicedSec, 0);
    });

    test('applies the RMS threshold with >= semantics at the boundary', () {
      // amplitude a → RMS a/√2. 430/√2 ≈ 304 (voiced); 400/√2 ≈ 283 (not).
      expect(voicedStats(_sine(1000, 430)).voicedSec, greaterThan(0.9));
      expect(voicedStats(_sine(1000, 400)).voicedSec, 0);
    });

    test('measures voiced islands inside silence', () {
      // 100ms of speech embedded in 1s of silence (frame-aligned).
      final s = voicedStats(_concat([_zeros(400), _sine(100, 8000), _zeros(500)]));
      expect(s.voicedSec, closeTo(0.1, 1e-2));
      expect(s.totalSec, closeTo(1.0, 1e-3));
    });

    test('handles a trailing partial frame without throwing', () {
      final pcm = Int16List(voicedFrameSamples + 7);
      expect(() => voicedStats(pcm), returnsNormally);
      expect(voicedStats(pcm).totalSec, closeTo(pcm.length / _sr, 1e-6));
    });

    test('handles an empty buffer', () {
      final s = voicedStats(Int16List(0));
      expect(s.totalSec, 0);
      expect(s.voicedSec, 0);
    });

    test('measures peak so a dead input can be told from a quiet room', () {
      expect(voicedStats(_zeros(1000)).peak, 0);
      expect(voicedStats(_sine(1000, 8000)).peak, greaterThan(7500));
    });

    test('gates a full 4.5-minute buffer within the perf budget', () {
      voicedStats(_sine(1000, 3000)); // JIT/warm-up so the measurement isn't cold-start.
      final pcm = _sine(4.5 * 60 * 1000, 3000);
      final sw = Stopwatch()..start();
      voicedStats(pcm);
      sw.stop();
      // The budget exists to catch order-of-magnitude regressions, sized
      // generously so a loaded CI runner can't flake it (TS budget: 400ms).
      expect(sw.elapsedMilliseconds, lessThan(2000));
    });
  });

  group('gateDecision', () {
    test('flags a capture shorter than the minimum as too-short regardless of voicing', () {
      expect(
        gateDecision(
          const AudioStats(totalSec: minTotalAudioSec - 0.01, voicedSec: minTotalAudioSec - 0.01, peak: 8000),
        ),
        GateDecision.tooShort,
      );
    });

    test('accepts exactly the minimum total duration', () {
      expect(
        gateDecision(const AudioStats(totalSec: minTotalAudioSec, voicedSec: minVoicedSec, peak: 8000)),
        GateDecision.ok,
      );
    });

    test('discards a long-but-silent hold silently', () {
      expect(
        gateDecision(const AudioStats(totalSec: 2.0, voicedSec: minVoicedSec - 0.01, peak: 200)),
        GateDecision.silent,
      );
    });

    test('accepts exactly the minimum voiced duration', () {
      expect(gateDecision(const AudioStats(totalSec: 1.0, voicedSec: minVoicedSec, peak: 8000)), GateDecision.ok);
    });

    test('distinguishes dead-mic (flat-line) from silent (quiet room)', () {
      expect(gateDecision(const AudioStats(totalSec: 2.0, voicedSec: 0, peak: 0)), GateDecision.deadMic);
      expect(gateDecision(const AudioStats(totalSec: 2.0, voicedSec: 0, peak: 200)), GateDecision.silent);
    });

    test('end-to-end: quiet speech below the RMS threshold is discarded, loud is kept', () {
      // Mirrors the TS fixture (×0.05 attenuation → RMS ~142).
      final quiet = _sine(1000, 200);
      final loud = _sine(1000, 3000);
      expect(gateDecision(voicedStats(quiet)), GateDecision.silent);
      expect(gateDecision(voicedStats(loud)), GateDecision.ok);
    });

    test('threshold constants are the macOS-parity values tests were written against', () {
      // If these change, re-verify against macOS PushToTalkManager and the
      // TS source's mirrored literals (`ptt/constants.ts`).
      expect(minTotalAudioSec, 0.35);
      expect(minVoicedSec, 0.2);
      expect(voicedRmsThreshold, 300);
      expect(voicedFrameSamples, 320);
    });
  });
}
