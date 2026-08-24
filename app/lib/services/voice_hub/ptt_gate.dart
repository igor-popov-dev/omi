// Pure release-gate math for push-to-talk — a 1:1 port of
// `desktop/windows/src/renderer/src/lib/ptt/gate.ts` (itself a port of the
// macOS `voicedAudioSeconds` / finalize silence-gate design). Decide from
// the captured PCM alone — before ANY network work — whether a hold is
// worth transcribing.
//
// Ground rule (same as the rest of `voice_hub/`, design doc §8): ZERO
// imports of Flutter, dart:io, or networking. `dart:typed_data`/`dart:math`
// are core Dart (not Flutter-specific) — the natural Dart counterparts of
// TS's `Int16Array` and `Math.sqrt` for a raw PCM16 buffer.

import 'dart:math' as math;
import 'dart:typed_data';

// ---------------------------------------------------------------------------
// MARK: - Constants (TS `ptt/constants.ts`, macOS-parity values)
// ---------------------------------------------------------------------------

/// Below this total capture duration, release beat the capture entirely
/// (fast tap) — always `tooShort`, regardless of voicing.
const double minTotalAudioSec = 0.35;

/// Below this much *voiced* duration, a real hold had no speech in it.
const double minVoicedSec = 0.2;

/// A 20ms frame counts as voiced when its RMS is at or above this (int16
/// units).
const int voicedRmsThreshold = 300;

/// Frame size for RMS voicing measurement: 20ms @ 16kHz.
const int voicedFrameSamples = 320;

/// Below this peak (int16 units), a non-voiced hold is a dead/flat-lined
/// input (virtual cable, muted/broken mic) rather than a merely quiet room.
const int deadMicPeak = 5;

// ---------------------------------------------------------------------------
// MARK: - AudioStats / voicedStats
// ---------------------------------------------------------------------------

class AudioStats {
  /// Total captured duration in seconds.
  final double totalSec;

  /// Seconds of 20ms frames whose RMS met the voiced threshold.
  final double voicedSec;

  /// Loudest absolute sample (int16). Distinguishes a DEAD input (peak ≈ 0 —
  /// virtual cable, muted/broken device) from a merely quiet room.
  final int peak;

  const AudioStats({required this.totalSec, required this.voicedSec, required this.peak});
}

/// Measure a raw 16kHz mono PCM16 buffer: total duration + voiced duration
/// (RMS over 20ms frames, macOS parity) + peak. A trailing partial frame is
/// ignored for voicing but counted in totalSec/peak.
AudioStats voicedStats(Int16List pcm) {
  final totalSec = pcm.length / 16000;
  var voicedFrames = 0;
  var peak = 0;
  final frames = pcm.length ~/ voicedFrameSamples;
  for (var f = 0; f < frames; f++) {
    final base = f * voicedFrameSamples;
    var sumSq = 0;
    for (var i = 0; i < voicedFrameSamples; i++) {
      final s = pcm[base + i];
      sumSq += s * s;
      final a = s < 0 ? -s : s;
      if (a > peak) peak = a;
    }
    if (math.sqrt(sumSq / voicedFrameSamples) >= voicedRmsThreshold) voicedFrames++;
  }
  for (var i = frames * voicedFrameSamples; i < pcm.length; i++) {
    final s = pcm[i];
    final a = s < 0 ? -s : s;
    if (a > peak) peak = a;
  }
  return AudioStats(totalSec: totalSec, voicedSec: (voicedFrames * voicedFrameSamples) / 16000, peak: peak);
}

// ---------------------------------------------------------------------------
// MARK: - GateDecision
// ---------------------------------------------------------------------------

enum GateDecision {
  /// Release beat the capture (fast tap): show "Hold longer to record".
  tooShort,

  /// A real hold whose input is flat-lined (virtual cable, muted/broken
  /// mic): show an actionable hint — the user thinks they spoke.
  deadMic,

  /// A real hold with no speech in a live room: discard silently — never
  /// send silence to STT (it hallucinates phrases).
  silent,

  /// Worth transcribing.
  ok,
}

GateDecision gateDecision(AudioStats stats) {
  if (stats.totalSec < minTotalAudioSec) return GateDecision.tooShort;
  if (stats.voicedSec < minVoicedSec) {
    return stats.peak < deadMicPeak ? GateDecision.deadMic : GateDecision.silent;
  }
  return GateDecision.ok;
}
