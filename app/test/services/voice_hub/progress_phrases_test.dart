// Tests for `progress_phrases.dart` — the activity wire contract and the
// no-repeat phrase picker behind the ask_claude wait notices.
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';

import 'package:omi/services/voice_hub/progress_phrase_bank.g.dart';
import 'package:omi/services/voice_hub/progress_phrases.dart';

const _a = ProgressPhrase('a.mp3', 'a');
const _b = ProgressPhrase('b.mp3', 'b');
const _c = ProgressPhrase('c.mp3', 'c');
const _g1 = ProgressPhrase('g1.mp3', 'g1');
const _g2 = ProgressPhrase('g2.mp3', 'g2');

void main() {
  group('ClaudeActivity.fromWire', () {
    test('maps every wire name to itself and anything else to generic', () {
      for (final value in ClaudeActivity.values) {
        expect(ClaudeActivity.fromWire(value.name), value);
      }
      expect(ClaudeActivity.fromWire('nonsense'), ClaudeActivity.generic);
      expect(ClaudeActivity.fromWire(null), ClaudeActivity.generic);
      expect(ClaudeActivity.fromWire(''), ClaudeActivity.generic);
    });
  });

  group('ProgressPhraseBank', () {
    test('never picks the same phrase twice in a row for an activity', () {
      final bank = ProgressPhraseBank({
        ClaudeActivity.read: [_a, _b, _c],
      }, random: Random(1));
      ProgressPhrase? previous;
      for (var i = 0; i < 50; i++) {
        final picked = bank.pick(ClaudeActivity.read);
        expect(picked, isNotNull);
        expect(picked, isNot(equals(previous)), reason: 'итерация $i');
        previous = picked;
      }
    });

    test('falls back to generic phrases for an activity without its own', () {
      final bank = ProgressPhraseBank({
        ClaudeActivity.generic: [_g1, _g2],
      }, random: Random(2));
      expect(bank.pick(ClaudeActivity.web), anyOf(_g1, _g2));
      expect(bank.pick(ClaudeActivity.agents), anyOf(_g1, _g2));
    });

    test('a single-phrase activity alternates with generic instead of repeating', () {
      final bank = ProgressPhraseBank({
        ClaudeActivity.memory: [_a],
        ClaudeActivity.generic: [_g1, _g2],
      }, random: Random(3));
      expect(bank.pick(ClaudeActivity.memory), _a);
      expect(bank.pick(ClaudeActivity.memory), anyOf(_g1, _g2), reason: 'единственная фраза только что звучала');
      expect(bank.pick(ClaudeActivity.memory), _a);
    });

    test('repeats only when there is nothing else at all, and returns null on an empty bank', () {
      final lonely = ProgressPhraseBank({
        ClaudeActivity.run: [_a],
      });
      expect(lonely.pick(ClaudeActivity.run), _a);
      expect(lonely.pick(ClaudeActivity.run), _a, reason: 'повтор лучше молчания');
      expect(ProgressPhraseBank(const {}).pick(ClaudeActivity.think), isNull);
    });

    test('the generated bank has a fallback and every asset path is under assets/sounds/progress/', () {
      // generic или think — страховка для любого типа без своих файлов;
      // без них банк молчит ровно там, где тип не распознан.
      expect(
        (progressPhraseAssets[ClaudeActivity.generic] ?? const []).isNotEmpty ||
            (progressPhraseAssets[ClaudeActivity.think] ?? const []).isNotEmpty,
        isTrue,
      );
      for (final entry in progressPhraseAssets.entries) {
        for (final phrase in entry.value) {
          expect(phrase.asset, startsWith('assets/sounds/progress/${entry.key.name}_'));
          expect(phrase.text, isNotEmpty);
        }
      }
    });
  });
}
