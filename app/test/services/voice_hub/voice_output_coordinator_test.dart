// A 1:1-in-spirit port of the desktop (Electron/TS) coordinator test suite
// at `desktop/windows/src/renderer/src/lib/voice/turn/voiceOutputCoordinator.test.ts`
// (itself ported from macOS `PTTVoiceOutputCoordinatorTests.swift`, 12
// cases). Test names are kept verbatim where they exist upstream.
//
// Two TS cases are intentionally NOT ported here — both are source-file grep
// tripwires against `voiceController.ts` (Windows-desktop playback wiring
// that has no Android counterpart yet, see `hub-port-design.md` §7 "player
// for streaming PCM24kHz" open question): `testFillerCarriesTextIntoSystemVoiceFallback`
// and the "voiceController leaseID seam" PR-3 case. Everything else in
// `VoiceOutputCoordinator` is pure, provider-agnostic lease bookkeeping and
// is ported in full below.
import 'package:flutter_test/flutter_test.dart';

import 'package:omi/services/voice_hub/voice_output_coordinator.dart';
import 'package:omi/services/voice_hub/voice_turn_machine.dart';

// ---- fixtures --------------------------------------------------------------

int _seq = 0;
VoiceTurnId _freshTurnId() => 'turn-${++_seq}';
VoiceLeaseId _freshLeaseId() => 'lease-${++_seq}';

const List<VoiceOutputLane> _allLanes = VoiceOutputLane.values;

VoiceOutputLease? _tryLease(VoiceOutputDecision decision) =>
    decision is VoiceOutputDecisionAcquired ? decision.lease : null;

void main() {
  group('VoiceOutputCoordinator — PTT output leases (ported from PTTVoiceOutputCoordinatorTests)', () {
    test('testAudioPlayerMustActuallyStartBeforePlaybackOwnsLease', () {
      expect(voicePlaybackStartPolicyAccepts(true), isTrue);
      expect(voicePlaybackStartPolicyAccepts(false), isFalse);
    });

    test('testFallbackCannotStartAfterNativeRealtimeLease', () {
      final coordinator = VoiceOutputCoordinator();
      final turnId = coordinator.beginTurn();
      final native = _tryLease(coordinator.acquire(VoiceOutputLane.nativeRealtime, turnId));

      expect(native?.lane, VoiceOutputLane.nativeRealtime);
      final decision = coordinator.acquire(VoiceOutputLane.selectedVoiceFallback, turnId);
      expect(decision, isA<VoiceOutputDecisionDenied>());
      expect(native, isNotNull);
      expect(leasesEqual((decision as VoiceOutputDecisionDenied).active, native!), isTrue);
    });

    test('testLateNativeAudioIsDeniedAfterFallbackLease', () {
      final coordinator = VoiceOutputCoordinator();
      final turnId = coordinator.beginTurn();
      final fallback = _tryLease(coordinator.acquire(VoiceOutputLane.selectedVoiceFallback, turnId));

      final decision = coordinator.acquire(VoiceOutputLane.nativeRealtime, turnId);
      expect(decision, isA<VoiceOutputDecisionDenied>());
      expect(fallback, isNotNull);
      expect(leasesEqual((decision as VoiceOutputDecisionDenied).active, fallback!), isTrue);
    });

    test('testEveryPTTAudibleLaneCompetesForTheSameLease', () {
      for (final firstLane in _allLanes) {
        for (final competingLane in _allLanes) {
          if (competingLane == firstLane) continue;
          final coordinator = VoiceOutputCoordinator();
          final turnId = coordinator.beginTurn();
          final first = _tryLease(coordinator.acquire(firstLane, turnId));

          final decision = coordinator.acquire(competingLane, turnId);
          expect(decision, isA<VoiceOutputDecisionDenied>(), reason: '$competingLane should not overlap $firstLane');
          expect(first, isNotNull);
          expect(leasesEqual((decision as VoiceOutputDecisionDenied).active, first!), isTrue,
              reason: '$competingLane should not overlap $firstLane');
        }
      }
    });

    test('testFillerIsTheOnlyLaneThatYieldsToRealOutputOnTheSameTurn', () {
      final turnId = _freshTurnId();
      final filler = VoiceOutputLease(id: _freshLeaseId(), turnId: turnId, lane: VoiceOutputLane.filler);

      for (final lane in _allLanes) {
        if (lane == VoiceOutputLane.filler) continue;
        expect(voiceOutputFillerCanYield(filler, lane, turnId), isTrue);
      }
      expect(voiceOutputFillerCanYield(filler, VoiceOutputLane.filler, turnId), isFalse);

      final native = VoiceOutputLease(id: _freshLeaseId(), turnId: turnId, lane: VoiceOutputLane.nativeRealtime);
      expect(voiceOutputFillerCanYield(native, VoiceOutputLane.selectedVoiceFallback, turnId), isFalse);
      expect(voiceOutputFillerCanYield(filler, VoiceOutputLane.nativeRealtime, _freshTurnId()), isFalse);
    });

    test('testSameLaneAcquireIsIdempotent', () {
      final coordinator = VoiceOutputCoordinator();
      final turnId = coordinator.beginTurn();
      final first = _tryLease(coordinator.acquire(VoiceOutputLane.nativeRealtime, turnId));
      final second = _tryLease(coordinator.acquire(VoiceOutputLane.nativeRealtime, turnId));

      expect(first, isNotNull);
      expect(second, isNotNull);
      expect(leasesEqual(first!, second!), isTrue);
    });

    test('testDeterministicAckSuppressesProviderOutputForTurn', () {
      final coordinator = VoiceOutputCoordinator();
      final turnId = coordinator.beginTurn();

      expect(_tryLease(coordinator.acquire(VoiceOutputLane.deterministicAgentAck, turnId)), isNotNull);
      expect(coordinator.snapshot().providerOutputSuppressed, isTrue);
    });

    test('testStaleReleaseCannotClearCurrentLease', () {
      final coordinator = VoiceOutputCoordinator();
      final firstTurnId = coordinator.beginTurn();
      final staleLease = _tryLease(coordinator.acquire(VoiceOutputLane.nativeRealtime, firstTurnId));
      final secondTurnId = coordinator.beginTurn();
      final currentLease = _tryLease(coordinator.acquire(VoiceOutputLane.selectedVoiceFallback, secondTurnId));

      expect(staleLease, isNotNull);
      expect(currentLease, isNotNull);
      expect(coordinator.release(staleLease!), isFalse);
      expect(leasesEqual(coordinator.snapshot().activeLease!, currentLease!), isTrue);
    });

    test('testStaleTurnCannotAcquireOrEndCurrentTurn', () {
      final coordinator = VoiceOutputCoordinator();
      final staleTurnId = coordinator.beginTurn();
      final currentTurnId = coordinator.beginTurn();

      expect(coordinator.acquire(VoiceOutputLane.nativeRealtime, staleTurnId), isA<VoiceOutputDecisionStaleTurn>());
      expect(coordinator.endTurn(staleTurnId), isFalse);
      expect(coordinator.snapshot().turnId, currentTurnId);
    });

    test('testReleaseRequiresExactLeaseIdentity', () {
      final coordinator = VoiceOutputCoordinator();
      final turnId = coordinator.beginTurn();
      final lease = _tryLease(coordinator.acquire(VoiceOutputLane.nativeRealtime, turnId));
      final impostor = VoiceOutputLease(id: _freshLeaseId(), turnId: turnId, lane: VoiceOutputLane.nativeRealtime);

      expect(lease, isNotNull);
      expect(coordinator.release(impostor), isFalse);
      expect(leasesEqual(coordinator.snapshot().activeLease!, lease!), isTrue);
      expect(coordinator.release(lease), isTrue);
      expect(coordinator.snapshot().activeLease, isNull);
    });

    test('testInterruptRequiresCurrentTurnAndRevokesLease', () {
      final coordinator = VoiceOutputCoordinator();
      final turnId = coordinator.beginTurn();
      expect(_tryLease(coordinator.acquire(VoiceOutputLane.systemVoiceFallback, turnId)), isNotNull);

      expect(coordinator.interrupt(_freshTurnId()), isFalse);
      expect(coordinator.snapshot().activeLease, isNotNull);
      expect(coordinator.interrupt(turnId), isTrue);
      expect(coordinator.snapshot().activeLease, isNull);
    });
  });
}
