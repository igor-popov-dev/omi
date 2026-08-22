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
import 'package:omi/services/voice_hub/hub_controller.dart';
import 'package:omi/services/voice_hub/voice_turn_driver.dart';

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

  test('flag on, no driver set: single-tap toggle is a no-op for the hub (legacy pipeline unaffected)', () {
    SharedPreferencesUtil().pttHubEnabled = true;
    final provider = CaptureProvider();
    expect(provider.hubTurnDriver, isNull);

    // Must not throw even though hubTurnDriver is unset.
    provider.handleSingleTapButtonEvent('device-1'); // start
    provider.handleSingleTapButtonEvent('device-1'); // end
  });

  test('flag on + driver set: begin() called on first tap, end() called on second tap', () {
    SharedPreferencesUtil().pttHubEnabled = true;
    final provider = CaptureProvider();
    final driver = _CountingHubTurnDriver();
    provider.hubTurnDriver = driver;

    provider.handleSingleTapButtonEvent('device-1'); // start
    expect(driver.beginCalls, 1);
    expect(driver.endCalls, 0);

    provider.handleSingleTapButtonEvent('device-1'); // end
    expect(driver.beginCalls, 1);
    expect(driver.endCalls, 1);
  });
}
