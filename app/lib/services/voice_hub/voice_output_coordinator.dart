// Authoritative audible-output owner for a PTT turn — a 1:1 port of
// `desktop/windows/src/renderer/src/lib/voice/turn/voiceOutputCoordinator.ts`
// (itself a port of macOS `PTTVoiceOutputCoordinator.swift` /
// `VoiceOutputCoordinator`).
//
// Every PTT audio path (native realtime, the selected-voice fallback, the
// deterministic agent ack, the filler, the system-voice fallback) must
// acquire a turn-scoped lease before it can play. Releases and turn endings
// are identity checked so an old playback callback cannot clear a newer
// turn's output or UI.
//
// The reducer file (`voice_turn_machine.dart`) already owns `VoiceLeaseId`,
// `VoiceOutputLease`, `VoiceOutputLane`, `VoiceTurnId` and `leasesEqual` —
// reused here verbatim, not redefined. This class is the *runtime owner* of
// the lease the reducer models as a value.
//
// Port notes (traps a "natural" Dart translation gets wrong — carried over
// verbatim from the TS source's own port notes):
//   * `release` fences on `leasesEqual(activeLease, lease)` (full field
//     equality, `VoiceOutputLease.==` is already value-based in the sibling
//     file) — a reconstructed impostor lease with the same fields would
//     (correctly) match, which is why `release` ALSO requires the current
//     turn to still own it (`currentTurnId == lease.turnId`).
//   * `acquire` on the SAME lane is IDEMPOTENT — it returns the existing
//     lease, never `denied`. Any DIFFERENT lane is denied while a lease is
//     held.
//   * `deterministicAgentAck` acquiring flips `providerOutputSuppressed`
//     true for the whole turn (the ack has spoken; suppress the provider's
//     own output).
//   * Every mutation is turn-ID fenced: a stale turnId yields `staleTurn`
//     (acquire) or `false` (endTurn/interrupt/release) with NO state change.
//
// Ground rule (same as `voice_turn_machine.dart`, design doc §8): ZERO
// imports of Flutter, dart:io, or networking here. `package:uuid` is a
// pure-Dart dependency already used elsewhere in this app (see
// pubspec.yaml) for default ID minting only — injectable so tests can pin
// identities, exactly like the TS source's `mintTurnID`/`mintLeaseID`
// options.

import 'package:uuid/uuid.dart';

import 'voice_turn_machine.dart';

// ---------------------------------------------------------------------------
// MARK: - Decision (TS `VoiceOutputDecision`)
// ---------------------------------------------------------------------------

sealed class VoiceOutputDecision {
  const VoiceOutputDecision();
}

final class VoiceOutputDecisionAcquired extends VoiceOutputDecision {
  final VoiceOutputLease lease;
  const VoiceOutputDecisionAcquired(this.lease);
}

final class VoiceOutputDecisionDenied extends VoiceOutputDecision {
  final VoiceOutputLease active;
  const VoiceOutputDecisionDenied(this.active);
}

final class VoiceOutputDecisionStaleTurn extends VoiceOutputDecision {
  const VoiceOutputDecisionStaleTurn();
}

// ---------------------------------------------------------------------------
// MARK: - Snapshot (TS `VoiceOutputSnapshot`)
// ---------------------------------------------------------------------------

class VoiceOutputSnapshot {
  final VoiceTurnId? turnId;
  final VoiceOutputLease? activeLease;
  final bool providerOutputSuppressed;

  const VoiceOutputSnapshot({
    required this.turnId,
    required this.activeLease,
    required this.providerOutputSuppressed,
  });
}

// ---------------------------------------------------------------------------
// MARK: - Handoff policy (TS `VoiceOutputHandoffPolicy`)
// ---------------------------------------------------------------------------

/// The FILLER lane yields to any non-filler lane on the SAME turn, and
/// nothing else yields. Ported verbatim: `active.turnID == turnID &&
/// active.lane == .filler && incomingLane != .filler`.
bool voiceOutputFillerCanYield(
  VoiceOutputLease active,
  VoiceOutputLane incomingLane,
  VoiceTurnId turnId,
) {
  return active.turnId == turnId && active.lane == VoiceOutputLane.filler && incomingLane != VoiceOutputLane.filler;
}

// ---------------------------------------------------------------------------
// MARK: - Playback-start policy (TS `VoicePlaybackStartPolicy`)
// ---------------------------------------------------------------------------

/// A player only owns the lease once it has ACTUALLY started
/// (`accepts(started) => started`).
bool voicePlaybackStartPolicyAccepts(bool started) => started;

// ---------------------------------------------------------------------------
// MARK: - Coordinator
// ---------------------------------------------------------------------------

class VoiceOutputCoordinator {
  final VoiceTurnId Function() _mintTurnId;
  final VoiceLeaseId Function() _mintLeaseId;

  VoiceTurnId? _currentTurnId;
  VoiceOutputLease? _currentActiveLease;
  bool _providerOutputSuppressed = false;

  VoiceOutputCoordinator({
    VoiceTurnId Function()? mintTurnId,
    VoiceLeaseId Function()? mintLeaseId,
  })  : _mintTurnId = mintTurnId ?? (() => const Uuid().v4()),
        _mintLeaseId = mintLeaseId ?? (() => const Uuid().v4());

  /// TS `beginTurn(id = mintTurnID())`.
  VoiceTurnId beginTurn([VoiceTurnId? id]) {
    final resolvedId = id ?? _mintTurnId();
    _currentTurnId = resolvedId;
    _currentActiveLease = null;
    _providerOutputSuppressed = false;
    return resolvedId;
  }

  /// TS `endTurn` — no-op unless the requested turn is current.
  bool endTurn(VoiceTurnId requestedTurnId) {
    if (requestedTurnId != _currentTurnId) return false;
    _currentTurnId = null;
    _currentActiveLease = null;
    _providerOutputSuppressed = false;
    return true;
  }

  /// TS `interrupt` — revokes the lease but KEEPS the turn open.
  bool interrupt(VoiceTurnId requestedTurnId) {
    if (requestedTurnId != _currentTurnId) return false;
    _currentActiveLease = null;
    _providerOutputSuppressed = false;
    return true;
  }

  /// TS `acquire(lane, turnID)`. Same-lane acquire is idempotent; any other
  /// lane is denied while a lease is held; a stale turn is rejected.
  VoiceOutputDecision acquire(VoiceOutputLane lane, VoiceTurnId requestedTurnId) {
    if (requestedTurnId != _currentTurnId) return const VoiceOutputDecisionStaleTurn();
    final active = _currentActiveLease;
    if (active != null) {
      if (active.turnId == requestedTurnId && active.lane == lane) {
        return VoiceOutputDecisionAcquired(active);
      }
      return VoiceOutputDecisionDenied(active);
    }
    final lease = VoiceOutputLease(id: _mintLeaseId(), turnId: requestedTurnId, lane: lane);
    _currentActiveLease = lease;
    if (lane == VoiceOutputLane.deterministicAgentAck) {
      _providerOutputSuppressed = true;
    }
    return VoiceOutputDecisionAcquired(lease);
  }

  /// TS `release` — exact lease identity AND the turn must still own it.
  bool release(VoiceOutputLease lease) {
    final active = _currentActiveLease;
    if (active == null || !leasesEqual(active, lease) || _currentTurnId != lease.turnId) {
      return false;
    }
    _currentActiveLease = null;
    _providerOutputSuppressed = false;
    return true;
  }

  VoiceOutputSnapshot snapshot() => VoiceOutputSnapshot(
        turnId: _currentTurnId,
        activeLease: _currentActiveLease,
        providerOutputSuppressed: _providerOutputSuppressed,
      );
}
