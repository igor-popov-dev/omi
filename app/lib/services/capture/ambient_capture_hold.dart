import 'package:omi/backend/schema/phone_call.dart';
import 'package:omi/utils/logger.dart';

/// Does a call in [state] still hold the phone's microphone?
///
/// The mistake this guards against is not a wrong pause but a MISSED RESUME: forget one
/// exit and the phone stays deaf after the call, for the rest of the session, silently.
/// Enumerating exits by hand is how that gets forgotten — so the hold is derived from the
/// call state instead, in one place, by a switch the analyzer will not let a new state
/// slip past.
bool callOwnsMicrophone(PhoneCallState state) {
  switch (state) {
    case PhoneCallState.connecting:
    case PhoneCallState.ringing:
    case PhoneCallState.active:
      return true;
    case PhoneCallState.idle:
    case PhoneCallState.ended:
    case PhoneCallState.failed:
      return false;
  }
}

/// Keeps the phone's own always-on recording off the microphone for the length of an
/// in-app call, and — the part that actually breaks — puts it back afterwards.
///
/// Why it exists at all: during a call of ours the phone keeps streaming the same
/// conversation into `v4/listen` while the cloud streams both legs under its own call_id,
/// and the backend de-duplicates nothing. One call becomes TWO conversations, one holding
/// our side and one the other party's — a result plausible enough to go unnoticed
/// (measured, lane 6 tick 22, marathon/tools/vox-dual-session-probe.py, case `ambient`).
/// On Android the two captures also fight over the microphone, and the loser gets silence.
///
/// Why it is a class of its own rather than three lines in the call provider: inside the
/// provider the hold is a side effect of a state machine driven by a phone SDK, so the
/// missed resume — the failure that matters — cannot be seen without a phone. Here it can.
class AmbientCaptureHold {
  /// Installed by the app. Left null in tests and on any build without capture; a hold
  /// with no gate is a no-op, never an error.
  Future<void> Function(bool paused)? gate;

  bool _held = false;

  /// True while ambient capture is hushed for a call.
  bool get held => _held;

  Future<void>? _inFlight;

  /// Waits for a pause or resume already in flight. Dialing must not race the pause: the
  /// call SDK takes the microphone natively, and a recorder still holding it at that
  /// moment is exactly the fight the pause exists to prevent.
  Future<void> settled() => _inFlight ?? Future.value();

  /// Called on every transition of the call state. Idempotent by construction: one call
  /// reports its end more than once (the transport says `failed`, the screen pops, a
  /// delayed reset lands on `idle`), and a second resume must not restart a session the
  /// user stopped by hand in between.
  void onCallState(PhoneCallState state) {
    final wanted = callOwnsMicrophone(state);
    if (_held == wanted) return;
    _held = wanted;
    final gate = this.gate;
    if (gate == null) return;
    // Chained, not replaced: a call that ends while its own pause is still in flight
    // would otherwise resume first and pause after, leaving the phone hushed forever.
    final previous = _inFlight ?? Future.value();
    _inFlight = previous.then((_) => gate(wanted)).catchError((Object e, StackTrace st) {
      // Never let this fail a call: losing the pause costs a duplicate conversation,
      // losing the call costs the call.
      Logger.error('AmbientCaptureHold: gate($wanted) failed: $e\n$st');
    });
  }
}
