import 'package:flutter/material.dart';

import 'package:provider/provider.dart';

import 'package:omi/backend/schema/memory.dart';
import 'package:omi/providers/memories_provider.dart';
import 'package:omi/utils/l10n_extensions.dart';
import 'package:omi/utils/theme/omi_tokens.dart';

class MemoryManagementSheet extends StatelessWidget {
  final MemoriesProvider provider;

  const MemoryManagementSheet({super.key, required this.provider});

  @override
  Widget build(BuildContext context) {
    final t = context.omi;
    return Consumer<MemoriesProvider>(
      builder: (context, provider, child) {
        return Container(
          decoration: BoxDecoration(
            color: t.bgSecondary,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          ),
          child: SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _buildHeader(context),
                Divider(height: 1, color: t.divider),
                _buildFilterSection(context),
                Divider(height: 1, color: t.divider),
                _buildMemoryCount(context),
                _buildActionButtons(context),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildHeader(BuildContext context) {
    final t = context.omi;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 16, 16),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(context.l10n.memoryManagement,
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500, color: t.textPrimary)),
          IconButton(
            icon: Icon(Icons.close, color: t.textPrimary.withValues(alpha: 0.7)),
            onPressed: () => Navigator.pop(context),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
          ),
        ],
      ),
    );
  }

  Widget _buildFilterSection(BuildContext context) {
    final t = context.omi;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 16, 8),
          child: Text(context.l10n.filterMemories,
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: t.textPrimary)),
        ),
        _buildCategoryFilterOption(context, context.l10n.filterAll, null),
        _buildCategoryFilterOption(context, context.l10n.filterSystem, MemoryCategory.system),
        _buildCategoryFilterOption(context, context.l10n.filterInteresting, MemoryCategory.interesting),
        _buildCategoryFilterOption(context, context.l10n.filterManual, MemoryCategory.manual),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
          child: Divider(height: 1, color: t.divider),
        ),
        _buildFilterOption(
          context,
          context.l10n.memoryThisDevice,
          isSelected: provider.filterThisDeviceOnly,
          onTap: () => provider.setFilterThisDeviceOnly(!provider.filterThisDeviceOnly),
        ),
        const SizedBox(height: 16),
      ],
    );
  }

  Widget _buildCategoryFilterOption(BuildContext context, String label, MemoryCategory? category) {
    // If category is null, it represents "All"
    // For "All", it is selected if the set is empty.
    final bool isSelected;
    if (category == null) {
      isSelected = provider.selectedCategories.isEmpty;
    } else {
      isSelected = provider.selectedCategories.contains(category);
    }

    return _buildFilterOption(
      context,
      label,
      isSelected: isSelected,
      onTap: () {
        if (category == null) {
          provider.clearCategoryFilter();
        } else {
          provider.toggleCategoryFilter(category);
        }
        // Do NOT pop here to allow multiple selections
      },
    );
  }

  Widget _buildFilterOption(
    BuildContext context,
    String label, {
    required bool isSelected,
    required VoidCallback onTap,
  }) {
    final t = context.omi;
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        child: Row(
          children: [
            Text(
              label,
              style: TextStyle(
                color: isSelected ? t.accent : t.textPrimary,
                fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                fontSize: 16,
              ),
            ),
            const Spacer(),
            if (isSelected) Icon(Icons.check, color: t.accent, size: 20),
          ],
        ),
      ),
    );
  }

  Widget _buildMemoryCount(BuildContext context) {
    final t = context.omi;
    final totalMemories = provider.memories.length;
    final publicMemories = provider.memories.where((m) => !m.deleted && m.visibility.name == 'public').length;
    final privateMemories = provider.memories.where((m) => !m.deleted && m.visibility.name == 'private').length;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(context.l10n.totalMemoriesCount(totalMemories),
              style: TextStyle(fontSize: 15, height: 1.4, color: t.textPrimary)),
          const SizedBox(height: 8),
          _buildMemoryCountRow(context, Icons.public, context.l10n.publicMemories, publicMemories),
          const SizedBox(height: 4),
          _buildMemoryCountRow(context, Icons.lock_outline, context.l10n.privateMemories, privateMemories),
        ],
      ),
    );
  }

  Widget _buildMemoryCountRow(BuildContext context, IconData icon, String label, int count) {
    final t = context.omi;
    return Row(
      children: [
        Icon(icon, size: 16, color: t.textPrimary.withValues(alpha: 0.6)),
        const SizedBox(width: 8),
        Text(label, style: TextStyle(fontSize: 14, color: t.textSecondary)),
        const Spacer(),
        Text(count.toString(),
            style: TextStyle(fontSize: 14, color: t.textSecondary).copyWith(fontWeight: FontWeight.w600)),
      ],
    );
  }

  Widget _buildActionButtons(BuildContext context) {
    final t = context.omi;
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildActionButton(
            context,
            context.l10n.makeAllPrivate,
            Icons.lock_outline,
            t.rowFillHover,
            () => _makeAllMemoriesPrivate(context),
          ),
          const SizedBox(height: 12),
          _buildActionButton(
            context,
            context.l10n.makeAllPublic,
            Icons.public,
            t.rowFillHover,
            () => _makeAllMemoriesPublic(context),
          ),
          const SizedBox(height: 24),
          Divider(height: 1, color: t.divider),
          const SizedBox(height: 24),
          _buildActionButton(
            context,
            context.l10n.deleteAllMemories,
            Icons.delete_outline,
            t.error.withValues(alpha: 0.1),
            () => _confirmDeleteAllMemories(context),
            textColor: t.error,
            iconColor: t.error,
          ),
          const SizedBox(height: 12),
        ],
      ),
    );
  }

  Widget _buildActionButton(
    BuildContext context,
    String text,
    IconData icon,
    Color backgroundColor,
    VoidCallback onPressed, {
    Color? textColor,
    Color? iconColor,
  }) {
    final t = context.omi;
    textColor ??= t.textPrimary;
    iconColor ??= t.textPrimary;
    return ElevatedButton(
      onPressed: onPressed,
      style: ElevatedButton.styleFrom(
        backgroundColor: backgroundColor,
        foregroundColor: textColor,
        elevation: 0,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
      child: Row(
        children: [
          Icon(icon, size: 20, color: iconColor),
          const SizedBox(width: 12),
          Text(
            text,
            style: TextStyle(color: textColor, fontSize: 15, fontWeight: FontWeight.w500),
          ),
        ],
      ),
    );
  }

  void _makeAllMemoriesPrivate(BuildContext context) async {
    final t = context.omi;
    Navigator.pop(context);
    await provider.updateAllMemoriesVisibility(true);

    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(context.l10n.allMemoriesPrivateResult),
          backgroundColor: t.bgTertiary,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  void _makeAllMemoriesPublic(BuildContext context) async {
    final t = context.omi;
    Navigator.pop(context);
    await provider.updateAllMemoriesVisibility(false);

    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(context.l10n.allMemoriesPublicResult),
          backgroundColor: t.bgTertiary,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  void _confirmDeleteAllMemories(BuildContext context) {
    final t = context.omi;
    if (provider.memories.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(context.l10n.noMemoriesToDelete),
          backgroundColor: t.bgTertiary,
          duration: const Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        ),
      );
      Navigator.pop(context);
      return;
    }

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: t.bgSecondary,
        title: Text(context.l10n.clearMemoryTitle, style: TextStyle(color: t.textPrimary)),
        content: Text(context.l10n.clearMemoryMessage, style: TextStyle(color: t.textSecondary)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(context.l10n.cancel, style: TextStyle(color: t.textSecondary)),
          ),
          TextButton(
            onPressed: () {
              provider.deleteAllMemories();
              Navigator.pop(context); // Close dialog
              Navigator.pop(context); // Close sheet
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(context.l10n.memoryClearedSuccess),
                  backgroundColor: t.bgTertiary,
                  duration: const Duration(seconds: 2),
                  behavior: SnackBarBehavior.floating,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                ),
              );
            },
            child: Text(context.l10n.clearMemoryButton, style: TextStyle(color: t.error)),
          ),
        ],
      ),
    );
  }
}
