"""Regression: a recovered conversation's completion must still reach the client.

`LiveConversationController.emit_recording_lifecycle_event` reads the recording-session
binding from `host.recording_session_ids_by_conversation`, which is a plain dict owned by
one WebSocket. Two finalization paths deliberately act on conversations that socket never
opened: `process_pending` re-dispatches every row still stuck in `processing`, and
`recover_stale_in_progress` (#9809) rescues rows orphaned by sessions that died. Their
bindings live on sockets that are gone, so the lookup misses and the guard returned before
sending anything.

The effect is one-sided: the server finalizes the conversation, the client is never told.
The mobile client only removes the processing card and inserts the conversation when
`memory_created` arrives, so a recovered conversation stayed unfinished on screen until a
manual refresh.

`processing` is different and stays suppressed: clients read it as "the capture running
right now is being saved" — the mobile client stamps the current session's pending WAL
audio with the conversation id the event carries — so a foreign conversation must not
claim it.

Seam: the controller takes only a host, so these drive the real emitter against a host
stub that records `send_event`. No patching, no sys.modules mutation.
"""

from datetime import datetime, timezone
from types import SimpleNamespace

from routers.listen.conversations import LiveConversationController


def _conversation(conversation_id: str) -> dict:
    now = datetime.now(timezone.utc)
    return {
        'id': conversation_id,
        'created_at': now,
        'started_at': now,
        'finished_at': now,
        'structured': {'title': '', 'overview': ''},
        'transcript_segments': [],
        'photos': [],
        'status': 'completed',
        'source': 'omi',
    }


class _Host:
    """Minimal listen host recording the events the socket would have sent."""

    def __init__(self, *, bindings: dict[str, str], conversation: dict | None) -> None:
        self.request = SimpleNamespace(uid='uid-1')
        self.recording_session_ids_by_conversation = dict(bindings)
        self.persistence = SimpleNamespace(call=self._call)
        self.events: list = []
        self.recorded_phases: list[tuple[str, str, str]] = []
        self._conversation = conversation

    def send_event(self, event) -> None:
        self.events.append(event)

    async def _call(self, fn, *args, **_kwargs):
        if fn.__name__ == 'get_conversation':
            return self._conversation
        if fn.__name__ == 'record_recording_session_event':
            _uid, recording_session_id, conversation_id, phase = args
            self.recorded_phases.append((recording_session_id, conversation_id, phase))
            return {
                'recording_session_id': recording_session_id,
                'conversation_id': conversation_id,
                'lifecycle_version': 1,
                'lifecycle_phase': phase,
                'lifecycle_sequence': 3,
            }
        raise AssertionError(f'unexpected persistence call {fn.__name__}')


async def test_completion_of_a_recovered_conversation_reaches_the_client():
    """The finalizing socket has no binding for a rescued row; the client still needs it."""
    host = _Host(bindings={}, conversation=_conversation('conv-orphan'))

    await LiveConversationController(host).emit_recording_lifecycle_event('conv-orphan', 'completed')

    assert len(host.events) == 1, f'completion was dropped: {host.events}'
    event = host.events[0]
    assert event.event_type == 'memory_created'
    assert event.memory.id == 'conv-orphan'
    assert event.conversation_id == 'conv-orphan'


async def test_unbound_completion_carries_no_ordered_envelope():
    """No binding means no ordered envelope can be minted, so the additive fields stay
    absent and the event travels the documented compatibility route."""
    host = _Host(bindings={}, conversation=_conversation('conv-orphan'))

    await LiveConversationController(host).emit_recording_lifecycle_event('conv-orphan', 'completed')

    event = host.events[0]
    assert event.recording_session_id is None
    assert event.lifecycle_version is None
    assert event.lifecycle_phase is None
    assert event.lifecycle_sequence is None
    assert host.recorded_phases == [], 'an unbound event must not persist a session lifecycle record'


async def test_bound_completion_keeps_its_ordered_envelope():
    """The owning socket's completion is unchanged: persisted and versioned."""
    host = _Host(bindings={'conv-1': 'session-1'}, conversation=_conversation('conv-1'))

    await LiveConversationController(host).emit_recording_lifecycle_event('conv-1', 'completed')

    assert host.recorded_phases == [('session-1', 'conv-1', 'completed')]
    event = host.events[0]
    assert event.recording_session_id == 'session-1'
    assert event.lifecycle_version == 1
    assert event.lifecycle_phase == 'completed'
    assert event.lifecycle_sequence == 3


async def test_unbound_processing_stays_suppressed():
    """`processing` claims the live capture. A conversation this socket never opened must
    not take that attribution — the mobile client would stamp the current session's WAL
    audio with the recovered conversation's id."""
    host = _Host(bindings={}, conversation=_conversation('conv-orphan'))

    await LiveConversationController(host).emit_recording_lifecycle_event('conv-orphan', 'processing')

    assert host.events == [], f'a foreign processing event must not be emitted: {host.events}'


async def test_bound_processing_is_still_emitted():
    """The owning socket's in-flight phase is unaffected."""
    host = _Host(bindings={'conv-1': 'session-1'}, conversation=_conversation('conv-1'))

    await LiveConversationController(host).emit_recording_lifecycle_event('conv-1', 'processing')

    assert len(host.events) == 1
    assert host.events[0].event_type == 'memory_processing_started'


async def test_a_deleted_conversation_emits_nothing():
    """Recovery races deletion: a row that is gone by emit time has nothing to announce."""
    host = _Host(bindings={}, conversation=None)

    await LiveConversationController(host).emit_recording_lifecycle_event('conv-gone', 'completed')

    assert host.events == []
