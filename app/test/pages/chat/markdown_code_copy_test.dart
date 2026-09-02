// Copying code out of AI chat messages without manual text selection:
// the per-block copy button rendered by `getMarkdownWidget`, the
// `extractCodeBlocks` helper behind the "Copy code" toolbar action, and the
// extra actions of `omiSelectionMenuBuilder`.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:omi/l10n/app_localizations.dart';
import 'package:omi/pages/chat/widgets/markdown_message_widget.dart';
import 'package:omi/widgets/text_selection_controls.dart';

Widget _app(Widget child, {double? width, Locale locale = const Locale('en')}) {
  return MaterialApp(
    locale: locale,
    theme: ThemeData.dark(),
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(
      body: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(width: width, child: Builder(builder: (context) => child)),
      ),
    ),
  );
}

/// Captures every `Clipboard.setData` call; returns the list of copied texts.
List<String> _mockClipboard() {
  final copied = <String>[];
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (
    call,
  ) async {
    if (call.method == 'Clipboard.setData') {
      copied.add((call.arguments as Map)['text'] as String);
    }
    return null;
  });
  addTearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      null,
    ),
  );
  return copied;
}

/// Stand-in for the `SelectableRegionState` the SelectionArea hands to the
/// context menu builder; only the members the builder touches.
class _FakeSelectionDelegate {
  int hideToolbarCalls = 0;

  TextSelectionToolbarAnchors get contextMenuAnchors =>
      const TextSelectionToolbarAnchors(primaryAnchor: Offset(100, 200), secondaryAnchor: Offset(100, 240));

  void hideToolbar([bool hideHandles = true]) => hideToolbarCalls++;

  void selectAll(SelectionChangedCause cause) {}
}

const _message = '''
Run this:

```bash
flutter pub get
```

then paste:

~~~dart
final answer = 42;
~~~
''';

void main() {
  group('extractCodeBlocks', () {
    test('returns fenced blocks without fences or info strings', () {
      expect(extractCodeBlocks(_message), ['flutter pub get', 'final answer = 42;']);
    });

    test('keeps inner lines and blank lines of a block', () {
      expect(extractCodeBlocks('```\na\n\n  b\n```'), ['a\n\n  b']);
    });

    test('ignores inline code and messages without fences', () {
      expect(extractCodeBlocks('use `x = 1` here'), isEmpty);
      expect(extractCodeBlocks(''), isEmpty);
    });

    test('a fence still streaming (unterminated) counts as a block', () {
      expect(extractCodeBlocks('```py\nprint(1)'), ['print(1)']);
    });

    test('a longer fence closes only with a fence of at least the same length', () {
      expect(extractCodeBlocks('````\n```\ninner\n```\n````'), ['```\ninner\n```']);
    });
  });

  group('code block copy button', () {
    testWidgets('every fenced block gets a button; tapping copies the bare code', (tester) async {
      final copied = _mockClipboard();
      await tester.pumpWidget(_app(Builder(builder: (context) => getMarkdownWidget(context, _message))));
      await tester.pumpAndSettle();

      expect(find.byType(CodeBlockCopyButton), findsNWidgets(2));
      expect(find.text('flutter pub get'), findsOneWidget);

      await tester.tap(find.byType(CodeBlockCopyButton).first);
      await tester.pump();

      expect(copied, ['flutter pub get']);
      expect(find.text('Code copied to clipboard'), findsOneWidget);

      await tester.tap(find.byType(CodeBlockCopyButton).last);
      await tester.pump();
      expect(copied.last, 'final answer = 42;');
    });

    testWidgets('feedback is localized (ru)', (tester) async {
      _mockClipboard();
      await tester.pumpWidget(
        _app(Builder(builder: (context) => getMarkdownWidget(context, '```\nx\n```')), locale: const Locale('ru')),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byType(CodeBlockCopyButton));
      await tester.pump();

      expect(find.text('Код скопирован в буфер обмена'), findsOneWidget);
    });

    testWidgets('no button without code; nothing overflows in a narrow block', (tester) async {
      await tester.pumpWidget(_app(Builder(builder: (context) => getMarkdownWidget(context, 'plain *text*'))));
      await tester.pumpAndSettle();
      expect(find.byType(CodeBlockCopyButton), findsNothing);

      final long = List.filled(20, 'very_long_identifier').join('.');
      await tester.pumpWidget(
        _app(Builder(builder: (context) => getMarkdownWidget(context, '```\nx\n```\n\n```\n$long\n```')), width: 90),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.byType(CodeBlockCopyButton), findsNWidgets(2));
      for (final button in find.byType(CodeBlockCopyButton).evaluate()) {
        final box = button.renderObject! as RenderBox;
        expect(box.size.width, lessThan(40));
        expect(box.size.height, lessThan(40));
      }
    });
  });

  group('omiSelectionMenuBuilder', () {
    testWidgets('offers "Copy message" and "Copy code" when callbacks are given', (tester) async {
      final delegate = _FakeSelectionDelegate();
      var messageCopies = 0;
      var codeCopies = 0;

      await tester.pumpWidget(
        _app(
          Builder(
            builder: (context) => omiSelectionMenuBuilder(
              context,
              delegate,
              (_) {},
              onCopyMessage: () => messageCopies++,
              onCopyCode: () => codeCopies++,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Copy message'), findsOneWidget);
      expect(find.text('Copy code'), findsOneWidget);

      await tester.tap(find.text('Copy code'));
      await tester.pump();
      expect(codeCopies, 1);
      expect(messageCopies, 0);
      expect(delegate.hideToolbarCalls, 1);
    });

    testWidgets('hides "Copy code" for messages without code', (tester) async {
      await tester.pumpWidget(
        _app(Builder(builder: (context) => omiSelectionMenuBuilder(context, _FakeSelectionDelegate(), (_) {}))),
      );
      await tester.pumpAndSettle();

      expect(find.text('Copy code'), findsNothing);
      expect(find.text('Copy message'), findsNothing);
      expect(find.text('Select all'), findsOneWidget);
    });
  });
}
