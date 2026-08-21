import 'dart:async';
import 'dart:typed_data';

import 'package:omi/gen/streaming_pcm_player_pigeon.g.dart';
import 'package:omi/services/voice_hub/hub_session.dart';
import 'package:omi/utils/logger.dart';

/// [VoicePlayer] backed by the native `StreamingPcmPlayer` (Kotlin AudioTrack,
/// design doc §7/§4 step 3). One instance per warm hub session, matching
/// [VoicePlayerFactory]'s "called once per `ensureWarm()`" contract in
/// `hub_session.dart`.
///
/// Session identity: [create] mints a new monotonically increasing session id
/// and passes it on every native call. [onStarted]/[onDrained] events carrying
/// a stale id (from a session this instance already [close]d, or from a
/// still-in-flight native callback that raced a fresh [create]) are dropped —
/// same fencing idiom as [PhoneMicFlutterApi]/`NativeMicRecorderService`, here
/// applied to a single shared [StreamingPcmPlayerFlutterApi] registration
/// rather than a fresh one per instance, since [VoicePlayerFactory] can be
/// invoked again (a new turn's warm session) before the FlutterApi channel
/// itself would ever need re-registering.
class NativeVoicePlayer implements VoicePlayer, StreamingPcmPlayerFlutterApi {
  static int _nextSessionId = 0;

  final StreamingPcmPlayerHostApi _hostApi;
  final int sessionId;
  final void Function() _onStarted;
  final void Function() _onDrained;

  /// The single live instance whose [sessionId] outbound native events are
  /// routed to; older instances that already [close]d are simply no longer
  /// registered here, so their stale callbacks (if any arrive after teardown)
  /// find no matching instance and are dropped by [_dispatchStarted]/[_dispatchDrained].
  static NativeVoicePlayer? _current;

  NativeVoicePlayer._(this._hostApi, this.sessionId, this._onStarted, this._onDrained);

  /// Matches [VoicePlayerFactory]: builds and starts the native player, then
  /// resolves once it is ready to receive [enqueuePcm16]. Throws whatever
  /// [PlatformException] the native `start()` throws (`track_init_failed`) —
  /// callers (`BaseHubSession._openConnection`) already catch and map this to
  /// a hub warm-attempt failure.
  static Future<NativeVoicePlayer> create(
    VoicePlayerStartSpec spec, {
    StreamingPcmPlayerHostApi? hostApi,
    bool registerFlutterApi = true,
  }) async {
    final api = hostApi ?? StreamingPcmPlayerHostApi();
    final sessionId = _nextSessionId++;
    final player = NativeVoicePlayer._(api, sessionId, spec.onStarted, spec.onDrained);
    if (registerFlutterApi) {
      StreamingPcmPlayerFlutterApi.setUp(player);
    }
    _current = player;
    await api.start(sessionId);
    return player;
  }

  @override
  void enqueuePcm16(Uint8List bytes) {
    unawaited(_hostApi.enqueuePcm16(bytes, sessionId).catchError((Object e) {
      Logger.error('[NativeVoicePlayer] enqueuePcm16 failed: $e');
    }));
  }

  @override
  void flush() {
    unawaited(_hostApi.flush(sessionId).catchError((Object e) {
      Logger.error('[NativeVoicePlayer] flush failed: $e');
    }));
  }

  @override
  void clear() {
    unawaited(_hostApi.clear(sessionId).catchError((Object e) {
      Logger.error('[NativeVoicePlayer] clear failed: $e');
    }));
  }

  @override
  void close() {
    if (identical(_current, this)) _current = null;
    unawaited(_hostApi.close(sessionId).catchError((Object e) {
      Logger.error('[NativeVoicePlayer] close failed: $e');
    }));
  }

  @override
  void onStarted(int sessionId) {
    final current = _current;
    if (current == null || current.sessionId != sessionId) return;
    current._onStarted();
  }

  @override
  void onDrained(int sessionId) {
    final current = _current;
    if (current == null || current.sessionId != sessionId) return;
    current._onDrained();
  }
}

/// [VoicePlayerFactory] for [BaseHubSession.new] (`playerFactory:` argument).
Future<VoicePlayer> nativeVoicePlayerFactory(VoicePlayerStartSpec spec) => NativeVoicePlayer.create(spec);
