// A 1:1 port of `desktop/windows/src/renderer/src/lib/voice/hub/hubClose.test.ts`
// (test names kept in spirit, not necessarily verbatim — the TS file was not
// re-read in this pass; `hub_close.dart`'s own header/doc-comments were
// ported faithfully from `hubClose.ts` and this suite exercises exactly the
// three branches its `classifyHubClose`/`consumesStrike` describe).
import 'package:flutter_test/flutter_test.dart';

import 'package:omi/services/voice_hub/hub_close.dart';

void main() {
  group('classifyHubClose', () {
    test('a non-1008 close is always transient regardless of turn/liveness', () {
      expect(
        classifyHubClose(const HubCloseInput(message: 'x', closeCode: 1006, aliveForMs: 0, hasActiveTurn: false)),
        HubCloseCategory.transient,
      );
      expect(
        classifyHubClose(
          const HubCloseInput(message: 'x', closeCode: 1011, aliveForMs: 999999, hasActiveTurn: false),
        ),
        HubCloseCategory.transient,
      );
    });

    test('a 1008 with no active turn after the idle threshold is an expected idle teardown', () {
      expect(
        classifyHubClose(const HubCloseInput(
          message: 'x',
          closeCode: 1008,
          aliveForMs: hubIdleTeardownThresholdMs,
          hasActiveTurn: false,
        )),
        HubCloseCategory.expectedIdleTeardown,
      );
    });

    test('a 1008 just under the idle threshold is a policy-fast reject, not an idle teardown', () {
      expect(
        classifyHubClose(const HubCloseInput(
          message: 'x',
          closeCode: 1008,
          aliveForMs: hubIdleTeardownThresholdMs - 1,
          hasActiveTurn: false,
        )),
        HubCloseCategory.policyFast,
      );
    });

    test('a 1008 during an active turn is a policy-fast reject even past the idle threshold', () {
      expect(
        classifyHubClose(const HubCloseInput(
          message: 'x',
          closeCode: 1008,
          aliveForMs: hubIdleTeardownThresholdMs + 1000,
          hasActiveTurn: true,
        )),
        HubCloseCategory.policyFast,
      );
    });

    test('parses the close code out of the message when none is threaded structurally', () {
      expect(
        classifyHubClose(const HubCloseInput(
          message: 'websocket closed (1008) idle',
          aliveForMs: hubIdleTeardownThresholdMs,
          hasActiveTurn: false,
        )),
        HubCloseCategory.expectedIdleTeardown,
      );
      expect(
        classifyHubClose(
          const HubCloseInput(message: 'websocket closed (1006) abnormal', aliveForMs: 0, hasActiveTurn: false),
        ),
        HubCloseCategory.transient,
      );
      expect(
        classifyHubClose(const HubCloseInput(message: 'no code here', aliveForMs: 0, hasActiveTurn: false)),
        HubCloseCategory.transient,
      );
    });
  });

  group('consumesStrike', () {
    test('an expected idle teardown does not consume a strike', () {
      expect(consumesStrike(HubCloseCategory.expectedIdleTeardown), isFalse);
    });

    test('a policy-fast or transient close consumes a strike', () {
      expect(consumesStrike(HubCloseCategory.policyFast), isTrue);
      expect(consumesStrike(HubCloseCategory.transient), isTrue);
    });
  });
}
