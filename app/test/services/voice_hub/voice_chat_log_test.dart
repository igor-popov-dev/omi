// Self-host patch, not for upstream: see lib/services/voice_hub/voice_chat_log.dart.
import 'dart:async';

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

    // 02.09: история должна появляться в чате после каждой реплики, а не по
    // завершении режима — коммит реплики сразу уходит на сервер.
    test('posts every committed turn right away, without waiting for the mode to stop', () async {
      log.addUserTurn('что я ел вчера');
      expect(posted.single.single.text, 'что я ел вчера');

      // Ответ приходит спустя секунды — предыдущий запрос давно завершён.
      await Future<void>.delayed(Duration.zero);
      log.addAssistantTurn('вчера была паста');

      expect(posted.map((b) => b.single.text), ['что я ел вчера', 'вчера была паста']);
      expect(posted.map((b) => b.single.sender), ['human', 'ai']);
    });

    test('flush after per-turn posting never sends a turn twice', () async {
      log.addUserTurn('привет');
      await Future<void>.delayed(Duration.zero);
      log.addAssistantTurn('здравствуй');

      await log.flush();
      await log.flush();

      expect(posted.expand((b) => b).map((t) => t.text), ['привет', 'здравствуй']);
    });

    test('turns committed while a post is in flight wait and keep spoken order', () async {
      final gate = Completer<bool>();
      var calls = 0;
      final slow = VoiceChatLog(post: (turns) async {
        posted.add(turns);
        if (++calls == 1) return gate.future;
        return true;
      });

      slow.addUserTurn('первая');
      slow.addAssistantTurn('вторая');
      slow.addUserTurn('третья');
      // Первый запрос ещё на проводе — второй не стартует параллельно.
      expect(posted, hasLength(1));

      gate.complete(true);
      await slow.flush();

      expect(posted.map((b) => b.map((t) => t.text).join(',')), ['первая', 'вторая,третья']);
      slow.dispose();
    });

    test('fires onStored after each successful post so chat can reload', () async {
      var stored = 0;
      log.onStored = () => stored++;

      log.addUserTurn('привет');
      await log.flush();
      log.addAssistantTurn('здравствуй');
      await log.flush();

      expect(stored, 2);
    });

    test('does not fire onStored when the post is refused', () async {
      var stored = 0;
      final refused = VoiceChatLog(post: (_) async => false)..onStored = () => stored++;

      refused.addUserTurn('привет');
      await refused.flush();

      expect(stored, 0);
      refused.dispose();
    });

    test('drops blank turns rather than storing empty bubbles', () async {
      log.addUserTurn('   ');
      log.addAssistantTurn('');

      await log.flush();

      expect(posted, isEmpty);
    });

    test('flush is a no-op when nothing is queued', () async {
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

    test('a failed post drops its batch and the next turn still goes out', () async {
      var calls = 0;
      final flaky = VoiceChatLog(post: (turns) async {
        posted.add(turns);
        if (++calls == 1) throw StateError('network down');
        return true;
      });

      flaky.addUserTurn('пропала');
      await flaky.flush();
      flaky.addAssistantTurn('дошла');
      await flaky.flush();

      expect(posted.map((b) => b.single.text), ['пропала', 'дошла']);
      flaky.dispose();
    });

    test('a queue larger than the server cap goes out in capped batches', () async {
      final gate = Completer<bool>();
      var calls = 0;
      final slow = VoiceChatLog(post: (turns) async {
        posted.add(turns);
        if (++calls == 1) return gate.future;
        return true;
      });

      slow.addUserTurn('первая'); // на проводе
      for (var i = 0; i < VoiceChatLog.maxTurnsPerFlush + 3; i++) {
        slow.addUserTurn('реплика $i'); // копятся за ней
      }
      gate.complete(true);
      await slow.flush();

      expect(posted.map((b) => b.length), [1, VoiceChatLog.maxTurnsPerFlush, 3]);
      slow.dispose();
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
