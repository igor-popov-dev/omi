"""Every conversation loses its audio_files records because a name was dropped from an import.

``create_audio_files_from_chunks`` calls ``list_audio_chunks``, which used to be imported at the
top of ``database/conversations.py``. #11858 replaced that import line with a new one instead of
adding beside it, so the name has been unresolvable since. Both call sites
(``process_conversation`` and ``merge_conversations``) wrap the call in ``except Exception`` and
only log, so the NameError never surfaced: conversations simply stopped getting ``audio_files``,
and with them the pre-cache and the conversation-level playback artifact that reads those records.

Every existing test of this path mocks ``create_audio_files_from_chunks`` itself, so its body has
had no coverage at all. These tests exercise the real body with only storage stubbed out, which is
the shape that fails today.
"""

import os

os.environ.setdefault("ENCRYPTION_SECRET", "omi_ZwB2ZNqB2HHpMK6wStk7sTpavJiPTFg7gXUHnc4tFABPU6pZ2c2DKgehtfgi4RZv")
os.environ.setdefault("OPENAI_API_KEY", "sk-test-not-real")

import database.conversations as conversations_db


def _chunk(timestamp: float, size: int = 160000):
    return {'timestamp': timestamp, 'size': size, 'path': f'chunks/uid/conv/{timestamp}.bin'}


def test_module_resolves_the_storage_listing_it_calls():
    """The call in create_audio_files_from_chunks has to resolve to something."""
    assert hasattr(conversations_db, 'list_audio_chunks')


def test_contiguous_chunks_become_one_audio_file(monkeypatch):
    monkeypatch.setattr(
        conversations_db,
        'list_audio_chunks',
        lambda uid, conversation_id: [_chunk(1000.0), _chunk(1005.0), _chunk(1010.0)],
    )

    audio_files = conversations_db.create_audio_files_from_chunks('uid', 'conv')

    assert len(audio_files) == 1
    assert audio_files[0].chunk_timestamps == [1000.0, 1005.0, 1010.0]
    assert audio_files[0].conversation_id == 'conv'


def test_a_gap_past_the_threshold_splits_the_group(monkeypatch):
    # 90s is the documented threshold; 200s apart has to land in separate files.
    monkeypatch.setattr(
        conversations_db,
        'list_audio_chunks',
        lambda uid, conversation_id: [_chunk(1000.0), _chunk(1200.0)],
    )

    audio_files = conversations_db.create_audio_files_from_chunks('uid', 'conv')

    assert [f.chunk_timestamps for f in audio_files] == [[1000.0], [1200.0]]


def test_no_chunks_is_not_an_error(monkeypatch):
    monkeypatch.setattr(conversations_db, 'list_audio_chunks', lambda uid, conversation_id: [])

    assert conversations_db.create_audio_files_from_chunks('uid', 'conv') == []
