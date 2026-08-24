import 'package:omi/utils/platform/platform_manager.dart';
import 'package:flutter/material.dart';

import 'package:provider/provider.dart';

import 'package:omi/backend/schema/memory.dart';
import 'package:omi/providers/memories_provider.dart';
import 'package:omi/utils/l10n_extensions.dart';
import 'widgets/memory_dialog.dart';
import 'widgets/memory_edit_sheet.dart';
import 'widgets/memory_item.dart';
import 'package:omi/utils/theme/omi_tokens.dart';

class CategoryMemoriesPage extends StatelessWidget {
  final MemoryCategory category;

  const CategoryMemoriesPage({super.key, required this.category});

  @override
  Widget build(BuildContext context) {
    final t = context.omi;
    return Consumer<MemoriesProvider>(
      builder: (context, provider, child) {
        return Scaffold(
          backgroundColor: context.omi.bgPrimary,
          appBar: AppBar(
            backgroundColor: context.omi.bgPrimary,
            title: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  category.toString().split('.').last[0].toUpperCase() +
                      category.toString().split('.').last.substring(1),
                ),
                Text(
                  context.l10n.memoriesCount(provider.filteredMemories.length),
                  style: TextStyle(fontSize: 14, color: t.textSecondary, fontWeight: FontWeight.normal),
                ),
              ],
            ),
            actions: [
              IconButton(
                icon: const Icon(Icons.add),
                onPressed: () {
                  showMemoryDialog(context, provider);
                  PlatformManager.instance.analytics.memoriesPageCreateMemoryBtn();
                },
              ),
            ],
          ),
          body: provider.filteredMemories.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.note_add, size: 48, color: t.textTertiary),
                      const SizedBox(height: 16),
                      Text(
                        context.l10n.noMemoriesInCategory,
                        style: TextStyle(color: t.textSecondary, fontSize: 18),
                      ),
                      const SizedBox(height: 8),
                      TextButton(
                        onPressed: () => showMemoryDialog(context, provider),
                        child: Text(context.l10n.addYourFirstMemory),
                      ),
                    ],
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: provider.filteredMemories.length,
                  itemBuilder: (context, index) {
                    final memory = provider.filteredMemories[index];
                    return MemoryItem(memory: memory, provider: provider, onTap: _showQuickEditSheet);
                  },
                ),
        );
      },
    );
  }

  void _showQuickEditSheet(BuildContext context, Memory memory, MemoriesProvider provider) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (context) => MemoryEditSheet(memory: memory, provider: provider, onDelete: (_, __, ___) {}),
    );
  }
}
