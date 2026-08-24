// Covers the CaptureController <-> VoiceHubTurnDriver gating added for the
// pttHubEnabled flag (see `capture_controller.dart`'s
// `handleSingleTapButtonEvent`, extracted from the BLE single-tap toggle
// branch specifically so it's testable without a real BLE button stream).
//
// This intentionally does NOT exercise BLE/audio: `handleSingleTapButtonEvent`
// is called directly, and the hub driver is a real `VoiceHubTurnDriver`
// wrapping fakes that are never actually invoked (the driver's own
// `pttHubEnabled: () => false` means `begin()` cancels before touching the
// hub/capture), so this stays a pure, hermetic unit test.
import 'dart:io';

import 'package:connectivity_plus_platform_interface/connectivity_plus_platform_interface.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:omi/backend/preferences.dart';
import 'package:omi/env/env.dart';
import 'package:omi/providers/capture_provider.dart';
import 'package:omi/services/services.dart';
import 'package:omi/services/voice_hub/free_form_voice_mode.dart';
import 'package:omi/services/voice_hub/hub_controller.dart';
import 'package:omi/services/voice_hub/hub_ptt_capture.dart';
import 'package:omi/services/voice_hub/hub_session.dart';
import 'package:omi/services/voice_hub/voice_turn_driver.dart';
import 'package:omi/services/voice_hub/voice_turn_machine.dart' show VoiceSessionId, idleVoiceTurnProjection;

class _TestConnectivityPlatform extends ConnectivityPlatform {
  @override
  Future<List<ConnectivityResult>> checkConnectivity() async {
    return [ConnectivityResult.none];
  }

  @override
  Stream<List<ConnectivityResult>> get onConnectivityChanged => const Stream.empty();
}

class _TestEnvFields implements EnvFields {
  @override
  String? get posthogApiKey => null;
  @override
  String? get apiBaseUrl => null;
  @override
  String? get googleMapsApiKey => null;
  @override
  String? get intercomAppId => null;
  @override
  String? get intercomIOSApiKey => null;
  @override
  String? get intercomAndroidApiKey => null;
  @override
  String? get googleClientId => null;
  @override
  String? get googleClientSecret => null;
  @override
  bool? get useWebAuth => false;
  @override
  bool? get useAuthCustomToken => false;
}

/// A `VoiceHubTurnDriver` whose deps are never actually invoked (kept
/// permanently flag-off internally), used only to count `begin()`/`end()`
/// calls from `CaptureController`.
class _CountingHubTurnDriver extends VoiceHubTurnDriver {
  int beginCalls = 0;
  int endCalls = 0;

  _CountingHubTurnDriver()
      : super(VoiceHubTurnDriverDeps(
          createHub: (events) => HubController(
            events: events,
            buildInstructions: () => '',
            mintToken: () async => throw UnimplementedError('not expected to be called in this test'),
            createSession: (spec) => throw UnimplementedError('not expected to be called in this test'),
          ),
          startCapture: (options) async => throw UnimplementedError('not expected to be called in this test'),
          applyProjection: (_) {},
          // Deliberately false so `begin()` cancels immediately without
          // touching the (unimplemented) hub/capture fakes above — this test
          // only cares whether CaptureController CALLED begin()/end(), not
          // what the driver does internally (that's voice_turn_driver_test.dart's job).
          pttHubEnabled: () => false,
        ));

  @override
  void begin() {
    beginCalls++;
    super.begin();
  }

  @override
  void end() {
    endCalls++;
    super.end();
  }
}

/// A minimal fake provider session for `FreeFormVoiceMode` wiring tests —
/// connects instantly on `ensureWarm()`, same pattern as
/// `free_form_voice_mode_test.dart`'s own `_FakeSession` (not shared across
/// test files, so duplicated here at the minimum this file actually needs).
class _FakeHubSession implements HubSession {
  @override
  HubProvider get provider => HubProvider.gemini;
  @override
  int get requiredInputSampleRate => 16000;
  @override
  HubBargeInStrategy get bargeInStrategy => HubBargeInStrategy.freshSession;

  final VoiceSessionId sessionId;
  final HubSessionEvents events;
  _FakeHubSession(this.sessionId, this.events);

  int cancelled = 0;

  @override
  Future<void> ensureWarm() {
    events.onConnected?.call(sessionId);
    return Future.value();
  }

  @override
  bool isWarm() => true;
  @override
  void beginTurn([HubBeginTurnOptions opts = const HubBeginTurnOptions()]) {}
  @override
  void appendAudio(Uint8List pcm) {}
  @override
  void commitTurn() {}
  @override
  void cancelTurn() => cancelled += 1;
  @override
  void sendToolResult(String callId, String name, String output) {}

  @override
  void sendUserText(String text) => userTexts.add(text);

  final List<String> userTexts = [];
  @override
  void clearPlayback() {}
  @override
  void teardown() {}
}

class _FakeHubCapture implements HubPttCapture {
  int disposeCalls = 0;
  @override
  void dispose() => disposeCalls += 1;
}

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    await SharedPreferencesUtil.init();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (MethodCall call) async {
        if (call.method == 'getApplicationDocumentsDirectory') return Directory.systemTemp.path;
        return null;
      },
    );
    ConnectivityPlatform.instance = _TestConnectivityPlatform();
    try {
      Env.init(_TestEnvFields());
    } catch (_) {
      // Env._instance is late final — ignore if already initialized in this isolate.
    }
    try {
      await ServiceManager.init();
    } catch (_) {
      // Ignore if already initialized by another test.
    }
  });

  setUp(() {
    SharedPreferencesUtil().pttHubEnabled = false;
  });

  test('flag off: single-tap toggle never touches the hub driver', () {
    final provider = CaptureProvider();
    final driver = _CountingHubTurnDriver();
    provider.hubTurnDriver = driver;

    provider.handleSingleTapButtonEvent('device-1'); // start
    provider.handleSingleTapButtonEvent('device-1'); // end

    expect(driver.beginCalls, 0);
    expect(driver.endCalls, 0);
  });

  test('PTT hub is retired: even a stored "true" flag reads back false and never reaches the driver', () {
    // Решение Игоря 24.08: удержание кнопки кулона занято питанием кулона, а
    // push-to-talk конфликтовал с одиночным нажатием. Геттер прибит к false
    // (preferences.dart); у Игоря в prefs осталось true с живого теста —
    // прибитый геттер обязан его игнорировать.
    SharedPreferencesUtil().pttHubEnabled = true;
    expect(SharedPreferencesUtil().pttHubEnabled, isFalse);

    final provider = CaptureProvider();
    final driver = _CountingHubTurnDriver();
    provider.hubTurnDriver = driver;

    provider.handleSingleTapButtonEvent('device-1'); // start
    provider.handleSingleTapButtonEvent('device-1'); // end

    expect(driver.beginCalls, 0);
    expect(driver.endCalls, 0);
  });

  group('FreeFormVoiceMode wiring (startFreeFormVoiceMode/stopFreeFormVoiceMode)', () {
    late _FakeHubSession session;
    late _FakeHubCapture capture;
    int captureCalls = 0;
    Object? captureError;
    int idleTimeoutCalls = 0;

    FreeFormVoiceMode buildMode() {
      final hub = HubController(
        buildInstructions: () => 'INSTRUCTIONS',
        mintToken: () async => 'ek_token',
        createSession: (spec) {
          session = _FakeHubSession('sess-1', spec.events);
          return session;
        },
      );
      return FreeFormVoiceMode(
        hub: hub,
        startCapture: (options) async {
          captureCalls += 1;
          if (captureError != null) throw captureError!;
          capture = _FakeHubCapture();
          return capture;
        },
        mintTurnId: () => 'turn-1',
        // No idle-timeout test in this group exercises real time — kept
        // off (null) so a stray timer never fires against a disposed
        // provider between tests.
        idleTimeout: null,
        onIdleTimeout: () => idleTimeoutCalls += 1,
      );
    }

    setUp(() {
      captureCalls = 0;
      captureError = null;
      idleTimeoutCalls = 0;
    });

    test('startFreeFormVoiceMode: flips freeFormModeActive and starts the mode', () async {
      final provider = CaptureProvider();
      provider.freeFormVoiceMode = buildMode();

      await provider.startFreeFormVoiceMode();

      expect(provider.freeFormModeActive.value, isTrue);
      expect(provider.freeFormVoiceMode!.isRunning, isTrue);
      expect(captureCalls, 1);
    });

    test('startFreeFormVoiceMode: no-op with no mode set (must not throw)', () async {
      final provider = CaptureProvider();
      expect(provider.freeFormVoiceMode, isNull);

      await provider.startFreeFormVoiceMode();

      expect(provider.freeFormModeActive.value, isFalse);
    });

    test('startFreeFormVoiceMode: a capture failure resets UI state and rethrows', () async {
      final provider = CaptureProvider();
      provider.freeFormVoiceMode = buildMode();
      captureError = StateError('mic denied');

      await expectLater(provider.startFreeFormVoiceMode(), throwsStateError);

      expect(provider.freeFormModeActive.value, isFalse);
      expect(provider.hubProjection.value, idleVoiceTurnProjection);
    });

    test('stopFreeFormVoiceMode: stops the mode and resets UI state', () async {
      final provider = CaptureProvider();
      provider.freeFormVoiceMode = buildMode();
      await provider.startFreeFormVoiceMode();

      provider.stopFreeFormVoiceMode();

      expect(provider.freeFormModeActive.value, isFalse);
      expect(provider.hubProjection.value, idleVoiceTurnProjection);
      expect(provider.freeFormVoiceMode!.isRunning, isFalse);
      expect(capture.disposeCalls, 1);
      expect(session.cancelled, 1);
    });

    // Self-host patch, not for upstream: a dropped socket used to end the
    // conversation in silence (reported 23.08 — "спросил, повисел, выключился").
    test('recoverFreeFormVoiceMode: reconnects instead of ending the conversation', () async {
      final provider = CaptureProvider();
      provider.freeFormVoiceMode = buildMode();
      await provider.startFreeFormVoiceMode();

      await provider.recoverFreeFormVoiceMode(StateError('socket closed 1011'));

      expect(provider.freeFormModeActive.value, isTrue, reason: 'режим остаётся включённым');
      expect(provider.freeFormVoiceMode!.isRunning, isTrue);
      expect(captureCalls, 2, reason: 'захват перезапущен');
      // The recovered session has no memory of the drop, so it is told to say
      // what happened — otherwise the user hears silence resume with no reason.
      expect(session.userTexts, isNotEmpty);
      expect(session.userTexts.single, contains('Связь прервалась'));
    });

    test('recoverFreeFormVoiceMode: gives up after repeated drops rather than looping', () async {
      final provider = CaptureProvider();
      provider.freeFormVoiceMode = buildMode();
      await provider.startFreeFormVoiceMode();

      // Reconnecting forever would burn per-minute billing on a session that
      // cannot hold, so the fourth drop in the window stops the mode.
      for (var i = 0; i < 4; i++) {
        await provider.recoverFreeFormVoiceMode(StateError('drop $i'));
      }

      expect(provider.freeFormModeActive.value, isFalse);
      expect(provider.hubProjection.value, idleVoiceTurnProjection);
      expect(provider.freeFormVoiceMode!.isRunning, isFalse);
    });

    test('recoverFreeFormVoiceMode: a mode that will not restart stops cleanly', () async {
      final provider = CaptureProvider();
      provider.freeFormVoiceMode = buildMode();
      await provider.startFreeFormVoiceMode();
      captureError = StateError('mic gone');

      await provider.recoverFreeFormVoiceMode(StateError('socket closed'));

      expect(provider.freeFormModeActive.value, isFalse);
      expect(provider.hubProjection.value, idleVoiceTurnProjection);
    });

    test('resetFreeFormVoiceModeUi: resets UI state without calling stop() on the mode', () async {
      final provider = CaptureProvider();
      provider.freeFormVoiceMode = buildMode();
      await provider.startFreeFormVoiceMode();

      // Simulates the `onIdleTimeout`/`onDisconnected` callers wired in
      // `main.dart`: the mode has already torn itself down (or is about to,
      // right after this callback returns), so this must NOT re-cancel the
      // hub turn — only the UI-facing notifiers reset.
      provider.resetFreeFormVoiceModeUi();

      expect(provider.freeFormModeActive.value, isFalse);
      expect(provider.hubProjection.value, idleVoiceTurnProjection);
      expect(session.cancelled, 0);
    });

    // Telecom call shell (voice-call-mode-design.md): the session runs inside
    // a self-managed Android call. The provider only owns the ordering
    // contract — shell up BEFORE capture opens (background-mic legality),
    // shell down at the single reset point every teardown path funnels into.
    test('call shell: starts before capture opens, ends on stop', () async {
      final provider = CaptureProvider();
      provider.freeFormVoiceMode = buildMode();
      var callStarts = 0;
      var callEnds = 0;
      provider.onVoiceModeCallStart = () async {
        callStarts += 1;
        // The contract that makes lock-screen starts legal: the call must be
        // active before the mic capture is even attempted.
        expect(captureCalls, 0, reason: 'call shell must start before capture opens');
      };
      provider.onVoiceModeCallEnd = () async => callEnds += 1;

      await provider.startFreeFormVoiceMode();
      expect(callStarts, 1);
      expect(callEnds, 0);

      provider.stopFreeFormVoiceMode();
      expect(callEnds, 1);
    });

    test('call shell: stop during call setup aborts the start (no headless mode)', () async {
      final provider = CaptureProvider();
      provider.freeFormVoiceMode = buildMode();
      var callEnds = 0;
      provider.onVoiceModeCallStart = () async {
        // The user hits Stop while telecom is still building the call.
        provider.stopFreeFormVoiceMode();
      };
      provider.onVoiceModeCallEnd = () async => callEnds += 1;

      await provider.startFreeFormVoiceMode();

      expect(provider.freeFormModeActive.value, isFalse);
      expect(provider.freeFormVoiceMode!.isRunning, isFalse, reason: 'the mode must not start headless');
      expect(captureCalls, 0);
      expect(callEnds, 1);
    });

    test('call shell: a capture failure still ends the shell', () async {
      final provider = CaptureProvider();
      provider.freeFormVoiceMode = buildMode();
      captureError = StateError('mic denied');
      var callEnds = 0;
      provider.onVoiceModeCallStart = () async {};
      provider.onVoiceModeCallEnd = () async => callEnds += 1;

      await expectLater(provider.startFreeFormVoiceMode(), throwsStateError);

      expect(callEnds, 1, reason: 'a failed start must not leak a live call');
    });
  });
}
