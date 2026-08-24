import 'package:omi/utils/platform/platform_manager.dart';
import 'package:flutter/material.dart';

import 'package:omi/pages/apps/add_app.dart';
import 'package:omi/pages/apps/add_mcp_server_page.dart';
import 'package:omi/utils/l10n_extensions.dart';
import 'package:omi/utils/other/temp.dart';
import 'package:omi/utils/theme/omi_tokens.dart';

class CreateOptionsSheet extends StatelessWidget {
  const CreateOptionsSheet({super.key});

  @override
  Widget build(BuildContext context) {
    final t = context.omi;

    return Container(
      padding: const EdgeInsets.fromLTRB(24, 32, 24, 24),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            context.l10n.whatWouldYouLikeToCreate,
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w400,
                  color: Theme.of(context).colorScheme.onSurface,
                ),
          ),
          const SizedBox(height: 24),
          Card(
            elevation: 0,
            color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            child: ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              titleAlignment: ListTileTitleAlignment.center,
              leading: Icon(Icons.apps, color: t.textPrimary),
              title: Text(
                context.l10n.createAnApp,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(color: t.textPrimary),
              ),
              onTap: () {
                Navigator.pop(context);
                PlatformManager.instance.analytics.pageOpened('Submit App');
                routeToPage(context, const AddAppPage());
              },
            ),
          ),
          const SizedBox(height: 12),
          Card(
            elevation: 0,
            color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            child: ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              leading: Icon(Icons.cable, color: t.textPrimary),
              titleAlignment: ListTileTitleAlignment.center,
              title: Text(
                context.l10n.addMcpServer,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(color: t.textPrimary),
              ),
              onTap: () {
                Navigator.pop(context);
                PlatformManager.instance.analytics.pageOpened('Add MCP Server');
                routeToPage(context, const AddMcpServerPage());
              },
            ),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}
