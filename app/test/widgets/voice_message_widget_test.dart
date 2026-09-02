// The voice-message bubble against a VoiceMessagePlayer wired to fakes:
// mocked http (the audio route), an injected auth-header builder, a temp
// cache directory and a fake audio backend instead of just_audio.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:omi/backend/schema/message.dart';
import 'package:omi/l10n/app_localizations.dart';
import 'package:omi/pages/chat/widgets/voice_message_widget.dart';
import 'package:omi/services/voice_message/voice_message_player.dart';

class _FakeBackend implements VoiceAudioBackend {
  final playing = StreamController<bool>.broadcast();
  final position = StreamController<Duration>.broadcast();
  final duration = StreamController<Duration?>.broadcast();
  final completed = StreamController<void>.broadcast();
  final List<String> calls = [];
  String? loadedPath;
  double? speed;
  Duration? seekedTo;

  @override
  Future<Duration?> setFilePath(String path) async {
    loadedPath = path;
    calls.add('setFilePath');
    return const Duration(seconds: 31);
  }

  @override
  Future<void> play() async {
    calls.add('play');
    playing.add(true);
  }

  @override
  Future<void> pause() async {
    calls.add('pause');
    playing.add(false);
  }

  @override
  Future<void> seek(Duration target) async {
    calls.add('seek');
    seekedTo = target;
    position.add(target);
  }

  @override
  Future<void> setSpeed(double value) async {
    speed = value;
  }

  @override
  Future<void> stop() async {
    calls.add('stop');
  }

  @override
  Stream<bool> get playingStream => playing.stream;

  @override
  Stream<Duration> get positionStream => position.stream;

  @override
  Stream<Duration?> get durationStream => duration.stream;

  @override
  Stream<void> get completedStream => completed.stream;

  @override
  Future<void> dispose() async {}
}

ServerMessage _voiceMessage({String text = 'Проверка плеера, это голосовое от ассистента'}) {
  final file = MessageFile(
    '',
    '',
    'voice-test.mp3',
    'audio/mpeg',
    'file-1',
    DateTime(2026, 9, 2),
    '',
    url: 'v2/chat/files/file-1/audio',
    durationSec: 31,
    kind: MessageFile.voiceMessageKind,
  );
  return ServerMessage(
    'msg-1',
    DateTime(2026, 9, 2),
    text,
    MessageSender.ai,
    MessageType.text,
    null,
    true,
    [file],
    ['file-1'],
    [],
  );
}

Widget _host(Widget child, {ThemeData? theme}) {
  return MaterialApp(
    theme: theme ?? ThemeData.dark(),
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    supportedLocales: const [Locale('en'), Locale('ru')],
    locale: const Locale('ru'),
    home: Scaffold(body: Padding(padding: const EdgeInsets.all(12), child: child)),
  );
}

/// Real async work (file cache, mocked http, stream events) only completes
/// inside `runAsync`, and `pumpAndSettle` never settles while the loading
/// spinner animates — so the interactive tests run their body in `runAsync`
/// and poll [done] instead.
Future<void> _tapAndWait(WidgetTester tester, Finder finder, bool Function() done) async {
  await tester.tap(finder);
  await _waitFor(done);
  await tester.pump();
}

Future<void> _waitFor(bool Function() done) async {
  for (var i = 0; i < 500 && !done(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(done(), isTrue, reason: 'interaction did not complete');
}

void main() {
  late Directory cacheDir;
  late _FakeBackend backend;
  late List<http.Request> requests;
  late VoiceMessagePlayer player;
  late bool hubBusy;

  setUp(() async {
    cacheDir = await Directory.systemTemp.createTemp('voice_message_test');
    backend = _FakeBackend();
    requests = [];
    hubBusy = false;
    player = VoiceMessagePlayer.custom(
      httpClient: MockClient((request) async {
        requests.add(request);
        if (request.headers['Authorization'] != 'Bearer test-token') {
          return http.Response('unauthorized', 401);
        }
        return http.Response.bytes(List<int>.filled(2048, 7), 200, headers: {'content-type': 'audio/mpeg'});
      }),
      headersBuilder: (url) async => {
        'Authorization': 'Bearer test-token',
        'CF-Access-Client-Id': 'cf-id',
        'CF-Access-Client-Secret': 'cf-secret',
      },
      backendFactory: () => backend,
      cacheDirectory: () async => cacheDir,
      voiceHubBusy: () => hubBusy,
      apiBaseUrl: () => 'https://omi-api.test/',
      configureAudioSession: false,
    );
  });

  tearDown(() async {
    await cacheDir.delete(recursive: true);
  });

  testWidgets('renders play button, duration, speed badge and a folded transcript', (tester) async {
    final message = _voiceMessage();
    await tester.pumpWidget(_host(VoiceMessageWidget(message: message, file: message.files.first, player: player)));

    expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);
    expect(find.text('0:00 / 0:31'), findsOneWidget);
    expect(find.text('1x'), findsOneWidget);
    expect(find.text('Показать текст'), findsOneWidget);
    expect(find.byKey(VoiceMessageWidget.transcriptKey('file-1')), findsNothing);

    await tester.tap(find.byKey(VoiceMessageWidget.transcriptToggleKey('file-1')));
    await tester.pumpAndSettle();
    expect(find.byKey(VoiceMessageWidget.transcriptKey('file-1')), findsOneWidget);
    expect(find.textContaining('Проверка плеера'), findsOneWidget);
    expect(find.text('Скрыть текст'), findsOneWidget);
  });

  testWidgets('hides the transcript toggle when the message has no text', (tester) async {
    final message = _voiceMessage(text: '');
    await tester.pumpWidget(_host(VoiceMessageWidget(message: message, file: message.files.first, player: player)));

    expect(find.byKey(VoiceMessageWidget.transcriptToggleKey('file-1')), findsNothing);
  });

  testWidgets('play downloads once with the API auth headers, caches the file and toggles pause', (tester) async {
    await tester.runAsync(() async {
      final message = _voiceMessage();
      await tester.pumpWidget(_host(VoiceMessageWidget(message: message, file: message.files.first, player: player)));

      final playKey = find.byKey(VoiceMessageWidget.playKey('file-1'));
      await _tapAndWait(tester, playKey, () => player.isPlaying('msg-1'));

      expect(requests, hasLength(1));
      expect(requests.single.url.toString(), 'https://omi-api.test/v2/chat/files/file-1/audio');
      expect(requests.single.headers['Authorization'], 'Bearer test-token');
      expect(requests.single.headers['CF-Access-Client-Id'], 'cf-id');
      expect(requests.single.headers['CF-Access-Client-Secret'], 'cf-secret');

      final cached = File('${cacheDir.path}/file-1.mp3');
      expect(await cached.exists(), isTrue);
      expect(await cached.length(), 2048);
      expect(backend.loadedPath, cached.path);
      expect(backend.calls, containsAllInOrder(['stop', 'setFilePath', 'play']));
      expect(backend.speed, 1.0);
      expect(find.byIcon(Icons.pause_rounded), findsOneWidget);

      await _tapAndWait(tester, playKey, () => !player.isPlaying('msg-1'));
      expect(backend.calls.last, 'pause');
      expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);

      // Resume must not hit the network again.
      await _tapAndWait(tester, playKey, () => player.isPlaying('msg-1'));
      expect(requests, hasLength(1));
      expect(backend.calls.last, 'play');
    });
  });

  testWidgets('position updates the time label, waveform tap seeks, speed badge cycles', (tester) async {
    await tester.runAsync(() async {
      final message = _voiceMessage();
      await tester.pumpWidget(_host(VoiceMessageWidget(message: message, file: message.files.first, player: player)));
      await _tapAndWait(tester, find.byKey(VoiceMessageWidget.playKey('file-1')), () => player.isPlaying('msg-1'));

      backend.position.add(const Duration(seconds: 7));
      await _waitFor(() => player.positionOf('msg-1') == const Duration(seconds: 7));
      await tester.pump();
      expect(find.text('0:07 / 0:31'), findsOneWidget);

      final waveform = find.byKey(VoiceMessageWidget.waveformKey('file-1'));
      final rect = tester.getRect(waveform);
      await tester.tapAt(Offset(rect.left + rect.width / 2, rect.center.dy));
      await _waitFor(() => backend.seekedTo != null);
      await tester.pump();
      expect((backend.seekedTo!.inMilliseconds - 15500).abs(), lessThan(1500));

      final speedKey = find.byKey(VoiceMessageWidget.speedKey('file-1'));
      await _tapAndWait(tester, speedKey, () => player.speed == 1.5);
      expect(find.text('1.5x'), findsOneWidget);
      expect(backend.speed, 1.5);
      await _tapAndWait(tester, speedKey, () => player.speed == 2.0);
      expect(find.text('2x'), findsOneWidget);
      await _tapAndWait(tester, speedKey, () => player.speed == 1.0);
      expect(find.text('1x'), findsOneWidget);
    });
  });

  testWidgets('renders in a light theme too', (tester) async {
    final message = _voiceMessage();
    await tester.pumpWidget(
      _host(VoiceMessageWidget(message: message, file: message.files.first, player: player), theme: ThemeData.light()),
    );
    expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);
    expect(find.text('0:00 / 0:31'), findsOneWidget);
  });

  test('a push is not auto-played while the voice hub is busy, a manual play still works', () async {
    hubBusy = true;
    final ref = VoiceMessageRef.fromPushData({
      'voice_message': 'true',
      'message_id': 'msg-1',
      'file_id': 'file-1',
      'audio_url': 'v2/chat/files/file-1/audio',
      'audio_duration_sec': '3.3',
    })!;
    expect(await player.play(ref, fromPush: true), isFalse);
    expect(requests, isEmpty);

    hubBusy = false;
    expect(await player.play(ref, fromPush: true), isTrue);
    expect(requests, hasLength(1));
    expect(ref.duration, const Duration(milliseconds: 3300));
  });

  test('the Firebase token is only attached for the API host', () {
    expect(isOmiApiUrl('https://omi-api.test/v2/chat/files/x/audio', 'https://omi-api.test/'), isTrue);
    expect(isOmiApiUrl('https://omi-api.test:8010/v2/x', 'https://omi-api.test/'), isFalse);
    expect(isOmiApiUrl('http://127.0.0.1:4443/storage/v1/b/chat-files/o/x', 'https://omi-api.test/'), isFalse);
    expect(isOmiApiUrl('https://omi-api.test/v2/x', null), isFalse);
  });

  test('VoiceMessageRef.fromPushData ignores non-voice pushes', () {
    expect(VoiceMessageRef.fromPushData({'notification_type': 'plugin'}), isNull);
    expect(VoiceMessageRef.fromPushData({'voice_message': 'true', 'message_id': 'm'}), isNull);
  });

  test('MessageFile picks up url/duration/kind from the raw message json', () {
    final message = ServerMessage.fromGeneratedWireJson({
      'id': 'msg-2',
      'created_at': '2026-09-02T07:13:43+00:00',
      'text': 'hello',
      'sender': 'ai',
      'type': 'text',
      'files_id': ['file-2'],
      'files': [
        {
          'id': 'file-2',
          'name': 'voice.mp3',
          'mime_type': 'audio/mpeg',
          'openai_file_id': '',
          'created_at': '2026-09-02T07:13:43+00:00',
          'url': 'v2/chat/files/file-2/audio',
          'duration_sec': 3.3,
          'kind': 'voice_message',
        }
      ],
    });
    final file = message.voiceFile;
    expect(file, isNotNull);
    expect(file!.url, 'v2/chat/files/file-2/audio');
    expect(file.duration, const Duration(milliseconds: 3300));
    expect(file.kind, 'voice_message');
    expect(file.toJson()['url'], 'v2/chat/files/file-2/audio');
  });
}
