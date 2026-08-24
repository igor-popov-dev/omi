// Звуковые сигналы голосового режима (просьбы Игоря 24.08, файлы — его же,
// эпохи pixel-jarvis):
//   assets/sounds/thinking.mp3 — единственный сигнал: старт голосового режима
//   («включился») и момент блокирующего вызова ask_claude («услышал, думаю»,
//   вместо фразы «секунду, уточню» — слышать её перед каждым ответом на
//   правом крае ползунка было невыносимо).
//
// Fail-open: сигнал — вежливость, а не функция. Любая ошибка проигрывания
// логируется и глотается — живой разговор важнее звука.
import 'package:just_audio/just_audio.dart';

import 'package:omi/utils/logger.dart';

class Earcon {
  final String asset;

  Earcon(this.asset);

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
      // Вдвое тише (просьба Игоря 24.08): сигнал звучит поверх живого
      // разговора и на полной громкости перекрикивал голос.
      await player.setVolume(0.5);
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

/// Единственный сигнал (решение Игоря 24.08: везде thinking.mp3): играет и на
/// старте голосового режима («включился»), и в момент блокирующего вызова
/// ask_claude («услышал, думаю»).
final Earcon thinkingEarcon = Earcon('assets/sounds/thinking.mp3');
