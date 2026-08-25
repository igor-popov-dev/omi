"""A malformed stored date must not 500 the action-items list.

``_action_item_list_sort_key`` read ``created_at`` with ``.get(key, <sentinel>)``
and called ``.timestamp()`` on the result, and compared ``due_at`` directly. The
default only covers an *absent* key, so a document holding an explicit null or an
ISO string — the shape ``_prepare_action_item_for_read`` deliberately passes
through, and the shape documents written before the write-side normalization
(#11137, 2026-08-10) can still have — raised AttributeError/TypeError inside
``sort()``. That happens in the database layer, upstream of the route's per-item
skip (``_safe_action_item_responses``), so one legacy row failed the whole page
with a 500 instead of being degraded.

``database.action_items`` is import-pure (``database._client.db`` is a lazy
proxy), so the query chain is replaced per-test via ``monkeypatch.setattr`` — the
same Tier-2 seam ``test_action_items_pagination_order.py`` uses.
"""

from datetime import datetime, timedelta, timezone
from unittest.mock import MagicMock

import pytest

import database.action_items as action_items

BASE = datetime(2026, 1, 1, tzinfo=timezone.utc)


class _Doc:
    def __init__(self, doc_id, data):
        self.id = doc_id
        self._data = dict(data)

    def to_dict(self):
        return dict(self._data)


class _Query:
    """Firestore query stand-in with completed equality filtering (production semantics)."""

    def __init__(self, docs, completed=None):
        self._docs = docs
        self._completed = completed
        self._limit = None

    def where(self, *a, **k):
        filt = k.get('filter') if k else None
        completed = self._completed
        if filt is not None:
            field = getattr(filt, 'field_path', None) or getattr(filt, 'field', None)
            value = getattr(filt, 'value', None)
            if field == 'completed':
                completed = value
        return _Query(self._docs, completed=completed)

    def order_by(self, *a, **k):
        return self

    def select(self, _fields):
        return self

    def offset(self, n):
        return self

    def limit(self, n):
        self._limit = n
        return self

    def stream(self):
        docs = list(self._docs)
        if self._completed is not None:
            # Firestore equality excludes missing/null completed fields.
            docs = [doc for doc in docs if doc._data.get('completed') is self._completed]
        if self._limit is not None:
            docs = docs[: self._limit]
        return iter(docs)


@pytest.fixture
def fake_db(monkeypatch):
    db = MagicMock(name='db')
    monkeypatch.setattr(action_items, 'db', db)
    return db


def _listed_ids(fake_db, docs, **kwargs):
    query = _Query(list(docs))
    fake_db.collection.return_value.document.return_value.collection.return_value = query
    return [item['id'] for item in action_items.get_action_items('uid1', **kwargs)]


def test_null_created_at_is_listed_last_not_a_500(fake_db):
    docs = [
        _Doc('older', {'created_at': BASE, 'due_at': None}),
        _Doc('null-created', {'created_at': None, 'due_at': None}),
        _Doc('newer', {'created_at': BASE + timedelta(days=1), 'due_at': None}),
    ]
    # Before the fix: AttributeError: 'NoneType' object has no attribute 'timestamp'.
    assert _listed_ids(fake_db, docs) == ['newer', 'older', 'null-created']


def test_string_created_at_is_listed_last_not_a_500(fake_db):
    docs = [
        _Doc('older', {'created_at': BASE, 'due_at': None}),
        _Doc('string-created', {'created_at': '2026-06-01T00:00:00+00:00', 'due_at': None}),
        _Doc('newer', {'created_at': BASE + timedelta(days=1), 'due_at': None}),
    ]
    # Before the fix: AttributeError: 'str' object has no attribute 'timestamp'.
    assert _listed_ids(fake_db, docs) == ['newer', 'older', 'string-created']


def test_string_due_at_sorts_with_the_no_due_date_tail_not_a_500(fake_db):
    docs = [
        _Doc('due-soon', {'created_at': BASE, 'due_at': BASE + timedelta(days=1)}),
        _Doc('string-due', {'created_at': BASE, 'due_at': '2026-01-02T00:00:00+00:00'}),
        _Doc('due-later', {'created_at': BASE, 'due_at': BASE + timedelta(days=5)}),
    ]
    # Before the fix: TypeError: '<' not supported between 'str' and 'datetime.datetime'.
    assert _listed_ids(fake_db, docs) == ['due-soon', 'due-later', 'string-due']


def test_absent_created_at_key_still_sorts_last(fake_db):
    # The pre-existing `.get(key, sentinel)` default handled a missing key; keep it pinned.
    docs = [
        _Doc('dated', {'created_at': BASE, 'due_at': None}),
        _Doc('undated', {'due_at': None}),
    ]
    assert _listed_ids(fake_db, docs) == ['dated', 'undated']


def test_well_formed_order_is_unchanged(fake_db):
    # Product order for healthy rows: active first, soonest due first, no-due last, newest first.
    docs = [
        _Doc('no-due-old', {'created_at': BASE, 'due_at': None}),
        _Doc('no-due-new', {'created_at': BASE + timedelta(days=2), 'due_at': None}),
        _Doc('due-later', {'created_at': BASE, 'due_at': BASE + timedelta(days=9)}),
        _Doc('due-soon', {'created_at': BASE, 'due_at': BASE + timedelta(days=3)}),
        _Doc('done', {'created_at': BASE + timedelta(days=3), 'due_at': None, 'completed': True}),
    ]
    assert _listed_ids(fake_db, docs) == ['due-soon', 'due-later', 'no-due-new', 'no-due-old', 'done']


def test_malformed_dates_do_not_break_the_completed_bucket(fake_db):
    docs = [
        _Doc('done-null', {'created_at': None, 'due_at': None, 'completed': True}),
        _Doc('done-dated', {'created_at': BASE, 'due_at': None, 'completed': True}),
    ]
    assert _listed_ids(fake_db, docs, completed=True) == ['done-dated', 'done-null']
