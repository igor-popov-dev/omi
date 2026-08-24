// Громкость речи ассистента для живой иконки (`OmiVoiceOrb`).
//
// Считать RMS в момент отправки чанка нельзя: `enqueuePcm16` кладёт аудио в
// нативный `AudioTrack` С ОПЕРЕЖЕНИЕМ — плеер держит подушку и играет чанк
// заметно позже, чем Dart его отдал. Нарисованная так огибающая обгоняла бы
// голос на длину буфера, и это видно глазом.
//
// Поэтому чанки не превращаются в «текущий уровень» сразу: они режутся на
// окна и складываются в очередь, а курсор по этой очереди двигает время —
// начиная с момента, когда нативный плеер сообщил, что РЕАЛЬНО заиграл
// (`onSpeakingStart` -> [noteSpeakingStart]).
//
// Класс намеренно без таймеров: время двигает вызывающий через [advance], и
// это единственное, что позволяет проверить синхронизацию тестом, а не на
// глаз. Таймер живёт снаружи (`VoiceOutputEnvelopePump`).
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

/// Формат вывода Gemini Live: 24 кГц, моно, 16 бит.
const int kVoiceOutputSampleRate = 24000;

/// Длина окна огибающей. 50 мс — компромисс: короче тонет в шуме отдельных
/// слогов, длиннее превращает дыхание иконки в кашу.
const double kVoiceEnvelopeWindowSeconds = 0.05;

/// Насколько быстро уровень идёт вверх и вниз. Атака короткая, спад мягкий:
/// иначе иконка дёргается на каждом слоге вместо того, чтобы дышать.
const double _kAttackSeconds = 0.045;
const double _kReleaseSeconds = 0.16;

class VoiceOutputEnvelope {
  VoiceOutputEnvelope();

  final ValueNotifier<double> level = ValueNotifier<double>(0);

  final List<double> _windows = [];
  double _cursorSeconds = 0;
  bool _playing = false;

  @visibleForTesting
  int get queuedWindows => _windows.length;

  @visibleForTesting
  bool get playing => _playing;

  /// Чанк PCM16 моно, как он уходит в нативный плеер.
  void push(Uint8List pcm16) {
    if (pcm16.lengthInBytes < 2) return;
    final samples = pcm16.buffer.asInt16List(pcm16.offsetInBytes, pcm16.lengthInBytes ~/ 2);
    final perWindow = (kVoiceOutputSampleRate * kVoiceEnvelopeWindowSeconds).round();

    for (var start = 0; start < samples.length; start += perWindow) {
      final end = math.min(start + perWindow, samples.length);
      var sum = 0.0;
      for (var i = start; i < end; i++) {
        final s = samples[i] / 32768.0;
        sum += s * s;
      }
      final rms = math.sqrt(sum / (end - start));
      // корень поднимает тихую речь до различимого размаха — та же кривая,
      // что у осциллограммы диктофона (`voice_recorder_provider.dart`)
      _windows.add(math.sqrt(rms).clamp(0.0, 1.0));
    }
  }

  /// Нативный плеер сообщил, что звук пошёл. С этого момента курсор двигается.
  void noteSpeakingStart() {
    _playing = true;
    _cursorSeconds = 0;
  }

  /// Речь кончилась (буфер опустел) — уровень плавно уходит в ноль.
  void noteSpeakingEnd() {
    _playing = false;
    _windows.clear();
    _cursorSeconds = 0;
  }

  /// Barge-in: всё, что не успело прозвучать, не прозвучит уже никогда.
  ///
  /// В отличие от [noteSpeakingEnd] уровень гасится СРАЗУ, без мягкого спада:
  /// пользователь нажал «замолчи», звук оборвался мгновенно — иконка, которая
  /// после этого ещё полсекунды дышит, выглядит так, будто прерывание не
  /// сработало.
  void clear() {
    noteSpeakingEnd();
    level.value = 0;
  }

  /// Двигает время. [dtSeconds] — сколько прошло с прошлого вызова.
  void advance(double dtSeconds) {
    if (dtSeconds <= 0) return;

    var target = 0.0;
    if (_playing) {
      _cursorSeconds += dtSeconds;
      final index = _cursorSeconds ~/ kVoiceEnvelopeWindowSeconds;
      // индекс за концом очереди — плеер обогнал то, что нам прислали:
      // тишина честнее, чем застывший на последнем окне уровень
      if (index >= 0 && index < _windows.length) target = _windows[index];
    }

    final tau = target > level.value ? _kAttackSeconds : _kReleaseSeconds;
    final k = 1 - math.exp(-dtSeconds / tau);
    final next = level.value + (target - level.value) * k;
    // Экспоненциальный спад к нулю не приходит никогда, а хвост в тысячные
    // доли держит иконку в перерисовке и не виден. 0.004 — примерно 0.4%
    // размаха, на глаз это уже ноль.
    level.value = next < 0.004 ? 0 : next;
  }

  void dispose() {
    level.dispose();
  }
}
