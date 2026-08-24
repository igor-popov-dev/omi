"""Credential-free executor for one durable listen finalization job.

Two entry points share this executor, and neither may hold BYOK credentials:

* the Cloud Tasks worker route, on deployments that dispatch durably; and
* the in-process reconciler, on deployments that do not have a durable queue
  to replay a stale lease into.

Keeping both on one implementation means a self-hosted deployment recovers a
crashed finalization through exactly the ownership, fencing and dead-letter
protocol the cloud path already relies on.
"""

from __future__ import annotations

import asyncio
import logging
from dataclasses import dataclass
from typing import Any

from database import conversation_finalization_jobs as jobs_db
from database.sync_jobs import release_job_run_lock, try_acquire_job_run_lock
from services.conversation_finalization import (
    final_attempt_failed,
    get_listen_finalization_tasks_max_attempts_for_worker,
)
from utils.account_cutover.access import should_skip_background_account_mutation
from utils.conversations import lifecycle as lifecycle_service
from utils.conversations.finalizer import (
    ConversationFinalizationDisposition,
    ConversationFinalizationError,
    finalize_persisted_conversation,
)
from utils.executors import db_executor, run_blocking
from utils.metrics import LISTEN_FINALIZATION_RETRIES_TOTAL
from utils.observability.journeys import record_capture_finalization_terminal

logger = logging.getLogger(__name__)


@dataclass(frozen=True)
class FinalizationRunResult:
    """The durable outcome of one delivery, independent of any transport."""

    status: str
    reason: str | None = None
    job_status: str | None = None


async def _retry_or_dead_letter(
    job_id: str,
    dispatch_generation: int,
    lease_epoch: int,
    task_retry_count: int,
    reason: str,
) -> bool:
    """Record a task failure; return whether this was the terminal delivery."""
    max_attempts = get_listen_finalization_tasks_max_attempts_for_worker()
    if task_retry_count >= max_attempts - 1:
        marked_dead_letter = await run_blocking(
            db_executor,
            final_attempt_failed,
            job_id,
            dispatch_generation,
            lease_epoch,
            task_retry_count + 1,
        )
        if not marked_dead_letter:
            return False
        return True

    await run_blocking(
        db_executor,
        jobs_db.mark_finalization_retryable,
        job_id,
        dispatch_generation,
        lease_epoch,
        reason,
    )
    LISTEN_FINALIZATION_RETRIES_TOTAL.inc()
    return False


async def execute_finalization_job(
    job_id: str,
    dispatch_generation: int,
    task_retry_count: int | None = None,
) -> FinalizationRunResult:
    """Claim, finalize and close exactly one durable job.

    `task_retry_count` is the transport's delivery counter. Cloud Tasks supplies
    it from the request header; an in-process replay has no such counter, so
    `None` derives it from the job's own persisted attempt count. Both feed the
    same bounded-retry budget, so a job that cannot be finalized dead-letters
    instead of being re-driven forever.
    """
    lock_key = f'listen-finalization:{job_id}'
    lock_token = await run_blocking(db_executor, try_acquire_job_run_lock, lock_key)
    if not lock_token:
        return FinalizationRunResult('locked')

    release_lock = True
    claimed_lease_epoch: int | None = None
    job: dict[str, Any] | None = None
    deliveries: int = task_retry_count or 0
    try:
        claim = await run_blocking(
            db_executor,
            jobs_db.claim_finalization_job,
            job_id,
            dispatch_generation,
        )
        claim_status = claim['status']
        if claim_status == 'completed':
            return FinalizationRunResult('acked', job_status='completed')
        if claim_status in {'leased', 'stale_generation'}:
            return FinalizationRunResult(claim_status)
        if claim_status != 'claimed':
            return FinalizationRunResult('dropped', reason=claim_status)
        claimed_lease_epoch = claim['lease_epoch']
        if claimed_lease_epoch is None:
            logger.error('listen finalization claim returned no lease epoch job=%s', job_id)
            return FinalizationRunResult('retry')
        if task_retry_count is None:
            # The claim just incremented the persisted attempt count, and the
            # transport counter is zero-based on first delivery.
            deliveries = max(0, int(claim['attempt_count'] or 1) - 1)

        job = await run_blocking(db_executor, jobs_db.get_finalization_job, job_id)
        if not job or not isinstance(job.get('uid'), str) or not isinstance(job.get('conversation_id'), str):
            terminal = await _retry_or_dead_letter(
                job_id, dispatch_generation, claimed_lease_epoch, deliveries, 'invalid_job'
            )
            if terminal:
                logger.error('listen finalization final attempt failed job=%s error=invalid_job', job_id)
                return FinalizationRunResult('dead_letter')
            return FinalizationRunResult('retry')

        if await run_blocking(db_executor, should_skip_background_account_mutation, job['uid']):
            # Prequeued finalization must not mutate migrating/new accounts.
            completed = await run_blocking(
                db_executor,
                lifecycle_service.complete_fenced_finalization,
                job_id,
                dispatch_generation,
                claimed_lease_epoch,
            )
            if not completed:
                return FinalizationRunResult('completion_conflict')
            record_capture_finalization_terminal('stale', job.get('created_at'))
            return FinalizationRunResult('skipped', reason='account_cutover')

        try:
            disposition = await finalize_persisted_conversation(
                job['uid'],
                job['conversation_id'],
                finalization_job_id=job_id,
                dispatch_generation=dispatch_generation,
                lease_epoch=claimed_lease_epoch,
                force_process=bool(job.get('force_process')),
                final_attempt=deliveries >= get_listen_finalization_tasks_max_attempts_for_worker() - 1,
            )
        except ConversationFinalizationError:
            terminal = await _retry_or_dead_letter(
                job_id, dispatch_generation, claimed_lease_epoch, deliveries, 'processing_failed'
            )
            if terminal:
                logger.error('listen finalization final attempt failed job=%s failure=processing_failed', job_id)
                return FinalizationRunResult('dead_letter')
            return FinalizationRunResult('retry')

        if disposition == ConversationFinalizationDisposition.fenced:
            completed = await run_blocking(
                db_executor,
                lifecycle_service.complete_fenced_finalization,
                job_id,
                dispatch_generation,
                claimed_lease_epoch,
            )
        else:
            completed = await run_blocking(
                db_executor,
                jobs_db.mark_finalization_completed,
                job_id,
                dispatch_generation,
                claimed_lease_epoch,
            )
        if not completed:
            return FinalizationRunResult('completion_conflict')
        accepted_at = job.get('created_at') if job else None
        if disposition == ConversationFinalizationDisposition.fenced:
            record_capture_finalization_terminal('stale', accepted_at)
        else:
            record_capture_finalization_terminal('success', accepted_at)
        return FinalizationRunResult('done')
    except asyncio.CancelledError:
        release_lock = False
        logger.warning('listen finalization handler cancelled job=%s; preserving run lock until TTL', job_id)
        raise
    except Exception:
        if claimed_lease_epoch is not None:
            try:
                terminal = await _retry_or_dead_letter(
                    job_id,
                    dispatch_generation,
                    claimed_lease_epoch,
                    deliveries,
                    'worker_failed',
                )
            except Exception:
                logger.error('listen finalization recovery update failed job=%s failure=worker_failed', job_id)
            else:
                if terminal:
                    logger.error('listen finalization final attempt failed job=%s failure=worker_failed', job_id)
                    return FinalizationRunResult('dead_letter')
                return FinalizationRunResult('retry')
        logger.error('listen finalization handler failed job=%s failure=worker_failed', job_id)
        return FinalizationRunResult('retry')
    finally:
        if release_lock:
            await run_blocking(db_executor, release_job_run_lock, lock_key, lock_token)
