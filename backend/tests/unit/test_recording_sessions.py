"""Contract tests for durable listen recording-session routing (#9351)."""

from __future__ import annotations

import copy
import threading
from dataclasses import dataclass, field
from datetime import datetime, timezone
from types import SimpleNamespace
from typing import Any

import pytest

from database import conversations as conversations_db
from database import recording_sessions
from routers.listen.conversations import LiveConversationController
from utils.conversations import lifecycle as lifecycle_service


def _stored_conversation(segments: list[dict[str, Any]], *, level: str = 'standard') -> dict[str, Any]:
    """Encode a conversation exactly as the production write path stores it.

    Seeding a raw ``transcript_segments`` list is what let the empty-cleanup
    guard ship reading a compressed blob as if it were a plain list.
    """
    return conversations_db.encode_conversation_for_write(
        'uid',
        {'id': 'conversation', 'status': 'in_progress', 'transcript_segments': segments},
        level,
    )


@dataclass
class _Snapshot:
    data: dict[str, Any] | None

    @property
    def exists(self) -> bool:
        return self.data is not None

    def to_dict(self) -> dict[str, Any] | None:
        return copy.deepcopy(self.data)


@dataclass
class _DocumentRef:
    firestore: '_FakeFirestore'
    path: tuple[str, ...]

    def get(self, transaction: object = None) -> _Snapshot:
        del transaction
        return _Snapshot(self.firestore.documents.get(self.path))

    def collection(self, name: str) -> '_CollectionRef':
        return _CollectionRef(self.firestore, self.path + (name,))


@dataclass
class _CollectionRef:
    firestore: '_FakeFirestore'
    path: tuple[str, ...]

    def document(self, document_id: str) -> _DocumentRef:
        return _DocumentRef(self.firestore, self.path + (document_id,))

    def where(self, *, filter: Any) -> '_QueryRef':
        return _QueryRef(self.firestore, self.path, (filter,))


@dataclass
class _QueryRef:
    firestore: '_FakeFirestore'
    path: tuple[str, ...]
    filters: tuple[Any, ...]

    def stream(self):
        for path, data in self.firestore.documents.items():
            if path[:-1] != self.path:
                continue
            if all(
                data.get(condition.field_path) == condition.value
                for condition in self.filters
                if condition.op_string == '=='
            ):
                yield _Snapshot(data)


@dataclass
class _Transaction:
    firestore: '_FakeFirestore'

    def create(self, document: _DocumentRef, data: dict[str, Any]) -> None:
        if document.path in self.firestore.documents:
            raise RuntimeError('already exists')
        self.firestore.documents[document.path] = copy.deepcopy(data)

    def update(self, document: _DocumentRef, updates: dict[str, Any]) -> None:
        self.firestore.documents[document.path].update(copy.deepcopy(updates))

    def delete(self, document: _DocumentRef) -> None:
        self.firestore.documents.pop(document.path, None)


@dataclass
class _FakeFirestore:
    documents: dict[tuple[str, ...], dict[str, Any]] = field(default_factory=dict)
    transaction_lock: threading.Lock = field(default_factory=threading.Lock)

    def collection(self, name: str) -> _CollectionRef:
        return _CollectionRef(self, (name,))

    def transaction(self) -> _Transaction:
        return _Transaction(self)


@pytest.fixture
def recording_store(monkeypatch):
    store = _FakeFirestore()

    def transactional(func):
        def locked(transaction, *args, **kwargs):
            with transaction.firestore.transaction_lock:
                return func(transaction, *args, **kwargs)

        return locked

    monkeypatch.setattr(recording_sessions.firestore, 'transactional', transactional)
    return store


def test_retry_keeps_one_canonical_recording_session_binding(recording_store):
    first = recording_sessions.create_or_get_recording_session(
        'uid', 'session', 'conversation', firestore_client=recording_store
    )
    retry = recording_sessions.create_or_get_recording_session(
        'uid', 'session', 'conversation', firestore_client=recording_store
    )

    assert first == retry
    assert first['mapping_conflict'] is False
    assert len(recording_store.documents) == 1


def test_completed_retry_returns_its_canonical_terminal_envelope(recording_store):
    recording_sessions.create_or_get_recording_session(
        'uid', 'recording-one', 'conversation-one', firestore_client=recording_store
    )
    recording_sessions.record_lifecycle_event(
        'uid', 'recording-one', 'conversation-one', 'processing', firestore_client=recording_store
    )
    completed = recording_sessions.record_lifecycle_event(
        'uid', 'recording-one', 'conversation-one', 'completed', firestore_client=recording_store
    )

    retry = recording_sessions.create_or_get_recording_session(
        'uid', 'recording-one', 'new-proposed-conversation', firestore_client=recording_store
    )
    replay = recording_sessions.record_lifecycle_event(
        'uid', 'recording-one', retry['conversation_id'], 'completed', firestore_client=recording_store
    )
    rollover = recording_sessions.create_or_get_recording_session(
        'uid', 'recording-two', 'conversation-two', firestore_client=recording_store
    )

    assert retry['conversation_id'] == 'conversation-one'
    assert retry['mapping_conflict'] is True
    assert replay['accepted'] is True
    assert replay['lifecycle_phase'] == 'completed'
    assert replay['lifecycle_sequence'] == completed['lifecycle_sequence']
    assert rollover['conversation_id'] == 'conversation-two'
    assert len(recording_store.documents) == 2


def test_empty_recording_tombstone_forces_a_fresh_live_generation(recording_store, monkeypatch):
    monkeypatch.setattr(lifecycle_service, 'recording_session_mode', lambda: 'enforce')
    monkeypatch.setattr(lifecycle_service.conversations_db, 'get_conversation', lambda *_, **__: None)
    lifecycle_service.open_recording_session(
        'uid', 'recording-old', 'conversation-old', firestore_client=recording_store
    )

    tombstone = lifecycle_service.tombstone_recording_session(
        'uid', 'recording-old', 'conversation-old', firestore_client=recording_store
    )
    reconnect = lifecycle_service.open_live_recording_session(
        'uid', 'recording-old', 'conversation-old', firestore_client=recording_store
    )
    fresh = lifecycle_service.open_live_recording_session(
        'uid', 'recording-new', 'conversation-new', firestore_client=recording_store
    )
    original = recording_sessions.get_recording_session('uid', 'recording-old', firestore_client=recording_store)

    assert tombstone is not None
    assert tombstone['lifecycle_phase'] == 'discarded'
    assert reconnect['requires_rollover'] is True
    assert fresh['requires_rollover'] is False
    assert fresh['conversation_id'] == 'conversation-new'
    assert fresh['conversation_id'] != reconnect['conversation_id']
    assert original is not None
    assert original['lifecycle_phase'] == 'discarded'


def test_missing_active_binding_is_tombstoned_before_rollover(recording_store, monkeypatch):
    monkeypatch.setattr(lifecycle_service, 'recording_session_mode', lambda: 'enforce')
    monkeypatch.setattr(lifecycle_service.conversations_db, 'get_conversation', lambda *_, **__: None)
    lifecycle_service.open_recording_session(
        'uid', 'recording-old', 'conversation-old', firestore_client=recording_store
    )

    reconnect = lifecycle_service.open_live_recording_session(
        'uid', 'recording-old', 'conversation-old', firestore_client=recording_store
    )
    original = recording_sessions.get_recording_session('uid', 'recording-old', firestore_client=recording_store)

    assert reconnect['requires_rollover'] is True
    assert original is not None
    assert original['lifecycle_phase'] == 'discarded'


@pytest.mark.parametrize('level', ['standard', 'enhanced'])
def test_empty_cleanup_atomically_tombstones_its_session(recording_store, level):
    conversation_path = ('users', 'uid', 'conversations', 'conversation')
    recording_store.documents[conversation_path] = _stored_conversation([], level=level)
    recording_sessions.create_or_get_recording_session(
        'uid', 'recording', 'conversation', firestore_client=recording_store
    )

    deleted = recording_sessions.tombstone_and_delete_empty_conversation(
        'uid', 'conversation', 'recording', firestore_client=recording_store
    )
    binding = recording_sessions.get_recording_session('uid', 'recording', firestore_client=recording_store)

    assert deleted is True
    assert conversation_path not in recording_store.documents
    assert binding is not None
    assert binding['lifecycle_phase'] == 'discarded'


@pytest.mark.parametrize('level', ['standard', 'enhanced'])
def test_empty_cleanup_refuses_late_content_without_tombstoning(recording_store, level):
    conversation_path = ('users', 'uid', 'conversations', 'conversation')
    recording_store.documents[conversation_path] = _stored_conversation(
        [{'id': 'late-segment', 'text': 'persisted'}], level=level
    )
    recording_sessions.create_or_get_recording_session(
        'uid', 'recording', 'conversation', firestore_client=recording_store
    )

    deleted = recording_sessions.tombstone_and_delete_empty_conversation(
        'uid', 'conversation', 'recording', firestore_client=recording_store
    )
    binding = recording_sessions.get_recording_session('uid', 'recording', firestore_client=recording_store)

    assert deleted is False
    assert conversation_path in recording_store.documents
    assert binding is not None
    assert binding['lifecycle_phase'] == 'in_progress'


def test_empty_cleanup_keeps_a_conversation_whose_segments_cannot_be_decoded(recording_store):
    conversation_path = ('users', 'uid', 'conversations', 'conversation')
    recording_store.documents[conversation_path] = {
        'id': 'conversation',
        'status': 'in_progress',
        'transcript_segments': b'not-a-zlib-stream',
        'transcript_segments_compressed': True,
    }
    recording_sessions.create_or_get_recording_session(
        'uid', 'recording', 'conversation', firestore_client=recording_store
    )

    deleted = recording_sessions.tombstone_and_delete_empty_conversation(
        'uid', 'conversation', 'recording', firestore_client=recording_store
    )

    assert deleted is False
    assert conversation_path in recording_store.documents


def test_conflicting_retry_returns_the_original_conversation(recording_store):
    recording_sessions.create_or_get_recording_session(
        'uid', 'session', 'first-conversation', firestore_client=recording_store
    )

    result = recording_sessions.create_or_get_recording_session(
        'uid', 'session', 'second-conversation', firestore_client=recording_store
    )

    assert result['conversation_id'] == 'first-conversation'
    assert result['mapping_conflict'] is True


def test_same_recording_id_is_scoped_to_each_user(recording_store):
    one = recording_sessions.create_or_get_recording_session(
        'first-user', 'session', 'first-conversation', firestore_client=recording_store
    )
    two = recording_sessions.create_or_get_recording_session(
        'second-user', 'session', 'second-conversation', firestore_client=recording_store
    )

    assert (one['conversation_id'], two['conversation_id']) == ('first-conversation', 'second-conversation')
    assert len(recording_store.documents) == 2


def test_events_are_monotonic_and_stale_callbacks_are_discarded(recording_store):
    recording_sessions.create_or_get_recording_session(
        'uid', 'session', 'conversation', firestore_client=recording_store
    )

    processing = recording_sessions.record_lifecycle_event(
        'uid', 'session', 'conversation', 'processing', firestore_client=recording_store
    )
    completed = recording_sessions.record_lifecycle_event(
        'uid', 'session', 'conversation', 'completed', firestore_client=recording_store
    )
    stale = recording_sessions.record_lifecycle_event(
        'uid', 'session', 'conversation', 'processing', firestore_client=recording_store
    )

    assert (processing['accepted'], processing['lifecycle_sequence']) == (True, 1)
    assert (completed['accepted'], completed['lifecycle_sequence']) == (True, 2)
    assert stale['accepted'] is False
    assert stale['discard_reason'] == 'terminal_immutable'
    assert stale['lifecycle_sequence'] == 2


@pytest.mark.parametrize('terminal_phase', ('completed', 'failed', 'discarded'))
@pytest.mark.parametrize('replacement_phase', ('completed', 'failed', 'discarded'))
def test_terminal_session_phase_is_immutable(recording_store, terminal_phase, replacement_phase):
    if terminal_phase == replacement_phase:
        return
    recording_sessions.create_or_get_recording_session(
        'uid', 'session', 'conversation', firestore_client=recording_store
    )
    if terminal_phase != 'completed':
        recording_sessions.record_lifecycle_event(
            'uid', 'session', 'conversation', 'processing', firestore_client=recording_store
        )
    terminal = recording_sessions.record_lifecycle_event(
        'uid', 'session', 'conversation', terminal_phase, firestore_client=recording_store
    )
    replacement = recording_sessions.record_lifecycle_event(
        'uid', 'session', 'conversation', replacement_phase, firestore_client=recording_store
    )

    assert replacement['accepted'] is False
    assert replacement['discard_reason'] == 'terminal_immutable'
    assert replacement['lifecycle_sequence'] == terminal['lifecycle_sequence']


def test_event_for_a_different_conversation_is_discarded(recording_store):
    recording_sessions.create_or_get_recording_session(
        'uid', 'session', 'conversation', firestore_client=recording_store
    )

    result = recording_sessions.record_lifecycle_event(
        'uid', 'session', 'other-conversation', 'processing', firestore_client=recording_store
    )

    assert result['accepted'] is False
    assert result['discard_reason'] == 'mapping_conflict'
    assert result['conversation_id'] == 'conversation'


def test_lifecycle_owner_enforces_a_conflicting_durable_binding(recording_store, monkeypatch):
    monkeypatch.setattr(lifecycle_service, 'recording_session_mode', lambda: 'enforce')
    lifecycle_service.open_recording_session('uid', 'session', 'first-conversation', firestore_client=recording_store)

    result = lifecycle_service.open_recording_session(
        'uid', 'session', 'second-conversation', firestore_client=recording_store
    )

    assert result['conversation_id'] == 'first-conversation'
    assert result['mapping_conflict'] is True


def test_shadow_mode_keeps_legacy_route_but_reports_the_mismatch(recording_store, monkeypatch):
    monkeypatch.setattr(lifecycle_service, 'recording_session_mode', lambda: 'shadow')
    lifecycle_service.open_recording_session('uid', 'session', 'first-conversation', firestore_client=recording_store)

    result = lifecycle_service.open_recording_session(
        'uid', 'session', 'second-conversation', firestore_client=recording_store
    )

    assert result['conversation_id'] == 'second-conversation'
    assert result['mapping_conflict'] is True
    assert result['lifecycle_version'] is None
    assert result['lifecycle_phase'] is None
    assert result['lifecycle_sequence'] is None


def test_dual_write_mode_keeps_legacy_route_while_reporting_the_mismatch(recording_store, monkeypatch):
    monkeypatch.setattr(lifecycle_service, 'recording_session_mode', lambda: 'dual_write')
    lifecycle_service.open_recording_session('uid', 'session', 'first-conversation', firestore_client=recording_store)

    result = lifecycle_service.open_recording_session(
        'uid', 'session', 'second-conversation', firestore_client=recording_store
    )

    assert result['conversation_id'] == 'second-conversation'
    assert result['mapping_conflict'] is True
    assert result['lifecycle_version'] is None
    assert result['lifecycle_phase'] is None
    assert result['lifecycle_sequence'] is None


def test_dual_write_mismatch_keeps_legacy_processing_and_completion_events(recording_store, monkeypatch):
    monkeypatch.setattr(lifecycle_service, 'recording_session_mode', lambda: 'dual_write')
    lifecycle_service.open_recording_session('uid', 'session', 'first-conversation', firestore_client=recording_store)
    binding = lifecycle_service.open_recording_session(
        'uid', 'session', 'second-conversation', firestore_client=recording_store
    )

    processing = lifecycle_service.record_recording_session_event(
        'uid', 'session', binding['conversation_id'], 'processing', firestore_client=recording_store
    )
    completed = lifecycle_service.record_recording_session_event(
        'uid', 'session', binding['conversation_id'], 'completed', firestore_client=recording_store
    )
    canonical = recording_sessions.create_or_get_recording_session(
        'uid', 'session', 'first-conversation', firestore_client=recording_store
    )

    expected_legacy_envelope = {
        'recording_session_id': 'session',
        'conversation_id': 'second-conversation',
        'lifecycle_version': None,
        'lifecycle_phase': None,
        'lifecycle_sequence': None,
    }
    assert processing == expected_legacy_envelope
    assert completed == expected_legacy_envelope
    assert canonical['conversation_id'] == 'first-conversation'
    assert canonical['lifecycle_phase'] == 'in_progress'
    assert canonical['lifecycle_sequence'] == 0


def test_shadow_mode_emits_legacy_envelope_when_durable_event_write_fails(monkeypatch):
    fallbacks: list[dict[str, Any]] = []

    def fail(*args, **kwargs):
        del args, kwargs
        raise RuntimeError('unavailable')

    monkeypatch.setattr(lifecycle_service, 'recording_session_mode', lambda: 'shadow')
    monkeypatch.setattr(lifecycle_service.recording_sessions_db, 'record_lifecycle_event', fail)
    monkeypatch.setattr(lifecycle_service, 'record_fallback', lambda **kwargs: fallbacks.append(kwargs))

    event = lifecycle_service.record_recording_session_event('uid', 'session', 'conversation', 'processing')

    assert event == {
        'recording_session_id': 'session',
        'conversation_id': 'conversation',
        'lifecycle_version': None,
        'lifecycle_phase': None,
        'lifecycle_sequence': None,
    }
    assert fallbacks[0]['to_mode'] == 'legacy_pointer'


# ── Reuse the lifecycle-owner's conversation read instead of re-reading it ──
#
# open_live_recording_session already reads the bound conversation once while
# resolving a reconnect. Before this fix, create_new_in_progress_conversation
# read the identical document again by id, doubling a billed Firestore read on
# every resumed live session. See conversation-existence-read.


class _ResumeSessionHost:
    """Wires create_new_in_progress_conversation's persistence.call to the real
    lifecycle_service.open_live_recording_session against a fake firestore, so
    the get_conversation call count reflects what actually happens end to end
    rather than what a mock says happens."""

    def __init__(self, *, firestore_client: Any) -> None:
        self.request = SimpleNamespace(uid='uid', source='omi', call_id=None, conversation_role=None)
        self.client_device_context = SimpleNamespace(client_device_id='dev-1', platform='desktop')
        self.language = 'en'
        self.use_custom_stt = False
        self.private_cloud_sync_enabled = False
        self.client_conversation_id = None
        self.recording_session_id = 'recording-1'
        self.is_multi_channel = False
        self.state = SimpleNamespace(current_conversation_id=None)
        self.recording_session_ids_by_conversation = {}
        self.persistence = SimpleNamespace(call=self._call)
        self._firestore_client = firestore_client

    async def _call(self, fn, *args, **kwargs):
        if fn.__name__ == 'open_live_recording_session':
            return fn(*args, firestore_client=self._firestore_client, **kwargs)
        if fn.__name__ in ('set_in_progress_conversation_id', 'update_conversation'):
            return None
        return fn(*args, **kwargs)


class _ResumeSessionController(LiveConversationController):
    def send_conversation_session(self, *args, **kwargs) -> None:
        pass


@pytest.mark.skip(
    reason="Проверяет апстримовскую оптимизацию conversation-existence-read (один "
    "get_conversation на resume вместо двух), которой в нашей приватной ветке пока нет. "
    "Тест приехал вместе с правкой durable-привязки 26.08; снять skip, когда заберём "
    "саму оптимизацию."
)
async def test_resume_reuses_the_lifecycle_snapshot_instead_of_reading_twice(recording_store, monkeypatch):
    monkeypatch.setattr(lifecycle_service, 'recording_session_mode', lambda: 'enforce')

    get_conversation_calls: list[str] = []
    conversation = {'id': 'conversation-old', 'status': 'in_progress', 'discarded': False}

    def counting_get_conversation(_uid, conversation_id, **_kwargs):
        get_conversation_calls.append(conversation_id)
        return conversation if conversation_id == 'conversation-old' else None

    monkeypatch.setattr(lifecycle_service.conversations_db, 'get_conversation', counting_get_conversation)

    # A prior message on this recording session already created and bound
    # 'conversation-old'; this call is the reconnect that resumes it.
    lifecycle_service.open_recording_session('uid', 'recording-1', 'conversation-old', firestore_client=recording_store)

    host = _ResumeSessionHost(firestore_client=recording_store)
    controller = _ResumeSessionController(host)

    await controller.create_new_in_progress_conversation()

    assert get_conversation_calls == [
        'conversation-old'
    ], f'expected exactly one get_conversation call, got {get_conversation_calls}'
    assert host.state.current_conversation_id == 'conversation-old'


class _OrphanRecoveryHost:
    """A socket that never opened the recording it is asked to finalize.

    Orphan recovery (#9809) and post-rollover completions run exactly here:
    the conversation is someone else's, so ``recording_session_ids_by_conversation``
    is empty and only the durable binding can name the recording.
    """

    def __init__(self, *, firestore_client: Any, conversation: dict[str, Any]) -> None:
        self.request = SimpleNamespace(uid='uid')
        self.recording_session_ids_by_conversation: dict[str, str] = {}
        self.persistence = SimpleNamespace(call=self._call)
        self.events: list[Any] = []
        self._firestore_client = firestore_client
        self._conversation = conversation

    async def _call(self, fn, *args, **kwargs):
        if fn.__name__ in ('recover_recording_session_binding', 'record_recording_session_event'):
            return fn(*args, firestore_client=self._firestore_client, **kwargs)
        if fn.__name__ == 'get_conversation':
            return self._conversation
        raise AssertionError(f'unexpected persistence call {fn.__name__}')

    def send_event(self, event: Any) -> None:
        self.events.append(event)


def _completed_conversation(conversation_id: str) -> dict[str, Any]:
    now = datetime(2026, 8, 26, 9, 0, tzinfo=timezone.utc)
    return {
        'id': conversation_id,
        'created_at': now,
        'started_at': now,
        'finished_at': now,
        'structured': {},
        'status': 'completed',
        'source': 'omi',
        'transcript_segments': [],
        'photos': [],
    }


def test_durable_binding_is_readable_by_conversation_for_a_dead_session(recording_store):
    lifecycle_service.open_recording_session('uid', 'recording-1', 'conversation', firestore_client=recording_store)

    binding = recording_sessions.get_recording_session_for_conversation(
        'uid', 'conversation', firestore_client=recording_store
    )

    assert binding is not None
    assert binding['recording_session_id'] == 'recording-1'
    assert binding['conversation_id'] == 'conversation'
    assert (
        recording_sessions.get_recording_session_for_conversation(
            'uid', 'never-recorded', firestore_client=recording_store
        )
        is None
    )


def test_binding_lookup_returns_the_newest_recording_generation(recording_store):
    """A resumed conversation collects one session per reconnect.

    The client is waiting on the last recording, so an older generation must
    not win the lookup just because it streams first.
    """
    for index, recording_session_id in enumerate(('recording-b', 'recording-a', 'recording-c')):
        lifecycle_service.open_recording_session(
            'uid', recording_session_id, 'conversation', firestore_client=recording_store
        )
        recording_store.documents[('users', 'uid', 'recording_sessions', recording_session_id)]['created_at'] = (
            datetime(2026, 8, 26, 9, index, tzinfo=timezone.utc)
        )

    binding = recording_sessions.get_recording_session_for_conversation(
        'uid', 'conversation', firestore_client=recording_store
    )

    assert binding is not None
    assert binding['recording_session_id'] == 'recording-c'


async def test_orphan_recovery_emits_the_completion_its_socket_never_bound(recording_store, monkeypatch):
    """The event a recovered conversation exists for must reach the client.

    Without the durable read-back the row is finalized and then goes silent:
    the app keeps showing nothing until the user pulls to refresh.
    """
    monkeypatch.setattr(lifecycle_service, 'recording_session_mode', lambda: 'enforce')
    lifecycle_service.open_recording_session('uid', 'recording-dead', 'conversation', firestore_client=recording_store)

    host = _OrphanRecoveryHost(firestore_client=recording_store, conversation=_completed_conversation('conversation'))
    controller = LiveConversationController(host)

    await controller.emit_recording_lifecycle_event('conversation', 'processing')
    await controller.emit_recording_lifecycle_event('conversation', 'completed')

    assert [event.event_type for event in host.events] == ['memory_processing_started', 'memory_created']
    completed = host.events[-1]
    assert completed.recording_session_id == 'recording-dead'
    assert completed.conversation_id == 'conversation'
    assert (completed.lifecycle_phase, completed.lifecycle_sequence) == ('completed', 2)
    # Resolved once, then reused: the second event must not re-read the binding.
    assert host.recording_session_ids_by_conversation == {'conversation': 'recording-dead'}


async def test_lifecycle_event_stays_suppressed_when_no_binding_was_ever_stored(recording_store, monkeypatch):
    monkeypatch.setattr(lifecycle_service, 'recording_session_mode', lambda: 'enforce')

    host = _OrphanRecoveryHost(firestore_client=recording_store, conversation=_completed_conversation('conversation'))
    controller = LiveConversationController(host)

    # Приватное расхождение с upstream: у нас `completed` НЕ подавляется даже без
    # привязки (правка полосы 2 — иначе приложение не узнаёт о готовом разговоре и
    # разговор виснет «в обработке» навсегда). Подавление осталось для in-flight
    # фаз, где привязка действительно обязательна: клиент приписывает `processing`
    # той записи, что идёт прямо сейчас. Проверяем именно эту фазу.
    await controller.emit_recording_lifecycle_event('conversation', 'processing')

    assert host.events == []
    assert host.recording_session_ids_by_conversation == {}
