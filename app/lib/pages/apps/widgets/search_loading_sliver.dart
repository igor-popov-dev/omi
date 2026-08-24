import 'package:flutter/material.dart';

import 'package:omi/widgets/shimmer_with_timeout.dart';
import 'package:omi/utils/theme/omi_tokens.dart';

/// Placeholder rows shown while an app search is running.
///
/// Extracted from `ExploreInstallPage` so the loading state can be pumped on its
/// own in a widget test — a search that outlives the shimmer animation is the
/// case that matters here, and it is not reachable through the full page without
/// a live backend.
class SearchLoadingSliver extends StatelessWidget {
  /// Creates the loading placeholder shown during a search.
  const SearchLoadingSliver({super.key, this.placeholderCount = 5});

  /// How many placeholder rows to draw.
  final int placeholderCount;

  @override
  Widget build(BuildContext context) {
    return SliverPadding(
      padding: const EdgeInsets.only(bottom: 64, left: 20, right: 20, top: 20),
      sliver: SliverMainAxisGroup(
        slivers: [
          const SliverToBoxAdapter(child: _SearchProgressBar()),
          SliverList(
            delegate: SliverChildBuilderDelegate(
              (context, index) => const _ShimmerListItem(),
              childCount: placeholderCount,
            ),
          ),
        ],
      ),
    );
  }
}

/// The one thing on screen that keeps moving for as long as the search runs.
///
/// The shimmer placeholders below it stop animating after five seconds and go
/// static, so on a slow search they stop being evidence of anything. This does
/// not time out, which is the whole point: it separates "still working" from
/// "wedged" at the moment the user starts to wonder.
class _SearchProgressBar extends StatelessWidget {
  const _SearchProgressBar();

  @override
  Widget build(BuildContext context) {
    final t = context.omi;

    return Padding(
      padding: const EdgeInsets.only(bottom: 16.0),
      child: LinearProgressIndicator(
        // Indeterminate: a search has no known duration, and a determinate bar
        // would have to invent a percentage that then appears to stall.
        minHeight: 3,
        backgroundColor: t.bgSecondary,
        valueColor: AlwaysStoppedAnimation<Color>(t.textPrimary),
        borderRadius: BorderRadius.circular(6.0),
      ),
    );
  }
}

class _ShimmerListItem extends StatelessWidget {
  const _ShimmerListItem();

  @override
  Widget build(BuildContext context) {
    final t = context.omi;

    return ShimmerWithTimeout(
      baseColor: t.bgSecondary,
      highlightColor: t.bgTertiary,
      child: Container(
        padding: const EdgeInsets.all(16),
        margin: const EdgeInsets.only(bottom: 8),
        decoration: BoxDecoration(color: t.bgSecondary, borderRadius: BorderRadius.circular(t.cardRadius)),
        child: Row(
          children: [
            Container(
              width: 60,
              height: 60,
              decoration: BoxDecoration(color: t.bgTertiary, borderRadius: BorderRadius.circular(12)),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: double.infinity,
                    height: 18,
                    decoration: BoxDecoration(
                      color: t.bgTertiary,
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Container(
                    width: 150,
                    height: 14,
                    decoration: BoxDecoration(
                      color: t.bgTertiary,
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Container(
              width: 72,
              height: 32,
              decoration: BoxDecoration(color: t.bgTertiary, borderRadius: BorderRadius.circular(16)),
            ),
          ],
        ),
      ),
    );
  }
}
