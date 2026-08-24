import 'package:omi/utils/platform/platform_manager.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:provider/provider.dart';
import 'package:omi/widgets/shimmer_with_timeout.dart';

import 'package:omi/backend/schema/memory.dart';
import 'package:omi/providers/home_provider.dart';
import 'package:omi/providers/memories_provider.dart';
import 'package:omi/utils/l10n_extensions.dart';
import 'package:omi/widgets/extensions/functions.dart';
import 'widgets/memory_dialog.dart';
import 'widgets/memory_edit_sheet.dart';
import 'widgets/memory_graph_page.dart';
import 'widgets/memory_item.dart';
import 'widgets/memory_management_sheet.dart';
import 'package:omi/utils/theme/omi_tokens.dart';

class MemoriesPage extends StatefulWidget {
  const MemoriesPage({super.key});

  @override
  State<MemoriesPage> createState() => MemoriesPageState();
}

class MemoriesPageState extends State<MemoriesPage> with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  final TextEditingController _searchController = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  OverlayEntry? _deleteNotificationOverlay;

  bool _isInitialLoad = true;

  @override
  void dispose() {
    _searchController.dispose();
    _scrollController.dispose();
    _removeDeleteNotification();
    super.dispose();
  }

  // Remove the delete notification overlay if it exists
  void _removeDeleteNotification() {
    _deleteNotificationOverlay?.remove();
    _deleteNotificationOverlay = null;
  }

  void showDeleteNotification(String memoryContent, Memory? memory) {
    final t = context.omi;
    _removeDeleteNotification();

    final provider = Provider.of<MemoriesProvider>(context, listen: false);

    _deleteNotificationOverlay = OverlayEntry(
      builder: (_) => Positioned(
        bottom: 20,
        left: 0,
        right: 0,
        child: Center(
          child: Material(
            color: Colors.transparent,
            child: Container(
              width: MediaQuery.of(context).size.width * 0.9,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: Colors.black87,
                borderRadius: BorderRadius.circular(8),
                boxShadow: [
                  BoxShadow(color: t.bgPrimary.withValues(alpha: 0.2), blurRadius: 4, offset: const Offset(0, 2)),
                ],
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(context.l10n.memoryDeleted, style: TextStyle(color: t.textPrimary, fontSize: 14)),
                  ),
                  TextButton(
                    onPressed: () async {
                      final success = await provider.restoreLastDeletedMemory();
                      if (success) {
                        _removeDeleteNotification();
                      }
                    },
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      minimumSize: const Size(0, 36),
                    ),
                    child: Text(
                      context.l10n.undo,
                      style: TextStyle(color: t.accent, fontWeight: FontWeight.w500),
                    ),
                  ),
                  IconButton(
                    onPressed: () {
                      provider.confirmPendingDeletion();
                      _removeDeleteNotification();
                    },
                    icon: Icon(Icons.close, color: t.textPrimary.withValues(alpha: 0.7), size: 20),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                    splashRadius: 20,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );

    Overlay.of(context).insert(_deleteNotificationOverlay!);

    Future.delayed(const Duration(seconds: 4), () {
      if (!mounted) return;
      _removeDeleteNotification();
    });
  }

  @override
  void initState() {
    super.initState();
    // Set default filter to all

    (() async {
      final provider = context.read<MemoriesProvider>();
      await provider.init();
      if (!mounted) return;

      if (!mounted) return;

      setState(() {
        _isInitialLoad = false;
      });
    }).withPostFrameCallback();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.omi;
    super.build(context);
    return Consumer<MemoriesProvider>(
      builder: (context, provider, _) {
        return PopScope(
          canPop: true,
          child: Scaffold(
            backgroundColor: context.omi.bgPrimary,
            appBar: AppBar(
              backgroundColor: Theme.of(context).colorScheme.surface,
              automaticallyImplyLeading: true,
              title: Text(
                context.l10n.memories,
                style: TextStyle(color: t.textPrimary, fontSize: 18, fontWeight: FontWeight.w600),
              ),
              elevation: 0,
              iconTheme: IconThemeData(color: t.textPrimary),
            ),
            body: Stack(
              children: [
                RefreshIndicator(
                  onRefresh: () async {
                    HapticFeedback.mediumImpact();
                    await provider.init();
                  },
                  color: t.accent,
                  backgroundColor: t.textPrimary,
                  child: provider.loading && _isInitialLoad
                      ? CustomScrollView(
                          physics: const AlwaysScrollableScrollPhysics(),
                          slivers: [
                            SliverToBoxAdapter(
                              child: Padding(
                                padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
                                child: Row(
                                  children: [
                                    Expanded(
                                      child: SizedBox(
                                        height: 44,
                                        child: SearchBar(
                                          hintText: context.l10n.searchMemories,
                                          leading: Padding(
                                            padding: const EdgeInsets.only(left: 6.0),
                                            child: FaIcon(
                                              FontAwesomeIcons.magnifyingGlass,
                                              color: t.textPrimary.withValues(alpha: 0.7),
                                              size: 14,
                                            ),
                                          ),
                                          backgroundColor: WidgetStateProperty.all(t.bgSecondary),
                                          elevation: WidgetStateProperty.all(0),
                                          padding: WidgetStateProperty.all(
                                            const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                                          ),
                                          hintStyle: WidgetStateProperty.all(
                                            TextStyle(color: t.textTertiary, fontSize: 14),
                                          ),
                                          textStyle: WidgetStateProperty.all(
                                            TextStyle(color: t.textPrimary, fontSize: 14),
                                          ),
                                          shape: WidgetStateProperty.all(
                                            RoundedRectangleBorder(
                                              borderRadius: BorderRadius.circular(t.rowRadius),
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    SizedBox(width: 44, height: 44, child: _buildShimmerButton()),
                                    const SizedBox(width: 8),
                                    SizedBox(width: 44, height: 44, child: _buildShimmerButton()),
                                  ],
                                ),
                              ),
                            ),
                            SliverFillRemaining(child: _buildShimmerMemoryList()),
                          ],
                        )
                      : CustomScrollView(
                          controller: _scrollController,
                          physics: const AlwaysScrollableScrollPhysics(),
                          slivers: [
                            SliverToBoxAdapter(
                              child: Padding(
                                padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
                                child: Row(
                                  children: [
                                    Consumer<HomeProvider>(
                                      builder: (context, home, child) {
                                        return Expanded(
                                          child: SizedBox(
                                            height: 44,
                                            child: SearchBar(
                                              hintText: context.l10n.searchMemories,
                                              leading: Padding(
                                                padding: const EdgeInsets.only(left: 6.0),
                                                child: FaIcon(
                                                  FontAwesomeIcons.magnifyingGlass,
                                                  color: t.textPrimary.withValues(alpha: 0.7),
                                                  size: 14,
                                                ),
                                              ),
                                              backgroundColor: WidgetStateProperty.all(t.bgSecondary),
                                              elevation: WidgetStateProperty.all(0),
                                              padding: WidgetStateProperty.all(
                                                const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                                              ),
                                              focusNode: home.memoriesSearchFieldFocusNode,
                                              controller: _searchController,
                                              trailing: provider.searchQuery.isNotEmpty
                                                  ? [
                                                      IconButton(
                                                        icon: Icon(Icons.close,
                                                            color: t.textPrimary.withValues(alpha: 0.7), size: 16),
                                                        padding: EdgeInsets.zero,
                                                        constraints: const BoxConstraints(minHeight: 36, minWidth: 36),
                                                        onPressed: () {
                                                          _searchController.clear();
                                                          provider.setSearchQuery('');
                                                          PlatformManager.instance.analytics.memorySearchCleared(
                                                            provider.memories.length,
                                                          );
                                                        },
                                                      ),
                                                    ]
                                                  : null,
                                              hintStyle: WidgetStateProperty.all(
                                                TextStyle(color: t.textTertiary, fontSize: 14),
                                              ),
                                              textStyle: WidgetStateProperty.all(
                                                TextStyle(color: t.textPrimary, fontSize: 14),
                                              ),
                                              shape: WidgetStateProperty.all(
                                                RoundedRectangleBorder(
                                                  borderRadius: BorderRadius.circular(t.rowRadius),
                                                ),
                                              ),
                                              onChanged: (value) => provider.setSearchQuery(value),
                                              onSubmitted: (value) {
                                                if (value.isNotEmpty) {
                                                  PlatformManager.instance.analytics.memorySearched(
                                                    value,
                                                    provider.filteredMemories.length,
                                                  );
                                                }
                                              },
                                            ),
                                          ),
                                        );
                                      },
                                    ),
                                    const SizedBox(width: 8),
                                    SizedBox(
                                      width: 44,
                                      height: 44,
                                      child: ElevatedButton(
                                        onPressed: () {
                                          Navigator.of(
                                            context,
                                          ).push(MaterialPageRoute(builder: (context) => const MemoryGraphPage()));
                                        },
                                        style: ElevatedButton.styleFrom(
                                          backgroundColor: t.bgSecondary,
                                          foregroundColor: t.textPrimary,
                                          padding: EdgeInsets.zero,
                                          shape:
                                              RoundedRectangleBorder(borderRadius: BorderRadius.circular(t.rowRadius)),
                                        ),
                                        child: const FaIcon(FontAwesomeIcons.brain, size: 16),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    SizedBox(
                                      width: 44,
                                      height: 44,
                                      child: ElevatedButton(
                                        onPressed: () {
                                          _showMemoryManagementSheet(context, provider);
                                        },
                                        style: ElevatedButton.styleFrom(
                                          backgroundColor: t.bgSecondary,
                                          foregroundColor: t.textPrimary,
                                          padding: EdgeInsets.zero,
                                          shape:
                                              RoundedRectangleBorder(borderRadius: BorderRadius.circular(t.rowRadius)),
                                        ),
                                        child: const FaIcon(FontAwesomeIcons.sliders, size: 16),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            if (provider.filteredMemories.isEmpty)
                              SliverFillRemaining(
                                child: Center(
                                  child: Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      Icon(Icons.note_add, size: 48, color: t.textTertiary),
                                      const SizedBox(height: 16),
                                      Text(
                                        provider.searchQuery.isEmpty && provider.selectedCategories.isEmpty
                                            ? context.l10n.noMemoriesYet
                                            : provider.selectedCategories.isNotEmpty
                                                ? provider.selectedCategories.contains(MemoryCategory.manual) &&
                                                        provider.selectedCategories.length == 1
                                                    ? context.l10n.noManualMemories
                                                    : context.l10n.noMemoriesInCategories
                                                : context.l10n.noMemoriesFound,
                                        style: TextStyle(color: t.textSecondary, fontSize: 18),
                                      ),
                                      if (provider.searchQuery.isEmpty && provider.selectedCategories.isEmpty) ...[
                                        const SizedBox(height: 8),
                                        TextButton(
                                          onPressed: () => showMemoryDialog(context, provider),
                                          child: Text(context.l10n.addFirstMemory),
                                        ),
                                      ],
                                    ],
                                  ),
                                ),
                              )
                            else
                              SliverPadding(
                                padding: const EdgeInsets.only(top: 8, left: 16, right: 16, bottom: 120),
                                sliver: SliverList(
                                  delegate: SliverChildBuilderDelegate((context, index) {
                                    final memory = provider.filteredMemories[index];
                                    return MemoryItem(
                                      memory: memory,
                                      provider: provider,
                                      onTap:
                                          (BuildContext context, Memory tappedMemory, MemoriesProvider tappedProvider) {
                                        PlatformManager.instance.analytics.memoryListItemClicked(tappedMemory);
                                        _showQuickEditSheet(context, tappedMemory, tappedProvider);
                                      },
                                      onDeleteNotification: showDeleteNotification,
                                    );
                                  }, childCount: provider.filteredMemories.length),
                                ),
                              ),
                          ],
                        ),
                ),
                Positioned(
                  right: 20,
                  bottom: 100,
                  child: FloatingActionButton(
                    heroTag: 'memories_fab',
                    onPressed: () {
                      showMemoryDialog(context, provider);
                      PlatformManager.instance.analytics.memoriesPageCreateMemoryBtn();
                    },
                    backgroundColor: t.accent,
                    tooltip: context.l10n.createMemoryTooltip,
                    child: Icon(Icons.add, color: t.textPrimary),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildShimmerButton() {
    final t = context.omi;
    return ShimmerWithTimeout(
      baseColor: t.bgSecondary,
      highlightColor: t.bgTertiary,
      child: Container(
        decoration: BoxDecoration(color: t.bgSecondary, borderRadius: BorderRadius.circular(t.rowRadius)),
      ),
    );
  }

  Widget _buildShimmerMemoryList() {
    final t = context.omi;
    return Padding(
      padding: const EdgeInsets.only(top: 8, left: 16, right: 16, bottom: 120),
      child: ListView.builder(
        itemCount: 8, // Show 8 shimmer items
        itemBuilder: (context, index) {
          return ShimmerWithTimeout(
            baseColor: t.bgSecondary,
            highlightColor: t.bgTertiary,
            child: Container(
              margin: const EdgeInsets.only(bottom: 12.0),
              height: 88, // Approximate height of a memory item
              decoration: BoxDecoration(
                color: t.bgSecondary,
                borderRadius: BorderRadius.circular(t.rowRadius),
              ),
            ),
          );
        },
      ),
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

  // ignore: unused_element
  void _showDeleteAllConfirmation(BuildContext context, MemoriesProvider provider) {
    final t = context.omi;
    if (provider.memories.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(context.l10n.noMemoriesToDelete), duration: const Duration(seconds: 2)));
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
            child: Text(
              MaterialLocalizations.of(context).cancelButtonLabel,
              style: TextStyle(color: t.textSecondary),
            ),
          ),
          TextButton(
            onPressed: () {
              provider.deleteAllMemories();
              Navigator.pop(context);
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text(context.l10n.memoryClearedSuccess), duration: const Duration(seconds: 2)),
              );
            },
            child: Text(context.l10n.clearMemoryButton, style: TextStyle(color: t.error)),
          ),
        ],
      ),
    );
  }

  void scrollToTop() {
    if (_scrollController.hasClients) {
      _scrollController.animateTo(0.0, duration: const Duration(milliseconds: 500), curve: Curves.easeOutCubic);
    }
  }

  void _showMemoryManagementSheet(BuildContext context, MemoriesProvider provider) {
    PlatformManager.instance.analytics.memoriesManagementSheetOpened();
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (context) => MemoryManagementSheet(provider: provider),
    );
  }
}

// ignore: unused_element
class _SliverSearchBarDelegate extends SliverPersistentHeaderDelegate {
  final double minHeight;
  final double maxHeight;
  final Widget child;

  _SliverSearchBarDelegate({required this.minHeight, required this.maxHeight, required this.child});

  @override
  double get minExtent => minHeight;

  @override
  double get maxExtent => maxHeight;

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlapsContent) {
    return SizedBox.expand(child: child);
  }

  @override
  bool shouldRebuild(_SliverSearchBarDelegate oldDelegate) {
    return maxHeight != oldDelegate.maxHeight || minHeight != oldDelegate.minHeight || child != oldDelegate.child;
  }
}
