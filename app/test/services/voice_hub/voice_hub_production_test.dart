// Unit coverage for `voice_hub_production.dart`'s pure, network-free
// pieces only. NOT covered here, and why:
//   * `mintGeminiHubToken` — built on `makeApiCall`, which is not
//     injectable (hardcoded to `HttpPoolManager.instance` + Firebase auth
//     headers) — same reason this app's other `api/*.dart` wrappers
//     (`action_items.dart`, `announcements.dart`, ...) have no direct unit
//     test of their own HTTP call either. Contract verified instead the
//     same way lane2 verified it server-side (lane2-log.md, 21.08 22:05):
//     a live smoke test against a real Firebase ID token, not a unit test.
//   * `createProductionVoiceHubTurnDriver` — its `startCapture`/player
//     factories touch real Pigeon platform channels
//     (`NativeMicRecorderService`, `StreamingPcmPlayerHostApi`), same as
//     every other production factory in this series
//     (`nativeMicHubCaptureFactory`, `nativeVoicePlayerFactory` themselves
//     have no direct unit test either — only their *consumers*, exercised
//     against fakes, do). The `toolExecutor` wiring this function adds is
//     covered instead at the seam it plugs into: `voice_turn_driver_test.dart`
//     "hub tool loop (real executor wired)".
//   * `createProductionFreeFormVoiceMode` — same reasoning: its
//     `startCapture` factory is the same real-platform-channel
//     `nativeMicHubCaptureFactory`/`NativeMicRecorderService` pair above,
//     and its own start/stop/idle-timeout logic is already exercised
//     hermetically against a plain `HubController` in
//     `free_form_voice_mode_test.dart`. The `onToolRequest` wiring this
//     function adds is the same `AskClaudeToolExecutor` seam as
//     `createProductionVoiceHubTurnDriver`'s, so it needs no separate
//     coverage here either.
import 'package:flutter_test/flutter_test.dart';

import 'package:omi/services/voice_hub/ask_claude_tool.dart';
import 'package:omi/services/voice_hub/voice_hub_production.dart';

void main() {
  group('buildProductionHubInstructions', () {
    test('returns a non-empty, stable prompt', () {
      final a = buildProductionHubInstructions();
      final b = buildProductionHubInstructions();
      expect(a, isNotEmpty);
      expect(a, b);
    });

    test('mentions the ask_claude escape hatch, so the model knows to reach for it', () {
      expect(buildProductionHubInstructions(), contains('ask_claude'));
    });

    test('demands the filler BEFORE the tool call, not merely in the same turn', () {
      // Observed on the phone: an instruction that only asked for a filler "in
      // the same turn" got one spoken *after* the result arrived, so the user
      // heard a long silence and then "one sec, let me check" glued to the
      // answer. The prompt has to state the order.
      final instructions = buildProductionHubInstructions();
      expect(instructions, contains('FIRST'));
      expect(instructions, contains('THEN call the tool'));
      expect(instructions.indexOf('FIRST'), lessThan(instructions.indexOf('THEN call the tool')));
    });
  });

  group('fetchHubTools', () {
    test('returns exactly the ask_claude tool catalog', () async {
      final tools = await fetchHubTools();
      expect(tools, [askClaudeToolDeclaration]);
    });
  });
}
