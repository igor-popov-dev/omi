"""Behavioral contract for re-admitting finished conversations nobody retried.

A synchronous processing failure rolls the admission back to ``in_progress`` and
trusts the producer to retry. When the producer stops (the app gives up after a
few 500s), the recording is finished, whole and owned by nobody: no finalization
job, so the durable replay never sees it; not ``processing``, so the crash-orphan
sweep never sees it. These tests pin the recovery: the sweep re-admits exactly
those rows through the ordinary durable admission, admission itself is what stops
it repeating, and the two users a background job may not act for -- an account
mid-cutover and a BYOK user -- are never admitted.
"""

from __future__ import annotations

from datetime import datetime, timedelta, timezone
from unittest.mock import MagicMock

from services import conversation_finalization as service

_FINISHED = datetime.now(timezone.utc) - timedelta(seconds=1000)


def _candidate(uid: str, conversation_id: str) -> dict:
    return {'uid': uid, 'conversation_id': conversation_id, 'finished_at': _FINISHED}


def _install(monkeypatch, candidates, *, exhausted: bool = True, resume_after_path: str | None = None):
    """Wire the sweep to a fixed candidate window and a fake admission."""
    monkeypatch.setattr(service.jobs_db, 'get_abandoned_in_progress_finalize_after', lambda: timedelta(seconds=900))
    monkeypatch.setattr(
        service.jobs_db,
        'get_abandoned_in_progress_candidates',
        lambda **kwargs: {
            'candidates': list(candidates),
            'resume_after_path': resume_after_path,
            'exhausted': exhausted,
        },
    )
    monkeypatch.setattr(
        service.jobs_db,
        'get_abandoned_in_progress_sweep_cursor',
        lambda **kwargs: {'resume_after_path': None, 'generation': 4},
    )
    advance_cursor = MagicMock(return_value=True)
    monkeypatch.setattr(service.jobs_db, 'advance_abandoned_in_progress_sweep_cursor', advance_cursor)
    monkeypatch.setattr(service, 'should_skip_background_account_mutation', lambda uid: False)
    monkeypatch.setattr(service.users_db, 'is_byok_active', lambda uid, **kwargs: False)
    request = MagicMock(return_value={'job_id': 'job-1', 'route': 'cloud_tasks'})
    monkeypatch.setattr(service.lifecycle_service, 'request_finalization', request)
    return request, advance_cursor


def test_an_abandoned_recording_is_re_admitted_through_the_durable_path(monkeypatch):
    request, _ = _install(monkeypatch, [_candidate('uid-1', 'conversation-1')])

    result = service.reconcile_abandoned_in_progress_conversations()

    assert result == {'requested': 1, 'skipped': 0, 'error': 0}
    request.assert_called_once()
    assert request.call_args.args == ('uid-1', 'conversation-1')
    # Platform credentials only: a background sweep holds no request-scoped keys.
    assert request.call_args.kwargs['has_byok_keys'] is False


def test_a_byok_user_is_never_finalized_on_platform_credentials(monkeypatch):
    request, _ = _install(monkeypatch, [_candidate('uid-1', 'conversation-1')])
    monkeypatch.setattr(service.users_db, 'is_byok_active', lambda uid, **kwargs: True)

    result = service.reconcile_abandoned_in_progress_conversations()

    assert result == {'requested': 0, 'skipped': 1, 'error': 0}
    request.assert_not_called()


def test_an_account_mid_cutover_is_left_alone(monkeypatch):
    request, _ = _install(monkeypatch, [_candidate('uid-1', 'conversation-1')])
    monkeypatch.setattr(service, 'should_skip_background_account_mutation', lambda uid: True)

    result = service.reconcile_abandoned_in_progress_conversations()

    assert result == {'requested': 0, 'skipped': 1, 'error': 0}
    request.assert_not_called()


def test_a_refused_admission_is_a_skip_not_work_done(monkeypatch):
    """`noop` is the transaction fencing the row out (already moved on, discarded,
    nothing to finalize). Counting it as recovery would hide a stuck backlog."""
    request, _ = _install(monkeypatch, [_candidate('uid-1', 'conversation-1')])
    request.return_value = {'job_id': None, 'route': 'noop'}

    result = service.reconcile_abandoned_in_progress_conversations()

    assert result == {'requested': 0, 'skipped': 1, 'error': 0}


def test_an_unavailable_handoff_is_a_skip_not_an_error(monkeypatch):
    """Nothing was persisted, and the next sweep re-scans this window."""
    request, _ = _install(monkeypatch, [_candidate('uid-1', 'conversation-1')])
    request.side_effect = service.lifecycle_service.FinalizationDispatchUnavailable('contended')

    result = service.reconcile_abandoned_in_progress_conversations()

    assert result == {'requested': 0, 'skipped': 1, 'error': 0}


def test_one_failing_row_does_not_stop_the_sweep(monkeypatch):
    request, _ = _install(monkeypatch, [_candidate('uid-1', 'first'), _candidate('uid-1', 'second')])
    request.side_effect = [Exception('firestore unavailable'), {'job_id': 'job-2', 'route': 'cloud_tasks'}]

    result = service.reconcile_abandoned_in_progress_conversations()

    assert result == {'requested': 1, 'skipped': 0, 'error': 1}
    assert request.call_count == 2


def test_a_failed_query_admits_nothing(monkeypatch):
    request, _ = _install(monkeypatch, [_candidate('uid-1', 'conversation-1')])

    def _boom(**kwargs):
        raise RuntimeError('firestore unavailable')

    monkeypatch.setattr(service.jobs_db, 'get_abandoned_in_progress_candidates', _boom)

    result = service.reconcile_abandoned_in_progress_conversations()

    assert result == {'requested': 0, 'skipped': 0, 'error': 1}
    request.assert_not_called()


def test_the_sweep_cursor_advances_under_the_generation_it_read(monkeypatch):
    """Eventual discovery depends on the cursor moving; the CAS generation keeps
    a delayed pod from rewinding another pod's progress."""
    _, advance_cursor = _install(
        monkeypatch, [], exhausted=False, resume_after_path='users/uid-1/conversations/conversation-9'
    )

    service.reconcile_abandoned_in_progress_conversations()

    advance_cursor.assert_called_once()
    assert advance_cursor.call_args.args == (4, 'users/uid-1/conversations/conversation-9')


def test_an_exhausted_sweep_rotates_the_cursor_back_to_the_top(monkeypatch):
    _, advance_cursor = _install(monkeypatch, [], exhausted=True, resume_after_path='users/uid-1/conversations/last')

    service.reconcile_abandoned_in_progress_conversations()

    assert advance_cursor.call_args.args == (4, None)


def test_a_cursor_that_cannot_advance_still_lets_the_sweep_run(monkeypatch):
    """Losing the cursor CAS costs coverage speed, never recovery: the window is
    still swept, and admission fences any row another pod already re-admitted."""
    request, advance_cursor = _install(monkeypatch, [_candidate('uid-1', 'conversation-1')])
    advance_cursor.side_effect = RuntimeError('cursor contention')

    result = service.reconcile_abandoned_in_progress_conversations()

    assert result == {'requested': 1, 'skipped': 0, 'error': 0}
    request.assert_called_once()
