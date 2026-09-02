import 'dart:io';
import 'package:omi/utils/platform/platform_manager.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:omi/app_globals.dart';
import 'package:omi/backend/preferences.dart';
import 'package:omi/core/app_shell.dart';
import 'package:omi/services/auth_service.dart';
import 'package:omi/pages/settings/appearance_settings_page.dart';
import 'package:omi/pages/settings/developer.dart';
import 'package:omi/pages/settings/notifications_settings_page.dart';
import 'package:omi/pages/settings/permissions_page.dart';
import 'package:omi/pages/settings/profile.dart';
import 'package:omi/pages/memories/page.dart';
import 'package:omi/pages/settings/integrations_page.dart';
import 'package:omi/pages/settings/usage_page.dart';
import 'package:omi/pages/settings/widgets/glass_icon_chip.dart';
import 'package:omi/pages/referral/referral_page.dart';
import 'package:omi/providers/device_provider.dart';
import 'package:omi/providers/usage_provider.dart';
import 'package:omi/utils/auth/clear_user_state.dart';
import 'package:omi/utils/other/temp.dart';
import 'package:omi/utils/platform/platform_service.dart';
import 'package:omi/utils/theme/glass_effects.dart';
import 'package:omi/utils/theme/omi_icons.dart';
import 'package:omi/utils/theme/omi_tokens.dart';
import 'package:omi/widgets/dialog.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';
import 'package:omi/utils/l10n_extensions.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:omi/backend/http/api/announcements.dart';
import 'package:omi/pages/announcements/changelog_sheet.dart';
import 'device_settings.dart';
import '../conversations/auto_sync_page.dart';
import '../conversations/sync_page.dart';

class _SearchableItem {
  final String title;
  final SettingsIconBuilder icon;
  final VoidCallback onTap;

  const _SearchableItem({required this.title, required this.icon, required this.onTap});
}

class SettingsDrawer extends StatefulWidget {
  const SettingsDrawer({super.key});

  @override
  State<SettingsDrawer> createState() => _SettingsDrawerState();

  static void show(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => const SettingsDrawer(),
    );
  }
}

class _SettingsDrawerState extends State<SettingsDrawer> {
  String? version;
  String? buildVersion;
  String? shortDeviceInfo;

  bool _isSearching = false;
  String _searchQuery = '';
  late TextEditingController _searchController;
  late FocusNode _searchFocusNode;

  @override
  void initState() {
    super.initState();
    _searchController = TextEditingController();
    _searchFocusNode = FocusNode();
    _loadAppAndDeviceInfo();
  }

  @override
  void dispose() {
    _searchController.dispose();
    _searchFocusNode.dispose();
    super.dispose();
  }

  Future<String> _getShortDeviceInfo() async {
    try {
      final deviceInfoPlugin = DeviceInfoPlugin();

      if (Platform.isAndroid) {
        final androidInfo = await deviceInfoPlugin.androidInfo;
        return '${androidInfo.brand} ${androidInfo.model} — Android ${androidInfo.version.release}';
      } else if (Platform.isIOS) {
        final iosInfo = await deviceInfoPlugin.iosInfo;
        return '${iosInfo.name} — iOS ${iosInfo.systemVersion}';
      } else {
        return context.l10n.unknownDevice;
      }
    } catch (e) {
      return context.l10n.unknownDevice;
    }
  }

  Future<void> _loadAppAndDeviceInfo() async {
    try {
      final packageInfo = await PackageInfo.fromPlatform();
      final shortDevice = await _getShortDeviceInfo();

      if (mounted) {
        setState(() {
          version = packageInfo.version;
          buildVersion = packageInfo.buildNumber.toString();
          shortDeviceInfo = shortDevice;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          shortDeviceInfo = context.l10n.unknownDevice;
        });
      }
    }
  }

  Widget _buildSettingsItem({
    required String title,
    required SettingsIconBuilder icon,
    required VoidCallback onTap,
    bool showBetaTag = false,
    bool showNewTag = false,
    Widget? trailingChip,
  }) {
    final t = context.omi;

    return GestureDetector(
      onTap: onTap,
      child: Container(
        // Glass follows the macOS "General" list: every row is its own card
        // with a gap, so the section around it stays transparent (see
        // [_buildSectionContainer]) and no second fill shows through the
        // corners. Classic keeps the 1px seam that made the rows read as one
        // slab.
        margin: EdgeInsets.only(bottom: t.isGlass ? 8 : 1),
        decoration: BoxDecoration(
          color: t.bgSecondary,
          borderRadius: BorderRadius.circular(t.isGlass ? t.settingsCardRadius : 20),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
          child: Row(
            children: [
              SettingsIconChip.plain(icon: icon),
              const SizedBox(width: 16),
              Expanded(
                child: Row(
                  children: [
                    Text(
                      title,
                      style: TextStyle(color: t.textPrimary, fontSize: 17, fontWeight: FontWeight.w400),
                    ),
                    if (showBetaTag) ...[
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: t.warning.withValues(alpha: 0.2),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(
                          context.l10n.beta,
                          style: TextStyle(
                            color: t.warning,
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                            letterSpacing: 0.5,
                          ),
                        ),
                      ),
                    ],
                    if (showNewTag) ...[
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: t.success.withValues(alpha: 0.2),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(
                          context.l10n.newTag,
                          style: TextStyle(
                            color: t.success,
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                            letterSpacing: 0.5,
                          ),
                        ),
                      ),
                    ],
                    if (trailingChip != null) ...[const SizedBox(width: 8), trailingChip],
                  ],
                ),
              ),
              OmiIconWidget(icon: OmiIcon.chevronRight, color: t.isGlass ? t.textTertiary : t.divider, size: 20),
            ],
          ),
        ),
      ),
    );
  }

  /// Groups rows into a section.
  ///
  /// Glass paints nothing here — each row is already a card, so a fill of its
  /// own would peek out from behind the row corners. Classic keeps the single
  /// rounded slab it has always drawn.
  Widget _buildSectionContainer({required List<Widget> children}) {
    final t = context.omi;

    if (t.isGlass) {
      return Column(children: children);
    }

    return Container(
      decoration: BoxDecoration(color: t.bgSecondary, borderRadius: BorderRadius.circular(20)),
      child: Column(children: children),
    );
  }

  /// Separator between two rows of a section: a hairline in Classic, nothing in
  /// Glass (the rows are separate cards there and the gap does the job).
  Widget _rowDivider() {
    final t = context.omi;
    if (t.isGlass) return const SizedBox.shrink();
    return Divider(height: 1, color: t.divider);
  }

  Widget _buildVersionInfoSection() {
    final t = context.omi;

    if (!Platform.isIOS && !Platform.isAndroid) {
      return const SizedBox.shrink();
    }

    final displayText = buildVersion != null ? '${version ?? ""} ($buildVersion)' : (version ?? '');

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(
          displayText,
          style: TextStyle(color: t.textSecondary, fontSize: 13, fontWeight: FontWeight.w400),
        ),
        const SizedBox(width: 2),
        GestureDetector(
          onTap: _copyVersionInfo,
          child: Container(
            padding: const EdgeInsets.all(2),
            child: OmiIconWidget(icon: OmiIcon.copy, size: 12, color: t.textSecondary),
          ),
        ),
      ],
    );
  }

  Future<void> _copyVersionInfo() async {
    final versionPart = buildVersion != null ? 'Omi AI ${version ?? ""} ($buildVersion)' : 'Omi AI ${version ?? ""}';
    final devicePart = shortDeviceInfo ?? context.l10n.unknownDevice;
    final fullVersionInfo = '$versionPart — $devicePart';

    await Clipboard.setData(ClipboardData(text: fullVersionInfo));

    if (mounted) {
      _showCopyNotification();
    }
  }

  void _showCopyNotification() {
    final t = context.omi;

    final overlay = Overlay.of(context);
    late OverlayEntry overlayEntry;

    overlayEntry = OverlayEntry(
      builder: (_) => Positioned(
        bottom: 20,
        left: 0,
        right: 0,
        child: Center(
          child: Material(
            color: Colors.transparent,
            child: Container(
              width: MediaQuery.of(context).size.width * 0.7,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: t.isGlass ? t.bgSecondary : Colors.black87,
                borderRadius: BorderRadius.circular(8),
                boxShadow: [
                  BoxShadow(color: Colors.black.withValues(alpha: 0.2), blurRadius: 4, offset: const Offset(0, 2)),
                ],
              ),
              child: Text(
                context.l10n.appAndDeviceCopied,
                textAlign: TextAlign.center,
                style: TextStyle(color: t.textPrimary, fontSize: 14),
              ),
            ),
          ),
        ),
      ),
    );

    overlay.insert(overlayEntry);

    Future.delayed(const Duration(seconds: 2), () {
      overlayEntry.remove();
    });
  }

  /// Leading icon of a settings row.
  ///
  /// Classic resolves [OmiTokens.textSecondary] to `#8E8E93` — the exact tint
  /// these rows have always used — so this stays pixel-identical there and
  /// picks up the ink tone under Glass.
  SettingsIconBuilder _rowIcon(BuildContext context, OmiIcon icon) {
    final color = context.omi.textSecondary;
    return (size) => OmiIconWidget(icon: icon, color: color, size: size);
  }

  List<_SearchableItem> _buildSearchableItems(BuildContext context) {
    final deviceProvider = Provider.of<DeviceProvider>(context, listen: false);

    void goToProfile() => routeToPage(context, const ProfilePage());
    void goToNotifications() => routeToPage(context, const NotificationsSettingsPage());
    void goToUsage() => Navigator.of(context).push(MaterialPageRoute(builder: (context) => const UsagePage()));
    void goToSync() {
      final page = SharedPreferencesUtil().deviceSupportsMultiFileSync ? const AutoSyncPage() : const SyncPage();
      Navigator.of(context).push(MaterialPageRoute(builder: (context) => page));
    }

    void goToDevice() => Navigator.of(context).push(MaterialPageRoute(builder: (context) => const DeviceSettings()));
    void goToIntegrations() =>
        Navigator.of(context).push(MaterialPageRoute(builder: (context) => const IntegrationsPage()));
    void goToPermissions() {
      PlatformManager.instance.analytics.permissionsSettingsOpened();
      routeToPage(context, const PermissionsPage());
    }

    void goToMemories() => routeToPage(context, const MemoriesPage());
    void goToDeveloper() async => await routeToPage(context, const DeveloperSettingsPage());
    void goToAppearance() => routeToPage(context, const AppearanceSettingsPage());

    final profileIcon = _rowIcon(context, OmiIcon.user);
    final notifIcon = _rowIcon(context, OmiIcon.bell);
    final usageIcon = _rowIcon(context, OmiIcon.chart);
    final deviceIcon = _rowIcon(context, OmiIcon.bluetooth);
    final permIcon = _rowIcon(context, OmiIcon.shield);
    final memIcon = _rowIcon(context, OmiIcon.brain);
    final devIcon = _rowIcon(context, OmiIcon.code);
    final intIcon = _rowIcon(context, OmiIcon.integrations);
    final syncIcon = _rowIcon(context, OmiIcon.cloud);
    final appearanceIcon = _rowIcon(context, OmiIcon.palette);

    final items = <_SearchableItem>[
      // --- Profile ---
      _SearchableItem(title: context.l10n.profile, icon: profileIcon, onTap: goToProfile),
      _SearchableItem(title: context.l10n.name, icon: profileIcon, onTap: goToProfile),
      _SearchableItem(title: context.l10n.email, icon: profileIcon, onTap: goToProfile),
      _SearchableItem(title: context.l10n.language, icon: profileIcon, onTap: goToProfile),
      _SearchableItem(title: context.l10n.customVocabulary, icon: profileIcon, onTap: goToProfile),
      _SearchableItem(title: context.l10n.speechProfile, icon: profileIcon, onTap: goToProfile),
      _SearchableItem(title: context.l10n.identifyingOthers, icon: profileIcon, onTap: goToProfile),
      _SearchableItem(title: context.l10n.voiceResponseMode, icon: profileIcon, onTap: goToProfile),
      if (Platform.isAndroid)
        _SearchableItem(title: context.l10n.backgroundModeTitle, icon: profileIcon, onTap: goToProfile),
      _SearchableItem(title: context.l10n.paymentMethods, icon: devIcon, onTap: goToDeveloper),
      _SearchableItem(title: context.l10n.conversationDisplay, icon: devIcon, onTap: goToDeveloper),
      _SearchableItem(title: context.l10n.dataPrivacy, icon: devIcon, onTap: goToDeveloper),
      _SearchableItem(title: context.l10n.deleteAccountTitle, icon: profileIcon, onTap: goToProfile),
      // --- Notifications ---
      _SearchableItem(title: context.l10n.notifications, icon: notifIcon, onTap: goToNotifications),
      _SearchableItem(title: context.l10n.notificationFrequency, icon: notifIcon, onTap: goToNotifications),
      _SearchableItem(title: context.l10n.dailySummary, icon: notifIcon, onTap: goToNotifications),
      _SearchableItem(title: context.l10n.deliveryTime, icon: notifIcon, onTap: goToNotifications),
      // --- Plan & Usage ---
      _SearchableItem(title: context.l10n.planAndUsage, icon: usageIcon, onTap: goToUsage),
      // --- Offline Sync ---
      _SearchableItem(title: context.l10n.offlineSync, icon: syncIcon, onTap: goToSync),
      // --- Device Settings (only when connected) ---
      if (deviceProvider.isConnected) ...[
        _SearchableItem(title: context.l10n.deviceSettings, icon: deviceIcon, onTap: goToDevice),
        _SearchableItem(title: context.l10n.deviceName, icon: deviceIcon, onTap: goToDevice),
        _SearchableItem(title: context.l10n.firmware, icon: deviceIcon, onTap: goToDevice),
        _SearchableItem(title: context.l10n.sdCardSync, icon: deviceIcon, onTap: goToDevice),
        _SearchableItem(title: context.l10n.doubleTap, icon: deviceIcon, onTap: goToDevice),
        _SearchableItem(title: context.l10n.ledBrightness, icon: deviceIcon, onTap: goToDevice),
        _SearchableItem(title: context.l10n.micGain, icon: deviceIcon, onTap: goToDevice),
      ],
      // --- Integrations ---
      _SearchableItem(title: context.l10n.integrations, icon: intIcon, onTap: goToIntegrations),
      // --- Permissions ---
      _SearchableItem(title: context.l10n.permissions, icon: permIcon, onTap: goToPermissions),
      _SearchableItem(title: context.l10n.microphone, icon: permIcon, onTap: goToPermissions),
      _SearchableItem(title: context.l10n.bluetooth, icon: permIcon, onTap: goToPermissions),
      _SearchableItem(title: context.l10n.location, icon: permIcon, onTap: goToPermissions),
      _SearchableItem(title: context.l10n.backgroundActivity, icon: permIcon, onTap: goToPermissions),
      // --- Memories ---
      _SearchableItem(title: context.l10n.memories, icon: memIcon, onTap: goToMemories),
      // --- Support ---
      if (PlatformService.isIntercomSupported) ...[
        _SearchableItem(
          title: context.l10n.feedbackBug,
          icon: _rowIcon(context, OmiIcon.envelope),
          onTap: () async {
            final Uri url = Uri.parse('https://feedback.omi.me/');
            if (await canLaunchUrl(url)) await launchUrl(url, mode: LaunchMode.inAppBrowserView);
          },
        ),
        _SearchableItem(
          title: context.l10n.helpCenter,
          icon: _rowIcon(context, OmiIcon.book),
          onTap: () async {
            final Uri url = Uri.parse('https://help.omi.me/en/');
            if (await canLaunchUrl(url)) {
              try {
                await launchUrl(url, mode: LaunchMode.inAppBrowserView);
              } catch (e) {
                await launchUrl(url, mode: LaunchMode.externalApplication);
              }
            }
          },
        ),
      ],
      // --- Appearance ---
      _SearchableItem(title: context.l10n.appearance, icon: appearanceIcon, onTap: goToAppearance),
      _SearchableItem(title: context.l10n.appearanceClassic, icon: appearanceIcon, onTap: goToAppearance),
      _SearchableItem(title: context.l10n.appearanceGlassBeta, icon: appearanceIcon, onTap: goToAppearance),
      // --- Developer ---
      _SearchableItem(title: context.l10n.developerSettings, icon: devIcon, onTap: goToDeveloper),
      _SearchableItem(title: context.l10n.apiKeys, icon: devIcon, onTap: goToDeveloper),
      _SearchableItem(title: context.l10n.debugAndDiagnostics, icon: devIcon, onTap: goToDeveloper),
      _SearchableItem(title: context.l10n.conversationEvents, icon: devIcon, onTap: goToDeveloper),
      _SearchableItem(title: context.l10n.realTimeTranscript, icon: devIcon, onTap: goToDeveloper),
      _SearchableItem(title: context.l10n.audioBytes, icon: devIcon, onTap: goToDeveloper),
      _SearchableItem(title: context.l10n.daySummary, icon: devIcon, onTap: goToDeveloper),
      _SearchableItem(title: context.l10n.autoCreateSpeakers, icon: devIcon, onTap: goToDeveloper),
      _SearchableItem(title: context.l10n.goalTracker, icon: devIcon, onTap: goToDeveloper),
      _SearchableItem(title: context.l10n.apiEnvironment, icon: devIcon, onTap: goToDeveloper),
      // --- What's New ---
      _SearchableItem(
        title: context.l10n.whatsNew,
        icon: _rowIcon(context, OmiIcon.star),
        onTap: () {
          PlatformManager.instance.analytics.whatsNewOpened();
          ChangelogSheet.showWithLoading(context, () => getAppChangelogs(limit: 5));
        },
      ),
      // --- Referral ---
      _SearchableItem(
        title: context.l10n.referralProgram,
        icon: _rowIcon(context, OmiIcon.gift),
        onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (context) => const ReferralPage())),
      ),
      // --- Sign Out ---
      _SearchableItem(
        title: context.l10n.signOut,
        icon: _rowIcon(context, OmiIcon.signOut),
        onTap: () async {
          final navigator = Navigator.of(context);
          navigator.pop();
          await showDialog(
            context: context,
            builder: (ctx) {
              return getDialog(
                ctx,
                () => Navigator.of(ctx).pop(),
                () async {
                  Navigator.of(ctx).pop();
                  final rootCtx = globalNavigatorKey.currentContext;
                  if (rootCtx != null && rootCtx.mounted) {
                    clearAllUserState(rootCtx);
                  }
                  await SharedPreferencesUtil().clear();
                  await AuthService.instance.signOut();
                  if (rootCtx != null && rootCtx.mounted) {
                    routeToPage(rootCtx, const AppShell(), replace: true);
                  }
                },
                context.l10n.signOutQuestion,
                context.l10n.signOutConfirmation,
              );
            },
          );
        },
      ),
    ];

    return items;
  }

  Widget _buildSearchResults(BuildContext context) {
    final t = context.omi;

    final allItems = _buildSearchableItems(context);
    final query = _searchQuery.toLowerCase();
    final filtered = allItems.where((item) => item.title.toLowerCase().contains(query)).toList();

    if (filtered.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.only(top: 48),
          child: Text(
            'No results',
            style: TextStyle(color: t.textSecondary, fontSize: 16, fontWeight: FontWeight.w400),
          ),
        ),
      );
    }

    return Column(
      children:
          filtered.map((item) => _buildSettingsItem(title: item.title, icon: item.icon, onTap: item.onTap)).toList(),
    );
  }

  Widget _buildOmiModeContent(BuildContext context) {
    return Consumer<UsageProvider>(
      builder: (context, usageProvider, child) {
        final t = context.omi;

        return Column(
          children: [
            // Profile & Notifications Section
            _buildSectionContainer(
              children: [
                // Wrapped 2025 - temporarily disabled
                // _buildSettingsItem(
                //   title: context.l10n.wrapped2025,
                //   icon: OmiIconWidget(icon: OmiIcon.gift, color: t.textSecondary, size: 20),
                //   showNewTag: true,
                //   onTap: () {
                //     Navigator.of(context).push(
                //       MaterialPageRoute(
                //         builder: (context) => const Wrapped2025Page(),
                //       ),
                //     );
                //   },
                // ),
                // const Divider(height: 1, color: Color(0xFF3C3C43)),
                _buildSettingsItem(
                  title: context.l10n.profile,
                  icon: _rowIcon(context, OmiIcon.user),
                  onTap: () {
                    routeToPage(context, const ProfilePage());
                  },
                ),
                _rowDivider(),
                _buildSettingsItem(
                  title: context.l10n.notifications,
                  icon: _rowIcon(context, OmiIcon.bell),
                  onTap: () {
                    routeToPage(context, const NotificationsSettingsPage());
                  },
                ),
                _rowDivider(),
                Consumer<UsageProvider>(
                  builder: (context, usageProvider, child) {
                    final sp = usageProvider.subscription?.subscription.plan;
                    final isUnlimited = sp?.isPaid ?? false;
                    return _buildSettingsItem(
                      title: context.l10n.planAndUsage,
                      icon: _rowIcon(context, OmiIcon.chart),
                      trailingChip: isUnlimited
                          ? Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                              decoration: BoxDecoration(
                                color: t.warning.withValues(alpha: 0.2),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  OmiIconWidget(icon: OmiIcon.crown, color: t.warning, size: 10),
                                  const SizedBox(width: 4),
                                  Text(
                                    context.l10n.pro.toUpperCase(),
                                    style: TextStyle(
                                      color: t.warning,
                                      fontSize: 10,
                                      fontWeight: FontWeight.w600,
                                      letterSpacing: 0.5,
                                    ),
                                  ),
                                ],
                              ),
                            )
                          : null,
                      onTap: () {
                        Navigator.of(context).push(MaterialPageRoute(builder: (context) => const UsagePage()));
                      },
                    );
                  },
                ),
                _rowDivider(),
                _buildSettingsItem(
                  title: context.l10n.offlineSync,
                  icon: _rowIcon(context, OmiIcon.cloud),
                  onTap: () {
                    final page =
                        SharedPreferencesUtil().deviceSupportsMultiFileSync ? const AutoSyncPage() : const SyncPage();
                    Navigator.of(context).push(MaterialPageRoute(builder: (context) => page));
                  },
                ),
                Consumer<DeviceProvider>(
                  builder: (context, deviceProvider, child) {
                    if (!deviceProvider.isConnected) {
                      return const SizedBox.shrink();
                    }
                    return Column(
                      children: [
                        _rowDivider(),
                        _buildSettingsItem(
                          title: context.l10n.deviceSettings,
                          icon: _rowIcon(context, OmiIcon.bluetooth),
                          onTap: () {
                            Navigator.of(context).push(MaterialPageRoute(builder: (context) => const DeviceSettings()));
                          },
                        ),
                      ],
                    );
                  },
                ),
                _rowDivider(),
                _buildSettingsItem(
                  title: context.l10n.integrations,
                  icon: _rowIcon(context, OmiIcon.integrations),
                  showBetaTag: true,
                  onTap: () {
                    Navigator.of(context).push(MaterialPageRoute(builder: (context) => const IntegrationsPage()));
                  },
                ),
                _rowDivider(),
                _buildSettingsItem(
                  title: context.l10n.permissions,
                  icon: _rowIcon(context, OmiIcon.shield),
                  onTap: () {
                    PlatformManager.instance.analytics.permissionsSettingsOpened();
                    routeToPage(context, const PermissionsPage());
                  },
                ),
              ],
            ),
            const SizedBox(height: 32),

            // Support & Settings Section
            _buildSectionContainer(
              children: [
                if (PlatformService.isIntercomSupported) ...[
                  _buildSettingsItem(
                    title: context.l10n.feedbackBug,
                    icon: _rowIcon(context, OmiIcon.envelope),
                    onTap: () async {
                      final Uri url = Uri.parse('https://feedback.omi.me/');
                      if (await canLaunchUrl(url)) {
                        await launchUrl(url, mode: LaunchMode.inAppBrowserView);
                      }
                    },
                  ),
                  _rowDivider(),
                  _buildSettingsItem(
                    title: context.l10n.helpCenter,
                    icon: _rowIcon(context, OmiIcon.book),
                    onTap: () async {
                      final Uri url = Uri.parse('https://help.omi.me/en/');
                      if (await canLaunchUrl(url)) {
                        try {
                          await launchUrl(url, mode: LaunchMode.inAppBrowserView);
                        } catch (e) {
                          await launchUrl(url, mode: LaunchMode.externalApplication);
                        }
                      }
                    },
                  ),
                  _rowDivider(),
                ],
                _buildSettingsItem(
                  title: context.l10n.appearance,
                  icon: _rowIcon(context, OmiIcon.palette),
                  onTap: () {
                    routeToPage(context, const AppearanceSettingsPage());
                  },
                ),
                _rowDivider(),
                _buildSettingsItem(
                  title: context.l10n.developerSettings,
                  icon: _rowIcon(context, OmiIcon.code),
                  onTap: () async {
                    await routeToPage(context, const DeveloperSettingsPage());
                  },
                ),
                _rowDivider(),
                _buildSettingsItem(
                  title: context.l10n.whatsNew,
                  icon: _rowIcon(context, OmiIcon.star),
                  onTap: () {
                    PlatformManager.instance.analytics.whatsNewOpened();
                    ChangelogSheet.showWithLoading(context, () => getAppChangelogs(limit: 5));
                  },
                ),
                _rowDivider(),
                _buildSettingsItem(
                  title: context.l10n.referralProgram,
                  icon: _rowIcon(context, OmiIcon.gift),
                  showNewTag: true,
                  onTap: () {
                    Navigator.of(context).push(MaterialPageRoute(builder: (context) => const ReferralPage()));
                  },
                ),
              ],
            ),
            const SizedBox(height: 32),

            // Sign Out Section
            _buildSectionContainer(
              children: [
                _buildSettingsItem(
                  title: context.l10n.signOut,
                  icon: _rowIcon(context, OmiIcon.signOut),
                  onTap: () async {
                    final navigator = Navigator.of(context);

                    navigator.pop(); // Close the settings drawer

                    await showDialog(
                      context: context,
                      builder: (ctx) {
                        return getDialog(
                          ctx,
                          () => Navigator.of(ctx).pop(),
                          () async {
                            Navigator.of(ctx).pop();
                            // The drawer's context is unmounted by the time we
                            // get here (we popped it before opening the
                            // confirm dialog), so routing through it is a
                            // silent no-op. Use the root navigator instead so
                            // we always land back on the auth screen.
                            final rootCtx = globalNavigatorKey.currentContext;
                            if (rootCtx != null && rootCtx.mounted) {
                              clearAllUserState(rootCtx);
                            }
                            await SharedPreferencesUtil().clear();
                            await AuthService.instance.signOut();
                            if (rootCtx != null && rootCtx.mounted) {
                              routeToPage(rootCtx, const AppShell(), replace: true);
                            }
                          },
                          context.l10n.signOutQuestion,
                          context.l10n.signOutConfirmation,
                        );
                      },
                    );
                  },
                ),
              ],
            ),
            const SizedBox(height: 32),

            // Version Info
            _buildVersionInfoSection(),
            const SizedBox(height: 24),
          ],
        );
      },
    );
  }

  /// Радиус шторки — скруглены только верхние углы, нижние уходят за экран.
  static const BorderRadius _sheetRadius =
      BorderRadius.only(topLeft: Radius.circular(28), topRight: Radius.circular(28));

  /// Размытие страницы под шторкой.
  ///
  /// Больше, чем у плавающих пилюль (32): пилюля глушит полосу контента, а
  /// шторка накрывает целую страницу с текстом и должна сделать его
  /// нечитаемым целиком. Меньше фоновой подложки (48) — та размывает
  /// фотографию, здесь же под фильтром мелкий шрифт, и 38 его уже растворяют.
  static const double _sheetBlurSigma = 38;

  /// Вуаль шторки в Glass.
  ///
  /// Токен `bgPrimary` (белый 0.46) остался бы честным, будь под шторкой
  /// blur, — но его не было, и страница просвечивала прямо сквозь пункты
  /// меню, на что и жаловался Игорь. Размытие снимает разборчивость, вуаль
  /// добивает остаточный контраст: белый 0.62 гасит смазанные пятна текста
  /// до фона, но пропускает достаточно, чтобы за стеклом угадывалась
  /// подложка [GlassBackdrop], а не глухая плита.
  ///
  /// Плотнее токена ровно потому, что здесь стекло стоит не на подложке, а на
  /// экране, полном собственного текста.
  static const Color _glassSheetVeil = Color(0x9EFFFFFF);

  @override
  Widget build(BuildContext context) {
    final t = context.omi;

    final content = ClipRRect(
      borderRadius: _sheetRadius,
      child: Column(
        children: [
          // Handle bar
          Container(
            margin: const EdgeInsets.only(top: 8),
            height: 4,
            width: 36,
            decoration: BoxDecoration(color: t.divider, borderRadius: BorderRadius.circular(2)),
          ),
          // Header
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 200),
            transitionBuilder: (child, animation) => FadeTransition(opacity: animation, child: child),
            child: _isSearching
                ? Padding(
                    key: const ValueKey('search-header'),
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                    child: Row(
                      children: [
                        Expanded(
                          child: TextFormField(
                            controller: _searchController,
                            focusNode: _searchFocusNode,
                            autofocus: true,
                            style: TextStyle(color: t.textPrimary, fontSize: 14),
                            cursorColor: t.textPrimary,
                            decoration: InputDecoration(
                              hintText: context.l10n.searchSettings,
                              hintStyle: TextStyle(color: t.textSecondary, fontSize: 14),
                              filled: true,
                              fillColor: t.bgSecondary,
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(24),
                                borderSide: BorderSide.none,
                              ),
                              focusedBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(24),
                                borderSide: BorderSide.none,
                              ),
                              enabledBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(24),
                                borderSide: BorderSide.none,
                              ),
                              prefixIcon: OmiIconWidget(icon: OmiIcon.search, color: t.textSecondary, size: 24),
                              suffixIcon: _searchQuery.isNotEmpty
                                  ? GestureDetector(
                                      onTap: () {
                                        setState(() => _searchQuery = '');
                                        _searchController.clear();
                                      },
                                      child: OmiIconWidget(icon: OmiIcon.close, color: t.textSecondary, size: 24),
                                    )
                                  : null,
                              contentPadding: const EdgeInsets.symmetric(horizontal: 12),
                            ),
                            onChanged: (value) => setState(() => _searchQuery = value),
                          ),
                        ),
                        const SizedBox(width: 10),
                        GestureDetector(
                          onTap: () {
                            setState(() {
                              _isSearching = false;
                              _searchQuery = '';
                              _searchController.clear();
                            });
                            _searchFocusNode.unfocus();
                          },
                          child: Text(context.l10n.cancel, style: TextStyle(color: t.textPrimary, fontSize: 16)),
                        ),
                      ],
                    ),
                  )
                : Padding(
                    key: const ValueKey('normal-header'),
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                    child: Row(
                      children: [
                        GestureDetector(
                          onTap: () {
                            setState(() => _isSearching = true);
                            Future.microtask(() => _searchFocusNode.requestFocus());
                          },
                          child: OmiIconWidget(icon: OmiIcon.search, color: t.textPrimary, size: 22),
                        ),
                        Expanded(
                          child: Center(
                            child: Text(
                              context.l10n.settings,
                              style: TextStyle(color: t.textPrimary, fontSize: 18, fontWeight: FontWeight.w600),
                            ),
                          ),
                        ),
                        GestureDetector(
                          onTap: () => Navigator.pop(context),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                            decoration: BoxDecoration(
                                color: (t.isGlass ? t.accent : Colors.white), borderRadius: BorderRadius.circular(20)),
                            child: Text(
                              context.l10n.done,
                              style: TextStyle(
                                  color: (t.isGlass ? t.onAccent : Colors.black),
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
          ),
          const SizedBox(height: 16),
          // Content
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: _isSearching && _searchQuery.isNotEmpty
                  ? _buildSearchResults(context)
                  : _buildOmiModeContent(context),
            ),
          ),
        ],
      ),
    );

    final height = MediaQuery.of(context).size.height * 0.9;

    if (!t.isGlass) {
      return Container(
        height: height,
        decoration: BoxDecoration(color: t.bgPrimary, borderRadius: _sheetRadius),
        child: content,
      );
    }

    // Glass: под шторкой честное стекло — сначала размывается всё, что уже
    // нарисовано ниже (страница + подложка), и только поверх ложится вуаль.
    return SizedBox(
      height: height,
      child: glassBlur(
        borderRadius: _sheetRadius,
        sigma: _sheetBlurSigma,
        child: DecoratedBox(
          decoration: const BoxDecoration(color: _glassSheetVeil, borderRadius: _sheetRadius),
          child: content,
        ),
      ),
    );
  }
}
