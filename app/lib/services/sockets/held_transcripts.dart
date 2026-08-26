/// Transcripts the Omi socket has not accepted yet.
///
/// In custom-STT mode the phone holds the ONLY copy of a transcript: the audio
/// window it was decoded from is already gone from the polling buffer, and the
/// raw audio the Omi socket receives is deliberately not transcribed server
/// side. So a payload dropped because the socket happens to be between
/// connections is speech lost for good — silently, which is how a user records
/// for an hour and finds an empty conversation.
///
/// The hold lives outside the socket on purpose: a reconnect does not reuse the
/// socket object, it stops the old one and builds a new one, so anything kept
/// inside the socket dies exactly when it is needed.
class HeldTranscripts {
  HeldTranscripts({this.maxEntries = 20, this.maxAge = const Duration(minutes: 2), DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  /// The hold used by live sockets. Tests build their own instance.
  static final HeldTranscripts shared = HeldTranscripts();

  /// How many payloads to keep. Roughly ten minutes of polled transcripts at a
  /// 30s flush window — past that the loss is real and should be reported, not
  /// hidden behind unbounded memory.
  final int maxEntries;

  /// How long a payload may wait before it stops belonging to its conversation.
  /// Matched to the backend's own `conversation_timeout` (120s): a transcript
  /// delivered later would land in a conversation it was never part of.
  final Duration maxAge;

  final DateTime Function() _clock;
  final List<_HeldTranscript> _entries = [];

  int get length => _entries.length;

  /// Holds [payload]; returns how many older payloads had to be dropped for it.
  int hold(String payload) {
    _entries.add(_HeldTranscript(payload, _clock()));
    var dropped = 0;
    while (_entries.length > maxEntries) {
      _entries.removeAt(0);
      dropped += 1;
    }
    return dropped;
  }

  /// Takes every payload still young enough to belong where it came from.
  /// Expired ones are reported separately so the loss stays visible.
  ({List<String> payloads, int expired}) drain() {
    if (_entries.isEmpty) {
      return (payloads: const <String>[], expired: 0);
    }
    final now = _clock();
    final payloads = <String>[];
    var expired = 0;
    for (final entry in _entries) {
      if (now.difference(entry.heldAt) > maxAge) {
        expired += 1;
      } else {
        payloads.add(entry.payload);
      }
    }
    _entries.clear();
    return (payloads: payloads, expired: expired);
  }

  void clear() => _entries.clear();
}

class _HeldTranscript {
  const _HeldTranscript(this.payload, this.heldAt);

  final String payload;
  final DateTime heldAt;
}
