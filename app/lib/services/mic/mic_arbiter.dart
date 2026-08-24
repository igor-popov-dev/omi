import 'dart:typed_data';

import 'package:omi/services/services.dart';

/// Single-owner token shared by every microphone stack (flutter_sound and the
/// native iOS recorder), so two stacks can never hold the mic — and fight over
/// the AVAudioSession — at the same time.
///
/// An in-app call is the third contender, and it is not a stack: its SDK takes the
/// microphone natively, below this arbiter, without asking. So a call is recorded here
/// as a VETO rather than as an owner — see [holdForCall].
class MicArbiter {
  String? _owner;
  bool _callHold = false;

  String? get owner => _owner;

  /// True while an in-app call holds the phone's microphone through its own SDK.
  bool get callHolds => _callHold;

  /// Who the microphone is refused for, in the words that reach the log and the error.
  /// A call is named as such: '(held by null)' is what a veto with no owner would read
  /// as otherwise, and that sends the reader looking for a recorder that never existed.
  String get holder => _callHold ? 'an in-app call' : (_owner ?? 'nobody');

  /// Record that an in-app call has the microphone. Deliberately not an acquisition:
  /// it cannot be refused and cannot fail. The call SDK will take the mic whatever this
  /// arbiter thinks, and refusing here would only mean losing the call — while the whole
  /// point is to refuse the OTHER contenders, honestly, instead of letting them record
  /// silence next to a live call.
  ///
  /// Idempotent, and independent of [_owner]: a recorder releasing its token mid-call
  /// (which is exactly what the ambient-capture pause does) must not lift the veto.
  void holdForCall() => _callHold = true;

  /// Give the microphone back after the call. Must run on EVERY exit of a call, which is
  /// why the only caller derives it from the call state rather than from the exit paths
  /// (see AmbientCaptureHold): left set, it makes the phone deaf for the rest of the
  /// session — every later recording refused, none of them by anything the user can see.
  void releaseCall() => _callHold = false;

  bool tryAcquire(String owner) {
    // Checked before re-entrancy on purpose: a stack that already held the token before
    // the call started does not get to keep renewing it while the call runs.
    if (_callHold) return false;
    if (_owner != null && _owner != owner) return false;
    _owner = owner;
    return true;
  }

  void release(String owner) {
    if (_owner == owner) _owner = null;
  }
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
      throw StateError('Microphone is busy (held by ${_arbiter.holder})');
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
      throw StateError('Microphone is busy (held by ${_arbiter.holder})');
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
