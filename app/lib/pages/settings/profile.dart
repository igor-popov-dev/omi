import 'package:omi/utils/platform/platform_manager.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:omi/backend/preferences.dart';
import 'package:omi/providers/capture_provider.dart';
import 'package:omi/pages/memories/page.dart';
import 'package:provider/provider.dart';
import 'package:omi/pages/settings/change_name_widget.dart';
import 'package:omi/pages/settings/language_settings_page.dart';
import 'package:omi/pages/settings/custom_vocabulary_page.dart';
import 'package:omi/pages/settings/people.dart';
import 'package:omi/pages/speech_profile/page.dart';

import 'package:omi/utils/alerts/app_snackbar.dart';
import 'package:omi/utils/l10n_extensions.dart';
import 'package:omi/utils/other/temp.dart';
import 'package:omi/utils/platform/platform_service.dart';

import 'delete_account.dart';
import 'package:omi/utils/theme/omi_tokens.dart';

class ProfilePage extends StatefulWidget {
  const ProfilePage({super.key});

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  @override
  void initState() {
    super.initState();
  }

  Widget _buildSectionContainer({required List<Widget> children}) {
    final t = context.omi;

    return Container(
      decoration: BoxDecoration(color: t.bgSecondary, borderRadius: BorderRadius.circular(20)),
      child: Column(children: children),
    );
  }

  Widget _buildProfileItem({
    required String title,
    String? subtitle,
    String? chipValue,
    required Widget icon,
    required VoidCallback onTap,
    bool showSubtitle = true,
    bool showBetaTag = false,
    bool showChevron = true,
  }) {
    final t = context.omi;

    return GestureDetector(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(color: t.bgSecondary, borderRadius: BorderRadius.circular(20)),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
          child: Row(
            children: [
              SizedBox(width: 24, height: 24, child: icon),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          title,
                          style: TextStyle(color: t.textPrimary, fontSize: 17, fontWeight: FontWeight.w400),
                        ),
                        if (showBetaTag) ...[
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                            decoration: BoxDecoration(
                              color: t.warning.withValues(alpha: 0.2),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Text(
                              'BETA',
                              style: TextStyle(
                                color: t.warning,
                                fontSize: 10,
                                fontWeight: FontWeight.w600,
                                letterSpacing: 0.5,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    if (showSubtitle && subtitle != null && chipValue == null) ...[
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        style: TextStyle(color: t.textSecondary, fontSize: 12, fontWeight: FontWeight.w400),
                      ),
                    ],
                  ],
                ),
              ),
              if (chipValue != null) ...[
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(color: t.bgTertiary, borderRadius: BorderRadius.circular(100)),
                  child: Text(
                    chipValue,
                    style: TextStyle(color: t.textPrimary, fontSize: 13, fontWeight: FontWeight.w500),
                  ),
                ),
                if (showChevron) const SizedBox(width: 8),
              ],
              if (showChevron) Icon(Icons.chevron_right, color: t.divider, size: 20),
            ],
          ),
        ),
      ),
    );
  }

  String _voiceResponseModeLabel(int mode) {
    switch (mode) {
      case 0:
        return context.l10n.voiceResponseOff;
      case 2:
        return context.l10n.voiceResponseAlways;
      case 1:
      default:
        return context.l10n.voiceResponseHeadphonesOnly;
    }
  }

  void _showVoiceResponseModeSheet() {
    final t = context.omi;

    int current = SharedPreferencesUtil().voiceResponseMode;
    showModalBottomSheet(
      context: context,
      backgroundColor: t.bgSecondary,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            void pick(int value) {
              setState(() => SharedPreferencesUtil().voiceResponseMode = value);
              PlatformManager.instance.analytics.voiceResponseModeChanged(value);
              Navigator.pop(sheetContext);
            }

            return SafeArea(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    margin: const EdgeInsets.only(top: 12, bottom: 16),
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(color: t.divider, borderRadius: BorderRadius.circular(2)),
                  ),
                  Text(
                    context.l10n.voiceResponseModeTitle,
                    style: TextStyle(color: t.textPrimary, fontSize: 17, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 16),
                  ListTile(
                    title: Text(
                      context.l10n.voiceResponseOff,
                      style: TextStyle(color: t.textPrimary, fontWeight: FontWeight.w400),
                    ),
                    trailing: current == 0 ? Icon(Icons.check, color: t.textPrimary, size: 20) : null,
                    onTap: () => pick(0),
                  ),
                  ListTile(
                    title: Text(
                      context.l10n.voiceResponseHeadphonesOnly,
                      style: TextStyle(color: t.textPrimary, fontWeight: FontWeight.w400),
                    ),
                    trailing: current == 1 ? Icon(Icons.check, color: t.textPrimary, size: 20) : null,
                    onTap: () => pick(1),
                  ),
                  ListTile(
                    title: Text(
                      context.l10n.voiceResponseAlways,
                      style: TextStyle(color: t.textPrimary, fontWeight: FontWeight.w400),
                    ),
                    trailing: current == 2 ? Icon(Icons.check, color: t.textPrimary, size: 20) : null,
                    onTap: () => pick(2),
                  ),
                  const SizedBox(height: 16),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildProfileStyleItem({
    required FaIconData icon,
    required String title,
    String? chipValue,
    VoidCallback? onTap,
  }) {
    final t = context.omi;

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
        child: Row(
          children: [
            SizedBox(width: 24, height: 24, child: FaIcon(icon, color: t.textSecondary, size: 20)),
            const SizedBox(width: 16),
            Expanded(
              child: Text(
                title,
                style: TextStyle(color: t.textPrimary, fontSize: 17, fontWeight: FontWeight.w400),
              ),
            ),
            if (chipValue != null) ...[
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(color: t.bgTertiary, borderRadius: BorderRadius.circular(100)),
                child: Text(
                  chipValue,
                  style: TextStyle(color: t.textPrimary, fontSize: 13, fontWeight: FontWeight.w500),
                ),
              ),
              const SizedBox(width: 8),
            ],
            Icon(Icons.chevron_right, color: t.divider, size: 20),
          ],
        ),
      ),
    );
  }

  void _showBackgroundModeSheet() {
    final t = context.omi;

    showModalBottomSheet(
      context: context,
      backgroundColor: t.bgSecondary,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            final captureProvider = context.read<CaptureProvider>();
            final enabled = SharedPreferencesUtil().backgroundModeEnabled;
            final canEnable = captureProvider.hasNativeBackgroundStreamRoute;
            void setEnabled(bool value) async {
              if (value && !canEnable) return;
              final accepted = await captureProvider.setBackgroundModeEnabled(value);
              if (accepted) {
                setSheetState(() {});
                setState(() {});
              }
            }

            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Center(
                      child: Container(
                        margin: const EdgeInsets.only(bottom: 16),
                        width: 36,
                        height: 4,
                        decoration: BoxDecoration(
                          color: t.divider,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            context.l10n.backgroundModeTitle,
                            style: TextStyle(color: t.textPrimary, fontSize: 18, fontWeight: FontWeight.w600),
                          ),
                        ),
                        Switch(
                          value: enabled,
                          activeThumbColor: t.textPrimary,
                          activeTrackColor: t.accent,
                          onChanged: (enabled || canEnable) ? (v) => setEnabled(v) : null,
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      context.l10n.backgroundModeDescription,
                      style: TextStyle(color: t.textSecondary, fontSize: 14, height: 1.4),
                    ),
                    const SizedBox(height: 16),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: t.bgTertiary,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(Icons.info_outline, color: t.textSecondary, size: 18),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              context.l10n.backgroundModeNote,
                              style: TextStyle(color: t.textSecondary, fontSize: 13, height: 1.4),
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (!canEnable) ...[
                      const SizedBox(height: 12),
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: const Color(0xFF3A2A2A),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(Icons.warning_amber_rounded, color: t.warning, size: 18),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                context.l10n.backgroundModeUnavailable,
                                style: TextStyle(color: t.warning, fontSize: 13, height: 1.4),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  void _showOfflineModeSheet() {
    final t = context.omi;

    final captureProvider = context.read<CaptureProvider>();
    showModalBottomSheet(
      context: context,
      backgroundColor: t.bgSecondary,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            final enabled = SharedPreferencesUtil().batchModeEnabled;
            Future<void> setEnabled(bool value) async {
              final accepted = await captureProvider.setBatchMode(value);
              if (!accepted && context.mounted) {
                AppSnackbar.showSnackbarError(context.l10n.transcribeLaterNote);
              }
              if (sheetContext.mounted) {
                setSheetState(() {});
              }
              if (mounted) {
                setState(() {});
              }
            }

            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Center(
                      child: Container(
                        margin: const EdgeInsets.only(bottom: 16),
                        width: 36,
                        height: 4,
                        decoration: BoxDecoration(
                          color: t.divider,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            context.l10n.transcribeLaterTitle,
                            style: TextStyle(color: t.textPrimary, fontSize: 18, fontWeight: FontWeight.w600),
                          ),
                        ),
                        Switch(
                          value: enabled,
                          activeThumbColor: t.textPrimary,
                          activeTrackColor: t.accent,
                          onChanged: (v) => setEnabled(v),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      context.l10n.transcribeLaterDescription,
                      style: TextStyle(color: t.textSecondary, fontSize: 14, height: 1.4),
                    ),
                    const SizedBox(height: 16),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: t.bgTertiary,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(Icons.info_outline, color: t.textSecondary, size: 18),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              context.l10n.transcribeLaterNote,
                              style: TextStyle(color: t.textSecondary, fontSize: 13, height: 1.4),
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (SharedPreferencesUtil().getBool('batchStorageFull')) ...[
                      const SizedBox(height: 12),
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: const Color(0xFF3A2A2A),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(Icons.warning_amber_rounded, color: t.warning, size: 18),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                context.l10n.transcribeLaterStorageFull,
                                style: TextStyle(color: t.warning, fontSize: 13, height: 1.4),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = context.omi;

    return Scaffold(
      backgroundColor: t.bgPrimary,
      appBar: AppBar(
        title: Text(
          context.l10n.profile,
          style: TextStyle(color: t.textPrimary, fontSize: 18, fontWeight: FontWeight.w600),
        ),
        centerTitle: true,
        backgroundColor: t.bgPrimary,
        elevation: 0,
        iconTheme: IconThemeData(color: t.textPrimary),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: Column(
          children: <Widget>[
            const SizedBox(height: 20),

            // YOUR INFORMATION SECTION
            _buildSectionContainer(
              children: [
                _buildProfileItem(
                  title: context.l10n.name,
                  chipValue: SharedPreferencesUtil().givenName.isEmpty
                      ? context.l10n.notSet
                      : SharedPreferencesUtil().givenName,
                  icon: FaIcon(FontAwesomeIcons.solidUser, color: t.textSecondary, size: 20),
                  onTap: () async {
                    PlatformManager.instance.analytics.pageOpened('Profile Change Name');
                    await showDialog(
                      context: context,
                      builder: (BuildContext context) {
                        return const ChangeNameWidget();
                      },
                    ).whenComplete(() => setState(() {}));
                  },
                ),
                Divider(height: 1, color: t.divider),
                _buildProfileItem(
                  title: context.l10n.email,
                  chipValue:
                      SharedPreferencesUtil().email.isEmpty ? context.l10n.notSet : SharedPreferencesUtil().email,
                  icon: FaIcon(FontAwesomeIcons.solidEnvelope, color: t.textSecondary, size: 20),
                  onTap: () {},
                  showChevron: false,
                ),
                Divider(height: 1, color: t.divider),
                _buildProfileItem(
                  title: context.l10n.language,
                  icon: FaIcon(FontAwesomeIcons.globe, color: t.textSecondary, size: 20),
                  onTap: () {
                    routeToPage(context, const LanguageSettingsPage());
                  },
                ),
                Divider(height: 1, color: t.divider),
                _buildProfileItem(
                  title: context.l10n.customVocabulary,
                  icon: FaIcon(FontAwesomeIcons.book, color: t.textSecondary, size: 20),
                  onTap: () {
                    routeToPage(context, const CustomVocabularyPage());
                  },
                ),
                Divider(height: 1, color: t.divider),
                _buildProfileItem(
                  title: context.l10n.memories,
                  icon: FaIcon(FontAwesomeIcons.brain, color: t.textSecondary, size: 20),
                  onTap: () {
                    routeToPage(context, const MemoriesPage());
                  },
                ),
              ],
            ),
            const SizedBox(height: 32),

            // VOICE & PEOPLE SECTION
            _buildSectionContainer(
              children: [
                _buildProfileItem(
                  title: context.l10n.speechProfile,
                  icon: FaIcon(FontAwesomeIcons.microphone, color: t.textSecondary, size: 20),
                  onTap: () {
                    routeToPage(context, const SpeechProfilePage());
                    PlatformManager.instance.analytics.pageOpened('Profile Speech Profile');
                  },
                ),
                Divider(height: 1, color: t.divider),
                _buildProfileItem(
                  title: context.l10n.identifyingOthers,
                  icon: FaIcon(FontAwesomeIcons.users, color: t.textSecondary, size: 20),
                  onTap: () {
                    routeToPage(context, const UserPeoplePage());
                  },
                ),
                Divider(height: 1, color: t.divider),
                _buildProfileStyleItem(
                  icon: FontAwesomeIcons.volumeHigh,
                  title: context.l10n.voiceResponseMode,
                  chipValue: _voiceResponseModeLabel(SharedPreferencesUtil().voiceResponseMode),
                  onTap: _showVoiceResponseModeSheet,
                ),
                if (PlatformService.isAndroid) ...[
                  Divider(height: 1, color: t.divider),
                  _buildProfileItem(
                    title: context.l10n.backgroundModeTitle,
                    icon: FaIcon(FontAwesomeIcons.towerBroadcast, color: t.textSecondary, size: 20),
                    showBetaTag: true,
                    chipValue: SharedPreferencesUtil().backgroundModeEnabled ? context.l10n.on : context.l10n.off,
                    onTap: _showBackgroundModeSheet,
                  ),
                ],
                Divider(height: 1, color: t.divider),
                _buildProfileItem(
                  title: context.l10n.transcribeLaterTitle,
                  icon: FaIcon(FontAwesomeIcons.floppyDisk, color: t.textSecondary, size: 20),
                  showBetaTag: true,
                  chipValue: SharedPreferencesUtil().batchModeEnabled ? context.l10n.on : context.l10n.off,
                  onTap: _showOfflineModeSheet,
                ),
              ],
            ),
            const SizedBox(height: 32),

            // ACCOUNT SECTION
            _buildSectionContainer(
              children: [
                Builder(
                  builder: (context) {
                    final uid = SharedPreferencesUtil().uid;
                    final truncatedUid =
                        uid.length > 6 ? '${uid.substring(0, 3)}•••••${uid.substring(uid.length - 3)}' : uid;
                    return _buildProfileItem(
                      title: context.l10n.userId,
                      chipValue: truncatedUid,
                      icon: FaIcon(FontAwesomeIcons.solidClipboard, color: t.textSecondary, size: 20),
                      onTap: () {
                        Clipboard.setData(ClipboardData(text: uid));
                        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(context.l10n.userIdCopied)));
                      },
                    );
                  },
                ),
                Divider(height: 1, color: t.divider),
                _buildProfileItem(
                  title: context.l10n.deleteAccountTitle,
                  icon: FaIcon(FontAwesomeIcons.exclamationTriangle, color: t.error, size: 20),
                  onTap: () {
                    PlatformManager.instance.analytics.pageOpened('Profile Delete Account Dialog');
                    Navigator.push(context, MaterialPageRoute(builder: (context) => const DeleteAccount()));
                  },
                ),
              ],
            ),
            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }
}
