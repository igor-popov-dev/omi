import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:omi/backend/http/shared.dart';
import 'package:omi/backend/schema/transcript_segment.dart';
import 'package:omi/env/env.dart';
import 'package:omi/utils/logger.dart';

/// One answer from the adapter's transcript endpoint.
class VoxTranscriptPage {
  final List<TranscriptSegment> segments;
  final List<String> deleted;
  final int cursor;

  /// Segments the adapter evicted from its buffer before we asked for them. Non-zero
  /// means the middle of this call is missing and no later poll will bring it back.
  final int dropped;

  /// `active` while the call runs, `finished` once the adapter closed the session.
  final String status;

  /// The adapter's numbering started over and these segments are everything it has.
  /// Its buffer lives in the memory of one call session: a leg that comes back after the
  /// session grace expires (a tunnel blink) — or a restart of the adapter itself — builds
  /// a fresh buffer counting from one, below any cursor we already hold.
  final bool reset;

  const VoxTranscriptPage({
    required this.segments,
    required this.deleted,
    required this.cursor,
    required this.dropped,
    required this.status,
    this.reset = false,
  });

  factory VoxTranscriptPage.fromJson(Map<String, dynamic> json) {
    final rawSegments = json['segments'];
    final rawDeleted = json['deleted'];
    return VoxTranscriptPage(
      segments: rawSegments is List
          ? rawSegments.whereType<Map<String, dynamic>>().map(TranscriptSegment.fromJson).toList(growable: false)
          : const [],
      deleted: rawDeleted is List ? rawDeleted.map((id) => id.toString()).toList(growable: false) : const [],
      cursor: json['cursor'] is int ? json['cursor'] as int : 0,
      dropped: json['dropped'] is int ? json['dropped'] as int : 0,
      status: json['status'] is String ? json['status'] as String : 'active',
      reset: json['reset'] == true,
    );
  }
}

/// Reads the live transcript of a Voximplant call from our call adapter.
///
/// Why the app polls instead of opening a socket. On the Voximplant path the audio of
/// both legs is streamed into `v4/listen` by the cloud scenario, under this call's
/// `call_id`. A second socket from the app would not fail loudly — it would quietly
/// create a SECOND conversation for the same call (lane 6 tick 22). So the text the
/// backend returns is kept by the adapter and read back over HTTP.
///
/// Why polling is enough: the backend emits transcript in ~12-second windows, so there
/// is nothing to push more often than that anyway.
class VoxTranscriptPoller {
  VoxTranscriptPoller({
    String? baseUrl,
    http.Client? client,
    Future<String> Function()? authHeader,
    this.interval = const Duration(seconds: 2),
    this.maxConsecutiveFailures = 5,
    this.maxInterval = const Duration(seconds: 30),
    this.drainInterval = const Duration(milliseconds: 500),
    this.drainWindow = const Duration(seconds: 12),
  })  : _baseUrl = (baseUrl ?? Env.voxTranscriptBaseUrl).trim(),
        _client = client ?? http.Client(),
        _authHeader = authHeader ?? getAuthHeader;

  final String _baseUrl;
  final http.Client _client;
  final Future<String> Function() _authHeader;
  final Duration interval;

  /// How many failures in a row before backing off. Not a stop condition: see [_nextDelay].
  final int maxConsecutiveFailures;

  /// The slowest the poller will ever go. It never stops on its own — a call outlives a
  /// server-side hiccup far more often than the other way round.
  final Duration maxInterval;

  /// How often [drain] asks after the hang-up. Faster than [interval] on purpose: the
  /// closing words land about a second after the call ends and the screen is waiting.
  final Duration drainInterval;

  /// The cap on [drain]. It is a safety net, not the normal exit: draining stops as soon
  /// as the adapter reports the call `finished`, which is the exact moment after which
  /// no further text can ever arrive.
  final Duration drainWindow;

  Timer? _timer;
  String? _callId;
  int _cursor = 0;
  int _failures = 0;
  bool _polling = false;
  bool _stopped = true;

  /// True when this build knows where the adapter lives. A build without the
  /// dart-define simply has no live transcript — it is not an error, and the call
  /// itself is unaffected (the cloud is recording either way).
  bool get configured => _baseUrl.isNotEmpty;

  int get cursor => _cursor;

  void Function(List<TranscriptSegment> segments)? onSegments;
  void Function(List<String> ids)? onDeleted;
  void Function(int dropped)? onGap;

  void start(String callId) {
    if (!configured) {
      Logger.debug('VoxTranscriptPoller: no adapter URL in this build, live transcript is off');
      return;
    }
    _callId = callId;
    _cursor = 0;
    _failures = 0;
    _stopped = false;
    _arm(Duration.zero);
  }

  Future<void> stop() async {
    _stopped = true;
    _timer?.cancel();
    _timer = null;
    _callId = null;
  }

  /// Keep reading for a few seconds after the call ended: that is where the closing
  /// words are.
  ///
  /// A single read used to be enough, and for the right reason at the time. Tick 37
  /// measured the live path twice and nothing at all arrived after a hang-up — the STT
  /// shim cuts a segment on 0.6s of silence, a conversation ends mid-word instead, and
  /// that last segment was only finalised when the socket closed, landing in the saved
  /// conversation where no socket could carry it back. The last 5-6 seconds of every
  /// call were invisible here.
  ///
  /// Tick 38 fixed the cause on the adapter: at hang-up it now feeds the backend a
  /// second of digital silence, so the shim cuts the last phrase while the socket is
  /// still open. Measured on the live path (30s of speech, both legs): the tail arrives
  /// 1.3s AFTER the hang-up — which a single farewell read cannot catch by construction.
  ///
  /// So this reads until the adapter says `finished`, which it does once the upstream
  /// socket is closed and the buffer can no longer change ([drainWindow] caps the wait).
  /// Errors are not worth reporting: the call is over.
  Future<void> drain() async {
    if (!configured || _callId == null) return;
    _timer?.cancel();
    _timer = null;
    _stopped = true;
    final deadline = DateTime.now().add(drainWindow);
    while (true) {
      final status = await _pollOnce();
      if (status == 'finished') break;
      if (!DateTime.now().isBefore(deadline)) {
        Logger.debug('VoxTranscriptPoller: drain gave up after ${drainWindow.inMilliseconds}ms, '
            'the adapter never reported the call finished');
        break;
      }
      await Future<void>.delayed(drainInterval);
    }
    _callId = null;
  }

  /// How long to wait before the next poll: [interval] while things work, then a widening
  /// backoff — but never a full stop.
  ///
  /// Stopping for good was the previous behaviour and it turned somebody else's minute
  /// into our whole call. The adapter verifies the app's token against Google on every
  /// poll, and Google answering 429 or 503 used to come back as HTTP 403 — five polls,
  /// ten seconds, and the live transcript was dead until hang-up, with one line in the
  /// app log and nothing at all on screen. The adapter now says 503 for "could not ask"
  /// (lane 6, tick 37), but the lesson holds for every transient failure: slow down,
  /// keep asking, and catch up when it recovers — the cursor makes that free.
  Duration get _nextDelay {
    if (_failures < maxConsecutiveFailures) return interval;
    final steps = (_failures - maxConsecutiveFailures + 1).clamp(1, 5);
    final ms = interval.inMilliseconds * (1 << steps);
    return Duration(milliseconds: ms < maxInterval.inMilliseconds ? ms : maxInterval.inMilliseconds);
  }

  /// Re-arms after each poll finishes instead of firing on a fixed period: a poll that
  /// takes longer than [interval] would otherwise stack requests on top of each other,
  /// and a public endpoint is the wrong place to do that.
  void _arm(Duration delay) {
    _timer?.cancel();
    if (_stopped) return;
    _timer = Timer(delay, () async {
      await _pollOnce();
      if (!_stopped) _arm(_nextDelay);
    });
  }

  /// Returns the call status the adapter reported (`active` / `finished`), or null when
  /// this poll produced no answer at all — a failure, a 404, or a poll already in flight.
  /// [drain] needs that distinction: `finished` is the only proof that the text is
  /// complete, and "no answer" must not be mistaken for it.
  Future<String?> _pollOnce() async {
    if (_polling || _callId == null) return null;
    _polling = true;
    final callId = _callId!;
    try {
      final url = Uri.parse('$_baseUrl/calls/${Uri.encodeComponent(callId)}/transcript')
          .replace(queryParameters: {'since': '$_cursor'});
      // Only Authorization, deliberately: `buildHeaders` also carries the Cloudflare
      // Access service token, and the adapter host is NOT behind Access (the Voximplant
      // cloud cannot send those headers). Sending it there would hand a tunnel credential
      // to a host that has no use for it.
      final response =
          await _client.get(url, headers: {'Authorization': await _authHeader()}).timeout(const Duration(seconds: 10));

      if (response.statusCode == 404) {
        // Normal early in a call: the adapter has no session until the first audio frame
        // arrives from the cloud. Not a failure, and the cursor must not move.
        _failures = 0;
        return null;
      }
      if (response.statusCode != 200) {
        _note('HTTP ${response.statusCode}');
        return null;
      }

      // `response.body` here would be WRONG: the adapter answers `application/json`
      // without a charset, and package:http then falls back to latin1 — every Russian
      // word in the transcript would arrive as mojibake, with no error anywhere.
      final page = VoxTranscriptPage.fromJson(
        jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>,
      );
      _failures = 0;
      if (page.dropped > 0) onGap?.call(page.dropped);
      if (page.segments.isNotEmpty) onSegments?.call(page.segments);
      if (page.deleted.isNotEmpty) onDeleted?.call(page.deleted);
      // Advance only on the server's own count, and only forward: an out-of-order answer
      // must not rewind the cursor and replay text the screen already shows. The single
      // exception is the adapter telling us its numbering restarted — forward-only would
      // then pin the cursor above anything the new buffer can ever issue, and the screen
      // would silently stop updating for the rest of the call (HTTP 200, no error, no
      // empty-transcript verdict: just text that never arrives again).
      if (page.reset || page.cursor > _cursor) _cursor = page.cursor;
      return page.status;
    } catch (e) {
      _note('${e.runtimeType}');
      return null;
    } finally {
      _polling = false;
    }
  }

  void _note(String reason) {
    _failures++;
    if (_failures == maxConsecutiveFailures) {
      Logger.error('VoxTranscriptPoller: $_failures polls in a row failed ($reason) — backing off '
          'to at most ${maxInterval.inMilliseconds}ms between tries, still polling');
    } else {
      Logger.debug('VoxTranscriptPoller: poll failed ($reason), attempt $_failures');
    }
  }
}
