// Self-host patch, not for upstream: records the free-form voice dialogue into
// the chat feed.
//
// WHY
// ---
// The voice mode talks to Gemini Live over its own socket, so nothing said or
// heard there ever reaches chat history. To the user that reads as two separate
// assistants — the voice one remembers the last ten minutes, the chat one has
// never heard of them. This takes both sides of the spoken exchange and posts
// them to the self-host `/v1/selfhost/voice-log` route (backend/routers/
// selfhost_voice_log.py), which stores turns verbatim WITHOUT generating a reply.
//
// Per turn, not per fragment and not per session: a live conversation produces
// a transcript fragment every few hundred milliseconds, and one HTTP round trip
// per fragment would both hammer the backend and compete with the audio socket
// for the phone's uplink — the same uplink whose saturation caused the 23.08 STT
// timeouts. Fragments are therefore accumulated by the projection
// (`free_form_voice_mode_projection.dart`) and handed here once per spoken
// turn; each committed turn is posted right away (02.09, просьба Игоря: история
// должна появляться в чате после КАЖДОЙ реплики, а не по завершении режима).
// Posts are serialized so turns land in the order they were spoken; a turn
// committed while a post is in flight waits for it and rides the next request.
// `flush()` drains whatever is still queued on mode teardown.
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

/// Posts spoken turns to the self-host voice-log route as they are committed.
///
/// Fail-open by design: losing a chat record must never disturb a live
/// conversation, so every failure is logged and swallowed. Turns that fail to
/// post are dropped rather than retried forever — a growing unbounded buffer on
/// a long session is worse than a missing line in history.
class VoiceChatLog {
  /// Matches the server's per-request cap.
  static const int maxTurnsPerFlush = 50;

  final Future<bool> Function(List<VoiceChatTurn> turns) _post;
  final List<VoiceChatTurn> _pending = [];

  /// The post currently on the wire, if any. Only one runs at a time so the
  /// backend sees turns in spoken order; `flush()` awaits it.
  Future<void>? _inFlight;

  /// Fires after every successful post — the hook for reloading the chat feed
  /// so the line shows up right after it was spoken, not when the mode stops.
  void Function()? onStored;

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
    _drain();
  }

  /// Starts posting the queue unless a post is already on the wire — that one
  /// loops and picks the new turn up itself. Never blocks the voice loop.
  void _drain() {
    if (_inFlight != null || _pending.isEmpty) return;
    _inFlight = _postQueued().whenComplete(() => _inFlight = null);
  }

  Future<void> _postQueued() async {
    while (_pending.isNotEmpty) {
      final batch = List<VoiceChatTurn>.unmodifiable(_pending.take(maxTurnsPerFlush));
      _pending.removeRange(0, batch.length);
      try {
        final ok = await _post(batch);
        if (ok) {
          onStored?.call();
        } else {
          Logger.debug('[VoiceChatLog] ${batch.length} реплик не сохранены');
        }
      } catch (e) {
        Logger.debug('[VoiceChatLog] не удалось сохранить ${batch.length} реплик: $e');
      }
    }
  }

  /// Completes once everything recorded so far has been posted (or dropped).
  /// Safe to call when idle. Called on mode teardown so the tail of a
  /// conversation is not lost; turns already posted are never sent twice —
  /// they left the queue the moment their request went out.
  Future<void> flush() async {
    _drain();
    await (_inFlight ?? Future<void>.value());
  }

  void dispose() {
    _pending.clear();
    onStored = null;
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
