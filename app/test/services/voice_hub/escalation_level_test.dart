// Контракт ползунка «как часто голосовой хаб ходит к Claude»
// (escalation_level.dart). Чистые функции — prefs не нужны; их читающая
// обёртка `currentClaudeEscalationLevel` проверяется только на дефолт
// (в тестовой среде SharedPreferences не инициализирован → defaultValue).
import 'package:flutter_test/flutter_test.dart';

import 'package:omi/services/voice_hub/ask_claude_tool.dart';
import 'package:omi/services/voice_hub/escalation_level.dart';

void main() {
  group('ClaudeEscalationLevel.fromIndex', () {
    test('maps stored indices onto levels in slider order', () {
      expect(ClaudeEscalationLevel.fromIndex(0), ClaudeEscalationLevel.geminiOnly);
      expect(ClaudeEscalationLevel.fromIndex(4), ClaudeEscalationLevel.fullProxy);
    });

    test('garbage indices fall back to balanced instead of crashing a session', () {
      // Старое приложение, ручная правка prefs, будущий откат версии — уровень
      // из хранилища не обязан быть валидным.
      expect(ClaudeEscalationLevel.fromIndex(-1), ClaudeEscalationLevel.balanced);
      expect(ClaudeEscalationLevel.fromIndex(99), ClaudeEscalationLevel.balanced);
    });
  });

  test('with the slider hidden, the level is pinned to balanced regardless of stored prefs', () {
    // Решение Игоря 24.08 ~02:10: ползунок скрыт после «раздвоения» на правом
    // крае, но в prefs могло остаться 4 — пин гарантирует стандартный режим.
    expect(claudeEscalationSliderEnabled, isFalse);
    expect(currentClaudeEscalationLevel(), ClaudeEscalationLevel.balanced);
  });

  group('geminiOnly (крайний левый)', () {
    test('is enforced structurally: the session gets NO tools at all', () {
      expect(hubToolsForLevel(ClaudeEscalationLevel.geminiOnly), isEmpty);
    });

    test('instructions never mention the tool the session does not have', () {
      // Промпт, обсуждающий недоступный инструмент, провоцирует модель звать
      // его вслепую или вслух рассуждать о «другой модели».
      expect(hubInstructionsForLevel(ClaudeEscalationLevel.geminiOnly), isNot(contains('ask_claude')));
    });
  });

  group('уровни с инструментом', () {
    const withTool = [
      ClaudeEscalationLevel.onRequest,
      ClaudeEscalationLevel.balanced,
      ClaudeEscalationLevel.aggressive,
      ClaudeEscalationLevel.fullProxy,
    ];

    test('catalog is exactly one ask_claude with the canonical parameter schema', () {
      for (final level in withTool) {
        final tools = hubToolsForLevel(level);
        expect(tools, hasLength(1), reason: '$level');
        expect(tools.single.name, askClaudeToolName, reason: '$level');
        // Схема аргументов — общая: и setup-фрейм, и AskClaudeToolExecutor
        // договорились именно о ней; уровень меняет только description.
        expect(tools.single.parameters, same(askClaudeToolDeclaration.parameters), reason: '$level');
      }
    });

    test('instructions mention ask_claude and demand the filler BEFORE the call', () {
      // Порядок «филлер вслух → вызов» проверяется на каждом уровне: наблюдение
      // с телефона — филлер после результата бесполезен (см. voice_hub_production_test).
      for (final level in withTool) {
        final instructions = hubInstructionsForLevel(level);
        expect(instructions, contains('ask_claude'), reason: '$level');
        expect(instructions.indexOf('FIRST'), lessThan(instructions.indexOf('THEN call the tool')), reason: '$level');
      }
    });

    test('tool description policy escalates with the slider', () {
      expect(hubToolsForLevel(ClaudeEscalationLevel.onRequest).single.description, contains('ТОЛЬКО по явной просьбе'));
      expect(hubToolsForLevel(ClaudeEscalationLevel.aggressive).single.description, contains('ЛЮБОГО'));
      expect(hubToolsForLevel(ClaudeEscalationLevel.fullProxy).single.description, contains('КАЖДУЮ'));
    });
  });

  test('fullProxy instructions route every substantive message through the tool', () {
    final instructions = hubInstructionsForLevel(ClaudeEscalationLevel.fullProxy);
    expect(instructions, contains('EVERY'));
    expect(instructions, contains('Do not compose substantive answers yourself'));
  });

  test('every slider cell produces a distinct prompt (a no-op cell is a UI lie)', () {
    final prompts = ClaudeEscalationLevel.values.map(hubInstructionsForLevel).toSet();
    expect(prompts, hasLength(ClaudeEscalationLevel.values.length));
  });

  test('labels and hints exist for every cell the slider renders', () {
    for (final level in ClaudeEscalationLevel.values) {
      expect(level.label, isNotEmpty);
      expect(level.hint, isNotEmpty);
    }
  });
}
