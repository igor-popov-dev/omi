import 'dart:io';

import 'package:omi/utils/platform/platform_manager.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:omi/backend/http/api/knowledge_graph_api.dart';
import 'package:omi/backend/schema/bt_device/bt_device.dart';
import 'package:omi/pages/home/firmware_mixin.dart';
import 'package:omi/backend/http/api/users.dart';
import 'package:omi/backend/preferences.dart';
import 'package:omi/env/env.dart';
import 'package:omi/models/stt_provider.dart';
import 'package:omi/pages/settings/conversation_display_settings.dart';
import 'package:omi/pages/settings/conversation_timeout_dialog.dart';
import 'package:omi/pages/settings/free_form_voice_timeout_dialog.dart';
import 'package:omi/pages/settings/voice_orb_theme_dialog.dart';
import 'package:omi/widgets/omi_switch.dart';
import 'package:omi/widgets/omi_voice_orb.dart';
import 'package:omi/services/voice_hub/free_form_voice_timeout.dart';
import 'package:omi/pages/settings/data_privacy_page.dart';
import 'package:omi/pages/settings/import_history_page.dart';
import 'package:omi/pages/payments/payments_page.dart';
import 'package:omi/pages/settings/transcription_settings_page.dart';
import 'package:omi/pages/settings/widgets/create_mcp_api_key_dialog.dart';
import 'package:omi/pages/settings/widgets/developer_api_keys_section.dart';
import 'package:omi/pages/settings/widgets/mcp_api_key_list_item.dart';
import 'package:omi/providers/device_provider.dart';
import 'package:omi/providers/capture_provider.dart';
import 'package:omi/providers/developer_mode_provider.dart';
import 'package:omi/providers/mcp_provider.dart';
import 'package:omi/services/voice_hub/escalation_level.dart';
import 'package:omi/utils/alerts/app_snackbar.dart';
import 'package:omi/utils/debug_log_manager.dart';
import 'package:omi/utils/firmware_update_build_policy.dart';
import 'package:omi/utils/l10n_extensions.dart';
import 'package:omi/utils/logger.dart';
import 'package:omi/pages/settings/widgets/glass_icon_chip.dart';
import 'package:omi/utils/theme/omi_tokens.dart';
import 'package:omi/utils/theme/omi_icons.dart';

class DeveloperSettingsPage extends StatelessWidget {
  const DeveloperSettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => DeveloperModeProvider()..initialize(),
      child: const _DeveloperSettingsPageView(),
    );
  }
}

class _DeveloperSettingsPageView extends StatefulWidget {
  const _DeveloperSettingsPageView();

  @override
  State<_DeveloperSettingsPageView> createState() => _DeveloperSettingsPageState();
}

class _DeveloperSettingsPageState extends State<_DeveloperSettingsPageView> {
  @override
  void initState() {
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      context.read<McpProvider>().fetchKeys();
    });
    super.initState();
  }

  // iPad requires a non-zero sharePositionOrigin (popover anchor) for the share sheet.
  Rect _shareOrigin() {
    if (!mounted) return const Rect.fromLTWH(0, 0, 100, 100);
    final box = context.findRenderObject() as RenderBox?;
    if (box != null && box.hasSize && box.size.width > 0 && box.size.height > 0) {
      return box.localToGlobal(Offset.zero) & box.size;
    }
    return const Rect.fromLTWH(0, 0, 100, 100);
  }

  Widget _buildSectionContainer({required List<Widget> children}) {
    final t = context.omi;

    return Container(
      decoration: BoxDecoration(color: t.bgSecondary, borderRadius: BorderRadius.circular(12)),
      child: Column(children: children),
    );
  }

  Widget _buildNavItem({required FaIconData icon, required String title, required VoidCallback onTap}) {
    final t = context.omi;

    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(color: t.bgSecondary, borderRadius: BorderRadius.circular(14)),
        child: Row(
          children: [
            SettingsIconChip.boxed(icon: (size) => FaIcon(icon, color: t.textSecondary, size: size)),
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                title,
                style: TextStyle(color: t.textPrimary, fontSize: 16, fontWeight: FontWeight.w500),
              ),
            ),
            FaIcon(FontAwesomeIcons.chevronRight, color: t.textSecondary, size: 14),
          ],
        ),
      ),
    );
  }

  Widget _buildSectionHeader(String title, {String? subtitle, Widget? trailing}) {
    final t = context.omi;

    return Padding(
      padding: const EdgeInsets.only(left: 4, right: 4, bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                title,
                style: TextStyle(color: t.textPrimary, fontSize: 20, fontWeight: FontWeight.w600),
              ),
              if (trailing != null) trailing,
            ],
          ),
          if (subtitle != null) ...[
            const SizedBox(height: 6),
            Text(subtitle, style: TextStyle(color: t.textSecondary, fontSize: 14)),
          ],
        ],
      ),
    );
  }

  Widget _buildSttChip() {
    final t = context.omi;

    final useCustom = SharedPreferencesUtil().useCustomStt;
    final config = SharedPreferencesUtil().customSttConfig;
    final label = useCustom ? SttProviderConfig.get(config.provider).displayName : 'Omi';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(color: t.textSecondary, borderRadius: BorderRadius.circular(8)),
      child: Text(
        label,
        style: TextStyle(color: t.textSecondary, fontSize: 11, fontWeight: FontWeight.w500),
      ),
    );
  }

  Widget _buildExperimentalItem({
    required String title,
    required String description,
    required FaIconData icon,
    required bool value,
    required ValueChanged<bool>? onChanged,
  }) {
    final t = context.omi;

    return Row(
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
    );
  }

  /// The free-form voice mode auto-off row: same shape as
  /// [_buildExperimentalItem], but a value picker instead of a switch (the
  /// setting is minutes, not on/off). Disabled while the mode's own flag is
  /// off — the value still applies once the flag is turned on, so it is shown
  /// rather than hidden, just visibly inert.
  Widget _buildFreeFormVoiceTimeoutItem(DeveloperModeProvider provider) {
    final enabled = provider.freeFormMode;
    final labelColor = enabled ? Colors.white : Colors.grey.shade600;
    return GestureDetector(
      onTap: enabled
          ? () async {
              final chosen = await FreeFormVoiceTimeoutDialog.show(
                context,
                currentMinutes: provider.freeFormVoiceIdleTimeoutMinutes,
              );
              if (chosen == null) return;
              provider.onFreeFormVoiceIdleTimeoutChanged(chosen);
            }
          : null,
      behavior: HitTestBehavior.opaque,
      child: Row(
        children: [
          SettingsIconChip.boxed(
              icon: (size) => FaIcon(FontAwesomeIcons.hourglassHalf,
                  color: context.omi.isGlass ? context.omi.textSecondary : Colors.grey.shade400, size: size),
              classicColor: const Color(0xFF2A2A2E)),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Voice mode auto-off',
                  style: TextStyle(color: labelColor, fontSize: 16, fontWeight: FontWeight.w500),
                ),
                const SizedBox(height: 2),
                Text(
                  'Silence after which free-form voice mode stops itself',
                  style: TextStyle(color: Colors.grey.shade500, fontSize: 12),
                ),
              ],
            ),
          ),
          Text(
            freeFormVoiceIdleTimeoutLabel(provider.freeFormVoiceIdleTimeoutMinutes),
            style: TextStyle(color: enabled ? Colors.grey.shade300 : Colors.grey.shade700, fontSize: 14),
          ),
          const SizedBox(width: 8),
          FaIcon(FontAwesomeIcons.chevronRight, color: Colors.grey.shade600, size: 14),
        ],
      ),
    );
  }

  /// Оформление живой иконки голосового режима — та же форма, что у строки
  /// авто-выключения выше, но справа вместо текста сама иконка: тему выбирают
  /// глазами, и подпись «Gradient» без картинки ничего не говорит.
  Widget _buildVoiceOrbThemeItem(DeveloperModeProvider provider) {
    final theme = voiceOrbThemeFromIndex(provider.voiceOrbTheme);
    return GestureDetector(
      onTap: () async {
        final chosen = await VoiceOrbThemeDialog.show(context, currentIndex: provider.voiceOrbTheme);
        if (chosen == null) return;
        provider.onVoiceOrbThemeChanged(chosen);
      },
      behavior: HitTestBehavior.opaque,
      child: Row(
        children: [
          SettingsIconChip.boxed(
              icon: (size) => FaIcon(FontAwesomeIcons.circleHalfStroke,
                  color: context.omi.isGlass ? context.omi.textSecondary : Colors.grey.shade400, size: size),
              classicColor: const Color(0xFF2A2A2E)),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Voice icon theme',
                  style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w500),
                ),
                const SizedBox(height: 2),
                Text(
                  'Look of the animated icon shown in chat',
                  style: TextStyle(color: Colors.grey.shade500, fontSize: 12),
                ),
              ],
            ),
          ),
          Text(
            voiceOrbThemeLabel(theme),
            style: TextStyle(color: Colors.grey.shade300, fontSize: 14),
          ),
          const SizedBox(width: 10),
          OmiVoiceOrb(phase: OmiVoiceOrbPhase.listening, theme: theme, diameter: 22),
          const SizedBox(width: 4),
          FaIcon(FontAwesomeIcons.chevronRight, color: Colors.grey.shade600, size: 14),
        ],
      ),
    );
  }

  // Ползунок «мозг голосового режима» (см. services/voice_hub/escalation_level.dart):
  // применяется со следующего запуска голосового режима, пересборка не нужна.
  Widget _buildClaudeEscalationItem(DeveloperModeProvider provider) {
    final level = ClaudeEscalationLevel.fromIndex(provider.claudeEscalationLevel);
    return Row(
      children: [
        SettingsIconChip.boxed(
            icon: (size) => FaIcon(FontAwesomeIcons.brain,
                color: context.omi.isGlass ? context.omi.textSecondary : Colors.grey.shade400, size: size),
            classicColor: const Color(0xFF2A2A2E)),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Voice brain: Gemini ↔ Claude',
                style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w500),
              ),
              const SizedBox(height: 2),
              Text('${level.label} — ${level.hint}', style: TextStyle(color: Colors.grey.shade500, fontSize: 12)),
              Slider(
                value: level.index.toDouble(),
                min: 0,
                max: (ClaudeEscalationLevel.values.length - 1).toDouble(),
                divisions: ClaudeEscalationLevel.values.length - 1,
                activeColor: const Color(0xFF22C55E),
                onChanged: (value) {
                  provider.onClaudeEscalationLevelChanged(value.round());
                  // Тёплый сокет хаба переживает остановку разговора со старыми
                  // инструкциями — рвём его, чтобы уровень применился сразу.
                  context.read<CaptureProvider>().invalidateWarmVoiceSessions();
                },
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildWebhookItem({
    required String title,
    required String description,
    required FaIconData icon,
    required bool isEnabled,
    required ValueChanged<bool> onToggle,
    required TextEditingController controller,
    Widget? extraField,
  }) {
    final t = context.omi;

    return Column(
      children: [
        Row(
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
            OmiSwitch(value: isEnabled, onChanged: onToggle, classicActiveThumbColor: t.success),
          ],
        ),
        if (isEnabled) ...[
          const SizedBox(height: 12),
          _buildTextField(controller: controller, label: context.l10n.endpointUrl),
          if (extraField != null) ...[const SizedBox(height: 8), extraField],
        ],
      ],
    );
  }

  Widget _buildTextField({
    required TextEditingController controller,
    required String label,
    String? hint,
    TextInputType? keyboardType,
  }) {
    final t = context.omi;

    return Container(
      decoration: BoxDecoration(color: t.bgTertiary, borderRadius: BorderRadius.circular(10)),
      child: TextField(
        controller: controller,
        keyboardType: keyboardType,
        style: TextStyle(color: t.textPrimary, fontSize: 15),
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          labelStyle: TextStyle(color: t.textSecondary, fontSize: 14),
          hintStyle: TextStyle(color: t.textSecondary, fontSize: 14),
          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          border: InputBorder.none,
          enabledBorder: InputBorder.none,
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide(color: t.hairline, width: 1),
          ),
        ),
      ),
    );
  }

  Widget _buildMcpConfigRow(String label, String value) {
    final t = context.omi;

    return GestureDetector(
      onTap: () {
        Clipboard.setData(ClipboardData(text: value));
        AppSnackbar.showSnackbar(context.l10n.labelCopied(label));
      },
      child: Row(
        children: [
          Expanded(
            flex: 2,
            child: Text(label, style: TextStyle(color: t.textSecondary, fontSize: 13)),
          ),
          Expanded(
            flex: 3,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(color: t.bgPrimary, borderRadius: BorderRadius.circular(6)),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      value,
                      style: TextStyle(color: t.textPrimary, fontFamily: 'Ubuntu Mono', fontSize: 13),
                    ),
                  ),
                  FaIcon(FontAwesomeIcons.copy, color: t.textSecondary, size: 11),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildApiKeysList(BuildContext context) {
    return Consumer<McpProvider>(
      builder: (context, provider, child) {
        final t = context.omi;

        if (provider.isLoading && provider.keys.isEmpty) {
          return Container(
            width: double.infinity,
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(color: t.bgSecondary, borderRadius: BorderRadius.circular(12)),
            child: Center(child: CircularProgressIndicator(strokeWidth: 2, color: t.textPrimary)),
          );
        }
        if (provider.error != null) {
          return Container(
            width: double.infinity,
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(color: t.bgSecondary, borderRadius: BorderRadius.circular(12)),
            child: Center(
              child: Text('Error: ${provider.error}', style: TextStyle(color: t.error)),
            ),
          );
        }
        if (provider.keys.isEmpty) {
          return Container(
            width: double.infinity,
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(color: t.bgSecondary, borderRadius: BorderRadius.circular(12)),
            child: Column(
              children: [
                FaIcon(FontAwesomeIcons.key, color: t.textSecondary, size: 28),
                const SizedBox(height: 12),
                Text(context.l10n.noApiKeysYet, style: TextStyle(color: t.textSecondary, fontSize: 15)),
                const SizedBox(height: 4),
                Text(context.l10n.createKeyToGetStarted, style: TextStyle(color: t.textSecondary, fontSize: 13)),
              ],
            ),
          );
        }
        return _buildSectionContainer(
          children: provider.keys.asMap().entries.map((entry) {
            final index = entry.key;
            final key = entry.value;
            return Column(
              children: [
                McpApiKeyListItem(apiKey: key),
                if (index < provider.keys.length - 1) Divider(height: 1, color: t.divider),
              ],
            );
          }).toList(),
        );
      },
    );
  }

  Widget _buildDocsButton(String url, String label) {
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

  Widget _buildCreateKeyButton(VoidCallback onTap) {
    final t = context.omi;

    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(color: t.rowFillHover, borderRadius: BorderRadius.circular(20)),
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
    );
  }

  Widget _buildManualFirmwareFlash(DeviceProvider provider) {
    final t = context.omi;

    return _buildSectionContainer(
      children: [
        GestureDetector(
          onTap: () async {
            final result = await FilePicker.platform.pickFiles(
              type: FileType.custom,
              allowedExtensions: ['zip'],
              dialogTitle: 'Select firmware ZIP file',
            );
            if (result == null || result.files.isEmpty) return;
            final file = result.files.first;
            if (file.path == null) return;

            if (!mounted) return;
            Navigator.of(context).push(
              MaterialPageRoute(
                builder: (context) => _ManualFirmwareFlashPage(
                  zipFilePath: file.path!,
                  fileName: file.name,
                  device: provider.pairedDevice!,
                ),
              ),
            );
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
            child: Row(
              children: [
                SizedBox(
                  width: 24,
                  height: 24,
                  child: Center(child: OmiIconWidget(icon: OmiIcon.chip, color: t.textPrimary, size: 16)),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Text('Flash Custom Firmware', style: TextStyle(color: t.textPrimary, fontSize: 16)),
                ),
                OmiIconWidget(icon: OmiIcon.chevronRight, color: t.textSecondary, size: 20),
              ],
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => FocusScope.of(context).unfocus(),
      child: Consumer<DeveloperModeProvider>(
        builder: (context, provider, child) {
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
                context.l10n.developerSettings,
                style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 18),
              ),
              centerTitle: true,
              actions: [
                TextButton(
                  onPressed: provider.savingSettingsLoading ? null : provider.saveSettings,
                  child: Text(
                    provider.savingSettingsLoading ? context.l10n.saving : context.l10n.save,
                    style: TextStyle(
                      color: provider.savingSettingsLoading ? t.textSecondary : t.textPrimary,
                      fontWeight: FontWeight.w500,
                      fontSize: 16,
                    ),
                  ),
                ),
              ],
            ),
            body: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Payment Methods
                  _buildNavItem(
                    icon: FontAwesomeIcons.solidCreditCard,
                    title: context.l10n.paymentMethods,
                    onTap: () =>
                        Navigator.of(context).push(MaterialPageRoute(builder: (context) => const PaymentsPage())),
                  ),
                  const SizedBox(height: 12),

                  // Conversation Display
                  _buildNavItem(
                    icon: FontAwesomeIcons.list,
                    title: context.l10n.conversationDisplay,
                    onTap: () => Navigator.of(
                      context,
                    ).push(MaterialPageRoute(builder: (context) => const ConversationDisplaySettings())),
                  ),
                  const SizedBox(height: 12),

                  // Data Privacy
                  _buildNavItem(
                    icon: FontAwesomeIcons.shield,
                    title: context.l10n.dataPrivacy,
                    onTap: () =>
                        Navigator.of(context).push(MaterialPageRoute(builder: (context) => const DataPrivacyPage())),
                  ),
                  const SizedBox(height: 12),

                  // Transcription Section
                  GestureDetector(
                    onTap: () async {
                      await Navigator.of(
                        context,
                      ).push(MaterialPageRoute(builder: (context) => const TranscriptionSettingsPage()));
                      if (mounted) {
                        setState(() {});
                      }
                    },
                    child: Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: t.bgSecondary,
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Row(
                        children: [
                          SettingsIconChip.boxed(
                              icon: (size) => OmiIconWidget(icon: OmiIcon.mic, color: t.textSecondary, size: size)),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  context.l10n.transcription,
                                  style: TextStyle(
                                    color: t.textPrimary,
                                    fontSize: 16,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  context.l10n.configureSttProvider,
                                  style: TextStyle(color: t.textSecondary, fontSize: 13),
                                ),
                              ],
                            ),
                          ),
                          _buildSttChip(),
                          const SizedBox(width: 8),
                          FaIcon(FontAwesomeIcons.chevronRight, color: t.textSecondary, size: 14),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),

                  // Conversation Timeout Section
                  GestureDetector(
                    onTap: () {
                      ConversationTimeoutDialog.show(context);
                    },
                    child: Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: t.bgSecondary,
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Row(
                        children: [
                          SettingsIconChip.boxed(
                              icon: (size) => OmiIconWidget(icon: OmiIcon.clock, color: t.textSecondary, size: size)),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  context.l10n.conversationTimeout,
                                  style: TextStyle(
                                    color: t.textPrimary,
                                    fontSize: 16,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  context.l10n.setWhenConversationsAutoEnd,
                                  style: TextStyle(color: t.textSecondary, fontSize: 13),
                                ),
                              ],
                            ),
                          ),
                          FaIcon(FontAwesomeIcons.chevronRight, color: t.textSecondary, size: 14),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),

                  // Import Data Section
                  GestureDetector(
                    onTap: () {
                      Navigator.of(context).push(MaterialPageRoute(builder: (context) => const ImportHistoryPage()));
                    },
                    child: Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: t.bgSecondary,
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Row(
                        children: [
                          SettingsIconChip.boxed(
                              icon: (size) => FaIcon(FontAwesomeIcons.fileImport, color: t.textSecondary, size: size)),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  context.l10n.importData,
                                  style: TextStyle(
                                    color: t.textPrimary,
                                    fontSize: 16,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  context.l10n.importDataFromOtherSources,
                                  style: TextStyle(color: t.textSecondary, fontSize: 13),
                                ),
                              ],
                            ),
                          ),
                          FaIcon(FontAwesomeIcons.chevronRight, color: t.textSecondary, size: 14),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 32),

                  // Debug Logs Section
                  _buildSectionHeader(context.l10n.debugAndDiagnostics),
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(color: t.bgSecondary, borderRadius: BorderRadius.circular(14)),
                    child: Column(
                      children: [
                        // Debug Logs toggle
                        Row(
                          children: [
                            SettingsIconChip.boxed(
                                icon: (size) => FaIcon(FontAwesomeIcons.bug, color: t.textSecondary, size: size)),
                            const SizedBox(width: 14),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    context.l10n.debugLogs,
                                    style: TextStyle(
                                      color: t.textPrimary,
                                      fontSize: 16,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    SharedPreferencesUtil().devLogsToFileEnabled
                                        ? context.l10n.autoDeletesAfterThreeDays
                                        : context.l10n.helpsDiagnoseIssues,
                                    style: TextStyle(color: t.textSecondary, fontSize: 13),
                                  ),
                                ],
                              ),
                            ),
                            OmiSwitch(
                              value: SharedPreferencesUtil().devLogsToFileEnabled,
                              onChanged: (v) async {
                                await DebugLogManager.setEnabled(v);
                                setState(() {});
                              },
                              classicActiveThumbColor: t.success,
                            ),
                          ],
                        ),

                        // Action buttons when enabled
                        if (SharedPreferencesUtil().devLogsToFileEnabled) ...[
                          const SizedBox(height: 16),
                          Row(
                            children: [
                              Expanded(
                                child: GestureDetector(
                                  onTap: () async {
                                    final files = await DebugLogManager.listLogFiles();
                                    if (files.isEmpty) {
                                      if (context.mounted) {
                                        AppSnackbar.showSnackbarError(context.l10n.noLogFilesFound);
                                      }
                                      return;
                                    }
                                    if (files.length == 1) {
                                      final result = await Share.shareXFiles(
                                        [XFile(files.first.path)],
                                        text: 'Omi debug log',
                                        sharePositionOrigin: _shareOrigin(),
                                      );
                                      if (result.status == ShareResultStatus.success) {
                                        Logger.debug('Log shared');
                                      }
                                      return;
                                    }

                                    if (!context.mounted) return;
                                    final selected = await showModalBottomSheet<File>(
                                      context: context,
                                      backgroundColor: t.bgSecondary,
                                      shape: const RoundedRectangleBorder(
                                        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
                                      ),
                                      builder: (ctx) {
                                        return SafeArea(
                                          child: Column(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              Container(
                                                margin: const EdgeInsets.only(top: 8),
                                                height: 4,
                                                width: 36,
                                                decoration: BoxDecoration(
                                                  color: t.divider,
                                                  borderRadius: BorderRadius.circular(2),
                                                ),
                                              ),
                                              Padding(
                                                padding: const EdgeInsets.all(16),
                                                child: Text(
                                                  context.l10n.selectLogFile,
                                                  style: TextStyle(
                                                    color: t.textPrimary,
                                                    fontSize: 18,
                                                    fontWeight: FontWeight.w600,
                                                  ),
                                                ),
                                              ),
                                              Flexible(
                                                child: ListView.separated(
                                                  shrinkWrap: true,
                                                  itemCount: files.length,
                                                  separatorBuilder: (_, __) => Divider(height: 1, color: t.divider),
                                                  itemBuilder: (ctx, i) {
                                                    final f = files[i];
                                                    final name = f.uri.pathSegments.last;
                                                    return ListTile(
                                                      title: Text(name, style: TextStyle(color: t.textPrimary)),
                                                      trailing: FaIcon(
                                                        FontAwesomeIcons.chevronRight,
                                                        color: t.divider,
                                                        size: 14,
                                                      ),
                                                      onTap: () => Navigator.of(ctx).pop(f),
                                                    );
                                                  },
                                                ),
                                              ),
                                            ],
                                          ),
                                        );
                                      },
                                    );

                                    if (selected != null) {
                                      final result = await Share.shareXFiles(
                                        [XFile(selected.path)],
                                        text: 'Omi debug log',
                                        sharePositionOrigin: _shareOrigin(),
                                      );
                                      if (result.status == ShareResultStatus.success) {
                                        Logger.debug('Log shared');
                                      }
                                    }
                                  },
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(vertical: 12),
                                    decoration: BoxDecoration(
                                      color: t.bgTertiary,
                                      borderRadius: BorderRadius.circular(10),
                                    ),
                                    child: Row(
                                      mainAxisAlignment: MainAxisAlignment.center,
                                      children: [
                                        FaIcon(FontAwesomeIcons.fileArrowUp, color: t.textSecondary, size: 16),
                                        const SizedBox(width: 8),
                                        Text(
                                          context.l10n.shareLogs,
                                          style: TextStyle(
                                            color: t.textSecondary,
                                            fontSize: 14,
                                            fontWeight: FontWeight.w500,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 12),
                              GestureDetector(
                                onTap: () async {
                                  final message = context.l10n.debugLogCleared;
                                  await DebugLogManager.clear();
                                  if (!context.mounted) return;
                                  AppSnackbar.showSnackbar(message);
                                },
                                child: Container(
                                  padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
                                  decoration: BoxDecoration(
                                    color: t.error.withValues(alpha: 0.15),
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                  child: Row(
                                    children: [
                                      FaIcon(FontAwesomeIcons.trash, color: t.error, size: 14),
                                      const SizedBox(width: 6),
                                      Text(
                                        context.l10n.clear,
                                        style: TextStyle(
                                          color: t.error,
                                          fontSize: 14,
                                          fontWeight: FontWeight.w500,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  GestureDetector(
                    onTap: provider.loadingExportMemories
                        ? null
                        : () async {
                            if (provider.loadingExportMemories) return;
                            // Capture l10n before async gaps
                            final exportTitle = context.l10n.exportAllData;
                            setState(() => provider.loadingExportMemories = true);
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(context.l10n.exportStartedMayTakeFewSeconds),
                                duration: const Duration(seconds: 3),
                              ),
                            );
                            final directory = await getApplicationDocumentsDirectory();
                            final filePath = '${directory.path}/omi-export.json';
                            final exportedPath = await exportUserDataToFile(filePath);
                            if (exportedPath == null) {
                              // Always reset the flag so the button is re-enabled even if widget is unmounted
                              provider.loadingExportMemories = false;
                              if (context.mounted) {
                                ScaffoldMessenger.of(
                                  context,
                                ).showSnackBar(const SnackBar(content: Text('Export failed. Please try again.')));
                                setState(() {});
                              }
                              return;
                            }

                            final result = await Share.shareXFiles(
                              [XFile(exportedPath)],
                              subject: exportTitle,
                              text: exportTitle,
                              sharePositionOrigin: _shareOrigin(),
                            );
                            if (result.status == ShareResultStatus.success) {
                              Logger.debug('Export shared');
                            }
                            PlatformManager.instance.analytics.exportMemories();
                            // Always reset the flag so the button is re-enabled even if widget is unmounted
                            provider.loadingExportMemories = false;
                            if (mounted) setState(() {});
                          },
                    child: Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: t.bgSecondary,
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Row(
                        children: [
                          SettingsIconChip.boxed(
                              icon: (size) => FaIcon(FontAwesomeIcons.fileExport, color: t.textSecondary, size: size)),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  context.l10n.exportAllData,
                                  style: TextStyle(
                                    color: t.textPrimary,
                                    fontSize: 16,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  context.l10n.exportConversationsToJson,
                                  style: TextStyle(color: t.textSecondary, fontSize: 13),
                                ),
                              ],
                            ),
                          ),
                          if (provider.loadingExportMemories)
                            SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2, color: t.textPrimary),
                            )
                          else
                            FaIcon(FontAwesomeIcons.chevronRight, color: t.textSecondary, size: 16),
                        ],
                      ),
                    ),
                  ),

                  const SizedBox(height: 32),

                  // Knowledge Graph Section
                  GestureDetector(
                    onTap: () {
                      showDialog(
                        context: context,
                        builder: (ctx) => AlertDialog(
                          backgroundColor: t.bgSecondary,
                          title: Text(
                            context.l10n.deleteKnowledgeGraphQuestion,
                            style: TextStyle(color: t.textPrimary),
                          ),
                          content: Text(
                            context.l10n.knowledgeGraphDeleteDescription,
                            style: TextStyle(color: t.textSecondary),
                          ),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.of(ctx).pop(),
                              child: Text(context.l10n.cancel, style: TextStyle(color: t.textSecondary)),
                            ),
                            TextButton(
                              onPressed: () async {
                                Navigator.of(ctx).pop();
                                try {
                                  // Call delete endpoint
                                  await KnowledgeGraphApi.deleteKnowledgeGraph();
                                  if (context.mounted) {
                                    AppSnackbar.showSnackbar(context.l10n.knowledgeGraphDeletedSuccessfully);
                                  }
                                } catch (e) {
                                  if (context.mounted) {
                                    AppSnackbar.showSnackbarError(context.l10n.failedToDeleteGraph(e.toString()));
                                  }
                                }
                              },
                              child: Text(context.l10n.delete, style: TextStyle(color: t.error)),
                            ),
                          ],
                        ),
                      );
                    },
                    child: Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: t.bgSecondary,
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Row(
                        children: [
                          SettingsIconChip.boxed(
                              icon: (size) => FaIcon(FontAwesomeIcons.trash, color: t.error, size: size)),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  context.l10n.deleteKnowledgeGraph,
                                  style: TextStyle(
                                    color: t.textPrimary,
                                    fontSize: 16,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  context.l10n.clearAllNodesAndConnections,
                                  style: TextStyle(color: t.textSecondary, fontSize: 13),
                                ),
                              ],
                            ),
                          ),
                          FaIcon(FontAwesomeIcons.chevronRight, color: t.textSecondary, size: 14),
                        ],
                      ),
                    ),
                  ),

                  const SizedBox(height: 32),

                  // Developer API Keys Section
                  const DeveloperApiKeysSection(),

                  const SizedBox(height: 32),

                  // MCP Section
                  Padding(
                    padding: const EdgeInsets.only(left: 4, right: 4, bottom: 12),
                    child: Row(
                      children: [
                        Text(
                          context.l10n.mcp,
                          style: TextStyle(color: t.textPrimary, fontSize: 20, fontWeight: FontWeight.w600),
                        ),
                        const Spacer(),
                        _buildDocsButton('https://docs.omi.me/doc/developer/MCP', 'MCP'),
                        const SizedBox(width: 8),
                        _buildCreateKeyButton(
                          () => showDialog(context: context, builder: (context) => const CreateMcpApiKeyDialog()),
                        ),
                      ],
                    ),
                  ),
                  _buildApiKeysList(context),

                  const SizedBox(height: 24),

                  // Claude Desktop Integration
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(color: t.bgSecondary, borderRadius: BorderRadius.circular(14)),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            SettingsIconChip.boxed(
                                icon: (size) => FaIcon(FontAwesomeIcons.desktop, color: t.textSecondary, size: size)),
                            const SizedBox(width: 14),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    context.l10n.claudeDesktop,
                                    style: TextStyle(
                                      color: t.textPrimary,
                                      fontSize: 16,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    context.l10n.addToClaudeDesktopConfig,
                                    style: TextStyle(color: t.textSecondary, fontSize: 13),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),
                        // Code block with JSON syntax highlighting
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: t.bgPrimary,
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: t.bgTertiary, width: 1),
                          ),
                          child: RichText(
                            text: TextSpan(
                              style: const TextStyle(fontFamily: 'Ubuntu Mono', fontSize: 11, height: 1.6),
                              children: [
                                TextSpan(
                                  text: '{\n',
                                  style: TextStyle(color: t.textPrimary),
                                ),
                                TextSpan(
                                  text: '  ',
                                  style: TextStyle(color: t.textPrimary),
                                ),
                                TextSpan(
                                  text: '"mcpServers"',
                                  style: TextStyle(color: Colors.cyan.shade300),
                                ),
                                TextSpan(
                                  text: ': {\n',
                                  style: TextStyle(color: t.textPrimary),
                                ),
                                TextSpan(
                                  text: '    ',
                                  style: TextStyle(color: t.textPrimary),
                                ),
                                TextSpan(
                                  text: '"omi"',
                                  style: TextStyle(color: Colors.cyan.shade300),
                                ),
                                TextSpan(
                                  text: ': {\n',
                                  style: TextStyle(color: t.textPrimary),
                                ),
                                TextSpan(
                                  text: '      ',
                                  style: TextStyle(color: t.textPrimary),
                                ),
                                TextSpan(
                                  text: '"command"',
                                  style: TextStyle(color: Colors.cyan.shade300),
                                ),
                                TextSpan(
                                  text: ': ',
                                  style: TextStyle(color: t.textPrimary),
                                ),
                                TextSpan(
                                  text: '"docker"',
                                  style: TextStyle(color: t.warning),
                                ),
                                TextSpan(
                                  text: ',\n',
                                  style: TextStyle(color: t.textPrimary),
                                ),
                                TextSpan(
                                  text: '      ',
                                  style: TextStyle(color: t.textPrimary),
                                ),
                                TextSpan(
                                  text: '"args"',
                                  style: TextStyle(color: Colors.cyan.shade300),
                                ),
                                TextSpan(
                                  text: ': [\n',
                                  style: TextStyle(color: t.textPrimary),
                                ),
                                TextSpan(
                                  text: '        ',
                                  style: TextStyle(color: t.textPrimary),
                                ),
                                TextSpan(
                                  text: '"run"',
                                  style: TextStyle(color: t.warning),
                                ),
                                TextSpan(
                                  text: ', ',
                                  style: TextStyle(color: t.textPrimary),
                                ),
                                TextSpan(
                                  text: '"--rm"',
                                  style: TextStyle(color: t.warning),
                                ),
                                TextSpan(
                                  text: ', ',
                                  style: TextStyle(color: t.textPrimary),
                                ),
                                TextSpan(
                                  text: '"-i"',
                                  style: TextStyle(color: t.warning),
                                ),
                                TextSpan(
                                  text: ', ',
                                  style: TextStyle(color: t.textPrimary),
                                ),
                                TextSpan(
                                  text: '"-e"',
                                  style: TextStyle(color: t.warning),
                                ),
                                TextSpan(
                                  text: ',\n',
                                  style: TextStyle(color: t.textPrimary),
                                ),
                                TextSpan(
                                  text: '        ',
                                  style: TextStyle(color: t.textPrimary),
                                ),
                                TextSpan(
                                  text: '"OMI_API_KEY=<your_key>"',
                                  style: TextStyle(color: t.warning),
                                ),
                                TextSpan(
                                  text: ',\n',
                                  style: TextStyle(color: t.textPrimary),
                                ),
                                TextSpan(
                                  text: '        ',
                                  style: TextStyle(color: t.textPrimary),
                                ),
                                TextSpan(
                                  text: '"omiai/mcp-server:latest"',
                                  style: TextStyle(color: t.warning),
                                ),
                                TextSpan(
                                  text: '\n      ]\n    }\n  }\n}',
                                  style: TextStyle(color: t.textPrimary),
                                ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                        GestureDetector(
                          onTap: () {
                            const config = '''{
  "mcpServers": {
    "omi": {
      "command": "docker",
      "args": ["run", "--rm", "-i", "-e", "OMI_API_KEY=your_api_key_here", "omiai/mcp-server:latest"]
    }
  }
}''';
                            Clipboard.setData(const ClipboardData(text: config));
                            AppSnackbar.showSnackbar(context.l10n.configCopiedToClipboard);
                          },
                          child: Container(
                            width: double.infinity,
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            decoration: BoxDecoration(
                              color: t.bgTertiary,
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                FaIcon(FontAwesomeIcons.copy, color: t.textSecondary, size: 14),
                                const SizedBox(width: 8),
                                Text(
                                  context.l10n.copyConfig,
                                  style: TextStyle(
                                    color: t.textSecondary,
                                    fontSize: 14,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 24),

                  // MCP Server Section
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(color: t.bgSecondary, borderRadius: BorderRadius.circular(14)),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            SettingsIconChip.boxed(
                                icon: (size) => FaIcon(FontAwesomeIcons.server, color: t.textSecondary, size: size)),
                            const SizedBox(width: 14),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    context.l10n.mcpServer,
                                    style: TextStyle(
                                      color: t.textPrimary,
                                      fontSize: 16,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    context.l10n.connectAiAssistantsToYourData,
                                    style: TextStyle(color: t.textSecondary, fontSize: 13),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 20),

                        // Server URL
                        Text(
                          context.l10n.serverUrl,
                          style: TextStyle(color: t.textSecondary, fontSize: 12, fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 8),
                        Builder(
                          builder: (context) {
                            final mcpUrl = '${Env.apiBaseUrl}v1/mcp/sse';
                            return GestureDetector(
                              onTap: () {
                                Clipboard.setData(ClipboardData(text: mcpUrl));
                                AppSnackbar.showSnackbar(context.l10n.urlCopied);
                              },
                              child: Container(
                                width: double.infinity,
                                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                                decoration: BoxDecoration(
                                  color: t.bgPrimary,
                                  borderRadius: BorderRadius.circular(10),
                                  border: Border.all(color: t.bgTertiary, width: 1),
                                ),
                                child: Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        mcpUrl,
                                        style: TextStyle(
                                          color: t.textPrimary,
                                          fontFamily: 'Ubuntu Mono',
                                          fontSize: 13,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    FaIcon(FontAwesomeIcons.copy, color: t.textSecondary, size: 14),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),

                        const SizedBox(height: 20),
                        Divider(color: t.textSecondary, height: 1),
                        const SizedBox(height: 20),

                        // API Key Auth Section
                        Text(
                          context.l10n.apiKeyAuth,
                          style: TextStyle(color: t.textSecondary, fontSize: 12, fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            Expanded(
                              flex: 2,
                              child: Text(
                                context.l10n.header,
                                style: TextStyle(color: t.textSecondary, fontSize: 13),
                              ),
                            ),
                            Expanded(
                              flex: 3,
                              child: Text(
                                'Authorization: Bearer <key>',
                                style: TextStyle(color: t.textSecondary, fontSize: 12, fontFamily: 'Ubuntu Mono'),
                              ),
                            ),
                          ],
                        ),

                        const SizedBox(height: 20),
                        Divider(color: t.textSecondary, height: 1),
                        const SizedBox(height: 20),

                        // OAuth Section
                        Text(
                          context.l10n.oAuth,
                          style: TextStyle(color: t.textSecondary, fontSize: 12, fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 12),

                        // Client ID
                        _buildMcpConfigRow(context.l10n.clientId, 'omi'),
                        const SizedBox(height: 8),

                        // Client Secret hint
                        Row(
                          children: [
                            Expanded(
                              flex: 2,
                              child: Text(
                                context.l10n.clientSecret,
                                style: TextStyle(color: t.textSecondary, fontSize: 13),
                              ),
                            ),
                            Expanded(
                              flex: 3,
                              child: Text(
                                context.l10n.useYourMcpApiKey,
                                style: TextStyle(
                                  color: t.textSecondary,
                                  fontSize: 13,
                                  fontStyle: FontStyle.italic,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 32),

                  // Webhooks Section
                  Padding(
                    padding: const EdgeInsets.only(left: 4, right: 4, bottom: 12),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          context.l10n.webhooks,
                          style: TextStyle(color: t.textPrimary, fontSize: 20, fontWeight: FontWeight.w600),
                        ),
                        _buildDocsButton('https://docs.omi.me/doc/developer/apps/Introduction', 'Webhooks'),
                      ],
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(color: t.bgSecondary, borderRadius: BorderRadius.circular(14)),
                    child: Column(
                      children: [
                        // Conversation Events
                        _buildWebhookItem(
                          title: context.l10n.conversationEvents,
                          description: context.l10n.newConversationCreated,
                          icon: FontAwesomeIcons.message,
                          isEnabled: provider.conversationEventsToggled,
                          onToggle: provider.onConversationEventsToggled,
                          controller: provider.webhookOnConversationCreated,
                        ),
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          child: Divider(color: t.textSecondary, height: 1),
                        ),
                        // Real-time Transcript
                        _buildWebhookItem(
                          title: context.l10n.realTimeTranscript,
                          description: context.l10n.transcriptReceived,
                          icon: FontAwesomeIcons.closedCaptioning,
                          isEnabled: provider.transcriptsToggled,
                          onToggle: provider.onTranscriptsToggled,
                          controller: provider.webhookOnTranscriptReceived,
                        ),
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          child: Divider(color: t.textSecondary, height: 1),
                        ),
                        // Realtime Audio Bytes
                        _buildWebhookItem(
                          title: context.l10n.audioBytes,
                          description: context.l10n.audioDataReceived,
                          icon: FontAwesomeIcons.waveSquare,
                          isEnabled: provider.audioBytesToggled,
                          onToggle: provider.onAudioBytesToggled,
                          controller: provider.webhookAudioBytes,
                          extraField: _buildTextField(
                            controller: provider.webhookAudioBytesDelay,
                            label: context.l10n.intervalSeconds,
                            keyboardType: TextInputType.number,
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          child: Divider(color: t.textSecondary, height: 1),
                        ),
                        // Day Summary
                        _buildWebhookItem(
                          title: context.l10n.daySummary,
                          description: context.l10n.summaryGenerated,
                          icon: FontAwesomeIcons.calendarDay,
                          isEnabled: provider.daySummaryToggled,
                          onToggle: provider.onDaySummaryToggled,
                          controller: provider.webhookDaySummary,
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 32),

                  // Experimental Section
                  Padding(
                    padding: const EdgeInsets.only(left: 4, right: 4, bottom: 12),
                    child: Text(
                      context.l10n.experimental,
                      style: TextStyle(color: t.textPrimary, fontSize: 20, fontWeight: FontWeight.w600),
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(color: t.bgSecondary, borderRadius: BorderRadius.circular(14)),
                    child: Column(
                      children: [
                        // Transcription Diagnostics
                        _buildExperimentalItem(
                          title: context.l10n.transcriptionDiagnostics,
                          description: context.l10n.detailedDiagnosticMessages,
                          icon: FontAwesomeIcons.stethoscope,
                          value: provider.transcriptionDiagnosticEnabled,
                          onChanged: provider.onTranscriptionDiagnosticChanged,
                        ),
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          child: Divider(color: t.textSecondary, height: 1),
                        ),
                        // Auto-create Speakers
                        _buildExperimentalItem(
                          title: context.l10n.autoCreateSpeakers,
                          description: context.l10n.autoCreateWhenNameDetected,
                          icon: FontAwesomeIcons.userPlus,
                          value: provider.autoCreateSpeakersEnabled,
                          onChanged: provider.onAutoCreateSpeakersChanged,
                        ),
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          child: Divider(color: t.textSecondary, height: 1),
                        ),
                        // VAD Gate
                        _buildExperimentalItem(
                          title: 'VAD Gate',
                          description: 'Server-side voice gating to reduce STT costs',
                          icon: FontAwesomeIcons.microphoneSlash,
                          value: provider.vadGateEnabled,
                          onChanged: provider.onVadGateChanged,
                        ),
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          child: Divider(color: Colors.grey.shade800, height: 1),
                        ),
                        // PTT Hub — тумблер СКРЫТ (решение Игоря 24.08): удержание
                        // кнопки кулона занято питанием самого кулона, push-to-talk
                        // конфликтовал с одиночным нажатием и не нужен. Геттер
                        // pttHubEnabled прибит к false (preferences.dart); разговор
                        // запускается одиночным/двойным нажатием (настройки кулона).
                        // Free-form Voice Mode
                        _buildExperimentalItem(
                          title: 'Free-form Voice Mode (chat button)',
                          description: 'Shows a hands-free voice-mode button in chat',
                          icon: FontAwesomeIcons.waveSquare,
                          value: provider.freeFormMode,
                          onChanged: provider.onFreeFormModeChanged,
                        ),
                        // Auto-off for the mode above. Shown even while the
                        // flag is off (it is what the mode WILL use), but
                        // greyed out so it does not read as live.
                        const SizedBox(height: 16),
                        _buildFreeFormVoiceTimeoutItem(provider),
                        // Оформление живой иконки в чате: работает независимо
                        // от флага режима — иконку рисует любой голосовой ход.
                        const SizedBox(height: 16),
                        _buildVoiceOrbThemeItem(provider),
                        // Ползунок «мозг голосового режима» (0 = чистый Gemini
                        // Live, 4 = каждый ответ через Claude) СКРЫТ вместе с
                        // шторкой в чате: на правом крае модель «двоилась»
                        // (см. claudeEscalationSliderEnabled). Код сохранён.
                        if (claudeEscalationSliderEnabled) ...[
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 16),
                            child: Divider(color: Colors.grey.shade800, height: 1),
                          ),
                          _buildClaudeEscalationItem(provider),
                        ],
                      ],
                    ),
                  ),

                  // Home Screen Section
                  const SizedBox(height: 32),
                  Padding(
                    padding: const EdgeInsets.only(left: 4, right: 4, bottom: 12),
                    child: Text(
                      'Home Screen',
                      style: TextStyle(color: t.textPrimary, fontSize: 20, fontWeight: FontWeight.w600),
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(color: t.bgSecondary, borderRadius: BorderRadius.circular(14)),
                    child: Column(
                      children: [
                        _buildExperimentalItem(
                          title: context.l10n.goalTracker,
                          description: context.l10n.trackYourGoalsOnHomepage,
                          icon: FontAwesomeIcons.bullseye,
                          value: provider.showGoalTrackerEnabled,
                          onChanged: provider.onShowGoalTrackerChanged,
                        ),
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          child: Divider(color: t.textSecondary, height: 1),
                        ),
                        _buildExperimentalItem(
                          title: context.l10n.dailyScore,
                          description: context.l10n.showDailyScoreOnHomepage,
                          icon: FontAwesomeIcons.chartLine,
                          value: provider.showDailyScoreEnabled,
                          onChanged: provider.onShowDailyScoreChanged,
                        ),
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          child: Divider(color: t.textSecondary, height: 1),
                        ),
                        _buildExperimentalItem(
                          title: context.l10n.tasks,
                          description: context.l10n.showTasksOnHomepage,
                          icon: FontAwesomeIcons.listCheck,
                          value: provider.showTasksEnabled,
                          onChanged: provider.onShowTasksChanged,
                        ),
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          child: Divider(color: t.textSecondary, height: 1),
                        ),
                        _buildExperimentalItem(
                          title: context.l10n.showPhoneCallButtonTitle,
                          description: context.l10n.showPhoneCallButtonDesc,
                          icon: FontAwesomeIcons.phone,
                          value: provider.showPhoneCallButton,
                          onChanged: provider.onShowPhoneCallButtonChanged,
                        ),
                      ],
                    ),
                  ),

                  // Manual Firmware Flash (only when device connected)
                  Builder(
                    builder: (context) {
                      final deviceProvider = context.watch<DeviceProvider>();
                      if (FirmwareUpdateBuildPolicy.current.allowsOmiFirmwareUpdate &&
                          deviceProvider.isConnected &&
                          deviceProvider.pairedDevice != null) {
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const SizedBox(height: 24),
                            _buildSectionHeader('Firmware', subtitle: 'Flash custom firmware builds'),
                            const SizedBox(height: 8),
                            _buildManualFirmwareFlash(deviceProvider),
                          ],
                        );
                      }
                      return const SizedBox.shrink();
                    },
                  ),

                  const SizedBox(height: 48),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

// ============================================================
// Manual Firmware Flash Page
// ============================================================

class _ManualFirmwareFlashPage extends StatefulWidget {
  final String zipFilePath;
  final String fileName;
  final BtDevice device;

  const _ManualFirmwareFlashPage({required this.zipFilePath, required this.fileName, required this.device});

  @override
  State<_ManualFirmwareFlashPage> createState() => _ManualFirmwareFlashPageState();
}

class _ManualFirmwareFlashPageState extends State<_ManualFirmwareFlashPage> with FirmwareMixin {
  bool _confirmed = false;
  String? _error;

  @override
  void initState() {
    super.initState();
  }

  @override
  void dispose() {
    killMcuUpdateManager();
    super.dispose();
  }

  Future<void> _startFlash() async {
    setState(() {
      _confirmed = true;
      _error = null;
    });
    try {
      // Manual flash always uses MCU DFU — modern firmware ZIPs contain
      // manifest.json which NordicDfu (legacy) cannot parse.
      await startMCUDfu(widget.device, zipFilePath: widget.zipFilePath);
    } catch (e) {
      if (mounted) {
        setState(() => _error = e.toString());
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.omi;

    return Scaffold(
      backgroundColor: t.bgPrimary,
      appBar: AppBar(
        backgroundColor: t.bgPrimary,
        title: Text(context.l10n.flashFirmware, style: TextStyle(color: t.textPrimary)),
        iconTheme: IconThemeData(color: t.textPrimary),
        elevation: 0,
      ),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // File info
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(color: t.bgSecondary, borderRadius: BorderRadius.circular(12)),
              child: Row(
                children: [
                  FaIcon(FontAwesomeIcons.file, color: t.accent, size: 20),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.fileName,
                          style: TextStyle(color: t.textPrimary, fontSize: 16, fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Target: ${widget.device.name}',
                          style: TextStyle(color: t.textSecondary, fontSize: 13),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),

            // Warning
            if (!_confirmed) ...[
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: t.warning.withValues(alpha: 0.3),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: t.warning.withValues(alpha: 0.5)),
                ),
                child: Row(
                  children: [
                    OmiIconWidget(icon: OmiIcon.warning, color: t.warning, size: 24),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'Flashing custom firmware can brick your device. Make sure this is a valid Omi firmware build. Do not disconnect during the update.',
                        style: TextStyle(color: t.warning, fontSize: 13),
                      ),
                    ),
                  ],
                ),
              ),
              const Spacer(),
              SizedBox(
                width: double.infinity,
                height: 52,
                child: ElevatedButton(
                  onPressed: _startFlash,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: t.accent,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  child: Text(
                    context.l10n.flashFirmware,
                    style: TextStyle(color: t.textPrimary, fontSize: 16, fontWeight: FontWeight.w600),
                  ),
                ),
              ),
            ],

            // Progress
            if (_confirmed && !isInstalled) ...[
              const SizedBox(height: 16),
              Text(
                isInstalling ? 'Installing...' : 'Preparing...',
                style: TextStyle(color: t.textPrimary, fontSize: 18, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 16),
              LinearProgressIndicator(
                value: installProgress / 100,
                backgroundColor: t.bgTertiary,
                valueColor: AlwaysStoppedAnimation<Color>(t.accent),
                minHeight: 8,
                borderRadius: BorderRadius.circular(4),
              ),
              const SizedBox(height: 8),
              Text('${installProgress}%', style: TextStyle(color: t.textSecondary, fontSize: 14)),
            ],

            // Success
            if (isInstalled) ...[
              const SizedBox(height: 32),
              Center(
                child: Column(
                  children: [
                    OmiIconWidget(icon: OmiIcon.checkCircle, color: t.success, size: 64),
                    const SizedBox(height: 16),
                    Text(
                      'Firmware flashed successfully!',
                      style: TextStyle(color: t.textPrimary, fontSize: 18, fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 8),
                    Text('Your device will restart.', style: TextStyle(color: t.textSecondary, fontSize: 14)),
                  ],
                ),
              ),
            ],

            // Error
            if (_error != null) ...[
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: t.error.withValues(alpha: 0.3),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(_error!, style: TextStyle(color: t.error, fontSize: 13)),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
