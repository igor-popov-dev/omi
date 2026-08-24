// Ползунок «как часто Gemini Live ходит к старшей модели (Claude Opus 5)» —
// просьба Игоря 24.08. Пять дискретных уровней, от «чистый Gemini Live» до
// «каждый содержательный ответ через Claude». Self-host патч, в upstream не
// отдавать (мост ask_claude — приватный клей, PLAN.md §4).
//
// Как уровень действует (оба рычага читаются при КАЖДОМ открытии сессии хаба —
// `HubController` зовёт `buildInstructions()`/`fetchTools()` на warm, поэтому
// смена уровня применяется со следующего запуска голосового режима, без
// пересборки):
//   1. Инструкции сессии (`hubInstructionsForLevel`) — насколько настойчиво
//      модель отправляют к инструменту ask_claude.
//   2. Каталог инструментов (`hubToolsForLevel`) — крайний левый уровень
//      обеспечен СТРУКТУРНО: инструмент в сессию не передаётся вовсе, эскалация
//      физически невозможна, а не «вежливо запрещена» промптом.
// Правый край (fullProxy) в v1 держится на промпте + описании инструмента;
// если Gemini будет «забывать» — v2: детерминированная авторутизация в
// VoiceTurnDriver (см. WORKLOG 24.08).
//
// Хранение: `SharedPreferencesUtil().claudeEscalationLevel` (int 0..4,
// дефолт 2 = balanced — ровно то поведение, что было до ползунка). UI:
// длинное нажатие на кнопку голосового режима в чате + строка в
// Settings → Developer.
import 'package:omi/backend/preferences.dart';

import 'ask_claude_tool.dart';
import 'hub_session.dart' show VoiceToolDeclaration;

/// Пять положений ползунка, слева направо. Индексы стабильны — они лежат в
/// SharedPreferences; новые уровни добавлять только в конец.
enum ClaudeEscalationLevel {
  /// Чистый Gemini Live: инструмента ask_claude в сессии нет вообще.
  geminiOnly,

  /// Claude — только по явной просьбе пользователя («спроси Клода», «уточни
  /// у старшей модели»).
  onRequest,

  /// Дефолт (поведение до ползунка): память, факты о пользователе, сложные
  /// рассуждения — к Claude, остальное Gemini ведёт сам.
  balanced,

  /// Агрессивно: Gemini сам отвечает только на смолток и мгновенные реплики,
  /// всё содержательное — к Claude.
  aggressive,

  /// Полный прокси: каждый содержательный ответ — от Claude, Gemini — голос
  /// и уши разговора.
  fullProxy;

  /// Безопасное чтение из хранилища: мусорный индекс (старая версия, ручная
  /// правка prefs) откатывается на [balanced], а не роняет сессию.
  static ClaudeEscalationLevel fromIndex(int index) =>
      (index >= 0 && index < ClaudeEscalationLevel.values.length) ? ClaudeEscalationLevel.values[index] : balanced;

  /// Короткое имя для UI ползунка.
  String get label => switch (this) {
        geminiOnly => 'Только Gemini',
        onRequest => 'По просьбе',
        balanced => 'Сбалансированно',
        aggressive => 'Чаще Claude',
        fullProxy => 'Всё через Claude',
      };

  /// Одна строка для UI: что уровень означает на практике.
  String get hint => switch (this) {
        geminiOnly => 'Быстрые ответы, но без памяти omi и инструментов.',
        onRequest => 'Claude подключается, только если попросить вслух.',
        balanced => 'Память и сложное — Claude, остальное Gemini сам.',
        aggressive => 'Gemini оставляет себе только смолток.',
        fullProxy => 'Каждый ответ думает Claude (~4–8 с на круг).',
      };

  /// Блокирующая доставка ask_claude для высоких уровней (идея 1 из WORKLOG
  /// 24.08 ~02:50, решение Игоря вернуть ползунок 24.08 ~03:30): модель
  /// говорит «секунду» и МОЛЧИТ до ответа — самодеятельность исключена
  /// механикой, а не просьбой. На низких уровнях эскалация редка, и
  /// неблокирующая доставка (разговор продолжается, ответ вливается позже,
  /// устаревший отбрасывается single-flight'ом) удобнее честной паузы.
  /// Честная пауза с тёплым мостом — ~4–8 с (замер 24.08 ~02:35).
  bool get blockingDelivery => switch (this) {
        geminiOnly || onRequest || balanced => false,
        aggressive || fullProxy => true,
      };
}

/// Ползунок ВОЗВРАЩЁН (решение Игоря 24.08 ~03:30) после лечения «раздвоения»:
/// single-flight + адресные ответы (идея 3), тёплый мост ~4–8 с на круг
/// (идея 4) и блокирующая доставка на высоких уровнях (идея 1,
/// [ClaudeEscalationLevel.blockingDelivery]). История скрытия — WORKLOG
/// 24.08 ~02:50.
const bool claudeEscalationSliderEnabled = true;

/// Текущий уровень из настроек; без инициализированных prefs (юнит-тесты)
/// честно падает в дефолт — `getInt` возвращает defaultValue (balanced).
/// Флаг-выключатель оставлен как аварийный рубильник: с false уровень снова
/// прибивается к balanced, UI прячется.
ClaudeEscalationLevel currentClaudeEscalationLevel() => claudeEscalationSliderEnabled
    ? ClaudeEscalationLevel.fromIndex(SharedPreferencesUtil().claudeEscalationLevel)
    : ClaudeEscalationLevel.balanced;

// Общая голосовая персона — начало инструкций на всех уровнях.
const String _kPersona = 'You are Omi, a warm and concise voice assistant running on the '
    "user's phone. Speak naturally and briefly, like a helpful friend, not a chatbot reading a list. ";

// Правило порядка «филлер вслух → вызов» — для НЕблокирующих уровней (там
// модель продолжает говорить, и фраза уместна). Причина в тексте: вызов —
// это секунды тишины.
const String _kFillerRule = 'ORDER MATTERS: FIRST say a short filler out loud — in Russian say exactly '
    '"секунду, уточню" — and only THEN call the tool. The call itself is seconds of silence, '
    'so a filler spoken after the result lands is useless — the user has already sat through '
    'the wait wondering whether you heard them at all.';

// Блокирующие уровни: филлер ЗАПРЕЩЁН — слышать «секунду, уточню» перед каждым
// ответом невыносимо (жалоба Игоря 24.08). Подтверждение «услышал» даёт сам
// телефон коротким звуковым сигналом в момент вызова (earcon.dart), модели
// говорить ничего не нужно.
const String _kChimeRule = 'Do NOT announce the call and do NOT say filler phrases like "секунду" or '
    '"сейчас уточню" — the phone automatically plays a short chime the moment you call the tool, '
    'so the user already knows they were heard. Call the tool silently; when the result arrives, '
    'just speak the answer itself.';

/// Инструкции сессии для уровня. Чистая функция — тестируется без prefs.
String hubInstructionsForLevel(ClaudeEscalationLevel level) => switch (level) {
      ClaudeEscalationLevel.geminiOnly => '$_kPersona'
          'Answer everything yourself from the conversation and general knowledge. You have no '
          'tools this session — never mention consulting another model, and if the user asks for '
          "something that clearly needs their personal data you don't have, say so honestly in one "
          'short sentence.',
      ClaudeEscalationLevel.onRequest => '$_kPersona'
          'Handle the whole conversation yourself. Call the ask_claude tool ONLY when the user '
          'explicitly asks to consult Claude / the smart model in that same turn (e.g. «спроси '
          'Клода», «уточни у умной модели»). Never call it on your own initiative. $_kFillerRule',
      ClaudeEscalationLevel.balanced => '$_kPersona'
          'For anything that needs real reasoning, remembered context, or looking something up — '
          "rather than a quick reply you're confident in — use the ask_claude tool instead of "
          'guessing. $_kFillerRule',
      ClaudeEscalationLevel.aggressive => '$_kPersona'
          'You personally answer ONLY small talk and instant conversational replies. For anything '
          "factual, personal (the user's memory, health, food, calendar, mail), computational, or "
          'multi-step — call the ask_claude tool instead of answering yourself. When in doubt, '
          'call it. $_kChimeRule',
      ClaudeEscalationLevel.fullProxy => '$_kPersona'
          'You are the voice and ears of this conversation, NOT its brain. For EVERY substantive '
          'user message call the ask_claude tool and then speak its answer in your own natural '
          'voice. Do not compose substantive answers yourself — only greetings, acknowledgements '
          'and clarifying questions may be answered directly. $_kChimeRule',
    };

// Описание инструмента тоже меняется по уровню: Gemini решает, звать ли тул,
// во многом именно по description, и он не должен спорить с инструкциями
// сессии (до ползунка спорил: инструкции говорили «зови для сложного», а
// description — «только по явной просьбе»).
const String _kToolDescriptionHead = 'Задай вопрос "умной модели" (Claude Opus на подписке Игоря, со всеми его '
    'инструментами и MCP: память omi/mempalace, здоровье, питание, календарь, почта, файлы, веб) '
    'через приватный мост. ';
const String _kToolDescriptionTail = ' СНАЧАЛА вслух скажи ровно "секунду, уточню" и ТОЛЬКО ПОТОМ вызывай '
    'инструмент — вызов занимает несколько секунд, и фраза, сказанная после результата, '
    'бесполезна: пользователь уже отсидел паузу в тишине.';
// Хвост для блокирующих уровней — согласован с _kChimeRule: фраз не говорить,
// сигнал играет телефон.
const String _kToolDescriptionTailChime = ' НЕ объявляй вызов вслух и не говори "секунду" — телефон сам '
    'проигрывает короткий звуковой сигнал в момент вызова. Вызови инструмент молча и озвучь '
    'пришедший ответ.';

String _toolPolicyForLevel(ClaudeEscalationLevel level) => switch (level) {
      // geminiOnly до описания не доходит — инструмента нет в каталоге.
      ClaudeEscalationLevel.geminiOnly => '',
      ClaudeEscalationLevel.onRequest => 'Вызывай ТОЛЬКО по явной просьбе пользователя в этом же ходе разговора, '
          'никогда фоново/сам по себе.',
      ClaudeEscalationLevel.balanced => 'Вызывай, когда вопрос требует памяти, фактов о пользователе, многошаговых '
          'рассуждений или поиска. Не вызывай фоново, без реплики пользователя.',
      ClaudeEscalationLevel.aggressive => 'Вызывай для ЛЮБОГО фактического, личного, вычислительного или '
          'многошагового вопроса; сам отвечай только на смолток. Сомневаешься — вызывай.',
      ClaudeEscalationLevel.fullProxy => 'Вызывай на КАЖДУЮ содержательную реплику пользователя и озвучивай ответ '
          'своими словами. Сам не сочиняй содержательных ответов.',
    };

/// Каталог инструментов сессии для уровня. Чистая функция.
///
/// [geminiOnly] возвращает пустой список — это и есть структурная гарантия
/// левого края ползунка. Остальные уровни отдают ask_claude с политикой
/// вызова, согласованной с инструкциями сессии того же уровня.
List<VoiceToolDeclaration> hubToolsForLevel(ClaudeEscalationLevel level) {
  if (level == ClaudeEscalationLevel.geminiOnly) return const [];
  final tail = level.blockingDelivery ? _kToolDescriptionTailChime : _kToolDescriptionTail;
  return [
    VoiceToolDeclaration(
      name: askClaudeToolDeclaration.name,
      description: '$_kToolDescriptionHead${_toolPolicyForLevel(level)}$tail',
      parameters: askClaudeToolDeclaration.parameters,
    ),
  ];
}
