import 'package:flutter/material.dart';

import 'package:omi/backend/schema/memory.dart';
import 'package:omi/utils/theme/omi_tokens.dart';

class CategoryChip extends StatelessWidget {
  final MemoryCategory category;
  final int? count;
  final bool isSelected;
  final VoidCallback? onTap;
  final bool showIcon;
  final bool showCheckmark;

  const CategoryChip({
    super.key,
    required this.category,
    this.count,
    this.isSelected = false,
    this.onTap,
    this.showIcon = false,
    this.showCheckmark = false,
  });

  /// Categorical palette: four hues that must stay distinguishable from each
  /// other, not four semantic roles. Left un-themed on purpose (same rule as
  /// user-colored folder icons) — collapsing these onto tokens would make
  /// `system` and `manual` the same color under Glass.
  Color _getCategoryColor() {
    switch (category) {
      case MemoryCategory.system:
        return Colors.blue;
      case MemoryCategory.interesting:
        return Colors.orange;
      case MemoryCategory.manual:
        return Colors.purple;
      case MemoryCategory.workflow:
        return Colors.teal;
    }
  }

  IconData _getCategoryIcon() {
    switch (category) {
      case MemoryCategory.system:
        return Icons.person_outlined;
      case MemoryCategory.interesting:
        return Icons.lightbulb_outlined;
      case MemoryCategory.manual:
        return Icons.edit_outlined;
      case MemoryCategory.workflow:
        return Icons.account_tree_outlined;
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.omi;
    // Use shorter display names for categories
    String displayName;
    switch (category) {
      case MemoryCategory.system:
        displayName = "About You";
        break;
      case MemoryCategory.interesting:
        displayName = "Insights";
        break;
      case MemoryCategory.manual:
        displayName = "Manual";
        break;
      case MemoryCategory.workflow:
        displayName = "Workflow";
        break;
    }

    final countText = count != null ? ' ($count)' : '';

    final categoryColor = _getCategoryColor();
    final categoryIcon = _getCategoryIcon();

    Widget chip = Container(
      height: 26,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 0),
      decoration: BoxDecoration(
        color: isSelected
            ? (onTap != null ? categoryColor : categoryColor.withValues(alpha: 0.15))
            : t.bgTertiary.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(13),
        border: isSelected && onTap == null ? Border.all(color: categoryColor, width: 1) : null,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (showIcon) ...[
            Icon(categoryIcon, size: 14, color: isSelected && onTap != null ? t.textPrimary : categoryColor),
            const SizedBox(width: 4),
          ],
          if (showCheckmark && isSelected) ...[
            Icon(Icons.check, size: 12, color: t.textPrimary),
            const SizedBox(width: 2),
          ],
          Text(
            displayName + countText,
            style: TextStyle(
              color:
                  isSelected ? (onTap != null ? t.textPrimary : categoryColor) : t.textPrimary.withValues(alpha: 0.7),
              fontSize: 12,
              fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
            ),
          ),
        ],
      ),
    );

    if (onTap != null) {
      return GestureDetector(onTap: onTap, child: chip);
    }

    return Align(alignment: Alignment.centerLeft, child: chip);
  }
}
