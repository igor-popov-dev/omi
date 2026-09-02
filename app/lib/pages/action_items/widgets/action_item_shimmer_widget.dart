import 'package:flutter/material.dart';

import 'package:omi/utils/theme/omi_tokens.dart';
import 'package:omi/widgets/shimmer_with_timeout.dart';

class ActionItemShimmerWidget extends StatelessWidget {
  const ActionItemShimmerWidget({super.key});

  @override
  Widget build(BuildContext context) {
    final t = context.omi;
    // Classic keeps the exact grey pair it always used; Glass needs a light
    // placeholder pair that still reads as "loading" on a white card.
    final base = t.isGlass ? t.bgTertiary : Colors.grey[800]!;
    final highlight = t.isGlass ? t.bgSecondary : Colors.grey[600]!;
    return ShimmerWithTimeout(
      baseColor: base,
      highlightColor: highlight,
      child: Container(
        height: 60,
        width: double.infinity,
        decoration: BoxDecoration(color: base, borderRadius: BorderRadius.circular(t.cardRadius)),
      ),
    );
  }
}

class ActionItemsShimmerList extends StatelessWidget {
  final int itemCount;

  const ActionItemsShimmerList({super.key, this.itemCount = 8});

  @override
  Widget build(BuildContext context) {
    return SliverList(
      delegate: SliverChildBuilderDelegate((context, index) {
        return const Padding(
          padding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: ActionItemShimmerWidget(),
        );
      }, childCount: itemCount),
    );
  }
}
