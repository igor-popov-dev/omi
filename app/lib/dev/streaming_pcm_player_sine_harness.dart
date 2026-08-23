// Manual dev harness for the native voice-hub player (design doc §7/§4 step 3,
// lane5.md "Kotlin-плеер ... тест-харнесс (проиграть синус) без остального
// приложения"). Isolated from the rest of the app on purpose: this exercises
// only StreamingPcmPlayer.kt + its Pigeon bridge, not the hub session/turn
// machinery above it.
//
// Deliberately NOT run as part of this task — night-task.md forbids installing
// anything to a phone or making sounds during the unattended marathon. Run it
// yourself, by hand, when you want to confirm the native player actually
// produces sound:
//
//   flutter run -t lib/dev/streaming_pcm_player_sine_harness.dart -d <deviceId>
//
// Tap "Play 440Hz sine" and you should hear a clean tone for ~2s, watch the
// status line go start → started → draining → drained, and — the real point
// of this harness — be able to mash the button mid-tone to check that a
// second start() cuts the first tone off immediately (the same discard path
// barge-in uses, see StreamingPcmPlayer.clear() / design doc §6).
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:omi/services/voice_hub/hub_session.dart';
import 'package:omi/services/voice_hub/native_voice_player.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const _SineHarnessApp());
}

class _SineHarnessApp extends StatelessWidget {
  const _SineHarnessApp();

  @override
  Widget build(BuildContext context) => const MaterialApp(home: _SineHarnessPage());
}

class _SineHarnessPage extends StatefulWidget {
  const _SineHarnessPage();

  @override
  State<_SineHarnessPage> createState() => _SineHarnessPageState();
}

class _SineHarnessPageState extends State<_SineHarnessPage> {
  static const _sampleRate = 24000; // Must match StreamingPcmPlayer.SAMPLE_RATE.
  static const _toneHz = 440.0;
  static const _toneDuration = Duration(seconds: 2);
  static const _chunkDuration = Duration(milliseconds: 100); // Simulates Gemini's per-frame cadence.

  String _status = 'idle';
  VoicePlayer? _player;

  Future<void> _play() async {
    // A fresh press always supersedes whatever is currently playing — same
    // "new start always wins" rule as barge-in (design doc §6 step 1).
    _player?.clear();
    _player?.close();
    setState(() => _status = 'starting…');

    final player = await nativeVoicePlayerFactory(VoicePlayerStartSpec(
      onStarted: () => setState(() => _status = 'started (should be audible now)'),
      onDrained: () => setState(() => _status = 'drained'),
    ));
    _player = player;

    final totalFrames = (_sampleRate * _toneDuration.inMilliseconds) ~/ 1000;
    final framesPerChunk = (_sampleRate * _chunkDuration.inMilliseconds) ~/ 1000;
    setState(() => _status = 'streaming tone…');
    for (var start = 0; start < totalFrames; start += framesPerChunk) {
      final end = math.min(start + framesPerChunk, totalFrames);
      player.enqueuePcm16(_sineChunk(start, end));
      // Pace the enqueue loop roughly like real audio arrival — otherwise this
      // dumps the whole 2s tone into the native queue instantly, which still
      // plays correctly but doesn't exercise the same timing as a live turn.
      await Future.delayed(_chunkDuration);
    }
    player.flush();
  }

  /// PCM16LE mono samples for `[startFrame, endFrame)` of a continuous sine
  /// wave — phase is continuous across chunks because it's computed from the
  /// absolute frame index, not reset per chunk.
  Uint8List _sineChunk(int startFrame, int endFrame) {
    final bytes = ByteData((endFrame - startFrame) * 2);
    for (var i = startFrame; i < endFrame; i++) {
      final t = i / _sampleRate;
      final sample = (math.sin(2 * math.pi * _toneHz * t) * 0.6 * 32767).round();
      bytes.setInt16((i - startFrame) * 2, sample, Endian.little);
    }
    return bytes.buffer.asUint8List();
  }

  @override
  void dispose() {
    _player?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('StreamingPcmPlayer sine harness')),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('status: $_status'),
            const SizedBox(height: 24),
            ElevatedButton(onPressed: _play, child: const Text('Play 440Hz sine')),
            const SizedBox(height: 8),
            const Text('Tap again mid-tone to check barge-in cutoff.', textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }
}
