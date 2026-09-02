import 'package:flutter/material.dart';

import 'package:omi/backend/schema/memory.dart';
import 'package:omi/providers/memories_provider.dart';
import 'package:omi/utils/l10n_extensions.dart';
import 'package:omi/utils/logger.dart';
import 'package:omi/widgets/extensions/string.dart';
import 'delete_confirmation.dart';
import 'package:omi/utils/theme/omi_tokens.dart';

class MemoryEditSheet extends StatefulWidget {
  final Memory memory;
  final MemoriesProvider provider;
  final Function(BuildContext, Memory, MemoriesProvider)? onDelete;

  const MemoryEditSheet({super.key, required this.memory, required this.provider, this.onDelete});

  @override
  State<MemoryEditSheet> createState() => _MemoryEditSheetState();
}

class _MemoryEditSheetState extends State<MemoryEditSheet> {
  late final TextEditingController contentController;
  bool _isSaving = false;
  bool _saveFailed = false;
  late bool _isBaseline;

  @override
  void initState() {
    super.initState();
    _isBaseline = widget.memory.isBaseline;
    contentController = TextEditingController(text: widget.memory.content.decodeString);
    contentController.selection = TextSelection.fromPosition(TextPosition(offset: contentController.text.length));
  }

  @override
  void dispose() {
    contentController.dispose();
    super.dispose();
  }

  Future<void> _toggleBaseline() async {
    final newState = !_isBaseline;
    setState(() {
      _isBaseline = newState;
    });

    final success = await widget.provider.toggleMemoryBaseline(widget.memory, newState);

    if (!success && mounted) {
      setState(() {
        _isBaseline = !newState;
      });
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Failed to update baseline status')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.omi;
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
                Row(
                  mainAxisSize: MainAxisSize.min,
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
                          Icon(Icons.label_outline, size: 14, color: t.textPrimary),
                          const SizedBox(width: 4),
                          Text(
                            widget.memory.category.toString().split('.').last,
                            style: TextStyle(color: t.textPrimary, fontSize: 14),
                          ),
                        ],
                      ),
                    ),
                    if (_isBaseline) ...[
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(
                          color: t.accent.withValues(alpha: 0.2),
                          borderRadius: BorderRadius.circular(t.cardRadius),
                          border: Border.all(color: t.accent.withValues(alpha: 0.5), width: 1),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.flag, size: 14, color: t.accent),
                            const SizedBox(width: 4),
                            Text(
                              context.l10n.baselineMemory,
                              style: TextStyle(color: t.accent, fontSize: 14, fontWeight: FontWeight.w500),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
                Row(
                  children: [
                    IconButton(
                      icon: Icon(
                        _isBaseline ? Icons.flag : Icons.flag_outlined,
                        color: _isBaseline ? t.accent : t.textPrimary,
                      ),
                      onPressed: _toggleBaseline,
                      tooltip: _isBaseline ? context.l10n.unpinAsBaseline : context.l10n.pinAsBaseline,
                    ),
                    IconButton(
                      icon: Icon(Icons.delete_outline, color: t.error),
                      onPressed: () => _showDeleteConfirmation(context),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 12),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 250),
              child: SingleChildScrollView(
                child: TextField(
                  controller: contentController,
                  autofocus: true,
                  maxLines: null,
                  minLines: 3,
                  textInputAction: TextInputAction.newline,
                  keyboardType: TextInputType.multiline,
                  style: TextStyle(color: t.textPrimary, fontSize: 16, height: 1.4),
                  decoration: const InputDecoration(
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
                'Failed to save. Please check your connection.',
                style: TextStyle(color: t.error, fontSize: 13),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
            ],
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
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
                        _saveFailed ? 'Retry' : 'Save Memory',
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

    bool success;

    try {
      success = await widget.provider.editMemory(widget.memory, contentController.text, widget.memory.category);
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
    final shouldDelete = await DeleteConfirmation.show(context);
    if (shouldDelete) {
      widget.provider.deleteMemory(widget.memory);
      if (context.mounted) {
        Navigator.pop(context); // Close edit sheet
        if (widget.onDelete != null) {
          widget.onDelete!(context, widget.memory, widget.provider);
        }
      }
    }
  }
}
