import 'dart:typed_data';

import 'package:omi/services/services.dart';
import 'package:omi/utils/logger.dart';

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
  final List<void Function()> _evictions = [];

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
  ///
  /// The veto alone is only half the job: it refuses the NEXT claim, and says nothing to a
  /// recorder that was already running when the call began. So this also EVICTS — see
  /// [onEvictedByCall]. The reason is the call, not the recording: on Android the
  /// microphone goes to one owner, and a flutter_sound session still holding it when the
  /// call SDK opens its own is how the other party hears nothing for the whole call. The
  /// silent voice memo is the cheaper half of the same bug.
  void holdForCall() {
    if (_callHold) return;
    _callHold = true;
    // Copied before iterating: an eviction may unregister itself as it unwinds.
    for (final evict in List<void Function()>.of(_evictions)) {
      // Never let a listener fail a call. Losing an eviction costs a wasted recording;
      // letting it throw here would abort the state transition that pauses ambient
      // capture and hands the microphone over — that costs the call itself.
      try {
        evict();
      } catch (e, st) {
        Logger.error('MicArbiter: eviction failed: $e\n$st');
      }
    }
  }

  /// Register [evict], to be run the moment an in-app call takes the microphone.
  ///
  /// Registration is deliberately open rather than a fixed list of stacks: a recorder
  /// added later has to opt IN to being evicted, but nothing has to remember to add it to
  /// a list kept somewhere else — the failure mode that keeps producing missed exits here.
  ///
  /// Returns a function that unregisters it. Callers whose lifetime is shorter than the
  /// arbiter's (a provider, a screen) must call it: the arbiter outlives every screen, and
  /// a listener left behind would unwind a session that ended long ago.
  void Function() onEvictedByCall(void Function() evict) {
    _evictions.add(evict);
    return () => _evictions.remove(evict);
  }

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

  /// Whether an in-app call stops this stack outright when it takes the microphone.
  ///
  /// True for the flutter_sound stack (chat voice memos, the speech profile): nothing else
  /// stops it, and a session left running would hold the microphone the call SDK is opening.
  ///
  /// FALSE for conversation capture, and not as an oversight. That stack is stopped by
  /// [CaptureController.pauseForInAppCall], which does more than stop: it marks the capture
  /// interrupted, keeps the socket and the segments already captured, and puts the
  /// recording back when the call ends. A blind stop here would run first, fire that
  /// controller's own stop callback, clear its active source — and the resume after the
  /// call would find nothing left to resume.
  ArbitratedMic({
    required IMicRecorderService inner,
    required MicArbiter arbiter,
    required String owner,
    bool evictedByCall = false,
  })  : _inner = inner,
        _arbiter = arbiter,
        _owner = owner {
    if (evictedByCall) arbiter.onEvictedByCall(_onCallTookMic);
  }

  void _onCallTookMic() {
    if (_arbiter.owner != _owner) return;
    // Token released BEFORE the stop, not after: if the stop throws, the token must not
    // stay held. The veto keeps others out for the length of the call anyway, and a token
    // still held after it lifts would refuse every later recording for the rest of the
    // session — deaf, and with nothing on screen to explain it.
    _arbiter.release(_owner);
    _inner.stop();
  }

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
