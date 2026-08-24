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
import 'package:audio_session/audio_session.dart';
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
      // Атрибуты РАЗГОВОРНОГО потока, не медиа (баг Игоря 24.08: «слышал один
      // раз в начале, после похода в Claude — тишина навсегда»). Медиа-звук
      // посреди живой сессии переключал Bluetooth с разговорного профиля (SCO)
      // на музыкальный (A2DP) — разговорный маршрут к гарнитуре рушился, и
      // весь дальнейший голос ассистента уходил в никуда. Сигнал обязан играть
      // тем же трактом, что и голос.
      await player.setAndroidAudioAttributes(const AndroidAudioAttributes(
        usage: AndroidAudioUsage.voiceCommunication,
        contentType: AndroidAudioContentType.sonification,
      ));
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
///
/// Обе громкости подняты до 1.0 (просьба Игоря 24.08 вечером): прежние
/// 0.5/0.25 подбирались в «тихую эпоху», когда сам голос играл придушенным
/// не-звонковым usage; после перевода голоса в звонковый тракт (846287ef56)
/// сигналы на его фоне стали едва слышны.
final Earcon voiceStartEarcon = Earcon('assets/sounds/voice_start.mp3', volume: 1.0);

/// «Услышал, думаю» — момент блокирующего вызова ask_claude.
final Earcon thinkingEarcon = Earcon('assets/sounds/thinking.mp3', volume: 1.0);
