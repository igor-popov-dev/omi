import 'package:flutter/material.dart';

import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:omi/utils/theme/omi_tokens.dart';

Widget getMarkdownWidget(BuildContext context, String message, {Function(String)? onAskOmi}) {
  final t = context.omi;
  return MarkdownBody(
    data: message.trimRight(),
    selectable: false,
    styleSheet: MarkdownStyleSheet(
      p: TextStyle(color: t.textPrimary, fontSize: 16, height: 1.4),
      a: const TextStyle(color: Colors.blue, decoration: TextDecoration.underline),
      listBullet: TextStyle(color: t.textPrimary, fontSize: 16),
      blockquote: TextStyle(color: t.textPrimary, fontSize: 16, height: 1.4, backgroundColor: Colors.transparent),
      blockquoteDecoration: BoxDecoration(color: t.bgTertiary, borderRadius: BorderRadius.circular(4)),
      code: TextStyle(color: t.textPrimary, backgroundColor: Colors.transparent, fontFamily: 'monospace'),
      codeblockDecoration: BoxDecoration(color: t.bgSecondary, borderRadius: BorderRadius.circular(8)),
    ),
    onTapLink: (text, href, title) {
      if (href != null) {
        launchUrl(Uri.parse(href));
      }
    },
  );
}
