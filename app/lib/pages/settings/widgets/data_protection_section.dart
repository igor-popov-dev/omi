import 'package:flutter/material.dart';

import 'package:provider/provider.dart';

import 'package:omi/providers/user_provider.dart';
import 'package:omi/utils/l10n_extensions.dart';
import 'package:omi/utils/theme/omi_tokens.dart';
import 'package:omi/utils/theme/omi_icons.dart';

extension StringExtension on String {
  String capitalize() {
    if (isEmpty) {
      return this;
    }
    return "${this[0].toUpperCase()}${substring(1)}";
  }
}

class DataProtectionSection extends StatefulWidget {
  const DataProtectionSection({super.key});

  @override
  State<DataProtectionSection> createState() => _DataProtectionSectionState();
}

class _DataProtectionSectionState extends State<DataProtectionSection> {
  @override
  void initState() {
    super.initState();
  }

  void _showE2eeComingSoonDialog(BuildContext context) {
    final t = context.omi;

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        // Dialogs sit on [OmiTokens.bgSecondary] everywhere else in the app
        // (`widgets/omi_confirm_dialog.dart`, `widgets/confirmation_dialog.dart`,
        // `widgets/language_picker.dart`); bgTertiary is a nested-surface tone
        // and loses contrast once it goes translucent under Glass. Classic keeps
        // bgTertiary: that is what this dialog has rendered as since the token
        // migration, and the Glass work must not shift Classic by a pixel.
        backgroundColor: t.isGlass ? t.bgSecondary : t.bgTertiary,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        title: Row(
          children: [
            Icon(Icons.lock_person_outlined, color: t.textPrimary),
            const SizedBox(width: 10),
            Text(
              context.l10n.maximumSecurityE2ee,
              style: TextStyle(color: t.textPrimary, fontWeight: FontWeight.bold),
            ),
          ],
        ),
        content: RichText(
          text: TextSpan(
            style: TextStyle(color: t.textSecondary, height: 1.5, fontSize: 15),
            children: [
              TextSpan(text: '${context.l10n.e2eeDescription}\n\n'),
              TextSpan(
                text: '${context.l10n.importantTradeoffs}\n',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              TextSpan(text: '${context.l10n.e2eeTradeoff1}\n'),
              TextSpan(text: '${context.l10n.e2eeTradeoff2}\n\n'),
              TextSpan(
                text: context.l10n.featureComingSoon,
                style: const TextStyle(fontStyle: FontStyle.italic),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(
              context.l10n.ok,
              style: TextStyle(color: t.textPrimary, fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<UserProvider>(
      builder: (context, provider, child) {
        final isMigrating = provider.isMigrating;
        final migrationFailed = provider.migrationFailed;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (isMigrating || migrationFailed) _buildMigrationStatus(provider),
            if (isMigrating)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.only(bottom: 16, left: 8, right: 8),
                child: Text(
                  context.l10n.migrationInProgressMessage,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.secondary.withValues(alpha: 0.9),
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ),
            _buildDefaultProtectionCard(context),
            _buildE2eeCard(context),
            const SizedBox(height: 12),
            _buildInfoRow(Icons.shield_outlined, context.l10n.dataAlwaysEncrypted),
          ],
        );
      },
    );
  }

  Widget _buildMigrationStatus(UserProvider provider) {
    final t = context.omi;

    if (provider.migrationFailed) {
      return Container(
        padding: const EdgeInsets.all(16),
        margin: const EdgeInsets.only(bottom: 24),
        decoration: BoxDecoration(
          color: t.error.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: t.error),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                OmiIconWidget(icon: OmiIcon.errorCircle, color: t.error, size: 20),
                const SizedBox(width: 8),
                Text(
                  context.l10n.migrationFailed,
                  style: TextStyle(color: t.textPrimary, fontWeight: FontWeight.bold, fontSize: 16),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              provider.migrationMessage,
              textAlign: TextAlign.center,
              style: TextStyle(color: t.textSecondary, fontSize: 14),
            ),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              onPressed: () {
                provider.updateDataProtectionLevel(provider.targetLevel);
              },
              icon: const Icon(Icons.refresh),
              label: Text(context.l10n.retry),
              style: ElevatedButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.secondary,
                foregroundColor: t.textPrimary,
              ),
            ),
          ],
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(16),
      margin: const EdgeInsets.only(bottom: 24),
      decoration: BoxDecoration(
        color: t.textTertiary,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: t.accent),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            context.l10n.migratingFromTo(provider.sourceLevel.capitalize(), provider.targetLevel.capitalize()),
            style: TextStyle(color: t.textPrimary, fontSize: 16, height: 1.4),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: LinearProgressIndicator(
                  value: provider.migrationTotalCount > 0
                      ? provider.migrationProcessedCount / provider.migrationTotalCount
                      : 0.0,
                  backgroundColor: t.textSecondary,
                  color: t.accent,
                  minHeight: 6,
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
              const SizedBox(width: 12),
              Text(
                provider.migrationTotalCount > 0
                    ? '${(provider.migrationProcessedCount / provider.migrationTotalCount * 100).toInt()}%'
                    : '0%',
                style: TextStyle(color: t.textPrimary, fontWeight: FontWeight.bold),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(provider.migrationETA, style: TextStyle(color: t.textSecondary, fontSize: 12)),
              Text(
                context.l10n.objectsCount(
                  provider.migrationProcessedCount.toString(),
                  provider.migrationTotalCount.toString(),
                ),
                style: TextStyle(color: t.textSecondary, fontSize: 12),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildDefaultProtectionCard(BuildContext context) {
    final t = context.omi;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: t.accent.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Theme.of(context).colorScheme.secondary, width: 1.5),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.verified_user_outlined, color: Theme.of(context).colorScheme.secondary, size: 28),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  context.l10n.secureEncryption,
                  style: TextStyle(fontWeight: FontWeight.bold, color: t.textPrimary, fontSize: 16),
                ),
                const SizedBox(height: 8),
                Text(
                  context.l10n.secureEncryptionDescription,
                  style: TextStyle(color: t.textSecondary, fontSize: 14, height: 1.4),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildE2eeCard(BuildContext context) {
    final t = context.omi;

    return GestureDetector(
      onTap: () => _showE2eeComingSoonDialog(context),
      child: Container(
        padding: const EdgeInsets.all(16),
        margin: const EdgeInsets.only(top: 12),
        decoration: BoxDecoration(
          color: t.bgSecondary,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: t.bgTertiary),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            OmiIconWidget(icon: OmiIcon.lock, color: t.textSecondary, size: 28),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        context.l10n.endToEndEncryption,
                        style: TextStyle(fontWeight: FontWeight.bold, color: t.textPrimary, fontSize: 16),
                      ),
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(color: t.textSecondary, borderRadius: BorderRadius.circular(16)),
                        child: Text(
                          context.l10n.comingSoon,
                          style: TextStyle(fontSize: 10, color: t.textPrimary, fontWeight: FontWeight.bold),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    context.l10n.e2eeCardDescription,
                    style: TextStyle(color: t.textSecondary, fontSize: 14, height: 1.4),
                  ),
                ],
              ),
            ),
            OmiIconWidget(icon: OmiIcon.info, color: t.textSecondary, size: 20),
          ],
        ),
      ),
    );
  }

  Widget _buildInfoRow(IconData icon, String text) {
    final t = context.omi;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4.0, vertical: 4.0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: t.textSecondary, size: 16),
          const SizedBox(width: 12),
          Expanded(
            child: Text(text, style: TextStyle(color: t.textSecondary, fontSize: 14, height: 1.4)),
          ),
        ],
      ),
    );
  }
}
