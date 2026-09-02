import 'package:flutter/material.dart';

import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:provider/provider.dart';

import 'package:omi/pages/settings/widgets/glass_icon_chip.dart';
import 'package:omi/providers/theme_provider.dart';
import 'package:omi/utils/l10n_extensions.dart';
import 'package:omi/utils/platform/platform_manager.dart';
import 'package:omi/utils/theme/omi_tokens.dart';
import 'package:omi/utils/theme/omi_icons.dart';

class AppearanceSettingsPage extends StatelessWidget {
  const AppearanceSettingsPage({super.key});

  Widget _buildThemeOption(
    BuildContext context, {
    required String title,
    required FaIconData icon,
    required bool isSelected,
    required bool showBetaTag,
    required VoidCallback onTap,
  }) {
    final t = context.omi;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            SettingsIconChip.boxed(
              icon: (size) => FaIcon(icon, color: t.textSecondary, size: size),
              radius: t.settingsCardRadius,
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Row(
                children: [
                  Flexible(
                    child: Text(
                      title,
                      style: TextStyle(
                        color: t.textPrimary,
                        fontSize: 16,
                        fontWeight: isSelected ? FontWeight.w500 : FontWeight.w400,
                      ),
                    ),
                  ),
                  if (showBetaTag) ...[
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: t.warning.withValues(alpha: 0.2),
                        borderRadius: BorderRadius.circular(t.chipRadius),
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
                ],
              ),
            ),
            if (isSelected) OmiIconWidget(icon: OmiIcon.check, color: t.textPrimary, size: 20),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    PlatformManager.instance.analytics.pageOpened('Appearance Settings');
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
          context.l10n.appearance,
          style: TextStyle(color: t.textPrimary, fontSize: 18, fontWeight: FontWeight.w600),
        ),
        centerTitle: true,
      ),
      body: Consumer<ThemeProvider>(
        builder: (context, themeProvider, _) {
          return SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 16),
                Container(
                  decoration: BoxDecoration(
                    color: t.bgSecondary,
                    borderRadius: BorderRadius.circular(t.cardRadius),
                  ),
                  child: Column(
                    children: [
                      _buildThemeOption(
                        context,
                        title: context.l10n.appearanceClassic,
                        icon: FontAwesomeIcons.moon,
                        isSelected: !themeProvider.isGlass,
                        showBetaTag: false,
                        onTap: () => themeProvider.setTheme(kOmiThemeClassic),
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Divider(height: 1, color: t.divider),
                      ),
                      _buildThemeOption(
                        context,
                        title: context.l10n.appearanceGlass,
                        icon: FontAwesomeIcons.sun,
                        isSelected: themeProvider.isGlass,
                        showBetaTag: true,
                        onTap: () => themeProvider.setTheme(kOmiThemeGlass),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 32),
              ],
            ),
          );
        },
      ),
    );
  }
}
