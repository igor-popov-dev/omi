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

  test('slider is back on and uninitialized prefs (this test env) resolve to balanced', () {
    // Возврат ползунка 24.08 ~03:30 — после single-flight, тёплого моста и
    // блокирующей доставки. Хранение — под НОВЫМ ключом (V2): под старым у
    // Игоря осталась «4» с неудачного теста, возврат не должен молча включить
    // правый край.
    expect(claudeEscalationSliderEnabled, isTrue);
    expect(currentClaudeEscalationLevel(), ClaudeEscalationLevel.balanced);
  });

  test('delivery blocks on high escalation levels only (идея 1)', () {
    // На высоких уровнях модель говорит «секунду» и молчит до ответа —
    // самодеятельность исключена механикой; на низких неблокирующий путь
    // (с single-flight) удобнее честной паузы.
    expect(ClaudeEscalationLevel.geminiOnly.blockingDelivery, isFalse);
    expect(ClaudeEscalationLevel.onRequest.blockingDelivery, isFalse);
    expect(ClaudeEscalationLevel.balanced.blockingDelivery, isFalse);
    expect(ClaudeEscalationLevel.aggressive.blockingDelivery, isTrue);
    expect(ClaudeEscalationLevel.fullProxy.blockingDelivery, isTrue);
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

    test('non-blocking levels demand the spoken filler BEFORE the call', () {
      // Порядок «филлер вслух → вызов»: наблюдение с телефона — филлер после
      // результата бесполезен (см. voice_hub_production_test).
      for (final level in [ClaudeEscalationLevel.onRequest, ClaudeEscalationLevel.balanced]) {
        final instructions = hubInstructionsForLevel(level);
        expect(instructions, contains('ask_claude'), reason: '$level');
        expect(instructions.indexOf('FIRST'), lessThan(instructions.indexOf('THEN call the tool')), reason: '$level');
      }
    });

    test('blocking levels forbid the spoken filler — the chime replaces it', () {
      // Жалоба Игоря 24.08: «секунду, уточню» перед КАЖДЫМ ответом на правом
      // крае невыносима. Там подтверждение — звуковой сигнал телефона, и
      // инструкции с description инструмента обязаны это говорить согласованно.
      for (final level in [ClaudeEscalationLevel.aggressive, ClaudeEscalationLevel.fullProxy]) {
        final instructions = hubInstructionsForLevel(level);
        expect(instructions, isNot(contains('FIRST say a short filler')), reason: '$level');
        expect(instructions, contains('chime'), reason: '$level');
        final description = hubToolsForLevel(level).single.description;
        expect(description, contains('звуковой сигнал'), reason: '$level');
        expect(description, isNot(contains('СНАЧАЛА вслух')), reason: '$level');
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
