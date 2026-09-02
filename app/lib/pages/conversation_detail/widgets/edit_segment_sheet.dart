import 'package:flutter/material.dart';

import 'package:omi/backend/schema/transcript_segment.dart';
import 'package:omi/utils/l10n_extensions.dart';
import 'package:omi/utils/theme/omi_tokens.dart';

void showEditSegmentBottomSheet(
  BuildContext context, {
  required TranscriptSegment segment,
  required String speakerName,
  required Function(String newText) onSave,
  VoidCallback? onDismissed,
}) {
  final t = context.omi;
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: t.bgSecondary,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(t.cardRadius))),
    builder: (context) => _EditSegmentSheet(segment: segment, speakerName: speakerName, onSave: onSave),
  ).whenComplete(() => onDismissed?.call());
}

class _EditSegmentSheet extends StatefulWidget {
  final TranscriptSegment segment;
  final String speakerName;
  final Function(String newText) onSave;

  const _EditSegmentSheet({required this.segment, required this.speakerName, required this.onSave});

  @override
  State<_EditSegmentSheet> createState() => _EditSegmentSheetState();
}

class _EditSegmentSheetState extends State<_EditSegmentSheet> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.segment.text);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _save() {
    final newText = _controller.text.trim();
    if (newText.isNotEmpty && newText != widget.segment.text) {
      widget.onSave(newText);
    }
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.omi;
    return Padding(
      padding: MediaQuery.of(context).viewInsets,
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(color: t.textTertiary, borderRadius: BorderRadius.circular(2)),
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.speakerName,
                      style: TextStyle(color: t.textPrimary, fontSize: 16, fontWeight: FontWeight.w600),
                    ),
                  ),
                  if (widget.segment.start > 0)
                    Text(
                      widget.segment.getTimestampString(),
                      style: TextStyle(color: t.textSecondary, fontSize: 12),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _controller,
                autofocus: true,
                maxLines: null,
                minLines: 3,
                style: TextStyle(color: t.textPrimary, fontSize: 15, height: 1.5),
                decoration: InputDecoration(
                  filled: true,
                  fillColor: t.textTertiary,
                  border:
                      OutlineInputBorder(borderRadius: BorderRadius.circular(t.rowRadius), borderSide: BorderSide.none),
                  contentPadding: const EdgeInsets.all(14),
                ),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _save,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: t.textPrimary,
                    foregroundColor: t.bgPrimary,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(t.rowRadius)),
                  ),
                  child: Text(context.l10n.save, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
