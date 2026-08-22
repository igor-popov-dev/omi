/// Self-host patch: one shared answer to "what should the recording UI say
/// about transcription right now?", so the capture page and the home capture
/// card cannot drift apart. Pure function — kept free of provider state so it
/// is trivially testable.
enum SttDisplayStatus {
  /// Recording is muted/paused (user action or an active phone call).
  paused,

  /// The server explicitly reported live STT as unavailable (stt_failed).
  failed,

  /// The custom STT endpoint is unreachable; audio keeps buffering locally.
  offlineBuffering,

  /// The transcription transport is down (socket lost / reconnecting) — very
  /// different from "silence", and must not be displayed as it.
  disconnected,

  /// Transcript text actually arrived recently — recognition is working.
  live,

  /// Transport is healthy and audio is flowing, but no speech has been
  /// recognized recently (silence, or nothing said yet).
  waitingForSpeech,
}

/// How recent the last recognized segment must be to still count as
/// [SttDisplayStatus.live]. 20s tolerates normal inter-sentence pauses without
/// flickering to [SttDisplayStatus.waitingForSpeech].
const Duration sttLiveActivityWindow = Duration(seconds: 20);

/// The `live` signal is deliberately fed by RECOGNIZED SEGMENTS only, not by
/// successful STT HTTP responses: a healthy HTTP wrapper around a broken
/// recognizer (wrong sample rate, dead ASR engine behind a 200) would keep
/// "success" fresh forever while the transcript stays empty — exactly the
/// false "it's working" this status exists to prevent.
SttDisplayStatus computeSttDisplayStatus({
  required bool isPaused,
  required bool hasTerminalFailure,
  required Duration? bufferingFor,
  required bool transportHealthy,
  required DateTime? lastSegmentAt,
  required DateTime now,
  Duration liveWindow = sttLiveActivityWindow,
}) {
  if (isPaused) return SttDisplayStatus.paused;
  if (hasTerminalFailure) return SttDisplayStatus.failed;
  if (bufferingFor != null) return SttDisplayStatus.offlineBuffering;
  if (!transportHealthy) return SttDisplayStatus.disconnected;
  if (lastSegmentAt != null && now.difference(lastSegmentAt) <= liveWindow) {
    return SttDisplayStatus.live;
  }
  return SttDisplayStatus.waitingForSpeech;
}
