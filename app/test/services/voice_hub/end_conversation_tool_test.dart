// Контракт end_conversation (end_conversation_tool.dart): модель сама
// заканчивает разговор, когда он по контексту завершён (просьба Игоря 24.08).
import 'package:flutter_test/flutter_test.dart';

import 'package:omi/services/voice_hub/end_conversation_tool.dart';
import 'package:omi/services/voice_hub/hub_session.dart';

void main() {
  ({EndConversationToolHandler handler, List<String> acks, List<Duration> scheduled, List<int> stops}) build() {
    final acks = <String>[];
    final scheduled = <Duration>[];
    final stops = <int>[];
    final pending = <void Function()>[];
    final handler = EndConversationToolHandler(
      sendToolResult: (callId, name, output) => acks.add(output),
      stopMode: () => stops.add(1),
      schedule: (delay, run) {
        scheduled.add(delay);
        pending.add(run);
      },
    );
    return (
      handler: handler,
      acks: acks,
      scheduled: scheduled,
      stops: stops,
    );
  }

  test('acks the call immediately and stops the mode only after the goodbye grace', () {
    final acks = <String>[];
    Duration? scheduledDelay;
    void Function()? scheduledRun;
    var stops = 0;
    final handler = EndConversationToolHandler(
      sendToolResult: (callId, name, output) => acks.add(output),
      stopMode: () => stops++,
      schedule: (delay, run) {
        scheduledDelay = delay;
        scheduledRun = run;
      },
    );

    final consumed = handler.handle(const HubToolCallRequest(
      name: endConversationToolName,
      callId: 'end-1',
      argumentsJson: '{"reason": "пользователь попрощался"}',
    ));

    expect(consumed, isTrue);
    // Незакрытый вызов подвесил бы ход модели — ack уходит сразу…
    expect(acks, hasLength(1));
    expect(acks.single, contains('выключается'));
    // …а сам стоп отложен: хвост прощания должен дозвучать.
    expect(stops, 0);
    expect(scheduledDelay, const Duration(seconds: 3));
    scheduledRun!();
    expect(stops, 1);
  });

  test('ignores every other tool name — ask_claude is not its business', () {
    final b = build();
    final consumed = b.handler.handle(const HubToolCallRequest(name: 'ask_claude', callId: 'c1', argumentsJson: '{}'));
    expect(consumed, isFalse);
    expect(b.acks, isEmpty);
    expect(b.scheduled, isEmpty);
    expect(b.stops, isEmpty);
  });

  test('declaration name matches what the handler consumes', () {
    expect(endConversationToolDeclaration.name, endConversationToolName);
    // Порядок «прощание вслух → вызов» — единственная защита от обрезанного
    // прощания; он обязан быть вбит в description.
    expect(endConversationToolDeclaration.description, contains('СНАЧАЛА'));
    expect(endConversationToolDeclaration.description, contains('ПОТОМ'));
  });
}
