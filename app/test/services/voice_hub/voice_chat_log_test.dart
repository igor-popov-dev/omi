// Self-host patch, not for upstream: see lib/services/voice_hub/voice_chat_log.dart.
import 'package:flutter_test/flutter_test.dart';

import 'package:omi/services/voice_hub/voice_chat_log.dart';

void main() {
  group('VoiceChatLog', () {
    late List<List<VoiceChatTurn>> posted;
    late VoiceChatLog log;

    setUp(() {
      posted = [];
      log = VoiceChatLog(post: (turns) async {
        posted.add(turns);
        return true;
      });
    });

    tearDown(() => log.dispose());

    test('buffers instead of posting per fragment', () async {
      log.addUserTurn('что я ел вчера');
      log.addAssistantTurn('вчера была паста');

      // A live conversation emits a fragment every few hundred ms; one request
      // per fragment would compete with the audio socket for the uplink.
      expect(posted, isEmpty);

      await log.flush();

      expect(posted.single.map((t) => t.text), ['что я ел вчера', 'вчера была паста']);
      expect(posted.single.map((t) => t.sender), ['human', 'ai']);
    });

    test('drops blank turns rather than storing empty bubbles', () async {
      log.addUserTurn('   ');
      log.addAssistantTurn('');

      await log.flush();

      expect(posted, isEmpty);
    });

    test('flush is a no-op when nothing is buffered', () async {
      await log.flush();
      expect(posted, isEmpty);
    });

    test('a failed post never throws into the live conversation', () async {
      final failing = VoiceChatLog(post: (_) async => throw StateError('network down'));
      failing.addUserTurn('привет');

      // Losing a history line must not disturb a call in progress.
      await failing.flush();
      failing.dispose();
    });

    test('a full batch posts immediately instead of growing unbounded', () async {
      for (var i = 0; i < VoiceChatLog.maxTurnsPerFlush; i++) {
        log.addUserTurn('реплика $i');
      }
      // Give the fire-and-forget flush a turn of the event loop.
      await Future<void>.delayed(Duration.zero);

      expect(posted.single, hasLength(VoiceChatLog.maxTurnsPerFlush));
    });

    test('turns carry the moment they were spoken, not the moment they were posted', () async {
      final spoken = DateTime.utc(2026, 8, 23, 20, 30);
      log.addUserTurn('привет', at: spoken);

      await log.flush();

      expect(posted.single.single.spokenAt, spoken);
      expect(posted.single.single.toJson()['spoken_at'], contains('2026-08-23T20:30'));
    });
  });
}
