import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:omi/backend/preferences.dart';
import 'package:omi/providers/voice_recorder_provider.dart';
import 'package:omi/services/mic/mic_arbiter.dart';
import 'package:omi/services/services.dart';

/// Mic double that reproduces [ArbitratedMic]'s contention contract: starting a
/// chat voice memo while a conversation holds the mic throws a [StateError].
class _ContendedMic implements IMicRecorderService {
  bool failStart = true;
  int startCalls = 0;
  int stopCalls = 0;
  Function()? _onStop;

  @override
  Future<void> start({
    required Function(Uint8List bytes) onByteReceived,
    Function()? onRecording,
    Function()? onStop,
    Function()? onInitializing,
    Function()? onStalled,
    Function(bool began)? onInterruption,
  }) async {
    startCalls++;
    if (failStart) {
      throw StateError('Microphone is busy (held by conversation)');
    }
    _onStop = onStop;
  }

  @override
  Future<void> startBatch({
    Function()? onStop,
    Function(bool began)? onInterruption,
    Function()? onBatchStalled,
    Function(String code, String message)? onError,
  }) async {
    throw UnsupportedError('batch capture is not used by the voice recorder');
  }

  @override
  void stop() {
    stopCalls++;
    _onStop?.call();
    _onStop = null;
  }

  @override
  void probeStallAfterForeground() {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');
  const permissionsChannel = MethodChannel('flutter.baseflow.com/permissions/methods');

  late Directory tempDir;

  Directory recordingsDir() => Directory('${tempDir.path}/voice_recordings');

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await SharedPreferencesUtil.init();
    tempDir = Directory.systemTemp.createTempSync('voice_recorder_contention_');

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(pathProviderChannel, (
      MethodCall call,
    ) async {
      if (call.method == 'getApplicationSupportDirectory') return tempDir.path;
      if (call.method == 'getTemporaryDirectory') return tempDir.path;
      return null;
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(permissionsChannel, (
      MethodCall call,
    ) async {
      if (call.method == 'checkPermissionStatus') return 1;
      if (call.method == 'requestPermissions') {
        return {for (final permission in call.arguments as List<dynamic>) permission: 1};
      }
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      pathProviderChannel,
      null,
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      permissionsChannel,
      null,
    );
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  group('VoiceRecorderProvider mic contention', () {
    test('a busy mic unwinds the half-armed session instead of escaping', () async {
      final mic = _ContendedMic();
      final provider = VoiceRecorderProvider(mic: mic);
      final observed = <VoiceRecorderState>[];
      provider.addListener(() => observed.add(provider.state));

      // Must not throw: startRecording() is called fire-and-forget from a tap
      // handler, so an escaping StateError is an unhandled async crash.
      await provider.startRecording();

      expect(mic.startCalls, 1);
      expect(provider.state, VoiceRecorderState.idle);
      expect(provider.isRecording, isFalse);
      expect(provider.isActive, isFalse);

      // The session was armed, then unwound — and listeners saw both.
      expect(observed, contains(VoiceRecorderState.recording));
      expect(observed.last, VoiceRecorderState.idle);

      // The PCM file opened before the failed start is deleted.
      expect(recordingsDir().listSync(), isEmpty);
    });

    test('the provider is not wedged — a later start records normally', () async {
      final mic = _ContendedMic();
      final provider = VoiceRecorderProvider(mic: mic);

      await provider.startRecording();
      expect(provider.state, VoiceRecorderState.idle);

      mic.failStart = false;
      await provider.startRecording();

      expect(mic.startCalls, 2);
      expect(provider.state, VoiceRecorderState.recording);
      expect(provider.isRecording, isTrue);
      expect(recordingsDir().listSync().length, 1);

      provider.close();
      expect(mic.stopCalls, 1);
      expect(provider.state, VoiceRecorderState.idle);
    });
  });

  // A memo running when an in-app call begins is stopped by the arbiter (ArbitratedMic
  // evicts it — the call SDK cannot share the microphone with it). What is left is the
  // memo's own bookkeeping: left alone, the sheet stays in `recording` with a waveform
  // flowing over a dead microphone, and pressing send transcribes only the seconds
  // captured BEFORE the call — a plausible answer to a question nobody asked.
  // Found by the eviction tests below, and not caused by them: close() runs its file
  // cleanups fire-and-forget, and `_pcmFile = null` landed inside the NEXT startRecording,
  // between creating the file and opening its sink. Crash in a fire-and-forget tap
  // handler — an unhandled async error, with the sheet left wedged in `recording`.
  group('VoiceRecorderProvider — a second memo right after the first', () {
    test('records instead of crashing on the cleanup of the previous one', () async {
      final mic = _ContendedMic()..failStart = false;
      final provider = VoiceRecorderProvider(mic: mic);

      await provider.startRecording();
      provider.close();
      await provider.startRecording();

      expect(provider.state, VoiceRecorderState.recording);
      expect(mic.startCalls, 2);
      expect(recordingsDir().listSync().length, 1, reason: 'the first PCM is gone, the second is live');
    });
  });

  group('VoiceRecorderProvider — an in-app call takes the microphone', () {
    test('the sheet returns to idle instead of recording into nothing', () async {
      final arbiter = MicArbiter();
      final mic = _ContendedMic()..failStart = false;
      final provider = VoiceRecorderProvider(mic: mic, arbiter: arbiter);

      await provider.startRecording();
      expect(provider.state, VoiceRecorderState.recording);

      arbiter.holdForCall();
      await pumpEventQueue();

      expect(provider.state, VoiceRecorderState.idle);
      expect(provider.isRecording, isFalse);
      expect(recordingsDir().listSync(), isEmpty, reason: 'the half-written PCM is cleaned up');
    });

    test('a memo that ended before the call is not unwound by it', () async {
      final arbiter = MicArbiter();
      final mic = _ContendedMic()..failStart = false;
      final provider = VoiceRecorderProvider(mic: mic, arbiter: arbiter);

      await provider.startRecording();
      provider.close();
      expect(provider.state, VoiceRecorderState.idle);

      // Second memo, after the first one is done and gone.
      await provider.startRecording();
      expect(provider.state, VoiceRecorderState.recording);
      provider.close();

      arbiter.holdForCall();
      await pumpEventQueue();
      expect(provider.state, VoiceRecorderState.idle);
    });

    // The arbiter outlives every screen: a hook left behind would keep a dead provider
    // alive and unwind a memo that ended long ago.
    test('a disposed provider leaves no eviction hook behind', () async {
      final arbiter = MicArbiter();
      final mic = _ContendedMic()..failStart = false;
      final provider = VoiceRecorderProvider(mic: mic, arbiter: arbiter);

      await provider.startRecording();
      provider.dispose();

      // Must not throw: notifyListeners() on a disposed ChangeNotifier does.
      arbiter.holdForCall();
      await pumpEventQueue();
    });
  });
}
