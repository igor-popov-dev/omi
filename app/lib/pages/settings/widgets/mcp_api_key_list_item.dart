import 'package:flutter/material.dart';

import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:provider/provider.dart';

import 'package:omi/backend/schema/mcp_api_key.dart';
import 'package:omi/providers/mcp_provider.dart';
import 'package:omi/utils/l10n_extensions.dart';
import 'package:omi/utils/theme/omi_tokens.dart';

class McpApiKeyListItem extends StatelessWidget {
  final McpApiKey apiKey;

  const McpApiKeyListItem({super.key, required this.apiKey});

  @override
  Widget build(BuildContext context) {
    final t = context.omi;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(color: t.bgTertiary, borderRadius: BorderRadius.circular(10)),
            child: FaIcon(FontAwesomeIcons.key, color: t.textSecondary, size: 16),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  apiKey.name,
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500, color: t.textPrimary),
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 4),
                Text(
                  apiKey.keyPrefix,
                  style: TextStyle(color: t.textSecondary, fontSize: 13, fontFamily: 'monospace'),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          GestureDetector(
            onTap: () => _showDeleteConfirmation(context, apiKey),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: t.error.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                context.l10n.revoke,
                style: TextStyle(color: t.error, fontSize: 13, fontWeight: FontWeight.w500),
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _showDeleteConfirmation(BuildContext context, McpApiKey apiKey) {
    showDialog(
      context: context,
      builder: (BuildContext dialogContext) {
        final t = context.omi;

        return AlertDialog(
          backgroundColor: t.bgSecondary,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Text(
            context.l10n.revokeKeyQuestion,
            style: TextStyle(color: t.textPrimary, fontWeight: FontWeight.w600),
          ),
          content: Text(context.l10n.revokeKeyConfirmation(apiKey.name), style: TextStyle(color: t.textSecondary)),
          actions: <Widget>[
            TextButton(
              child: Text(context.l10n.cancel, style: TextStyle(color: t.textSecondary)),
              onPressed: () => Navigator.of(dialogContext).pop(),
            ),
            TextButton(
              child: Text(
                context.l10n.revoke,
                style: TextStyle(color: t.error, fontWeight: FontWeight.w600),
              ),
              onPressed: () {
                Provider.of<McpProvider>(context, listen: false).deleteKey(apiKey.id);
                Navigator.of(dialogContext).pop();
              },
            ),
          ],
        );
      },
    );
  }
}
