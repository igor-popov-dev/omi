// Tests for `free_form_voice_mode_projection.dart` — a pure event->projection
// mapping, so this stays a hermetic unit test with no HubController/session
// fakes needed: `freeFormModeProjectionEvents` builds a `HubControllerEvents`
// and this file just invokes its callbacks directly.
import 'package:flutter_test/flutter_test.dart';

import 'package:omi/services/voice_hub/free_form_voice_mode_projection.dart';
import 'package:omi/services/voice_hub/voice_chat_log.dart';
import 'package:omi/services/voice_hub/hub_controller.dart';
import 'package:omi/services/voice_hub/voice_turn_machine.dart' show VoiceTurnUiProjection, idleVoiceTurnProjection;

void main() {
  group('freeFormModeProjectionEvents', () {
    late List<VoiceTurnUiProjection> applied;
    late int disconnectCalls;
    late int expiringCalls;
    late HubControllerEvents events;

    setUp(() {
      applied = [];
      disconnectCalls = 0;
      expiringCalls = 0;
      events = freeFormModeProjectionEvents(
        applyProjection: (p) => applied.add(p),
        onDisconnected: (_) => disconnectCalls += 1,
        onSocketExpiring: () => expiringCalls += 1,
      );
    });

    test('onConnected projects listening', () {
      events.onConnected!('sess-1');

      expect(applied, hasLength(1));
      expect(applied.single.isListening, isTrue);
      expect(applied.single.isResponseActive, isFalse);
    });

    test('onSpeakingStart projects response-active (not listening)', () {
      events.onSpeakingStart!();

      expect(applied.single.isResponseActive, isTrue);
      expect(applied.single.isListening, isFalse);
    });

    test('onSpeakingEnd projects back to listening', () {
      events.onSpeakingStart!();
      events.onSpeakingEnd!();

      expect(applied.last.isListening, isTrue);
      expect(applied.last.isResponseActive, isFalse);
    });

    test('onUserSpeechState(true) projects listening AND hearing-user', () {
      events.onUserSpeechState!(true);

      expect(applied.single.isListening, isTrue);
      expect(applied.single.isHearingUser, isTrue);
      expect(applied.single.isResponseActive, isFalse);
    });

    test('onUserSpeechState(false) projects thinking — the user stopped, the reply has not started', () {
      events.onUserSpeechState!(false);

      expect(applied.single.isThinking, isTrue);
      expect(applied.single.isListening, isFalse);
      expect(applied.single.isHearingUser, isFalse);
    });

    // The regression this pair guards: a transcript lands in the same frame
    // as the end-of-utterance verdict (measured live, 23.08), so projecting
    // it would overwrite "Думаю…" with "Слушаю…" every single turn — and the
    // gap it covers is exactly where `ask_claude` spends its silent seconds.
    test('a transcript arriving after the end-of-utterance verdict does not drag the state back to listening', () {
      events.onUserSpeechState!(false);
      events.onInputTranscript!('привет', true, null);

      expect(applied, hasLength(1));
      expect(applied.single.isThinking, isTrue);
    });

    test('onInputTranscript projects nothing on its own', () {
      events.onInputTranscript!('hello', false, null);
      events.onInputTranscript!('', true, null);

      expect(applied, isEmpty);
    });

    test('a full free-form turn walks listening -> hearing -> thinking -> speaking -> listening', () {
      events.onConnected!('sess-1');
      events.onUserSpeechState!(true);
      events.onUserSpeechState!(false);
      events.onSpeakingStart!();
      events.onSpeakingEnd!();

      expect(
        applied.map((p) => (p.isListening, p.isHearingUser, p.isThinking, p.isResponseActive)),
        [
          (true, false, false, false), // connected: mic open, nothing heard yet
          (true, true, false, false), // server VAD hears the user
          (false, false, true, false), // user stopped; reply not started
          (false, false, false, true), // assistant audible
          (true, false, false, false), // player drained: back to listening
        ],
      );
    });

    test('onError fires onDisconnected, not applyProjection', () {
      events.onError!(const HubControllerError(reason: 'boom', retryable: false, aliveForMs: 0));

      expect(disconnectCalls, 1);
      expect(applied, isEmpty);
    });

    test('goAway asks for a rebuild without touching the on-screen state', () {
      // The user is mid-conversation and the rebuild is meant to be
      // invisible: showing "reconnecting" for a socket that still works
      // would be a worse lie than saying nothing.
      events.onGoAway!(const Duration(seconds: 50));

      expect(expiringCalls, 1);
      expect(disconnectCalls, 0);
      expect(applied, isEmpty);
    });

    test('none of the projected states ever equal idle', () {
      events.onConnected!('sess-1');
      events.onSpeakingStart!();
      events.onSpeakingEnd!();

      for (final p in applied) {
        expect(p, isNot(equals(idleVoiceTurnProjection)));
      }
    });
  });

  // Self-host patch: история должна отражать УСЛЫШАННОЕ, а не сгенерированное.
  group('запись разговора в историю', () {
    late List<VoiceChatTurn> posted;
    late VoiceChatLog log;
    late HubControllerEvents events;

    setUp(() {
      posted = [];
      log = VoiceChatLog(post: (turns) async {
        posted.addAll(turns);
        return true;
      });
      events = freeFormModeProjectionEvents(
        applyProjection: (_) {},
        onDisconnected: (_) {},
        // Обязательный параметр появился вместе с упреждающей пересборкой
        // сокета (полоса 5); этой группе тестов goAway не интересен.
        onSocketExpiring: () {},
        chatLog: log,
      );
    });

    tearDown(() => log.dispose());

    test('реплики копятся по кускам и пишутся одной строкой', () async {
      events.onInputTranscript!('что я ', false, null);
      events.onInputTranscript!('ел вчера', false, null);
      events.onSpeakingStart!();
      events.onAssistantText!('вчера была ', false, null);
      events.onAssistantText!('паста', false, null);
      events.onTurnDone!(null);
      await log.flush();

      expect(posted.map((t) => t.text), ['что я ел вчера', 'вчера была паста']);
      expect(posted.map((t) => t.sender), ['human', 'ai']);
    });

    // Регресс 24.08: метка = момент НАЧАЛА речи, не коммита. onTurnDone
    // коммитит пользователя перед ассистентом — следующая реплика
    // пользователя, начатая во время ответа, получала метку раньше самого
    // ответа, и чат (сортировка по created_at) показывал их не по порядку.
    test('метки реплик хронологичны даже при коммите парами', () async {
      events.onInputTranscript!('первый вопрос', false, null); // user1 начал
      await Future<void>.delayed(const Duration(milliseconds: 5));
      events.onSpeakingStart!(); // ассистент начал, user1 закоммичен
      events.onAssistantText!('длинный ответ', false, null);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      // Пользователь заговорил, пока ассистент ещё отвечает.
      events.onInputTranscript!('второй вопрос', false, null);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      events.onTurnDone!(null); // коммитит user2 ПЕРЕД assistant1
      await log.flush();

      expect(posted.map((t) => t.text), ['первый вопрос', 'второй вопрос', 'длинный ответ']);
      final byTime = [...posted]..sort((a, b) => a.spokenAt.compareTo(b.spokenAt));
      expect(byTime.map((t) => t.text), ['первый вопрос', 'длинный ответ', 'второй вопрос'],
          reason: 'хронология по меткам обязана совпадать с реальным порядком речи');
    });

    // Скрин Игоря 24.08: пузырь «<noise>» в чате — служебная метка не-речи
    // от Gemini, а не сказанное.
    test('токен <noise> вырезается, реплика из одного шума не пишется', () async {
      events.onInputTranscript!('<noise>', false, null);
      events.onSpeakingStart!(); // коммит user — чистый шум, писать нечего
      events.onAssistantText!('Тут я.', false, null);
      events.onTurnDone!(null);
      events.onInputTranscript!('<noise>', false, null);
      events.onInputTranscript!('Ты меня слышишь?', false, null);
      events.onTurnDone!(null);
      await log.flush();

      expect(posted.map((t) => t.text), ['Тут я.', 'Ты меня слышишь?']);
    });

    test('перебивание помечает реплику как недоговорённую', () async {
      events.onSpeakingStart!();
      events.onAssistantText!('вчера была паста и ещё', false, null);
      events.onInterrupted!();
      await log.flush();

      // Хвост после перебивания пользователь не слышал — строка помечена,
      // чтобы следующий ход не строился на том, чего не было в эфире.
      expect(posted.single.text, 'вчера была паста и ещё… [прервано]');
      expect(posted.single.sender, 'ai');
    });

    test('после перебивания следующая реплика не тянет за собой старый хвост', () async {
      events.onSpeakingStart!();
      events.onAssistantText!('первая', false, null);
      events.onInterrupted!();
      events.onSpeakingStart!();
      events.onAssistantText!('вторая', false, null);
      events.onTurnDone!(null);
      await log.flush();

      expect(posted.map((t) => t.text), ['первая… [прервано]', 'вторая']);
    });

    test('обрыв сессии тоже сохраняет прозвучавшее', () async {
      events.onAssistantText!('успел сказать', false, null);
      events.onError!(const HubControllerError(reason: 'socket closed', retryable: true, aliveForMs: 10));
      await log.flush();

      expect(posted.single.text, 'успел сказать');
    });
  });
}
