import 'package:flutter/material.dart';

import 'package:omi/utils/theme/omi_tokens.dart';

class OmiConfirmDialog {
  static Future<bool?> show(
    BuildContext context, {
    required String title,
    required String message,
    String confirmLabel = 'Confirm',
    String cancelLabel = 'Cancel',
    Color? confirmColor,
  }) {
    final t = context.omi;
    confirmColor ??= t.error;
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: t.bgSecondary,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(t.cardRadius)),
        title: Text(
          title,
          style: TextStyle(color: t.textPrimary, fontSize: 18, fontWeight: FontWeight.w600),
        ),
        content: Text(message, style: TextStyle(color: t.textSecondary, fontSize: 14)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(cancelLabel, style: TextStyle(color: t.textSecondary)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(confirmLabel, style: TextStyle(color: confirmColor)),
          ),
        ],
      ),
    );
  }

  static Future<ConfirmationResult?> showWithSkipOption(
    BuildContext context, {
    required String title,
    required String message,
    String confirmLabel = 'Confirm',
    String cancelLabel = 'Cancel',
    String skipLabel = 'Do not show this again',
    Color? confirmColor,
  }) {
    final t = context.omi;
    confirmColor ??= t.error;
    bool skipFutureConfirmations = false;

    return showDialog<ConfirmationResult>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          backgroundColor: t.bgSecondary,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(t.cardRadius)),
          title: Text(
            title,
            style: TextStyle(color: t.textPrimary, fontSize: 18, fontWeight: FontWeight.w600),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(message, style: TextStyle(color: t.textSecondary, fontSize: 14)),
              const SizedBox(height: 16),
              Row(
                children: [
                  SizedBox(
                    height: 24,
                    width: 24,
                    child: Checkbox(
                      value: skipFutureConfirmations,
                      onChanged: (value) {
                        setState(() {
                          skipFutureConfirmations = value ?? false;
                        });
                      },
                      activeColor: t.accent,
                      checkColor: t.bgPrimary,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(skipLabel, style: TextStyle(color: t.textSecondary, fontSize: 12)),
                  ),
                ],
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(
                ctx,
                ConfirmationResult(confirmed: false, skipFutureConfirmations: skipFutureConfirmations),
              ),
              child: Text(cancelLabel, style: TextStyle(color: t.textSecondary)),
            ),
            TextButton(
              onPressed: () => Navigator.pop(
                ctx,
                ConfirmationResult(confirmed: true, skipFutureConfirmations: skipFutureConfirmations),
              ),
              child: Text(confirmLabel, style: TextStyle(color: confirmColor)),
            ),
          ],
        ),
      ),
    );
  }
}

class ConfirmationResult {
  final bool confirmed;
  final bool skipFutureConfirmations;

  const ConfirmationResult({required this.confirmed, required this.skipFutureConfirmations});
}
