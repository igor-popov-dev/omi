import 'package:flutter/material.dart';

import 'package:provider/provider.dart';

import 'package:omi/pages/apps/app_detail/app_detail.dart';
import 'package:omi/providers/app_provider.dart';
import 'package:omi/utils/l10n_extensions.dart';
import 'package:omi/utils/other/temp.dart';
import 'package:omi/utils/theme/omi_tokens.dart';

class ExternalIntegrationsSection extends StatelessWidget {
  const ExternalIntegrationsSection({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<AppProvider>(
      builder: (context, appProvider, child) {
        final t = context.omi;

        final enabledExternalApps = appProvider.apps.where((app) => app.enabled && app.worksExternally()).toList();

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              context.l10n.externalAppAccess,
              style: TextStyle(color: t.textPrimary, fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(context.l10n.externalAppAccessDescription, style: TextStyle(color: t.textSecondary, fontSize: 14)),
            const SizedBox(height: 16),
            if (enabledExternalApps.isEmpty)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 24.0),
                decoration: BoxDecoration(color: t.bgSecondary, borderRadius: BorderRadius.circular(12)),
                child: Center(
                  child: Text(context.l10n.noExternalAppsHaveAccess, style: TextStyle(color: t.textSecondary)),
                ),
              )
            else
              Container(
                decoration: BoxDecoration(color: t.bgSecondary, borderRadius: BorderRadius.circular(12)),
                child: ListView.separated(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: enabledExternalApps.length,
                  itemBuilder: (context, index) {
                    final app = enabledExternalApps[index];
                    return ListTile(
                      leading: CircleAvatar(backgroundImage: NetworkImage(app.getImageUrl())),
                      title: Text(app.getName()),
                      trailing: const Icon(Icons.arrow_forward_ios, size: 16),
                      onTap: () {
                        routeToPage(context, AppDetailPage(app: app));
                      },
                    );
                  },
                  separatorBuilder: (context, index) => Divider(height: 1, color: t.textSecondary),
                ),
              ),
          ],
        );
      },
    );
  }
}
