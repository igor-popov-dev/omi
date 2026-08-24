import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:omi/models/local_recording.dart';
import 'package:omi/providers/local_recordings_provider.dart';
import 'package:omi/widgets/omi_confirm_dialog.dart';
import 'package:omi/utils/alerts/app_snackbar.dart';
import 'package:omi/utils/l10n_extensions.dart';
import 'package:omi/utils/other/temp.dart';
import 'package:omi/utils/other/time_utils.dart';
import 'package:omi/utils/theme/omi_tokens.dart';
import 'package:omi/widgets/waveform_painter.dart';
import 'package:omi/utils/theme/omi_tokens.dart';

/// Floating bottom sheet for a batch/offline recording — playback (waveform +
/// scrub + transport), the primary "Sync now" (transcribe → conversation)
/// action, and share / details / delete. Replaces the old full-page detail.
Future<void> showRecordingDetailSheet(BuildContext context, LocalRecording recording) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _RecordingDetailSheet(recording: recording),
  );
}

class _RecordingDetailSheet extends StatefulWidget {
  final LocalRecording recording;

  const _RecordingDetailSheet({required this.recording});

  @override
  State<_RecordingDetailSheet> createState() => _RecordingDetailSheetState();
}

class _RecordingDetailSheetState extends State<_RecordingDetailSheet> {
  List<double>? _waveform;
  bool _loadingWaveform = false;
  Timer? _ticker;
  LocalRecordingsProvider? _provider;

  @override
  void initState() {
    super.initState();
    _loadWaveform();
    _ticker = Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (mounted && (_provider?.isPlaying(widget.recording) ?? false)) setState(() {});
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _provider = context.read<LocalRecordingsProvider>();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    if (_provider != null && _provider!.isPlaying(widget.recording)) {
      _provider!.togglePlayback(widget.recording);
    }
    super.dispose();
  }

  Future<void> _loadWaveform() async {
    if (!mounted) return;
    setState(() => _loadingWaveform = true);
    final data = await context.read<LocalRecordingsProvider>().getWaveform(widget.recording);
    if (!mounted) return;
    setState(() {
      _waveform = _normalize(data);
      _loadingWaveform = false;
    });
  }

  // Scale amplitudes so the loudest bar nearly fills the height — a quiet
  // recording still reads as a real waveform instead of a flat line.
  List<double>? _normalize(List<double>? data) {
    if (data == null || data.isEmpty) return data;
    final maxV = data.reduce(math.max);
    if (maxV <= 0) return data;
    final scale = 0.95 / maxV;
    return data.map((v) => (v * scale).clamp(0.0, 1.0)).toList();
  }

  String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60);
    final s = d.inSeconds.remainder(60);
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final t = context.omi;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Container(
        margin: const EdgeInsets.all(8),
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(color: t.bgSecondary, borderRadius: BorderRadius.circular(28)),
        child: SafeArea(
          top: false,
          child: Consumer<LocalRecordingsProvider>(
            builder: (context, provider, child) {
              final rec = provider.getById(widget.recording.id) ?? widget.recording;
              final isPlaying = provider.isPlaying(rec);
              final canPlay = provider.canPlay(rec);
              final total = provider.totalDuration.inMilliseconds > 0 && isPlaying
                  ? provider.totalDuration
                  : Duration(seconds: rec.seconds);
              final position = isPlaying ? provider.currentPosition : Duration.zero;
              final progress = isPlaying ? provider.playbackProgress.clamp(0.0, 1.0) : 0.0;

              return Stack(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 14, 24, 30),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 36,
                          height: 4,
                          decoration: BoxDecoration(
                            color: t.divider,
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                        const SizedBox(height: 18),
                        Row(
                          children: [
                            const SizedBox(width: 40),
                            Expanded(
                              child: Column(
                                children: [
                                  Text(
                                    dateTimeFormat('dd MMM yyyy', rec.startedAt),
                                    style: TextStyle(
                                      color: t.textPrimary,
                                      fontSize: 19,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  const SizedBox(height: 3),
                                  Text(
                                    dateTimeFormat('h:mm a', rec.startedAt),
                                    style: TextStyle(color: t.textSecondary, fontSize: 13),
                                  ),
                                ],
                              ),
                            ),
                            _buildMenu(context, provider, rec),
                          ],
                        ),
                        const SizedBox(height: 36),
                        SizedBox(height: 60, child: _buildWaveform(provider, rec, isPlaying, canPlay, total, progress)),
                        const SizedBox(height: 14),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(_fmt(position), style: _timeStyle),
                            Text(_fmt(total), style: _timeStyle),
                          ],
                        ),
                        const SizedBox(height: 28),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            IconButton(
                              iconSize: 28,
                              color: t.textPrimary,
                              disabledColor: t.textTertiary,
                              onPressed: canPlay && isPlaying ? () => provider.skipBackward() : null,
                              icon: const Icon(Icons.replay_10_rounded),
                            ),
                            const SizedBox(width: 28),
                            GestureDetector(
                              onTap: canPlay ? () => provider.togglePlayback(rec) : null,
                              child: Container(
                                width: 66,
                                height: 66,
                                decoration: BoxDecoration(
                                  color: canPlay ? t.textPrimary : t.bgTertiary,
                                  shape: BoxShape.circle,
                                ),
                                child: Icon(
                                  provider.isProcessingAudio && isPlaying
                                      ? Icons.hourglass_empty_rounded
                                      : (isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded),
                                  color: canPlay ? t.bgPrimary : t.textTertiary,
                                  size: 36,
                                ),
                              ),
                            ),
                            const SizedBox(width: 28),
                            IconButton(
                              iconSize: 28,
                              color: t.textPrimary,
                              disabledColor: t.textTertiary,
                              onPressed: canPlay && isPlaying ? () => provider.skipForward() : null,
                              icon: const Icon(Icons.forward_10_rounded),
                            ),
                          ],
                        ),
                        const SizedBox(height: 32),
                        SizedBox(
                          width: double.infinity,
                          height: 52,
                          child: ElevatedButton.icon(
                            onPressed: rec.isBusy ? null : () => _handleTranscribe(provider, rec),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: t.bgTertiary,
                              disabledBackgroundColor: t.bgTertiary,
                              foregroundColor: t.textPrimary,
                              disabledForegroundColor: t.textTertiary,
                              elevation: 0,
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(t.cardRadius)),
                            ),
                            icon: rec.isBusy
                                ? SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(strokeWidth: 2, color: t.textSecondary),
                                  )
                                : const Icon(Icons.cloud_upload_outlined, size: 20),
                            label: Text(
                              rec.isBusy ? context.l10n.syncStatusUploaded : context.l10n.processNow,
                              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (provider.isPreparingShare) _preparingOverlay(context),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  TextStyle get _timeStyle => TextStyle(
        color: context.omi.textSecondary,
        fontSize: 12,
        fontWeight: FontWeight.w500,
        fontFeatures: const [FontFeature.tabularFigures()],
      );

  Widget _buildWaveform(
    LocalRecordingsProvider provider,
    LocalRecording rec,
    bool isPlaying,
    bool canPlay,
    Duration total,
    double progress,
  ) {
    final t = context.omi;
    if (_loadingWaveform) {
      return Center(
        child: SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(strokeWidth: 2, color: t.textTertiary),
        ),
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        void seek(double dx) {
          if (total.inMilliseconds <= 0) return;
          final p = (dx / constraints.maxWidth).clamp(0.0, 1.0);
          provider.seekTo(Duration(milliseconds: (p * total.inMilliseconds).round()));
        }

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: isPlaying ? (d) => seek(d.localPosition.dx) : null,
          onHorizontalDragUpdate: isPlaying ? (d) => seek(d.localPosition.dx) : null,
          child: SizedBox(
            width: double.infinity,
            height: double.infinity,
            child: RepaintBoundary(
              child: CustomPaint(
                painter: WaveformPainter(
                  isPlaying: isPlaying,
                  t: context.omi,
                  waveformData: _waveform,
                  playbackProgress: progress,
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _preparingOverlay(BuildContext context) {
    final t = context.omi;
    return Positioned.fill(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {},
        child: Container(
          color: t.bgSecondary.withValues(alpha: 0.9),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 26,
                  height: 26,
                  child: CircularProgressIndicator(strokeWidth: 2.5, color: t.textPrimary),
                ),
                const SizedBox(height: 16),
                Text(context.l10n.preparingAudio, style: TextStyle(color: t.textSecondary, fontSize: 14)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildMenu(BuildContext context, LocalRecordingsProvider provider, LocalRecording rec) {
    final t = context.omi;
    return PopupMenuButton<String>(
      icon: Icon(Icons.more_horiz_rounded, color: t.textSecondary),
      color: t.bgTertiary,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      position: PopupMenuPosition.under,
      onSelected: (v) {
        switch (v) {
          case 'share':
            provider.share(rec);
          case 'info':
            _showFileDetailsDialog(context, rec);
          case 'delete':
            _confirmDelete(context, provider, rec);
        }
      },
      itemBuilder: (_) => [
        _menuItem('share', Icons.ios_share_rounded, context.l10n.shareRecording, t.textPrimary),
        _menuItem('info', Icons.info_outline_rounded, context.l10n.recordingInfo, t.textPrimary),
        if (!rec.isBusy) _menuItem('delete', Icons.delete_outline_rounded, context.l10n.delete, t.error),
      ],
    );
  }

  PopupMenuItem<String> _menuItem(String value, IconData icon, String label, Color color) {
    return PopupMenuItem<String>(
      value: value,
      child: Row(
        children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(width: 12),
          Text(label, style: TextStyle(color: color, fontSize: 14)),
        ],
      ),
    );
  }

  Future<void> _handleTranscribe(LocalRecordingsProvider provider, LocalRecording rec) async {
    final outcome = await provider.upload(rec);
    if (!mounted) return;
    switch (outcome) {
      case LocalUploadOutcome.fairUseLimited:
        AppSnackbar.showSnackbarError(context.l10n.fairUseBudgetExhausted, duration: const Duration(seconds: 4));
      case LocalUploadOutcome.backendBusy:
        AppSnackbar.showSnackbarError(context.l10n.msgUploadFileFailed, duration: const Duration(seconds: 4));
      case LocalUploadOutcome.failed:
        AppSnackbar.showSnackbarError(context.l10n.anErrorOccurredTryAgain);
      case LocalUploadOutcome.busy:
        break;
      case LocalUploadOutcome.started:
        Navigator.of(context).maybePop();
    }
  }

  void _confirmDelete(BuildContext context, LocalRecordingsProvider provider, LocalRecording rec) async {
    final t = context.omi;
    final navigator = Navigator.of(context);
    final confirmed = await OmiConfirmDialog.show(
      context,
      title: context.l10n.deleteRecording,
      message: context.l10n.deleteRecordingConfirmation,
      confirmLabel: context.l10n.delete,
      confirmColor: t.error,
    );
    if (confirmed == true) {
      navigator.pop();
      provider.delete(rec);
    }
  }

  void _showFileDetailsDialog(BuildContext context, LocalRecording rec) {
    final t = context.omi;
    final theme = Theme.of(context);
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: t.bgSecondary,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(t.cardRadius)),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _detailRow(context.l10n.dateTimeLabel, dateTimeFormat('MMM dd, yyyy h:mm:ss a', rec.startedAt)),
              _detailRow(context.l10n.durationLabel, secondsToHumanReadable(rec.seconds, context)),
              _detailRow(context.l10n.audioFormatLabel, rec.codec.toFormattedString()),
              _detailRow(context.l10n.estimatedSizeLabel, _formatBytes(rec.sizeBytes)),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(context.l10n.close, style: theme.textTheme.labelMedium?.copyWith(color: t.textPrimary)),
          ),
        ],
      ),
    );
  }

  Widget _detailRow(String label, String value) {
    final t = context.omi;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: Theme.of(context).textTheme.labelMedium!.copyWith(color: t.textSecondary)),
          const SizedBox(height: 2),
          Text(value, style: Theme.of(context).textTheme.bodyMedium),
        ],
      ),
    );
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }
}
