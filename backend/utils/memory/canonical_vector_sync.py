"""Sync universal canonical memory items to Pinecone using user-scoped provider ids."""

from __future__ import annotations

import logging
from typing import Callable, Optional

from models.memory_evidence import SourceState
from models.product_memory import (
    RESTRICTED_SENSITIVITY_LABELS,
    MemoryItem,
    MemoryItemStatus,
    ProcessingState,
)

logger = logging.getLogger(__name__)


def canonical_vector_provider_configured() -> bool:
    """Report whether this deployment has a usable canonical vector index.

    The vector helpers already degrade to a warning when the index is absent,
    but the outbox consumer requires a strict ``True`` and would otherwise spend
    every delivery attempt on a provider the install never configured.
    """
    try:
        from database.vector_db import index

        return index is not None
    except Exception:
        logger.exception("canonical vector provider probe failed")
        return False


def delete_canonical_memory_vector(uid: str, memory_id: str) -> bool:
    """Delete all provider identities for one user's canonical memory."""
    try:
        from database.vector_db import delete_canonical_memory_vectors

        return delete_canonical_memory_vectors(uid, memory_id)
    except Exception:
        logger.exception(
            "canonical vector delete failed memory_id=%s uid=%s",
            memory_id,
            uid,
        )
        return False


def sync_canonical_memory_vector(
    item: MemoryItem,
    *,
    projection_commit_id: Optional[str] = None,
    on_hard_failure: Optional[Callable[[], None]] = None,
) -> bool:
    """Converge one live canonical item without indexing restricted content."""
    if set(item.sensitivity_labels).intersection(RESTRICTED_SENSITIVITY_LABELS):
        deleted = delete_canonical_memory_vector(item.uid, item.memory_id)
        if not deleted and on_hard_failure is not None:
            on_hard_failure()
        return deleted
    if (
        item.status != MemoryItemStatus.active
        or item.processing_state != ProcessingState.processed
        or item.source_state != SourceState.active
        or (item.promotion or {}).get("user_review") is False
    ):
        return False
    content = (item.content or "").strip()
    if not content:
        return False

    try:
        from database.vector_db import upsert_canonical_memory_vector

        result = upsert_canonical_memory_vector(item, projection_commit_id=projection_commit_id)
    except Exception:
        logger.exception(
            "canonical vector sync failed memory_id=%s uid=%s",
            item.memory_id,
            item.uid,
        )
        if on_hard_failure is not None:
            on_hard_failure()
        return False
    if result is None:
        logger.warning("canonical vector sync skipped memory_id=%s uid=%s", item.memory_id, item.uid)
        return False
    return True
