// Инструмент `end_conversation`: модель сама заканчивает голосовой разговор,
// когда он по контексту завершён (просьба Игоря 24.08). До этого разговор
// заканчивался только кнопкой или сторожем тишины (3 минуты) — «пока, до
// связи» оставлял режим висеть и слушать.
//
// Порядок обязателен и вбит в description: СНАЧАЛА прощание вслух, ПОТОМ
// вызов. Обработчик отвечает на вызов сразу (протоколу нужен tool-result),
// а сам режим гасит с небольшой отсрочкой — чтобы хвост прощания успел
// дозвучать, если модель всё же заговорила после вызова.
import 'hub_session.dart' show HubToolCallRequest, VoiceToolDeclaration;

const String endConversationToolName = 'end_conversation';

const VoiceToolDeclaration endConversationToolDeclaration = VoiceToolDeclaration(
  name: endConversationToolName,
  description: 'Заверши голосовой разговор и выключи голосовой режим. Вызывай, когда разговор ЯВНО '
      'закончен: пользователь попрощался («пока», «до связи»), сказал «всё», «спасибо, хватит», '
      'попросил выключиться — или прямо согласился закончить. СНАЧАЛА скажи короткое тёплое '
      'прощание вслух и ТОЛЬКО ПОТОМ вызывай инструмент. НИКОГДА не вызывай его посреди '
      'разговора или из-за паузы: молчание — не прощание.',
  parameters: {
    'type': 'object',
    'properties': {
      'reason': {
        'type': 'string',
        'description': 'Короткая причина для лога, например «пользователь попрощался».',
      },
    },
  },
);

/// Handles `end_conversation` calls: ack the tool call, then stop the mode
/// after a short grace so a goodbye spoken around the call finishes playing.
class EndConversationToolHandler {
  final void Function(String callId, String name, String output) sendToolResult;

  /// Гасит режим целиком — в production это `CaptureController.stopFreeFormVoiceMode`
  /// (стоп + сброс UI + досылка диалога в чат + перечитка сообщений).
  final void Function() stopMode;

  /// Отсрочка перед выключением: хвост прощания должен дозвучать. Модель
  /// проинструктирована прощаться ДО вызова, так что обычно тут уже тихо —
  /// отсрочка страхует нарушивших порядок.
  final Duration goodbyeGrace;

  /// Планировщик — инъецируем ради тестов (в production — обычный Timer).
  final void Function(Duration delay, void Function() run) schedule;

  const EndConversationToolHandler({
    required this.sendToolResult,
    required this.stopMode,
    required this.schedule,
    this.goodbyeGrace = const Duration(seconds: 3),
  });

  /// Returns true if the call was an `end_conversation` and was consumed.
  bool handle(HubToolCallRequest call) {
    if (call.name != endConversationToolName) return false;
    // Ответ — инструкция, не данные: модель уже попрощалась и ничего не ждёт,
    // но незакрытый вызов подвесил бы её ход.
    sendToolResult(call.callId, call.name, 'Разговор завершён, голосовой режим выключается. Больше ничего не говори.');
    schedule(goodbyeGrace, stopMode);
    return true;
  }
}
