import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:omi/utils/platform/platform_manager.dart';
import 'package:flutter/material.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
// hide PermissionStatus: flutter_contacts has its own PermissionStatus enum, and this
// file never spells out permission_handler's version by name (only inferred via `var`).
import 'package:permission_handler/permission_handler.dart' hide PermissionStatus;
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'package:omi/backend/http/api/phone_calls.dart' as api;
import 'package:omi/backend/http/shared.dart';
import 'package:omi/backend/preferences.dart';
import 'package:omi/backend/schema/phone_call.dart';
import 'package:omi/backend/schema/transcript_segment.dart';
import 'package:omi/models/audio_route.dart';
import 'package:omi/services/auth/auth_token_result.dart';
import 'package:omi/services/capture/ambient_capture_hold.dart';
import 'package:omi/services/phone_call_service.dart';
import 'package:omi/services/voximplant_call_service.dart';
import 'package:omi/services/vox_transcript_poller.dart';
import 'package:omi/utils/logger.dart';

/// State of the transcription link for the CURRENT call.
///
/// [cloud] is not a degraded [active]: on a Voximplant call the audio is streamed to our
/// backend by the cloud scenario, so this app has no socket to watch at all. Reporting
/// [active] there would claim knowledge the app does not have.
enum TranscriptionStatus { idle, connecting, active, reconnecting, failed, cloud }

class PhoneCallProvider extends ChangeNotifier {
  final PhoneCallService _nativeService = PhoneCallService();
  final VoximplantCallService _voxService = VoximplantCallService();

  /// A call must hush the phone's own always-on recording while it runs; the app wires
  /// [AmbientCaptureHold.gate] to the capture stack. Calls stay unaware of capture.
  final AmbientCaptureHold ambientCapture = AmbientCaptureHold();

  /// Every transition of the call state goes through here. Writing the field directly is
  /// what makes a missed resume possible, so the field has no other writer.
  void _setCallState(PhoneCallState state) {
    if (_callState == state) return;
    _callState = state;
    ambientCapture.onCallState(state);
  }

  /// True while the current call runs through Voximplant, where the cloud — not this app —
  /// captures both legs and feeds them to our backend.
  bool _cloudAudio = false;
  bool get cloudAudio => _cloudAudio;

  // Call state
  PhoneCallState _callState = PhoneCallState.idle;
  PhoneCallState get callState => _callState;

  String? _currentCallId;
  String? get currentCallId => _currentCallId;

  String? _remoteNumber;
  String? get remoteNumber => _remoteNumber;

  String? _contactName;
  String? get contactName => _contactName;

  bool _isMuted = false;
  bool get isMuted => _isMuted;

  bool _isSpeakerOn = false;
  bool get isSpeakerOn => _isSpeakerOn;

  // Call duration
  DateTime? _callStartTime;
  Timer? _durationTimer;
  Duration _callDuration = Duration.zero;
  Duration get callDuration => _callDuration;

  // Real-time transcript segments
  final List<TranscriptSegment> _transcriptSegments = [];
  List<TranscriptSegment> get transcriptSegments => List.unmodifiable(_transcriptSegments);

  // Audio routes
  List<AudioRoute> _availableRoutes = [];
  List<AudioRoute> get availableRoutes => List.unmodifiable(_availableRoutes);
  AudioRoute? _selectedRoute;
  AudioRoute? get selectedRoute => _selectedRoute;

  // Transcription status
  // Живой транскрипт облачного пути читается опросом адаптера, а не сокетом: свой сокет
  // под тем же call_id завёл бы ВТОРОЙ разговор (см. VoxTranscriptPoller).
  VoxTranscriptPoller? _transcriptPoller;
  TranscriptionStatus _transcriptionStatus = TranscriptionStatus.idle;
  TranscriptionStatus get transcriptionStatus => _transcriptionStatus;

  // Token refresh
  Timer? _tokenRefreshTimer;

  // WebSocket for transcription
  WebSocketChannel? _transcriptionSocket;
  int _wsReconnectAttempts = 0;
  Timer? _wsReconnectTimer;
  static const int _maxWsReconnectAttempts = 10;

  // Audio buffer during WS reconnect (~2s at 20ms per frame)
  final List<Uint8List> _audioBuffer = [];
  static const int _maxAudioBufferSize = 100;

  // Verified phone numbers
  List<VerifiedPhoneNumber> _verifiedNumbers = [];
  List<VerifiedPhoneNumber> get verifiedNumbers => _verifiedNumbers;

  // Loading states
  bool _isLoading = false;
  bool get isLoading => _isLoading;

  bool _numbersLoaded = false;
  bool get numbersLoaded => _numbersLoaded;

  String? _error;
  String? get error => _error;

  PhoneCallError? _lastError;
  PhoneCallError? get lastError => _lastError;

  Future<void>? _initialLoad;
  Future<void> get initialLoad => _initialLoad ?? Future.value();
  int _sessionGeneration = 0;
  bool _sessionEnabled = true;

  /// Bumped by every dial, so the teardown of one call cannot write into the next.
  ///
  /// A call reports its end more than once — we hang up locally and the SDK confirms a
  /// signalling round-trip later — and the teardown ends in a DELAYED write of the
  /// screen's state. Two teardowns meant two of those writes, scheduled a round trip
  /// apart: the first gives the screen back, and the second lands two seconds after that,
  /// on whatever is on screen by then. See [_onCallEnded].
  int _callGeneration = 0;

  /// The generation whose teardown has already run. Not a bool: a bool would have to be
  /// cleared somewhere, and the path that forgets to clear it is the path that loses the
  /// teardown of a real call.
  int? _endedGeneration;

  PhoneCallProvider() {
    _nativeService.onCallStateChanged = _onCallStateChanged;
    _nativeService.onAudioData = _onAudioData;
    _nativeService.onError = _onNativeError;
    _nativeService.onMuteConfirmed = _onMuteConfirmed;
    _nativeService.onSpeakerConfirmed = _onSpeakerConfirmed;
    _nativeService.startListening();
    _voxService.onCallStateChanged = _onCallStateChanged;
    _voxService.onError = _onNativeError;
    _voxService.onMuteConfirmed = _onMuteConfirmed;
    _voxService.onSpeakerConfirmed = _onSpeakerConfirmed;
    _initialLoad = loadVerifiedNumbers();
  }

  // ************************************************
  // *********** PHONE NUMBER MANAGEMENT ************
  // ************************************************

  Future<void> loadVerifiedNumbers() async {
    _sessionEnabled = true;
    final generation = _sessionGeneration;
    try {
      final numbers = await api.getVerifiedPhoneNumbers();
      if (generation != _sessionGeneration) return;
      _verifiedNumbers = numbers;
    } catch (e) {
      if (generation != _sessionGeneration) return;
      print('PhoneCallProvider: failed to load verified numbers: $e');
      _verifiedNumbers = [];
    } finally {
      if (generation == _sessionGeneration) {
        _numbersLoaded = true;
        notifyListeners();
      }
    }
  }

  String? _validationCode;
  String? get validationCode => _validationCode;

  String? _verificationStatus;
  String? get verificationStatus => _verificationStatus;

  Future<bool> startVerification(String phoneNumber) async {
    final generation = _sessionGeneration;
    _isLoading = true;
    _error = null;
    _validationCode = null;
    _verificationStatus = null;
    notifyListeners();

    PlatformManager.instance.analytics.phoneCallVerificationStarted();

    var result = await api.verifyPhoneNumber(phoneNumber);
    if (generation != _sessionGeneration) return false;
    _isLoading = false;

    if (result == null) {
      _error = 'Failed to start verification';
      notifyListeners();
      return false;
    }

    if (result.containsKey('error')) {
      _error = result['error'] as String?;
      notifyListeners();
      return false;
    }

    _validationCode = result['validation_code'] as String?;
    _verificationStatus = result['status'] as String?;
    notifyListeners();
    return true;
  }

  Future<bool> checkVerification(String phoneNumber) async {
    final generation = _sessionGeneration;
    var result = await api.checkPhoneVerification(phoneNumber);
    if (generation != _sessionGeneration) return false;
    if (result == null) return false;

    bool verified = result['verified'] == true;
    if (verified) {
      PlatformManager.instance.analytics.phoneCallVerificationCompleted();
      await loadVerifiedNumbers();
    }
    return verified;
  }

  Future<bool> deleteNumber(String phoneNumberId) async {
    final generation = _sessionGeneration;
    var success = await api.deleteVerifiedPhoneNumber(phoneNumberId);
    if (generation != _sessionGeneration) return false;
    if (success) {
      _verifiedNumbers.removeWhere((n) => n.id == phoneNumberId);
      notifyListeners();
    }
    return success;
  }

  // ************************************************
  // ************** CALL MANAGEMENT *****************
  // ************************************************

  Future<bool> startCall(String phoneNumber) async {
    _sessionEnabled = true;
    final generation = _sessionGeneration;
    if (_callState != PhoneCallState.idle) {
      _error = 'A call is already in progress';
      notifyListeners();
      return false;
    }

    _error = null;
    _lastError = null;
    _callGeneration++;
    _setCallState(PhoneCallState.connecting);
    _remoteNumber = phoneNumber;
    final callId = DateTime.now().millisecondsSinceEpoch.toString();
    _currentCallId = callId;
    _transcriptSegments.clear();
    _isMuted = false;
    _isSpeakerOn = false;
    notifyListeners();

    // Request mic permission first, before any SDK initialization
    var micStatus = await Permission.microphone.request();
    if (generation != _sessionGeneration) return false;
    if (!micStatus.isGranted) {
      _setCallState(PhoneCallState.idle);
      _error = 'Microphone permission is required to make calls';
      notifyListeners();
      return false;
    }

    // Resolve contact name from device contacts
    _contactName = await _resolveContactName(phoneNumber);
    if (generation != _sessionGeneration) return false;

    // Ask the backend for call credentials. Which provider answers is the deployment's
    // choice, not a build-time constant: Twilio hands back an access token, Voximplant
    // hands back the node to connect to and expects a one-time key in return.
    var tokenResult = await api.getPhoneCallToken();
    if (generation != _sessionGeneration) return false;
    var token = tokenResult.token;
    var handshake = tokenResult.voximplant;
    if (token == null && handshake == null) {
      _setCallState(PhoneCallState.idle);
      // The backend refuses for several different reasons (no verified number, quota
      // exhausted, plan without calling). Reporting its own reason beats guessing one.
      _error = tokenResult.error ?? 'Failed to get call token. Please try again.';
      notifyListeners();
      return false;
    }

    _cloudAudio = handshake != null;

    if (handshake != null) {
      var loginError = await _voxService.login(
        handshake,
        (key) async => (await api.getPhoneCallToken(oneTimeKey: key)).voximplant,
      );
      if (generation != _sessionGeneration) return false;
      if (loginError != null) {
        _setCallState(PhoneCallState.idle);
        _error = loginError;
        notifyListeners();
        return false;
      }
    } else {
      // Initialize native Twilio SDK
      final twilioToken = token!;
      var initialized = await _nativeService.initialize(twilioToken.accessToken);
      if (generation != _sessionGeneration) return false;
      if (!initialized) {
        _setCallState(PhoneCallState.idle);
        _error = 'Failed to initialize call service';
        notifyListeners();
        return false;
      }

      // Schedule token refresh before expiry (3-minute buffer)

      _scheduleTokenRefresh(twilioToken.ttl);
    }

    // The phone's own recording must be off the microphone BEFORE the SDK reaches for
    // it — not merely on its way off. Everything above this line is setup that does not
    // touch the mic, so the wait costs nothing on the normal path.
    await ambientCapture.settled();

    // Make the call through whichever SDK just logged in
    var callStarted = _cloudAudio
        ? await _voxService.makeCall(
            phoneNumber: phoneNumber,
            callId: callId,
            uid: SharedPreferencesUtil().uid,
          )
        : await _nativeService.makeCall(
            phoneNumber: phoneNumber,
            callId: callId,
            contactName: _contactName,
          );
    if (generation != _sessionGeneration) {
      if (callStarted) unawaited(_endCallOnTransport());
      return false;
    }

    if (!callStarted) {
      _setCallState(PhoneCallState.idle);
      _error = 'Failed to start call';
      PlatformManager.instance.analytics.phoneCallFailed(error: 'Failed to start call');
      _disconnectTranscriptionSocket();
      notifyListeners();
      return false;
    }

    PlatformManager.instance.analytics.phoneCallStarted(contactName: _contactName);
    return true;
  }

  /// Hangs up on whichever SDK is carrying the current call.
  Future<void> _endCallOnTransport() => _cloudAudio ? _voxService.endCall() : _nativeService.endCall();

  Future<void> endCall() async {
    await _endCallOnTransport();
    _onCallEnded();
  }

  void toggleMute() {
    // Don't update state here — wait for confirmation via _onMuteConfirmed
    if (_cloudAudio) {
      _voxService.toggleMute(!_isMuted);
    } else {
      _nativeService.toggleMute(!_isMuted);
    }
  }

  void toggleSpeaker() {
    // Don't update state here — wait for confirmation via _onSpeakerConfirmed
    if (_cloudAudio) {
      _voxService.toggleSpeaker(!_isSpeakerOn);
    } else {
      _nativeService.toggleSpeaker(!_isSpeakerOn);
    }
  }

  Future<void> loadAudioRoutes() async {
    final generation = _sessionGeneration;
    final routes = _cloudAudio ? await _voxService.getAudioRoutes() : await _nativeService.getAudioRoutes();
    if (generation != _sessionGeneration) return;
    _availableRoutes = routes;
    notifyListeners();
  }

  Future<void> selectAudioRoute(AudioRoute route) async {
    final generation = _sessionGeneration;
    var success =
        _cloudAudio ? await _voxService.selectAudioRoute(route.id) : await _nativeService.selectAudioRoute(route.id);
    if (generation != _sessionGeneration) return;
    if (success) {
      _selectedRoute = route;
      _isSpeakerOn = route.type == AudioRouteType.speaker;
      notifyListeners();
    }
  }

  void sendDtmf(String digit) {
    if (_callState != PhoneCallState.active) return;
    if (_cloudAudio) {
      _voxService.sendDtmf(digit);
    } else {
      _nativeService.sendDtmf(digit);
    }
  }

  // ************************************************
  // ************* SPEAKER LABELS *******************
  // ************************************************

  String getSpeakerLabel(TranscriptSegment segment) {
    if (segment.isUser) return 'You';
    return _contactName ?? _remoteNumber ?? 'Unknown';
  }

  // ************************************************
  // *********** PRIVATE HELPERS ********************
  // ************************************************

  /// The single door both call SDKs report state through. Not private only so a test can
  /// drive the state machine without an SDK — the same seam, and for the same reason, as
  /// [VoximplantCallService.emitState].
  @visibleForTesting
  void reportCallState(PhoneCallState state) => _onCallStateChanged(state);

  void _onCallStateChanged(PhoneCallState state) {
    if (!_sessionEnabled) return;
    _setCallState(state);
    if (state == PhoneCallState.active && _callStartTime == null) {
      _callStartTime = DateTime.now();
      _startDurationTimer();
      if (_cloudAudio) {
        // The cloud scenario already streams both legs into `v4/listen` under this call_id.
        // A socket from the app would not fail loudly — it would quietly create a SECOND
        // conversation for the same call (lane 6 tick 22, vox-dual-session-probe.py).
        _transcriptionStatus = TranscriptionStatus.cloud;
        // The text of that conversation still belongs on this screen, so read it back
        // from the adapter instead of opening a socket of our own.
        _startCloudTranscriptPolling();
      } else {
        _connectTranscriptionSocket();
      }
      PlatformManager.instance.analytics.phoneCallConnected();
    } else if (state == PhoneCallState.ended || state == PhoneCallState.failed) {
      _onCallEnded();
    }
    notifyListeners();
  }

  void _onAudioData(Uint8List audioData, int channel) {
    if (!_sessionEnabled) return;
    var socket = _transcriptionSocket;

    // Buffer audio during WebSocket reconnect
    if (socket == null) {
      if (_audioBuffer.length < _maxAudioBufferSize) {
        var data = Uint8List(1 + audioData.length);
        data[0] = channel;
        data.setRange(1, data.length, audioData);
        _audioBuffer.add(data);
      }
      return;
    }

    try {
      // Flush buffered audio first
      if (_audioBuffer.isNotEmpty) {
        for (var buffered in _audioBuffer) {
          socket.sink.add(buffered);
        }
        _audioBuffer.clear();
      }

      var data = Uint8List(1 + audioData.length);
      data[0] = channel; // 0x01 = user, 0x02 = remote
      data.setRange(1, data.length, audioData);
      socket.sink.add(data);
    } catch (e) {
      Logger.error('PhoneCallProvider: failed to send audio data: $e');
    }
  }

  void _onCallEnded() {
    // Once per call, whoever reports the end first. Both reporters are legitimate — the
    // user's hang-up runs this directly, and the SDK's confirmation arrives through
    // [_onCallStateChanged] — and neither can be dropped, because either can be the only
    // one (a call that drops on its own is never reported by us). So the guard is on the
    // call, not on the caller. Without it the second reporter also charges the analytics
    // a second 'Phone Call Ended' and, worse, schedules a second delayed reset.
    if (_endedGeneration == _callGeneration) return;
    _endedGeneration = _callGeneration;
    final generation = _callGeneration;
    PlatformManager.instance.analytics.phoneCallEnded(durationSeconds: _callDuration.inSeconds);
    _setCallState(PhoneCallState.ended);
    _stopDurationTimer();
    // Take the poller out before the teardown stops it. The closing words of the call
    // arrive about a second AFTER the hang-up — the adapter feeds the backend a second
    // of silence at that point so the STT shim cuts the last, unfinished phrase while
    // the socket is still open (lane 6 tick 38, measured on the live path). Draining
    // reads until the adapter reports the call finished; the adapter keeps a finished
    // call's text for exactly that.
    final poller = _transcriptPoller;
    _transcriptPoller = null;
    _disconnectTranscriptionSocket();
    if (poller != null) unawaited(poller.drain());
    _tokenRefreshTimer?.cancel();
    _tokenRefreshTimer = null;
    _transcriptionStatus = TranscriptionStatus.idle;
    _audioBuffer.clear();
    notifyListeners();

    // Reset state after a short delay so UI can show "Call Ended".
    //
    // The transcript is deliberately NOT cleared here. Draining outlives this delay:
    // the closing words land ~1.3s after the hang-up and the adapter only confirms the
    // text is complete when it closes the upstream socket, a few seconds later. Wiping
    // the list on a two-second timer threw exactly that tail away — the part of the
    // call that took the longest to get onto the screen. Nothing leaks: a new call
    // clears the list before it dials, and so does `clearUserData`.
    Future.delayed(const Duration(seconds: 2), () {
      // Belongs to the call that scheduled it. `clearUserData` can also give the screen
      // back before this lands, and a dial right after that would meet this write
      // otherwise — a reset landing mid-call takes the state to `idle`, and `idle` is
      // what un-pauses the phone's own always-on recording on top of a live call.
      if (generation != _callGeneration) return;
      _setCallState(PhoneCallState.idle);
      _currentCallId = null;
      _remoteNumber = null;
      _contactName = null;
      _callStartTime = null;
      _callDuration = Duration.zero;
      _cloudAudio = false;
      _availableRoutes = [];
      _selectedRoute = null;
      notifyListeners();
    });
  }

  void _onNativeError(PhoneCallError error) {
    _lastError = error;
    _error = error.message;
    Logger.error('PhoneCallProvider: native error: ${error.code} - ${error.message}');
    notifyListeners();
  }

  void _onMuteConfirmed(bool muted) {
    _isMuted = muted;
    notifyListeners();
  }

  void _onSpeakerConfirmed(bool speakerOn) {
    _isSpeakerOn = speakerOn;
    notifyListeners();
  }

  void _scheduleTokenRefresh(int ttlSeconds) {
    _tokenRefreshTimer?.cancel();
    final generation = _sessionGeneration;
    // Refresh 3 minutes before expiry (or half TTL if TTL < 6 min)
    var refreshInSeconds = ttlSeconds > 360 ? ttlSeconds - 180 : ttlSeconds ~/ 2;
    if (refreshInSeconds <= 0) return;

    Logger.info('PhoneCallProvider: scheduling token refresh in ${refreshInSeconds}s');
    _tokenRefreshTimer = Timer(Duration(seconds: refreshInSeconds), () async {
      if (generation != _sessionGeneration || !_sessionEnabled) return;
      if (_callState != PhoneCallState.active && _callState != PhoneCallState.ringing) return;
      Logger.info('PhoneCallProvider: refreshing call token');
      var token = (await api.getPhoneCallToken()).token;
      if (generation != _sessionGeneration || !_sessionEnabled) return;
      if (token != null) {
        await _nativeService.initialize(token.accessToken);
        if (generation != _sessionGeneration || !_sessionEnabled) return;
        _scheduleTokenRefresh(token.ttl);
      } else {
        Logger.error('PhoneCallProvider: token refresh failed, retrying in 30s');
        _scheduleTokenRefresh(60);
      }
    });
  }

  void _startDurationTimer() {
    _durationTimer?.cancel();
    _durationTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_callStartTime != null) {
        _callDuration = DateTime.now().difference(_callStartTime!);
        notifyListeners();
      }
    });
  }

  void _stopDurationTimer() {
    _durationTimer?.cancel();
    _durationTimer = null;
  }

  // ************************************************
  // *********** TRANSCRIPTION SOCKET ***************
  // ************************************************

  Future<void> _connectTranscriptionSocket() async {
    if (_currentCallId == null || !_sessionEnabled) return;
    final generation = _sessionGeneration;

    _wsReconnectTimer?.cancel();
    _wsReconnectTimer = null;
    _transcriptionStatus = TranscriptionStatus.connecting;
    notifyListeners();

    var language =
        SharedPreferencesUtil().hasSetPrimaryLanguage ? SharedPreferencesUtil().userPrimaryLanguage : 'multi';

    var wsUrl = api.buildPhoneCallWebSocketUrl(
      callId: _currentCallId!,
      uid: SharedPreferencesUtil().uid,
      language: language,
    );
    Logger.info('PhoneCallProvider: connecting to $wsUrl');

    try {
      var headers = await buildHeaders(requireAuthCheck: true, url: wsUrl, forWebSocket: true);
      if (generation != _sessionGeneration || !_sessionEnabled) return;
      _transcriptionSocket = IOWebSocketChannel.connect(
        wsUrl,
        headers: headers,
        pingInterval: const Duration(seconds: 20),
      );
      _transcriptionSocket!.stream.listen(
        (message) {
          if (generation != _sessionGeneration || !_sessionEnabled) return;
          if (_transcriptionStatus != TranscriptionStatus.active) {
            _transcriptionStatus = TranscriptionStatus.active;
            notifyListeners();
          }
          if (message is String) {
            _handleTranscriptionMessage(message);
          }
        },
        onError: (error) {
          if (generation != _sessionGeneration || !_sessionEnabled) return;
          Logger.error('PhoneCallProvider: WebSocket error: $error');
          _transcriptionSocket = null;
          _scheduleReconnect();
        },
        onDone: () {
          if (generation != _sessionGeneration || !_sessionEnabled) return;
          Logger.info('PhoneCallProvider: WebSocket closed');
          _transcriptionSocket = null;
          _scheduleReconnect();
        },
      );
      _wsReconnectAttempts = 0;
    } on AuthTokenUnavailableException catch (e) {
      Logger.debug('PhoneCallProvider: authenticated WebSocket blocked before connect: ${e.result.runtimeType}');
      _transcriptionSocket = null;
      if (e.result is AuthTokenTransientFailure) {
        _scheduleReconnect();
      } else {
        _transcriptionStatus = TranscriptionStatus.failed;
        notifyListeners();
      }
    } catch (e) {
      Logger.error('PhoneCallProvider: failed to connect WebSocket: $e');
      _transcriptionSocket = null;
      _scheduleReconnect();
    }
  }

  void _scheduleReconnect() {
    if (_callState != PhoneCallState.active || !_sessionEnabled) return;
    if (_wsReconnectAttempts >= _maxWsReconnectAttempts) {
      Logger.error('PhoneCallProvider: max reconnect attempts reached, giving up');
      _transcriptionStatus = TranscriptionStatus.failed;
      notifyListeners();
      return;
    }

    _transcriptionStatus = TranscriptionStatus.reconnecting;
    notifyListeners();

    var delay = Duration(seconds: 1 << _wsReconnectAttempts); // 1s, 2s, 4s, 8s...
    _wsReconnectAttempts++;
    Logger.info('PhoneCallProvider: reconnecting WebSocket in ${delay.inSeconds}s (attempt $_wsReconnectAttempts)');

    _wsReconnectTimer = Timer(delay, () {
      if (_callState == PhoneCallState.active) {
        _connectTranscriptionSocket();
      }
    });
  }

  void _disconnectTranscriptionSocket() {
    _wsReconnectTimer?.cancel();
    _wsReconnectTimer = null;
    _wsReconnectAttempts = 0;
    _transcriptionSocket?.sink.close();
    _transcriptionSocket = null;
    unawaited(_transcriptPoller?.stop() ?? Future.value());
    _transcriptPoller = null;
  }

  /// Both paths land here: the Twilio socket pushes segments, the Voximplant poller pulls
  /// them. Merging by `id` rather than appending is not a nicety — the backend re-sends a
  /// segment it has merged with its neighbour, under the same id and with longer text.
  void _mergeSegments(List<TranscriptSegment> segments) {
    if (segments.isEmpty) return;
    for (final segment in segments) {
      final existingIndex = _transcriptSegments.indexWhere((s) => s.id == segment.id);
      if (existingIndex >= 0) {
        _transcriptSegments[existingIndex] = segment;
      } else {
        _transcriptSegments.add(segment);
      }
    }
    notifyListeners();
  }

  /// The backend re-cut the conversation and these segments are gone. Without this the
  /// screen would keep showing a phrase that no longer exists in the recording.
  void _removeSegments(List<String> ids) {
    final before = _transcriptSegments.length;
    _transcriptSegments.removeWhere((s) => ids.contains(s.id));
    if (_transcriptSegments.length != before) notifyListeners();
  }

  void _startCloudTranscriptPolling() {
    final callId = _currentCallId;
    if (callId == null) return;
    final generation = _sessionGeneration;
    final poller = VoxTranscriptPoller()
      ..onSegments = (segments) {
        if (generation != _sessionGeneration || !_sessionEnabled) return;
        _mergeSegments(segments);
      }
      ..onDeleted = (ids) {
        if (generation != _sessionGeneration || !_sessionEnabled) return;
        _removeSegments(ids);
      }
      ..onGap = (dropped) => Logger.error(
            'PhoneCallProvider: adapter evicted $dropped segment(s) before we read them — '
            'the live transcript has a hole in the middle of this call',
          );
    _transcriptPoller = poller;
    poller.start(callId);
  }

  void _handleTranscriptionMessage(String message) {
    if (message == 'ping') return;

    try {
      var data = jsonDecode(message);

      // Standard segment array format: [{id, text, is_user, speaker, start, end, ...}, ...]
      if (data is List) {
        _mergeSegments(data.map((json) => TranscriptSegment.fromJson(json as Map<String, dynamic>)).toList());
        return;
      }

      // Handle translation events
      if (data is Map && data['type'] == 'translating') {
        var segments = data['segments'] as List<dynamic>? ?? [];
        for (var segmentJson in segments) {
          var translated = TranscriptSegment.fromJson(segmentJson as Map<String, dynamic>);
          var existingIndex = _transcriptSegments.indexWhere((s) => s.id == translated.id);
          if (existingIndex >= 0) {
            _transcriptSegments[existingIndex].translations = translated.translations;
          }
        }
        if (segments.isNotEmpty) notifyListeners();
        return;
      }
    } catch (e) {
      Logger.error('PhoneCallProvider: failed to parse transcript message: $e');
    }
  }

  // ************************************************
  // *********** CONTACT RESOLUTION *****************
  // ************************************************

  Future<String?> _resolveContactName(String phoneNumber) async {
    try {
      final status = await FlutterContacts.permissions.request(PermissionType.read);
      if (status != PermissionStatus.granted && status != PermissionStatus.limited) return null;

      var contacts = await FlutterContacts.getAll(properties: {ContactProperty.phone});
      var cleaned = _cleanPhoneNumber(phoneNumber);

      for (var contact in contacts) {
        for (var phone in contact.phones) {
          if (_cleanPhoneNumber(phone.number) == cleaned) {
            return contact.displayName;
          }
        }
      }
    } catch (e) {
      Logger.error('PhoneCallProvider: contact resolution failed: $e');
    }
    return null;
  }

  String _cleanPhoneNumber(String number) {
    return number.replaceAll(RegExp(r'[\s\-\(\)]'), '');
  }

  @override
  void dispose() {
    _stopDurationTimer();
    _disconnectTranscriptionSocket();
    _tokenRefreshTimer?.cancel();
    // The state machine never reaches `idle` when the provider is torn down mid-call,
    // so the state-derived resume above cannot fire here. Left out, the phone would
    // come back from a torn-down call deaf.
    _setCallState(PhoneCallState.idle);
    _nativeService.dispose();
    _voxService.dispose();
    super.dispose();
  }

  void clearUserData() {
    _sessionGeneration++;
    // Signing out gives the screen back too, and it does it without waiting the two
    // seconds a teardown waits — so a reset still in flight belongs to nobody from here
    // on, exactly as it does after a dial.
    _callGeneration++;
    _sessionEnabled = false;
    if (_callState != PhoneCallState.idle) unawaited(_endCallOnTransport());
    _stopDurationTimer();
    _disconnectTranscriptionSocket();
    _tokenRefreshTimer?.cancel();
    _tokenRefreshTimer = null;
    _setCallState(PhoneCallState.idle);
    _currentCallId = null;
    _remoteNumber = null;
    _contactName = null;
    _callStartTime = null;
    _callDuration = Duration.zero;
    _transcriptSegments.clear();
    _availableRoutes = [];
    _selectedRoute = null;
    _audioBuffer.clear();
    _verifiedNumbers = [];
    _numbersLoaded = false;
    _validationCode = null;
    _verificationStatus = null;
    _transcriptionStatus = TranscriptionStatus.idle;
    _isLoading = false;
    _error = null;
    _lastError = null;
    notifyListeners();
  }
}
