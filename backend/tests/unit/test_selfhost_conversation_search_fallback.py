"""Self-host patch: the app's conversation search answers from the database when Typesense cannot.

A self-host deployment has no Typesense collection, so `client.collections['conversations']` raises
ObjectNotFound (404) and every POST /v1/conversations/search came back 500 — search was simply dead
on the phone. The util now falls back to a local scan. Pinned against a fake Typesense client and a
fake conversations database, no live services.
"""

import os

os.environ.setdefault(
    "ENCRYPTION_SECRET",
    "omi_ZwB2ZNqB2HHpMK6wStk7sTpavJiPTFg7gXUHnc4tFABPU6pZ2c2DKgehtfgi4RZv",
)
# The Typesense client validates its config at construction; these are inert and never connect.
os.environ.setdefault("TYPESENSE_HOST", "localhost")
os.environ.setdefault("TYPESENSE_HOST_PORT", "8108")
os.environ.setdefault("TYPESENSE_PROTOCOL", "http")
os.environ.setdefault("TYPESENSE_API_KEY", "test-key")

import sys  # noqa: E402
import types  # noqa: E402
from unittest.mock import MagicMock  # noqa: E402

import pytest  # noqa: E402

import utils.conversations.search as search_mod  # noqa: E402
import utils.selfhost_retrieval as selfhost  # noqa: E402


class _ObjectNotFound(Exception):
    """Stands in for typesense.exceptions.ObjectNotFound: the collection was never created."""


def _dead_typesense(exc: Exception) -> MagicMock:
    fake = MagicMock()
    fake.collections.__getitem__.return_value.documents.search.side_effect = exc
    return fake


def _conversation(cid: str, title: str = "", overview: str = "", transcript: str = "", **extra):
    doc = {
        'id': cid,
        'structured': {'title': title, 'overview': overview},
        'transcript_segments': [{'text': transcript}] if transcript else [],
    }
    doc.update(extra)
    return doc


@pytest.fixture
def fake_conversations_db(monkeypatch):
    """Install a fake `database.conversations` for the lazy import inside the fallback."""
    module = types.ModuleType('database.conversations')
    calls: dict = {}

    def get_conversations(uid, limit=100, include_discarded=False, start_date=None, end_date=None, **kwargs):
        calls['uid'] = uid
        calls['limit'] = limit
        calls['include_discarded'] = include_discarded
        calls['start_date'] = start_date
        calls['end_date'] = end_date
        return list(module.rows)

    module.rows = []
    module.get_conversations = get_conversations
    module.calls = calls
    package = types.ModuleType('database')
    package.conversations = module
    monkeypatch.setitem(sys.modules, 'database', package)
    monkeypatch.setitem(sys.modules, 'database.conversations', module)
    return module


def test_missing_collection_falls_back_to_local_matches(monkeypatch, fake_conversations_db):
    monkeypatch.setattr(search_mod, "client", _dead_typesense(_ObjectNotFound("[Errno 404] Not found.")))
    fake_conversations_db.rows = [
        _conversation("c-new", title="Ужин"),
        _conversation("c-hit", overview="Обсуждали гиюр и раввина"),
        _conversation("c-transcript", transcript="дальше про гиюр в Израиле"),
    ]

    # Before the patch this raised Exception("Failed to search conversations: ...") -> HTTP 500.
    result = search_mod.search_conversations(uid="u1", query="гиюр", page=1, per_page=10)

    assert [item['id'] for item in result['items']] == ["c-hit", "c-transcript"]
    assert result['current_page'] == 1 and result['per_page'] == 10
    assert result['total_pages'] == 1


def test_no_local_match_returns_empty_not_recent(monkeypatch, fake_conversations_db):
    monkeypatch.setattr(search_mod, "client", _dead_typesense(_ObjectNotFound("[Errno 404] Not found.")))
    fake_conversations_db.rows = [_conversation("c1", title="Ужин"), _conversation("c2", title="Прогулка")]

    result = search_mod.search_conversations(uid="u1", query="гиюр", page=1, per_page=10)

    # A human typed a word: an unrelated page of recent conversations would read as a lying search.
    assert result['items'] == []


def test_locked_conversations_never_reach_the_page(monkeypatch, fake_conversations_db):
    monkeypatch.setattr(search_mod, "client", _dead_typesense(_ObjectNotFound("[Errno 404] Not found.")))
    fake_conversations_db.rows = [
        _conversation("c-locked", title="гиюр", is_locked=True),
        _conversation("c-open", title="гиюр"),
    ]

    result = search_mod.search_conversations(uid="u1", query="гиюр", page=1, per_page=10)

    assert [item['id'] for item in result['items']] == ["c-open"]


def test_fallback_paginates_and_reports_more(monkeypatch, fake_conversations_db):
    monkeypatch.setattr(search_mod, "client", _dead_typesense(_ObjectNotFound("[Errno 404] Not found.")))
    fake_conversations_db.rows = [_conversation(f"c{i}", title="гиюр") for i in range(5)]

    first = search_mod.search_conversations(uid="u1", query="гиюр", page=1, per_page=2)
    second = search_mod.search_conversations(uid="u1", query="гиюр", page=2, per_page=2)
    third = search_mod.search_conversations(uid="u1", query="гиюр", page=3, per_page=2)

    assert [item['id'] for item in first['items']] == ["c0", "c1"]
    assert first['total_pages'] == 2  # page + 1 signals "there is more"
    assert [item['id'] for item in second['items']] == ["c2", "c3"]
    assert [item['id'] for item in third['items']] == ["c4"]
    assert third['total_pages'] == 3  # last page: no further page advertised


def test_fallback_honours_include_discarded_and_date_window(monkeypatch, fake_conversations_db):
    monkeypatch.setattr(search_mod, "client", _dead_typesense(_ObjectNotFound("[Errno 404] Not found.")))
    fake_conversations_db.rows = [_conversation("c1", title="гиюр")]

    search_mod.search_conversations(
        uid="u1", query="гиюр", include_discarded=False, start_date=1700000000, end_date=1700003600
    )

    calls = fake_conversations_db.calls
    assert calls['uid'] == "u1"
    assert calls['include_discarded'] is False
    assert calls['start_date'].timestamp() == 1700000000
    assert calls['end_date'].timestamp() == 1700003600


def test_filter_only_browse_returns_the_window(monkeypatch, fake_conversations_db):
    # Empty query with a speaker filter is a browse, not a search: everything in range qualifies
    # and the router applies the speaker filter after hydration.
    monkeypatch.setattr(search_mod, "client", _dead_typesense(_ObjectNotFound("[Errno 404] Not found.")))
    fake_conversations_db.rows = [_conversation("c1"), _conversation("c2")]

    result = search_mod.search_conversations(uid="u1", query="", speaker_id="user")

    assert [item['id'] for item in result['items']] == ["c1", "c2"]


def test_transient_typesense_still_raises_unavailable(monkeypatch, fake_conversations_db):
    # Upstream contract: a reachable-but-slow index means 503, not a quietly degraded local answer.
    monkeypatch.setattr(search_mod, "client", _dead_typesense(Exception("Connection timed out")))
    fake_conversations_db.rows = [_conversation("c1", title="гиюр")]

    with pytest.raises(search_mod.ConversationSearchUnavailableError):
        search_mod.search_conversations(uid="u1", query="гиюр")


def test_dead_database_reraises_original_search_error(monkeypatch, fake_conversations_db):
    monkeypatch.setattr(search_mod, "client", _dead_typesense(_ObjectNotFound("[Errno 404] Not found.")))

    def explode(*args, **kwargs):
        raise RuntimeError("mongo down")

    fake_conversations_db.get_conversations = explode

    # Nothing to fall back on: report the failure instead of claiming the archive is empty.
    with pytest.raises(Exception, match="Failed to search conversations"):
        search_mod.search_conversations(uid="u1", query="гиюр")


def test_non_index_error_never_reroutes_even_with_a_healthy_database(monkeypatch, fake_conversations_db):
    # A malformed query is a defect, not a missing index: answering it from the local scan would
    # dress a broken search up as a working one. Upstream's contract holds.
    monkeypatch.setattr(search_mod, "client", _dead_typesense(ValueError("bad query shape")))
    fake_conversations_db.rows = [_conversation("c1", title="гиюр")]

    with pytest.raises(Exception, match="Failed to search conversations"):
        search_mod.search_conversations(uid="u1", query="гиюр")

    assert fake_conversations_db.calls == {}  # the database was never touched
