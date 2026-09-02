import 'package:flutter/material.dart';

import 'package:provider/provider.dart';

import 'package:omi/pages/settings/task_integrations_page.dart';
import 'package:omi/providers/task_integration_provider.dart';
import 'package:omi/utils/l10n_extensions.dart';
import 'package:omi/utils/logger.dart';
import 'package:omi/utils/platform/platform_service.dart';
import 'package:omi/utils/theme/omi_tokens.dart';
import 'package:omi/utils/theme/omi_icons.dart';

class IntegrationSettingsPage extends StatefulWidget {
  final String appName;
  final String appKey;
  final Future<void> Function() disconnectService;
  final List<Widget> children;
  final bool showRefresh;
  final VoidCallback? onRefresh;
  final String? infoText;

  const IntegrationSettingsPage({
    super.key,
    required this.appName,
    required this.appKey,
    required this.disconnectService,
    this.children = const [],
    this.showRefresh = false,
    this.onRefresh,
    this.infoText,
  });

  @override
  State<IntegrationSettingsPage> createState() => _IntegrationSettingsPageState();
}

class _IntegrationSettingsPageState extends State<IntegrationSettingsPage> {
  Future<void> _disconnect() async {
    final provider = context.read<TaskIntegrationProvider>();
    final navigator = Navigator.of(context);
    final scaffoldMessenger = ScaffoldMessenger.of(context);
    final l10n = context.l10n;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) {
        final t = context.omi;

        return AlertDialog(
          backgroundColor: t.bgSecondary,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Text(context.l10n.disconnectFromApp(widget.appName), style: TextStyle(color: t.textPrimary)),
          content: Text(
            context.l10n.disconnectFromAppDesc(widget.appName),
            style: TextStyle(color: t.textSecondary),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(context.l10n.cancel, style: TextStyle(color: t.textSecondary)),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(context.l10n.disconnect, style: TextStyle(color: t.error)),
            ),
          ],
        );
      },
    );

    if (confirmed == true) {
      await widget.disconnectService();
      if (!mounted) return;
      await provider.deleteConnection(widget.appKey);
      if (provider.selectedApp.key == widget.appKey) {
        final candidates = TaskIntegrationApp.values.where((app) {
          if (!app.isAvailable) return false;
          if (!PlatformService.isApple && app == TaskIntegrationApp.appleReminders) return false;
          if (app.key == widget.appKey) return false;
          return provider.isAppConnected(app);
        });
        final fallback = candidates.isNotEmpty ? candidates.first : null;
        if (fallback != null) {
          await provider.setSelectedApp(fallback);
          Logger.debug('Task integration disabled: ${widget.appName} - switched to ${fallback.key}');
        } else {
          Logger.debug('Task integration disabled: ${widget.appName} - no active integration selected');
        }
      }
      provider.refresh();
      scaffoldMessenger.showSnackBar(
        SnackBar(content: Text(l10n.disconnectedFrom(widget.appName)), duration: const Duration(seconds: 2)),
      );
      navigator.pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.omi;

    return Scaffold(
      backgroundColor: t.bgPrimary,
      appBar: AppBar(
        backgroundColor: t.bgPrimary,
        elevation: 0,
        leading: IconButton(
          icon: Icon(Icons.arrow_back, color: t.textPrimary),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(
          context.l10n.appSettings(widget.appName),
          style: TextStyle(color: t.textPrimary, fontSize: 18, fontWeight: FontWeight.w600),
        ),
        centerTitle: true,
        actions: [
          if (widget.showRefresh)
            IconButton(
              icon: Icon(Icons.refresh, color: t.textPrimary),
              onPressed: widget.onRefresh,
              tooltip: context.l10n.refresh,
            ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                margin: const EdgeInsets.only(bottom: 24),
                decoration: BoxDecoration(
                  color: t.success.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: t.success.withValues(alpha: 0.3)),
                ),
                child: Row(
                  children: [
                    OmiIconWidget(icon: OmiIcon.checkCircle, color: t.success, size: 16),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        context.l10n.connectedToApp(widget.appName),
                        style: TextStyle(color: t.success, fontSize: 14),
                      ),
                    ),
                  ],
                ),
              ),
              Text(
                context.l10n.account,
                style: TextStyle(color: t.textPrimary, fontSize: 18, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 8),
              Text(
                widget.infoText ?? context.l10n.actionItemsSyncedTo(widget.appName),
                style: TextStyle(color: t.textSecondary, fontSize: 14),
              ),
              const SizedBox(height: 32),
              // Wrap children in Expanded with SingleChildScrollView to handle overflow
              Expanded(
                child: SingleChildScrollView(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: widget.children),
                ),
              ),
              const SizedBox(height: 16),
              GestureDetector(
                onTap: _disconnect,
                child: Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: t.error.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: t.error.withValues(alpha: 0.3)),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.logout, color: t.error, size: 20),
                      const SizedBox(width: 12),
                      Text(
                        context.l10n.disconnectFromApp(widget.appName).replaceAll('?', ''),
                        style: TextStyle(color: t.error, fontSize: 16, fontWeight: FontWeight.w500),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
