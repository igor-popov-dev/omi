// A 1:1-in-spirit port of the desktop test suite for
// `geminiToolSchema.ts`'s `sanitizeGeminiToolSchema`.
import 'package:flutter_test/flutter_test.dart';

import 'package:omi/services/voice_hub/gemini_tool_schema.dart';

void main() {
  group('sanitizeGeminiToolSchema', () {
    test('drops additionalProperties at the top level', () {
      final out = sanitizeGeminiToolSchema({
        'type': 'object',
        'additionalProperties': false,
        'properties': <String, dynamic>{},
      });
      expect(out, {'type': 'object', 'properties': <String, dynamic>{}});
    });

    test('recurses into properties, keeping every property name and sanitizing each sub-schema', () {
      final out = sanitizeGeminiToolSchema({
        'type': 'object',
        'properties': {
          'question': {'type': 'string', 'additionalProperties': false},
          'nested': {
            'type': 'object',
            'additionalProperties': true,
            'properties': {
              'inner': {'type': 'number', 'unknownKeyword': 'x'},
            },
          },
        },
      });
      expect(out, {
        'type': 'object',
        'properties': {
          'question': {'type': 'string'},
          'nested': {
            'type': 'object',
            'properties': {
              'inner': {'type': 'number'},
            },
          },
        },
      });
    });

    test('recurses into items (array schemas)', () {
      final out = sanitizeGeminiToolSchema({
        'type': 'array',
        'items': {'type': 'string', 'additionalProperties': false},
      });
      expect(out, {
        'type': 'array',
        'items': {'type': 'string'},
      });
    });

    test('recurses into every anyOf branch', () {
      final out = sanitizeGeminiToolSchema({
        'anyOf': [
          {'type': 'string', 'additionalProperties': false},
          {'type': 'number', 'unknownKeyword': 'x'},
        ],
      });
      expect(out, {
        'anyOf': [
          {'type': 'string'},
          {'type': 'number'},
        ],
      });
    });

    test('copies scalar/enum/required/default/example values verbatim', () {
      final out = sanitizeGeminiToolSchema({
        'type': 'string',
        'enum': ['a', 'b'],
        'required': ['x'],
        'default': 'a',
        'example': 'b',
      });
      expect(out, {
        'type': 'string',
        'enum': ['a', 'b'],
        'required': ['x'],
        'default': 'a',
        'example': 'b',
      });
    });

    test('passes non-map input through unchanged (defensive)', () {
      expect(sanitizeGeminiToolSchema('not a schema'), 'not a schema');
      expect(sanitizeGeminiToolSchema(null), null);
    });

    test('never mutates the input (returns a fresh copy)', () {
      final input = {
        'type': 'object',
        'additionalProperties': false,
        'properties': {
          'q': {'type': 'string'},
        },
      };
      final snapshotBefore = Map<String, dynamic>.from(input);
      sanitizeGeminiToolSchema(input);
      expect(input, snapshotBefore);
    });
  });
}
