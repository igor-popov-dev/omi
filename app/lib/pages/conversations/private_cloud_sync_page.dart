import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:provider/provider.dart';

import 'package:omi/providers/user_provider.dart';
import 'package:omi/utils/l10n_extensions.dart';
import 'package:omi/utils/theme/omi_theme.dart';
import 'package:omi/utils/theme/omi_tokens.dart';

class PrivateCloudSyncPage extends StatefulWidget {
  const PrivateCloudSyncPage({super.key});

  @override
  State<PrivateCloudSyncPage> createState() => _PrivateCloudSyncPageState();
}

class _PrivateCloudSyncPageState extends State<PrivateCloudSyncPage> {
  bool _isSaving = false;

  Future<void> _togglePrivateCloudSync(bool value) async {
    final t = context.omi;
    final userProvider = context.read<UserProvider>();
    if (value) {
      final confirmed = await _showEnableDialog();
      if (confirmed != true) return;
    }

    setState(() => _isSaving = true);
    try {
      await userProvider.setPrivateCloudSync(value);
      if (!mounted) return;
      setState(() => _isSaving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(value ? context.l10n.cloudStorageEnabled : context.l10n.cloudStorageDisabled),
          backgroundColor: t.success,
        ),
      );
    } catch (e) {
      print('Error toggling cloud storage: $e');
      if (!mounted) return;
      setState(() => _isSaving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.failedToUpdateSettings(e.toString())), backgroundColor: t.error),
      );
    }
  }

  Future<bool?> _showEnableDialog() {
    final t = context.omi;
    return showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: t.bgSecondary,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(
          context.l10n.enableCloudStorage,
          style: TextStyle(color: t.textPrimary, fontSize: 18, fontWeight: FontWeight.w600),
        ),
        content: Text(
          context.l10n.cloudStorageDialogMessage,
          style: TextStyle(color: t.textSecondary, fontSize: 14, height: 1.4),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(context.l10n.cancel, style: TextStyle(color: t.textSecondary)),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(
              context.l10n.enable,
              style: TextStyle(color: t.accent, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFaIcon(FaIconData icon, {double size = 18, Color? color}) {
    final t = context.omi;
    return Padding(
      padding: const EdgeInsets.only(left: 2, top: 1),
      child: FaIcon(icon, size: size, color: color ?? t.textSecondary),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = context.omi;
    return Consumer<UserProvider>(
      builder: (context, userProvider, child) {
        final isEnabled = userProvider.privateCloudSyncEnabled;
        final isLoading = userProvider.isLoading;

        return Scaffold(
          backgroundColor: t.bgPrimary,
          appBar: AppBar(
            backgroundColor: t.bgPrimary,
            elevation: 0,
            leading: IconButton(
              icon: _buildFaIcon(FontAwesomeIcons.chevronLeft, size: 18, color: t.textPrimary),
              onPressed: () => Navigator.of(context).pop(),
            ),
            title: Text(
              context.l10n.storeAudioOnCloud,
              style: TextStyle(color: t.textPrimary, fontSize: 18, fontWeight: FontWeight.w600),
            ),
            centerTitle: true,
          ),
          body: isLoading
              ? Center(child: CircularProgressIndicator(color: t.textPrimary))
              : SingleChildScrollView(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        padding: const EdgeInsets.all(20),
                        decoration: BoxDecoration(
                          color: t.bgSecondary,
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                _buildFaIcon(FontAwesomeIcons.cloud, size: 20, color: t.accent),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Text(
                                    context.l10n.storeAudioOnCloud,
                                    style: TextStyle(
                                      color: t.textPrimary,
                                      fontSize: 18,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                                  decoration: BoxDecoration(
                                    color: isEnabled ? t.success.withValues(alpha: 0.2) : t.bgTertiary,
                                    borderRadius: BorderRadius.circular(100),
                                  ),
                                  child: Text(
                                    isEnabled ? context.l10n.on : context.l10n.off,
                                    style: TextStyle(
                                      color: isEnabled ? t.success : t.textPrimary,
                                      fontSize: 13,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 20),
                            Text(
                              context.l10n.storeAudioCloudDescription,
                              style: TextStyle(color: t.textSecondary, fontSize: 14, height: 1.5),
                            ),
                            const SizedBox(height: 24),
                            Divider(height: 1, color: t.divider),
                            const SizedBox(height: 20),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(
                                  context.l10n.enableCloudStorage,
                                  style: TextStyle(
                                    color: t.textPrimary,
                                    fontSize: 16,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                                Transform.scale(
                                  scale: 0.85,
                                  child: CupertinoSwitch(
                                    value: isEnabled,
                                    onChanged: _isSaving ? null : _togglePrivateCloudSync,
                                    activeTrackColor: t.accent,
                                    inactiveTrackColor: t.isGlass ? kGlassSwitchOffTrack : null,
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
        );
      },
    );
  }
}
