# Self-host patches — реестр

Этот форк живёт на своём сервере (mac mini) и по подписке Claude, без платных сервисов,
которые предполагает upstream. Отсюда набор приватных правок, которые **никогда не уходят
в upstream** и должны переживать `git merge upstream/main`.

Файл существует ради одной цели: чтобы обновление из основного репозитория было дешёвым и
предсказуемым — видно, что именно наше, где оно лежит и что проверить после слияния.

## Правило, по которому пишется патч

1. **Логика — в отдельном файле, которого нет в upstream.** Такой файл не может конфликтовать
   при слиянии. Пример: `backend/utils/selfhost_retrieval.py`.
2. **В upstream-файле — минимальная врезка**, помеченная комментарием `Self-host patch`:
   импорт и короткий блок вызова. Чем меньше строк, тем тривиальнее разрешается конфликт.
3. **Каждая врезка объясняет ПОЧЕМУ**, а не что: через год причина важнее механики.
4. **Патч не ломает upstream-поведение при наличии сервисов** — он включается только тогда,
   когда штатный путь недоступен (fail-open), поэтому слияние никогда не «чинит» лишнего.

## Что делать после `git merge upstream/main`

- Прогнать `backend/test.sh` и `app/test.sh` — тесты патчей лежат рядом со штатными и
  падают первыми, если врезку затёрли.
- Пройтись по таблице ниже: убедиться, что маркеры `Self-host patch` на месте
  (`grep -rn "Self-host patch" backend/ app/lib/`).
- Отдельно проверить незакоммиченные пробросы окружения на mini (см. последний раздел) —
  они живут вне git и теряются молча.

## Реестр

| Область | Наш файл (конфликтов не даёт) | Врезки в upstream-файлы | Зачем |
|---|---|---|---|
| Поиск по разговорам | `backend/utils/selfhost_retrieval.py` | `backend/utils/retrieval/tool_services/conversations.py` — импорт + блок в `search_conversations_text`; `backend/utils/conversations/search.py` — импорт + блок в терминальной ветке `except` | Upstream ищет через Typesense + эмбеддинги. У нас нет ни того, ни другого: Typesense не настроен, а эмбеддинги — это второй платный вендор. Векторная нога стала необязательной (её падение больше не роняет весь инструмент), а отбор релевантного делает Claude, читая выборку. С 24.08 та же дыра закрыта и для экрана поиска в приложении: коллекции `conversations` в Typesense не существует, поэтому `POST /v1/conversations/search` отвечал 500 — теперь при отсутствующем индексе ответ собирается сканом базы (заголовок, обзор и **транскрипт**), а пустой результат остаётся пустым |
| Постобработка и память | — | `backend/utils/conversations/process_conversation.py`, `backend/utils/llm/clients.py` | Цепочка памяти и постобработка переведены с OpenAI на мост `claude-bridge` (подписка вместо ключа) |
| STT на устройстве | — | `app/lib/services/sockets/pure_polling.dart`, `transcription_polling_service.dart`, `app/lib/models/stt_provider.dart` | Свой STT-роутер на mini вместо облачного: адаптивное окно флаша, честная семантика отказов, буферизация офлайн |
| Адрес своего STT | — | `app/lib/env/env.dart` (`defaultSttUrl`), `app/lib/backend/preferences.dart` | Чистая установка должна сразу смотреть на наш роутер, а не на облако |
| Индикация записи | — | `app/lib/services/capture/stt_display_status.dart`, `capture_controller.dart`, `app/lib/pages/conversation_capturing/page.dart` | Видимое состояние распознавания вместо «Listening» без информации |
| Подпись сборки | — | `app/android/app/build.gradle` | Свой ключ подписи (`OMI_SELFHOST_SIGNING`) |
| Голосовой хаб | `app/lib/services/voice_hub/*`, `app/android/.../voiceplayer/*` | точки подключения в `main.dart`, `capture_controller.dart`, `pages/chat/` | Свободный голосовой режим (Gemini Live + Charon) и инструмент `ask_claude` — наш клей, в upstream не отдаём |
| Гарнитура в голосовом режиме | `app/android/.../voiceplayer/VoiceRouteCoordinator.kt` | `StreamingPcmPlayerController.kt` — поле + `engage()`/`release()` рядом с audio focus | `AudioSource.MIC` следует медийной маршрутизации, поэтому Bluetooth-наушники микрофон не отдавали: ответ звучал в ушах, а говорил человек в телефон. На время сессии звук уходит в режим связи и закрепляется за гарнитурой; область узкая — фоновая запись это не затрагивает |
| Голосовой диалог в чате | `app/lib/services/voice_hub/voice_chat_log.dart`, `backend/routers/selfhost_voice_log.py` | `backend/main.py` — одна строка `include_router`; `free_form_voice_mode_projection.dart`, `capture_controller.dart`, `main.dart` — проводка | Голос жил в своём сокете и не попадал в историю: два ассистента, каждый не знает о другом. Роут сохраняет уже произнесённые реплики дословно и НЕ генерирует ответ — обмен состоялся вслух |
| Неблокирующий `ask_claude` | `app/lib/services/voice_hub/ask_claude_tool.dart` (поле `announce`) | — | Пока не пришёл tool result, Gemini обязана молчать, поэтому круг к Opus был мёртвым эфиром (44 с, замер 23.08). Ход освобождается сразу, ответ приходит отдельной репликой и озвучивается |
| Устойчивость голосового режима | `capture_controller.dart` (`recoverFreeFormVoiceMode`), `hub_session.dart`/`gemini_hub_session.dart` (`sendUserText`) | `free_form_voice_mode_projection.dart` — ошибка доезжает с причиной | Обрыв гасил разговор молча, без слова вслух и без строчки в логе. Теперь сессия переподключается и объясняется голосом; три обрыва за две минуты — выключение, чтобы не жечь поминутную оплату |
| Выходы из записи голосового сообщения | — | `app/lib/pages/chat/widgets/voice_recorder_widget.dart` — крестик в состояниях `recording`, `transcribing`, `transcribeFailed` | Записи и расшифровке некуда было деться: единственной кнопкой была отправка, и зависшее распознавание блокировало композер намертво |
| Устный стиль и потолок ходов | `marathon/ask_claude_bridge.py` (флаг `voice`, `max_turns`) в штабе omi-jarvis | `voice_hub_production.dart` — `maxTurns`, `ask_claude_tool.dart` — `'voice': true` | Ответ читается вслух: две фразы, 50 слов, без списков. Потолок ходов — против агента, который уходит на 12 ходов и 90 секунд; пустой результат при обрыве превращается во фразу, а не в тишину |
| Пульт апстрим-синка | `backend/routers/selfhost_upstream_sync.py`, `app/lib/pages/conversations/widgets/upstream_sync_card.dart`, `app/lib/providers/upstream_sync_provider.dart`, `app/lib/backend/http/api/upstream_sync.dart` | `backend/main.py` — импорт + `include_router`; `app/lib/pages/conversations/conversations_page.dart` — одна плашка в списке | Upstream идёт по несколько десятков коммитов в день, и цена отставания растёт нелинейно: каждая полоса при вливании получает тем больше конфликтов, чем дольше не синкались. Механику делает `~/omi-jarvis/bin/omi-sync-upstream` (вне репозитория — он должен работать и когда сервер лежит), приложение только показывает отставание и даёт две кнопки: «синкать» и, отдельным подтверждением, «влить». В `private` пульт сам не пишет никогда |
| Локальные блобы на настоящем Firestore | `backend/tests/unit/test_selfhost_local_storage_optin.py` | `backend/utils/other/local_storage.py` — опт-ин `OMI_SELFHOST_LOCAL_STORAGE` перед проверкой эмулятора | Upstream разрешает `OMI_LOCAL_STORAGE_ROOT` только эмуляторному стенду (demo-проект + `FIRESTORE_EMULATOR_HOST`). У нас блобы лежат на диске mini при НАСТОЯЩЕМ Firestore, потому что GCS — платный вендор, которого в self-host нет; без локального корня профили голоса и загрузка файлов в чат отвечают 500. Проверка вложенности корня в состояние стенда сохранена — ослаблено только требование эмулятора. Цена ошибки известна: 24.08 эта проверка уронила бэкенд на mini прямо в импорте `main.py` |
| Чат без месячного потолка | `backend/utils/selfhost_chat_quota.py`, `backend/tests/unit/test_selfhost_chat_quota_optin.py` | `backend/utils/subscription.py` — импорт + две врезки: первой строкой `get_chat_quota_snapshot()` и первой строкой `enforce_chat_quota()` | Upstream меряет чат помесячно, потому что платит провайдеру за каждый вопрос (`basic`/«Free» — 30 в месяц). У нас провайдера нет: вопросы уходят в `claude-bridge` на подписку, серверная цена вопроса нулевая. Счётчик всё это время тикал вхолостую и 25.08 дотикал до 40/30 — телефон и Omi Mini стали получать вместо ответа готовую реплику «лимит исчерпан». Симптом обманчив и стоил половины разбора: отказ живёт ДО провайдера, `routers/chat.py` превращает свой же 402 в текст ассистента и отдаёт **200 OK**, поэтому в логах моста ноль запросов и ноль ошибок, а в логах бэкенда ноль отказов — ищущий идёт в мост, а причина в подписке. Опт-ин `OMI_SELFHOST_UNLIMITED_CHAT`; расход в снапшоте остаётся настоящим (`used`), снимается только потолок (`limit=None`), чтение расхода fail-open — врезка не должна уметь отказывать. Обе точки закрывают все 12 вызовов квоты, включая десктопные через `enforce_desktop_chat_quota()` |

## Пробросы окружения на mini (вне git — теряются молча)

Живут в `~/omi-jarvis-backend/bin/run-backend-real-firestore.py` и в рабочем дереве на mini.
Это единственное место, где реально собирается окружение дочернего процесса бэкенда.

- `GEMINI_API_KEY` — минт эфемерных токенов для голосового режима (`/v2/realtime/session`).
- `MCP_RESOURCE_URL`, `MCP_AUTHORIZATION_SERVER_URL` — иначе MCP OAuth указывает на прод omi.
- `FIREBASE_*` — свой Firebase-проект.
- `BUCKET_TEMPORAL_SYNC_LOCAL` — без него заливка аудио падает до распознавания.
- `ASK_CLAUDE_MODEL=opus` в `~/Library/LaunchAgents/ai.omi-jarvis.claude-bridge.plist` —
  модель мозга. Правило «Opus 5 везде» и карта всех трёх мест выбора модели — `~/omi-jarvis/PLAN.md` §4.
- `ASK_CLAUDE_MCP_CONFIG` — курированный набор MCP (`bridge-mcp-config.json`: memory,
  mempalace, omi). Ключ MCP в нём протухает при ротации: если Claude отвечает «нет
  инструментов памяти», сверь его с `OMI_MCP_TOKEN` в `~/.secrets/omi.env`.
- `OMI_SELFHOST_UNLIMITED_CHAT=1` в `~/omi-jarvis-backend/bin/backend-real-up.sh` — рубильник
  врезки «чат без месячного потолка». Снять переменную = вернуть стоковые 30 вопросов в месяц
  и вместе с ними немой чат. ВАЖНО: у desktop-backend (:8013) своё окружение и свой лончер —
  переменную туда никто не проставил, так что генерация десктопного чата через :8013 всё ещё
  ходит под стоковой квотой (экран Account & Plan это не затрагивает: он читает :8010).
- Незакоммиченная правка `backend/config/stt_provider_policy.py` в боевом дереве — без неё
  русский уходит к чужому провайдеру и транскрипт звонка молча пустой.

Проверка после любых операций с деревом на mini: `~/omi-jarvis/marathon/tools/voicemsg-deploy.sh status`.
