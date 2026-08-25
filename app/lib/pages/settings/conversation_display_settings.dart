import 'package:omi/utils/platform/platform_manager.dart';
import 'package:flutter/material.dart';

import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:provider/provider.dart';

import 'package:omi/providers/conversation_provider.dart';
import 'package:omi/utils/l10n_extensions.dart';
import 'package:omi/pages/settings/widgets/glass_icon_chip.dart';
import 'package:omi/utils/theme/omi_tokens.dart';
import 'package:omi/utils/theme/omi_icons.dart';
import 'package:omi/widgets/omi_switch.dart';

class ConversationDisplaySettings extends StatefulWidget {
  const ConversationDisplaySettings({super.key});

  @override
  State<ConversationDisplaySettings> createState() => _ConversationDisplaySettingsState();
}

class _ConversationDisplaySettingsState extends State<ConversationDisplaySettings> {
  @override
  void initState() {
    super.initState();
    PlatformManager.instance.analytics.conversationDisplaySettingsOpened();
  }

  Widget _buildSectionContainer({required List<Widget> children}) {
    final t = context.omi;

    return Container(
      decoration: BoxDecoration(color: t.bgSecondary, borderRadius: BorderRadius.circular(12)),
      child: Column(children: children),
    );
  }

  Widget _buildSectionHeader(String title, {String? subtitle}) {
    final t = context.omi;

    return Padding(
      padding: const EdgeInsets.only(left: 4, right: 4, bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(color: t.textPrimary, fontSize: 20, fontWeight: FontWeight.w600),
          ),
          if (subtitle != null) ...[
            const SizedBox(height: 6),
            Text(subtitle, style: TextStyle(color: t.textSecondary, fontSize: 14)),
          ],
        ],
      ),
    );
  }

  Widget _buildToggleItem({
    required String title,
    required String description,
    required FaIconData icon,
    required bool value,
    required ValueChanged<bool>? onChanged,
  }) {
    final t = context.omi;

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          SettingsIconChip.boxed(icon: (size) => FaIcon(icon, color: t.textSecondary, size: size)),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(color: t.textPrimary, fontSize: 16, fontWeight: FontWeight.w500),
                ),
                const SizedBox(height: 2),
                Text(description, style: TextStyle(color: t.textSecondary, fontSize: 12)),
              ],
            ),
          ),
          OmiSwitch(value: value, onChanged: onChanged, classicActiveThumbColor: t.success),
        ],
      ),
    );
  }

  Widget _buildThresholdSelector(ConversationProvider provider) {
    final t = context.omi;

    String getThresholdLabel(int seconds) {
      final minutes = seconds ~/ 60;
      return context.l10n.minLabel(minutes);
    }

    final thresholds = [
      (60, context.l10n.minLabel(1)),
      (120, context.l10n.minLabel(2)),
      (180, context.l10n.minLabel(3)),
      (240, context.l10n.minLabel(4)),
      (300, context.l10n.minLabel(5)),
    ];

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              SettingsIconChip.boxed(
                  icon: (size) => OmiIconWidget(icon: OmiIcon.clock, color: t.textSecondary, size: size)),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      context.l10n.durationThreshold,
                      style: TextStyle(color: t.textPrimary, fontSize: 16, fontWeight: FontWeight.w500),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      context.l10n.durationThresholdDesc,
                      style: TextStyle(color: t.textSecondary, fontSize: 12),
                    ),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(color: t.bgTertiary, borderRadius: BorderRadius.circular(8)),
                child: Text(
                  getThresholdLabel(provider.shortConversationThreshold),
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: t.textPrimary),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: thresholds.map((threshold) {
              final isSelected = provider.shortConversationThreshold == threshold.$1;
              return Expanded(
                child: GestureDetector(
                  onTap: () {
                    provider.setShortConversationThreshold(threshold.$1);
                    PlatformManager.instance.analytics.shortConversationThresholdChanged(threshold.$1);
                    setState(() {});
                  },
                  child: Container(
                    margin: EdgeInsets.only(right: threshold != thresholds.last ? 8 : 0),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    decoration: BoxDecoration(
                      color: isSelected ? t.success.withValues(alpha: 0.2) : t.bgTertiary,
                      borderRadius: BorderRadius.circular(8),
                      border: isSelected ? Border.all(color: t.success, width: 1) : null,
                    ),
                    child: Text(
                      threshold.$2,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
                        color: isSelected ? t.textPrimary : t.textSecondary,
                      ),
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
        ],
      ),
    );
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
          icon: const FaIcon(FontAwesomeIcons.chevronLeft, size: 18),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text(
          context.l10n.conversationDisplay,
          style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 18),
        ),
        centerTitle: true,
      ),
      body: Consumer<ConversationProvider>(
        builder: (context, provider, child) {
          return SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildSectionHeader(context.l10n.visibility, subtitle: context.l10n.visibilitySubtitle),
                _buildSectionContainer(
                  children: [
                    _buildToggleItem(
                      icon: FontAwesomeIcons.clock,
                      title: context.l10n.showShortConversations,
                      description: context.l10n.showShortConversationsDesc,
                      value: provider.showShortConversations,
                      onChanged: (_) {
                        provider.toggleShortConversations();
                        PlatformManager.instance.analytics.showShortConversationsToggled(
                          provider.showShortConversations,
                        );
                      },
                    ),
                    Divider(height: 1, color: t.divider),
                    _buildToggleItem(
                      icon: FontAwesomeIcons.trash,
                      title: context.l10n.showDiscardedConversations,
                      description: context.l10n.showDiscardedConversationsDesc,
                      value: provider.showDiscardedConversations,
                      onChanged: (_) {
                        provider.toggleDiscardConversations();
                        PlatformManager.instance.analytics.showDiscardedConversationsToggled(
                          provider.showDiscardedConversations,
                        );
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 32),
                _buildSectionHeader(
                  context.l10n.shortConversationThreshold,
                  subtitle: context.l10n.shortConversationThresholdSubtitle,
                ),
                _buildSectionContainer(children: [_buildThresholdSelector(provider)]),
                const SizedBox(height: 32),
              ],
            ),
          );
        },
      ),
    );
  }
}
