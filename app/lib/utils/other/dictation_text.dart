import 'package:flutter/services.dart';

/// Merge a freshly transcribed voice message into whatever is already in the
/// chat composer instead of replacing it, so a recording can continue a draft
/// the user started — by typing, or by dictating an earlier chunk.
///
/// The transcript lands at the caret (replacing the selection when there is
/// one) and falls back to the end of the draft when the field was never
/// focused, which is the common case: the composer loses focus while the
/// waveform takes its place. Spacing is added only where the join would
/// otherwise run two words together, so dictating into an empty field yields
/// exactly the transcript.
TextEditingValue insertDictation(TextEditingValue current, String transcript) {
  final insert = transcript.trim();
  if (insert.isEmpty) return current;

  final text = current.text;
  final selection = current.selection;
  // An unfocused field reports an invalid (-1) selection — append there.
  final start = selection.isValid ? selection.start : text.length;
  final end = selection.isValid ? selection.end : text.length;

  final before = text.substring(0, start);
  final after = text.substring(end);

  final needsLeadingSpace = before.isNotEmpty && !before.endsWith(' ') && !before.endsWith('\n');
  final needsTrailingSpace = after.isNotEmpty && !after.startsWith(' ') && !after.startsWith('\n');

  final inserted = '${needsLeadingSpace ? ' ' : ''}$insert${needsTrailingSpace ? ' ' : ''}';
  final caret = before.length + inserted.length - (needsTrailingSpace ? 1 : 0);

  return TextEditingValue(
    text: '$before$inserted$after',
    selection: TextSelection.collapsed(offset: caret),
  );
}
