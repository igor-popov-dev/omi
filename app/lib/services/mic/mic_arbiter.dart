import 'dart:typed_data';

import 'package:omi/services/services.dart';

/// Single-owner token shared by every microphone stack (flutter_sound and the
/// native iOS recorder), so two stacks can never hold the mic — and fight over
/// the AVAudioSession — at the same time.
class MicArbiter {
  String? _owner;

  String? get owner => _owner;

  bool tryAcquire(String owner) {
    if (_owner != null && _owner != owner) return false;
    _owner = owner;
    return true;
  }

  void release(String owner) {
    if (_owner == owner) _owner = null;
  }
}

/// Arbiter owner names. Strings compared by identity of value — kept here so
/// the two handles onto the one native recorder cannot drift apart by typo.
const String kConversationMicOwner = 'conversation';
const String kVoiceHubMicOwner = 'voice-hub';

/// The two handles the app has onto ONE native recorder: conversation capture
/// and the realtime voice hub.
///
/// Sharing the [native] instance is the whole point, not an optimization.
/// `NativeMicRecorderService` registers itself as THE `PhoneMicFlutterApi`
/// handler in its constructor, and that registration is a single global
/// message handler per channel — so a second instance silently detaches the
/// first, which then never receives another frame, state change or error for
/// the rest of the process. Worse, session ids are minted per instance and
/// both start at 1, so the identity gate that exists to keep sessions apart
/// reads the other consumer's frames as its own.
///
/// One instance, two arbiter owners: two consumers can still never hold the
/// mic at the same time, and the loser now finds out by [StateError] instead
/// of by having its audio quietly rerouted.
({IMicRecorderService conversation, IMicRecorderService voiceHub}) arbitratedPhoneMicHandles({
  required IMicRecorderService native,
  required MicArbiter arbiter,
}) {
  return (
    conversation: ArbitratedMic(inner: native, arbiter: arbiter, owner: kConversationMicOwner),
    voiceHub: ArbitratedMic(inner: native, arbiter: arbiter, owner: kVoiceHubMicOwner),
  );
}

/// Decorator gating an [IMicRecorderService] behind a shared [MicArbiter].
/// Contention throws a [StateError], mirroring [MicRecorderService]'s existing
/// "Recorder is recording" throw — but consistently across both stacks.
class ArbitratedMic implements IMicRecorderService {
  final IMicRecorderService _inner;
  final MicArbiter _arbiter;
  final String _owner;

  ArbitratedMic({required IMicRecorderService inner, required MicArbiter arbiter, required String owner})
      : _inner = inner,
        _arbiter = arbiter,
        _owner = owner;

  @override
  Future<void> start({
    required Function(Uint8List bytes) onByteReceived,
    Function()? onRecording,
    Function()? onStop,
    Function()? onInitializing,
    Function()? onStalled,
    Function(bool began)? onInterruption,
  }) async {
    if (!_arbiter.tryAcquire(_owner)) {
      throw StateError('Microphone is busy (held by ${_arbiter.owner})');
    }
    try {
      await _inner.start(
        onByteReceived: onByteReceived,
        onRecording: onRecording,
        onStop: () {
          // Release on natural stops too (e.g. recorder self-retired), so a
          // dead session can never deadlock the other mic consumer.
          _arbiter.release(_owner);
          onStop?.call();
        },
        onInitializing: onInitializing,
        onStalled: onStalled,
        onInterruption: onInterruption,
      );
    } catch (e) {
      _arbiter.release(_owner);
      rethrow;
    }
  }

  @override
  Future<void> startBatch({
    Function()? onStop,
    Function(bool began)? onInterruption,
    Function()? onBatchStalled,
    Function(String code, String message)? onError,
  }) async {
    if (!_arbiter.tryAcquire(_owner)) {
      throw StateError('Microphone is busy (held by ${_arbiter.owner})');
    }
    try {
      await _inner.startBatch(
        onStop: () {
          _arbiter.release(_owner);
          onStop?.call();
        },
        onInterruption: onInterruption,
        onBatchStalled: onBatchStalled,
        onError: onError,
      );
    } catch (e) {
      _arbiter.release(_owner);
      rethrow;
    }
  }

  @override
  void stop() {
    _inner.stop();
    _arbiter.release(_owner);
  }

  @override
  void probeStallAfterForeground() {
    _inner.probeStallAfterForeground();
  }
}
