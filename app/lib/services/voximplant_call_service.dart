import 'dart:async';
import 'dart:convert';

import 'package:flutter_voximplant/flutter_voximplant.dart';
import 'package:omi/backend/schema/phone_call.dart';
import 'package:omi/models/audio_route.dart';
import 'package:omi/utils/logger.dart';

/// Places calls through Voximplant instead of Twilio (private fork).
///
/// The two providers differ in more than the SDK name, and the difference decides what this
/// class does NOT do:
///
/// * **Audio never touches the app.** With Twilio the app captures both legs (mic + remote)
///   and pushes PCM into `v4/listen` itself. With Voximplant both legs are forwarded by the
///   cloud scenario (`marathon/deploy/voxengine-call-scenario.js`) straight to our adapter,
///   so there is no `onAudioData` here and the caller must not open the transcription socket:
///   a second socket for the same `call_id` does not fail loudly, it silently produces a
///   SECOND conversation (proved by `marathon/tools/vox-dual-session-probe.py`, lane 6 tick 22).
/// * **Login is a handshake, not a token.** Voximplant has no short-lived access token. The
///   SDK must first be connected to the account's node, then it asks the cloud for a one-time
///   key, and only our backend can turn that key into a login hash (the application user's
///   password never leaves the server). Hence [login] takes the node from the backend's
///   keyless answer and calls back into it once more with the key.
///
/// The public surface mirrors [PhoneCallService] so `PhoneCallProvider` can hold either one.
class VoximplantCallService {
  /// Voximplant silently drops `customData` longer than this.
  static const int _customDataLimit = 200;

  Function(PhoneCallState state)? onCallStateChanged;
  Function(PhoneCallError error)? onError;
  Function(bool muted)? onMuteConfirmed;
  Function(bool speakerOn)? onSpeakerConfirmed;

  VIClient? _client;
  VICall? _call;
  bool _isMuted = false;
  bool _audioListenerAttached = false;

  /// The SDK is connected and logged in — a call may be placed.
  bool get isLoggedIn => _loggedIn;
  bool _loggedIn = false;

  /// Connects to the node named by the backend and logs in with a one-time key.
  ///
  /// `handshake` is the keyless answer of `POST v1/phone/token` (provider, user, node).
  /// `exchangeKey` posts the one-time key back to the same endpoint and returns the answer
  /// carrying the login hash.
  ///
  /// Returns null on success, or a human-readable reason to show the user.
  Future<String?> login(
    VoximplantLogin handshake,
    Future<VoximplantLogin?> Function(String key) exchangeKey,
  ) async {
    final node = parseNode(handshake.node);
    if (node == null) {
      return 'Calling is misconfigured on the server: unknown Voximplant node "${handshake.node}".';
    }

    try {
      final client = _client ??= Voximplant().getClient(VIClientConfig());
      _attachAudioDeviceListener();

      var state = await client.getClientState();
      if (state == VIClientState.LoggedIn) {
        _loggedIn = true;
        return null;
      }
      if (state == VIClientState.Disconnected) {
        await client.connect(node: node);
        state = await client.getClientState();
      }
      if (state != VIClientState.Connected) {
        return 'Could not reach the calling service (state: ${state.name}). Check the connection and try again.';
      }

      // The key dies in five minutes and is invalidated when the same account asks for
      // another one, so it is requested here — right before dialling — and never cached.
      final key = await client.requestOneTimeLoginKey(handshake.user);
      final answer = await exchangeKey(key);
      if (answer == null || answer.hash == null) {
        return 'The server did not confirm the call login. Please try again.';
      }

      await client.loginWithOneTimeKey(answer.user, answer.hash!);
      _loggedIn = true;
      return null;
    } on VIException catch (e) {
      _loggedIn = false;
      Logger.error('VoximplantCallService: login failed: ${e.code} ${e.message}');
      return _loginErrorMessage(e);
    } catch (e) {
      _loggedIn = false;
      Logger.error('VoximplantCallService: login failed: $e');
      return 'Could not sign in to the calling service. Please try again.';
    }
  }

  /// Dials `phoneNumber` and hands the cloud scenario the ids it needs.
  ///
  /// `uid` and `callId` travel in `customData`: the scenario reads them to authorize the
  /// call and to open the transcription socket on our backend under the right user
  /// (`voxengine-call-scenario.js`, `AppEvents.CallAlerting`). Without them the call still
  /// connects but is never recorded, so an over-long payload is a failure, not a warning.
  Future<bool> makeCall({
    required String phoneNumber,
    required String callId,
    required String uid,
  }) async {
    final client = _client;
    if (client == null || !_loggedIn) {
      _reportError('ERROR_CLIENT_NOT_LOGGED_IN', 'The calling service is not connected.');
      return false;
    }

    final customData = buildCustomData(uid: uid, callId: callId);
    if (customData == null) {
      _reportError('ERROR_INVALID_ARGUMENTS', 'Call ids do not fit into the call payload.');
      return false;
    }

    try {
      final settings = VICallSettings()..customData = customData;
      final call = await client.call(phoneNumber, settings: settings);
      _bindCall(call);
      _isMuted = false;
      onCallStateChanged?.call(PhoneCallState.connecting);
      return true;
    } on VIException catch (e) {
      Logger.error('VoximplantCallService: call failed: ${e.code} ${e.message}');
      _reportError(e.code, _callErrorMessage(e));
      return false;
    } catch (e) {
      Logger.error('VoximplantCallService: call failed: $e');
      _reportError('ERROR_INTERNAL', 'Could not start the call. Please try again.');
      return false;
    }
  }

  Future<void> endCall() async {
    final call = _call;
    if (call == null) return;
    try {
      await call.hangup();
    } catch (e) {
      Logger.error('VoximplantCallService: hangup error: $e');
    }
  }

  /// Mutes or unmutes the microphone. Voximplant reports no event for this, so the
  /// confirmation is the call itself returning without an error.
  Future<void> toggleMute(bool muted) async {
    final call = _call;
    if (call == null) return;
    try {
      await call.sendAudio(!muted);
      _isMuted = muted;
      onMuteConfirmed?.call(muted);
    } catch (e) {
      Logger.error('VoximplantCallService: toggleMute error: $e');
      onMuteConfirmed?.call(_isMuted);
    }
  }

  /// Switches between the speaker and the earpiece. The confirmation arrives through
  /// [VIAudioDeviceManager.onAudioDeviceChanged], which also fires when the user plugs in
  /// a headset — that is why the state is not set here.
  Future<void> toggleSpeaker(bool speakerOn) async {
    try {
      await Voximplant().audioDeviceManager.selectAudioDevice(
            speakerOn ? VIAudioDevice.Speaker : VIAudioDevice.Earpiece,
          );
    } catch (e) {
      Logger.error('VoximplantCallService: toggleSpeaker error: $e');
    }
  }

  Future<void> sendDtmf(String digits) async {
    final call = _call;
    if (call == null) return;
    try {
      for (final digit in digits.split('')) {
        await call.sendTone(digit);
      }
    } catch (e) {
      Logger.error('VoximplantCallService: sendDtmf error: $e');
    }
  }

  Future<List<AudioRoute>> getAudioRoutes() async {
    try {
      final devices = await Voximplant().audioDeviceManager.getAudioDevices();
      return devices.where((device) => device != VIAudioDevice.None).map(audioRouteOf).toList();
    } catch (e) {
      Logger.error('VoximplantCallService: getAudioRoutes error: $e');
      return [];
    }
  }

  Future<bool> selectAudioRoute(String routeId) async {
    final device = parseAudioDevice(routeId);
    if (device == null) return false;
    try {
      await Voximplant().audioDeviceManager.selectAudioDevice(device);
      return true;
    } catch (e) {
      Logger.error('VoximplantCallService: selectAudioRoute error: $e');
      return false;
    }
  }

  void dispose() {
    _call = null;
    Voximplant().audioDeviceManager.onAudioDeviceChanged = null;
    _audioListenerAttached = false;
  }

  // ************************************************
  // *********** PURE HELPERS (UNIT-TESTED) *********
  // ************************************************

  /// `Node4` (as the backend normalises it) → [VINode.Node4]; null when the name is unknown.
  static VINode? parseNode(String name) {
    final wanted = name.trim().replaceFirst('VINode.', '').toLowerCase();
    for (final node in VINode.values) {
      if (node.name.toLowerCase() == wanted) return node;
    }
    return null;
  }

  /// The `{"uid": …, "call_id": …}` the cloud scenario parses, or null if it would not fit.
  static String? buildCustomData({required String uid, required String callId}) {
    final payload = jsonEncode({'uid': uid, 'call_id': callId});
    if (utf8.encode(payload).length > _customDataLimit) return null;
    return payload;
  }

  static AudioRoute audioRouteOf(VIAudioDevice device) {
    return AudioRoute(id: device.name, name: _audioDeviceLabel(device), type: _audioRouteType(device));
  }

  static VIAudioDevice? parseAudioDevice(String routeId) {
    for (final device in VIAudioDevice.values) {
      if (device.name == routeId) return device;
    }
    return null;
  }

  static String _audioDeviceLabel(VIAudioDevice device) {
    switch (device) {
      case VIAudioDevice.Bluetooth:
        return 'Bluetooth';
      case VIAudioDevice.Earpiece:
        return 'Phone';
      case VIAudioDevice.Speaker:
        return 'Speaker';
      case VIAudioDevice.WiredHeadset:
        return 'Headphones';
      case VIAudioDevice.None:
        return 'Unknown';
    }
  }

  static AudioRouteType _audioRouteType(VIAudioDevice device) {
    switch (device) {
      case VIAudioDevice.Bluetooth:
        return AudioRouteType.bluetoothHeadset;
      case VIAudioDevice.Earpiece:
        return AudioRouteType.iPhone;
      case VIAudioDevice.Speaker:
        return AudioRouteType.speaker;
      case VIAudioDevice.WiredHeadset:
        return AudioRouteType.headphones;
      case VIAudioDevice.None:
        return AudioRouteType.unknown;
    }
  }

  // ************************************************
  // *********** PRIVATE HELPERS ********************
  // ************************************************

  void _attachAudioDeviceListener() {
    if (_audioListenerAttached) return;
    Voximplant().audioDeviceManager.onAudioDeviceChanged = (manager, device) {
      onSpeakerConfirmed?.call(device == VIAudioDevice.Speaker);
    };
    _audioListenerAttached = true;
  }

  void _bindCall(VICall call) {
    _call = call;
    call.onCallRinging = (call, headers) => onCallStateChanged?.call(PhoneCallState.ringing);
    call.onCallConnected = (call, headers) => onCallStateChanged?.call(PhoneCallState.active);
    call.onCallDisconnected = (call, headers, answeredElsewhere) {
      _call = null;
      onCallStateChanged?.call(PhoneCallState.ended);
    };
    call.onCallFailed = (call, code, description, headers) {
      _call = null;
      // 486 and 603 are the scenario refusing (quota, direction, no verified number) or the
      // other side declining — telling them apart matters more than the SIP number does.
      _reportError('SIP_$code', description.trim().isEmpty ? 'The call could not be completed.' : description);
      onCallStateChanged?.call(PhoneCallState.failed);
    };
  }

  void _reportError(String code, String message) {
    onError?.call(PhoneCallError(code: code, message: message));
  }

  String _loginErrorMessage(VIException e) {
    switch (e.code) {
      case VIClientError.ERROR_INVALID_PASSWORD:
        return 'The call login was rejected. The server key may be out of date.';
      case VIClientError.ERROR_ACCOUNT_FROZEN:
        return 'The calling account is frozen — top it up to make calls.';
      case VIClientError.ERROR_NETWORK_ISSUES:
      case VIClientError.ERROR_CONNECTION_FAILED:
      case VIClientError.ERROR_TIMEOUT:
        return 'Could not reach the calling service. Check the connection and try again.';
      default:
        return e.message ?? 'Could not sign in to the calling service.';
    }
  }

  String _callErrorMessage(VIException e) {
    switch (e.code) {
      case VICallError.ERROR_MISSING_PERMISSION:
        return 'Microphone permission is required to make calls.';
      case VICallError.ERROR_CLIENT_NOT_LOGGED_IN:
        return 'The calling service is not connected.';
      default:
        return e.message ?? 'Could not start the call.';
    }
  }
}
