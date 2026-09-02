// Dart owner of the telecom call shell for the free-form voice mode: while a
// session runs, Android holds a self-managed call (ConnectionService +
// CallStyle notification — design: ~/omi-jarvis/docs/voice-call-mode-design.md),
// giving the conversation phone-call UX (hang-up in the shade and on the lock
// screen) and background-mic legality.
//
// FAIL-OPEN, matching the native side's contract: the shell is UX, not a
// prerequisite for audio. Every platform error here is logged and swallowed —
// a voice session without a call notification is still a working session, and
// on platforms without the native peer (iOS today) start() simply no-ops.
import 'package:omi/gen/voice_call_session_pigeon.g.dart';
import 'package:omi/utils/logger.dart';

class VoiceCallSession implements VoiceCallSessionFlutterApi {
  VoiceCallSession({VoiceCallSessionHostApi? hostApi, bool registerFlutterApi = true})
      : _hostApi = hostApi ?? VoiceCallSessionHostApi() {
    // One shared registration per engine, same as NativeVoicePlayer's
    // StreamingPcmPlayerFlutterApi.setUp; tests pass false to stay off the
    // platform channels.
    if (registerFlutterApi) VoiceCallSessionFlutterApi.setUp(this);
  }

  final VoiceCallSessionHostApi _hostApi;

  /// Dart-minted, monotonically increasing session identity — the same fencing
  /// as the streaming player: a stale native event can never touch a newer
  /// session.
  int _sessionCounter = 0;
  int? _activeSessionId;

  /// The call ended natively (hang-up in the notification, telecom tore it
  /// down for a real phone call). Wired in main.dart to
  /// `CaptureController.stopFreeFormVoiceMode` — the same teardown as the
  /// chat Stop button.
  void Function()? onEndedBySystem;

  /// Places the call for a new session. Resolves when the call is active or
  /// when it could not be established (fail-open) — never throws.
  Future<void> start() async {
    final sessionId = ++_sessionCounter;
    _activeSessionId = sessionId;
    try {
      final established = await _hostApi.start(sessionId);
      if (!established) {
        // Warning, not debug: without the shell there is no «идёт разговор»
        // notification and no background-mic legality — this is the first
        // thing to look for when the status-bar icon is missing.
        Logger.warning('[VoiceCallSession] no call shell for session $sessionId '
            '(telecom refused / timed out — see logcat VoiceCallController)');
      }
    } catch (e) {
      // MissingPluginException on iOS, or any platform failure: carry on.
      Logger.warning('[VoiceCallSession] start($sessionId) failed, running without a call shell: $e');
    }
  }

  /// Ends the active session's call. Idempotent; never throws. Safe when the
  /// call already ended natively (the native `end` no-ops on a stale id).
  Future<void> end() async {
    final sessionId = _activeSessionId;
    if (sessionId == null) return;
    _activeSessionId = null;
    try {
      await _hostApi.end(sessionId);
    } catch (e) {
      Logger.debug('[VoiceCallSession] end($sessionId) failed: $e');
    }
  }

  @override
  void onEnded(int sessionId, String reason) {
    if (sessionId != _activeSessionId) return;
    _activeSessionId = null;
    Logger.debug('[VoiceCallSession] session $sessionId ended natively: $reason');
    onEndedBySystem?.call();
  }
}
