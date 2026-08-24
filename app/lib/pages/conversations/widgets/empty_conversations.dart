import 'package:flutter/material.dart';

import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import 'package:omi/utils/l10n_extensions.dart';
import 'package:omi/utils/theme/omi_tokens.dart';

class EmptyConversationsWidget extends StatefulWidget {
  final bool isStarredFilterActive;

  const EmptyConversationsWidget({super.key, this.isStarredFilterActive = false});

  @override
  State<EmptyConversationsWidget> createState() => _EmptyConversationsWidgetState();
}

class _EmptyConversationsWidgetState extends State<EmptyConversationsWidget> {
  @override
  Widget build(BuildContext context) {
    final t = context.omi;
    if (widget.isStarredFilterActive) {
      return Padding(
        padding: const EdgeInsets.only(top: 80.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(color: t.warning.withValues(alpha: 0.1), shape: BoxShape.circle),
              child: FaIcon(FontAwesomeIcons.star, color: t.warning, size: 32),
            ),
            const SizedBox(height: 16),
            Text(
              context.l10n.noStarredConversations,
              style: TextStyle(color: t.textPrimary, fontSize: 16, fontWeight: FontWeight.w500),
            ),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32.0),
              child: Text(
                context.l10n.starConversationHint,
                style: TextStyle(color: t.textSecondary, fontSize: 14),
                textAlign: TextAlign.center,
              ),
            ),
          ],
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(top: 120.0),
      child: Text(context.l10n.noConversationsYet, style: TextStyle(color: t.textSecondary, fontSize: 16)),
    );
  }
}
