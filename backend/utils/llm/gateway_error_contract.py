"""Privacy-safe gateway failure details consumed at backend composition boundaries."""

from __future__ import annotations

import logging
from collections.abc import Mapping
from enum import Enum

from fastapi import HTTPException

BYOK_RATE_LIMIT_FAILURE_CLASS = 'byok_rate_limit'
GATEWAY_CREDENTIAL_FAILURE_CODE = 'credential_failure'
PROVIDER_UNAVAILABLE_FAILURE_CODE = 'provider_unavailable'
PROVIDER_UNAVAILABLE_ERROR_DETAIL = {
    'code': PROVIDER_UNAVAILABLE_FAILURE_CODE,
    'message': 'The model provider is temporarily unavailable. This will be retried automatically.',
}
# Transport-level "come back later" answers. A provider that says this has not
# rejected the work itself, so retrying the same conversation later can still
# succeed - unlike a validation or parsing failure, which repeats forever.
_PROVIDER_UNAVAILABLE_STATUS_CODES = frozenset({429, 502, 503, 504, 529})
BYOK_RATE_LIMIT_ERROR_DETAIL = {
    'code': BYOK_RATE_LIMIT_FAILURE_CLASS,
    'message': 'The configured provider account is rate limited. Please retry later or check its limits.',
}
GENERIC_CONVERSATION_PROCESSING_ERROR_DETAIL = 'Error processing conversation, please try again later'

logger = logging.getLogger(__name__)


def is_byok_rate_limit_gateway_error(error: BaseException) -> bool:
    """Return whether ``error`` is the gateway's typed BYOK rate-limit failure.

    Gateway code may be raised directly in in-process tests, while production
    callers receive either the gateway's OpenAI-compatible error envelope or
    its unwrapped ``error`` member through the SDK. Require both the credential
    error code and the explicit failure class so generic provider 429s and other
    BYOK credential failures remain distinct.
    """
    if (
        _string_value(getattr(error, 'code', None)) == GATEWAY_CREDENTIAL_FAILURE_CODE
        and _string_value(getattr(error, 'failure_class', None)) == BYOK_RATE_LIMIT_FAILURE_CLASS
    ):
        return True

    if getattr(error, 'status_code', None) != 429:
        return False

    body = getattr(error, 'body', None)
    if not isinstance(body, Mapping):
        return False
    gateway_error = body.get('error', body)
    if not isinstance(gateway_error, Mapping):
        return False
    return (
        _string_value(gateway_error.get('code')) == GATEWAY_CREDENTIAL_FAILURE_CODE
        and _string_value(gateway_error.get('failure_class')) == BYOK_RATE_LIMIT_FAILURE_CLASS
    )


def is_provider_unavailable_error(error: BaseException) -> bool:
    """Return whether ``error`` means "the provider could not answer right now".

    Callers use this to keep an outage from looking like a poison-pill payload.
    A conversation that failed because the provider was rate limited or down is
    still perfectly finalizable once the provider returns, so it must not spend
    a durable job's attempt budget (see ``utils.pusher_finalization``).

    Three shapes count, deliberately narrow so a deterministic failure never
    passes: the gateway's typed BYOK rate limit, a provider client that marks
    itself unavailable (``provider_unavailable``), and a bare transport status
    from the retry-later family.
    """
    if is_byok_rate_limit_gateway_error(error):
        return True
    if getattr(error, 'provider_unavailable', False):
        return True
    status = getattr(error, 'status_code', None)
    return isinstance(status, int) and not isinstance(status, bool) and status in _PROVIDER_UNAVAILABLE_STATUS_CODES


def _string_value(value: object) -> str | None:
    if isinstance(value, str):
        return value
    if isinstance(value, Enum) and isinstance(value.value, str):
        return value.value
    return None


def conversation_processing_http_exception(error: BaseException) -> HTTPException:
    """Map a processing failure to the existing safe HTTP contract.

    The caller is the authoritative conversation composition boundary. Logging
    the BYOK case by its bounded class avoids leaking provider error bodies,
    while every other exception retains the existing generic response and a
    privacy-safe log entry.
    """
    if is_byok_rate_limit_gateway_error(error):
        logger.warning('Conversation processing halted because the configured BYOK provider is rate limited')
        return HTTPException(status_code=429, detail=BYOK_RATE_LIMIT_ERROR_DETAIL)
    if getattr(error, 'provider_unavailable', False):
        # 503 keeps the outage legible to whoever re-raises this: the finalizer
        # reads it back through is_provider_unavailable_error and keeps the job
        # retryable instead of dead-lettering the customer's conversation.
        logger.warning('Conversation processing halted because the model provider is unavailable')
        return HTTPException(status_code=503, detail=PROVIDER_UNAVAILABLE_ERROR_DETAIL)
    logger.error('Conversation processing failed: %s', type(error).__name__)
    return HTTPException(status_code=500, detail=GENERIC_CONVERSATION_PROCESSING_ERROR_DETAIL)
