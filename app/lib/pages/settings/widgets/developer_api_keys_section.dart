import 'package:omi/utils/platform/platform_manager.dart';
import 'package:flutter/material.dart';

import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:omi/pages/settings/widgets/create_dev_api_key_sheet.dart';
import 'package:omi/pages/settings/widgets/dev_api_key_list_item.dart';
import 'package:omi/providers/dev_api_key_provider.dart';
import 'package:omi/utils/l10n_extensions.dart';
import 'package:omi/utils/theme/omi_tokens.dart';

class DeveloperApiKeysSection extends StatelessWidget {
  const DeveloperApiKeysSection({super.key});

  Widget _buildDocsButton(BuildContext context, String url, String label) {
    final t = context.omi;

    return Material(
      color: (t.isGlass ? t.accent : Colors.white),
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        onTap: () {
          launchUrl(Uri.parse(url));
          PlatformManager.instance.analytics.pageOpened('$label Docs');
        },
        borderRadius: BorderRadius.circular(20),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Text(
            context.l10n.docs,
            style: TextStyle(color: (t.isGlass ? t.onAccent : Colors.black), fontWeight: FontWeight.w600, fontSize: 12),
          ),
        ),
      ),
    );
  }

  Widget _buildCreateKeyButton(BuildContext context) {
    final t = context.omi;

    return Material(
      color: t.rowFillHover,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        onTap: () {
          final provider = Provider.of<DevApiKeyProvider>(context, listen: false);
          CreateDevApiKeySheet.show(context, provider);
        },
        borderRadius: BorderRadius.circular(20),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              FaIcon(FontAwesomeIcons.plus, color: t.textPrimary, size: 10),
              const SizedBox(width: 6),
              Text(
                context.l10n.createKey,
                style: TextStyle(color: t.textPrimary, fontSize: 12, fontWeight: FontWeight.w500),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = context.omi;

    return ChangeNotifierProvider(
      create: (_) => DevApiKeyProvider()..fetchKeys(),
      child: Builder(
        builder: (context) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Section Header with Docs and Create Key buttons
            Padding(
              padding: const EdgeInsets.only(left: 4, right: 4, bottom: 12),
              child: Row(
                children: [
                  Text(
                    context.l10n.developerApi,
                    style: TextStyle(color: t.textPrimary, fontSize: 20, fontWeight: FontWeight.w600),
                  ),
                  const Spacer(),
                  _buildDocsButton(context, 'https://docs.omi.me/doc/developer/api', 'Developer API'),
                  const SizedBox(width: 8),
                  _buildCreateKeyButton(context),
                ],
              ),
            ),

            // API Keys List
            Consumer<DevApiKeyProvider>(
              builder: (context, provider, child) {
                if (provider.isLoading && provider.keys.isEmpty) {
                  return Container(
                    padding: const EdgeInsets.all(24),
                    decoration: BoxDecoration(color: t.bgSecondary, borderRadius: BorderRadius.circular(12)),
                    child: Center(child: CircularProgressIndicator(strokeWidth: 2, color: t.textPrimary)),
                  );
                }
                if (provider.error != null) {
                  return Container(
                    padding: const EdgeInsets.all(24),
                    decoration: BoxDecoration(color: t.bgSecondary, borderRadius: BorderRadius.circular(12)),
                    child: Center(
                      child: Text(
                        context.l10n.errorWithMessage(provider.error!),
                        style: TextStyle(color: t.error),
                      ),
                    ),
                  );
                }
                if (provider.keys.isEmpty) {
                  return Container(
                    padding: const EdgeInsets.all(24),
                    decoration: BoxDecoration(color: t.bgSecondary, borderRadius: BorderRadius.circular(12)),
                    child: Column(
                      children: [
                        FaIcon(FontAwesomeIcons.key, color: t.textSecondary, size: 28),
                        const SizedBox(height: 12),
                        Text(context.l10n.noApiKeys, style: TextStyle(color: t.textSecondary, fontSize: 15)),
                        const SizedBox(height: 4),
                        Text(
                          context.l10n.createAKeyToGetStarted,
                          style: TextStyle(color: t.textSecondary, fontSize: 13),
                        ),
                      ],
                    ),
                  );
                }
                return Container(
                  decoration: BoxDecoration(color: t.bgSecondary, borderRadius: BorderRadius.circular(12)),
                  child: Column(
                    children: provider.keys.asMap().entries.map((entry) {
                      final index = entry.key;
                      final key = entry.value;
                      return Column(
                        children: [
                          DevApiKeyListItem(apiKey: key),
                          if (index < provider.keys.length - 1) Divider(height: 1, color: t.divider),
                        ],
                      );
                    }).toList(),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}
