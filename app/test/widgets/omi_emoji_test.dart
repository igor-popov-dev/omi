import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/utils/theme/omi_emoji.dart';
import 'package:omi/utils/theme/omi_theme.dart';
import 'package:omi/utils/theme/omi_tokens.dart';

Widget _wrap(OmiTokens tokens, Widget child) =>
    MaterialApp(theme: buildOmiTheme(tokens), home: Scaffold(body: Center(child: child)));

void main() {
  group('OmiEmoji', () {
    testWidgets('classic keeps the colored system emoji', (tester) async {
      await tester.pumpWidget(_wrap(OmiTokens.classic, const OmiEmoji('🧠', size: 22)));

      expect(find.byType(Icon), findsNothing);
      final text = tester.widget<Text>(find.text('🧠'));
      expect(text.style?.fontFamily, isNull);
      expect(text.style?.fontSize, 22);
    });

    testWidgets('glass draws a Lucide icon for a mapped emoji', (tester) async {
      await tester.pumpWidget(_wrap(OmiTokens.glass, const OmiEmoji('🧠', size: 22)));

      expect(find.text('🧠'), findsNothing);
      final icon = tester.widget<Icon>(find.byType(Icon));
      expect(icon.icon, OmiEmoji.lucideFor('🧠'));
      expect(icon.size, 22);
      expect(icon.color, OmiTokens.glass.textSecondary);
    });

    testWidgets('glass falls back to the monochrome Noto Emoji font', (tester) async {
      await tester.pumpWidget(_wrap(OmiTokens.glass, const OmiEmoji('🦄', size: 20)));

      expect(find.byType(Icon), findsNothing);
      final text = tester.widget<Text>(find.text('🦄'));
      expect(text.style?.fontFamily, kOmiEmojiFontFamily);
      expect(text.style?.color, OmiTokens.glass.textSecondary);
    });

    test('map keys cover the emoji the app can pick', () {
      // Folder icons, goal emoji and the category/summary defaults.
      for (final emoji in ['📁', '❤️', '👨‍👩‍👧‍👦', '🛠️', '🎯', '✍️', '⚖️', '🧑‍💻', '🧠', '📅']) {
        expect(OmiEmoji.lucideFor(emoji), isNotNull, reason: 'no Lucide glyph for $emoji');
      }
    });
  });
}
