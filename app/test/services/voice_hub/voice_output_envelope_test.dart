// Огибающая громкости ассистента: главное здесь — что уровень НЕ появляется
// раньше звука. Чанки уходят в нативный плеер с опережением, и вся суть
// класса в том, что курсор двигает время воспроизведения, а не приход чанка.
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:omi/services/voice_hub/voice_output_envelope.dart';

/// Ровный тон заданной амплитуды длиной [seconds].
Uint8List _tone(double amplitude, double seconds) {
  final count = (kVoiceOutputSampleRate * seconds).round();
  final samples = Int16List(count);
  for (var i = 0; i < count; i++) {
    samples[i] = (math.sin(2 * math.pi * 220 * i / kVoiceOutputSampleRate) * amplitude * 32767).round();
  }
  return samples.buffer.asUint8List();
}

/// Прокручивает время шагами по 20 мс — как это делает насос в проде.
void _run(VoiceOutputEnvelope envelope, double seconds) {
  const step = 0.02;
  for (var t = 0.0; t < seconds; t += step) {
    envelope.advance(step);
  }
}

void main() {
  test('чанки, отданные до старта плеера, не поднимают уровень', () {
    final envelope = VoiceOutputEnvelope();
    addTearDown(envelope.dispose);

    envelope.push(_tone(0.8, 1.0));
    _run(envelope, 0.5);

    // плеер ещё не заиграл — иконка обязана молчать, хотя аудио уже у него
    expect(envelope.level.value, 0);
    expect(envelope.queuedWindows, greaterThan(0));
  });

  test('после старта уровень идёт за громкостью чанка', () {
    final envelope = VoiceOutputEnvelope();
    addTearDown(envelope.dispose);

    envelope.push(_tone(0.8, 1.0));
    envelope.noteSpeakingStart();
    _run(envelope, 0.3);

    expect(envelope.level.value, greaterThan(0.3));
  });

  test('тихая речь даёт уровень ниже громкой', () {
    double levelFor(double amplitude) {
      final envelope = VoiceOutputEnvelope();
      addTearDown(envelope.dispose);
      envelope.push(_tone(amplitude, 1.0));
      envelope.noteSpeakingStart();
      _run(envelope, 0.3);
      return envelope.level.value;
    }

    expect(levelFor(0.15), lessThan(levelFor(0.9)));
  });

  // Курсор идёт по очереди во времени: вторая секунда речи должна звучать
  // тише первой, если такой её прислали, — иначе «синхронность» держится
  // только на том, что чанки приходят вовремя.
  test('уровень следует за формой очереди во времени', () {
    final envelope = VoiceOutputEnvelope();
    addTearDown(envelope.dispose);

    envelope.push(_tone(0.9, 0.6));
    envelope.push(_tone(0.05, 0.6));
    envelope.noteSpeakingStart();

    _run(envelope, 0.3);
    final loudPart = envelope.level.value;
    _run(envelope, 0.6);
    final quietPart = envelope.level.value;

    expect(loudPart, greaterThan(quietPart));
  });

  test('когда очередь кончилась, уровень уходит в ноль', () {
    final envelope = VoiceOutputEnvelope();
    addTearDown(envelope.dispose);

    envelope.push(_tone(0.9, 0.2));
    envelope.noteSpeakingStart();
    _run(envelope, 0.2);
    expect(envelope.level.value, greaterThan(0));

    _run(envelope, 1.0);
    expect(envelope.level.value, 0);
  });

  // Barge-in: недосказанное не должно продолжать дышать в иконке.
  test('clear гасит уровень и выбрасывает очередь', () {
    final envelope = VoiceOutputEnvelope();
    addTearDown(envelope.dispose);

    envelope.push(_tone(0.9, 2.0));
    envelope.noteSpeakingStart();
    _run(envelope, 0.3);
    expect(envelope.level.value, greaterThan(0));

    envelope.clear();
    _run(envelope, 0.5);

    expect(envelope.level.value, 0);
    expect(envelope.queuedWindows, 0);
    expect(envelope.playing, isFalse);
  });

  test('спад мягче атаки', () {
    final envelope = VoiceOutputEnvelope();
    addTearDown(envelope.dispose);

    envelope.push(_tone(0.9, 0.3));
    envelope.noteSpeakingStart();
    _run(envelope, 0.1);
    final afterAttack = envelope.level.value;

    envelope.noteSpeakingEnd();
    envelope.advance(0.1);
    final afterSameTimeOfRelease = envelope.level.value;

    // за одинаковое время спад проходит меньшую долю пути, чем атака
    expect(afterSameTimeOfRelease / afterAttack, greaterThan(0.2));
  });

  test('пустой и слишком короткий чанк не ломают разбор', () {
    final envelope = VoiceOutputEnvelope();
    addTearDown(envelope.dispose);

    envelope.push(Uint8List(0));
    envelope.push(Uint8List(1));

    expect(envelope.queuedWindows, 0);
  });
}
