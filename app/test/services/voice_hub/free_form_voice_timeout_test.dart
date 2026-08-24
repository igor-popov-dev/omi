// The minutes <-> Duration rule behind the "Voice mode auto-off" setting
// (priority 22.08 step 6). Small on purpose — the point is that the stored `0`
// and a hand-edited negative both mean "never", because either one arming a
// real timer would misbehave badly (a zero/negative Duration fires on the next
// event-loop turn, i.e. free-form mode would switch itself off the instant it
// started).
import 'package:flutter_test/flutter_test.dart';

import 'package:omi/services/voice_hub/free_form_voice_timeout.dart';

void main() {
  group('freeFormIdleTimeoutFromMinutes', () {
    test('a positive minute count becomes that many minutes', () {
      expect(freeFormIdleTimeoutFromMinutes(1), const Duration(minutes: 1));
      expect(freeFormIdleTimeoutFromMinutes(10), const Duration(minutes: 10));
    });

    test('zero means never — no timer at all', () {
      expect(freeFormIdleTimeoutFromMinutes(0), isNull);
    });

    test('a negative value means never too, instead of firing immediately', () {
      expect(freeFormIdleTimeoutFromMinutes(-5), isNull);
    });

    test('the stock default is a real duration, not never', () {
      expect(freeFormIdleTimeoutFromMinutes(kDefaultFreeFormVoiceIdleTimeoutMinutes), isNotNull);
    });
  });

  group('the choices offered in settings', () {
    test('include the default, so the current value is always selectable', () {
      expect(kFreeFormVoiceIdleTimeoutChoicesMinutes, contains(kDefaultFreeFormVoiceIdleTimeoutMinutes));
    });

    test('offer exactly one "never" and no negative values', () {
      expect(kFreeFormVoiceIdleTimeoutChoicesMinutes.where((m) => m <= 0).toList(), [0]);
    });
  });

  group('freeFormVoiceIdleTimeoutLabel', () {
    test('reads as a sentence for every choice', () {
      expect(freeFormVoiceIdleTimeoutLabel(0), 'Never');
      expect(freeFormVoiceIdleTimeoutLabel(1), '1 minute');
      expect(freeFormVoiceIdleTimeoutLabel(3), '3 minutes');
    });
  });
}
