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
| Поиск по разговорам | `backend/utils/selfhost_retrieval.py` | `backend/utils/retrieval/tool_services/conversations.py` — импорт + блок в `search_conversations_text` | Upstream ищет через Typesense + эмбеддинги. У нас нет ни того, ни другого: Typesense не настроен, а эмбеддинги — это второй платный вендор. Векторная нога стала необязательной (её падение больше не роняет весь инструмент), а отбор релевантного делает Claude, читая выборку |
| Постобработка и память | — | `backend/utils/conversations/process_conversation.py`, `backend/utils/llm/clients.py` | Цепочка памяти и постобработка переведены с OpenAI на мост `claude-bridge` (подписка вместо ключа) |
| STT на устройстве | — | `app/lib/services/sockets/pure_polling.dart`, `transcription_polling_service.dart`, `app/lib/models/stt_provider.dart` | Свой STT-роутер на mini вместо облачного: адаптивное окно флаша, честная семантика отказов, буферизация офлайн |
| Адрес своего STT | — | `app/lib/env/env.dart` (`defaultSttUrl`), `app/lib/backend/preferences.dart` | Чистая установка должна сразу смотреть на наш роутер, а не на облако |
| Индикация записи | — | `app/lib/services/capture/stt_display_status.dart`, `capture_controller.dart`, `app/lib/pages/conversation_capturing/page.dart` | Видимое состояние распознавания вместо «Listening» без информации |
| Подпись сборки | — | `app/android/app/build.gradle` | Свой ключ подписи (`OMI_SELFHOST_SIGNING`) |
| Голосовой хаб | `app/lib/services/voice_hub/*`, `app/android/.../voiceplayer/*` | точки подключения в `main.dart`, `capture_controller.dart`, `pages/chat/` | Свободный голосовой режим (Gemini Live + Charon) и инструмент `ask_claude` — наш клей, в upstream не отдаём |

## Пробросы окружения на mini (вне git — теряются молча)

Живут в `~/omi-jarvis-backend/bin/run-backend-real-firestore.py` и в рабочем дереве на mini.
Это единственное место, где реально собирается окружение дочернего процесса бэкенда.

- `GEMINI_API_KEY` — минт эфемерных токенов для голосового режима (`/v2/realtime/session`).
- `MCP_RESOURCE_URL`, `MCP_AUTHORIZATION_SERVER_URL` — иначе MCP OAuth указывает на прод omi.
- `FIREBASE_*` — свой Firebase-проект.
- `BUCKET_TEMPORAL_SYNC_LOCAL` — без него заливка аудио падает до распознавания.
- Незакоммиченная правка `backend/config/stt_provider_policy.py` в боевом дереве — без неё
  русский уходит к чужому провайдеру и транскрипт звонка молча пустой.

Проверка после любых операций с деревом на mini: `~/omi-jarvis/marathon/tools/voicemsg-deploy.sh status`.
