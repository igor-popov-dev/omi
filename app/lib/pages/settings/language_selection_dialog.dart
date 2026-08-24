import 'package:flutter/material.dart';

import 'package:provider/provider.dart';

import 'package:omi/providers/capture_provider.dart';
import 'package:omi/providers/home_provider.dart';
import 'package:omi/providers/user_provider.dart';
import 'package:omi/utils/alerts/app_snackbar.dart';
import 'package:omi/utils/l10n_extensions.dart';
import 'package:omi/utils/theme/omi_tokens.dart';
import 'package:omi/utils/theme/omi_icons.dart';

class LanguageSelectionDialog {
  static Future<void> show(
    BuildContext context, {
    bool isRequired = false,
    bool forceShow = false,
    bool showSingleLanguageWarning = false,
  }) async {
    final homeProvider = Provider.of<HomeProvider>(context, listen: false);

    // If the user has already set a primary language and it's not required or forced, don't show the dialog
    if (homeProvider.hasSetPrimaryLanguage && !isRequired && !forceShow) {
      return;
    }

    // If the user's primary language is empty, they haven't set one yet
    if (homeProvider.userPrimaryLanguage.isEmpty) {
      isRequired = true; // Make the dialog required if no language is set
    }

    // Use the availableLanguages directly as they're already ordered by popularity
    final languages = homeProvider.availableLanguages.entries.toList();

    // Preset the selected language if the user has one
    String? selectedLanguage = homeProvider.userPrimaryLanguage.isNotEmpty ? homeProvider.userPrimaryLanguage : null;
    String? selectedLanguageName = selectedLanguage != null ? homeProvider.getLanguageName(selectedLanguage) : null;
    String searchQuery = '';
    List<MapEntry<String, String>> filteredLanguages = List.from(languages);
    final ScrollController scrollController = ScrollController();

    await showDialog(
      context: context,
      barrierDismissible: !isRequired,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setState) {
            final t = context.omi;

            void filterLanguages(String query) {
              setState(() {
                searchQuery = query.toLowerCase();
                if (query.isEmpty) {
                  filteredLanguages = languages;
                } else {
                  // Filter all languages
                  final filtered = languages.where((lang) {
                    return lang.key.toLowerCase().contains(searchQuery) ||
                        lang.value.toLowerCase().contains(searchQuery);
                  }).toList();

                  // Keep the original order from availableLanguages
                  filtered.sort((a, b) {
                    final aIndex = languages.indexOf(a);
                    final bIndex = languages.indexOf(b);
                    return aIndex.compareTo(bIndex);
                  });

                  filteredLanguages = filtered;
                }
              });
            }

            return AlertDialog(
              backgroundColor: t.bgSecondary,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              title: Text(
                context.l10n.tellUsPrimaryLanguage,
                style: TextStyle(color: t.textPrimary, fontSize: 18, fontWeight: FontWeight.bold),
              ),
              content: SizedBox(
                width: double.maxFinite,
                height: 300,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      context.l10n.languageForTranscription,
                      style: TextStyle(color: t.textSecondary, fontSize: 14),
                    ),
                    if (showSingleLanguageWarning) ...[
                      const SizedBox(height: 8),
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: t.bgTertiary,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: t.textTertiary),
                        ),
                        child: Row(
                          children: [
                            OmiIconWidget(icon: OmiIcon.info, color: t.textSecondary, size: 18),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                context.l10n.singleLanguageModeInfo,
                                style: TextStyle(color: t.textSecondary, fontSize: 12),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                    const SizedBox(height: 16),
                    TextField(
                      onChanged: filterLanguages,
                      style: TextStyle(color: t.textPrimary),
                      decoration: InputDecoration(
                        hintText: context.l10n.searchLanguageHint,
                        hintStyle: TextStyle(color: t.textSecondary),
                        prefixIcon: Icon(Icons.search, color: t.textSecondary),
                        filled: true,
                        fillColor: t.bgTertiary,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: BorderSide(color: t.bgTertiary),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: BorderSide(color: t.bgTertiary),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: BorderSide(color: (t.isGlass ? t.accent : Colors.white)),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Expanded(
                      child: filteredLanguages.isEmpty
                          ? Center(
                              child: Text(context.l10n.noLanguagesFound, style: TextStyle(color: t.textSecondary)),
                            )
                          : ListView.builder(
                              controller: scrollController,
                              itemCount: filteredLanguages.length,
                              itemBuilder: (context, index) {
                                final language = filteredLanguages[index];
                                final isSelected = selectedLanguage == language.value;

                                return ListTile(
                                  title: Text(language.key, style: TextStyle(color: t.textPrimary)),
                                  trailing: isSelected ? Icon(Icons.check_circle, color: t.textPrimary) : null,
                                  selected: isSelected,
                                  selectedTileColor: t.rowFillHover,
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                  onTap: () {
                                    setState(() {
                                      // Toggle selection - if already selected, unselect it
                                      if (selectedLanguage == language.value) {
                                        selectedLanguage = null;
                                        selectedLanguageName = null;
                                      } else {
                                        selectedLanguage = language.value;
                                        selectedLanguageName = language.key;
                                      }
                                    });
                                  },
                                );
                              },
                            ),
                    ),
                    // Auto-scroll to selected language when selection changes
                    if (selectedLanguage != null)
                      Builder(
                        builder: (context) {
                          WidgetsBinding.instance.addPostFrameCallback((_) {
                            final selectedIndex = filteredLanguages.indexWhere(
                              (lang) => lang.value == selectedLanguage,
                            );
                            if (selectedIndex != -1 && scrollController.hasClients) {
                              scrollController.animateTo(
                                selectedIndex * 56.0, // Approximate height of each list item
                                duration: const Duration(milliseconds: 300),
                                curve: Curves.easeInOut,
                              );
                            }
                          });
                          return const SizedBox.shrink();
                        },
                      ),
                  ],
                ),
              ),
              actions: [
                if (!isRequired)
                  TextButton(
                    onPressed: () {
                      Navigator.of(context).pop();
                    },
                    style: TextButton.styleFrom(foregroundColor: t.textSecondary),
                    child: Text(context.l10n.skip),
                  ),
                ElevatedButton(
                  onPressed: selectedLanguage == null
                      ? null
                      : () async {
                          final successMsg = context.l10n.languageSetTo(selectedLanguageName!);
                          final failMsg = context.l10n.failedToSetLanguage;
                          final userProvider = Provider.of<UserProvider>(context, listen: false);
                          final success = await homeProvider.updateUserPrimaryLanguage(
                            selectedLanguage!,
                            userProvider: userProvider,
                          );
                          if (!context.mounted) return;
                          if (success) {
                            Provider.of<CaptureProvider>(context, listen: false).onRecordProfileSettingChanged();
                            Navigator.of(context).pop();
                            AppSnackbar.showSnackbarSuccess(successMsg);
                          } else {
                            AppSnackbar.showSnackbarError(failMsg);
                          }
                        },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: (t.isGlass ? t.accent : Colors.white),
                    disabledBackgroundColor: t.textTertiary,
                    foregroundColor: (t.isGlass ? t.onAccent : Colors.black),
                    disabledForegroundColor: (t.isGlass ? t.onAccent : Colors.black).withValues(alpha: 0.4),
                  ),
                  child: Text(context.l10n.confirm),
                ),
              ],
            );
          },
        );
      },
    );
  }
}
