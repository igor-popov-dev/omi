import 'dart:io';
import 'dart:ui' as ui;

import 'package:omi/utils/platform/platform_manager.dart';
import 'package:flutter/material.dart';

import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';

import 'package:omi/backend/http/api/apps.dart';
import 'package:omi/backend/preferences.dart';
import 'package:omi/backend/schema/app.dart';
import 'package:omi/utils/l10n_extensions.dart';
import 'package:omi/pages/conversation_detail/conversation_detail_provider.dart';
import 'package:omi/pages/conversation_detail/widgets/summarized_apps_sheet.dart';
import 'package:omi/pages/conversation_detail/widgets/template_creation_outcome.dart';
import 'package:omi/providers/app_provider.dart';
import 'package:omi/utils/alerts/app_snackbar.dart';
import 'package:omi/utils/logger.dart';
import 'package:omi/utils/theme/glass_effects.dart';
import 'package:omi/utils/theme/omi_tokens.dart';
import 'package:omi/widgets/omi_switch.dart';

class CreateTemplateBottomSheet extends StatefulWidget {
  final String? conversationId;
  final ScrollController? scrollController;

  const CreateTemplateBottomSheet({super.key, this.conversationId, this.scrollController});

  @override
  State<CreateTemplateBottomSheet> createState() => _CreateTemplateBottomSheetState();
}

class _CreateTemplateBottomSheetState extends State<CreateTemplateBottomSheet> {
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _promptController = TextEditingController();
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();

  bool _isPublic = false;
  bool _isCreating = false;
  String _statusMessage = '';

  @override
  void dispose() {
    _nameController.dispose();
    _promptController.dispose();
    super.dispose();
  }

  Future<File> _createEmojiIcon(String emoji) async {
    final t = context.omi;
    // Create a simple widget with white background and emoji
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    const size = 256.0;

    // Draw white background
    final bgPaint = Paint()..color = t.textPrimary;
    canvas.drawRect(const Rect.fromLTWH(0, 0, size, size), bgPaint);

    // Draw emoji text
    final textPainter = TextPainter(
      text: TextSpan(text: emoji, style: const TextStyle(fontSize: 140)),
      textDirection: TextDirection.ltr,
    );
    textPainter.layout();

    // Center the emoji
    final offsetX = (size - textPainter.width) / 2;
    final offsetY = (size - textPainter.height) / 2;
    textPainter.paint(canvas, Offset(offsetX, offsetY));

    // Convert to image
    final picture = recorder.endRecording();
    final image = await picture.toImage(size.toInt(), size.toInt());
    final byteData = await image.toByteData(format: ui.ImageByteFormat.png);

    if (byteData == null) {
      throw Exception('Failed to create icon image');
    }

    // Save to temp file
    final tempDir = await getTemporaryDirectory();
    final file = File('${tempDir.path}/emoji_icon_${DateTime.now().millisecondsSinceEpoch}.png');
    await file.writeAsBytes(byteData.buffer.asUint8List());

    return file;
  }

  Future<void> _createTemplate() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _isCreating = true;
      _statusMessage = context.l10n.generatingDescription;
    });

    try {
      final name = _nameController.text.trim();
      final prompt = _promptController.text.trim();
      const category = 'conversation-analysis';

      // Generate description and emoji using AI
      final result = await getGeneratedDescriptionAndEmoji(name, prompt);
      final description = result.description;
      final emoji = result.emoji;

      setState(() {
        _statusMessage = context.l10n.creatingAppIcon;
      });

      // Create simple emoji icon
      final iconFile = await _createEmojiIcon(emoji);

      setState(() {
        _statusMessage = context.l10n.creatingYourApp;
      });

      // Prepare app data
      final Map<String, dynamic> appData = {
        'name': name,
        'description': description,
        'capabilities': ['memories'],
        'deleted': false,
        'uid': SharedPreferencesUtil().uid,
        'category': category,
        'private': !_isPublic,
        'is_paid': false,
        'price': 0.0,
        'memory_prompt': prompt,
        'thumbnails': [],
      };

      // Submit app
      final submitResult = await submitAppServer(iconFile, appData);

      // Clean up temp icon file
      if (iconFile.existsSync()) {
        await iconFile.delete();
      }

      if (submitResult.$1) {
        // Success
        PlatformManager.instance.analytics.quickTemplateCreated(
          conversationId: widget.conversationId ?? '',
          appName: name,
          isPublic: _isPublic,
        );

        // Refresh apps list
        if (mounted) {
          await context.read<AppProvider>().getApps();
        }

        // Get the created app
        App? createdApp;
        if (submitResult.$3 != null && mounted) {
          final appDetails = await getAppDetailsServer(submitResult.$3!);
          if (appDetails != null) {
            createdApp = App.fromJson(appDetails);
          }
        }

        if (mounted && createdApp != null) {
          setState(() {
            _statusMessage = context.l10n.installingApp;
          });

          // Enable/install through the provider: it owns prefs, app-list
          // state, and the failure dialog, so a failed install can no longer
          // be reported as success (#10074 follow-up).
          final success = await context.read<AppProvider>().toggleApp(createdApp.id, true, null);
          if (success) {
            createdApp.enabled = true;

            // Update the conversation detail provider's cached apps
            if (mounted) {
              final conversationProvider = context.read<ConversationDetailProvider>();
              conversationProvider.addToEnabledConversationApps(createdApp);
            }
          }

          if (mounted) {
            // Close the create template bottom sheet
            Navigator.pop(context);
            // Polarity comes from the tested classifier so a failed install
            // can never be reported as success (#10074).
            final outcome = success ? TemplateCreationOutcome.installed : TemplateCreationOutcome.installFailed;
            if (templateCreationOutcomeIsError(outcome)) {
              // The provider already showed the failure dialog; tell the user
              // what state they are actually in.
              AppSnackbar.showSnackbarError(context.l10n.failedToInstallApp(createdApp.name));
            } else {
              AppSnackbar.showSnackbarSuccess(context.l10n.appCreatedAndInstalled);

              // Show the summarized apps sheet so user can use the new app
              showModalBottomSheet(
                context: context,
                isScrollControlled: true,
                backgroundColor: Colors.transparent,
                builder: (context) => const SummarizedAppsBottomSheet(),
              );
            }
          }
        } else if (mounted) {
          Navigator.pop(context);
          AppSnackbar.showSnackbarSuccess(context.l10n.appCreatedSuccessfully);
        }
      } else {
        // Error
        if (mounted) {
          setState(() {
            _isCreating = false;
            _statusMessage = '';
          });
          AppSnackbar.showSnackbarError(submitResult.$2.isNotEmpty ? submitResult.$2 : context.l10n.failedToCreateApp);
        }
      }
    } catch (e) {
      Logger.debug('Error creating template: $e');
      if (mounted) {
        setState(() {
          _isCreating = false;
          _statusMessage = '';
        });
        AppSnackbar.showSnackbarError(context.l10n.failedToCreateApp);
      }
    }
  }

  /// Радиус панели — скруглены только верхние углы, нижние уходят за экран.
  static const BorderRadius _sheetRadius = BorderRadius.vertical(top: Radius.circular(24));

  /// Размытие страницы под панелью — то же 38, что у шторки настроек и у
  /// панели «Шаблон сводки», из которой эта панель и открывается: два стекла
  /// подряд не должны отличаться плотностью.
  static const double _sheetBlurSigma = 38;

  /// Вуаль панели в Glass — белый 0.62 вместо токена `bgPrimary` (0.46).
  /// Токен честен на подложке [GlassBackdrop], но здесь панель стоит поверх
  /// страницы разговора с её собственным текстом; блюр снимает разборчивость,
  /// вуаль добивает остаточный контраст.
  static const Color _glassSheetVeil = Color(0x9EFFFFFF);

  @override
  Widget build(BuildContext context) {
    final t = context.omi;
    final content = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Handle bar
        Container(
          width: 40,
          height: 4,
          margin: const EdgeInsets.only(top: 12),
          decoration: BoxDecoration(color: t.textTertiary, borderRadius: BorderRadius.circular(2)),
        ),

        // Header
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [t.accent, t.accent],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(t.rowRadius),
                ),
                child: Icon(Icons.auto_fix_high, color: t.textPrimary, size: 20),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Text(
                  context.l10n.createCustomTemplate,
                  style: TextStyle(color: t.textPrimary, fontSize: 18, fontWeight: FontWeight.w600),
                ),
              ),
              IconButton(
                onPressed: _isCreating ? null : () => Navigator.pop(context),
                icon: Icon(Icons.close, color: t.textSecondary),
              ),
            ],
          ),
        ),

        // Form content
        Flexible(
          child: SingleChildScrollView(
            controller: widget.scrollController,
            padding: const EdgeInsets.only(left: 20, right: 20, top: 20, bottom: 20),
            child: Form(
              key: _formKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Name field
                  Text(
                    context.l10n.templateName,
                    style: TextStyle(color: t.textSecondary, fontSize: 14, fontWeight: FontWeight.w500),
                  ),
                  const SizedBox(height: 8),
                  TextFormField(
                    controller: _nameController,
                    enabled: !_isCreating,
                    style: TextStyle(color: t.textPrimary),
                    decoration: InputDecoration(
                      hintText: context.l10n.templateNameHint,
                      hintStyle: TextStyle(color: t.textTertiary),
                      filled: true,
                      fillColor: t.bgSecondary,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(t.rowRadius),
                        borderSide: BorderSide.none,
                      ),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                    ),
                    validator: (value) {
                      if (value == null || value.trim().isEmpty) {
                        return context.l10n.pleaseEnterAppName;
                      }
                      if (value.trim().length < 3) {
                        return context.l10n.nameMustBeAtLeast3Characters;
                      }
                      return null;
                    },
                  ),

                  const SizedBox(height: 20),

                  // Prompt field
                  Text(
                    context.l10n.conversationPrompt,
                    style: TextStyle(color: t.textSecondary, fontSize: 14, fontWeight: FontWeight.w500),
                  ),
                  const SizedBox(height: 8),
                  TextFormField(
                    controller: _promptController,
                    enabled: !_isCreating,
                    style: TextStyle(color: t.textPrimary),
                    maxLines: 4,
                    decoration: InputDecoration(
                      hintText: context.l10n.conversationPromptHint,
                      hintStyle: TextStyle(color: t.textTertiary),
                      filled: true,
                      fillColor: t.bgSecondary,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(t.rowRadius),
                        borderSide: BorderSide.none,
                      ),
                      contentPadding: const EdgeInsets.all(16),
                    ),
                    validator: (value) {
                      if (value == null || value.trim().isEmpty) {
                        return context.l10n.pleaseEnterAppPrompt;
                      }
                      if (value.trim().length < 10) {
                        return context.l10n.promptMustBeAtLeast10Characters;
                      }
                      return null;
                    },
                  ),

                  const SizedBox(height: 20),

                  // Public toggle
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: t.bgSecondary,
                      borderRadius: BorderRadius.circular(t.rowRadius),
                    ),
                    child: Row(
                      children: [
                        Container(
                          width: 40,
                          height: 40,
                          decoration: BoxDecoration(
                            color: t.bgTertiary,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Center(
                            child: FaIcon(
                              _isPublic ? FontAwesomeIcons.globe : FontAwesomeIcons.lock,
                              color: t.textSecondary,
                              size: 16,
                            ),
                          ),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                context.l10n.makePublic,
                                style: TextStyle(
                                  color: t.textPrimary,
                                  fontSize: 16,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                _isPublic ? context.l10n.anyoneCanDiscoverTemplate : context.l10n.onlyYouCanUseTemplate,
                                style: TextStyle(color: t.textSecondary, fontSize: 13),
                              ),
                            ],
                          ),
                        ),
                        OmiSwitch(
                          value: _isPublic,
                          onChanged: _isCreating
                              ? null
                              : (value) {
                                  setState(() {
                                    _isPublic = value;
                                  });
                                },
                          classicActiveThumbColor: t.accent,
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 24),

                  // Create button
                  SizedBox(
                    width: double.infinity,
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      child: ElevatedButton(
                        onPressed: _isCreating ? null : _createTemplate,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: _isCreating ? t.bgTertiary : t.textPrimary,
                          foregroundColor: t.bgPrimary,
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(t.rowRadius)),
                          elevation: 0,
                        ),
                        child: _isCreating
                            ? Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      valueColor: AlwaysStoppedAnimation<Color>(t.textPrimary),
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Text(
                                    _statusMessage,
                                    style: TextStyle(
                                      color: t.textPrimary,
                                      fontSize: 16,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ],
                              )
                            : Text(
                                context.l10n.createApp,
                                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                              ),
                      ),
                    ),
                  ),

                  SizedBox(height: MediaQuery.of(context).padding.bottom + 8),
                ],
              ),
            ),
          ),
        ),
      ],
    );

    if (!t.isGlass) {
      return GestureDetector(
        onTap: () => FocusScope.of(context).unfocus(),
        child: Container(
          decoration: BoxDecoration(color: t.bgPrimary, borderRadius: _sheetRadius),
          child: content,
        ),
      );
    }

    // Glass: под панелью честное стекло — сначала размывается всё, что уже
    // нарисовано ниже, и только поверх ложится вуаль.
    return GestureDetector(
      onTap: () => FocusScope.of(context).unfocus(),
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

/// Shows the create template bottom sheet
void showCreateTemplateBottomSheet(BuildContext context, {String? conversationId}) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (context) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: DraggableScrollableSheet(
        initialChildSize: 0.65,
        minChildSize: 0.4,
        maxChildSize: 0.95,
        expand: false,
        builder: (context, scrollController) =>
            CreateTemplateBottomSheet(conversationId: conversationId, scrollController: scrollController),
      ),
    ),
  );
}
