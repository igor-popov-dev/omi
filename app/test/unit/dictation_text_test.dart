import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:omi/utils/other/dictation_text.dart';

TextEditingValue draft(String text, {int? caret}) => TextEditingValue(
      text: text,
      selection: caret == null ? const TextSelection.collapsed(offset: -1) : TextSelection.collapsed(offset: caret),
    );

void main() {
  group('insertDictation', () {
    test('an empty composer receives exactly the transcript', () {
      final result = insertDictation(draft(''), 'call the dentist');

      expect(result.text, 'call the dentist');
      expect(result.selection.baseOffset, 'call the dentist'.length);
    });

    test('a second recording continues the draft instead of replacing it', () {
      final result = insertDictation(draft('call the dentist'), 'and book a table');

      expect(result.text, 'call the dentist and book a table');
      expect(result.selection.baseOffset, result.text.length);
    });

    test('the join never doubles a space the draft already ends with', () {
      final result = insertDictation(draft('call the dentist '), '  and book a table  ');

      expect(result.text, 'call the dentist and book a table');
    });

    test('a caret inside the draft dictates at that point, not at the end', () {
      // "call the |dentist" — caret before the last word.
      final result = insertDictation(draft('call the dentist', caret: 9), 'nearest');

      expect(result.text, 'call the nearest dentist');
      expect(result.selection.baseOffset, 'call the nearest'.length);
    });

    test('a selection is replaced by the transcript', () {
      const value = TextEditingValue(
        text: 'call the dentist',
        selection: TextSelection(baseOffset: 9, extentOffset: 16),
      );

      final result = insertDictation(value, 'plumber');

      expect(result.text, 'call the plumber');
      expect(result.selection.baseOffset, result.text.length);
    });

    test('an unfocused field (invalid selection) appends at the end', () {
      final result = insertDictation(draft('typed by hand'), 'said out loud');

      expect(result.text, 'typed by hand said out loud');
    });

    test('an empty or blank transcript leaves the draft untouched', () {
      final value = draft('call the dentist', caret: 4);

      expect(insertDictation(value, ''), value);
      expect(insertDictation(value, '   '), value);
    });

    test('a newline in the draft is treated as separation already present', () {
      final result = insertDictation(draft('first line\n'), 'second line');

      expect(result.text, 'first line\nsecond line');
    });
  });
}
