// Playback of spoken assistant replies ("voice messages") attached to chat
// messages by the self-host `bin/send_voice_message.py`.
//
// The audio lives in the chat-files bucket, which the phone cannot reach on
// the self-host stand (fake-gcs on loopback), so the backend streams it from
// `GET /v2/chat/files/{file_id}/audio` under the normal Firebase auth. The
// file `url` (and the push `audio_url`) is that API path relative to
// `Env.apiBaseUrl`; absolute URLs are accepted too. Every download carries the
// same headers `makeApiCall` sends (Bearer token + CF-Access service token),
// and the bytes are cached under the app support directory so a bubble that
// is replayed — or a push that is tapped after the foreground autoplay —
// never fetches twice.
//
// One player for the whole app (`VoiceMessagePlayer.instance`): the chat
// bubble (`VoiceMessageWidget`) and the FCM handler
// (`notification_service_fcm.dart`) both drive it, and only one voice message
// plays at a time. Everything platform-bound (just_audio, path_provider, the
// auth header builder, the "is a Gemini voice call running" probe) is
// injectable so the widget test can run against fakes.
import 'dart:async';
import 'dart:io';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';

import 'package:omi/app_globals.dart';
import 'package:omi/backend/http/shared.dart';
import 'package:omi/backend/schema/message.dart';
import 'package:omi/env/env.dart';
import 'package:omi/providers/capture_provider.dart';
import 'package:omi/services/voice_playback/omi_voice_playback_service.dart';
import 'package:omi/utils/logger.dart';

/// What the player needs to know about one voice message.
class VoiceMessageRef {
  final String messageId;
  final String fileId;
  final String url;
  final String mimeType;
  final Duration? duration;

  const VoiceMessageRef({
    required this.messageId,
    required this.fileId,
    required this.url,
    this.mimeType = 'audio/mpeg',
    this.duration,
  });

  static VoiceMessageRef? fromFile(String messageId, MessageFile file) {
    final url = file.url;
    if (url == null || url.isEmpty || !file.isAudio) return null;
    return VoiceMessageRef(
      messageId: messageId,
      fileId: file.id,
      url: url,
      mimeType: file.mimeType,
      duration: file.duration,
    );
  }

  /// FCM data of `send_voice_message.py`: `voice_message=true`, `message_id`,
  /// `file_id`, `audio_url`, `audio_mime`, `audio_duration_sec`.
  static VoiceMessageRef? fromPushData(Map<String, dynamic> data) {
    if (data['voice_message']?.toString() != 'true') return null;
    final messageId = data['message_id']?.toString() ?? data['id']?.toString() ?? '';
    final fileId = data['file_id']?.toString() ?? '';
    final url = data['audio_url']?.toString() ?? '';
    if (messageId.isEmpty || fileId.isEmpty || url.isEmpty) return null;
    final seconds = double.tryParse(data['audio_duration_sec']?.toString() ?? '');
    return VoiceMessageRef(
      messageId: messageId,
      fileId: fileId,
      url: url,
      mimeType: data['audio_mime']?.toString().trim().isNotEmpty == true ? data['audio_mime'].toString() : 'audio/mpeg',
      duration: seconds != null && seconds > 0 ? Duration(milliseconds: (seconds * 1000).round()) : null,
    );
  }

  /// The attachment a push-built chat message needs so the bubble renders the
  /// player before `/v2/messages` is refreshed.
  MessageFile toMessageFile(DateTime createdAt) {
    return MessageFile(
      '',
      '',
      'voice-$fileId${_extensionFor(mimeType)}',
      mimeType,
      fileId,
      createdAt,
      '',
      url: url,
      durationSec: duration == null ? null : duration!.inMilliseconds / 1000,
      kind: MessageFile.voiceMessageKind,
    );
  }
}

String _extensionFor(String mimeType) {
  switch (mimeType.split(';').first.trim().toLowerCase()) {
    case 'audio/mpeg':
    case 'audio/mp3':
      return '.mp3';
    case 'audio/mp4':
    case 'audio/aac':
    case 'audio/x-m4a':
      return '.m4a';
    case 'audio/wav':
    case 'audio/x-wav':
      return '.wav';
    case 'audio/ogg':
    case 'audio/opus':
      return '.ogg';
    default:
      return '.bin';
  }
}

/// The subset of just_audio the player uses, so tests can substitute a fake.
abstract class VoiceAudioBackend {
  Future<Duration?> setFilePath(String path);
  Future<void> play();
  Future<void> pause();
  Future<void> seek(Duration position);
  Future<void> setSpeed(double speed);
  Future<void> stop();
  Stream<bool> get playingStream;
  Stream<Duration> get positionStream;
  Stream<Duration?> get durationStream;
  Stream<void> get completedStream;
  Future<void> dispose();
}

class JustAudioVoiceBackend implements VoiceAudioBackend {
  final AudioPlayer _player = AudioPlayer();

  @override
  Future<Duration?> setFilePath(String path) => _player.setFilePath(path);

  @override
  Future<void> play() => _player.play();

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> seek(Duration position) => _player.seek(position);

  @override
  Future<void> setSpeed(double speed) => _player.setSpeed(speed);

  @override
  Future<void> stop() => _player.stop();

  @override
  Stream<bool> get playingStream => _player.playingStream;

  @override
  Stream<Duration> get positionStream => _player.positionStream;

  @override
  Stream<Duration?> get durationStream => _player.durationStream;

  @override
  Stream<void> get completedStream =>
      _player.processingStateStream.where((state) => state == ProcessingState.completed);

  @override
  Future<void> dispose() => _player.dispose();
}

typedef VoiceMessageHeadersBuilder = Future<Map<String, String>> Function(String url);
typedef VoiceHubBusyCheck = bool Function();

/// Authorization + CF-Access headers exactly like `makeApiCall`, but the
/// Firebase token only for our own API host — it must never travel to some
/// other origin (e.g. a legacy absolute bucket URL).
Future<Map<String, String>> defaultVoiceMessageHeaders(String url) {
  return buildHeaders(requireAuthCheck: isOmiApiUrl(url, Env.apiBaseUrl), url: url, method: 'GET');
}

@visibleForTesting
bool isOmiApiUrl(String url, String? apiBaseUrl) {
  if (apiBaseUrl == null || apiBaseUrl.isEmpty) return false;
  final target = Uri.tryParse(url);
  final base = Uri.tryParse(apiBaseUrl);
  if (target == null || base == null || target.host.isEmpty) return false;
  return target.host.toLowerCase() == base.host.toLowerCase() && target.port == base.port;
}

/// True while a realtime Gemini voice call (voice hub) or the device-button
/// reply playback is running — a pushed voice message must not talk over it.
bool defaultVoiceHubBusy() {
  if (OmiVoicePlaybackService.instance.isSpeaking) return true;
  final context = globalNavigatorKey.currentContext;
  if (context == null) return false;
  try {
    final capture = context.read<CaptureProvider>();
    if (capture.freeFormModeActive.value) return true;
    final projection = capture.hubProjection.value;
    return projection.isListening ||
        projection.isThinking ||
        projection.isResponseWaiting ||
        projection.isResponseActive;
  } catch (_) {
    return false;
  }
}

class VoiceMessagePlayer extends ChangeNotifier {
  VoiceMessagePlayer.custom({
    http.Client? httpClient,
    VoiceMessageHeadersBuilder? headersBuilder,
    VoiceAudioBackend Function()? backendFactory,
    Future<Directory> Function()? cacheDirectory,
    VoiceHubBusyCheck? voiceHubBusy,
    String? Function()? apiBaseUrl,
    bool configureAudioSession = true,
  })  : _httpClient = httpClient ?? http.Client(),
        _headersBuilder = headersBuilder ?? defaultVoiceMessageHeaders,
        _backendFactory = backendFactory ?? JustAudioVoiceBackend.new,
        _cacheDirectory = cacheDirectory ?? _defaultCacheDirectory,
        _voiceHubBusy = voiceHubBusy ?? defaultVoiceHubBusy,
        _apiBaseUrl = apiBaseUrl ?? _defaultApiBaseUrl,
        _configureAudioSession = configureAudioSession;

  static final VoiceMessagePlayer instance = VoiceMessagePlayer.custom();

  static const List<double> speeds = [1.0, 1.5, 2.0];

  final http.Client _httpClient;
  final VoiceMessageHeadersBuilder _headersBuilder;
  final VoiceAudioBackend Function() _backendFactory;
  final Future<Directory> Function() _cacheDirectory;
  final VoiceHubBusyCheck _voiceHubBusy;
  final String? Function() _apiBaseUrl;
  final bool _configureAudioSession;

  static String? _defaultApiBaseUrl() => Env.apiBaseUrl;

  VoiceAudioBackend? _backend;
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  bool _audioSessionConfigured = false;

  VoiceMessageRef? _active;
  String? _loadingMessageId;
  bool _playing = false;
  Duration _position = Duration.zero;
  Duration? _duration;
  double _speed = speeds.first;
  String? _lastError;
  final Map<String, Future<File>> _downloads = {};

  String? get activeMessageId => _active?.messageId;
  double get speed => _speed;
  String? get lastError => _lastError;

  bool isActive(String messageId) => _active?.messageId == messageId;
  bool isPlaying(String messageId) => isActive(messageId) && _playing;
  bool isLoading(String messageId) => _loadingMessageId == messageId;

  Duration positionOf(String messageId) => isActive(messageId) ? _position : Duration.zero;

  Duration? durationOf(String messageId, {Duration? fallback}) =>
      isActive(messageId) ? (_duration ?? fallback) : fallback;

  /// Play from the start (or resume) if idle/paused, pause if playing.
  Future<void> toggle(VoiceMessageRef ref) async {
    if (isPlaying(ref.messageId)) {
      await pause();
      return;
    }
    await play(ref);
  }

  /// Starts [ref]. With [fromPush] the call is refused (returns false) while
  /// a voice call is running — the bubble still shows, the user taps it later.
  Future<bool> play(VoiceMessageRef ref, {bool fromPush = false, Duration? startAt}) async {
    if (fromPush && _voiceHubBusy()) {
      Logger.debug('VoiceMessagePlayer: voice hub busy, not auto-playing ${ref.messageId}');
      return false;
    }
    if (isActive(ref.messageId) && _loadingMessageId == null) {
      final backend = _backend;
      if (backend != null) {
        if (startAt != null) await backend.seek(startAt);
        await backend.play();
        return true;
      }
    }
    _loadingMessageId = ref.messageId;
    _lastError = null;
    notifyListeners();
    try {
      final file = await ensureCached(ref);
      if (_loadingMessageId != ref.messageId) return false; // superseded by another play()
      final backend = await _ensureBackend();
      await backend.stop();
      _active = ref;
      _position = startAt ?? Duration.zero;
      _duration = ref.duration;
      final loaded = await backend.setFilePath(file.path);
      if (loaded != null) _duration = loaded;
      await backend.setSpeed(_speed);
      if (startAt != null) await backend.seek(startAt);
      _loadingMessageId = null;
      notifyListeners();
      unawaited(backend.play());
      return true;
    } catch (e, stack) {
      Logger.debug('VoiceMessagePlayer: play failed for ${ref.messageId}: $e\n$stack');
      _lastError = e.toString();
      if (_loadingMessageId == ref.messageId) _loadingMessageId = null;
      if (isActive(ref.messageId)) _active = null;
      _playing = false;
      notifyListeners();
      return false;
    }
  }

  Future<void> pause() async {
    final backend = _backend;
    if (backend == null || _active == null) return;
    await backend.pause();
  }

  Future<void> stop() async {
    final backend = _backend;
    if (backend == null) return;
    await backend.stop();
    _active = null;
    _playing = false;
    _position = Duration.zero;
    notifyListeners();
  }

  /// Seeks inside the active message, or starts [ref] at [position].
  Future<void> seek(VoiceMessageRef ref, Duration position) async {
    if (isActive(ref.messageId) && _backend != null && _loadingMessageId == null) {
      _position = position;
      notifyListeners();
      await _backend!.seek(position);
      return;
    }
    await play(ref, startAt: position);
  }

  Future<void> cycleSpeed() async {
    final index = speeds.indexOf(_speed);
    _speed = speeds[(index + 1) % speeds.length];
    notifyListeners();
    final backend = _backend;
    if (backend != null) await backend.setSpeed(_speed);
  }

  /// Resolves a relative API path (`v2/chat/files/{id}/audio`) against the
  /// API base; absolute URLs pass through.
  String resolveUrl(String url) {
    if (url.startsWith('http://') || url.startsWith('https://')) return url;
    final base = (_apiBaseUrl() ?? '').trim();
    final normalizedBase = base.endsWith('/') ? base : '$base/';
    return '$normalizedBase${url.startsWith('/') ? url.substring(1) : url}';
  }

  /// Local copy of the audio, downloading it once with the API auth headers.
  Future<File> ensureCached(VoiceMessageRef ref) {
    return _downloads.putIfAbsent(ref.fileId, () async {
      try {
        return await _download(ref);
      } finally {
        _downloads.remove(ref.fileId);
      }
    });
  }

  Future<File> cachedFileFor(VoiceMessageRef ref) async {
    final dir = await _cacheDirectory();
    return File('${dir.path}${Platform.pathSeparator}${ref.fileId}${_extensionFor(ref.mimeType)}');
  }

  Future<File> _download(VoiceMessageRef ref) async {
    final target = await cachedFileFor(ref);
    if (await target.exists() && await target.length() > 0) return target;
    await target.parent.create(recursive: true);

    final url = resolveUrl(ref.url);
    final headers = await _headersBuilder(url);
    final request = http.Request('GET', Uri.parse(url))..headers.addAll(headers);
    final response = await _httpClient.send(request).timeout(const Duration(seconds: 60));
    if (response.statusCode != 200) {
      await response.stream.drain<void>();
      throw HttpException('voice message download failed: HTTP ${response.statusCode}', uri: request.url);
    }
    final partial = File('${target.path}.part');
    final sink = partial.openWrite();
    try {
      await response.stream.pipe(sink);
    } catch (_) {
      await sink.close();
      if (await partial.exists()) await partial.delete();
      rethrow;
    }
    if (await partial.length() == 0) {
      await partial.delete();
      throw const HttpException('voice message download returned an empty body');
    }
    return partial.rename(target.path);
  }

  Future<VoiceAudioBackend> _ensureBackend() async {
    final existing = _backend;
    if (existing != null) return existing;
    if (_configureAudioSession && !_audioSessionConfigured) {
      _audioSessionConfigured = true;
      try {
        final session = await AudioSession.instance;
        await session.configure(
          const AudioSessionConfiguration(
            avAudioSessionCategory: AVAudioSessionCategory.playback,
            avAudioSessionMode: AVAudioSessionMode.spokenAudio,
            androidAudioAttributes: AndroidAudioAttributes(
              contentType: AndroidAudioContentType.speech,
              usage: AndroidAudioUsage.media,
            ),
            androidAudioFocusGainType: AndroidAudioFocusGainType.gainTransientMayDuck,
          ),
        );
      } catch (e) {
        Logger.debug('VoiceMessagePlayer: audio_session configure failed: $e');
      }
    }
    final backend = _backendFactory();
    _backend = backend;
    _subscriptions.add(backend.playingStream.listen((playing) {
      if (_playing == playing) return;
      _playing = playing;
      notifyListeners();
    }));
    _subscriptions.add(backend.positionStream.listen((position) {
      _position = position;
      notifyListeners();
    }));
    _subscriptions.add(backend.durationStream.listen((duration) {
      if (duration == null) return;
      _duration = duration;
      notifyListeners();
    }));
    _subscriptions.add(backend.completedStream.listen((_) => _onCompleted()));
    return backend;
  }

  Future<void> _onCompleted() async {
    final backend = _backend;
    if (backend == null) return;
    _playing = false;
    _position = Duration.zero;
    notifyListeners();
    try {
      await backend.pause();
      await backend.seek(Duration.zero);
    } catch (e) {
      Logger.debug('VoiceMessagePlayer: reset after completion failed: $e');
    }
  }

  static Future<Directory> _defaultCacheDirectory() async {
    final support = await getApplicationSupportDirectory();
    return Directory('${support.path}${Platform.pathSeparator}voice_messages');
  }

  @override
  void dispose() {
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    _subscriptions.clear();
    _backend?.dispose();
    _backend = null;
    super.dispose();
  }
}

/// `m:ss` for bubble labels.
String formatVoiceMessageDuration(Duration duration) {
  final totalSeconds = duration.inSeconds < 0 ? 0 : duration.inSeconds;
  final minutes = totalSeconds ~/ 60;
  final seconds = totalSeconds % 60;
  return '$minutes:${seconds.toString().padLeft(2, '0')}';
}
