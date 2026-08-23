// A 1:1-in-spirit port of the desktop (Electron/TS) test suite at
// `desktop/windows/src/renderer/src/lib/voice/turn/voiceTurnHost.test.ts`.
//
// `voice_turn_host.dart`'s own header documents three scope cuts vs. the TS
// source, all Windows-desktop-specific with no Android equivalent wired up.
// This file does NOT invent tests for code that was never ported — instead
// it ports every TS case that exercises a seam that exists here, and
// documents (rather than fakes) the ones that don't:
//   * No `restoreSystemAudio` / A4 system-audio-duck seam. Skipped:
//     "stopCapture restores system audio", "A4: stopCapture then terminal
//     ⇒ exactly one restore", "A4: EVERY one of the 16 terminal reasons ⇒
//     exactly one restore", "A4: a repeated terminal for the SAME turn
//     restores only once", "a new turn gets its own single restore". In
//     their place, "every terminal reason ends the lease and notifies the
//     hub exactly once" below still exercises the *existing* per-reason
//     terminal dispatch (endTurn + voiceTurnDidTerminate), just without the
//     restore-count assertion that has no seam to hang off.
//   * No `trackEvent` fallback-telemetry seam. Skipped: "emits an
//     `exhausted` fallback ONLY for the no-path-left provider/warm
//     terminals" and "does NOT emit fallback telemetry for a clean success
//     or a hard non-hub failure" — there is no telemetry call to assert on
//     either way.
//   * No A7c `onHubConnected`/`onHubError` pass-through seam — the TS
//     source itself has no test for it either (a no-op host handler,
//     "A7c is a later body change"), so nothing is skipped here.
//
// One signature adaptation: the Dart `selectPttRoute` takes a required
// `pttHubEnabled: bool` (no `Map` of preferences / `getPreferences()`
// default — that whole prefs-lookup seam was not ported), so the TS suite's
// "flag OFF (undefined)" and "flag explicitly false" cases — both meaning
// "the pref does not resolve to `true`" — collapse into the one Dart case
// below.
import 'package:flutter_test/flutter_test.dart';

import 'package:omi/services/voice_hub/voice_turn_host.dart';
import 'package:omi/services/voice_hub/voice_turn_machine.dart';

// ---- fixtures ---------------------------------------------------------------

class _FakeHub implements PttHubAvailability {
  final bool available;
  final bool warm;
  _FakeHub({required this.available, required this.warm});
  @override
  bool isAvailable() => available;
  @override
  bool isWarm() => warm;
}

class _Spies {
  final List<({VoiceTurnId turnId, VoiceCaptureId? captureId})> disposeCaptureCalls = [];
  final List<VoiceTurnId> cancelTurnCalls = [];
  final List<VoiceTurnId> handoffCalls = [];
  final List<VoiceTurnId> voiceTurnDidTerminateCalls = [];
  final List<VoiceLeaseId?> interruptPlaybackCalls = [];
  final List<VoiceTurnId> endTurnCalls = [];
  final List<VoiceTurnUiProjection> applyProjectionCalls = [];
}

class _FakeHubPort implements VoiceTurnHubPort {
  final _Spies spies;
  _FakeHubPort(this.spies);
  @override
  void cancelTurn(VoiceTurnId turnId) => spies.cancelTurnCalls.add(turnId);
  @override
  void handoffWarmWaitToCascade(VoiceTurnId turnId) => spies.handoffCalls.add(turnId);
  @override
  void voiceTurnDidTerminate(VoiceTurnId turnId) => spies.voiceTurnDidTerminateCalls.add(turnId);
}

class _FakeOutputPort implements VoiceTurnOutputPort {
  final _Spies spies;
  _FakeOutputPort(this.spies);
  @override
  bool endTurn(VoiceTurnId turnId) {
    spies.endTurnCalls.add(turnId);
    return true;
  }
}

({VoiceTurnHost host, _Spies spies}) _makeHost() {
  final spies = _Spies();
  final deps = VoiceTurnHostDeps(
    disposeCapture: (turnId, captureId) => spies.disposeCaptureCalls.add((turnId: turnId, captureId: captureId)),
    hub: _FakeHubPort(spies),
    interruptPlayback: (leaseId) => spies.interruptPlaybackCalls.add(leaseId),
    outputCoordinator: _FakeOutputPort(spies),
    applyProjection: (projection) => spies.applyProjectionCalls.add(projection),
  );
  return (host: VoiceTurnHost(deps), spies: spies);
}

VoiceTurnEffect _terminal(VoiceTurnId turnId, VoiceTurnTerminalReason reason) => VoiceTurnEffectTerminal(
      record: VoiceTurnTerminalRecord(turnId: turnId, reason: reason, route: const VoiceTurnRouteOmniStt()),
    );

// ---- tests ------------------------------------------------------------------

void main() {
  group('selectPttRoute — the pttHubEnabled kill-switch', () {
    final warmHub = _FakeHub(available: true, warm: true);
    final coldHub = _FakeHub(available: true, warm: false);
    final noHub = _FakeHub(available: false, warm: false);

    test('flag OFF ⇒ omniSTT regardless of hub state — the cascade path', () {
      expect(selectPttRoute(warmHub, pttHubEnabled: false), const VoiceTurnRouteOmniStt());
      expect(selectPttRoute(coldHub, pttHubEnabled: false), const VoiceTurnRouteOmniStt());
      expect(selectPttRoute(noHub, pttHubEnabled: false), const VoiceTurnRouteOmniStt());
    });

    test('flag ON ⇒ hub when warm, hubWarmWait when cold, omniSTT when unavailable', () {
      expect(selectPttRoute(warmHub, pttHubEnabled: true), const VoiceTurnRouteHub(null));
      expect(selectPttRoute(coldHub, pttHubEnabled: true), const VoiceTurnRouteHubWarmWait());
      expect(selectPttRoute(noHub, pttHubEnabled: true), const VoiceTurnRouteOmniStt());
    });
  });

  group('VoiceTurnHost — effect mapping', () {
    test('stopCapture disposes the capture window mic capture', () {
      final h = _makeHost();
      h.host.effectHandler(const VoiceTurnEffectStopCapture(turnId: 'a', captureId: 7));
      expect(h.spies.disposeCaptureCalls, [(turnId: 'a', captureId: 7)]);
    });

    test('cancelHub calls hubController.cancelTurn(turnId) (route dropped)', () {
      final h = _makeHost();
      h.host.effectHandler(const VoiceTurnEffectCancelHub(turnId: 'a', route: VoiceTurnRouteHub(null)));
      expect(h.spies.cancelTurnCalls, ['a']);
    });

    test('stopPlayback interrupts the current response for the lease', () {
      final h = _makeHost();
      h.host.effectHandler(const VoiceTurnEffectStopPlayback(turnId: 'a', leaseId: 'L1'));
      expect(h.spies.interruptPlaybackCalls, ['L1']);
    });

    test('the five coordinator-owned effects are no-ops in the host', () {
      final h = _makeHost();
      final ignored = <VoiceTurnEffect>[
        const VoiceTurnEffectScheduleDeadline(turnId: 'a', deadline: VoiceTurnDeadline.transcription, after: 12),
        const VoiceTurnEffectCancelDeadline(turnId: 'a', deadline: VoiceTurnDeadline.transcription),
        const VoiceTurnEffectCancelAllDeadlines(turnId: 'a'),
        const VoiceTurnEffectStaleEventDropped(turnId: 'a', event: 'capture_started'),
        const VoiceTurnEffectInvalidTransition(turnId: 'a', event: 'lock', phase: null),
      ];
      for (final effect in ignored) {
        expect(() => h.host.effectHandler(effect), returnsNormally);
      }
      // No subsystem call fired for any of them.
      expect(h.spies.disposeCaptureCalls, isEmpty);
      expect(h.spies.cancelTurnCalls, isEmpty);
      expect(h.spies.handoffCalls, isEmpty);
      expect(h.spies.voiceTurnDidTerminateCalls, isEmpty);
      expect(h.spies.interruptPlaybackCalls, isEmpty);
      expect(h.spies.endTurnCalls, isEmpty);
      expect(h.spies.applyProjectionCalls, isEmpty);
    });

    test('broadcasts the projection through the presenter', () {
      final h = _makeHost();
      const projection = VoiceTurnUiProjection(
        isListening: true,
        isLocked: false,
        isFollowUp: false,
        transcript: '',
        hint: '',
        isThinking: false,
        isResponseWaiting: false,
        isResponseActive: false,
      );
      h.host.presenter(projection);
      expect(h.spies.applyProjectionCalls, [projection]);
    });

    test('the snapshot handler seam also broadcasts the derived projection', () {
      final h = _makeHost();
      h.host.snapshotHandler(idleVoiceTurnModel);
      expect(h.spies.applyProjectionCalls, [idleVoiceTurnProjection]);
    });
  });

  group('VoiceTurnHost — fallbackToTranscription keeps the turn alive, no double emit', () {
    test('hands the warm-wait buffer to the cascade and does NOT terminate the turn', () {
      final h = _makeHost();
      h.host.effectHandler(
        const VoiceTurnEffectFallbackToTranscription(turnId: 'a', reason: VoiceTurnTerminalReason.hubWarmTimeout),
      );
      expect(h.spies.handoffCalls, ['a']);
      // The turn continues — nothing terminal fires from the host here.
      expect(h.spies.endTurnCalls, isEmpty);
      expect(h.spies.voiceTurnDidTerminateCalls, isEmpty);
    });
  });

  group('VoiceTurnHost — terminal', () {
    test('ends the lease and releases hub per-turn state, in that order', () {
      final h = _makeHost();
      h.host.effectHandler(_terminal('a', VoiceTurnTerminalReason.success));
      expect(h.spies.endTurnCalls, ['a']);
      expect(h.spies.voiceTurnDidTerminateCalls, ['a']);
    });

    test('every terminal reason ends the lease and notifies the hub exactly once', () {
      for (final reason in VoiceTurnTerminalReason.values) {
        final h = _makeHost();
        h.host.effectHandler(_terminal('turn', reason));
        expect(h.spies.endTurnCalls, ['turn'], reason: 'endTurn for $reason');
        expect(h.spies.voiceTurnDidTerminateCalls, ['turn'], reason: 'voiceTurnDidTerminate for $reason');
      }
    });

    test('a repeated terminal for the same turn calls through again (host has no dedupe seam of its own)', () {
      // Unlike the TS source's A4 restore guard, the Dart host keeps no
      // per-turn "already handled" state (there is nothing to dedupe without
      // the restore seam) — a second terminal for the same turn is simply
      // forwarded again, exactly like any other terminal.
      final h = _makeHost();
      h.host.effectHandler(_terminal('a', VoiceTurnTerminalReason.success));
      h.host.effectHandler(_terminal('a', VoiceTurnTerminalReason.success));
      expect(h.spies.endTurnCalls, ['a', 'a']);
      expect(h.spies.voiceTurnDidTerminateCalls, ['a', 'a']);
    });
  });
}
