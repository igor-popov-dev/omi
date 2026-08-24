import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'package:omi/utils/l10n_extensions.dart';
import 'package:omi/utils/theme/omi_tokens.dart';

class DeleteConfirmation {
  static Future<bool> show(BuildContext context, {String? title, String? content}) async {
    final t = context.omi;
    title ??= context.l10n.deleteMemory;
    content ??= context.l10n.thisActionCannotBeUndone;

    if (Platform.isIOS) {
      return await showCupertinoDialog<bool>(
            context: context,
            builder: (context) => CupertinoAlertDialog(
              title: Text(title!),
              content: Text(content!),
              actions: [
                CupertinoDialogAction(
                  isDefaultAction: true,
                  onPressed: () => Navigator.pop(context, false),
                  child: Text(context.l10n.cancel, style: TextStyle(color: t.textSecondary)),
                ),
                CupertinoDialogAction(
                  isDestructiveAction: true,
                  onPressed: () => Navigator.pop(context, true),
                  child: Text(context.l10n.delete),
                ),
              ],
            ),
          ) ??
          false;
    } else {
      return await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
              backgroundColor: t.bgSecondary,
              surfaceTintColor: Colors.transparent,
              title: Text(title!, style: TextStyle(color: t.textPrimary, fontSize: 18)),
              content: Text(content!, style: TextStyle(color: t.textPrimary.withValues(alpha: 0.7), fontSize: 14)),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: Text(context.l10n.cancel, style: TextStyle(color: t.textSecondary)),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: Text(context.l10n.delete, style: TextStyle(color: t.error)),
                ),
              ],
            ),
          ) ??
          false;
    }
  }
}
