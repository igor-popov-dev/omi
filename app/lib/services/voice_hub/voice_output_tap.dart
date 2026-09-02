// Съём громкости с исходящего голоса — обёртка над [VoicePlayer].
//
// Почему обёртка, а не событие в `HubSessionEvents`: всё, что нужно
// огибающей, проходит ровно через плеер — чанки (`enqueuePcm16`), обрыв
// (`clear`) и обе границы речи (`onStarted`/`onDrained` в
// [VoicePlayerStartSpec]). Проброс тех же фактов через три слоя событий
// (session -> controller -> host) добавил бы по полю в каждый и ещё одно
// место, где их можно забыть связать.
//
// Фабрика подставляется только в production-сборке
// (`voice_hub_production.dart`), поэтому тесты хаба продолжают работать со
// своими фейковыми плеерами и ничего не знают об огибающей.
import 'dart:async';
import 'dart:typed_data';

import 'package:omi/services/voice_hub/hub_session.dart';
import 'package:omi/services/voice_hub/voice_output_envelope.dart';

/// Как часто двигается курсор огибающей. 20 мс (50 Гц) — вдвое чаще окна
/// огибающей, чтобы уровень не шагал ступеньками; на кадр это одно
/// умножение, дешевле, чем перерисовка, которую оно питает.
const Duration kVoiceEnvelopeTickInterval = Duration(milliseconds: 20);

/// Оборачивает [inner] так, чтобы всё проходящее через плеер попадало в
/// [envelope]. Таймер живёт ровно между «звук пошёл» и «буфер опустел»:
/// молчащая иконка не должна будить кадры.
VoicePlayerFactory envelopeTappedPlayerFactory(
  VoicePlayerFactory inner,
  VoiceOutputEnvelope envelope,
) {
  return (VoicePlayerStartSpec spec) async {
    final tap = _EnvelopeTap(envelope);
    final player = await inner(VoicePlayerStartSpec(
      onStarted: () {
        tap.start();
        spec.onStarted();
      },
      onDrained: () {
        tap.stop();
        spec.onDrained();
      },
      onAudioFocusLost: spec.onAudioFocusLost,
    ));
    return _TappedVoicePlayer(player, tap);
  };
}

class _EnvelopeTap {
  _EnvelopeTap(this.envelope);

  final VoiceOutputEnvelope envelope;
  Timer? _timer;

  void start() {
    envelope.noteSpeakingStart();
    _timer ??= Timer.periodic(kVoiceEnvelopeTickInterval, (_) {
      envelope.advance(kVoiceEnvelopeTickInterval.inMicroseconds / Duration.microsecondsPerSecond);
    });
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    envelope.noteSpeakingEnd();
    // один шаг после остановки, чтобы уровень поехал вниз, а не завис на
    // последнем значении до следующей реплики
    envelope.advance(kVoiceEnvelopeTickInterval.inMicroseconds / Duration.microsecondsPerSecond);
  }

  /// Barge-in: гасим сразу и не ждём `onDrained` — его при обрыве может и не
  /// быть, а уровень обязан упасть вместе со звуком.
  void cut() {
    _timer?.cancel();
    _timer = null;
    envelope.clear();
  }
}

class _TappedVoicePlayer implements VoicePlayer {
  _TappedVoicePlayer(this._inner, this._tap);

  final VoicePlayer _inner;
  final _EnvelopeTap _tap;

  @override
  void enqueuePcm16(Uint8List bytes) {
    _tap.envelope.push(bytes);
    _inner.enqueuePcm16(bytes);
  }

  @override
  void flush() => _inner.flush();

  @override
  void clear() {
    _tap.cut();
    _inner.clear();
  }

  @override
  void close() {
    _tap.cut();
    _inner.close();
  }
}
