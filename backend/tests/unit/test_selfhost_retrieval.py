"""Tests for the self-host retrieval fallback (private patch, see utils/selfhost_retrieval.py)."""

import sys
import types

import pytest

from utils import selfhost_retrieval


def _conversation(conversation_id: str, title: str = '', overview: str = '', segments=()):
    return {
        'id': conversation_id,
        'structured': {'title': title, 'overview': overview},
        'transcript_segments': [{'text': text} for text in segments],
    }


@pytest.fixture
def fake_conversations(monkeypatch):
    """Install a fake `database.conversations` so no Firestore client is constructed."""
    state = {'returns': [], 'raises': None, 'calls': []}

    module = types.ModuleType('database.conversations')

    def get_conversations(uid, limit=100, include_discarded=False, start_date=None, end_date=None, **kwargs):
        state['calls'].append({'uid': uid, 'limit': limit, 'start_date': start_date, 'end_date': end_date})
        if state['raises'] is not None:
            raise state['raises']
        return state['returns']

    module.get_conversations = get_conversations
    monkeypatch.setitem(sys.modules, 'database.conversations', module)
    return state


def test_ranks_by_stem_overlap(fake_conversations):
    fake_conversations['returns'] = [
        _conversation('newest', title='Прогулка'),
        _conversation('about-food', title='Обед', overview='ели пасту', segments=('еда была вкусной',)),
        _conversation('one-hit', segments=('еда',)),
    ]

    ids = selfhost_retrieval.local_keyword_conversation_ids('uid', 'что я ел, какая еда была?', limit=5)

    # 'about-food' matches both stems ("ел"->dropped as too short, "еда"/"едой" share the stem),
    # so it must outrank the single-hit conversation, and the unrelated one must be absent.
    assert ids[0] == 'about-food'
    assert 'one-hit' in ids
    assert 'newest' not in ids


def test_falls_back_to_most_recent_when_nothing_matches(fake_conversations):
    fake_conversations['returns'] = [_conversation('a', title='Прогулка'), _conversation('b', title='Работа')]

    ids = selfhost_retrieval.local_keyword_conversation_ids('uid', 'квантовая хромодинамика', limit=1)

    # The model can dismiss an irrelevant conversation; it cannot reason about nothing.
    assert ids == ['a']


def test_query_without_usable_tokens_returns_recent(fake_conversations):
    fake_conversations['returns'] = [_conversation('a'), _conversation('b')]

    ids = selfhost_retrieval.local_keyword_conversation_ids('uid', 'что как это', limit=2)

    assert ids == ['a', 'b']


def test_read_failure_is_fail_open(fake_conversations):
    fake_conversations['raises'] = RuntimeError('firestore unavailable')

    assert selfhost_retrieval.local_keyword_conversation_ids('uid', 'еда', limit=5) == []


def test_empty_store_returns_empty(fake_conversations):
    fake_conversations['returns'] = []

    assert selfhost_retrieval.local_keyword_conversation_ids('uid', 'еда', limit=5) == []


def test_date_range_is_passed_through(fake_conversations):
    fake_conversations['returns'] = []

    selfhost_retrieval.local_keyword_conversation_ids('uid', 'еда', limit=5, start_date=1000, end_date=2000)

    call = fake_conversations['calls'][0]
    assert call['start_date'] is not None and call['end_date'] is not None
    assert call['start_date'].timestamp() == 1000
    assert call['end_date'].timestamp() == 2000


def test_stems_drop_stopwords_and_short_words():
    assert selfhost_retrieval.query_stems('что я ел про еду') == ['еду']


def test_haystack_covers_title_overview_and_transcript():
    haystack = selfhost_retrieval.conversation_haystack(
        _conversation('x', title='Обед', overview='паста', segments=('было вкусно',))
    )

    assert 'обед' in haystack and 'паста' in haystack and 'вкусно' in haystack
