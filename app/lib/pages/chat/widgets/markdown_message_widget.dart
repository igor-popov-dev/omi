import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:url_launcher/url_launcher.dart';
import 'package:omi/utils/theme/omi_tokens.dart';

import 'package:omi/utils/l10n_extensions.dart';

const TextStyle _kCodeTextStyle = TextStyle(
  color: Colors.white,
  backgroundColor: Colors.transparent,
  fontFamily: 'monospace',
);
const EdgeInsets _kCodeBlockPadding = EdgeInsets.all(8);

/// Fenced code blocks (``` or ~~~) of [markdown], without fences and info strings.
/// Mirrors what the markdown parser treats as a `pre` block, so the "copy code"
/// action of a message and the per-block copy button return the same text.
List<String> extractCodeBlocks(String markdown) {
  final blocks = <String>[];
  final fence = RegExp(r'^\s{0,3}(`{3,}|~{3,})');
  String? openFence;
  final buffer = <String>[];

  for (final line in markdown.split('\n')) {
    final match = fence.firstMatch(line);
    if (openFence == null) {
      if (match != null) {
        openFence = match.group(1);
        buffer.clear();
      }
      continue;
    }
    final closes = match != null && match.group(1)![0] == openFence[0] && match.group(1)!.length >= openFence.length;
    if (closes && line.substring(match.end).trim().isEmpty) {
      blocks.add(buffer.join('\n'));
      openFence = null;
    } else {
      buffer.add(line);
    }
  }
  // An unterminated fence (message still streaming) is still a code block.
  if (openFence != null && buffer.isNotEmpty) blocks.add(buffer.join('\n'));
  return blocks;
}

/// Copies [text] and shows the app's usual short snackbar feedback.
Future<void> copyToClipboardWithFeedback(BuildContext context, String text, String feedback) async {
  HapticFeedback.lightImpact();
  await Clipboard.setData(ClipboardData(text: text));
  if (!context.mounted) return;
  ScaffoldMessenger.maybeOf(context)
    ?..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(feedback, style: const TextStyle(color: Colors.white, fontSize: 12.0)),
        duration: const Duration(milliseconds: 1500),
      ),
    );
}

/// Small "copy" button pinned to the top-right corner of a fenced code block.
class CodeBlockCopyButton extends StatelessWidget {
  final String code;

  const CodeBlockCopyButton({super.key, required this.code});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // The chip carries its own surface so the icon stays readable on the
    // fixed dark code background in both light and dark themes.
    return Material(
      color: theme.colorScheme.surface.withValues(alpha: 0.9),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(6),
        side: BorderSide(color: theme.dividerColor),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => copyToClipboardWithFeedback(context, code, context.l10n.codeCopied),
        child: Tooltip(
          message: context.l10n.copyCode,
          child: Padding(
            padding: const EdgeInsets.all(5),
            child: Icon(Icons.copy_rounded, size: 14, color: theme.colorScheme.onSurface),
          ),
        ),
      ),
    );
  }
}

/// Renders `pre` blocks like flutter_markdown does by default (horizontally
/// scrollable, monospace) and overlays [CodeBlockCopyButton].
class _CodeBlockBuilder extends MarkdownElementBuilder {
  /// flutter_markdown only closes the inline scope of a block it delegates to a
  /// builder when [visitText] produced a widget; without this the builder
  /// trips `assert(_inlines.isEmpty)` on the next block. The placeholder is
  /// discarded because [visitElementAfterWithContext] replaces the block.
  @override
  Widget? visitText(md.Text text, TextStyle? preferredStyle) => const SizedBox.shrink();

  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    final code = element.textContent.replaceAll(RegExp(r'\n$'), '');
    return Stack(
      children: [
        _HorizontalCodeScroller(code: code),
        Positioned(top: 4, right: 4, child: CodeBlockCopyButton(code: code)),
      ],
    );
  }
}

class _HorizontalCodeScroller extends StatefulWidget {
  final String code;

  const _HorizontalCodeScroller({required this.code});

  @override
  State<_HorizontalCodeScroller> createState() => _HorizontalCodeScrollerState();
}

class _HorizontalCodeScrollerState extends State<_HorizontalCodeScroller> {
  final _controller = ScrollController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scrollbar(
      controller: _controller,
      child: SingleChildScrollView(
        controller: _controller,
        scrollDirection: Axis.horizontal,
        // Extra right padding keeps narrow snippets from sliding under the button.
        padding: _kCodeBlockPadding.copyWith(right: _kCodeBlockPadding.right + 28),
        child: Text.rich(TextSpan(style: _kCodeTextStyle, text: widget.code)),
      ),
    );
  }
}

Widget getMarkdownWidget(BuildContext context, String message, {Function(String)? onAskOmi}) {
  final t = context.omi;
  return MarkdownBody(
    data: message.trimRight(),
    selectable: false,
    builders: {'pre': _CodeBlockBuilder()},
    styleSheet: MarkdownStyleSheet(
      p: TextStyle(color: t.textPrimary, fontSize: 16, height: 1.4),
      a: const TextStyle(color: Colors.blue, decoration: TextDecoration.underline),
      listBullet: TextStyle(color: t.textPrimary, fontSize: 16),
      blockquote: TextStyle(color: t.textPrimary, fontSize: 16, height: 1.4, backgroundColor: Colors.transparent),
      blockquoteDecoration: BoxDecoration(color: t.bgTertiary, borderRadius: BorderRadius.circular(4)),
      code: _kCodeTextStyle,
      codeblockPadding: _kCodeBlockPadding,
      codeblockDecoration: BoxDecoration(color: t.bgSecondary, borderRadius: BorderRadius.circular(8)),
    ),
    onTapLink: (text, href, title) {
      if (href != null) {
        launchUrl(Uri.parse(href));
      }
    },
  );
}
