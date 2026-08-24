import 'package:omi/utils/platform/platform_manager.dart';
import 'package:flutter/material.dart';

import 'package:provider/provider.dart';

import 'package:omi/pages/settings/usage_page.dart';
import 'package:omi/providers/usage_provider.dart';
import 'package:omi/utils/l10n_extensions.dart';
import 'package:omi/utils/other/temp.dart';
import 'package:omi/utils/theme/omi_tokens.dart';

class OutOfCreditsWidget extends StatelessWidget {
  const OutOfCreditsWidget({super.key});

  @override
  Widget build(BuildContext context) {
    final t = context.omi;
    return Consumer<UsageProvider>(
      builder: (context, usageProvider, child) {
        if (!usageProvider.isOutOfCredits) {
          return const SizedBox.shrink();
        }
        if (!usageProvider.showSubscriptionUI) {
          return const SizedBox.shrink();
        }

        return Container(
          color: t.bgSecondary,
          padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 12.0),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Text(
                  context.l10n.monthlyLimitReached,
                  style: TextStyle(color: t.textPrimary, fontSize: 14),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 12),
              TextButton(
                onPressed: () {
                  PlatformManager.instance.analytics.paywallOpened('Out of Credits Banner');
                  routeToPage(context, const UsagePage());
                },
                child: Text(
                  context.l10n.checkUsage,
                  style: TextStyle(color: t.accent, fontWeight: FontWeight.bold, fontSize: 13),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
