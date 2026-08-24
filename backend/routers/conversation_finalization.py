"""Protected Cloud Tasks worker for durable listen conversation finalization."""

from __future__ import annotations

import logging
from typing import Any

from fastapi import APIRouter, Depends, Request
from fastapi.responses import JSONResponse

from services.listen_finalization_worker import FinalizationRunResult, execute_finalization_job
from utils.cloud_tasks import verify_listen_finalization_cloud_tasks_oidc

logger = logging.getLogger(__name__)

router = APIRouter()

# How each durable outcome answers Cloud Tasks. 5xx asks for another delivery;
# 409 says another owner holds the job; 200 ends this delivery for good.
_TASK_HTTP_STATUS: dict[str, int] = {
    'done': 200,
    'acked': 200,
    'dropped': 200,
    'dead_letter': 200,
    'skipped': 200,
    'locked': 409,
    'leased': 409,
    'stale_generation': 409,
    'completion_conflict': 409,
    'retry': 500,
}


def _parse_task_payload(payload: Any) -> tuple[str, int] | None:
    """Accept exactly the opaque durable task schema, never credential fields."""
    if not isinstance(payload, dict) or set(payload) != {'job_id', 'dispatch_generation'}:
        return None
    job_id = payload.get('job_id')
    generation = payload.get('dispatch_generation')
    if not isinstance(job_id, str) or not job_id or len(job_id) > 128:
        return None
    if not isinstance(generation, int) or isinstance(generation, bool) or generation < 1:
        return None
    return job_id, generation


def _task_response(result: FinalizationRunResult) -> JSONResponse:
    content: dict[str, Any] = {'status': result.status}
    if result.reason is not None:
        content['reason'] = result.reason
    if result.job_status is not None:
        content['job_status'] = result.job_status
    return JSONResponse(status_code=_TASK_HTTP_STATUS.get(result.status, 500), content=content)


@router.post('/v1/conversation-finalization-jobs/run', include_in_schema=False)
async def run_listen_finalization_job(
    request: Request,
    task_retry_count: int = Depends(verify_listen_finalization_cloud_tasks_oidc),
):
    try:
        parsed = _parse_task_payload(await request.json())
    except Exception:
        parsed = None
    if parsed is None:
        logger.warning('listen finalization handler dropped invalid opaque task payload')
        return JSONResponse(status_code=200, content={'status': 'dropped', 'reason': 'invalid_payload'})

    job_id, dispatch_generation = parsed
    return _task_response(await execute_finalization_job(job_id, dispatch_generation, task_retry_count))
