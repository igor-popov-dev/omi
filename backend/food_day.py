"""Что человек съел за день — по всем разговорам сразу.

Зачем отдельно от шаблонов сводок. Шаблон в omi работает по ОДНОЙ беседе, а еда за день
рассыпана по разным: завтрак обсуждали утром, кофе упомянули между делом, ужин — вечером.
Ни одна отдельная беседа не даёт картину дня, поэтому здесь всё наоборот: сначала
собираются все разговоры за сутки, и только потом они разбираются одним запросом.

Разбор идёт через наш мост (Claude по подписке), а не через облачные ключи omi.

Запуск на mini:
    ~/omi-jarvis-backend/omi-me/backend/.venv/bin/python food_day.py [YYYY-MM-DD]
Без даты — сегодняшний день по времени владельца.
"""

import json
import os
import sys
import urllib.request
from datetime import datetime, time, timedelta, timezone

os.environ.setdefault("GOOGLE_APPLICATION_CREDENTIALS", os.path.expanduser("~/.secrets/omi-jarvis-firebase-sa.json"))

from google.cloud import firestore  # noqa: E402

UID = "o0WBG0xaXefQO6Oa3cNqeyR7ytd2"
PROJECT = "omi-jarvis-igor"
BRIDGE = os.environ.get("CLAUDE_BRIDGE_URL", "http://127.0.0.1:8766")
# Москва: разговоры хранятся в UTC, а «день» человек считает по своим часам.
TZ = timezone(timedelta(hours=3))

PROMPT = """Ниже — расшифровки всех разговоров человека за один день, по порядку.

Собери, что он за этот день ел и пил. Правила:
- Каждый пункт: время (если известно), что именно, примерная порция.
- Разделяй «съел точно» и «упоминалось, но неясно, съел ли» — это разные списки.
- Кофе, чай, вода, алкоголь тоже считаются.
- Не додумывай блюда, которых в разговорах не было. Лучше короткий честный список.
- Если про еду ничего не говорилось, так и напиши одной строкой.
- В конце — строка «Пробелы:» с частями дня, про которые еды не упоминалось вовсе
  (например «утро — нет данных»): это подсказка, что запись просто не попала в разговоры.
Пиши по-русски, компактно, без вступлений."""


def day_bounds(day: datetime) -> tuple[datetime, datetime]:
    start_local = datetime.combine(day.date(), time.min, tzinfo=TZ)
    return start_local.astimezone(timezone.utc), (start_local + timedelta(days=1)).astimezone(timezone.utc)


def collect(db, start_utc: datetime, end_utc: datetime) -> list[tuple[datetime, str]]:
    """Расшифровки бесед за сутки. Сегменты зашифрованы, поэтому берём тот же путь,
    что и приложение — через код бэкенда, если он доступен, иначе только заголовки."""
    from pathlib import Path

    repo_root = Path(os.path.expanduser("~/omi-jarvis-backend/omi-me"))
    sys.path.insert(0, str(repo_root / "backend"))
    try:
        # Тот же набор переменных, что получает боевой процесс бэкенда: без него
        # недоступен ключ шифрования, а сегменты бесед лежат в базе зашифрованными.
        sys.path.insert(0, str(repo_root / "scripts" / "dev-harness"))
        from dev_harness import config as harness_config  # noqa: E402

        os.environ.update(harness_config.child_env_for(harness_config.load_config(repo_root)))
        os.environ["GOOGLE_APPLICATION_CREDENTIALS"] = os.path.expanduser("~/.secrets/omi-jarvis-firebase-sa.json")
        os.environ["OMI_LOCAL_DEV_REAL_FIRESTORE"] = "1"
        os.environ.pop("FIRESTORE_EMULATOR_HOST", None)

        import database.conversations as conversations_db  # noqa: E402

        raw = conversations_db.get_conversations(UID, limit=200, offset=0, include_discarded=False)
    except Exception as exc:
        print(f"(!) расшифровка недоступна: {type(exc).__name__}: {exc}", file=sys.stderr)
        return []

    out = []
    for conv in raw:
        created = conv.get("created_at")
        if not isinstance(created, datetime):
            continue
        if not (start_utc <= created.astimezone(timezone.utc) < end_utc):
            continue
        segments = conv.get("transcript_segments") or []
        text = " ".join((s.get("text") or "") for s in segments if isinstance(s, dict)).strip()
        if text:
            out.append((created.astimezone(TZ), text))
    return sorted(out, key=lambda pair: pair[0])


def ask_bridge(question: str, context: str) -> str:
    """Мост отдаёт ответ потоком (SSE): куски `delta` и финальный `done` с полным текстом."""
    payload = json.dumps({"question": question, "context": context, "model": "opus"}).encode()
    req = urllib.request.Request(
        f"{BRIDGE}/ask", data=payload, headers={"Content-Type": "application/json"}, method="POST"
    )
    parts = []
    with urllib.request.urlopen(req, timeout=600) as resp:
        for raw_line in resp:
            line = raw_line.decode("utf-8", "replace").strip()
            if not line.startswith("data:"):
                continue
            try:
                event = json.loads(line[5:].strip())
            except json.JSONDecodeError:
                continue
            if event.get("type") == "done":
                return event.get("text") or "".join(parts)
            if event.get("type") == "delta":
                parts.append(event.get("text") or "")
            elif event.get("type") == "error":
                return f"(мост вернул ошибку: {event.get('text') or event})"
    return "".join(parts) or "(мост не вернул текста)"


def main() -> None:
    day = datetime.now(TZ) if len(sys.argv) < 2 else datetime.fromisoformat(sys.argv[1]).replace(tzinfo=TZ)
    start_utc, end_utc = day_bounds(day)

    db = firestore.Client(project=PROJECT)
    conversations = collect(db, start_utc, end_utc)
    if not conversations:
        print(f"за {day.date()} разговоров с расшифровкой не нашлось")
        return

    context = "\n\n".join(f"[{ts.strftime('%H:%M')}] {text}" for ts, text in conversations)
    print(f"разговоров за {day.date()}: {len(conversations)}, знаков расшифровки: {len(context)}\n")
    print(ask_bridge(PROMPT, context))


if __name__ == "__main__":
    main()
