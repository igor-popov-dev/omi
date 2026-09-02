// Фразы-статусы блокирующего ask_claude: «читаю файл», «спрашиваю память»,
// «почти готово» — вместо двух одинаковых записанных «подожди» (жалоба Игоря
// 02.09: чужой голос и всегда одно и то же).
//
// Откуда тип активности: мост (`bridge/ask_claude_bridge.py`, `Activity` /
// `classify_tool`) читает stream-json / SDK-события claude, видит имена
// инструментов (Read, Grep, Bash, Edit, WebSearch, mcp__memory__*, Agent…) и
// шлёт в тот же SSE-поток `/ask` событие `{"type": "progress", "activity":
// "<kind>", "tool": "<имя>"}`. Ключи `kind` здесь, в мосте и в манифесте
// генератора (`bridge/tools/progress_phrases.json`) — один контракт.
//
// Откуда звук: готовые mp3 голосом той же сессии (Charon — см.
// `gemini_hub_session.dart`, speechConfig), сгенерированные
// `bridge/tools/gen_progress_phrases.py` в `assets/sounds/progress/`; карта
// тип → файлы — `progress_phrase_bank.g.dart`. Играет их `ProgressVoice`
// (earcon.dart) тем же разговорным трактом, что и сигналы: модель во время
// tool call молчит, а системный TTS рвёт Bluetooth-маршрут (см. там).
import 'dart:math';

/// Чем мозг занят сейчас. Порядок и имена — wire-контракт с мостом
/// (`PROGRESS_KINDS`); неизвестное имя → [generic].
enum ClaudeActivity {
  think,
  search,
  read,
  run,
  edit,
  web,
  memory,
  agents,
  finishing,
  generic;

  static ClaudeActivity fromWire(String? name) {
    if (name == null) return ClaudeActivity.generic;
    for (final value in ClaudeActivity.values) {
      if (value.name == name) return value;
    }
    return ClaudeActivity.generic;
  }
}

/// Одна озвученная фраза: путь к asset-у и её текст (для лога).
class ProgressPhrase {
  final String asset;
  final String text;

  const ProgressPhrase(this.asset, this.text);

  @override
  String toString() => 'ProgressPhrase($text)';
}

/// Выбор фразы под активность: случайно, но не та же, что звучала в прошлый
/// раз — ни для этого типа, ни вообще последняя (повторный таймер ожидания
/// на той же активности должен дать ДРУГОЙ вариант, см. `AskClaudeToolExecutor`).
class ProgressPhraseBank {
  final Map<ClaudeActivity, List<ProgressPhrase>> phrases;
  final Random _random;
  final Map<ClaudeActivity, ProgressPhrase> _lastByActivity = {};
  ProgressPhrase? _lastSpoken;

  ProgressPhraseBank(this.phrases, {Random? random}) : _random = random ?? Random();

  /// Фраза для [activity]; `null`, если банк пуст совсем.
  /// У типа без своих файлов — общие фразы ([ClaudeActivity.generic]), а без
  /// них — «думаю» ([ClaudeActivity.think]: банк генерируется частями —
  /// у бесплатного ключа TTS 10 запросов в день); если у типа единственный
  /// вариант и он только что звучал — тоже запасные, чтобы не повторяться.
  ProgressPhrase? pick(ClaudeActivity activity) {
    for (final source in [activity, ClaudeActivity.generic, ClaudeActivity.think]) {
      final fresh = _fresh(source);
      if (fresh.isNotEmpty) return _choose(source, fresh);
    }
    // Не из чего выбирать без повтора — повторяем, чем молчать.
    for (final source in [activity, ClaudeActivity.generic, ClaudeActivity.think]) {
      final all = phrases[source] ?? const [];
      if (all.isNotEmpty) return _choose(source, all);
    }
    return null;
  }

  /// Варианты [activity], которые можно сказать сейчас: не последняя
  /// сказанная фраза вообще и (если вариантов больше одного) не последняя
  /// фраза этого типа — чтобы «читаю файл» → память → «читаю файл» тоже не
  /// повторялось слово в слово.
  List<ProgressPhrase> _fresh(ClaudeActivity activity) {
    final all = phrases[activity] ?? const [];
    final lastOfKind = all.length > 1 ? _lastByActivity[activity] : null;
    return all.where((p) => p != lastOfKind && p != _lastSpoken).toList();
  }

  ProgressPhrase _choose(ClaudeActivity activity, List<ProgressPhrase> pool) {
    final chosen = pool[_random.nextInt(pool.length)];
    _lastByActivity[activity] = chosen;
    _lastSpoken = chosen;
    return chosen;
  }
}
