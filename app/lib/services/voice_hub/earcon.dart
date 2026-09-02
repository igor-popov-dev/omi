// Звуковые сигналы голосового режима (просьбы Игоря 24.08, файлы — его же,
// эпохи pixel-jarvis):
//   assets/sounds/voice_start.mp3 — «голосовой режим включён» (старт разговора);
//   assets/sounds/thinking.mp3 — «услышал, думаю»: конец фразы пользователя
//   (`free_form_voice_mode_projection.dart`, дебаунс по VAD) и старт
//   блокирующего вызова ask_claude — вместо фразы «секунду, уточню» (слышать
//   её перед каждым ответом на правом крае ползунка было невыносимо).
//
// Fail-open: сигнал — вежливость, а не функция. Любая ошибка проигрывания
// логируется и глотается — живой разговор важнее звука.
import 'dart:async';

import 'package:audio_session/audio_session.dart';
import 'package:just_audio/just_audio.dart';

import 'package:omi/utils/logger.dart';

class Earcon {
  final String asset;

  /// Громкость 0..1. Медиаканал, которым играет сигнал, субъективно громче
  /// канала связи, которым говорит ассистент, — подбирается на слух.
  final double volume;

  Earcon(this.asset, {this.volume = 0.5});

  /// Готовый плеер: атрибуты тракта выставлены, файл декодирован.
  AudioPlayer? _player;

  /// Идущий прогрев — параллельные [preload]/[play] делят один и тот же.
  Future<AudioPlayer>? _preloading;

  /// Замок на время звучания: второй [play] поверх первого игнорируется.
  /// Раньше параллельные вызовы (несколько functionCalls в одном кадре
  /// toolCall) рвали друг другу setAsset/play, исключение глоталось — и
  /// сигнала не было вовсе.
  bool _playing = false;

  /// Прогрев на старте голосового режима. Холодный [play] — создание плеера,
  /// атрибуты, декодирование файла — стоил сотни миллисекунд, и сигнал
  /// опаздывал к моменту, ради которого существует. Повторный вызов на
  /// готовом плеере — no-op; ошибка логируется, следующий [play] прогреет
  /// заново.
  Future<void> preload() async {
    try {
      await _ensureLoaded();
    } catch (e) {
      Logger.error('[Earcon] не удалось подготовить $asset: $e');
      _release();
    }
  }

  Future<void> play() async {
    if (_playing) {
      Logger.debug('[Earcon] $asset уже звучит — повторный вызов пропущен');
      return;
    }
    _playing = true;
    try {
      final player = await _ensureLoaded();
      // Тёплый путь: только перемотка и старт, без setAsset на каждый вызов.
      await player.seek(Duration.zero);
      // play() у just_audio завершается по КОНЦУ файла — всё это время
      // держится замок [_playing].
      await player.play();
      // После конца файла just_audio оставляет `playing == true`: без паузы
      // следующий play() был бы no-op, а seek(0) запускал бы звук сам, мимо
      // замка. pause() сбрасывает флаг, буферы остаются.
      await player.pause();
    } catch (e) {
      Logger.error('[Earcon] не удалось проиграть $asset: $e');
      // Плеер мог остаться в любом состоянии (ошибка декодера) — сбросить,
      // следующий вызов создаст свежий.
      _release();
    } finally {
      _playing = false;
    }
  }

  Future<AudioPlayer> _ensureLoaded() {
    final ready = _player;
    if (ready != null) return Future.value(ready);
    return _preloading ??= _load().whenComplete(() => _preloading = null);
  }

  Future<AudioPlayer> _load() async {
    // handleAudioSessionActivation: false — КРИТИЧНО. Дефолтный AudioPlayer
    // при play() захватывает аудиофокус, и живой голосовой сокет умирает:
    // на телефоне обрыв сессии наступал через ~90 мс после старта вызова
    // ask_claude (логкат 24.08 03:31:45.528 запрос -> .619 обрыв). Сигнал
    // должен ПОДМЕШИВАТЬСЯ к сессии, а не отбирать у неё звук.
    final player = AudioPlayer(handleAudioSessionActivation: false);
    try {
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
      await player.setAsset(asset);
      await player.setVolume(volume);
    } catch (_) {
      _disposeQuietly(player);
      rethrow;
    }
    _player = player;
    return player;
  }

  void _release() {
    final player = _player;
    _player = null;
    _preloading = null;
    if (player != null) _disposeQuietly(player);
  }

  static void _disposeQuietly(AudioPlayer player) {
    unawaited(player.dispose().catchError((Object e) {
      Logger.debug('[Earcon] ошибка при освобождении плеера: $e');
    }));
  }

  void dispose() => _release();
}

/// «Голосовой режим включён» — играет на старте разговора.
///
/// Обе громкости подняты до 1.0 (просьба Игоря 24.08 вечером): прежние
/// 0.5/0.25 подбирались в «тихую эпоху», когда сам голос играл придушенным
/// не-звонковым usage; после перевода голоса в звонковый тракт (846287ef56)
/// сигналы на его фоне стали едва слышны.
final Earcon voiceStartEarcon = Earcon('assets/sounds/voice_start.mp3', volume: 1.0);

/// «Услышал, думаю» — конец фразы пользователя и старт блокирующего вызова
/// ask_claude.
final Earcon thinkingEarcon = Earcon('assets/sounds/thinking.mp3', volume: 1.0);

/// Голосовой комментарий о задержке блокирующего ask_claude (см.
/// `AskClaudeToolExecutor.onBlockingWaitLong`): ответа нет ~5 с — «Секунду,
/// думаю, это займёт секунд пятнадцать-двадцать». Записанный файл, а не TTS
/// и не просьба к Gemini: пока висит tool call, модель молчит и на клиентский
/// текст (замер 24.08 — ждёт все результаты, не говоря ни слова), а системный
/// TTS играет медиатрактом и рвёт разговорный Bluetooth-маршрут (та же
/// история, что у сигналов выше). Файл — той же природы, что thinking.mp3.
final Earcon thinkingWaitEarcon = Earcon('assets/sounds/thinking_wait.mp3', volume: 1.0);

/// Повтор ещё через ~20 с ожидания — «Ещё немного, почти готово».
final Earcon thinkingWaitMoreEarcon = Earcon('assets/sounds/thinking_wait_more.mp3', volume: 1.0);
