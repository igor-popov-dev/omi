import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:omi/pages/settings/widgets/glass_icon_chip.dart';
import 'package:omi/providers/phone_call_provider.dart';
import 'package:omi/utils/l10n_extensions.dart';
import 'package:omi/widgets/dialog.dart';
import 'package:omi/utils/theme/omi_tokens.dart';

class PhoneCallSettingsPage extends StatelessWidget {
  const PhoneCallSettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.omi.bgPrimary,
      appBar: AppBar(
        title: Text(context.l10n.phoneCallSettingsTitle),
        backgroundColor: context.omi.bgPrimary,
        elevation: 0,
      ),
      body: Consumer<PhoneCallProvider>(
        builder: (context, provider, _) {
          final t = context.omi;

          return Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  context.l10n.yourVerifiedNumbers,
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: t.textPrimary),
                ),
                const SizedBox(height: 6),
                Text(context.l10n.verifiedNumbersDescription, style: TextStyle(fontSize: 14, color: t.textSecondary)),
                const SizedBox(height: 24),
                if (provider.verifiedNumbers.isEmpty)
                  _buildEmptyState(context)
                else
                  ...provider.verifiedNumbers.map(
                    (number) => _buildNumberRow(context, provider, number.id, number.phoneNumber, number.verifiedAt),
                  ),
                const Spacer(),
                SizedBox(height: MediaQuery.of(context).viewPadding.bottom),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildEmptyState(BuildContext context) {
    final t = context.omi;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 24),
      child: Center(
        child: Text(context.l10n.noVerifiedNumbers, style: TextStyle(fontSize: 15, color: t.textTertiary)),
      ),
    );
  }

  Widget _buildNumberRow(
    BuildContext context,
    PhoneCallProvider provider,
    String id,
    String phoneNumber,
    String verifiedAt,
  ) {
    final t = context.omi;

    var timeAgo = _formatVerifiedAt(context, verifiedAt);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: t.bgSecondary, borderRadius: BorderRadius.circular(t.cardRadius)),
      child: Row(
        children: [
          SettingsIconChip.boxed(
            icon: (size) => Icon(Icons.phone, color: t.textSecondary, size: size),
            radius: 12,
            classicIconSize: 20,
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  phoneNumber,
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500, color: t.textPrimary),
                ),
                const SizedBox(height: 2),
                Text(timeAgo, style: TextStyle(fontSize: 13, color: t.textSecondary)),
              ],
            ),
          ),
          GestureDetector(
            onTap: () => _confirmDelete(context, provider, id, phoneNumber),
            child: Icon(Icons.delete_outline, color: t.error, size: 22),
          ),
        ],
      ),
    );
  }

  void _confirmDelete(BuildContext context, PhoneCallProvider provider, String id, String phoneNumber) {
    showDialog(
      context: context,
      builder: (ctx) => getDialog(
        ctx,
        () => Navigator.pop(ctx),
        () async {
          Navigator.pop(ctx);
          await provider.deleteNumber(id);
        },
        context.l10n.deletePhoneNumberConfirm(phoneNumber),
        context.l10n.deletePhoneNumberWarning,
        okButtonText: context.l10n.phoneDeleteButton,
      ),
    );
  }

  String _formatVerifiedAt(BuildContext context, String verifiedAt) {
    try {
      var dt = DateTime.parse(verifiedAt);
      var diff = DateTime.now().difference(dt);
      if (diff.inMinutes < 60) return context.l10n.verifiedMinutesAgo(diff.inMinutes);
      if (diff.inHours < 24) return context.l10n.verifiedHoursAgo(diff.inHours);
      if (diff.inDays < 7) return context.l10n.verifiedDaysAgo(diff.inDays);
      return context.l10n.verifiedOnDate('${dt.month}/${dt.day}/${dt.year}');
    } catch (_) {
      return context.l10n.verifiedFallback;
    }
  }
}
