import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_voximplant/flutter_voximplant.dart';
import 'package:omi/backend/schema/phone_call.dart';
import 'package:omi/models/audio_route.dart';
import 'package:omi/services/voximplant_call_service.dart';

void main() {
  group('VoximplantLogin.fromJson', () {
    test('reads the keyless half of the handshake', () {
      final login = VoximplantLogin.fromJson({
        'provider': 'voximplant',
        'hash': null,
        'user': 'phone@omijarvis.igor.voximplant.com',
        'node': 'Node4',
        'ttl': 300,
      });

      expect(login, isNotNull);
      expect(login!.hash, isNull);
      expect(login.node, 'Node4');
      expect(login.ttl, 300);
    });

    test('reads the half that carries the hash', () {
      final login = VoximplantLogin.fromJson({
        'provider': 'voximplant',
        'hash': 'deadbeef',
        'user': 'phone@omijarvis.igor.voximplant.com',
        'node': 'Node4',
        'ttl': 300,
      });

      expect(login?.hash, 'deadbeef');
    });

    test('a Twilio answer is not mistaken for a Voximplant one', () {
      // Both shapes carry `ttl`; only `provider` tells them apart, and getting this wrong
      // means logging in to the wrong cloud instead of failing.
      final login = VoximplantLogin.fromJson({'access_token': 'jwt', 'ttl': 3600, 'identity': 'uid'});
      expect(login, isNull);
    });

    test('a half-filled answer is refused rather than half-used', () {
      expect(VoximplantLogin.fromJson({'provider': 'voximplant', 'node': 'Node4', 'ttl': 300}), isNull);
      expect(
        VoximplantLogin.fromJson({'provider': 'voximplant', 'user': 'phone@a.b.voximplant.com', 'ttl': 300}),
        isNull,
      );
    });
  });

  group('VoximplantCallService.parseNode', () {
    test('accepts what the backend sends', () {
      expect(VoximplantCallService.parseNode('Node4'), VINode.Node4);
      expect(VoximplantCallService.parseNode('Node13'), VINode.Node13);
    });

    test('accepts the spelling the control panel shows', () {
      expect(VoximplantCallService.parseNode('VINode.Node4'), VINode.Node4);
      expect(VoximplantCallService.parseNode(' node4 '), VINode.Node4);
    });

    test('an unknown node is null, not a silent default', () {
      // Connecting to the wrong node fails at login with a misleading "invalid password".
      expect(VoximplantCallService.parseNode('Node99'), isNull);
      expect(VoximplantCallService.parseNode(''), isNull);
    });
  });

  group('VoximplantCallService.buildCustomData', () {
    test('carries the two ids the cloud scenario reads', () {
      final payload = VoximplantCallService.buildCustomData(
        uid: 'firebase-uid-28-characters-x',
        callId: '1755950000000',
      );

      expect(payload, isNotNull);
      final decoded = jsonDecode(payload!) as Map<String, dynamic>;
      expect(decoded['uid'], 'firebase-uid-28-characters-x');
      expect(decoded['call_id'], '1755950000000');
    });

    test('refuses a payload over Voximplant\'s 200-byte limit', () {
      // The cloud silently drops customData that does not fit, and a call without uid is a
      // call without a transcript — better to fail here, where the reason is still visible.
      final payload = VoximplantCallService.buildCustomData(uid: 'u' * 300, callId: '1');
      expect(payload, isNull);
    });
  });

  group('VoximplantCallService audio routes', () {
    test('every device maps to a route and back', () {
      for (final device in VIAudioDevice.values) {
        final route = VoximplantCallService.audioRouteOf(device);
        expect(route.name, isNotEmpty);
        expect(VoximplantCallService.parseAudioDevice(route.id), device);
      }
    });

    test('the speaker keeps its own type so the speaker button can light up', () {
      expect(VoximplantCallService.audioRouteOf(VIAudioDevice.Speaker).type, AudioRouteType.speaker);
      expect(VoximplantCallService.audioRouteOf(VIAudioDevice.Earpiece).type, AudioRouteType.iPhone);
    });

    test('an unknown route id is refused', () {
      expect(VoximplantCallService.parseAudioDevice('Telepathy'), isNull);
    });
  });

  group('VoximplantCallService microphone foreground service', () {
    /// Records what the platform channel would have been asked to do.
    ({VoximplantCallService service, List<bool> calls}) serviceWatching({bool refuse = false}) {
      final calls = <bool>[];
      final service = VoximplantCallService(holdMicService: (hold) async {
        calls.add(hold);
        return !(refuse && hold);
      });
      return (service: service, calls: calls);
    }

    test('the states that carry audio hold the service, the rest release it', () {
      // Ringing counts: the user can put the app in the background while it is still
      // ringing, and Android suspends the microphone of a backgrounded app regardless.
      expect(VoximplantCallService.micServiceHeldIn(PhoneCallState.connecting), isTrue);
      expect(VoximplantCallService.micServiceHeldIn(PhoneCallState.ringing), isTrue);
      expect(VoximplantCallService.micServiceHeldIn(PhoneCallState.active), isTrue);
      expect(VoximplantCallService.micServiceHeldIn(PhoneCallState.ended), isFalse);
      expect(VoximplantCallService.micServiceHeldIn(PhoneCallState.failed), isFalse);
      expect(VoximplantCallService.micServiceHeldIn(PhoneCallState.idle), isFalse);
    });

    test('a whole call holds the service once and releases it once', () async {
      final w = serviceWatching();
      for (final state in [
        PhoneCallState.connecting,
        PhoneCallState.ringing,
        PhoneCallState.active,
        PhoneCallState.ended,
      ]) {
        w.service.emitState(state);
      }
      await pumpEventQueue();

      // Not [true, true, true, false]: starting an already running service is a no-op the
      // user pays for in wakeups, and the released state has to be reached exactly once.
      expect(w.calls, [true, false]);
    });

    test('a failed call releases the service just like a normal hangup', () async {
      final w = serviceWatching();
      w.service.emitState(PhoneCallState.connecting);
      w.service.emitState(PhoneCallState.failed);
      await pumpEventQueue();

      expect(w.calls, [true, false]);
    });

    test('a refused service is not "stopped" afterwards', () async {
      // Android can refuse to start a foreground service (no permission, background start).
      // Stopping what never started would be harmless noise here, but the same bookkeeping
      // error in the other direction leaves the microphone notification up for good.
      final w = serviceWatching(refuse: true);
      w.service.emitState(PhoneCallState.connecting);
      await pumpEventQueue();
      w.service.emitState(PhoneCallState.ended);
      await pumpEventQueue();

      expect(w.calls, [true]);
    });

    test('two states in the same turn do not start the service twice', () async {
      // Both emits land before the first await resolves — the flag has to be set before it.
      final w = serviceWatching();
      w.service.emitState(PhoneCallState.connecting);
      w.service.emitState(PhoneCallState.ringing);
      await pumpEventQueue();

      expect(w.calls, [true]);
    });

    test('the state still reaches the listener while the service is being held', () async {
      final w = serviceWatching();
      final seen = <PhoneCallState>[];
      w.service.onCallStateChanged = seen.add;
      w.service.emitState(PhoneCallState.active);
      await pumpEventQueue();

      expect(seen, [PhoneCallState.active]);
    });
  });

  group('callFailure', () {
    // Что этот разбор стоит: сценарий отклоняет звонок кодом 486, а платформа рисует
    // 486 как «Busy Here». Без заголовка «месячный лимит исчерпан» приходит на телефон
    // словами «собеседник занят» — и пользователь перезванивает вместо того, чтобы
    // пополнить счёт.
    test('a refusal names its own cause instead of the SIP reason phrase', () {
      final e = VoximplantCallService.callFailure(
        code: 486,
        description: 'Busy Here',
        headers: {'X-Omi-Reason': 'quota_exceeded', 'X-Omi-Used': '300', 'X-Omi-Limit': '300'},
      );

      expect(e.code, 'VOX_QUOTA_EXCEEDED');
      expect(e.message, contains('limit is used up'));
      expect(e.message, contains('300 of 300'));
      expect(e.message, isNot(contains('Busy')));
    });

    test('the counters are optional — the reason still shows without them', () {
      final e = VoximplantCallService.callFailure(
        code: 486,
        description: 'Busy Here',
        headers: {'X-Omi-Reason': 'quota_exceeded'},
      );

      // Не «нет подстроки of» — она есть в «start of next month», и такая проверка
      // краснела бы на верном коде. Проверяется ровно то, что обещано: скобки со счётом.
      expect(e.message, contains('limit is used up'));
      expect(e.message, isNot(contains('(')));
    });

    // SIP-заголовки регистронезависимы, и SDK двух платформ отдают их в разном регистре.
    // Поиск по точной строке работал бы на одной и молча ломался на другой — а выглядело
    // бы это как «заголовок не доехал», то есть уводило бы от причины.
    test('the header is found whatever case the SDK hands it over in', () {
      final e = VoximplantCallService.callFailure(
        code: 486,
        description: 'Busy Here',
        headers: {'x-omi-reason': 'no_verified_number'},
      );

      expect(e.code, 'VOX_NO_VERIFIED_NUMBER');
      expect(e.message, contains('verify your number'));
    });

    // Главная страховка: доставку этих заголовков ИХ сетью нельзя проверить до первого
    // живого звонка. Значит их отсутствие обязано стоить ровно ноль — прежнее поведение.
    test('without the header nothing changes — a real busy signal stays a busy signal', () {
      final e = VoximplantCallService.callFailure(code: 486, description: 'Busy Here', headers: {});

      expect(e.code, 'SIP_486');
      expect(e.message, 'Busy Here');
    });

    test('null headers are not a crash — the SDK may omit them entirely', () {
      final e = VoximplantCallService.callFailure(code: 603, description: '', headers: null);

      expect(e.code, 'SIP_603');
      expect(e.message, 'The call could not be completed.');
    });

    // Бэкенд может завести новую причину раньше, чем клиент про неё узнает. Показать
    // сырое слово лучше, чем «Busy Here»: его хотя бы можно найти в логе кабинета.
    test('an unknown reason still beats the SIP reason phrase', () {
      final e = VoximplantCallService.callFailure(
        code: 486,
        description: 'Busy Here',
        headers: {'X-Omi-Reason': 'some_new_backend_reason'},
      );

      expect(e.code, 'VOX_SOME_NEW_BACKEND_REASON');
      expect(e.message, contains('some_new_backend_reason'));
    });

    // Все пять причин бэкенда (routers/phone_calls.py) плюс три, которые сценарий решает
    // сам, обязаны иметь человеческий текст — иначе ветка default их проглотит незаметно.
    test('every reason the backend and the scenario can send has its own wording', () {
      const reasons = [
        'quota_exceeded',
        'feature_disabled',
        'no_verified_number',
        'destination_not_allowed',
        'invalid_destination',
        'inbound_not_ours',
        'call_loop_guard',
        'denied_by_server',
      ];
      for (final reason in reasons) {
        final e = VoximplantCallService.callFailure(
          code: 486,
          description: 'Busy Here',
          headers: {'X-Omi-Reason': reason},
        );
        expect(e.message, isNot(contains(reason)), reason: '$reason fell through to the default branch');
      }
    });
  });
}
