// Self-host patch, not for upstream: records the free-form voice dialogue into
// the chat feed.
//
// WHY
// ---
// The voice mode talks to Gemini Live over its own socket, so nothing said or
// heard there ever reaches chat history. To the user that reads as two separate
// assistants — the voice one remembers the last ten minutes, the chat one has
// never heard of them. This buffers both sides of the spoken exchange and posts
// it to the self-host `/v1/selfhost/voice-log` route (backend/routers/
// selfhost_voice_log.py), which stores turns verbatim WITHOUT generating a reply.
//
// Buffered, not per-utterance: a live conversation produces a transcript
// fragment every few hundred milliseconds, and one HTTP round trip per fragment
// would both hammer the backend and compete with the audio socket for the
// phone's uplink — the same uplink whose saturation caused the 23.08 STT
// timeouts. Turns are flushed on a timer and when the mode stops.
import 'dart:async';
import 'dart:convert';

import 'package:omi/backend/http/shared.dart';
import 'package:omi/env/env.dart';
import 'package:omi/utils/logger.dart';

/// One spoken turn, as it actually happened.
class VoiceChatTurn {
  /// 'human' for what the user said, 'ai' for what the assistant spoke.
  final String sender;
  final String text;
  final DateTime spokenAt;

  const VoiceChatTurn({required this.sender, required this.text, required this.spokenAt});

  Map<String, dynamic> toJson() => {
        'sender': sender,
        'text': text,
        'spoken_at': spokenAt.toUtc().toIso8601String(),
      };
}

/// Collects spoken turns and posts them to the self-host voice-log route.
///
/// Fail-open by design: losing a chat record must never disturb a live
/// conversation, so every failure is logged and swallowed. Turns that fail to
/// post are dropped rather than retried forever — a growing unbounded buffer on
/// a long session is worse than a missing line in history.
class VoiceChatLog {
  /// How long to accumulate before posting. Long enough that a normal
  /// back-and-forth lands in one request, short enough that history is never
  /// far behind what the user just heard.
  static const Duration flushInterval = Duration(seconds: 10);

  /// Matches the server's per-request cap.
  static const int maxTurnsPerFlush = 50;

  final Future<bool> Function(List<VoiceChatTurn> turns) _post;
  final List<VoiceChatTurn> _pending = [];
  Timer? _timer;

  VoiceChatLog({Future<bool> Function(List<VoiceChatTurn> turns)? post}) : _post = post ?? _postToBackend;

  /// Records what the user said.
  void addUserTurn(String text, {DateTime? at}) => _add('human', text, at);

  /// Records what the assistant spoke — only what was actually voiced, so the
  /// chat history matches what the user heard rather than what was generated.
  void addAssistantTurn(String text, {DateTime? at}) => _add('ai', text, at);

  void _add(String sender, String text, DateTime? at) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    _pending.add(VoiceChatTurn(sender: sender, text: trimmed, spokenAt: at ?? DateTime.now()));
    if (_pending.length >= maxTurnsPerFlush) {
      unawaited(flush());
      return;
    }
    _timer ??= Timer(flushInterval, () => unawaited(flush()));
  }

  /// Posts everything buffered. Safe to call when empty. Called on a timer and
  /// on mode teardown, so the tail of a conversation is not lost.
  Future<void> flush() async {
    _timer?.cancel();
    _timer = null;
    if (_pending.isEmpty) return;
    final batch = List<VoiceChatTurn>.unmodifiable(_pending);
    _pending.clear();
    try {
      final ok = await _post(batch);
      if (!ok) Logger.debug('[VoiceChatLog] ${batch.length} реплик не сохранены');
    } catch (e) {
      Logger.debug('[VoiceChatLog] не удалось сохранить ${batch.length} реплик: $e');
    }
  }

  void dispose() {
    _timer?.cancel();
    _timer = null;
    _pending.clear();
  }

  static Future<bool> _postToBackend(List<VoiceChatTurn> turns) async {
    final response = await makeApiCall(
      url: '${Env.apiBaseUrl}v1/selfhost/voice-log',
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode({'turns': turns.map((t) => t.toJson()).toList()}),
      method: 'POST',
    );
    return response?.statusCode == 200;
  }
}
