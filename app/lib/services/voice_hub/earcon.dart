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

import 'progress_phrase_bank.g.dart';
import 'progress_phrases.dart';

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
    final player = await _newConversationPlayer(volume);
    try {
      await player.setAsset(asset);
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

/// Плеер, подмешивающийся к живой голосовой сессии, — общий для сигналов
/// ([Earcon]) и фраз-статусов ([ProgressVoice]); asset выставляет вызывающий.
///
/// handleAudioSessionActivation: false — КРИТИЧНО. Дефолтный AudioPlayer
/// при play() захватывает аудиофокус, и живой голосовой сокет умирает:
/// на телефоне обрыв сессии наступал через ~90 мс после старта вызова
/// ask_claude (логкат 24.08 03:31:45.528 запрос -> .619 обрыв). Звук
/// должен ПОДМЕШИВАТЬСЯ к сессии, а не отбирать у неё аудио.
///
/// Атрибуты РАЗГОВОРНОГО потока, не медиа (баг Игоря 24.08: «слышал один
/// раз в начале, после похода в Claude — тишина навсегда»). Медиа-звук
/// посреди живой сессии переключал Bluetooth с разговорного профиля (SCO)
/// на музыкальный (A2DP) — разговорный маршрут к гарнитуре рушился, и
/// весь дальнейший голос ассистента уходил в никуда. Всё, что играет
/// поверх сессии, обязано играть тем же трактом, что и голос.
Future<AudioPlayer> _newConversationPlayer(double volume) async {
  final player = AudioPlayer(handleAudioSessionActivation: false);
  try {
    await player.setAndroidAudioAttributes(const AndroidAudioAttributes(
      usage: AndroidAudioUsage.voiceCommunication,
      contentType: AndroidAudioContentType.sonification,
    ));
    await player.setVolume(volume);
  } catch (_) {
    Earcon._disposeQuietly(player);
    rethrow;
  }
  return player;
}

/// Фразы о ходе работы блокирующего ask_claude (см. progress_phrases.dart):
/// «читаю файл», «спрашиваю память», «почти готово» — по типу активности,
/// который присылает мост, случайный вариант без повтора подряд.
///
/// Записанные файлы, а не TTS и не просьба к Gemini: пока висит tool call,
/// модель молчит и на клиентский текст (замер 24.08 — ждёт все результаты,
/// не говоря ни слова), а системный TTS играет медиатрактом и рвёт
/// разговорный Bluetooth-маршрут (та же история, что у сигналов выше).
/// Файлы — той же природы, что thinking.mp3, только голосом самой сессии
/// (Charon, генератор bridge/tools/gen_progress_phrases.py).
///
/// ОДИН плеер на весь банк (setAsset на каждую фразу, ~десятки мс на файл в
/// секунду-две), а не [Earcon] на каждый из 40 файлов: фраза ожидания не
/// требует мгновенности сигнала «услышал», а 40 декодированных плееров в
/// памяти — цена не по задаче.
class ProgressVoice {
  final ProgressPhraseBank bank;
  final double volume;

  ProgressVoice(this.bank, {this.volume = 1.0});

  AudioPlayer? _player;
  Future<AudioPlayer>? _preparing;

  /// Замок на время звучания — как у [Earcon.play]: фраза поверх фразы
  /// (таймер догнал долгий файл) пропускается, а не рвёт setAsset.
  bool _playing = false;

  /// Последняя произнесённая фраза — для лога и тестов.
  ProgressPhrase? lastSpoken;

  /// Прогрев плеера (атрибуты тракта) на старте голосового режима; сам файл
  /// выбирается в момент [play].
  Future<void> preload() async {
    try {
      await _ensurePlayer();
    } catch (e) {
      Logger.error('[ProgressVoice] не удалось подготовить плеер: $e');
      _release();
    }
  }

  Future<void> play(ClaudeActivity activity) async {
    if (_playing) {
      Logger.debug('[ProgressVoice] фраза ещё звучит — ${activity.name} пропущен');
      return;
    }
    final phrase = bank.pick(activity);
    if (phrase == null) {
      Logger.debug('[ProgressVoice] нет фраз для ${activity.name}');
      return;
    }
    _playing = true;
    try {
      final player = await _ensurePlayer();
      await player.setAsset(phrase.asset);
      lastSpoken = phrase;
      Logger.debug('[ProgressVoice] ${activity.name}: «${phrase.text}»');
      // play() у just_audio завершается по КОНЦУ файла; pause() после него
      // сбрасывает `playing`, иначе следующий play() был бы no-op (см. Earcon).
      await player.play();
      await player.pause();
    } catch (e) {
      Logger.error('[ProgressVoice] не удалось проиграть ${phrase.asset}: $e');
      _release();
    } finally {
      _playing = false;
    }
  }

  Future<AudioPlayer> _ensurePlayer() {
    final ready = _player;
    if (ready != null) return Future.value(ready);
    return _preparing ??= _newConversationPlayer(volume).then((player) {
      _player = player;
      return player;
    }).whenComplete(() => _preparing = null);
  }

  void _release() {
    final player = _player;
    _player = null;
    _preparing = null;
    if (player != null) Earcon._disposeQuietly(player);
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

/// Фразы о ходе блокирующего ask_claude (см. [ProgressVoice] и
/// `AskClaudeToolExecutor.onBlockingWait`): ответа нет ~5 с — фраза о том,
/// чем мозг занят сейчас, и дальше периодически, пока ответа нет. Заменяет
/// прежние thinking_wait.mp3 / thinking_wait_more.mp3 (чужой голос, всегда
/// одно и то же, с оценкой времени — жалоба Игоря 02.09).
final ProgressVoice progressVoice = ProgressVoice(ProgressPhraseBank(progressPhraseAssets), volume: 1.0);
