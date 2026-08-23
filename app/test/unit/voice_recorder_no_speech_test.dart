import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:omi/backend/http/api/messages.dart';
import 'package:omi/backend/preferences.dart';
import 'package:omi/providers/voice_recorder_provider.dart';
import 'package:omi/services/services.dart';

/// Mic double that records nothing but reports a clean start/stop, so the
/// provider can walk its state machine without native plumbing.
class _SilentMic implements IMicRecorderService {
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
    _onStop = onStop;
    onRecording?.call();
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

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await SharedPreferencesUtil.init();
    tempDir = Directory.systemTemp.createTempSync('voice_recorder_no_speech_');

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

  Future<File> createPendingWav(String name) async {
    final wavFile = File('${tempDir.path}/$name');
    await wavFile.writeAsBytes(List<int>.filled(44 + 32000, 0));
    await SharedPreferencesUtil().saveString('voice_recorder_pending_wav_path', wavFile.path);
    return wavFile;
  }

  group('VoiceRecorderProvider wordless recording', () {
    test('a recognized-nothing upload is an outcome, not a red error', () async {
      final wavFile = await createPendingWav('wordless.wav');
      var transcriptDelivered = false;

      final provider = VoiceRecorderProvider(
        mic: _SilentMic(),
        transcriber: (_) async => throw const VoiceMessageNoSpeechException('stt_empty_unexpected'),
      );
      provider.setCallbacks(onTranscriptReady: (_, __) => transcriptDelivered = true);
      await provider.checkPendingRecording();

      await provider.retry();

      expect(provider.state, VoiceRecorderState.noSpeechDetected);
      expect(provider.hasNoSpeechDetected, isTrue);
      expect(transcriptDelivered, isFalse);
      // Nothing is deleted yet: the user has not asked for a new take.
      expect(wavFile.existsSync(), isTrue);
    });

    test('the next tap records again instead of re-uploading the same bytes', () async {
      final wavFile = await createPendingWav('wordless_loop.wav');
      var uploads = 0;
      final mic = _SilentMic();

      final provider = VoiceRecorderProvider(
        mic: mic,
        transcriber: (_) async {
          uploads++;
          throw const VoiceMessageNoSpeechException('stt_empty_unexpected');
        },
      );
      await provider.checkPendingRecording();

      await provider.retry();
      expect(uploads, 1);
      expect(mic.startCalls, 0);

      // The loop this closes: before, every tap re-sent the identical bytes to
      // a deterministic transcriber and landed on the same red error forever.
      await provider.retry();

      expect(uploads, 1);
      expect(mic.startCalls, 1);
      expect(provider.state, VoiceRecorderState.recording);
      expect(wavFile.existsSync(), isFalse);
      expect(SharedPreferencesUtil().getString('voice_recorder_pending_wav_path'), isEmpty);

      provider.close();
    });

    test('recordAgain drops the wordless take and arms a new session', () async {
      final wavFile = await createPendingWav('wordless_manual.wav');
      final mic = _SilentMic();

      final provider = VoiceRecorderProvider(
        mic: mic,
        transcriber: (_) async => throw const VoiceMessageNoSpeechException('expected_silence'),
      );
      await provider.checkPendingRecording();
      await provider.retry();

      await provider.recordAgain();

      expect(mic.startCalls, 1);
      expect(provider.state, VoiceRecorderState.recording);
      expect(wavFile.existsSync(), isFalse);

      provider.close();
    });

    test('a real transport failure still reads as failed and keeps the retry', () async {
      final wavFile = await createPendingWav('transport_failure.wav');
      var uploads = 0;

      final provider = VoiceRecorderProvider(
        mic: _SilentMic(),
        transcriber: (_) async {
          uploads++;
          throw Exception('Error transcribing voice message: connection closed');
        },
      );
      await provider.checkPendingRecording();

      await provider.retry();
      expect(provider.state, VoiceRecorderState.transcribeFailed);

      // Re-sending the same bytes is the right move here — the upload, not the
      // audio, is what failed.
      await provider.retry();
      expect(uploads, 2);
      expect(provider.state, VoiceRecorderState.transcribeFailed);
      expect(wavFile.existsSync(), isTrue);
    });
  });

  group('transcriptionErrorCode', () {
    test('reads the typed code out of FastAPI detail and flat bodies', () {
      expect(
        transcriptionErrorCode('{"detail":{"error":"stt_empty_unexpected","retryable":true}}'),
        'stt_empty_unexpected',
      );
      expect(transcriptionErrorCode('{"error":"stt_upstream_error"}'), 'stt_upstream_error');
    });

    test('returns null for bodies a proxy or gateway can hand back', () {
      for (final body in ['', 'Bad Gateway', '[]', '{"detail":"nope"}', '{"error":42}', 'null']) {
        expect(transcriptionErrorCode(body), isNull, reason: body);
      }
    });
  });
}
