import 'package:flutter/material.dart';

import 'package:provider/provider.dart';
import 'package:omi/widgets/shimmer_with_timeout.dart';

import 'package:omi/providers/voice_recorder_provider.dart';
import 'package:omi/utils/l10n_extensions.dart';
import 'package:omi/utils/theme/omi_tokens.dart';

/// Compact waveform pill that lives inside the chat input row, between the
/// stop button and the send button. Mirrors the visual treatment of the
/// regular text field so the input bar feels cohesive in voice mode.
class VoiceRecorderWidget extends StatefulWidget {
  final Function(String transcript, bool autoSend) onTranscriptReady;
  final VoidCallback onClose;

  const VoiceRecorderWidget({super.key, required this.onTranscriptReady, required this.onClose});

  @override
  State<VoiceRecorderWidget> createState() => _VoiceRecorderWidgetState();
}

class _VoiceRecorderWidgetState extends State<VoiceRecorderWidget> with SingleTickerProviderStateMixin {
  late AnimationController _animationController;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(vsync: this, duration: const Duration(milliseconds: 1000))
      ..repeat(reverse: true);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      final provider = context.read<VoiceRecorderProvider>();
      provider.setCallbacks(onTranscriptReady: widget.onTranscriptReady, onClose: widget.onClose);

      if (!provider.isRecording && !provider.hasPendingRecording) {
        provider.startRecording();
      }
    });
  }

  @override
  void dispose() {
    _animationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.omi;
    return Consumer<VoiceRecorderProvider>(
      builder: (context, provider, child) {
        switch (provider.state) {
          case VoiceRecorderState.recording:
            return SizedBox(
              height: 44,
              child: Row(
                children: [
                  Expanded(
                    child: CustomPaint(
                      painter: AudioWavePainter(
                        levels: provider.audioLevels,
                        waveColor: t.textPrimary.withValues(alpha: 0.85),
                      ),
                      child: const SizedBox.expand(),
                    ),
                  ),
                  // Self-host patch, not for upstream: recording had NO way out —
                  // the only control was "send", so a user who changed their mind
                  // (or whose transcription would fail anyway) was stuck listening
                  // to themselves with the composer locked. Reported live 23.08.
                  GestureDetector(
                    onTap: provider.close,
                    child: const Padding(
                      padding: EdgeInsets.only(left: 8, right: 4),
                      child: Icon(Icons.close, color: Color(0xFF8E8E93), size: 20),
                    ),
                  ),
                ],
              ),
            );

          case VoiceRecorderState.transcribing:
            return SizedBox(
              height: 44,
              child: Row(
                children: [
                  Expanded(
                    child: Center(
                      child: ShimmerWithTimeout(
                        baseColor: t.bgTertiary,
                        highlightColor: t.textPrimary,
                        child: Text(
                          context.l10n.transcribing,
                          style: TextStyle(color: t.textPrimary, fontSize: 15),
                        ),
                      ),
                    ),
                  ),
                  // Self-host patch: transcription can hang (backend down, STT
                  // unreachable), and this state had no exit at all — the composer
                  // stayed locked on "Расшифровываю…" indefinitely.
                  GestureDetector(
                    onTap: provider.close,
                    child: const Padding(
                      padding: EdgeInsets.only(left: 8, right: 4),
                      child: Icon(Icons.close, color: Color(0xFF8E8E93), size: 20),
                    ),
                  ),
                ],
              ),
            );

          // Nothing was recognized in the recording. Re-uploading the same
          // bytes would return the same empty result, so the only offer here
          // is a fresh take — and it reads as an outcome, not as an error.
          case VoiceRecorderState.noSpeechDetected:
            return SizedBox(
              height: 44,
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      context.l10n.voiceNoSpeechDetected,
                      style: TextStyle(
                          color: t.textPrimary.withValues(alpha: 0.7), fontSize: 13, fontWeight: FontWeight.w500),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  GestureDetector(
                    onTap: provider.recordAgain,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: Icon(Icons.mic_none, color: t.textPrimary, size: 20),
                    ),
                  ),
                  // Same exit as the error bar below: not wanting to speak again
                  // must not leave the composer occupied.
                  GestureDetector(
                    onTap: provider.close,
                    child: const Padding(
                      padding: EdgeInsets.only(left: 4, right: 8),
                      child: Icon(Icons.close, color: Color(0xFF8E8E93), size: 20),
                    ),
                  ),
                ],
              ),
            );

          case VoiceRecorderState.transcribeFailed:
          case VoiceRecorderState.pendingRecovery:
            return SizedBox(
              height: 44,
              child: Row(
                children: [
                  Text(
                    provider.state == VoiceRecorderState.pendingRecovery
                        ? context.l10n.voiceRecordingFound
                        : context.l10n.error,
                    style: TextStyle(
                      color: provider.state == VoiceRecorderState.pendingRecovery ? t.textPrimary : t.error,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: SizedBox(
                      height: 32,
                      child: CustomPaint(
                        painter: AudioWavePainter(
                          levels: provider.audioLevels,
                          waveColor: t.textPrimary.withValues(alpha: 0.85),
                        ),
                        child: const SizedBox.expand(),
                      ),
                    ),
                  ),
                  GestureDetector(
                    onTap: provider.retry,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: Icon(Icons.refresh, color: t.textPrimary, size: 20),
                    ),
                  ),
                  // Self-host patch, not for upstream: a failed transcription had
                  // retry as its ONLY exit. When the failure is not transient (the
                  // backend is down, the recording is unusable) the error bar sits
                  // in the composer permanently, with no way to dismiss it and get
                  // the text field back. close() drops the recording and its temp
                  // files and returns the composer to idle.
                  GestureDetector(
                    onTap: provider.close,
                    child: const Padding(
                      padding: EdgeInsets.only(left: 4, right: 8),
                      child: Icon(Icons.close, color: Color(0xFF8E8E93), size: 20),
                    ),
                  ),
                ],
              ),
            );

          default:
            return const SizedBox(height: 44);
        }
      },
    );
  }
}

class AudioWavePainter extends CustomPainter {
  final List<double> levels;

  /// Wave color. A painter has no BuildContext, so the token is resolved by the
  /// caller; the fallback is the Classic value for callers without a theme.
  final Color? waveColor;

  AudioWavePainter({required List<double> levels, this.waveColor}) : levels = List<double>.from(levels);

  @override
  void paint(Canvas canvas, Size size) {
    if (levels.isEmpty || size.width <= 0 || size.height <= 0) return;

    final paint = Paint()
      ..color = waveColor ?? const Color(0xD9FFFFFF)
      ..strokeWidth = 2.0
      ..strokeCap = StrokeCap.round;

    final width = size.width;
    final height = size.height;
    final centerY = height / 2;
    // Even spacing across the full width regardless of level count.
    final spacing = width / levels.length;
    // Min bar = a small dot so silence still reads as "active".
    const minBarHeight = 3.0;
    final maxBarHeight = height * 0.92;

    for (int i = 0; i < levels.length; i++) {
      final x = spacing * (i + 0.5);
      final level = levels[i].clamp(0.0, 1.0);
      final barHeight = (minBarHeight + level * (maxBarHeight - minBarHeight)).clamp(minBarHeight, maxBarHeight);

      canvas.drawLine(
        Offset(x, centerY - barHeight / 2),
        Offset(x, centerY + barHeight / 2),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant AudioWavePainter oldDelegate) {
    if (levels.length != oldDelegate.levels.length) return true;
    for (int i = 0; i < levels.length; i++) {
      if ((levels[i] - oldDelegate.levels[i]).abs() > 0.005) return true;
    }
    return false;
  }
}
