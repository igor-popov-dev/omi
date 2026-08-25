"""Deleting an empty listen generation must not strand its private-cloud audio.

Private cloud sync uploads audio batches while a recording is still open, so a
generation that ends up empty has already written objects keyed by its
conversation id. Once the row is deleted nothing else ever reads those objects:
they outlive the account they belong to.
"""

from __future__ import annotations

from unittest.mock import MagicMock

import pytest

from database import conversations as conversations_db
from database import recording_sessions as recording_sessions_db
from utils.conversations import lifecycle as lifecycle_service
from utils.other import storage as storage_mod


@pytest.fixture
def cleanup_spies(monkeypatch):
    delete_audio = MagicMock()
    delete_photos = MagicMock()
    monkeypatch.setattr(storage_mod, 'delete_conversation_audio_files', delete_audio)
    monkeypatch.setattr(conversations_db, 'delete_conversation_photos', delete_photos)
    return delete_audio, delete_photos


def _stub_tombstone(monkeypatch, deleted: bool) -> None:
    monkeypatch.setattr(
        recording_sessions_db,
        'tombstone_and_delete_empty_conversation',
        MagicMock(return_value=deleted),
    )


def test_deleting_empty_generation_cascades_to_its_audio(monkeypatch, cleanup_spies):
    delete_audio, delete_photos = cleanup_spies
    _stub_tombstone(monkeypatch, True)

    assert lifecycle_service.delete_empty_recording_conversation('uid', 'conversation', 'session') is True

    delete_photos.assert_called_once_with('uid', 'conversation')
    delete_audio.assert_called_once_with('uid', 'conversation')


def test_refused_deletion_leaves_the_audio_alone(monkeypatch, cleanup_spies):
    """The row gained content between admission and cleanup: it keeps its audio."""
    delete_audio, delete_photos = cleanup_spies
    _stub_tombstone(monkeypatch, False)

    assert lifecycle_service.delete_empty_recording_conversation('uid', 'conversation', 'session') is False

    delete_photos.assert_not_called()
    delete_audio.assert_not_called()


def test_storage_failure_still_reports_the_row_deleted(monkeypatch, cleanup_spies):
    """The row is already gone; a failed sweep must not re-open it as undeletable."""
    delete_audio, _ = cleanup_spies
    delete_audio.side_effect = RuntimeError('bucket unavailable')
    _stub_tombstone(monkeypatch, True)

    assert lifecycle_service.delete_empty_recording_conversation('uid', 'conversation', 'session') is True
