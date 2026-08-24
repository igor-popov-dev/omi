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
import 'package:omi/services/voice_hub/free_form_voice_mode_projection.dart'
    show freeFormListeningProjection, freeFormMicBusyProjection;
import 'package:omi/services/voice_hub/hub_controller.dart';
import 'package:omi/services/voice_hub/hub_ptt_capture.dart';
import 'package:omi/services/voice_hub/hub_session.dart';
import 'package:omi/services/voice_hub/voice_turn_driver.dart';
import 'package:omi/services/voice_hub/voice_turn_machine.dart'
    show VoiceSessionId, VoiceTurnUiProjection, idleVoiceTurnProjection;

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
  int teardownCalls = 0;

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

  @override
  void teardown() {
    teardownCalls++;
    super.teardown();
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

  int muted = 0;
  @override
  void muteCurrentResponse() => muted += 1;
  @override
  void teardown() {}
}

class _FakeHubCapture implements HubPttCapture {
  int disposeCalls = 0;
  @override
  void dispose() => disposeCalls += 1;
}

/// Ручные часы для теста тишины: настоящий таймер в этой группе не заводится
/// намеренно (см. `resolveIdleTimeout: () => null` в `buildMode`).
class _FakeClock implements HubClock {
  final Map<int, void Function()> _timers = {};
  int _seq = 0;

  @override
  Object setTimer(Duration duration, void Function() fire) {
    final id = ++_seq;
    _timers[id] = fire;
    return id;
  }

  @override
  void clearTimer(Object handle) => _timers.remove(handle);

  void fire() {
    final pending = List<void Function()>.from(_timers.values);
    _timers.clear();
    for (final f in pending) {
      f();
    }
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

  test('free-form mode running: a tap must NOT open a second hub socket', () {
    // Regression, measured 24.08: the two voice paths own separate
    // `HubController`s, and a second Gemini Live socket on the same key gets
    // the OLDER one closed with 1011 "Resource has been exhausted" — the tap
    // would hang up the conversation in progress. See the comment at the
    // `begin()` call site.
    SharedPreferencesUtil().pttHubEnabled = true;
    final provider = CaptureProvider();
    final driver = _CountingHubTurnDriver();
    provider.hubTurnDriver = driver;
    provider.freeFormModeActive.value = true;

    provider.handleSingleTapButtonEvent('device-1'); // start
    expect(driver.beginCalls, 0, reason: 'второй сокет поверх идущего разговора не поднимаем');

    provider.handleSingleTapButtonEvent('device-1'); // end
    expect(driver.beginCalls, 0);
  });

  group('FreeFormVoiceMode wiring (startFreeFormVoiceMode/stopFreeFormVoiceMode)', () {
    late _FakeHubSession session;
    late HubController hub;
    late _FakeHubCapture capture;
    int captureCalls = 0;
    Object? captureError;
    int idleTimeoutCalls = 0;
    void Function(Uint8List)? lastOnChunk;
    void Function(bool)? lastOnInterruption;

    /// One mic frame, as the native capture tees them. The drop recovery now
    /// asks whether the dying socket ever heard the mic at all, so a test
    /// that means "the socket died while the user was talking" has to have
    /// said something first.
    void feedMicFrame() => lastOnChunk?.call(Uint8List.fromList(const [1, 2, 3, 4]));

    FreeFormVoiceMode buildMode({
      HubClock? clock,
      Duration? Function()? idleTimeout,
      void Function()? onIdle,
      void Function(bool)? onMicInterruption,
    }) {
      hub = HubController(
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
          lastOnChunk = options.onChunk;
          lastOnInterruption = options.onInterruption;
          if (captureError != null) throw captureError!;
          capture = _FakeHubCapture();
          return capture;
        },
        mintTurnId: () => 'turn-1',
        clock: clock,
        // Off (null) by default so a stray real timer never fires against a
        // disposed provider between tests; the one test that DOES exercise
        // the silence timeout passes both a duration and hand-wound [clock].
        resolveIdleTimeout: idleTimeout ?? () => null,
        onIdleTimeout: onIdle ?? () => idleTimeoutCalls += 1,
        onMicInterruption: onMicInterruption,
      );
    }

    setUp(() {
      captureCalls = 0;
      captureError = null;
      idleTimeoutCalls = 0;
      lastOnChunk = null;
      lastOnInterruption = null;
    });

    test('startFreeFormVoiceMode: releases the PTT hub socket first', () async {
      // The mirror of the tap gate: the PTT hub stays warm for 90s after a
      // turn, so a pendant question asked half a minute ago still holds a
      // socket. Opening a second one on the same key gets one of them closed
      // with 1011 (measured 24.08) — and here the loser would be the socket
      // this call is opening, so the mode would come up and immediately die.
      final provider = CaptureProvider();
      final driver = _CountingHubTurnDriver();
      provider.hubTurnDriver = driver;
      provider.freeFormVoiceMode = buildMode();

      await provider.startFreeFormVoiceMode();

      expect(driver.teardownCalls, 1, reason: 'тёплый PTT-сокет отпущен до открытия нового');
      expect(provider.freeFormModeActive.value, isTrue);
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
      feedMicFrame();

      await provider.recoverFreeFormVoiceMode(StateError('socket closed 1011'));

      expect(provider.freeFormModeActive.value, isTrue, reason: 'режим остаётся включённым');
      expect(provider.freeFormVoiceMode!.isRunning, isTrue);
      expect(captureCalls, 2, reason: 'захват перезапущен');
      // The recovered session has no memory of the drop, so it is told to say
      // what happened — otherwise the user hears silence resume with no reason.
      expect(session.userTexts, isNotEmpty);
      expect(session.userTexts.single, contains('Связь прервалась'));
    });

    // The recovery used to go through the public stop(), which since the
    // conversation-resumption work means "the USER ended the conversation" —
    // so the reconnected model was handed a blank session and the recovery
    // line ("продолжай с того места, где мы остановились") asked it to
    // continue something it had never heard.
    test('recoverFreeFormVoiceMode: keeps the conversation, so the model really can continue it', () async {
      final provider = CaptureProvider();
      provider.freeFormVoiceMode = buildMode();
      await provider.startFreeFormVoiceMode();
      feedMicFrame();
      session.events.onResumptionHandle?.call('H1');
      expect(hub.canResumeConversation, isTrue);

      await provider.recoverFreeFormVoiceMode(StateError('socket closed 1011'));

      expect(hub.canResumeConversation, isTrue);
    });

    // Регресс 24.08 ~16:08: ре-коннект «на месте» восстанавливал сессию В ОБХОД
    // звонка-оболочки — воскресшая сессия жила без звонка, держала микрофон
    // бесконечно и отбирала аудиофокус у других приложений.
    test('recoverFreeFormVoiceMode: восстановленная сессия снова живёт в звонке', () async {
      final provider = CaptureProvider();
      provider.freeFormVoiceMode = buildMode();
      final callEvents = <String>[];
      provider.onVoiceModeCallStart = () async => callEvents.add('start');
      provider.onVoiceModeCallEnd = () async => callEvents.add('end');
      await provider.startFreeFormVoiceMode();
      // Иначе сработает гард «микрофон молчал всю сессию (звонок?) — выключаю
      // режим, а не пересобираю», и до цикла звонка дело не дойдёт.
      feedMicFrame();

      await provider.recoverFreeFormVoiceMode(StateError('socket closed 1005'));

      expect(provider.freeFormModeActive.value, isTrue);
      expect(callEvents, ['start', 'end', 'start'],
          reason: 'обрыв обязан пройти полный цикл: звонок снят и поставлен заново');
    });

    test('recoverFreeFormVoiceMode: gives up after repeated drops rather than looping', () async {
      final provider = CaptureProvider();
      provider.freeFormVoiceMode = buildMode();
      await provider.startFreeFormVoiceMode();

      // Reconnecting forever would burn per-minute billing on a session that
      // cannot hold, so the fourth drop in the window stops the mode. Each
      // rebuilt socket hears the mic before it dies — otherwise the
      // starved-mic guard would stop the mode on the first drop, which is a
      // different rule (see its own test below).
      for (var i = 0; i < 4; i++) {
        feedMicFrame();
        await provider.recoverFreeFormVoiceMode(StateError('drop $i'));
      }

      expect(provider.freeFormModeActive.value, isFalse);
      expect(provider.hubProjection.value, idleVoiceTurnProjection);
      expect(provider.freeFormVoiceMode!.isRunning, isFalse);
    });

    // A phone call is the everyday cause: the native capture treats a stalled
    // mic under a call mode as an interruption and waits the call out
    // (`PhoneMicController.kt` Rule 2), so the hub sits on a mute wire until
    // the provider hangs up on it ~2.5 minutes later. Rebuilding there buys
    // nothing — the new socket gets the same silence — and it is not
    // self-limiting: the drops arrive further apart than the retry window, so
    // they never accumulate to the give-up count, while every recovery line
    // spoken out loud counts as activity and rearms the silence auto-off that
    // would otherwise end the mode. A long call would hold the mode open
    // indefinitely, talking over itself.
    test('recoverFreeFormVoiceMode: a socket that never heard the mic stops the mode instead of looping', () async {
      final provider = CaptureProvider();
      provider.freeFormVoiceMode = buildMode();
      await provider.startFreeFormVoiceMode();
      // No feedMicFrame(): the mic was taken away before it delivered
      // anything to this socket.

      await provider.recoverFreeFormVoiceMode(StateError('socket closed 1008'));

      expect(provider.freeFormModeActive.value, isFalse);
      expect(provider.freeFormVoiceMode!.isRunning, isFalse);
      expect(provider.hubProjection.value, idleVoiceTurnProjection);
      expect(captureCalls, 1, reason: 'захват не перезапускали — пересобирать нечего');
      expect(session.userTexts, isEmpty, reason: 'нечего объявлять: разговора не было');
    });

    // The mirror: input the mode DID hear is what makes a rebuild worth
    // paying for, and the counter is per socket generation — a recovered
    // session that goes mute later must be caught by the same guard.
    test('recoverFreeFormVoiceMode: the heard-input check resets with every rebuilt socket', () async {
      final provider = CaptureProvider();
      provider.freeFormVoiceMode = buildMode();
      await provider.startFreeFormVoiceMode();
      feedMicFrame();

      await provider.recoverFreeFormVoiceMode(StateError('drop 1'));
      expect(provider.freeFormModeActive.value, isTrue);
      expect(captureCalls, 2);

      // The mic went away right after the rebuild — the second drop stops the
      // mode rather than starting the loop.
      await provider.recoverFreeFormVoiceMode(StateError('drop 2'));
      expect(provider.freeFormModeActive.value, isFalse);
      expect(captureCalls, 2);
    });

    // Ручной barge-in с иконки. Прерывание обязано ГЛУШИТЬ остаток ответа, а
    // не только чистить буфер: сервер об отмене не знает и продолжает слать
    // сгенерированное, поэтому один сброс дал бы паузу вместо тишины.
    group('interruptAssistantSpeech', () {
      test('во время речи глушит ответ, гасит уровень и возвращает слушание', () async {
        final provider = CaptureProvider();
        provider.freeFormVoiceMode = buildMode();
        await provider.startFreeFormVoiceMode();
        provider.hubProjection.value = const VoiceTurnUiProjection(
          isListening: false,
          isLocked: false,
          isFollowUp: false,
          transcript: '',
          hint: '',
          isThinking: false,
          isResponseWaiting: false,
          isResponseActive: true,
        );
        provider.voiceOutputEnvelope.push(Uint8List.fromList(List<int>.filled(2400, 40)));
        provider.voiceOutputEnvelope.noteSpeakingStart();
        provider.voiceOutputEnvelope.advance(0.1);

        final handled = provider.interruptAssistantSpeech();

        expect(handled, isTrue);
        expect(session.muted, 1);
        expect(provider.voiceOutputEnvelope.level.value, 0);
        expect(provider.hubProjection.value.isListening, isTrue);
        expect(provider.freeFormModeActive.value, isTrue, reason: 'прерывание не выключает режим');
      });

      // Нажатие на молчащую иконку означает прежнее — выключить режим, и
      // сказать об этом должен именно возврат false: иначе кнопка проглотит
      // нажатие и поминутный сокет останется висеть.
      test('вне речи не срабатывает', () async {
        final provider = CaptureProvider();
        provider.freeFormVoiceMode = buildMode();
        await provider.startFreeFormVoiceMode();
        provider.hubProjection.value = freeFormListeningProjection;

        expect(provider.interruptAssistantSpeech(), isFalse);
        expect(session.muted, 0);
      });

      test('при выключенном режиме не срабатывает', () {
        final provider = CaptureProvider();

        expect(provider.interruptAssistantSpeech(), isFalse);
      });
    });

    // The indicator's only source of truth is the hub's own events, and the
    // hub has nothing to say about a mic that was taken away — it just stops
    // receiving frames, exactly as if the user had gone quiet. So a call used
    // to leave "Слушаю…" on screen for its entire length while nothing the
    // user said could reach anybody.
    test('a mic taken away by a call says so instead of "Слушаю…"', () async {
      final provider = CaptureProvider();
      provider.freeFormVoiceMode = buildMode(onMicInterruption: (began) {
        provider.applyFreeFormMicInterruption(began);
      });
      await provider.startFreeFormVoiceMode();

      lastOnInterruption!(true);
      expect(provider.hubProjection.value, freeFormMicBusyProjection);
      expect(provider.freeFormModeActive.value, isTrue, reason: 'режим не выключаем: звонок кончится сам');

      lastOnInterruption!(false);
      expect(provider.hubProjection.value, freeFormListeningProjection);
    });

    test('a mic interruption after the mode stopped does not repaint the idle UI', () async {
      final provider = CaptureProvider();
      provider.freeFormVoiceMode = buildMode();
      await provider.startFreeFormVoiceMode();
      provider.stopFreeFormVoiceMode();

      provider.applyFreeFormMicInterruption(true);

      expect(provider.hubProjection.value, idleVoiceTurnProjection);
    });

    // The starved-mic guard above only fires on a socket that never heard the
    // mic AT ALL — so a session the user had been talking to right up to the
    // moment the call arrived looks perfectly recoverable when its socket dies
    // mid-call. It would be rebuilt and would announce "Связь прервалась" out
    // loud, over the call. Knowing the mic is gone right now settles it on the
    // FIRST drop.
    test('recoverFreeFormVoiceMode: a drop while the mic is taken stops the mode, silently', () async {
      final provider = CaptureProvider();
      provider.freeFormVoiceMode = buildMode(onMicInterruption: (began) {
        provider.applyFreeFormMicInterruption(began);
      });
      await provider.startFreeFormVoiceMode();
      feedMicFrame(); // the user was mid-sentence when the call came in
      lastOnInterruption!(true);

      await provider.recoverFreeFormVoiceMode(StateError('socket closed 1011'));

      expect(provider.freeFormModeActive.value, isFalse);
      expect(provider.freeFormVoiceMode!.isRunning, isFalse);
      expect(captureCalls, 1, reason: 'сокет не пересобирали');
      expect(session.userTexts, isEmpty, reason: 'ничего не сказано поверх звонка');
    });

    // The other end of the same call: what the user comes back TO. The mode
    // shuts down mid-call by the rule above, and until now it did so through
    // the public stop(), which since the resumption work means "the USER
    // ended the conversation" (`FreeFormVoiceMode.stop`) — so a five-minute
    // call cost the whole conversation. Switching the mode back on afterwards
    // opened a blank session and the user had to re-explain themselves,
    // while the exact same five minutes of SILENCE (the idle auto-off, which
    // has always suspended rather than stopped) would have been picked up
    // where it left off. A call is the least ambiguous "the user did not end
    // this" there is.
    test('recoverFreeFormVoiceMode: a call suspends the conversation instead of ending it', () async {
      final provider = CaptureProvider();
      provider.freeFormVoiceMode = buildMode(onMicInterruption: (began) {
        provider.applyFreeFormMicInterruption(began);
      });
      await provider.startFreeFormVoiceMode();
      feedMicFrame(); // the user was mid-sentence when the call came in
      session.events.onResumptionHandle?.call('H1');
      lastOnInterruption!(true);

      await provider.recoverFreeFormVoiceMode(StateError('socket closed 1011'));

      expect(provider.freeFormModeActive.value, isFalse, reason: 'режим всё равно выключается');
      expect(hub.canResumeConversation, isTrue, reason: 'но разговор переживает звонок');
    });

    // The same rule for the give-up path: what failed there is the socket,
    // and the handle is not tied to a socket. The user pressed nothing.
    test('recoverFreeFormVoiceMode: giving up after repeated drops also keeps the conversation', () async {
      final provider = CaptureProvider();
      provider.freeFormVoiceMode = buildMode();
      await provider.startFreeFormVoiceMode();
      session.events.onResumptionHandle?.call('H1');

      for (var i = 0; i < 4; i++) {
        feedMicFrame();
        await provider.recoverFreeFormVoiceMode(StateError('drop $i'));
      }

      expect(provider.freeFormModeActive.value, isFalse);
      expect(hub.canResumeConversation, isTrue);
    });

    // The line the whole distinction rests on: the button still means what it
    // says. Without this the change above would read as "nothing ever ends a
    // conversation", and a user who deliberately closed one would find it
    // waiting for them.
    test('stopFreeFormVoiceMode: the button still ends the conversation', () async {
      final provider = CaptureProvider();
      provider.freeFormVoiceMode = buildMode();
      await provider.startFreeFormVoiceMode();
      feedMicFrame();
      session.events.onResumptionHandle?.call('H1');
      expect(hub.canResumeConversation, isTrue);

      provider.stopFreeFormVoiceMode();

      expect(hub.canResumeConversation, isFalse, reason: 'кнопка — единственное «мы закончили»');
    });

    test('recoverFreeFormVoiceMode: a mode that will not restart stops cleanly', () async {
      final provider = CaptureProvider();
      provider.freeFormVoiceMode = buildMode();
      await provider.startFreeFormVoiceMode();
      feedMicFrame();
      captureError = StateError('mic gone');

      await provider.recoverFreeFormVoiceMode(StateError('socket closed'));

      expect(provider.freeFormModeActive.value, isFalse);
      expect(provider.hubProjection.value, idleVoiceTurnProjection);
    });

    // goAway: the provider warns ~9 minutes in with 50 seconds of notice
    // (measured 24.08, `marathon/probes/lane5-goaway.py`). Spending it beats
    // taking the drop — nothing is lost and nothing is said out loud.
    test('rebuildFreeFormVoiceModeSocket: rebuilds silently, keeping the mode and the conversation', () async {
      final provider = CaptureProvider();
      provider.freeFormVoiceMode = buildMode();
      await provider.startFreeFormVoiceMode();
      session.events.onResumptionHandle?.call('H1');

      await provider.rebuildFreeFormVoiceModeSocket();

      expect(provider.freeFormModeActive.value, isTrue);
      expect(provider.freeFormVoiceMode!.isRunning, isTrue);
      expect(captureCalls, 2, reason: 'сокет и захват пересобраны');
      expect(hub.canResumeConversation, isTrue);
      // Unlike a recovered drop, nothing is announced: the user never lost
      // anything, so there is nothing to apologise for.
      expect(session.userTexts, isEmpty);
    });

    test('rebuildFreeFormVoiceModeSocket: no-op when the mode is not running', () async {
      final provider = CaptureProvider();
      provider.freeFormVoiceMode = buildMode();

      await provider.rebuildFreeFormVoiceModeSocket();

      expect(captureCalls, 0);
      expect(provider.freeFormModeActive.value, isFalse);
    });

    test('rebuildFreeFormVoiceModeSocket: a failed rebuild falls back to the drop recovery', () async {
      final provider = CaptureProvider();
      provider.freeFormVoiceMode = buildMode();
      await provider.startFreeFormVoiceMode();
      captureError = StateError('mic gone');

      await provider.rebuildFreeFormVoiceModeSocket();

      // The recovery path owns the retry budget and the give-up decision;
      // this one must not invent a second policy. Here recovery itself
      // cannot restart either, so it stops the mode cleanly.
      expect(provider.freeFormModeActive.value, isFalse);
      expect(provider.hubProjection.value, idleVoiceTurnProjection);
    });

    test('silence auto-off: a socket that dies afterwards must NOT turn the mic back on', () async {
      // The silence timeout exists to stop paying for an abandoned session
      // (~$0.002 per minute of speech in). It cuts the mic but deliberately
      // LEAVES THE SOCKET OPEN, so coming back picks the conversation up —
      // which means the two paths that rebuild a dying socket run while
      // nobody is there. Both are gated on `freeFormModeActive`, and this
      // test is what keeps them gated: without it a later refactor could
      // reconnect an abandoned session and stream the mic until the battery
      // ran out, with the button reading "off" the whole time.
      final provider = CaptureProvider();
      final clock = _FakeClock();
      provider.freeFormVoiceMode = buildMode(
        clock: clock,
        idleTimeout: () => const Duration(minutes: 3),
        // Exactly `main.dart`'s wiring, which is what makes the gates shut.
        onIdle: provider.resetFreeFormVoiceModeUi,
      );
      await provider.startFreeFormVoiceMode();
      expect(captureCalls, 1);

      clock.fire(); // три минуты тишины

      expect(provider.freeFormModeActive.value, isFalse);
      expect(capture.disposeCalls, 1, reason: 'микрофон отпущен, а не только погашен UI');

      await provider.recoverFreeFormVoiceMode(StateError('socket dropped'));
      await provider.rebuildFreeFormVoiceModeSocket();

      expect(captureCalls, 1, reason: 'без человека микрофон не оживает — платим за поток');
      expect(provider.freeFormModeActive.value, isFalse);
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
