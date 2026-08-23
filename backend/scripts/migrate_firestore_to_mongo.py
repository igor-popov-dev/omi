"""Перенос данных из Firestore в MongoDB (self-host, PR BasedHardware/omi#10887).

В самом PR миграции данных НЕТ — автор вынес её за скобки явно. Этот скрипт закрывает
пробел для нашей установки.

Как устроен: обе стороны — реализации одного и того же нейтрального порта
(``database/store/ports.py``), поэтому перенос это буквально «прочитал StoredDocument
слева, записал справа». Никакой ручной перекладки полей: сжатые байты транскрипта,
вложенные словари, даты — всё едет как есть.

Обход рекурсивный: корневые коллекции -> документы -> их подколлекции -> и так вглубь.
Firestore не отдаёт «все документы поддерева» одним запросом, поэтому спускаемся сами.

Идемпотентно: пишем ``set`` по полному логическому пути, повторный прогон просто
перезапишет. Значит прогон можно прервать и запустить снова.

ВАЖНО про квоту: каждый прочитанный документ — это чтение Firestore. У бесплатного
тарифа дневной потолок, поэтому скрипт считает чтения и умеет останавливаться по
``--max-reads``. Сначала гоняем с ``--dry-run``, чтобы узнать объём.

Запуск (из backend/, в venv):
    GOOGLE_APPLICATION_CREDENTIALS=~/.secrets/omi-jarvis-firebase-sa.json \\
    MONGO_URI=mongodb://127.0.0.1:27017/?replicaSet=rs0 MONGO_DB=omi \\
    python -m scripts.migrate_firestore_to_mongo --dry-run
"""

from __future__ import annotations

import argparse
import logging
import os
import sys
import time
from collections import Counter
from typing import Any, Dict, Iterable, List, Optional

logger = logging.getLogger("migrate")


class Budget(Exception):
    """Достигнут потолок чтений — не ошибка, а штатная остановка."""


class Migrator:
    def __init__(self, source: Any, target: Optional[Any], *, max_reads: Optional[int] = None) -> None:
        self._source = source
        self._target = target  # None => сухой прогон
        self._max_reads = max_reads
        self.reads = 0
        self.writes = 0
        self.per_collection: Counter = Counter()
        self.skipped: List[str] = []

    # --- обход ---------------------------------------------------------------------------------

    def _spend(self, n: int = 1) -> None:
        self.reads += n
        if self._max_reads is not None and self.reads >= self._max_reads:
            raise Budget(f"достигнут потолок чтений: {self._max_reads}")

    def walk_collection(self, collection_path: str, depth: int = 0) -> None:
        """Перенести все документы коллекции и рекурсивно их подколлекции."""
        try:
            records = self._source.query(collection_path)
        except Exception as exc:  # коллекция может быть недоступна или пуста
            logger.warning("не прочиталась коллекция %s: %s", collection_path, exc)
            self.skipped.append(collection_path)
            return

        self._spend(len(records) or 1)
        leaf = collection_path.split("/")[-1]
        self.per_collection[leaf] += len(records)
        indent = "  " * depth
        if records:
            logger.info("%s%s — %d док.", indent, collection_path, len(records))

        for record in records:
            doc_path = f"{collection_path}/{record.id}"
            if self._target is not None:
                self._target.set(doc_path, dict(record.data or {}))
                self.writes += 1
            for sub in self._subcollections(doc_path):
                self.walk_collection(f"{doc_path}/{sub}", depth + 1)

    def _subcollections(self, doc_path: str) -> Iterable[str]:
        try:
            return self._source.list_subcollections(doc_path)
        except Exception as exc:
            logger.warning("не перечислились подколлекции %s: %s", doc_path, exc)
            self.skipped.append(doc_path + "/*")
            return []


def _root_collections(client: Any, explicit: Optional[List[str]]) -> List[str]:
    """Корневые коллекции Firestore. Порт их перечислять не умеет — это единственное
    место, где нужен сам клиент."""
    if explicit:
        return explicit
    return sorted(c.id for c in client.collections())


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--dry-run", action="store_true", help="только посчитать, ничего не писать")
    parser.add_argument("--collections", help="перенести только эти корневые коллекции (через запятую)")
    parser.add_argument("--users", help="только эти uid внутри users (через запятую)")
    parser.add_argument("--max-reads", type=int, help="остановиться после N прочитанных документов (щадит квоту)")
    parser.add_argument("--mongo-db", default=os.environ.get("MONGO_DB", "omi"), help="база назначения")
    parser.add_argument("-v", "--verbose", action="store_true")
    args = parser.parse_args(argv)

    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(asctime)s %(levelname)s %(message)s",
        datefmt="%H:%M:%S",
    )

    # Источник: НАСТОЯЩИЙ Firestore. Явно гасим STORAGE_BACKEND, иначе _client.py подсунет
    # фасад над Mongo и мы бодро перенесём базу саму в себя.
    os.environ.pop("STORAGE_BACKEND", None)
    if os.environ.get("FIRESTORE_EMULATOR_HOST"):
        logger.warning("FIRESTORE_EMULATOR_HOST задан — источником будет ЭМУЛЯТОР, а не облако")

    from database._client import get_firestore_client
    from database.store.adapters.firestore import FirestoreDocumentStore

    client = get_firestore_client()
    source = FirestoreDocumentStore(client=client)

    target = None
    if not args.dry_run:
        uri = os.environ.get("MONGO_URI")
        if not uri:
            logger.error("нужен MONGO_URI (или запускайте с --dry-run)")
            return 2
        from database.store.adapters.mongo import MongoDocumentStore

        target = MongoDocumentStore(uri=uri, db_name=args.mongo_db)
        logger.info("назначение: Mongo %s, база %s", uri.split("@")[-1], args.mongo_db)
    else:
        logger.info("СУХОЙ ПРОГОН — ничего не записывается")

    roots = _root_collections(client, args.collections.split(",") if args.collections else None)
    logger.info("корневых коллекций: %d — %s", len(roots), ", ".join(roots))

    migrator = Migrator(source, target, max_reads=args.max_reads)
    started = time.time()
    try:
        for root in roots:
            if root == "users" and args.users:
                for uid in args.users.split(","):
                    uid = uid.strip()
                    record = source.get(f"users/{uid}")
                    migrator._spend()
                    if record.exists:
                        if target is not None:
                            target.set(f"users/{uid}", dict(record.data or {}))
                            migrator.writes += 1
                        migrator.per_collection["users"] += 1
                        for sub in migrator._subcollections(f"users/{uid}"):
                            migrator.walk_collection(f"users/{uid}/{sub}", 1)
                    else:
                        logger.warning("пользователя нет: %s", uid)
                continue
            migrator.walk_collection(root)
    except Budget as stop:
        logger.warning("остановлено: %s", stop)
    except KeyboardInterrupt:
        logger.warning("прервано вручную — прогон идемпотентен, можно запустить снова")
    finally:
        if target is not None:
            close = getattr(target, "close", None)
            if callable(close):
                close()

    elapsed = time.time() - started
    logger.info("--- итог за %.1f с ---", elapsed)
    logger.info("прочитано документов: %d", migrator.reads)
    logger.info("записано документов:  %d", migrator.writes)
    for name, count in migrator.per_collection.most_common():
        logger.info("   %-32s %d", name, count)
    if migrator.skipped:
        logger.warning("пропущено путей: %d (первые 10: %s)", len(migrator.skipped), migrator.skipped[:10])
    return 0


if __name__ == "__main__":
    sys.exit(main())
