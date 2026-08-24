import 'package:flutter/material.dart';

import 'package:provider/provider.dart';

import 'package:omi/providers/locale_provider.dart';
import 'package:omi/utils/l10n_extensions.dart';
import 'package:omi/utils/theme/omi_tokens.dart';

class LanguagePickerTile extends StatelessWidget {
  const LanguagePickerTile({super.key});

  @override
  Widget build(BuildContext context) {
    final t = context.omi;
    return Consumer<LocaleProvider>(
      builder: (context, localeProvider, child) {
        final currentLocale = localeProvider.locale;
        final displayName =
            currentLocale != null ? LocaleProvider.getDisplayName(currentLocale) : context.l10n.systemDefault;

        return ListTile(
          title: Text(context.l10n.language, style: TextStyle(color: t.textPrimary)),
          subtitle: Text(displayName, style: TextStyle(color: t.textSecondary)),
          trailing: Icon(Icons.chevron_right, color: t.textSecondary),
          onTap: () => _showLanguagePicker(context, localeProvider),
        );
      },
    );
  }

  void _showLanguagePicker(BuildContext context, LocaleProvider localeProvider) {
    final t = context.omi;
    final supportedLocales = LocaleProvider.supportedLocales;
    final currentLocale = localeProvider.locale;

    showModalBottomSheet(
      context: context,
      backgroundColor: t.bgSecondary,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(t.cardRadius))),
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
                context.l10n.selectLanguage,
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
                      trailing: isSelected ? Icon(Icons.check, color: t.textPrimary, size: 20) : null,
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
}
