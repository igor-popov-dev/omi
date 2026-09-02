import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'package:omi/utils/l10n_extensions.dart';
import 'package:omi/utils/platform/platform_service.dart';
import 'package:omi/utils/theme/omi_tokens.dart';

getDialog(
  BuildContext context,
  Function onCancel,
  Function onConfirm,
  String title,
  String content, {
  bool singleButton = false,
  String? okButtonText,
  String? cancelButtonText,
}) {
  final t = context.omi;
  final okText = okButtonText ?? context.l10n.ok;
  final cancelText = cancelButtonText ?? context.l10n.cancel;

  var actions = singleButton
      ? [
          TextButton(
            onPressed: () => onCancel(),
            child: Text(okText, style: TextStyle(color: t.textPrimary)),
          ),
        ]
      : [
          TextButton(
            onPressed: () => onCancel(),
            child: Text(cancelText, style: TextStyle(color: t.textPrimary)),
          ),
          TextButton(
            onPressed: () => onConfirm(),
            child: Text(okText, style: TextStyle(color: t.textPrimary)),
          ),
        ];
  if (PlatformService.isApple) {
    return CupertinoAlertDialog(title: Text(title), content: Text(content), actions: actions);
  }
  return AlertDialog(title: Text(title), content: Text(content), actions: actions);
}
