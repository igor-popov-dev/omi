// Пауза фоновой записи телефона на время СВОЕГО звонка.
//
// Что ломается без неё: телефон продолжает писать тот же разговор в `v4/listen`, пока
// облако шлёт туда же обе дорожки звонка под своим call_id. Бэкенд не дедуплицирует
// ничего — на один звонок выходит ДВА разговора, в одном мои слова, в другом собеседника
// (измерено, полоса 6 тик 22, `marathon/tools/vox-dual-session-probe.py`, случай ambient).
// На Android две записи ещё и дерутся за микрофон, и проигравший пишет тишину.
//
// Проверяется здесь ИМЕННО возврат: забытый выход оставляет телефон глухим до конца
// сессии и молча. В провайдере такое видно только с телефоном в руках, здесь — без.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:omi/backend/schema/phone_call.dart';
import 'package:omi/services/capture/ambient_capture_hold.dart';
import 'package:omi/services/mic/mic_arbiter.dart';

/// Записывает, что гейт просили сделать, и (по требованию) даёт задержать ответ.
class _RecordingGate {
  final List<bool> calls = [];
  Completer<void>? pending;
  Object? throwOnNext;

  Future<void> call(bool paused) async {
    calls.add(paused);
    final err = throwOnNext;
    if (err != null) {
      throwOnNext = null;
      throw err;
    }
    final block = pending;
    if (block != null) {
      pending = null;
      await block.future;
    }
  }
}

AmbientCaptureHold _holdWith(_RecordingGate gate) => AmbientCaptureHold()..gate = gate.call;

void main() {
  group('какие состояния держат микрофон', () {
    test('держат ровно те три, в которых звонок жив', () {
      final owning = PhoneCallState.values.where(callOwnsMicrophone).toSet();
      expect(owning, {PhoneCallState.connecting, PhoneCallState.ringing, PhoneCallState.active});
    });

    // Не украшение первого: он говорит про сегодняшний список, этот — про правило.
    // Любое состояние, из которого звонка уже нет, ОБЯЗАНО отпускать микрофон, иначе
    // телефон остаётся глухим до конца сессии.
    test('каждое состояние без звонка отпускает микрофон', () {
      for (final state in [PhoneCallState.idle, PhoneCallState.ended, PhoneCallState.failed]) {
        expect(callOwnsMicrophone(state), isFalse, reason: '$state оставляет телефон глухим');
      }
    });
  });

  group('обычный ход звонка', () {
    test('нормальный звонок = одна пауза и один возврат', () async {
      final gate = _RecordingGate();
      final hold = _holdWith(gate);

      for (final state in [
        PhoneCallState.connecting,
        PhoneCallState.ringing,
        PhoneCallState.active,
        PhoneCallState.ended,
        PhoneCallState.idle,
      ]) {
        hold.onCallState(state);
        await hold.settled();
      }

      expect(gate.calls, [true, false]);
      expect(hold.held, isFalse);
    });

    test('отказ облака (failed) возвращает микрофон', () async {
      final gate = _RecordingGate();
      final hold = _holdWith(gate);

      hold.onCallState(PhoneCallState.connecting);
      hold.onCallState(PhoneCallState.failed);
      await hold.settled();

      expect(gate.calls, [true, false]);
      expect(hold.held, isFalse);
    });

    test('отказ ДО набора (connecting → idle) тоже возвращает', () async {
      final gate = _RecordingGate();
      final hold = _holdWith(gate);

      hold.onCallState(PhoneCallState.connecting);
      hold.onCallState(PhoneCallState.idle);
      await hold.settled();

      expect(gate.calls, [true, false]);
    });

    test('конец звонка приходит несколько раз — возврат один', () async {
      final gate = _RecordingGate();
      final hold = _holdWith(gate);

      hold.onCallState(PhoneCallState.connecting);
      hold.onCallState(PhoneCallState.active);
      hold.onCallState(PhoneCallState.ended);
      hold.onCallState(PhoneCallState.idle);
      hold.onCallState(PhoneCallState.idle);
      await hold.settled();

      expect(gate.calls, [true, false]);
    });

    test('второй звонок подряд снова паузит', () async {
      final gate = _RecordingGate();
      final hold = _holdWith(gate);

      for (final state in [PhoneCallState.connecting, PhoneCallState.active, PhoneCallState.idle]) {
        hold.onCallState(state);
      }
      hold.onCallState(PhoneCallState.connecting);
      await hold.settled();

      expect(gate.calls, [true, false, true]);
      expect(hold.held, isTrue);
    });
  });

  group('гонки и отказы', () {
    // Ради этого settled() и существует: SDK берёт микрофон нативно, и запись, всё ещё
    // державшая его в этот момент, — ровно та драка, от которой пауза и заводилась.
    test('settled() ждёт незавершённую паузу', () async {
      final gate = _RecordingGate();
      final hold = _holdWith(gate);
      final block = Completer<void>();
      gate.pending = block;

      hold.onCallState(PhoneCallState.connecting);
      var settled = false;
      unawaited(hold.settled().then((_) => settled = true));
      await Future<void>.delayed(Duration.zero);
      expect(settled, isFalse, reason: 'набор пошёл бы, пока микрофон ещё занят записью');

      block.complete();
      await hold.settled();
      expect(settled, isTrue);
    });

    // Если возврат обгонит паузу, телефон останется приглушённым НАВСЕГДА: пауза ляжет
    // последней и отпускать её будет уже некому.
    test('звонок, оборвавшийся во время своей же паузы, возвращает микрофон ПОСЛЕ неё', () async {
      final gate = _RecordingGate();
      final hold = _holdWith(gate);
      final block = Completer<void>();
      gate.pending = block;

      hold.onCallState(PhoneCallState.connecting);
      await Future<void>.delayed(Duration.zero); // пауза дошла до гейта и там встала
      hold.onCallState(PhoneCallState.failed);
      await Future<void>.delayed(Duration.zero);
      expect(gate.calls, [true], reason: 'возврат не имеет права начаться раньше паузы');

      block.complete();
      await hold.settled();
      expect(gate.calls, [true, false]);
      expect(hold.held, isFalse);
    });

    test('упавшая пауза не мешает возврату', () async {
      final gate = _RecordingGate();
      final hold = _holdWith(gate);
      gate.throwOnNext = StateError('recorder is busy');

      hold.onCallState(PhoneCallState.connecting);
      await hold.settled();
      hold.onCallState(PhoneCallState.idle);
      await hold.settled();

      expect(gate.calls, [true, false]);
    });

    test('без гейта состояние всё равно отслеживается и ничего не падает', () async {
      final hold = AmbientCaptureHold();

      hold.onCallState(PhoneCallState.active);
      await hold.settled();
      expect(hold.held, isTrue);

      hold.onCallState(PhoneCallState.ended);
      await hold.settled();
      expect(hold.held, isFalse);
    });
  });

  // Гейт выше глушит только фоновую запись. ВТОРОЙ микрофонный стек — голосовая заметка
  // в чате и профиль голоса — про звонок не знает вовсе: запущенный посреди звонка, он
  // получит микрофон, который SDK звонка уже держит нативно, запишет тишину и отчитается
  // успехом. Отказ живёт в арбитре, и берётся он здесь.
  group('микрофонный токен на время звонка', () {
    test('вето поднято раньше, чем гейт успел хоть что-то сделать', () async {
      final gate = _RecordingGate()..pending = Completer<void>();
      final arbiter = MicArbiter();
      final hold = _holdWith(gate)..arbiter = arbiter;

      hold.onCallState(PhoneCallState.connecting);

      // Ни одного await: набор ждёт settled(), а голосовая заметка не ждёт ничего —
      // вето обязано стоять уже к возврату из onCallState.
      expect(arbiter.callHolds, isTrue);
      expect(arbiter.tryAcquire('mic'), isFalse);
    });

    // Возврат фоновой записи сам идёт через арбитра. Сними вето после гейта — и звонок
    // откажет в микрофоне собственному возврату, то есть телефон останется глухим ровно
    // от той строки, которая должна была его вернуть.
    test('вето снято ДО возврата записи', () async {
      final gate = _RecordingGate();
      final arbiter = MicArbiter();
      bool? heldWhenResuming;
      final hold = AmbientCaptureHold()
        ..arbiter = arbiter
        ..gate = (paused) {
          if (!paused) heldWhenResuming = arbiter.callHolds;
          return gate.call(paused);
        };

      hold.onCallState(PhoneCallState.connecting);
      await hold.settled();
      hold.onCallState(PhoneCallState.idle);
      await hold.settled();

      expect(heldWhenResuming, isFalse, reason: 'возврат записи был бы отвергнут звонком');
      expect(arbiter.tryAcquire('conversation'), isTrue);
    });

    test('каждый выход из звонка отпускает токен', () async {
      for (final exit in [PhoneCallState.ended, PhoneCallState.failed, PhoneCallState.idle]) {
        final arbiter = MicArbiter();
        final hold = _holdWith(_RecordingGate())..arbiter = arbiter;

        hold.onCallState(PhoneCallState.connecting);
        hold.onCallState(exit);
        await hold.settled();

        expect(arbiter.callHolds, isFalse, reason: '$exit оставляет телефон глухим до конца сессии');
      }
    });

    test('упавший гейт не оставляет токен захваченным', () async {
      final gate = _RecordingGate();
      final arbiter = MicArbiter();
      final hold = _holdWith(gate)..arbiter = arbiter;

      hold.onCallState(PhoneCallState.connecting);
      await hold.settled();
      gate.throwOnNext = StateError('capture is gone');
      hold.onCallState(PhoneCallState.idle);
      await hold.settled();

      expect(arbiter.callHolds, isFalse);
      expect(arbiter.tryAcquire('mic'), isTrue);
    });

    test('без арбитра ничего не падает', () async {
      final hold = _holdWith(_RecordingGate());

      hold.onCallState(PhoneCallState.active);
      hold.onCallState(PhoneCallState.idle);
      await hold.settled();

      expect(hold.held, isFalse);
    });
  });
}
