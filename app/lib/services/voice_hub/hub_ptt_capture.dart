// The push-to-talk capture CONTRACT the turn driver depends on — design doc
// `~/omi-jarvis/docs/hub-port-design.md` §7 "ptt/capture.ts — NOT a template
// for a structural port": the TS source (`ptt/capture.ts`, 161 lines) is an
// IPC client to a SEPARATE Electron capture window (`pttGraph.ts`), an
// architecture with no Android analog (one process, one mic owner). Per the
// design doc, only the CONTRACT is ported — `PttCapture{analyser, drain(),
// dispose()}` — not the file.
//
// Two more narrowing cuts vs. even that contract, both driven by what
// `voice_turn_driver.dart` actually calls (it never reads `.analyser` or
// `.drain()` — only `.dispose()`, confirmed by re-reading
// `voiceHubTurnDriver.ts` end-to-end for this port):
//   * `analyser` (a `WaveformSource` for a waveform UI widget) — dropped.
//     It exists in the TS contract for OTHER consumers (the local non-hub
//     PTT hook's waveform), not for this driver. No Android UI is wired to
//     the hub this tick anyway (see the driver's own file header).
//   * `drain()` (resolve with the capture window's full backfilled buffer,
//     idempotent, 600ms-timeout fallback to empty) — dropped for the same
//     reason: it is the local-hook's finalize path, not the hub driver's.
//     The hub driver finalizes by simply calling `dispose()` once `end()`/
//     `cancel()` fires; audio already streamed via `onChunk` is what the
//     driver accumulates itself (see `_cascadeBuffer` in
//     `voice_turn_driver.dart`), so there is nothing left to "drain".
//
// What IS carried over faithfully: `backfillMs` pre-roll is simply not
// offered — `NativeMicRecorderService`/the native `PhoneMicHostApi` have no
// pre-roll ring buffer at all (confirmed by reading both files for this
// port), so there is no seam to wire even if we wanted parity. A future
// native pre-roll addition would re-introduce it here, not silently no-op.
import 'dart:async';
import 'dart:typed_data';

import 'package:omi/services/services.dart' show IMicRecorderService;

/// What the turn driver needs from a live mic capture: nothing but a way to
/// stop it. See file header for why `analyser`/`drain()` are not modeled.
abstract class HubPttCapture {
  void dispose();
}

class HubPttCaptureOptions {
  /// Tee for each raw PCM16LE-mono-16kHz chunk, in arrival order — mirrors
  /// `NativeMicRecorderService.start(onByteReceived: ...)`.
  final void Function(Uint8List pcm)? onChunk;

  /// The mic was taken away (`began: true`) or given back (`began: false`) —
  /// mirrors `NativeMicRecorderService.start(onInterruption: ...)`, which
  /// relays the native controller's `INTERRUPTED`/`RUNNING` transitions
  /// (`PhoneMicController.kt`: `Cause.MODE` when a phone call takes the audio
  /// mode, `Cause.SILENCED` when another app preempts the input).
  ///
  /// Nothing restarts the capture from here: the native side resumes itself
  /// and this is state, not a command (see `NativeMicRecorderService`'s own
  /// header). A continuous consumer needs it because the alternative is
  /// inferring a silent mic from the absence of frames, which looks exactly
  /// like a person not talking.
  final void Function(bool began)? onInterruption;

  const HubPttCaptureOptions({this.onChunk, this.onInterruption});
}

/// Resolves once the capture is confirmed live, or rejects if the mic failed
/// to start (permission denied, engine start failure, ...) — mirrors the TS
/// `startPttCapture` promise contract the driver depends on.
typedef HubStartCapture = Future<HubPttCapture> Function(HubPttCaptureOptions options);

/// Wraps one [IMicRecorderService] session as a [HubPttCapture]. `dispose()`
/// is idempotent (mirrors `NativeMicRecorderService.stop()`'s own
/// idempotency — see that file's header).
class NativeMicHubPttCapture implements HubPttCapture {
  final IMicRecorderService _recorder;
  bool _disposed = false;

  NativeMicHubPttCapture._(this._recorder);

  static Future<NativeMicHubPttCapture> start(
    IMicRecorderService recorder, {
    required void Function(Uint8List pcm) onChunk,
    void Function(bool began)? onInterruption,
  }) async {
    await recorder.start(onByteReceived: onChunk, onInterruption: onInterruption);
    return NativeMicHubPttCapture._(recorder);
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _recorder.stop();
  }
}

/// Production [HubStartCapture]: one [IMicRecorderService] session per turn.
///
/// `createRecorder` is expected to hand back the app's SHARED recorder, not a
/// fresh one — production passes `ServiceManager.instance().voiceHubMic`. It
/// once minted a `NativeMicRecorderService()` per capture, which detached
/// conversation capture from the native event stream for the rest of the
/// process (see `arbitratedPhoneMicHandles`). The seam stays a factory
/// because the arbiter, not this file, decides whether the mic is available:
/// a contended `start()` throws, and the capture contract already promises
/// callers a rejected future in that case.
HubStartCapture nativeMicHubCaptureFactory(IMicRecorderService Function() createRecorder) {
  return (options) async {
    final recorder = createRecorder();
    final onChunk = options.onChunk;
    final onInterruption = options.onInterruption;
    return NativeMicHubPttCapture.start(
      recorder,
      onChunk: (pcm) => onChunk?.call(pcm),
      // Passed through as null when unwanted rather than as an empty closure:
      // `NativeMicRecorderService` treats a null handler as "nobody is
      // listening", which is the truth for the PTT driver.
      onInterruption: onInterruption == null ? null : (began) => onInterruption(began),
    );
  };
}
