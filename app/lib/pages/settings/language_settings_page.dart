import 'package:omi/utils/platform/platform_manager.dart';
import 'package:flutter/material.dart';

import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:provider/provider.dart';

import 'package:omi/providers/capture_provider.dart';
import 'package:omi/providers/home_provider.dart';
import 'package:omi/providers/locale_provider.dart';
import 'package:omi/providers/user_provider.dart';
import 'package:omi/utils/l10n_extensions.dart';
import 'package:omi/pages/settings/widgets/glass_icon_chip.dart';
import 'package:omi/utils/theme/omi_tokens.dart';
import 'package:omi/utils/theme/omi_icons.dart';
import 'package:omi/widgets/omi_switch.dart';

class LanguageSettingsPage extends StatefulWidget {
  const LanguageSettingsPage({super.key});

  @override
  State<LanguageSettingsPage> createState() => _LanguageSettingsPageState();
}

class _LanguageSettingsPageState extends State<LanguageSettingsPage> {
  bool _isUpdatingLanguage = false;

  Widget _buildSectionHeader(String title) {
    final t = context.omi;

    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 8),
      child: Text(
        title,
        style: TextStyle(color: t.textSecondary, fontSize: 13, fontWeight: FontWeight.w600, letterSpacing: 0.5),
      ),
    );
  }

  Widget _buildAppInterfaceCard(LocaleProvider localeProvider) {
    final t = context.omi;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: t.bgSecondary, borderRadius: BorderRadius.circular(14)),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => _showAppLanguageSelectionSheet(localeProvider),
        child: Row(
          children: [
            SettingsIconChip.boxed(
                icon: (size) => FaIcon(FontAwesomeIcons.textHeight, color: t.textSecondary, size: size)),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    context.l10n.appLanguage,
                    style: TextStyle(color: t.textPrimary, fontSize: 16, fontWeight: FontWeight.w500),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    localeProvider.locale != null
                        ? LocaleProvider.getDisplayName(localeProvider.locale!)
                        : context.l10n.systemDefault,
                    style: TextStyle(color: t.textSecondary, fontSize: 13),
                  ),
                ],
              ),
            ),
            FaIcon(FontAwesomeIcons.chevronRight, color: t.textSecondary, size: 14),
          ],
        ),
      ),
    );
  }

  Widget _buildSpeechTranscriptionCard(
    HomeProvider homeProvider,
    UserProvider userProvider,
    CaptureProvider captureProvider,
  ) {
    final t = context.omi;

    final languageName = homeProvider.userPrimaryLanguage.isNotEmpty
        ? homeProvider.availableLanguages.entries
            .firstWhere(
              (element) => element.value == homeProvider.userPrimaryLanguage,
              orElse: () => MapEntry(context.l10n.notSet, ''),
            )
            .key
        : context.l10n.notSet;

    final isUpdatingTranslation = userProvider.isUpdatingSingleLanguageMode;
    final isAutoTranslationEnabled = !userProvider.singleLanguageMode;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: t.bgSecondary, borderRadius: BorderRadius.circular(14)),
      child: Column(
        children: [
          // Speech Language Row
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _isUpdatingLanguage ? null : () => _showLanguageSelectionSheet(homeProvider, captureProvider),
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
                        context.l10n.primaryLanguage,
                        style: TextStyle(color: t.textPrimary, fontSize: 16, fontWeight: FontWeight.w500),
                      ),
                      const SizedBox(height: 2),
                      Text(languageName, style: TextStyle(color: t.textSecondary, fontSize: 13)),
                    ],
                  ),
                ),
                if (_isUpdatingLanguage)
                  SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor: AlwaysStoppedAnimation<Color>(t.textPrimary),
                    ),
                  )
                else
                  FaIcon(FontAwesomeIcons.chevronRight, color: t.textSecondary, size: 14),
              ],
            ),
          ),

          Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Divider(height: 1, color: t.textSecondary),
          ),

          // Multi-language Detection Row
          Row(
            children: [
              SettingsIconChip.boxed(
                  icon: (size) => FaIcon(FontAwesomeIcons.language, color: t.textSecondary, size: size)),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      context.l10n.automaticTranslation,
                      style: TextStyle(color: t.textPrimary, fontSize: 16, fontWeight: FontWeight.w500),
                    ),
                    const SizedBox(height: 2),
                    Text(context.l10n.detectLanguages, style: TextStyle(color: t.textSecondary, fontSize: 13)),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              if (isUpdatingTranslation)
                SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation<Color>(t.textPrimary),
                  ),
                )
              else
                OmiSwitch(
                  value: isAutoTranslationEnabled,
                  onChanged: (value) async {
                    final success = await userProvider.setSingleLanguageMode(!value);
                    if (success && mounted) {
                      context.read<CaptureProvider>().onTranscriptionSettingsChanged();
                    }
                  },
                  classicActiveThumbColor: t.success,
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildHelperText() {
    final t = context.omi;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
      child: Text(
        context.l10n.languageSettingsHelperText,
        style: TextStyle(color: t.textSecondary, fontSize: 12, height: 1.4),
      ),
    );
  }

  void _showAppLanguageSelectionSheet(LocaleProvider localeProvider) {
    final t = context.omi;

    final supportedLocales = LocaleProvider.supportedLocales;
    final currentLocale = localeProvider.locale;

    showModalBottomSheet(
      context: context,
      backgroundColor: t.bgSecondary,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (context) {
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
                context.l10n.appLanguage,
                style: TextStyle(color: t.textPrimary, fontSize: 17, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 16),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  physics: const ClampingScrollPhysics(),
                  itemCount: supportedLocales.length,
                  itemBuilder: (context, index) {
                    final locale = supportedLocales[index];
                    final isSelected = currentLocale?.languageCode == locale.languageCode;
                    return ListTile(
                      title: Text(
                        LocaleProvider.getDisplayName(locale),
                        style: TextStyle(
                          color: isSelected ? t.textPrimary : t.textSecondary,
                          fontWeight: isSelected ? FontWeight.w500 : FontWeight.w400,
                        ),
                      ),
                      trailing: isSelected ? OmiIconWidget(icon: OmiIcon.check, color: t.textPrimary, size: 20) : null,
                      onTap: () {
                        localeProvider.setLocale(locale);
                        Navigator.pop(context);
                      },
                    );
                  },
                ),
              ),
              const SizedBox(height: 16),
            ],
          ),
        );
      },
    );
  }

  void _showLanguageSelectionSheet(HomeProvider homeProvider, CaptureProvider captureProvider) {
    final t = context.omi;

    final languages = homeProvider.availableLanguages;
    String currentLanguage = homeProvider.userPrimaryLanguage;

    showModalBottomSheet(
      context: context,
      backgroundColor: t.bgSecondary,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      isScrollControlled: true,
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            return DraggableScrollableSheet(
              initialChildSize: 0.7,
              minChildSize: 0.5,
              maxChildSize: 0.9,
              expand: false,
              builder: (context, scrollController) {
                return Column(
                  children: [
                    Container(
                      margin: const EdgeInsets.only(top: 12, bottom: 16),
                      width: 36,
                      height: 4,
                      decoration: BoxDecoration(color: t.divider, borderRadius: BorderRadius.circular(2)),
                    ),
                    Text(
                      context.l10n.selectLanguage,
                      style: TextStyle(color: t.textPrimary, fontSize: 17, fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 16),
                    Expanded(
                      child: ListView.builder(
                        controller: scrollController,
                        itemCount: languages.length,
                        itemBuilder: (context, index) {
                          final entry = languages.entries.elementAt(index);
                          final isSelected = entry.value == currentLanguage;
                          return ListTile(
                            title: Text(
                              entry.key,
                              style: TextStyle(
                                color: isSelected ? t.textPrimary : t.textSecondary,
                                fontWeight: isSelected ? FontWeight.w500 : FontWeight.w400,
                              ),
                            ),
                            trailing:
                                isSelected ? OmiIconWidget(icon: OmiIcon.check, color: t.textPrimary, size: 20) : null,
                            onTap: _isUpdatingLanguage
                                ? null
                                : () async {
                                    setSheetState(() {
                                      currentLanguage = entry.value;
                                    });
                                    Navigator.pop(sheetContext);
                                    setState(() {
                                      _isUpdatingLanguage = true;
                                    });
                                    try {
                                      final userProvider = Provider.of<UserProvider>(context, listen: false);
                                      final success = await homeProvider.updateUserPrimaryLanguage(
                                        entry.value,
                                        userProvider: userProvider,
                                      );
                                      if (success) {
                                        captureProvider.onRecordProfileSettingChanged();
                                        PlatformManager.instance.analytics.languageChanged(entry.value);
                                      }
                                    } finally {
                                      if (mounted) {
                                        setState(() {
                                          _isUpdatingLanguage = false;
                                        });
                                      }
                                    }
                                  },
                          );
                        },
                      ),
                    ),
                  ],
                );
              },
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = context.omi;

    PlatformManager.instance.analytics.pageOpened('Language Settings');

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
          context.l10n.languageTitle,
          style: TextStyle(color: t.textPrimary, fontSize: 18, fontWeight: FontWeight.w600),
        ),
        centerTitle: true,
      ),
      body: Consumer4<HomeProvider, UserProvider, CaptureProvider, LocaleProvider>(
        builder: (context, homeProvider, userProvider, captureProvider, localeProvider, _) {
          return SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 16),
                // App Interface Section
                _buildSectionHeader(context.l10n.appInterfaceSectionTitle),
                _buildAppInterfaceCard(localeProvider),
                const SizedBox(height: 24),
                // Speech & Transcription Section
                _buildSectionHeader(context.l10n.speechTranscriptionSectionTitle),
                _buildSpeechTranscriptionCard(homeProvider, userProvider, captureProvider),
                const SizedBox(height: 12),
                _buildHelperText(),
                const SizedBox(height: 32),
              ],
            ),
          );
        },
      ),
    );
  }
}
