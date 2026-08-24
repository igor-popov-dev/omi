import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:omi/backend/schema/dev_api_key.dart';
import 'package:omi/utils/alerts/app_snackbar.dart';
import 'package:omi/utils/l10n_extensions.dart';
import 'package:omi/utils/theme/omi_tokens.dart';
import 'package:omi/utils/theme/omi_icons.dart';

class DevApiKeyCreatedSheet extends StatefulWidget {
  final DevApiKeyCreated apiKey;

  const DevApiKeyCreatedSheet({super.key, required this.apiKey});

  @override
  State<DevApiKeyCreatedSheet> createState() => _DevApiKeyCreatedSheetState();
}

class _DevApiKeyCreatedSheetState extends State<DevApiKeyCreatedSheet> {
  bool _copied = false;

  void _copyKey(BuildContext context) {
    Clipboard.setData(ClipboardData(text: widget.apiKey.key));
    setState(() => _copied = true);
    AppSnackbar.showSnackbar(context.l10n.copiedToClipboard(context.l10n.apiKey));
  }

  @override
  Widget build(BuildContext context) {
    final t = context.omi;

    return Container(
      decoration: BoxDecoration(
        color: t.bgPrimary,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Handle bar
          Center(
            child: Container(
              margin: const EdgeInsets.only(top: 12, bottom: 8),
              width: 40,
              height: 4,
              decoration: BoxDecoration(color: t.divider, borderRadius: BorderRadius.circular(2)),
            ),
          ),
          // Success header
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
            child: Column(
              children: [
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: t.isGlass ? t.success.withValues(alpha: 0.12) : null,
                    gradient: t.isGlass
                        ? null
                        : LinearGradient(
                            colors: [
                              const Color(0xFF10B981).withValues(alpha: 0.2),
                              const Color(0xFF10B981).withValues(alpha: 0.05),
                            ],
                          ),
                    shape: BoxShape.circle,
                  ),
                  child: OmiIconWidget(icon: OmiIcon.checkCircle, color: t.success, size: 40),
                ),
                const SizedBox(height: 16),
                Text(
                  context.l10n.apiKeyCreated,
                  style: TextStyle(color: t.textPrimary, fontSize: 22, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 6),
                Text(widget.apiKey.name, style: TextStyle(color: t.textSecondary, fontSize: 14)),
              ],
            ),
          ),
          const SizedBox(height: 24),
          // Warning banner
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: t.warning.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: t.warning.withValues(alpha: 0.2)),
              ),
              child: Row(
                children: [
                  OmiIconWidget(icon: OmiIcon.warning, color: t.warning, size: 20),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      context.l10n.saveKeyWarning,
                      style: TextStyle(color: t.warning, fontSize: 13, fontWeight: FontWeight.w500),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 20),
          // Key display
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: GestureDetector(
              onTap: () => _copyKey(context),
              child: Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: t.bgSecondary,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: _copied ? t.success : t.bgTertiary,
                    width: _copied ? 1.5 : 1,
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          context.l10n.yourApiKey,
                          style: TextStyle(
                            color: t.textSecondary,
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            letterSpacing: 0.5,
                          ),
                        ),
                        const Spacer(),
                        AnimatedContainer(
                          duration: const Duration(milliseconds: 200),
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(
                            color: _copied ? t.success.withValues(alpha: 0.15) : t.bgTertiary,
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                _copied ? Icons.check : Icons.copy,
                                size: 14,
                                color: _copied ? t.success : t.textSecondary,
                              ),
                              const SizedBox(width: 4),
                              Text(
                                _copied ? context.l10n.copied : context.l10n.tapToCopy,
                                style: TextStyle(
                                  color: _copied ? t.success : t.textSecondary,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    SelectableText(
                      widget.apiKey.key,
                      style: TextStyle(
                        fontFamily: 'monospace',
                        color: _copied ? t.success : t.accent,
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                        height: 1.4,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 28),
          // Buttons
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => _copyKey(context),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: _copied ? t.success : t.accent,
                      side: BorderSide(color: _copied ? t.success : t.accent, width: 1.5),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(_copied ? Icons.check : Icons.copy, size: 18),
                        const SizedBox(width: 8),
                        Text(
                          _copied ? context.l10n.copied : context.l10n.copyKey,
                          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton(
                    onPressed: () => Navigator.of(context).pop(),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: t.bgTertiary,
                      foregroundColor: t.textPrimary,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      elevation: 0,
                    ),
                    child: Text(context.l10n.done, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                  ),
                ),
              ],
            ),
          ),
          SizedBox(height: MediaQuery.of(context).padding.bottom),
        ],
      ),
    );
  }
}
