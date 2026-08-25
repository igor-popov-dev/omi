import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:provider/provider.dart';

import 'package:omi/pages/settings/task_integrations_page.dart';
import 'package:omi/providers/action_items_provider.dart';
import 'package:omi/providers/task_integration_provider.dart';
import 'package:omi/utils/bottom_nav_metrics.dart';
import 'package:omi/utils/l10n_extensions.dart';
import 'package:omi/utils/theme/omi_tokens.dart';

/// Bottom-anchored selection action bar for the action items page.
/// Same visual language as `MergeActionBar` for the conversations page —
/// dark sheet with rounded top corners, slide-up animation, single primary
/// pill action.
///
/// Mounted at the home page's outer Stack so it paints above the bottom
/// nav bar (mirrors `MergeActionBar`). Selection state lives in
/// `ActionItemsProvider`. Bulk-delete is intentionally not part of the bar:
/// per-row swipe-left handles individual delete, and the section header's
/// clear-completed path covers bulk-delete of completed tasks.
class TaskSelectionActionBar extends StatefulWidget {
  const TaskSelectionActionBar({super.key});

  @override
  State<TaskSelectionActionBar> createState() => _TaskSelectionActionBarState();
}

class _TaskSelectionActionBarState extends State<TaskSelectionActionBar> with SingleTickerProviderStateMixin {
  late final AnimationController _animationController;
  late final Animation<Offset> _slideAnimation;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(vsync: this, duration: const Duration(milliseconds: 280));
    _slideAnimation = Tween<Offset>(
      begin: const Offset(0, 1),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _animationController, curve: Curves.easeOutCubic));
  }

  @override
  void dispose() {
    _animationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.omi;
    return Consumer<ActionItemsProvider>(
      builder: (context, provider, _) {
        final isActive = provider.isSelectionMode;
        final taskCount = provider.selectedCount;
        final canExport = taskCount > 0;

        if (isActive) {
          _animationController.forward();
        } else {
          _animationController.reverse();
        }

        return IgnorePointer(
          ignoring: !isActive,
          child: SlideTransition(
            position: _slideAnimation,
            child: Container(
              decoration: BoxDecoration(
                color: t.bgSecondary,
                borderRadius: BorderRadius.vertical(top: Radius.circular(t.cardRadius)),
                boxShadow: [
                  BoxShadow(color: t.bgPrimary.withValues(alpha: 0.5), blurRadius: 20, offset: const Offset(0, -4)),
                ],
              ),
              child: SafeArea(
                top: false,
                child: Padding(
                  padding: EdgeInsets.fromLTRB(
                    20,
                    20,
                    20,
                    BottomNavMetrics.actionSheetBottomPadding(context, classic: 20),
                  ),
                  child: Row(
                    children: [
                      // Cancel
                      GestureDetector(
                        onTap: () {
                          HapticFeedback.lightImpact();
                          provider.endSelection();
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                          child: Text(
                            context.l10n.cancel,
                            style: TextStyle(color: t.textSecondary, fontSize: 17, fontWeight: FontWeight.w500),
                          ),
                        ),
                      ),
                      const Spacer(),
                      // Destructive secondary: bulk delete. Icon-only on purpose
                      // so the Export pill stays the visual primary; the count
                      // lives on that pill instead of in the centre to keep this
                      // row from feeling crowded.
                      _IconActionButton(
                        icon: Icons.delete_outline_rounded,
                        enabled: canExport,
                        tint: t.error,
                        onTap: () => _handleDelete(context, provider, taskCount),
                      ),
                      const SizedBox(width: 8),
                      _ActionPillButton(
                        icon: Icons.ios_share_rounded,
                        label: canExport ? '${context.l10n.exportButton}  ·  $taskCount' : context.l10n.exportButton,
                        enabled: canExport,
                        accent: t.accent,
                        onTap: () => _handleExport(context, provider),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _handleExport(BuildContext context, ActionItemsProvider provider) async {
    final t = context.omi;
    HapticFeedback.lightImpact();

    // Users connect one task app at a time. If none connected, nudge to
    // Settings; otherwise export directly to the connected app.
    final integrations = Provider.of<TaskIntegrationProvider>(context, listen: false);
    final connected = TaskIntegrationApp.values.where(integrations.isAppConnected).toList(growable: false);

    if (connected.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(context.l10n.connectTaskAppToExport),
          backgroundColor: t.bgTertiary,
          duration: const Duration(seconds: 4),
          action: SnackBarAction(
            label: context.l10n.connectAction,
            textColor: t.textPrimary,
            onPressed: () {
              Navigator.of(context).push(MaterialPageRoute(builder: (_) => const TaskIntegrationsPage()));
            },
          ),
        ),
      );
      return;
    }

    await provider.bulkExportSelected(context, connected.first);
  }

  Future<void> _handleDelete(BuildContext context, ActionItemsProvider provider, int taskCount) async {
    final t = context.omi;
    HapticFeedback.lightImpact();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: t.bgSecondary,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        title: Text(
          context.l10n.deleteSelectedItemsTitle,
          style: TextStyle(color: t.textPrimary, fontSize: 17, fontWeight: FontWeight.w600),
        ),
        content: Text(
          context.l10n.deleteSelectedItemsMessage(taskCount, taskCount > 1 ? 's' : ''),
          style: TextStyle(color: t.textTertiary, fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(
              context.l10n.cancel,
              style: TextStyle(color: t.textSecondary, fontWeight: FontWeight.w500),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(
              context.l10n.delete,
              style: TextStyle(color: t.error, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    if (!context.mounted) return;
    await provider.deleteSelectedItems(context: context);
  }
}

class _IconActionButton extends StatelessWidget {
  final IconData icon;
  final bool enabled;
  final Color tint;
  final VoidCallback onTap;

  const _IconActionButton({
    required this.icon,
    required this.enabled,
    required this.tint,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final t = context.omi;
    return GestureDetector(
      onTap: enabled ? onTap : null,
      child: Container(
        width: 44,
        height: 44,
        alignment: Alignment.center,
        child: Icon(
          icon,
          size: 22,
          color: enabled ? tint : t.textTertiary,
        ),
      ),
    );
  }
}

class _ActionPillButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool enabled;
  final Color accent;
  final VoidCallback onTap;

  const _ActionPillButton({
    required this.icon,
    required this.label,
    required this.enabled,
    required this.accent,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final t = context.omi;
    return GestureDetector(
      onTap: enabled ? onTap : null,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        decoration: BoxDecoration(
          color: enabled ? accent : t.bgTertiary,
          borderRadius: BorderRadius.circular(22),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 18, color: enabled ? t.textPrimary : t.textTertiary),
            const SizedBox(width: 8),
            Text(
              label,
              style: TextStyle(
                color: enabled ? t.textPrimary : t.textTertiary,
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
