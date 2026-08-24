// Звуковые сигналы голосового режима (просьбы Игоря 24.08, файлы — его же,
// эпохи pixel-jarvis):
//   assets/sounds/voice_start.mp3 — «голосовой режим включён» (старт разговора);
//   assets/sounds/thinking.mp3 — «услышал, думаю»: момент блокирующего вызова
//   ask_claude, вместо фразы «секунду, уточню» (слышать её перед каждым
//   ответом на правом крае ползунка было невыносимо). Играет ТИШЕ стартового:
//   он звучит рядом с голосом ассистента и не должен его перекрикивать
//   (медиаканал субъективно громче канала связи — потому 0.25, а не 0.5).
//
// Fail-open: сигнал — вежливость, а не функция. Любая ошибка проигрывания
// логируется и глотается — живой разговор важнее звука.
import 'package:just_audio/just_audio.dart';

import 'package:omi/utils/logger.dart';

class Earcon {
  final String asset;

  /// Громкость 0..1. Медиаканал, которым играет сигнал, субъективно громче
  /// канала связи, которым говорит ассистент, — подбирается на слух.
  final double volume;

  Earcon(this.asset, {this.volume = 0.5});

  AudioPlayer? _player;

  Future<void> play() async {
    try {
      // handleAudioSessionActivation: false — КРИТИЧНО. Дефолтный AudioPlayer
      // при play() захватывает аудиофокус, и живой голосовой сокет умирает:
      // на телефоне обрыв сессии наступал через ~90 мс после старта вызова
      // ask_claude (логкат 24.08 03:31:45.528 запрос -> .619 обрыв). Сигнал
      // должен ПОДМЕШИВАТЬСЯ к сессии, а не отбирать у неё звук.
      final player = _player ??= AudioPlayer(handleAudioSessionActivation: false);
      // setAsset на каждый вызов вместо seek(0): плеер мог быть в любом
      // состоянии (доигрывает прошлый сигнал, ошибка декодера) — свежая
      // загрузка короткого файла надёжнее и стоит десятки миллисекунд.
      await player.setAsset(asset);
      await player.setVolume(volume);
      await player.play();
    } catch (e) {
      Logger.debug('[Earcon] не удалось проиграть $asset: $e');
    }
  }

  void dispose() {
    _player?.dispose();
    _player = null;
  }
}

/// «Голосовой режим включён» — играет на старте разговора.
final Earcon voiceStartEarcon = Earcon('assets/sounds/voice_start.mp3');

/// «Услышал, думаю» — момент блокирующего вызова ask_claude. Вдвое тише
/// стартового (просьба Игоря 24.08: не перекрикивать голос ассистента).
final Earcon thinkingEarcon = Earcon('assets/sounds/thinking.mp3', volume: 0.25);
