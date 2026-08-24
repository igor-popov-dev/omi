import 'package:omi/utils/platform/platform_manager.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:omi/gen/assets.gen.dart';
import 'package:omi/pages/settings/task_integrations_page.dart';
import 'package:omi/utils/l10n_extensions.dart';
import 'package:omi/utils/theme/omi_tokens.dart';

class TaskIntegrationsBanner extends StatelessWidget {
  const TaskIntegrationsBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final t = context.omi;
    return GestureDetector(
      onTap: () {
        HapticFeedback.lightImpact();

        // Track banner click
        PlatformManager.instance.analytics.exportTasksBannerClicked();

        Navigator.of(context).push(MaterialPageRoute(builder: (context) => const TaskIntegrationsPage()));
      },
      child: Container(
        margin: const EdgeInsets.only(bottom: 16),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          // Glass has no gradients (§3.1) — a flat accent tint stands in for the
          // purple sweep Classic keeps unchanged.
          gradient: t.isGlass
              ? null
              : LinearGradient(
                  colors: [Colors.deepPurple.withValues(alpha: 0.3), Colors.purple.withValues(alpha: 0.3)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
          color: t.isGlass ? t.accent.withValues(alpha: 0.12) : null,
          borderRadius: BorderRadius.circular(t.cardRadius),
          border: Border.all(color: t.accent.withValues(alpha: 0.2), width: 1),
        ),
        child: Row(
          children: [
            // Overlapping app logos (stacked)
            SizedBox(
              width: 80, // Width for 3 overlapping logos
              height: 28,
              child: Stack(
                children: [
                  // First logo - Todoist
                  Positioned(
                    left: 0,
                    child: Hero(
                      tag: 'task_integration_todoist_icon',
                      child: _buildOverlappingLogo(Assets.integrationAppLogos.todoistLogo.path, 28),
                    ),
                  ),
                  // Second logo - ClickUp
                  Positioned(
                    left: 22,
                    child: Hero(
                      tag: 'task_integration_clickup_icon',
                      child: _buildOverlappingLogo(Assets.integrationAppLogos.clickupLogo.path, 28),
                    ),
                  ),
                  // Third logo - Asana
                  Positioned(
                    left: 44,
                    child: Hero(
                      tag: 'task_integration_asana_icon',
                      child: _buildOverlappingLogo(Assets.integrationAppLogos.asanaLogo.path, 28),
                    ),
                  ),
                ],
              ),
            ),

            // const SizedBox(width: 20),

            // Message
            Expanded(
              child: Text(
                context.l10n.exportTasksWithOneTap,
                style: TextStyle(color: t.textPrimary, fontSize: 15, fontWeight: FontWeight.w500),
              ),
            ),

            // NEW badge (moved to right)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
              decoration: BoxDecoration(
                color: t.success.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                context.l10n.newTag,
                style: TextStyle(
                  color: t.textPrimary,
                  fontSize: 9,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.5,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildOverlappingLogo(String path, double size) {
    return Container(
      width: size,
      height: size,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: Image.asset(path, width: size, height: size, fit: BoxFit.contain),
      ),
    );
  }
}
