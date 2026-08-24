// The VoiceTurn HOST — the coordinator's effect handler. A 1:1-in-spirit
// port of
// `desktop/windows/src/renderer/src/lib/voice/turn/voiceTurnHost.ts`, design
// doc `~/omi-jarvis/docs/hub-port-design.md` §8 step 6.
//
// The reducer (`voice_turn_reducer.dart`) decides WHAT happens; the
// coordinator (`voice_turn_coordinator.dart`) owns timers, the timeline, and
// effect delivery; the host is where each reducer effect finally becomes a
// real subsystem call. Every collaborator is an injected seam so the whole
// host is exercisable against fakes, and the kill-switch stays structural:
// when the hub pref is off, `selectPttRoute` always returns `omniSTT`, so
// none of the host's hub-facing effects ever fire.
//
// Effect -> action (same mapping as the TS source):
//   stopCapture             -> dispose the mic capture for the turn
//   cancelHub               -> hubController.cancelTurn(turnId) [route
//                               dropped — a single warm session needs no
//                               transport selection, matching the TS
//                               source's own Windows deviation note]
//   fallbackToTranscription -> hubController.handoffWarmWaitToCascade(turnId)
//                               — the turn CONTINUES on the cascade; nothing
//                               here terminates it.
//   stopPlayback            -> interruptPlayback(leaseId)
//   terminal                -> outputCoordinator.endTurn +
//                               hubController.voiceTurnDidTerminate
//   scheduleDeadline / cancelDeadline / cancelAllDeadlines /
//   staleEventDropped / invalidTransition -> IGNORED. The coordinator
//                               already armed/cancelled the timer; the host
//                               must not re-handle them.
//
// Three scope cuts vs. the TS source, all Windows-desktop-specific with no
// Android equivalent wired up (documented here, not filled in with
// placeholders):
//   * The A4 system-audio duck restore (`restoreSystemAudio`, muting OTHER
//     apps' output while the mic is open) — a Windows-endpoint-mute concept
//     with no Android analog; Android's own audio-focus/ducking model is
//     unrelated and out of this lane's scope (voice_hub/ owns WebSocket +
//     audio plumbing, not system audio routing).
//   * `trackEvent` fallback telemetry (`fallback_triggered` on an
//     exhausted-hub terminal) — no Android telemetry sink wired to this
//     package yet, same cut already made in `hub_controller.dart`.
//   * The A7c `onHubConnected`/`onHubError` pass-through seam — vestigial in
//     the TS source itself at this stage (wired to a no-op host handler,
//     "A7c is a later body change") and never used by
//     `voiceHubTurnDriver.ts`; not worth a seam that has never had a
//     consumer.
//
// Ground rule (design doc §8): ZERO Flutter imports here.

import 'voice_turn_machine.dart';

// ---------------------------------------------------------------------------
// MARK: - Route selection (the kill-switch seam)
// ---------------------------------------------------------------------------

/// What the host needs to know about the warm hub to pick a route.
/// `HubController` satisfies this structurally via an adapter (see
/// `voice_turn_driver.dart`).
abstract class PttHubAvailability {
  bool isAvailable();
  bool isWarm();
}

/// The single choke point of the hub kill-switch. When [pttHubEnabled] is
/// false (the default), this ALWAYS returns `omniSTT` — the cascade route —
/// no matter the hub's state, so the reducer drives the existing cascade
/// path byte-for-byte and the host's hub-facing effects never fire. Only
/// when the flag is on AND the hub is available does a press take the warm
/// lane (`hub` when already warm, else `hubWarmWait`, which the reducer's 1s
/// `hubWarm` deadline degrades back to the cascade — never worse than
/// today). The HOST picks the route; the reducer never does.
VoiceTurnRoute selectPttRoute(PttHubAvailability hub, {required bool pttHubEnabled}) {
  if (!pttHubEnabled || !hub.isAvailable()) {
    return const VoiceTurnRouteOmniStt();
  }
  return hub.isWarm() ? const VoiceTurnRouteHub(null) : const VoiceTurnRouteHubWarmWait();
}

// ---------------------------------------------------------------------------
// MARK: - Injected collaborators
// ---------------------------------------------------------------------------

/// The subset of `HubController` the host drives from reducer effects.
abstract class VoiceTurnHubPort {
  void cancelTurn(VoiceTurnId turnId);
  void handoffWarmWaitToCascade(VoiceTurnId turnId);
  void voiceTurnDidTerminate(VoiceTurnId turnId);
}

/// The subset of `VoiceOutputCoordinator` the host ends on terminal.
abstract class VoiceTurnOutputPort {
  bool endTurn(VoiceTurnId turnId);
}

class VoiceTurnHostDeps {
  /// Dispose the mic capture for a turn (`stopCapture` effect). The
  /// captureId argument mirrors the TS source's own signature but is
  /// intentionally ignored by the driver's wiring — see that file: the
  /// driver holds at most one live capture handle at a time, so "which
  /// capture" is never ambiguous.
  final void Function(VoiceTurnId turnId, VoiceCaptureId? captureId) disposeCapture;
  final VoiceTurnHubPort hub;

  /// Stop the current spoken reply for a lease (`stopPlayback` effect).
  final void Function(VoiceLeaseId? leaseId) interruptPlayback;
  final VoiceTurnOutputPort outputCoordinator;

  /// Broadcast the reducer projection. No-op by default (no UI is wired to
  /// the hub yet — this tick is plumbing only, see `voice_turn_driver.dart`
  /// header).
  final void Function(VoiceTurnUiProjection projection) applyProjection;

  const VoiceTurnHostDeps({
    required this.disposeCapture,
    required this.hub,
    required this.interruptPlayback,
    required this.outputCoordinator,
    required this.applyProjection,
  });
}

// ---------------------------------------------------------------------------
// MARK: - Host
// ---------------------------------------------------------------------------

class VoiceTurnHost {
  final VoiceTurnHostDeps deps;
  const VoiceTurnHost(this.deps);

  /// Wire as `coordinator.setEffectHandler(host.effectHandler)`.
  void effectHandler(VoiceTurnEffect effect) {
    switch (effect) {
      case VoiceTurnEffectStopCapture():
        deps.disposeCapture(effect.turnId, effect.captureId);
      case VoiceTurnEffectCancelHub():
        deps.hub.cancelTurn(effect.turnId);
      case VoiceTurnEffectFallbackToTranscription():
        deps.hub.handoffWarmWaitToCascade(effect.turnId);
      case VoiceTurnEffectStopPlayback():
        deps.interruptPlayback(effect.leaseId);
      case VoiceTurnEffectTerminal():
        _handleTerminal(effect.record.turnId);
      // The coordinator already armed/cancelled these timers and recorded
      // the anomalies — the host deliberately ignores them.
      case VoiceTurnEffectScheduleDeadline():
      case VoiceTurnEffectCancelDeadline():
      case VoiceTurnEffectCancelAllDeadlines():
      case VoiceTurnEffectStaleEventDropped():
      case VoiceTurnEffectInvalidTransition():
        return;
    }
  }

  /// Wire as `coordinator.configure(host.presenter)` — the reducer
  /// projection is broadcast on every published transition.
  void presenter(VoiceTurnUiProjection projection) => deps.applyProjection(projection);

  /// Alternate presentation seam (`coordinator.setSnapshotHandler`), kept
  /// for parity with the TS source's dual seam; `voice_turn_driver.dart`
  /// wires `presenter` only (see that file's header — the seam this method
  /// exists for in the TS driver, the single-audible-owner leak guard, is
  /// cut).
  void snapshotHandler(VoiceTurnModel model) => deps.applyProjection(projectionOf(model));

  void _handleTerminal(VoiceTurnId turnId) {
    // Release the output lease, then release the hub's per-turn state
    // (KEEPING the warm socket).
    deps.outputCoordinator.endTurn(turnId);
    deps.hub.voiceTurnDidTerminate(turnId);
  }
}
