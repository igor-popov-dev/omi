import 'package:pigeon/pigeon.dart';

// Native contract for running one free-form voice-mode session as a
// self-managed telecom call (Android ConnectionService + CallStyle
// notification), so the OS treats the assistant conversation exactly like an
// ongoing phone call: a hang-up action in the shade and on the lock screen,
// telecom-owned audio routing, and a legal microphone even when the app is
// backgrounded (design: ~/omi-jarvis/docs/voice-call-mode-design.md).
//
// Mirrors streaming_pcm_player_interface.dart's session-id fencing: every
// FlutterApi event carries the id of the session it belongs to, and stale
// events from a torn-down call can never reach a newer Dart-side session.
// Regenerate with: dart run pigeon --input lib/voice_call_session_interface.dart
@ConfigurePigeon(
  PigeonOptions(
    dartOut: 'lib/gen/voice_call_session_pigeon.g.dart',
    dartOptions: DartOptions(),
    kotlinOut: 'android/app/src/main/kotlin/com/friend/ios/voicecall/VoiceCallSessionPigeon.g.kt',
    kotlinOptions: KotlinOptions(package: 'com.friend.ios.voicecall', errorClassName: 'VoiceCallSessionPigeonError'),
    dartPackageName: 'omi_voice_call_session',
  ),
)

/// Dart -> native. One telecom call per free-form voice-mode session.
@HostApi()
abstract class VoiceCallSessionHostApi {
  /// Registers the self-managed PhoneAccount (idempotent) and places the
  /// call. Resolves `true` once the Connection is active and the CallStyle
  /// foreground service is up; `false` when telecom refuses the call
  /// (`isOutgoingCallPermitted` said no — e.g. a real cellular call is
  /// already active). The voice mode itself must keep working when this
  /// returns `false`: the call shell is UX + background-mic legality, not a
  /// prerequisite for audio (fail-open, like every other shell here).
  @async
  bool start(int sessionId);

  /// Ends the call: disconnects + destroys the Connection, stops the
  /// foreground service, removes the notification. Idempotent; safe for a
  /// session that never got a call (start returned false) or already ended.
  @async
  void end(int sessionId);
}

/// Native -> Dart.
@FlutterApi()
abstract class VoiceCallSessionFlutterApi {
  /// The call ended natively rather than through [VoiceCallSessionHostApi.end]:
  /// the user hit hang-up in the notification, telecom tore the call down
  /// (an answered real phone call — session policy is to END, not hold, per
  /// Igor's 24.08 decision), or the Connection failed. The Dart side reacts
  /// by stopping the whole voice mode (the same path as the chat Stop
  /// button); a reason string is carried for logging only.
  void onEnded(int sessionId, String reason);
}
