// Telegram-style bubble for a spoken assistant reply: round play/pause on the
// left, a tappable/draggable bar waveform for the progress on the right,
// elapsed / total time and a 1x → 1.5x → 2x speed badge under it, and a
// "Show text" chevron that unfolds the transcript (the message's own `text`,
// which `bin/send_voice_message.py` fed to the TTS). Colours come from the
// theme's `colorScheme` so the bubble reads in both light and dark.
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:omi/backend/schema/message.dart';
import 'package:omi/pages/chat/widgets/markdown_message_widget.dart';
import 'package:omi/services/voice_message/voice_message_player.dart';
import 'package:omi/utils/l10n_extensions.dart';

class VoiceMessageWidget extends StatefulWidget {
  final ServerMessage message;
  final MessageFile file;
  final VoiceMessagePlayer? player;
  final Function(String)? onAskOmi;

  const VoiceMessageWidget({super.key, required this.message, required this.file, this.player, this.onAskOmi});

  static Key playKey(String fileId) => ValueKey('voice_message_play_$fileId');
  static Key waveformKey(String fileId) => ValueKey('voice_message_waveform_$fileId');
  static Key speedKey(String fileId) => ValueKey('voice_message_speed_$fileId');
  static Key transcriptToggleKey(String fileId) => ValueKey('voice_message_transcript_toggle_$fileId');
  static Key transcriptKey(String fileId) => ValueKey('voice_message_transcript_$fileId');

  @override
  State<VoiceMessageWidget> createState() => _VoiceMessageWidgetState();
}

class _VoiceMessageWidgetState extends State<VoiceMessageWidget> {
  bool _showTranscript = false;

  VoiceMessagePlayer get _player => widget.player ?? VoiceMessagePlayer.instance;

  VoiceMessageRef? get _ref => VoiceMessageRef.fromFile(widget.message.id, widget.file);

  String get _transcript => widget.message.text.trim();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = scheme.brightness == Brightness.dark;
    final foreground = scheme.onSurface;
    final onButton = isDark ? Colors.black : Colors.white;
    final bubble = foreground.withValues(alpha: 0.07);
    final border = foreground.withValues(alpha: 0.12);
    final ref = _ref;

    return AnimatedBuilder(
      animation: _player,
      builder: (context, _) {
        final messageId = widget.message.id;
        final playing = _player.isPlaying(messageId);
        final loading = _player.isLoading(messageId);
        final total = _player.durationOf(messageId, fallback: widget.file.duration);
        final position = _player.positionOf(messageId);
        final fraction = total == null || total.inMilliseconds == 0
            ? 0.0
            : (position.inMilliseconds / total.inMilliseconds).clamp(0.0, 1.0);

        return Container(
          margin: const EdgeInsets.only(top: 2, bottom: 6),
          constraints: const BoxConstraints(maxWidth: 320, minWidth: 220),
          padding: const EdgeInsets.fromLTRB(10, 10, 12, 8),
          decoration: BoxDecoration(
            color: bubble,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: border),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  _PlayButton(
                    key: VoiceMessageWidget.playKey(widget.file.id),
                    playing: playing,
                    loading: loading,
                    enabled: ref != null,
                    background: foreground,
                    foreground: onButton,
                    onTap: ref == null ? null : () => _player.toggle(ref),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                          height: 30,
                          child: LayoutBuilder(
                            builder: (context, constraints) {
                              return GestureDetector(
                                key: VoiceMessageWidget.waveformKey(widget.file.id),
                                behavior: HitTestBehavior.opaque,
                                onTapDown: (details) => _seekTo(details.localPosition.dx, constraints.maxWidth, total),
                                onHorizontalDragUpdate: (details) =>
                                    _seekTo(details.localPosition.dx, constraints.maxWidth, total),
                                child: CustomPaint(
                                  size: Size(constraints.maxWidth, 30),
                                  painter: VoiceWaveformPainter(
                                    seed: widget.file.id,
                                    progress: fraction,
                                    playedColor: foreground,
                                    remainingColor: foreground.withValues(alpha: 0.3),
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            Text(
                              '${formatVoiceMessageDuration(position)} / '
                              '${total == null ? '–:––' : formatVoiceMessageDuration(total)}',
                              style: TextStyle(
                                color: foreground.withValues(alpha: 0.7),
                                fontSize: 12,
                                fontFeatures: const [FontFeature.tabularFigures()],
                              ),
                            ),
                            const Spacer(),
                            _SpeedBadge(
                              key: VoiceMessageWidget.speedKey(widget.file.id),
                              speed: _player.speed,
                              foreground: foreground,
                              onTap: _player.cycleSpeed,
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              if (_transcript.isNotEmpty) ...[
                const SizedBox(height: 4),
                InkWell(
                  key: VoiceMessageWidget.transcriptToggleKey(widget.file.id),
                  borderRadius: BorderRadius.circular(8),
                  onTap: () => setState(() => _showTranscript = !_showTranscript),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          _showTranscript ? Icons.expand_less : Icons.expand_more,
                          size: 18,
                          color: foreground.withValues(alpha: 0.7),
                        ),
                        const SizedBox(width: 4),
                        Text(
                          _showTranscript ? context.l10n.voiceMessageHideText : context.l10n.voiceMessageShowText,
                          style: TextStyle(color: foreground.withValues(alpha: 0.7), fontSize: 13),
                        ),
                      ],
                    ),
                  ),
                ),
                if (_showTranscript)
                  Padding(
                    key: VoiceMessageWidget.transcriptKey(widget.file.id),
                    padding: const EdgeInsets.fromLTRB(4, 2, 4, 4),
                    child: getMarkdownWidget(context, _transcript, onAskOmi: widget.onAskOmi),
                  ),
              ],
            ],
          ),
        );
      },
    );
  }

  void _seekTo(double dx, double width, Duration? total) {
    final ref = _ref;
    if (ref == null || total == null || width <= 0 || total.inMilliseconds == 0) return;
    final fraction = (dx / width).clamp(0.0, 1.0);
    _player.seek(ref, Duration(milliseconds: (total.inMilliseconds * fraction).round()));
  }
}

class _PlayButton extends StatelessWidget {
  final bool playing;
  final bool loading;
  final bool enabled;
  final Color background;
  final Color foreground;
  final VoidCallback? onTap;

  const _PlayButton({
    super.key,
    required this.playing,
    required this.loading,
    required this.enabled,
    required this.background,
    required this.foreground,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: enabled ? background : background.withValues(alpha: 0.4),
      shape: const CircleBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: enabled && !loading ? onTap : null,
        child: SizedBox(
          width: 44,
          height: 44,
          child: Center(
            child: loading
                ? SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2, color: foreground),
                  )
                : Icon(playing ? Icons.pause_rounded : Icons.play_arrow_rounded, color: foreground, size: 28),
          ),
        ),
      ),
    );
  }
}

class _SpeedBadge extends StatelessWidget {
  final double speed;
  final Color foreground;
  final VoidCallback onTap;

  const _SpeedBadge({super.key, required this.speed, required this.foreground, required this.onTap});

  static String label(double speed) {
    final text = speed == speed.roundToDouble() ? speed.toInt().toString() : speed.toString();
    return '${text}x';
  }

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
          color: foreground.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text(
          label(speed),
          style: TextStyle(color: foreground, fontSize: 12, fontWeight: FontWeight.w600),
        ),
      ),
    );
  }
}

/// Bars of pseudo-random height (stable per [seed], so a bubble keeps its
/// shape across rebuilds) filled up to [progress].
class VoiceWaveformPainter extends CustomPainter {
  final String seed;
  final double progress;
  final Color playedColor;
  final Color remainingColor;

  static const double barWidth = 3;
  static const double gap = 2;

  const VoiceWaveformPainter({
    required this.seed,
    required this.progress,
    required this.playedColor,
    required this.remainingColor,
  });

  static List<double> heightsFor(String seed, int count) {
    var state = seed.hashCode & 0x7fffffff;
    if (state == 0) state = 1;
    final heights = <double>[];
    for (var i = 0; i < count; i++) {
      state = (state * 1103515245 + 12345) & 0x7fffffff;
      final unit = (state >> 8) / 0x7fffff; // 0..1
      // Skew towards mid heights so the shape reads as speech, not noise.
      heights.add(0.25 + 0.75 * math.pow(unit, 1.4));
    }
    return heights;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final count = math.max(1, ((size.width + gap) / (barWidth + gap)).floor());
    final heights = heightsFor(seed, count);
    final playedPaint = Paint()..color = playedColor;
    final remainingPaint = Paint()..color = remainingColor;
    final playedUntil = progress * size.width;
    for (var i = 0; i < count; i++) {
      final x = i * (barWidth + gap);
      final barHeight = math.max(3.0, heights[i] * size.height);
      final rect = RRect.fromRectAndRadius(
        Rect.fromLTWH(x, (size.height - barHeight) / 2, barWidth, barHeight),
        const Radius.circular(1.5),
      );
      canvas.drawRRect(rect, x + barWidth / 2 <= playedUntil ? playedPaint : remainingPaint);
    }
  }

  @override
  bool shouldRepaint(covariant VoiceWaveformPainter oldDelegate) {
    return oldDelegate.seed != seed ||
        oldDelegate.progress != progress ||
        oldDelegate.playedColor != playedColor ||
        oldDelegate.remainingColor != remainingColor;
  }
}
