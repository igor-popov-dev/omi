import 'package:pigeon/pigeon.dart';

// Native contract for the streaming spoken-audio player (design doc §7/§4 step 3:
// AudioTrack on Android, potential AVAudioEngine peer on iOS — Android only for now).
// Mirrors phone_mic_interface.dart's session-id fencing so a stale native callback
// from a torn-down player can never reach a newer Dart-side session.
// Regenerate with: dart run pigeon --input lib/streaming_pcm_player_interface.dart
@ConfigurePigeon(
  PigeonOptions(
    dartOut: 'lib/gen/streaming_pcm_player_pigeon.g.dart',
    dartOptions: DartOptions(),
    kotlinOut: 'android/app/src/main/kotlin/com/friend/ios/voiceplayer/StreamingPcmPlayerPigeon.g.kt',
    // PigeonCommunicator.g.kt (package com.friend.ios) already declares the default
    // FlutterError; an own package + error class keeps generated files disjoint,
    // same convention as PhoneMicPigeon.g.kt.
    kotlinOptions:
        KotlinOptions(package: 'com.friend.ios.voiceplayer', errorClassName: 'StreamingPcmPlayerPigeonError'),
    dartPackageName: 'omi_streaming_pcm_player',
  ),
)

/// Dart -> native. One player instance per warm hub session (design doc §4:
/// `VoicePlayerFactory` is called once per `ensureWarm()`); a fresh `start()`
/// after a previous `close()` is a new instance, not a resume.
///
/// `start(sessionId)` resolves once the AudioTrack is built and playing (silence,
/// nothing enqueued yet) or throws a PlatformException with `track_init_failed` if
/// AudioTrack construction/initialization fails. `sessionId` is a Dart-minted,
/// monotonically increasing identity: every FlutterApi event carries the id of the
/// session it belongs to, and every HostApi call below is dropped natively if
/// `sessionId` does not match the currently active one (guards against a call that
/// raced a `close()`).
///
/// `enqueuePcm16`/`flush`/`clear` are fire-and-forget (no round trip) — the turn
/// choreography in `hub_session.dart` never awaits them, only `start`/`close`.
@HostApi()
abstract class StreamingPcmPlayerHostApi {
  @async
  void start(int sessionId);

  /// Raw 16-bit little-endian mono PCM @24kHz (Gemini Live spoken-audio wire
  /// format, `geminiHubSession.ts`/`gemini_hub_session.dart` `playAudio`). Queued
  /// in arrival order and written to the AudioTrack by a dedicated native thread.
  void enqueuePcm16(Uint8List bytes, int sessionId);

  /// End of turn (`BaseHubSession.flushPlayback`): this implementation writes
  /// straight through with no pre-roll cushion, so nothing is actually withheld —
  /// `flush` only arms `onDrained` detection for the audio queued up to this
  /// call (see that method's doc for why it is a fixed post-roll estimate, not
  /// an exact playback-position marker).
  void flush(int sessionId);

  /// Barge-in (`BaseHubSession.clearPlayback`): drop everything queued AND
  /// already handed to the AudioTrack, immediately, then leave the track paused
  /// and ready — the next `enqueuePcm16` resumes it for the replacement turn on
  /// the same warm player (no `start()` round trip).
  void clear(int sessionId);

  /// Idempotent teardown: stop the writer thread, release the AudioTrack. Safe to
  /// call on an already-closed or never-started player.
  @async
  void close(int sessionId);
}

/// Native -> Dart. Both map straight onto `VoicePlayerStartSpec` in
/// `hub_session.dart` (`onStarted`/`onDrained`). A `sessionId` mismatch against
/// the Dart-side active player is dropped by the caller, same fencing as
/// `PhoneMicFlutterApi`.
@FlutterApi()
abstract class StreamingPcmPlayerFlutterApi {
  /// Fires once, the first time audio actually reaches the AudioTrack after
  /// `start()` (i.e. on the first non-empty `enqueuePcm16`) — not at `start()`
  /// itself, which only means "ready to receive", not "audibly speaking".
  void onStarted(int sessionId);

  /// Fires once per `flush()`, once the audio queued at that flush has had
  /// time to actually leave the speaker. NOT driven by
  /// `AudioTrack.setNotificationMarkerPosition` — whether that API's frame
  /// position resets across a barge-in `pause()`+`flush()` cycle could not be
  /// verified against real hardware in the environment this was written in
  /// (see `StreamingPcmPlayer.bufferDrainMs` doc), so this is instead a fixed
  /// post-roll delay after the native writer's software queue empties,
  /// deliberately rounded up. A `clear()` before that delay elapses cancels
  /// the pending callback — barge-in does not get a stray `onDrained` for
  /// audio it just discarded.
  void onDrained(int sessionId);
}
