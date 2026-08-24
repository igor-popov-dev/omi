import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:omi/models/local_recording.dart';
import 'package:omi/pages/conversations/recording_detail/recording_detail_sheet.dart';
import 'package:omi/providers/local_recordings_provider.dart';
import 'package:omi/utils/l10n_extensions.dart';
import 'package:omi/utils/other/temp.dart';
import 'package:omi/utils/theme/omi_tokens.dart';

/// A row in the conversations list for a batch/offline-mode recording captured
/// locally. Unlike a conversation it has no title/icon yet — it shows the
/// recording's time + duration, its state, and an inline play/pause button that
/// decodes and plays the local audio on device. Tapping opens a floating
/// playback sheet (transcribe, share, delete).
class RecordingListItem extends StatelessWidget {
  final LocalRecording recording;

  const RecordingListItem({super.key, required this.recording});

  String _formatDuration(int seconds) {
    final m = seconds ~/ 60;
    final s = seconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  (Color, String) _status(BuildContext context) {
    final t = context.omi;
    final l = context.l10n;
    switch (recording.state) {
      case LocalRecordingState.uploading:
        return (t.textSecondary, l.syncStatusBackingUp);
      case LocalRecordingState.processing:
        return (t.textSecondary, l.syncStatusUploaded);
      case LocalRecordingState.failed:
        return (t.error, l.failedStatus);
      case LocalRecordingState.pending:
        return (t.textSecondary, l.privateAndSecureOnDevice);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.omi;
    return Consumer<LocalRecordingsProvider>(
      builder: (context, provider, _) {
        final (statusColor, statusLabel) = _status(context);
        final isPlaying = provider.isPlaying(recording);
        final timeStr = dateTimeFormat(
          'h:mm a',
          recording.startedAt,
          locale: Localizations.localeOf(context).languageCode,
        );

        return Padding(
          padding: const EdgeInsets.only(top: 12, left: 16, right: 16),
          child: Container(
            width: double.maxFinite,
            decoration: BoxDecoration(color: t.bgSecondary, borderRadius: BorderRadius.circular(24.0)),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(24.0),
              child: Dismissible(
                key: ValueKey('rec_${recording.id}'),
                direction: recording.isBusy ? DismissDirection.none : DismissDirection.endToStart,
                background: Container(
                  alignment: Alignment.centerRight,
                  color: t.error,
                  padding: const EdgeInsets.only(right: 20),
                  child: Icon(Icons.delete, color: t.textPrimary),
                ),
                onDismissed: (_) => provider.delete(recording),
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => showRecordingDetailSheet(context, recording),
                  child: Padding(
                    padding: const EdgeInsetsDirectional.symmetric(horizontal: 16, vertical: 18),
                    child: Row(
                      children: [
                        Container(
                          width: 40,
                          height: 40,
                          decoration: BoxDecoration(
                            color: t.bgTertiary,
                            borderRadius: BorderRadius.circular(t.rowRadius),
                          ),
                          child: Icon(Icons.graphic_eq, color: t.textSecondary, size: 20),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '$timeStr · ${_formatDuration(recording.seconds)}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(color: t.textPrimary, fontSize: 16, fontWeight: FontWeight.w600),
                              ),
                              const SizedBox(height: 3),
                              Text(
                                statusLabel,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(color: statusColor, fontSize: 12),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 10),
                        GestureDetector(
                          onTap: () => provider.togglePlayback(recording),
                          child: Container(
                            width: 44,
                            height: 44,
                            decoration: BoxDecoration(color: t.bgTertiary, shape: BoxShape.circle),
                            child: Icon(isPlaying ? Icons.pause : Icons.play_arrow, color: t.textPrimary, size: 24),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
