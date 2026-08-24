// Звуковой сигнал «услышал» для голосового режима (просьба Игоря 24.08):
// на высоких уровнях эскалации модель молчит до ответа Claude (блокирующая
// доставка), и раньше единственным подтверждением была фраза «секунду,
// уточню» перед КАЖДЫМ ответом — когнитивный диссонанс. Теперь фразы нет,
// а факт «вопрос услышан, ответ едет» подтверждает короткий звук — тот же,
// что Игорь сделал для pixel-jarvis (assets/sounds/claude_ack.mp3, его файл).
//
// Fail-open: сигнал — вежливость, а не функция. Любая ошибка проигрывания
// логируется и глотается — живой разговор важнее звука.
import 'package:just_audio/just_audio.dart';

import 'package:omi/utils/logger.dart';

class AckEarcon {
  static const String _asset = 'assets/sounds/claude_ack.mp3';

  AudioPlayer? _player;

  Future<void> play() async {
    try {
      final player = _player ??= AudioPlayer();
      // setAsset на каждый вызов вместо seek(0): плеер мог быть в любом
      // состоянии (доигрывает прошлый сигнал, ошибка декодера) — свежая
      // загрузка короткого файла надёжнее и стоит десятки миллисекунд.
      await player.setAsset(_asset);
      await player.play();
    } catch (e) {
      Logger.debug('[AckEarcon] не удалось проиграть сигнал: $e');
    }
  }

  void dispose() {
    _player?.dispose();
    _player = null;
  }
}
