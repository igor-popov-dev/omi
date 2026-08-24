"""Self-host retrieval fallback — a private patch, deliberately not for upstream.

WHY THIS FILE EXISTS SEPARATELY
-------------------------------
Upstream hybrid retrieval assumes two managed services: Typesense for keyword hits
and an embeddings provider for the vector leg. A self-host deployment has neither.
Typesense is unconfigured, and embeddings would mean paying a second vendor purely
to turn text into numbers — while the caller doing the actual reasoning is Claude,
reached through the ask_claude bridge on the user's own subscription.

So the split here is: this module returns a *wide net* of plausible conversations,
and the model reads them and decides what is relevant. Semantic ranking moves from
a vector index into the model that was going to read the results anyway.

Keeping the whole implementation in this file (rather than editing
`utils/conversations/search.py`) is what makes upstream updates cheap: this file
never exists upstream, so it can never conflict. The only upstream file that had to
change is `utils/retrieval/tool_services/conversations.py`, and only by a short,
clearly marked block — see `docs/selfhost-patches.md`.
"""

import logging
from datetime import datetime, timezone
from typing import Any, Dict, List, Optional, Tuple

logger = logging.getLogger(__name__)

# How many recent conversations to pull before ranking. The whole point is to hand the
# model enough material to judge; scanning is a Firestore range read, not a search index,
# so this stays modest.
SCAN_LIMIT = 200
MIN_TOKEN_LEN = 3
# Prefix length for crude stemming. Russian inflects heavily ("еда"/"еде"/"еду"), and
# comparing whole words would miss the same noun in a different case.
STEM_LEN = 5
STOPWORDS = frozenset(
    {
        'что',
        'как',
        'мне',
        'про',
        'для',
        'это',
        'вчера',
        'сегодня',
        'когда',
        'какой',
        'какие',
        'the',
        'and',
        'for',
        'was',
        'were',
        'what',
        'when',
        'about',
        'with',
        'that',
        'this',
    }
)


def _fold(text: str) -> str:
    """Lowercase and replace every non-alphanumeric character with a space."""
    return ''.join(ch.lower() if ch.isalnum() else ' ' for ch in text)


def query_stems(query: str) -> List[str]:
    """Normalize a query into comparable stems, dropping stopwords and very short words."""
    stems: List[str] = []
    for word in _fold(query).split():
        if len(word) < MIN_TOKEN_LEN or word in STOPWORDS:
            continue
        stems.append(word[:STEM_LEN])
    return stems


def conversation_haystack(conversation: Dict[str, Any]) -> str:
    """Flatten one conversation's searchable text (title, overview, transcript) into folded text."""
    structured = conversation.get('structured') or {}
    parts: List[str] = [str(structured.get('title') or ''), str(structured.get('overview') or '')]
    for segment in conversation.get('transcript_segments') or []:
        if isinstance(segment, dict) and segment.get('text'):
            parts.append(str(segment['text']))
    return _fold(' '.join(parts))


def local_keyword_conversation_ids(
    uid: str,
    query: str,
    limit: int = 5,
    start_date: Optional[int] = None,
    end_date: Optional[int] = None,
) -> List[str]:
    """Rank recent conversations by literal stem overlap, using no external service.

    Fail-open, like the Typesense leg upstream: any error returns [] rather than
    breaking the caller. A query that matches nothing literally returns the most
    recent conversations in range instead of an empty list — the model can dismiss
    an irrelevant conversation, but it cannot reason about material it never saw.
    """
    # Imported lazily so importing this module never requires a Firestore client.
    from database import conversations as conversations_db

    try:
        starts = datetime.fromtimestamp(start_date, timezone.utc) if start_date else None
        ends = datetime.fromtimestamp(end_date, timezone.utc) if end_date else None
        recent = conversations_db.get_conversations(
            uid,
            limit=SCAN_LIMIT,
            include_discarded=False,
            start_date=starts,
            end_date=ends,
        )
    except Exception as e:
        logger.warning("selfhost local retrieval: could not read conversations for uid=%s: %s", uid, e)
        return []

    if not recent:
        return []

    def most_recent_ids() -> List[str]:
        return [str(c['id']) for c in recent[:limit] if c.get('id')]

    stems = query_stems(query)
    if not stems:
        return most_recent_ids()

    scored: List[Tuple[int, str]] = []
    for conversation in recent:
        conversation_id = conversation.get('id')
        if not conversation_id:
            continue
        haystack = conversation_haystack(conversation)
        hits = sum(1 for stem in stems if stem in haystack)
        if hits:
            scored.append((hits, str(conversation_id)))

    if not scored:
        return most_recent_ids()

    # `recent` arrives newest-first and Python's sort is stable, so ranking by hit
    # count alone keeps recency as the tie-breaker.
    scored.sort(key=lambda pair: pair[0], reverse=True)
    return [conversation_id for _, conversation_id in scored[:limit]]


# Typesense answers "the collection does not exist" with a 404 the client raises as
# ObjectNotFound; a deployment with no Typesense configured at all fails to even build a node
# (ConfigError). Both mean the same thing here — there is no index to ask — while every other
# failure keeps its upstream meaning. Matched by name, not by import, because the client
# package is optional in the environments this module is exercised from.
_MISSING_INDEX_EXCEPTION_NAMES = frozenset({'ObjectNotFound', 'ConfigError'})


def typesense_index_missing(exc: BaseException) -> bool:
    """Whether a Typesense failure means "no index here", as opposed to a real search error."""
    if type(exc).__name__ in _MISSING_INDEX_EXCEPTION_NAMES:
        return True
    message = str(exc).lower()
    return 'not found' in message or 'missing host' in message


# The app's search screen scans a bounded window, not the whole archive: reading every
# conversation of a long-lived account on every keystroke-sized request is the kind of cost a
# search index exists to avoid. The cap is logged when it bites, so "search misses old
# conversations" is diagnosable instead of mysterious.
PAGE_SCAN_LIMIT = 500


def local_conversation_search_page(
    uid: str,
    query: str,
    page: int = 1,
    per_page: int = 10,
    include_discarded: bool = True,
    start_date: Optional[int] = None,
    end_date: Optional[int] = None,
) -> Optional[Dict[str, Any]]:
    """Answer the app's conversation search from the database when Typesense cannot.

    Returns the same page shape ``utils.conversations.search.search_conversations`` returns —
    the callers only read ``items[].id`` plus the pagination fields and hydrate the rest
    themselves — or ``None`` when even the local scan fails, so the caller can raise its
    original error rather than pretend the archive is empty.

    Deliberately NOT the wide net of ``local_keyword_conversation_ids``: that one feeds a model
    that can dismiss an irrelevant conversation, this one feeds a human who typed a word. A
    query matching nothing must come back empty, because a screen full of unrelated recent
    conversations reads as "search is lying", not as "nothing matched".
    """
    # Imported lazily so importing this module never requires a database client.
    from database import conversations as conversations_db

    page = max(1, page or 1)
    per_page = max(1, per_page or 10)

    try:
        starts = datetime.fromtimestamp(start_date, timezone.utc) if start_date else None
        ends = datetime.fromtimestamp(end_date, timezone.utc) if end_date else None
        recent = conversations_db.get_conversations(
            uid,
            limit=PAGE_SCAN_LIMIT,
            include_discarded=include_discarded,
            start_date=starts,
            end_date=ends,
        )
    except Exception as e:
        logger.warning("selfhost conversation search: could not read conversations for uid=%s: %s", uid, e)
        return None

    if len(recent) >= PAGE_SCAN_LIMIT:
        logger.warning(
            "selfhost conversation search: scan hit the %s-conversation cap for uid=%s; "
            "older conversations are outside this search",
            PAGE_SCAN_LIMIT,
            uid,
        )

    stems = query_stems(query)
    matched: List[Tuple[int, str]] = []
    for conversation in recent:
        conversation_id = conversation.get('id')
        if not conversation_id:
            continue
        # Locked conversations are filtered again after hydration by the callers, but dropping
        # them here too keeps a page from being silently short by the number of hidden hits.
        if conversation.get('is_locked'):
            continue
        if not stems:
            # No usable query left (empty, or nothing but stopwords): this is the filter-only
            # browse the caller already validated — date range, speaker — so recency is the
            # answer and every conversation in range qualifies.
            matched.append((0, str(conversation_id)))
            continue
        hits = sum(1 for stem in stems if stem in conversation_haystack(conversation))
        if hits:
            matched.append((hits, str(conversation_id)))

    # `recent` arrives newest-first and Python's sort is stable, so ranking by hit count alone
    # keeps recency as the tie-breaker.
    matched.sort(key=lambda pair: pair[0], reverse=True)
    start_index = (page - 1) * per_page
    window = matched[start_index : start_index + per_page]
    has_more = len(matched) > start_index + per_page

    return {
        'items': [{'id': conversation_id} for _, conversation_id in window],
        'total_pages': page + 1 if has_more else page,
        'current_page': page,
        'per_page': per_page,
    }
