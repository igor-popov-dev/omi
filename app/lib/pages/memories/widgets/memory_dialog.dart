import 'package:omi/utils/platform/platform_manager.dart';
import 'package:flutter/material.dart';

import 'package:omi/backend/schema/memory.dart';
import 'package:omi/providers/memories_provider.dart';
import 'package:omi/utils/l10n_extensions.dart';
import 'package:omi/utils/logger.dart';
import 'delete_confirmation.dart';
import 'package:omi/utils/theme/omi_tokens.dart';

class MemoryDialog extends StatefulWidget {
  final MemoriesProvider provider;
  final Memory? memory;

  const MemoryDialog({super.key, required this.provider, this.memory});

  @override
  State<MemoryDialog> createState() => _MemoryDialogState();
}

class _MemoryDialogState extends State<MemoryDialog> {
  late TextEditingController contentController;
  bool _isSaving = false;
  bool _saveFailed = false;

  @override
  void initState() {
    super.initState();
    contentController = TextEditingController(text: widget.memory?.content ?? '');
    contentController.selection = TextSelection.fromPosition(TextPosition(offset: contentController.text.length));
  }

  @override
  void dispose() {
    contentController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.omi;
    final isEditing = widget.memory != null;

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Container(
        decoration: BoxDecoration(
          color: t.bgSecondary,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: t.rowFillHover,
                    borderRadius: BorderRadius.circular(t.cardRadius),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(isEditing ? Icons.label_outline : Icons.add_circle_outline, size: 14, color: t.textPrimary),
                      const SizedBox(width: 4),
                      Text(
                        isEditing
                            ? (widget.memory!.category == MemoryCategory.manual
                                ? context.l10n.filterManual
                                : widget.memory!.category == MemoryCategory.interesting
                                    ? context.l10n.filterInteresting
                                    : context.l10n.filterSystem)
                            : context.l10n.newMemory,
                        style: TextStyle(color: t.textPrimary, fontSize: 14),
                      ),
                    ],
                  ),
                ),
                if (isEditing)
                  IconButton(
                    icon: Icon(Icons.delete_outline, color: t.error),
                    onPressed: () => _showDeleteConfirmation(context),
                  )
                else
                  IconButton(
                    icon: Icon(Icons.close, color: t.textSecondary),
                    onPressed: () => Navigator.pop(context),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 250),
              child: SingleChildScrollView(
                child: TextField(
                  key: const ValueKey('memory_content_field'),
                  controller: contentController,
                  autofocus: true,
                  maxLines: null,
                  minLines: 3,
                  textInputAction: TextInputAction.newline,
                  keyboardType: TextInputType.multiline,
                  style: TextStyle(color: t.textPrimary, fontSize: 16, height: 1.4),
                  decoration: InputDecoration(
                    hintText: isEditing ? null : context.l10n.memoryContentHint,
                    hintStyle: TextStyle(color: t.textSecondary),
                    border: InputBorder.none,
                    contentPadding: EdgeInsets.zero,
                    isDense: true,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 24),
            if (_saveFailed) ...[
              Text(
                context.l10n.failedToSaveMemory,
                style: TextStyle(color: t.error, fontSize: 13),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
            ],
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                key: const ValueKey('memory_save_button'),
                onPressed: _isSaving ? null : _handleSave,
                style: ElevatedButton.styleFrom(
                  backgroundColor: _saveFailed ? t.warning : t.accent,
                  foregroundColor: t.textPrimary,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(t.rowRadius)),
                  disabledBackgroundColor: t.accent.withValues(alpha: 0.5),
                  disabledForegroundColor: t.textPrimary.withValues(alpha: 0.7),
                ),
                child: _isSaving
                    ? SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          valueColor: AlwaysStoppedAnimation<Color>(t.textPrimary),
                        ),
                      )
                    : Text(
                        _saveFailed ? context.l10n.retry : context.l10n.saveMemory,
                        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _handleSave() async {
    if (contentController.text.trim().isEmpty) return;

    setState(() {
      _isSaving = true;
      _saveFailed = false;
    });

    final isEditing = widget.memory != null;
    bool success;

    try {
      if (isEditing) {
        success = await widget.provider.editMemory(widget.memory!, contentController.text);
        if (success) {
          PlatformManager.instance.analytics.memoriesPageEditedMemory();
        }
      } else {
        success = await widget.provider.createMemory(
          contentController.text,
          MemoryVisibility.private,
          MemoryCategory.manual,
        );
        if (success) {
          PlatformManager.instance.analytics.memoriesPageCreatedMemory(MemoryCategory.manual);
        }
      }
    } catch (e) {
      success = false;
      Logger.debug('Error saving memory: $e');
    }

    if (!mounted) return;

    setState(() {
      _isSaving = false;
      _saveFailed = !success;
    });

    if (success) {
      Navigator.pop(context);
    }
  }

  Future<void> _showDeleteConfirmation(BuildContext context) async {
    if (widget.memory == null) return;

    final shouldDelete = await DeleteConfirmation.show(context);
    if (shouldDelete) {
      widget.provider.deleteMemory(widget.memory!);
      if (context.mounted) {
        Navigator.pop(context);
      }
    }
  }
}

// Helper function to show the memory dialog
Future<void> showMemoryDialog(BuildContext context, MemoriesProvider provider, {Memory? memory}) async {
  return showModalBottomSheet(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (context) => MemoryDialog(provider: provider, memory: memory),
  );
}
