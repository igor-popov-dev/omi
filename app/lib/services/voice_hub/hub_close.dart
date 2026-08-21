// Close-code classification for the warm hub socket — a 1:1 port of
// `desktop/windows/src/renderer/src/lib/voice/hub/hubClose.ts`. Answers the
// one question `HubController`'s reconnect policy needs: was this socket
// close an EXPECTED idle teardown (Gemini idle-closes a warm session with WS
// 1008 after ~2.5 min of no input), or a real failure? The two drive very
// different reconnect behavior (see `hub_controller.dart`):
//   * expectedIdleTeardown -> re-warm WITHOUT spending a reconnect strike.
//   * policyFast / transient -> a genuine failure: bounded re-warm capped by
//     the strike budget so a dead endpoint isn't hammered.
//
// Provider auth/quota classification (the TS source's cross-provider
// failover dependency) is NOT ported — design doc §3 cuts failover entirely
// (single provider, nothing to fail over to). So every 1008 that isn't an
// idle teardown is `policyFast`, and every non-1008 close is `transient`,
// exactly as the TS source's own minimal slice already behaved.
//
// Pure and input-only, same as the TS source — no Flutter/platform imports.

/// A 1008 that arrives with no active turn after the socket has lived at
/// least this long is the provider's expected idle-close, not a failure.
const int hubIdleTeardownThresholdMs = 60000;

enum HubCloseCategory { expectedIdleTeardown, policyFast, transient }

class HubCloseInput {
  /// The `websocket closed (<code>) …` message `BaseHubSession` forwards.
  final String message;

  /// The WS close code, threaded structurally from `BaseHubSession`'s
  /// `onClose`. When absent the code is parsed out of [message] as a
  /// fallback.
  final int? closeCode;

  /// How long the socket had been connected before the close (0 if it never
  /// opened).
  final int aliveForMs;

  /// Whether a PTT turn was in flight when the socket closed.
  final bool hasActiveTurn;

  const HubCloseInput({
    required this.message,
    this.closeCode,
    required this.aliveForMs,
    required this.hasActiveTurn,
  });
}

/// Parses the numeric close code out of a `websocket closed (1008) …`
/// message — the fallback when a structured code wasn't threaded.
int? _parseCloseCode(String message) {
  final match = RegExp(r'websocket closed \((\d+)\)').firstMatch(message);
  if (match == null) return null;
  return int.tryParse(match.group(1)!);
}

/// Classifies a warm-socket close. See the file header for the policy each
/// category drives.
HubCloseCategory classifyHubClose(HubCloseInput input) {
  final code = input.closeCode ?? _parseCloseCode(input.message);
  // Only a 1008 policy close is ever an idle teardown. Any other code (1006
  // abnormal, 1011, a transport drop) is a transient failure -> bounded
  // re-warm.
  if (code != 1008) return HubCloseCategory.transient;
  // A 1008 with no active turn after the socket has lived a while is the
  // expected provider idle-close; a fast 1008 (or one during a turn) is a
  // policy reject.
  if (!input.hasActiveTurn && input.aliveForMs >= hubIdleTeardownThresholdMs) {
    return HubCloseCategory.expectedIdleTeardown;
  }
  return HubCloseCategory.policyFast;
}

/// Whether a re-warm for this category spends a strike. An expected idle
/// teardown is not a failure, so it re-warms freely; a real failure is
/// capped by the strike budget so a dead endpoint isn't hammered.
bool consumesStrike(HubCloseCategory category) => category != HubCloseCategory.expectedIdleTeardown;
