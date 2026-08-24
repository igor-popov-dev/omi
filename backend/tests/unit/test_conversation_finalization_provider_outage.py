"""A model-provider outage must not discard the customer's capture.

Live incident (2026-08-24, self-hosted deployment): the chat provider backing
conversation structuring started refusing every call at 14:05 with a quota
error. Each finalization attempt failed identically, the durable job's attempt
budget was spent within minutes, and dead-lettering marked the conversation
`failed` + `discarded` — three captures of 5 720, 15 048 and 39 392 transcript
segments disappeared from the app while the transcript itself sat intact in the
database. The provider recovered 80 minutes later; nothing brought them back,
because `dead_letter` is terminal.

The attempt budget is the right bound for a payload that fails deterministically.
It is the wrong bound for "the provider cannot answer anyone right now".
"""

from unittest.mock import AsyncMock, MagicMock

import pytest
from fastapi import HTTPException
from langchain_core.exceptions import OutputParserException

from utils.conversations import finalizer as finalizer_module
from utils.conversations.finalizer import ConversationFinalizationError, finalize_persisted_conversation
from utils.llm.claude_bridge_client import ClaudeBridgeUpstreamError
from utils.llm.gateway_error_contract import (
    PROVIDER_UNAVAILABLE_FAILURE_CODE,
    conversation_processing_http_exception,
    is_provider_unavailable_error,
)


@pytest.fixture
def anyio_backend():
    return 'asyncio'


@pytest.mark.parametrize(
    'error',
    [
        ClaudeBridgeUpstreamError('spent', code='usage_limit', resets_at=1787555000),
        ClaudeBridgeUpstreamError('refused', code='upstream_error'),
        HTTPException(status_code=503, detail='provider down'),
        HTTPException(status_code=429, detail='slow down'),
        HTTPException(status_code=529, detail='overloaded'),
    ],
)
def test_retry_later_answers_are_recognised_as_an_outage(error):
    assert is_provider_unavailable_error(error) is True


@pytest.mark.parametrize(
    'error',
    [
        ValueError('bad transcript'),
        OutputParserException('not json'),
        HTTPException(status_code=500, detail='Error processing conversation, please try again later'),
        HTTPException(status_code=400, detail='malformed'),
        HTTPException(status_code=404, detail='gone'),
    ],
)
def test_a_deterministic_failure_is_never_mistaken_for_an_outage(error):
    """The exemption has to stay narrow: a poison payload must still terminate."""
    assert is_provider_unavailable_error(error) is False


def test_the_outage_survives_the_hop_through_the_http_contract():
    """process_conversation re-raises as HTTPException; the code has to survive that."""
    raised = conversation_processing_http_exception(ClaudeBridgeUpstreamError('spent', code='usage_limit'))

    assert raised.status_code == 503
    assert raised.detail['code'] == PROVIDER_UNAVAILABLE_FAILURE_CODE
    assert 'spent' not in str(raised.detail)  # provider text never reaches the client
    assert is_provider_unavailable_error(raised) is True


def test_a_generic_processing_failure_keeps_its_existing_500_contract():
    raised = conversation_processing_http_exception(ValueError('transcript excerpt'))

    assert raised.status_code == 500
    assert 'transcript excerpt' not in str(raised.detail)
    assert is_provider_unavailable_error(raised) is False


async def _finalize_with_processing_error(monkeypatch, error):
    """Drive the finalizer to the point where process_conversation raises."""
    monkeypatch.setattr(
        finalizer_module.conversations_db,
        'get_conversation',
        MagicMock(return_value={'id': 'conversation-1', 'status': 'processing'}),
    )
    conversation = MagicMock()
    conversation.id = 'conversation-1'
    conversation.status = finalizer_module.ConversationStatus.processing
    monkeypatch.setattr(finalizer_module, 'deserialize_conversation', lambda _data: conversation)
    monkeypatch.setattr(finalizer_module, 'get_cached_user_geolocation', MagicMock(return_value=None))

    def raise_processing(*_args, **_kwargs):
        raise error

    monkeypatch.setattr(finalizer_module, 'process_conversation', raise_processing)

    async def inline_run_blocking(_executor, fn, *args, **kwargs):
        return fn(*args, **kwargs)

    monkeypatch.setattr(finalizer_module, 'run_blocking', inline_run_blocking)

    with pytest.raises(ConversationFinalizationError) as excinfo:
        await finalize_persisted_conversation(
            'uid-1',
            'conversation-1',
            'en',
            finalization_job_id='job-1',
            dispatch_generation=3,
            lease_epoch=4,
        )
    return excinfo.value


@pytest.mark.anyio
async def test_finalizer_labels_an_outage_so_the_caller_can_spare_the_budget(monkeypatch):
    error = await _finalize_with_processing_error(
        monkeypatch, HTTPException(status_code=503, detail={'code': PROVIDER_UNAVAILABLE_FAILURE_CODE})
    )

    assert error.failure_code == PROVIDER_UNAVAILABLE_FAILURE_CODE


@pytest.mark.anyio
async def test_finalizer_still_labels_a_deterministic_failure_as_processing_failed(monkeypatch):
    error = await _finalize_with_processing_error(monkeypatch, ValueError('bad transcript'))

    assert error.failure_code == 'processing_failed'
