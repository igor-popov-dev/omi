import 'package:flutter/material.dart';

import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:omi/backend/preferences.dart';
import 'package:omi/utils/theme/omi_tokens.dart';

class MarkdownViewer extends StatefulWidget {
  final String markdown;
  final String title;
  const MarkdownViewer({super.key, required this.markdown, required this.title});

  @override
  State<MarkdownViewer> createState() => _MarkdownViewerState();
}

class _MarkdownViewerState extends State<MarkdownViewer> {
  @override
  Widget build(BuildContext context) {
    final t = context.omi;

    return Scaffold(
      appBar: AppBar(backgroundColor: context.omi.bgPrimary, title: Text(widget.title)),
      backgroundColor: context.omi.bgPrimary,
      body: ListView(
        children: [
          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.only(left: 16.0, right: 24),
            child: MarkdownBody(
              shrinkWrap: true,
              styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
                a: const TextStyle(fontSize: 18, height: 1.2),
                p: const TextStyle(fontSize: 16, height: 1.2),
                blockquote: TextStyle(
                  fontSize: 16,
                  height: 1.2,
                  backgroundColor: Colors.transparent,
                  color: (t.isGlass ? t.onAccent : Colors.black),
                ),
                blockquoteDecoration: BoxDecoration(
                  color: t.bgTertiary,
                  borderRadius: BorderRadius.circular(4),
                ),
                code: TextStyle(
                  fontSize: 16,
                  height: 1.2,
                  backgroundColor: Colors.transparent,
                  decoration: TextDecoration.none,
                  color: t.textPrimary,
                  fontWeight: FontWeight.w500,
                ),
              ),
              data: widget.markdown,
              imageBuilder: (uri, title, alt) {
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8.0),
                  child: Image.network(uri.toString()),
                );
                // return Container();
              },
              onTapLink: (text, href, title) {
                if (href != null) {
                  if (href.contains('?')) {
                    href += '&uid=${SharedPreferencesUtil().uid}';
                  } else {
                    href += '?uid=${SharedPreferencesUtil().uid}';
                  }
                  launchUrl(Uri.parse(href));
                }
              },
            ),
          ),
        ],
      ),
    );
  }
}
