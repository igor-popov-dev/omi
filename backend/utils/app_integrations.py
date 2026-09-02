import asyncio
import re
import threading
from datetime import datetime, timezone
from collections import Counter
from math import log, sqrt
from typing import List
import os
import time

import httpx

from utils.http_client import (
    safe_request_target,
    UnsafeWebhookURLError,
    get_webhook_client,
    get_webhook_circuit_breaker,
    get_webhook_semaphore,
    latest_wins_start,
    latest_wins_check,
)
from utils.executors import db_executor, postprocess_executor, run_blocking
from utils.async_tasks import gather_safe
import utils.dev_cache as dev_cache

import database.notifications as notification_db
from database._client import db as firestore_db
import database.dev_api_key as dev_api_key_db
from database import mem_db
from database import redis_db
from database.apps import get_app_by_id_db, record_app_usage
from database.redis_db import delete_app_cache_by_id
from database.webhook_health import (
    ACTION_DISABLE,
    ACTION_REDIRECT_NOT_FOLLOWED,
    ACTION_WARN_DAY1,
    ACTION_WARN_DAY2,
    record_app_webhook_failure,
    record_app_webhook_success,
    is_app_webhook_disabled,
    disable_app_in_firestore,
)
from database.chat import add_app_message, get_app_messages
from database.goals import get_user_goals
from database.notifications import get_mentor_notification_frequency
from database.users import get_user_language_preference
from utils.subscription import is_trial_paywalled
from database.redis_db import (
    get_generic_cache,
    set_generic_cache,
    incr_daily_notification_count,
    get_daily_notification_count,
)
from models.app import App, ProactiveNotification, UsageHistoryType
from models.chat import Message
from models.conversation import Conversation
from models.conversation_enums import ConversationSource, ConversationStatus
from utils.conversations.factory import deserialize_conversations
from utils.conversations.render import conversations_to_string
from utils.llm.temporal import current_date_for_uid
from models.notification_message import NotificationMessage
from utils.apps import get_available_apps
from utils.notifications import send_notification, send_notification_async
from utils.llm.clients import generate_embedding, get_llm
from utils.llm.proactive_notification import (
    evaluate_relevance,
    generate_notification,
    validate_notification,
    FREQUENCY_TO_BASE_THRESHOLD,
    MAX_DAILY_NOTIFICATIONS,
)
from utils.llm.usage_tracker import track_usage, Features
from utils.llms.memory import get_prompt_memories
from database.vector_db import query_vectors_by_metadata
import database.conversations as conversations_db
from utils.conversations.render import conversation_to_dict, serialize_datetimes
from utils.log_sanitizer import sanitize
from utils.mentor_notifications import process_mentor_notification
from utils.journey_metrics_contract import ClientKind, bounded_client_kind, resolve_client_kind
from utils.observability.fallback import record_fallback
from utils.observability.journeys import ClientJourneyAttempt
import logging

logger = logging.getLogger(__name__)


class ExternalIntegrationFanoutError(RuntimeError):
    """At least one durable finalization webhook did not acknowledge delivery."""


# A retry only helps when the destination may answer differently next time.
# Webhook health tracking (`record_app_webhook_failure`) owns the permanent
# case: it warns the app owner and auto-disables the webhook after 72h.
_RETRYABLE_DELIVERY_STATUSES = frozenset({408, 425, 429})


def _delivery_failure_is_retryable(status_code: int) -> bool:
    """Whether a non-2xx webhook response leaves the finalization job retryable."""
    return status_code >= 500 or status_code in _RETRYABLE_DELIVERY_STATUSES


def _drop_exhausted_delivery(app_id: str, reason: str) -> None:
    """Give up on a delivery whose finalization job has no attempt left.

    On the terminal attempt the job dead-letters no matter what this delivery
    does, so keeping it retryable buys the webhook nothing and costs the user
    the whole conversation: fanout never completes and the capture journey ends
    in `failure`. An app endpoint answering 5xx for days (Cloudflare 530) took
    every conversation of every user who installed it down with it, because
    webhook health only auto-disables after 72h.
    """
    logger.info('durable webhook delivery dropped on final attempt app=%s reason=%s', app_id, reason)
    record_fallback(
        component='webhook',
        from_mode='durable_delivery',
        to_mode='dropped',
        reason=reason,
        outcome='exhausted',
    )


def _notify_app_owner(app_id: str, title: str, body: str):
    """Send a push notification to the app owner about webhook health."""
    try:
        app_data = get_app_by_id_db(app_id)
        if app_data and app_data.get('uid'):
            send_notification(app_data['uid'], title, body)
    except Exception as e:
        logger.warning(f'Failed to notify app owner for {app_id}: {e}')


def _handle_webhook_health_action(app_id: str, action: int, error: str):
    """Handle graduated response from webhook health tracking.
    action: 0=nothing, 1=day1 warn, 2=day2 warn, 3=auto-disable,
    4=redirect not followed (notify only)
    """
    if action == ACTION_REDIRECT_NOT_FOLLOWED:
        logger.warning(f'Webhook health: app {app_id} endpoint redirects and was not delivered. {error}')
        _notify_app_owner(
            app_id,
            'Webhook Endpoint Redirects',
            f'Your app webhook returned a redirect ({error[:40]}), so the payload was not delivered. '
            'For security we do not follow redirects. Update the webhook URL to the final destination '
            '(check for a missing/extra trailing slash or an http:// to https:// upgrade).',
        )
    elif action == ACTION_WARN_DAY1:
        logger.warning(f'Webhook health: app {app_id} failing for 24h+ (day 1 warning). Last error: {error}')
        _notify_app_owner(
            app_id,
            'Webhook Failing',
            f'Your app webhook has been failing for 24+ hours. Error: {error[:100]}. '
            'Please check your endpoint. It will be auto-disabled in 48 hours if failures continue.',
        )
    elif action == ACTION_WARN_DAY2:
        logger.warning(f'Webhook health: app {app_id} failing for 48h+ (day 2 final warning). Last error: {error}')
        _notify_app_owner(
            app_id,
            'Webhook Final Warning',
            f'Your app webhook has been failing for 48+ hours. Error: {error[:100]}. '
            'It will be auto-disabled in 24 hours if failures continue.',
        )
    elif action == ACTION_DISABLE:
        logger.error(f'Webhook health: auto-disabling app {app_id} after 72h+ of failures. Last error: {error}')
        disable_app_in_firestore(app_id, error, 72)
        delete_app_cache_by_id(app_id)
        _notify_app_owner(
            app_id,
            'Webhook Auto-Disabled',
            f'Your app has been auto-disabled after 72+ hours of webhook failures. Error: {error[:100]}. '
            'Fix your endpoint, then open the app in your developer dashboard and press Re-enable.',
        )


PROACTIVE_NOTI_LIMIT_SECONDS = 30  # 1 noti / 30s


def get_github_docs_content(repo="BasedHardware/omi", path="docs/doc"):
    """
    Recursively retrieves content from GitHub docs folder and subfolders using GitHub API.
    Returns a dict mapping file paths to their raw content.

    If cached, returns cached content. (24 hours)
    So any changes to the docs will take 24 hours to be reflected.
    """
    if cached := get_generic_cache(f'get_github_docs_content_{repo}_{path}'):
        return cached
    docs_content = {}
    headers = {"Authorization": f"token {os.getenv('GITHUB_TOKEN')}"}

    def get_contents(path):
        url = f"https://api.github.com/repos/{repo}/contents/{path}"
        response = httpx.get(url, headers=headers, timeout=30.0)

        if response.status_code != 200:
            logger.error(f"Failed to fetch contents for {path}: {response.status_code}")
            return

        contents = response.json()

        if not isinstance(contents, list):
            return

        for item in contents:
            if item["type"] == "file" and (item["name"].endswith(".md") or item["name"].endswith(".mdx")):
                # Get raw content for documentation files
                raw_response = httpx.get(item["download_url"], headers=headers, timeout=30.0)
                if raw_response.status_code == 200:
                    docs_content[item["path"]] = raw_response.text

            elif item["type"] == "dir":
                # Recursively process subfolders
                get_contents(item["path"])

    get_contents(path)
    set_generic_cache(f'get_github_docs_content_{repo}_{path}', docs_content, 60 * 24 * 7)
    return docs_content


# **************************************************
# ************* EXTERNAL INTEGRATIONS **************
# **************************************************


async def trigger_external_integrations(
    uid: str,
    conversation: Conversation,
    *,
    idempotency_key: str | None = None,
    require_delivery: bool = False,
    last_delivery_attempt: bool = False,
) -> list:
    """ON CONVERSATION CREATED — uses asyncio.gather + httpx (Lane 1).

    Finalization workers provide a durable key so a lease replay can safely
    retry an interrupted external fanout without creating a second effect.
    They also require a delivery acknowledgement, preserving the existing
    best-effort behavior for non-finalization callers.

    `last_delivery_attempt` marks the finalization job's terminal attempt: the
    retry budget is spent, so a failed delivery is dropped with telemetry
    instead of failing the conversation's fanout one final time.
    """
    if not conversation or conversation.discarded:
        return []
    if conversation.is_locked:
        return []

    client_kind = resolve_client_kind(
        x_app_platform=getattr(conversation, 'client_platform', None),
        user_agent=None,
    )
    apps: List[App] = await run_blocking(db_executor, get_available_apps, uid)
    filtered_apps = [app for app in apps if app.triggers_on_conversation_creation() and app.enabled]
    if not filtered_apps:
        return []

    results = {}
    failed_deliveries: list[str] = []

    async def _single(app: App):
        if not app.external_integration.webhook_url:
            return

        if await run_blocking(db_executor, is_app_webhook_disabled, app.id):
            return

        conversation_dict = conversation_to_dict(conversation)

        # Ignore external data on workflow
        if conversation.source == ConversationSource.workflow and 'external_data' in conversation_dict:
            conversation_dict['external_data'] = None

        url = app.external_integration.webhook_url
        journey_attempt = ClientJourneyAttempt('app_webhook_delivery', client_kind)
        if '?' in url:
            url += '&uid=' + uid
        else:
            url += '?uid=' + uid

        # SSRF guard: a developer-configured webhook that resolves to a
        # private/loopback/link-local/metadata address is a configuration
        # error, not a delivery failure — reject it without recording a
        # failure, tripping the circuit breaker, or failing the durable
        # fan-out. Resolution is a blocking getaddrinfo call, so offload it
        # to the owned db executor rather than stalling the event loop.
        try:
            pinned_url, pin_kwargs = await run_blocking(db_executor, safe_request_target, url)
        except UnsafeWebhookURLError as e:
            journey_attempt.fail('invalid_response')
            logger.warning('Rejected non-public webhook URL for app %s: %s', app.id, e)
            return

        cb = get_webhook_circuit_breaker(url)
        if not cb.allow_request():
            journey_attempt.fail('dependency_unavailable')
            logger.info(f'trigger_external_integrations: circuit breaker open for {app.id}')
            if require_delivery:
                if last_delivery_attempt:
                    _drop_exhausted_delivery(app.id, 'circuit_open')
                else:
                    failed_deliveries.append(app.id)
            return

        try:
            payload = serialize_datetimes(conversation_dict)
            headers = dict(pin_kwargs['headers'])
            if idempotency_key:
                headers['X-Omi-Idempotency-Key'] = idempotency_key
            async with get_webhook_semaphore():
                client = get_webhook_client()
                response = await client.post(
                    pinned_url,
                    json=payload,
                    headers=headers,
                    extensions=pin_kwargs['extensions'],
                    follow_redirects=False,
                )
            if response.status_code < 200 or response.status_code >= 300:
                journey_attempt.fail('upstream_rejected')
                cb.record_failure()
                error_str = f'HTTP {response.status_code}'
                action = await run_blocking(
                    db_executor, record_app_webhook_failure, app.id, response.status_code, error_str
                )
                await run_blocking(db_executor, _handle_webhook_health_action, app.id, action, error_str)
                logger.info(
                    f'App integration failed {app.id} status: {response.status_code} result: {sanitize(response.text[:100])}'
                )
                if require_delivery:
                    if _delivery_failure_is_retryable(response.status_code):
                        if last_delivery_attempt:
                            _drop_exhausted_delivery(
                                app.id,
                                'provider_429' if response.status_code == 429 else 'provider_5xx',
                            )
                        else:
                            failed_deliveries.append(app.id)
                    else:
                        # The destination rejected this payload permanently (expired
                        # OAuth token, deleted target, malformed for that app). Every
                        # retry repeats it verbatim, so keeping the conversation's
                        # finalization job retryable would only strand the
                        # conversation until the job dead-letters.
                        record_fallback(
                            component='webhook',
                            from_mode='durable_delivery',
                            to_mode='dropped',
                            reason='auth' if response.status_code in (401, 403) else 'policy',
                            outcome='degraded',
                        )
                return

            journey_attempt.succeed()
            cb.record_success()
            await run_blocking(db_executor, record_app_webhook_success, app.id)

            if app.uid is not None:
                if app.uid != uid:
                    await run_blocking(
                        db_executor,
                        record_app_usage,
                        uid,
                        app.id,
                        UsageHistoryType.memory_created_external_integration,
                        conversation_id=conversation.id,
                    )
            else:
                await run_blocking(
                    db_executor,
                    record_app_usage,
                    uid,
                    app.id,
                    UsageHistoryType.memory_created_external_integration,
                    conversation_id=conversation.id,
                )

            try:
                if message := response.json().get('message', ''):
                    results[app.id] = message
            except Exception:
                pass
        except Exception as e:
            journey_attempt.fail('upstream_timeout' if isinstance(e, TimeoutError) else 'provider_error')
            cb.record_failure()
            error_str = type(e).__name__
            action = await run_blocking(db_executor, record_app_webhook_failure, app.id, 0, error_str)
            await run_blocking(db_executor, _handle_webhook_health_action, app.id, action, error_str)
            logger.error('Plugin integration request failed app=%s error=%s', app.id, type(e).__name__)
            if require_delivery:
                if last_delivery_attempt:
                    _drop_exhausted_delivery(app.id, 'timeout' if isinstance(e, TimeoutError) else 'other')
                else:
                    failed_deliveries.append(app.id)
            return

    await gather_safe(*[_single(app) for app in filtered_apps], label="trigger_integrations", max_concurrency=10)

    if failed_deliveries:
        raise ExternalIntegrationFanoutError(f'{len(failed_deliveries)} durable integration deliveries failed')

    messages = []
    for key, message in results.items():
        if not message:
            continue
        messages.append(await run_blocking(db_executor, add_app_message, message, key, uid, conversation.id))
    return messages


async def trigger_realtime_integrations(
    uid: str,
    segments: list[dict],
    conversation_id: str | None,
    source: str | None = None,
    *,
    client_kind: ClientKind = 'unknown',
):
    logger.info(f"trigger_realtime_integrations {uid}")
    """REALTIME STREAMING"""
    return await _async_trigger_realtime_integrations(
        uid,
        segments,
        conversation_id,
        source=source,
        client_kind=bounded_client_kind(client_kind),
    )


async def trigger_realtime_audio_bytes(uid: str, sample_rate: int, data: bytearray):
    logger.info(f"trigger_realtime_audio_bytes {uid}")
    """REALTIME AUDIO STREAMING"""
    return await _async_trigger_realtime_audio_bytes(uid, sample_rate, data)


# proactive notification
def _retrieve_contextual_memories(uid: str, user_context):
    vector = generate_embedding(user_context.get('question', '')) if user_context.get('question') else [0] * 3072
    logger.info(f"query_vectors vector: {vector[:5]}")

    date_filters = {}  # not support yet
    filters = user_context.get('filters', {})
    memories_id = query_vectors_by_metadata(
        uid,
        vector,
        dates_filter=[date_filters.get("start"), date_filters.get("end")],
        people=filters.get("people", []),
        topics=filters.get("topics", []),
        entities=filters.get("entities", []),
        dates=filters.get("dates", []),
    )
    convos = conversations_db.get_conversations_by_id(uid, memories_id)
    return [c for c in convos if not c.get('is_locked')]


def _hit_proactive_notification_rate_limits(uid: str, app: App):
    sent_at = mem_db.get_proactive_noti_sent_at(uid, app.id)
    if sent_at and time.time() - sent_at < PROACTIVE_NOTI_LIMIT_SECONDS:
        return True

    # remote
    sent_at = redis_db.get_proactive_noti_sent_at(uid, app.id)
    if not sent_at:
        return False
    ttl = redis_db.get_proactive_noti_sent_at_ttl(uid, app.id)
    if ttl > 0:
        mem_db.set_proactive_noti_sent_at(uid, app_id=app.id, ts=int(time.time() + ttl), ttl=ttl)

    return time.time() - sent_at < PROACTIVE_NOTI_LIMIT_SECONDS


def _set_proactive_noti_sent_at(uid: str, app: App):
    ts = time.time()
    mem_db.set_proactive_noti_sent_at(uid, app_id=app.id, ts=int(ts), ttl=PROACTIVE_NOTI_LIMIT_SECONDS)
    redis_db.set_proactive_noti_sent_at(uid, app_id=app.id, ts=int(ts), ttl=PROACTIVE_NOTI_LIMIT_SECONDS)


def _is_developer(uid: str) -> bool:
    """A user with at least one developer API key is treated as a developer and
    is exempt from the daily proactive-notification cap (#3346), so building and
    testing an app is not throttled. Result is cached (in ``utils.dev_cache``, and
    invalidated on dev-key changes) to keep the cap check off the Firestore hot
    path. Fails closed (treats the user as a non-developer, and does not cache the
    failure) so a lookup error never silently lifts the cap for everyone."""
    cached = dev_cache.get_cached_developer(uid)
    if cached is not None:
        return cached
    try:
        result = bool(dev_api_key_db.get_dev_keys_for_user(uid))
    except Exception as e:
        logger.warning(f"proactive daily cap: developer check failed uid={uid}, applying cap: {e}")
        return False
    dev_cache.set_cached_developer(uid, result)
    return result


def _proactive_daily_cap_reached(uid: str) -> bool:
    """True when the user has already received the day's allotment of proactive
    notifications. Counts every proactive source together (mentor + third-party
    apps) against one per-user daily budget, and exempts developers (#3346)."""
    if _is_developer(uid):
        return False
    return (get_daily_notification_count(uid) or 0) >= MAX_DAILY_NOTIFICATIONS


MENTOR_RATE_LIMIT_SECONDS = 300  # 5 minutes between mentor notifications

# The cheapest gate call is the one not made. One attempt costs 0.342% of the user's five-hour
# subscription window (lane7 tick 59) — 81k tokens, 92% of them the facts block — and the live
# mentor spends 52% of a window a day on attempts, while 105 attempts in the production log
# already died with "You've hit your session limit". A buffer that carries almost no speech
# cannot produce a notification: the gate is asked to point at a SPECIFIC thing the user is
# agreeing to, scheduling or committing to in the current conversation, and four characters of
# "Угу" contain nothing to point at.
#
# Measured on the live path (25.08, lane7 tick 64, marathon/deploy/lane7-buffer-substance.py),
# 73 distinct production buffers with 506 gate draws between them, paired prompt-to-score inside
# one bridge session:
#
#     substance, chars   buffers   draws   max score   >=0.78
#              0- 200        16      19        0.15         0
#            200- 500        11      23        0.93        10
#            500-1500        22     209        0.91        33
#           1500+            24     255        0.91        77
#
# The lowest-substance buffer that ever cleared the threshold carries 391 characters; nothing
# below 353 has ever scored above 0.20. The gap is in the SCORES, not in the lengths — the
# lengths run continuously (3, 4, 12, 35, 51, 57, 59, 75, 125, ...) — so this cannot be a
# plateau-centre constant like MENTOR_PAST_MIN_TRANSCRIPT_CHARS. It is a margin: 200 leaves
# 191 characters between the rule and the poorest material that has ever passed, and it is the
# same number tick 51 arrived at by reading the live windows by eye.
#
# The obvious objection is that one live draw proves little, because the gate is bimodal — the
# same rich prompt scored 0.10 and 0.91 on different draws (tick 48). Re-drawn deliberately:
# a 4-character buffer gave 0.02 five times out of five, a 129-character one 0.10/0.10/0.10/
# 0.10/0.15, and a 184-character one 0.05/0.05/0.15. Poor buffers are not bimodal; there is
# nothing for the draw to disagree about.
#
# Nothing is lost by staying silent here. The trigger hands over the WHOLE accumulated buffer,
# not just the new segments (utils/mentor_notifications.py), so a conversation skipped now is
# evaluated again a few segments later with everything it said meanwhile still in it.
#
# Set to 0 to disable the rule — no buffer is shorter than nothing, so the comparison itself
# is the switch and there is no second branch to keep honest.
MENTOR_MIN_BUFFER_CHARS = 200


def _buffer_substance_chars(messages: list[dict]) -> int:
    """How much speech the buffer actually carries, ignoring the speaker markup around it.

    Counted the same way the past-conversation rule counts a transcript
    (`_has_context_for_mentor`): the texts themselves. The rendered block is not the measure —
    "[Игорь]: " is nine characters per line, so ten "Угу" render as 130 characters of nothing.
    """
    return sum(len(str((m or {}).get('text') or '').strip()) for m in (messages or []))


# Firestore can stop answering entirely, and on this deployment it does so daily. The project is
# on the free plan, whose 50k document reads per day run out: the log shows windows of refusal on
# 21.08 and again on 23.08 (08:49-09:56, then from 19:57), each lasting an hour or more.
#
# It is the READS that run out, and only them — measured inside a live window 23.08 21:26
# (marathon/deploy, lane7-quota-scope.py): reads refused while writes, Firebase Auth and FCM all
# answered in under a second. So the mentor's problem here is never "the backend is down"; it is
# that everything it needs to know is unreadable while everything it wants to do still works.
# What burns the quota is not established — the periodic sweeps were the obvious suspect and were
# measured at about 5% of a day's reads, so it is spread across the ordinary request paths
# (marathon/deploy/lane7-read-cost.py prices them, once the reads come back).
#
# Blind is not slow: the cheapest possible read, one document by id, retried for 256 seconds and
# then failed with `429 Quota exceeded`. That is what makes this worth handling here rather than
# leaving to each read's own fallback. The chain reads Firestore six times in a row (frequency,
# facts, goals, recent notifications, past conversations, language) and each one waits out its own
# retry deadline, so a single doomed run can hold a postprocess_executor worker for close to half
# an hour — while the transcript path that started it, which waits only
# MENTOR_PIPELINE_TIMEOUT_SECONDS, gave up on the result minutes ago.
#
# So remember the refusal for a minute. The first run to hit a blind database pays for it once,
# says so out loud, and every run that follows leaves immediately instead of paying again. The
# memory is per-process, which is where the cost is: the worker pool it protects is per-process
# too. One minute is short enough that the mentor comes back on its own within a minute of the
# quota resetting, and long enough to cover the runs of one busy conversation.
MENTOR_DB_BLIND_COOLDOWN_SECONDS = 60

# One refused read is not a blind database. The chain already survives a single failed input on
# purpose — a mentor with no goals, or no past conversations, is worse than a whole one but far
# better than silence, and there is a test holding that open. What the daily quota produces is a
# different animal: every read fails, one after another, for hours. Two refusals in one run is
# the cheapest thing that tells them apart, and it costs one extra doomed read to learn.
MENTOR_DB_BLIND_AFTER_FAILURES = 2
_mentor_db_blind_until = 0.0
_mentor_db_blind_lock = threading.Lock()

# The cooldown above stops the chain paying twice, but the first payment is still a full retry
# deadline: measured in a live window 23.08, run 1 spent 287.7 seconds before it learned what the
# database would have told it in half a second, and only then went quiet for the minute. One user
# runs one chain at a time (_mentor_runs_in_flight), so no pool is flooded — but a postprocess
# worker sits on a doomed run for most of every minute of a window that lasts hours, while the
# transcript path that started it gave up at MENTOR_PIPELINE_TIMEOUT_SECONDS.
#
# So ask cheaply first. One document by id, no retries, short deadline: a healthy database
# answers in a fraction of a second, and a blind one refuses immediately — 429 comes back at
# once, it is the retrying that takes minutes (measured 0.07-0.62 s per refusal, same window).
# The cost of asking is one read per run, and the chain runs about fifty times a day here — a
# tenth of a percent of the daily quota to stop spending five minutes out of every six on a
# question already answered.
MENTOR_DB_PROBE_TIMEOUT_SECONDS = 5.0


def _mentor_db_probe(uid: str) -> bool:
    """Whether Firestore is answering reads at all, asked in one cheap question.

    Reads the same user document the frequency setting lives in, so the probe is the chain's
    own first question rather than a synthetic one. A refusal mutes the mentor exactly as a
    refusal mid-chain does — the run that follows leaves on the cooldown instead of retrying.
    """
    try:
        firestore_db.collection('users').document(uid).get(
            field_paths=['mentor_notification_frequency'],
            retry=None,
            timeout=MENTOR_DB_PROBE_TIMEOUT_SECONDS,
        )
        return True
    except Exception as e:
        _mark_mentor_db_blind(uid, 'probe', e)
        return False


def _mentor_db_blind() -> bool:
    """Whether a recent run of the chain found Firestore refusing read after read."""
    with _mentor_db_blind_lock:
        return time.time() < _mentor_db_blind_until


def _mark_mentor_db_blind(uid: str, step: str, error: Exception) -> None:
    """Record that Firestore is refusing the mentor's reads, and name the silence it causes.

    Logged at error level on purpose: without it a blind database and "nothing worth saying"
    look identical in the log — the same absence of `gate_rejected` — and telling them apart
    took a tick of hand measurement against the live account.
    """
    global _mentor_db_blind_until
    with _mentor_db_blind_lock:
        _mentor_db_blind_until = time.time() + MENTOR_DB_BLIND_COOLDOWN_SECONDS
    logger.error(
        f"mentor_proactive db_unavailable uid={uid} step={step} error={type(error).__name__} "
        f"muted_for={MENTOR_DB_BLIND_COOLDOWN_SECONDS}s"
    )


def _mentor_db_reader(uid: str):
    """A reader for the chain's Firestore inputs that notices when the database stops answering.

    Each read still degrades softly on its own — the caller gets the fallback and carries on —
    but the refusals are counted across the run, and MENTOR_DB_BLIND_AFTER_FAILURES of them mute
    the mentor for a cooldown. Returns `(value, ok)`; `ok` is False when the value is the
    fallback, which is not the same as a read that legitimately returned nothing (the output
    language is the one caller that cares about the difference).
    """
    failures: list[str] = []

    def read(step: str, fetch, fallback):
        if _mentor_db_blind():
            return fallback, False
        try:
            return fetch(), True
        except Exception as e:
            failures.append(step)
            if len(failures) >= MENTOR_DB_BLIND_AFTER_FAILURES:
                _mark_mentor_db_blind(uid, step, e)
            else:
                logger.error(f"mentor_proactive {step}_failed uid={uid} error={e}")
            return fallback, False

    return read


# Every app notification is titled "<app name> says", built in English at the payload boundary and
# shared by every caller. For the mentor that title is the line above the suggestion on the lock
# screen — so a user whose notification text is carefully written in their language (#5214) still
# reads an English header first. Localise it only for the mentor, and only for languages we can
# actually write: an unlisted language keeps the shared English form rather than a machine guess.
_MENTOR_NOTIFICATION_TITLES = {'ru': 'Подсказка Omi'}


def _mentor_notification_title(output_language: str) -> str | None:
    """Title for the mentor's push, or None to keep the shared "<app name> says" form."""
    lang = (output_language or '').strip().lower()
    return _MENTOR_NOTIFICATION_TITLES.get(lang.split('-')[0])


# The mentor fires *during* a conversation, so the past conversation most worth connecting to is
# usually the most recent one — and that is exactly the one still in progress, with no title or
# overview yet. Rendered as a summary it is a dated blank, indistinguishable from silence. Give
# those the tail of their transcript instead, bounded: five of them is the worst case, and the
# chain already runs against a wall-clock budget.
MENTOR_PAST_TRANSCRIPT_FALLBACK_CHARS = 1200

# How many past conversations the mentor is shown, and how deep we look to find that many.
#
# Taking the five most recent ones outright assumes every conversation document carries
# something to read. On this deployment that is false: the phone opens a conversation
# whenever it connects, so a document with zero segments — or a single "Угу." — is written
# each time the device reconnects, and those are *newer* than every real conversation.
# Measured on the live account (23.08): four of the five most recent documents were such
# husks, so the block that exists to hold "yesterday you said you fly out Thursday at two"
# spent four of its five slots on dated blanks. The husks are a defect one layer down
# (lanes 1/2 own it); the mentor must not go blind while it stands.
#
# So read deeper and keep the ones that have something to say. The depth is bounded because
# each document carries its transcript: this is one Firestore read either way, just wider.
MENTOR_PAST_CONVERSATIONS = 5
MENTOR_PAST_CONVERSATIONS_SCANNED = 15

# ...and a count is not a reach. The block exists for "yesterday you said you fly out Thursday
# at two", which is a claim about HOURS, while the depth above is a claim about DOCUMENTS — and
# the exchange rate between them is the user's talking rate, which swings by an order of
# magnitude within one day. Measured on the live account (23.08, lane7 tick 24,
# marathon/deploy/lane7-past-span.py): the same fifteen documents reach back
#
#     3.0 hours   during a busy stretch (median over the 12 newest positions)
#    39.1 hours   across the quiet night before it
#
# so the depth that comfortably held yesterday at 4am holds one afternoon at 6pm, and the class
# the block was built for silently leaves it exactly when the user is talking the most — the
# hours where a commitment is most likely to be made twice.
#
# So state the reach and let the depth follow it: read the usual window, and only when it turns
# out to be shallower than the target read once more, wider. A quiet account pays nothing (its
# first read already reaches back a day); a busy one pays a second read for the hours it needs.
# The wide read is capped because each document carries its transcript, and this sits on the
# live transcript path.
MENTOR_PAST_HOURS_TARGET = 24.0
# The cap was 45 until it was measured against the store the mentor actually reads. The
# instrument that sized it had been pointed at Firestore, which this deployment stopped
# writing to; there the account held 35 documents spanning 43h, so 45 looked generous.
# The live store holds 140 spanning 79h, and the production log agrees: every deepened read
# logs reach_now=10.2h against a 24h target — the second read has never once met it.
# Measured on the live store: 45 docs reach 11.5h, 80 reach 28.7h, 100 reach 31.8h; the
# reads cost 12ms, 25ms and 28ms. Only MENTOR_PAST_CONVERSATIONS of them ever enter a
# prompt, so a wider scan buys reach without paying a single extra token.
MENTOR_PAST_CONVERSATIONS_SCANNED_DEEP = 80
# A conversation still being written has no summary yet — that is what the transcript
# fallback above is for — so "has something to say" cannot mean "has a summary". One lone
# segment is the reconnect husk; two is the shortest exchange that can carry a commitment.
MENTOR_PAST_MIN_SEGMENTS = 2


def _mentor_conversation_time(conversation: dict):
    """When this conversation happened, as an aware datetime, or None if it cannot be told."""
    when = conversation.get('created_at') or conversation.get('started_at')
    if not isinstance(when, datetime):
        return None
    return when if when.tzinfo is not None else when.replace(tzinfo=timezone.utc)


def _mentor_past_reach_hours(conversations: list[dict]) -> float:
    """How many hours back a pool of past conversations reaches from now.

    Returns 0.0 for an empty pool or one whose timestamps are all unreadable — i.e. "reaches
    nothing", which makes the caller read wider rather than trust a window it cannot measure.
    """
    stamps = [t for t in (_mentor_conversation_time(c) for c in conversations) if t is not None]
    if not stamps:
        return 0.0
    return max((datetime.now(timezone.utc) - min(stamps)).total_seconds() / 3600.0, 0.0)


def _read_past_for_mentor(uid: str) -> list[dict]:
    """Read the pool of past conversations the mentor ranks, deep enough to reach yesterday.

    See MENTOR_PAST_HOURS_TARGET: the second read happens only when the first one turns out to
    cover less than the target, and it replaces the first rather than extending it (same query,
    wider limit) so the result stays a plain newest-first page with no seam in the middle.

    A pool short of the limit means the account has no more conversations to give — reading
    wider would return the same documents, so the shallow reach is the true one and is kept.
    """
    recent = conversations_db.get_conversations(uid, limit=MENTOR_PAST_CONVERSATIONS_SCANNED, offset=0) or []
    if len(recent) < MENTOR_PAST_CONVERSATIONS_SCANNED:
        return recent
    reach = _mentor_past_reach_hours(recent)
    if reach >= MENTOR_PAST_HOURS_TARGET:
        return recent
    deeper = conversations_db.get_conversations(uid, limit=MENTOR_PAST_CONVERSATIONS_SCANNED_DEEP, offset=0) or []
    if len(deeper) <= len(recent):
        return recent
    # A deep read that still falls short is the failure this whole path was built to prevent,
    # and until now it looked identical in the log to one that succeeded: both printed a
    # reach_now and moved on. It stayed unnoticed for a day and a half of production that way.
    # A full pool short of the target means the cap is the binding constraint, not the account.
    reach_now = _mentor_past_reach_hours(deeper)
    short = (
        " short_of_target=1"
        if reach_now < MENTOR_PAST_HOURS_TARGET and len(deeper) >= MENTOR_PAST_CONVERSATIONS_SCANNED_DEEP
        else ""
    )
    logger.info(
        f"mentor_proactive past_window_deepened uid={uid} reach={reach:.1f}h "
        f"docs={len(recent)}->{len(deeper)} reach_now={reach_now:.1f}h{short}"
    )
    return deeper


# A conversation the backend failed to finalize is hidden from the mentor by the same flag
# the user's own "discard" sets, and the mentor reads with the default include_discarded=False.
# `fail_and_discard_processing` (utils/conversations/lifecycle.py) marks an infrastructure
# failure `status=failed, discarded=True` — so a night the bridge spent rate-limited does not
# leave the mentor's context merely thinner, it *empties* it, and the emptier it gets the more
# certain the gate's rejection becomes (the gate works by collision with what is already known).
#
# Measured on the live account (24.08, lane7 tick 31, marathon/deploy/lane7-discarded-corpus.py):
#
#     4 conversations visible to the mentor      3 readable, 16 segments
#    20 conversations behind the flag           13 readable, 98 segments   (all 20 status=failed)
#
# The transcript survives the failure — only the summary is missing, and the transcript
# fallback above exists precisely for conversations without one. So read them back.
#
# Only `status=failed` ones. `discard()` is a deliberate user action and leaves the status
# alone; a conversation the user threw away must stay thrown away, and re-reading it would be
# the mentor quoting something they chose to delete. The two are indistinguishable in the one
# case where a user discards an already-failed conversation — that admits a husk the user meant
# to lose, not a private conversation they meant to hide, so it fails in the harmless direction.
#
# Failing soft is deliberate: this shape (include_discarded + statuses) has no declared
# composite index on Firestore, and the fallback in get_conversations covers only the plain
# recent-list query. An exception here would propagate through db_read and cost the mentor the
# whole past-conversation block — i.e. trying to widen the context would narrow it to nothing.
def _read_dead_lettered_for_mentor(uid: str) -> list[dict]:
    """Past conversations hidden by a failed finalization rather than by the user."""
    try:
        hidden = (
            conversations_db.get_conversations(
                uid,
                limit=MENTOR_PAST_CONVERSATIONS_SCANNED_DEEP,
                offset=0,
                include_discarded=True,
                statuses=[ConversationStatus.failed.value],
            )
            or []
        )
        # The `statuses` argument above already asks the store for failed rows only, and this
        # repeats the question in Python. Deliberate: the promise being kept is that a
        # conversation the user deleted never comes back out of the mentor's mouth, and that
        # promise should not rest on a query filter travelling through two interchangeable
        # storage adapters (Firestore and the Mongo-backed client behind database/_client.py)
        # and agreeing. The check is a list comprehension over at most 45 rows; the failure it
        # guards against is silent and unrecoverable.
        return [c for c in hidden if str(c.get('status') or '') == ConversationStatus.failed.value]
    except Exception as e:
        logger.error(f"mentor_proactive dead_letter_read_failed uid={uid} error={e}")
        return []


def _merge_past_for_mentor(primary: list[dict], extra: list[dict]) -> list[dict]:
    """Fold `extra` into `primary`, newest first, without duplicating a document.

    Both reads are newest-first on their own, but concatenating two sorted lists does not
    give a sorted one — and the order is load-bearing twice over: MENTOR_PAST_RECENCY_SLOTS
    reserves a slot for "the newest readable conversation", and _mentor_past_reach_hours
    reads the span. A document with no readable timestamp sorts last rather than crashing
    the comparison; it can still be picked on overlap, it just cannot claim to be the newest.
    """
    seen = {c.get('id') for c in primary if c.get('id')}
    merged = list(primary) + [c for c in extra if c.get('id') and c.get('id') not in seen]
    epoch = datetime.min.replace(tzinfo=timezone.utc)
    return sorted(merged, key=lambda c: _mentor_conversation_time(c) or epoch, reverse=True)


# A summary is evidence that something was said, not evidence of what — and the summariser
# writes prose either way. The live account holds a conversation whose whole transcript is the
# three characters "Ти-" and whose overview is 268 characters explaining, at length, that there
# is nothing here ("вероятно, диктофон сработал случайно"). It passed as readable, ranked well
# on those 268 characters, and on 25.08 took a slot in the block away from a real conversation
# (lane7 tick 63, marathon/deploy/lane7-husks.py). So let a summary vouch for a conversation
# only when the transcript it summarises carries something.
#
# Measured on the live pool of 78: every threshold between 20 and 120 characters drops exactly
# that one document and nothing else — the single-segment documents split into one 3-character
# husk and dictations of 125 characters and up. 200 starts eating the dictations. The value
# below sits in the middle of the plateau rather than at an edge of it, because there is
# nothing in the gap to tune against.
#
# Over the whole 140-document account it is not one husk but six, so this is a class and not an
# accident: 133 readable documents become 127, nothing becomes readable that was not, and the
# six transcripts in full are "Ти-", "Угу", "Кей. Ой.", "О чём нужно знать?", "Это в приложении
# клон." and "Сердце напополам. Так." — each carrying 246 to 306 characters of summary written
# about it. The fourth is a real question and the honest cost of the rule; a question with no
# answer recorded is not something the mentor can collide anything against.
#
# The test applies only to a document that HAS a transcript. A conversation carrying a summary
# and no segments at all is the Omi-STT path, where the summary is the whole of what the mentor
# was ever meant to read; there is no transcript there to disagree with it, and dropping those
# would blind the mentor on that path to save it from one husk.
MENTOR_PAST_MIN_TRANSCRIPT_CHARS = 60


def _has_context_for_mentor(conversation: dict) -> bool:
    """Whether this past conversation can contribute anything the mentor could read."""
    segments = conversation.get('transcript_segments') or []
    with_text = [t for t in (str((s or {}).get('text') or '').strip() for s in segments) if t]
    if len(with_text) >= MENTOR_PAST_MIN_SEGMENTS:
        return True
    if not str((conversation.get('structured') or {}).get('overview') or '').strip():
        return False
    return not with_text or sum(len(t) for t in with_text) >= MENTOR_PAST_MIN_TRANSCRIPT_CHARS


# One slot of the five is reserved for the newest readable conversation no matter what it says.
# It is usually the immediate predecessor of the live one — the same sitting, cut in two by the
# silence timer — so dropping it would break the mentor's sense of what is happening right now.
MENTOR_PAST_RECENCY_SLOTS = 1

# ...and one for the best conversation old enough to be "yesterday". Ranking by overlap alone
# spends every remaining slot on the last few hours, because what a person says now resembles
# what they said an hour ago: measured over the 48 live positions where the deep read fires
# (25.08, lane7 tick 63, marathon/deploy/lane7-oldest-slot.py), the pool reached back 27.8h
# median while the block the model actually read reached 14.3h and cleared 24h in 15 of them.
# The block was built for "yesterday you said you fly out Thursday at two", and that line is
# never in the last few hours by construction — the deep read paid for the hours and the
# ranking handed them back.
#
# Reserving one slot for the highest-scoring document past this age clears the target in all
# 48 positions. It is not free: the displaced candidate scores 0.154 (median worst-of-four)
# against 0.116 for the promoted one, so a third of one slot's relevance buys the day. Zero of
# the 33 exchanges promoted a document with no overlap at all, which is the case that would
# have made it a bad trade.
#
# The floor is the target rather than half of it because the class is dated: a 12h floor moves
# the median to 23.4h but still clears the target in only 22 of 48 — it buys hours without
# buying yesterday. Set to 0 to go back to pure ranking.
MENTOR_PAST_OLDEST_SLOT_HOURS = 24.0

_MENTOR_WORD_RE = re.compile(r'[a-zA-Zа-яёА-ЯЁ0-9]+')
# Prefix length for the crude stemmer below. Russian inflection ("рейс", "рейса", "рейсом")
# otherwise never matches itself, and the backend has no stemmer to borrow — pulling one in to
# rank five documents would not pay for itself. Different words colliding on one prefix
# ("прод" from "продукт" and from "продать") is diffused by the IDF weight: a prefix that
# collides sits in many documents and is worth almost nothing.
_MENTOR_STEM_CHARS = 4


def _mentor_tokens(text: str) -> Counter:
    return Counter(w[:_MENTOR_STEM_CHARS] for w in _MENTOR_WORD_RE.findall(text.lower()) if len(w) >= 4)


def _mentor_conversation_text(conversation: dict) -> str:
    parts = []
    structured = conversation.get('structured') or {}
    for key in ('title', 'overview'):
        value = str(structured.get(key) or '').strip()
        if value:
            parts.append(value)
    for segment in conversation.get('transcript_segments') or []:
        text = str((segment or {}).get('text') or '').strip()
        if text:
            parts.append(text)
    return ' '.join(parts)


def _mentor_cosine(a: Counter, b: Counter, idf: dict) -> float:
    shared = a.keys() & b.keys()
    if not shared:
        return 0.0
    num = sum(a[t] * b[t] * idf.get(t, 0.0) ** 2 for t in shared)
    na = sqrt(sum((a[t] * idf.get(t, 0.0)) ** 2 for t in a))
    nb = sqrt(sum((b[t] * idf.get(t, 0.0)) ** 2 for t in b))
    return num / (na * nb) if na and nb else 0.0


def _pick_past_for_mentor(readable: list[dict], current_messages: list[dict]) -> list[dict]:
    """Choose which of the conversations already read from Firestore go into the prompt.

    Taking the newest five looks like the obvious answer and is the wrong one, because
    "newest five" is not a span of the user's past — it is a span of the user's last few
    minutes. Measured on the live account (23.08, lane7 tick 21,
    marathon/deploy/lane7-lexical-probe.py): the five readable conversations the mentor was
    handed covered **0.7 hours**, while the fifteen documents paid for in the same read
    covered **40 hours**. So the block built for "yesterday you said you fly out Thursday at
    two" was, by construction, showing the last forty-two minutes, and the two-day context
    was fetched from the database and thrown away.

    The other channel that was supposed to reach back — semantic search — is dead here and
    always has been: this deployment runs with no embedding provider, so every single
    ``gate_passed`` in the log carries a ``vector_search_failed`` beside it. Waiting for it
    means waiting forever.

    So rank the documents we already hold by word overlap with the live conversation and
    spend the slots on the ones that earn them. No provider, no extra read: TF-IDF over the
    pool itself (see MENTOR_PAST_CONVERSATIONS_SCANNED and the reach target below it), which is
    small enough that its own document frequencies are the only corpus statistics available and
    good enough to sink the filler words.

    One slot stays with the newest (see MENTOR_PAST_RECENCY_SLOTS). When nothing overlaps at
    all — a live conversation of three words, a pool of husks — every score is zero and this
    degrades exactly to the old newest-first behaviour rather than to an arbitrary pick.
    """
    if len(readable) <= MENTOR_PAST_CONVERSATIONS:
        return readable

    current_text = ' '.join(str((m or {}).get('text') or '') for m in current_messages or [])
    current_tokens = _mentor_tokens(current_text)

    head = readable[:MENTOR_PAST_RECENCY_SLOTS]
    tail = readable[MENTOR_PAST_RECENCY_SLOTS:]
    slots = MENTOR_PAST_CONVERSATIONS - len(head)

    pool_tokens = [_mentor_tokens(_mentor_conversation_text(c)) for c in tail]
    df: Counter = Counter()
    for toks in pool_tokens:
        df.update(toks.keys())
    idf = {tok: log((len(pool_tokens) + 1) / (d + 0.5)) for tok, d in df.items()}
    scored = [_mentor_cosine(current_tokens, toks, idf) for toks in pool_tokens]

    # Ties — and an all-zero pool is nothing but ties — fall back to position, i.e. to time.
    ranked = sorted(range(len(tail)), key=lambda i: (-scored[i], i))
    reserved = _mentor_slot_for_yesterday(tail, scored) if slots > 1 else None
    if reserved is None:
        order = ranked[:slots]
    else:
        order = [reserved] + [i for i in ranked if i != reserved][: slots - 1]
    return head + [tail[i] for i in sorted(order)]


def _mentor_slot_for_yesterday(tail: list[dict], scored: list[float]) -> int | None:
    """Index of the best-scoring conversation old enough to be yesterday, or None if there is none.

    None is the honest answer for an account that has not been talking for a day yet, and it
    leaves the ranking exactly as it was — this slot exists to reach hours that are there, not
    to invent them. A conversation whose timestamp cannot be read is not old enough to be
    trusted with the slot either: it would win the reach on paper (see the reach helper, which
    refuses to count it) and lose it in the prompt.

    Only ever spent when more than one ranked slot exists (see the caller): handing the single
    remaining slot to age would leave the block with no relevance at all.
    """
    if MENTOR_PAST_OLDEST_SLOT_HOURS <= 0:
        return None
    now = datetime.now(timezone.utc)
    old = []
    for i, conversation in enumerate(tail):
        when = _mentor_conversation_time(conversation)
        if when is None:
            continue
        if (now - when).total_seconds() / 3600.0 >= MENTOR_PAST_OLDEST_SLOT_HOURS:
            old.append(i)
    if not old:
        return None
    # Best overlap among the old ones; ties go to the newest of them, which is the one most
    # likely to still be live for the user.
    return max(old, key=lambda i: (scored[i], -i))


def _log_past_block(uid: str, readable: list[dict], picked: list[dict]) -> None:
    """Say how far back the block that actually reaches the prompt goes.

    `past_window_deepened` above reports the reach of the POOL, and the pool is not what the
    model reads: MENTOR_PAST_CONVERSATIONS of it are, chosen by `_pick_past_for_mentor`.
    Raising the cap to 80 made the pool clear the target (28.8h on the live account) and the
    log started reading like success — while the block, measured on the same account over the
    48 positions where the deep read fires (25.08, lane7 tick 63,
    marathon/deploy/lane7-block-reach.py), reaches a median of 14.3 hours and clears 24 in 15
    of them. The quantity the feature is judged by was the one nobody printed.

    The alarm fires only when the pool DID reach back a day and the block did not, i.e. when
    the hours were bought and then left on the table. An account younger than the target has
    nothing to answer for, and saying otherwise would repeat the mistake this line exists to
    correct: a log that calls a healthy state a failure teaches the next reader to skip it.
    """
    if not picked:
        return
    reach = _mentor_past_reach_hours(picked)
    pool_reach = _mentor_past_reach_hours(readable)
    short = ' short_of_target=1' if reach < MENTOR_PAST_HOURS_TARGET <= pool_reach else ''
    logger.info(
        f"mentor_proactive past_block uid={uid} docs={len(picked)}/{len(readable)} "
        f"reach={reach:.1f}h pool_reach={pool_reach:.1f}h{short}"
    )


def _render_past_conversations(uid: str, conversations: list[dict]) -> str:
    """Render the mentor's past-conversation context, never raising into the chain."""
    if not conversations:
        return ''
    # Timestamps in the user's own timezone, not UTC (lane7 tick70). conversations_to_string
    # renders and labels every timestamp in ``tz``; called without it the mentor sees "24 Aug
    # 2026 at 12:10 UTC" for a conversation the user remembers happening at 15:10, and that
    # number lands verbatim on their lock screen. The chat retrieval path already passes it.
    try:
        try:
            tz = notification_db.get_user_time_zone(uid)
        except Exception as e:  # noqa: BLE001 - a timezone lookup must not drop the context
            logger.warning(f"mentor_proactive timezone_lookup_failed uid={uid} error={e}")
            tz = None
        return conversations_to_string(
            deserialize_conversations(conversations[:MENTOR_PAST_CONVERSATIONS]),
            transcript_fallback_chars=MENTOR_PAST_TRANSCRIPT_FALLBACK_CHARS,
            tz=tz,
        )
    except Exception as e:
        logger.error(f"mentor_proactive past_conversations_render_failed uid={uid} error={e}")
        return ''


# Wall-clock budget for one run of the whole gate→generate→critic chain (self-host, lane7).
#
# The chain is awaited by the pusher's per-connection transcript task, so it holds up
# realtime transcript dispatch for that user while it runs; the queue behind it is a
# bounded deque that drops the oldest item when it overflows. Each step already carries
# its own deadline (see proactive_notification._step_timeout_seconds), but a step can be
# retried once by the structured-output parser, so the sum needs its own ceiling.
# A healthy full run measured ~15s.
MENTOR_PIPELINE_TIMEOUT_SECONDS = 150.0


# Result keys whose message is already persisted by the code that produced it, and so must
# not be stored again by the generic result-merging below.
#
# The mentor is the one such key: _process_mentor_proactive_notification stores its text
# right after the push, next to the rate-limit bookkeeping. Storing it here too put the same
# notification into `messages` twice under plugin_id='mentor' — which is exactly what
# get_app_messages(uid, 'mentor') reads back. The user would see the same advice twice in
# /chat/mentor, and the anti-repeat window (limit=20) would hold half as many distinct
# notifications as it is meant to, weakening the rule that write exists to feed.
#
# Keeping the write in the pipeline rather than here is deliberate: on
# MENTOR_PIPELINE_TIMEOUT_SECONDS the caller drops its result while the worker thread runs
# on and still pushes to the phone, so a write living only here would silently lose exactly
# the notifications that were slowest to produce — the ones most likely to repeat.
_SELF_STORING_RESULT_KEYS = frozenset({'mentor'})


# One mentor chain per user at a time.
#
# The 5-minute cooldown is read at the top of the chain and written at the very bottom,
# after the push — so the whole gate→generate→critic run sits inside that window, and a
# second run started meanwhile reads no cooldown at all and pushes again right behind the
# first. That is the opposite of what the rate limit is for, and the user feels it as the
# mentor spamming.
#
# The transcript dispatcher normally awaits one item before starting the next, so the
# overlap needs a trigger: on MENTOR_PIPELINE_TIMEOUT_SECONDS the caller drops its result
# and moves on to the next item while this thread keeps running to completion and still
# pushes (threads are not cancellable). Precisely the slowest runs — the ones most likely
# to be retried by the structured-output parser — are the ones that overlap.
#
# Skipping rather than waiting is deliberate: a queued second run would deliver the same
# advice about the same conversation seconds later, and waiting would pin a
# postprocess_executor worker for the length of a whole chain. This guard is per-process;
# the redis-backed cooldown still covers the multi-process case.
_mentor_runs_lock = threading.Lock()
_mentor_runs_in_flight: set[str] = set()


def _process_mentor_proactive_notification(uid: str, conversation_messages: list[dict]) -> str | None:
    """Run the mentor chain for `uid`, unless one is already running for them."""
    with _mentor_runs_lock:
        if uid in _mentor_runs_in_flight:
            logger.info(f"mentor_proactive already_running uid={uid}")
            return None
        _mentor_runs_in_flight.add(uid)
    try:
        return _run_mentor_proactive_chain(uid, conversation_messages)
    finally:
        with _mentor_runs_lock:
            _mentor_runs_in_flight.discard(uid)


def _run_mentor_proactive_chain(uid: str, conversation_messages: list[dict]) -> str | None:
    """
    Three-step proactive notification pipeline:
      1. Gate  — is this conversation worth evaluating? (cheap, rejects most)
      2. Generate — produce the actual notification (only if gate passes)
      3. Critic — would a human actually want this on their phone? (final check)

    Returns:
        The notification text if sent, None otherwise.
    """
    # 0. Is there anything here at all? This comes before the database reads, not just before
    # the gate: a skipped run also skips the facts page and the 80-document past read.
    substance = _buffer_substance_chars(conversation_messages)
    if substance < MENTOR_MIN_BUFFER_CHARS:
        logger.info(
            f"mentor_proactive buffer_too_thin uid={uid} chars={substance} "
            f"msgs={len(conversation_messages or [])} min={MENTOR_MIN_BUFFER_CHARS}"
        )
        return None

    # 1. Get frequency setting
    if _mentor_db_blind():
        logger.info(f"mentor_proactive db_blind_cooldown uid={uid}")
        return None
    if not _mentor_db_probe(uid):
        return None
    db_read = _mentor_db_reader(uid)
    # The entry read is the one exception to the two-failure rule: a frequency nobody could read
    # is not a soft input the chain can do without — it is the setting that decides whether the
    # mentor is allowed to speak at all, and guessing it would mean speaking uninvited.
    try:
        frequency = get_mentor_notification_frequency(uid)
    except Exception as e:
        _mark_mentor_db_blind(uid, 'frequency', e)
        return None
    if frequency == 0:
        return None

    base_threshold = FREQUENCY_TO_BASE_THRESHOLD.get(frequency)
    if base_threshold is None:
        return None

    # 2. Rate limit check (5 min gap)
    mentor_sent_at = mem_db.get_proactive_noti_sent_at(uid, 'mentor')
    if mentor_sent_at and time.time() - mentor_sent_at < MENTOR_RATE_LIMIT_SECONDS:
        logger.info(f"mentor_proactive rate_limited uid={uid}")
        return None
    # Check remote rate limit
    remote_sent_at = redis_db.get_proactive_noti_sent_at(uid, 'mentor')
    if remote_sent_at and time.time() - remote_sent_at < MENTOR_RATE_LIMIT_SECONDS:
        logger.info(f"mentor_proactive rate_limited_remote uid={uid}")
        return None

    # 3. Daily cap check (shared budget across all proactive sources; devs exempt)
    if _proactive_daily_cap_reached(uid):
        logger.info(f"mentor_proactive daily_cap_reached uid={uid}")
        return None

    # 4. Gather lightweight context (no vector search yet — save for step 2)
    (user_name, user_facts), _ok = db_read('memories', lambda: get_prompt_memories(uid), ('User', ''))
    goals, _ok = db_read('goals', lambda: get_user_goals(uid, limit=3), [])
    recent_notifications, _ok = db_read('recent_notifications', lambda: get_app_messages(uid, 'mentor', limit=20), [])

    # Recent-by-time conversations belong to this lightweight step, not to the post-gate one.
    # The gate is the only place that decides whether anything is sent at all, so context it
    # cannot see can never produce a notification — and the collision worth interrupting for
    # ("you just agreed to Thursday afternoon; yesterday you said you fly out Thursday at two")
    # is never in the last ten lines, it is in yesterday's conversation. This is one Firestore
    # read with no embedding provider behind it; the expensive semantic search stays after the
    # gate, and the passing path now reuses this fetch instead of repeating it.
    def _read_all_past() -> list[dict]:
        recent_convos = _merge_past_for_mentor(_read_past_for_mentor(uid), _read_dead_lettered_for_mentor(uid))
        readable = [rc for rc in (recent_convos or []) if not rc.get('is_locked') and _has_context_for_mentor(rc)]
        picked = _pick_past_for_mentor(readable, conversation_messages)
        _log_past_block(uid, readable, picked)
        return picked

    all_past, _ok = db_read('past_conversations', _read_all_past, [])

    past_conversations_str = _render_past_conversations(uid, all_past)

    # Resolve the user's output language once so the notification is generated in it, not English
    # (the daily summary already respects this setting) (#5214). Resolved BEFORE the gate, not
    # between the gate and the generate step: the gate's `reasoning` is what the generate step
    # reads as `gate_reasoning`, and a gate left to answer in the prompt's language hands the next
    # step an English argument to write a Russian notification from (measured on the live path:
    # 6 of 9 gate answers on the user's own conversations came back in English).
    #
    # A read that comes back empty is a user who has set no preference, and English is the right
    # answer for them. A read that does not come back at all is a different thing wearing the same
    # clothes, and answering it with English is how the user already met this feature: the first
    # live suggestion he ever saw, on his lock screen on 23.08, was in English while his account
    # said `ru`. With the database blind for fourteen hours a day, falling back to English here
    # would reproduce that on every evening suggestion. Say nothing instead — the mentor is an
    # interruption, and an interruption in the wrong language is worse than silence.
    output_language, language_known = db_read('language', lambda: get_user_language_preference(uid) or 'en', '')
    if not language_known:
        logger.info(f"mentor_proactive language_unknown uid={uid} — staying silent rather than defaulting to English")
        return None

    # "Today" as the user's calendar shows it, not UTC (lane7 tick70). Between 21:00 and
    # midnight Moscow time the UTC date is still yesterday, and every "today"/"yesterday" in
    # the notification flips. current_date_for_uid falls back to UTC on any lookup failure.
    try:
        mentor_current_date = current_date_for_uid(uid)
    except Exception as e:  # noqa: BLE001 - date grounding must not abort the chain
        logger.warning(f"mentor_proactive current_date_failed uid={uid} error={e}")
        mentor_current_date = None

    # ── Step 1: Gate ─────────────────────────────────────────────────────
    try:
        with track_usage(uid, Features.PROACTIVE_NOTIFICATION):
            relevance = evaluate_relevance(
                user_name=user_name,
                user_facts=user_facts,
                goals=goals,
                current_messages=conversation_messages,
                recent_notifications=recent_notifications,
                past_conversations_str=past_conversations_str,
                output_language=output_language,
                current_date=mentor_current_date,
            )
    except Exception as e:
        logger.error(f"mentor_proactive gate_failed uid={uid} error={e}")
        return None

    if not relevance.is_relevant or relevance.relevance_score < base_threshold:
        # A rejection line that carries only the score cannot be read back. Sixty of them
        # accumulated on the live account before anyone tried, and answering "was the gate
        # starved or was the day simply uneventful" then took stitching this line to the
        # buffer line in another module, log position by log position — while the two facts
        # that actually separate the cases, `is_relevant` and the size of the context the
        # gate was handed, were never written down at all.
        #
        # `relevant` is the load-bearing one: `is_relevant=False` is the model refusing, and
        # `is_relevant=True` under the threshold is the model agreeing and being overruled by
        # the frequency setting. Those are opposite problems wearing one log line, and only
        # the second is fixed by a knob the user can reach.
        logger.info(
            f"mentor_proactive gate_rejected uid={uid} score={relevance.relevance_score:.2f} "
            f"relevant={relevance.is_relevant} thr={base_threshold:.2f} "
            f"msgs={len(conversation_messages)} facts={len(user_facts or '')} "
            f"past={len(past_conversations_str or '')} "
            f"context={relevance.context_summary[:100]}"
        )
        return None

    logger.info(
        f"mentor_proactive gate_passed uid={uid} score={relevance.relevance_score:.2f} "
        f"reason={relevance.reasoning[:100]}"
    )

    # ── Add the expensive half of the context, now that it is worth paying for ──
    #
    # Semantic search is what needs an embedding provider and a vector store; it stays behind
    # the gate so a rejected conversation never pays for it. It fails on its own — the
    # recent-by-time context gathered above must survive an embedding outage, since otherwise
    # the draft is silently written from the live transcript alone.
    semantic_past: list[dict] = []
    try:
        conversation_text = ' '.join(msg.get('text', '') for msg in conversation_messages)
        if conversation_text.strip():
            vector = generate_embedding(conversation_text[:2000])
            memory_ids = query_vectors_by_metadata(
                uid, vector, dates_filter=[None, None], people=[], topics=[], entities=[], dates=[], limit=3
            )
            if memory_ids:
                vector_convos = conversations_db.get_conversations_by_id(uid, memory_ids)
                if vector_convos:
                    semantic_past = [c for c in vector_convos if not c.get('is_locked')]
    except Exception as e:
        logger.warning(f"mentor_proactive vector_search_failed uid={uid} error={e}")

    if semantic_past:
        # Semantically matched conversations lead: they were picked for this conversation,
        # while the recent ones are merely the latest.
        semantic_ids = {c.get('id') for c in semantic_past}
        all_past = semantic_past + [c for c in all_past if c.get('id') not in semantic_ids]
        past_conversations_str = _render_past_conversations(uid, all_past)

    # ── Step 2: Generate ─────────────────────────────────────────────────
    try:
        with track_usage(uid, Features.PROACTIVE_NOTIFICATION):
            draft = generate_notification(
                user_name=user_name,
                user_facts=user_facts,
                goals=goals,
                past_conversations_str=past_conversations_str,
                current_messages=conversation_messages,
                recent_notifications=recent_notifications,
                frequency=frequency,
                gate_reasoning=relevance.reasoning,
                output_language=output_language,
                current_date=mentor_current_date,
            )
    except Exception as e:
        logger.error(f"mentor_proactive generate_failed uid={uid} error={e}")
        return None

    notification_text = draft.notification_text
    if not notification_text or len(notification_text) < 5:
        logger.info(f"mentor_proactive empty_draft uid={uid}")
        return None

    if draft.confidence < base_threshold:
        logger.info(
            f"mentor_proactive draft_below_threshold uid={uid} "
            f"confidence={draft.confidence:.2f} threshold={base_threshold}"
        )
        return None

    # ── Step 3: Critic ───────────────────────────────────────────────────
    try:
        with track_usage(uid, Features.PROACTIVE_NOTIFICATION):
            validation = validate_notification(
                user_name=user_name,
                notification_text=notification_text,
                draft_reasoning=draft.reasoning,
                current_messages=conversation_messages,
                goals=goals,
                output_language=output_language,
                user_facts=user_facts,
                past_conversations_str=past_conversations_str,
                current_date=mentor_current_date,
            )
    except Exception as e:
        logger.error(f"mentor_proactive critic_failed uid={uid} error={e}")
        return None

    if not validation.approved:
        logger.info(
            f"mentor_proactive critic_rejected uid={uid} "
            f"notification={notification_text[:80]} reason={validation.reasoning[:100]}"
        )
        return None

    # ── Send ─────────────────────────────────────────────────────────────
    if len(notification_text) > 150:
        notification_text = notification_text[:150]

    logger.info(
        f"mentor_proactive sending uid={uid} confidence={draft.confidence:.2f} "
        f"category={draft.category} reasoning={draft.reasoning[:100]}"
    )
    send_app_notification(uid, 'Omi', 'mentor', notification_text, title=_mentor_notification_title(output_language))

    # Record what was just sent. Both the gate and the generate prompts are handed
    # `recent_notifications` under a header that reads "do not repeat or send semantically
    # similar" — but that list comes from get_app_messages(uid, 'mentor'), and nothing ever
    # stored a message under that app id, so it was empty on every run. The anti-repeat rule
    # had no material to work with: the same advice could go out once per cooldown until the
    # daily cap. Persisting it also gives the push somewhere to land — the payload navigates
    # to /chat/mentor, which was an empty thread.
    #
    # Failing to store must not skip the rate-limit bookkeeping below: the notification has
    # already left for the user's phone, and a mentor that "forgets" to arm its own cooldown
    # would immediately be eligible to send again.
    try:
        add_app_message(notification_text, 'mentor', uid)
    except Exception as e:
        logger.error(f"mentor_proactive persist_failed uid={uid} error={e}")

    # Update rate limit and daily count
    ts = int(time.time())
    mem_db.set_proactive_noti_sent_at(uid, app_id='mentor', ts=ts, ttl=MENTOR_RATE_LIMIT_SECONDS)
    redis_db.set_proactive_noti_sent_at(uid, app_id='mentor', ts=ts, ttl=MENTOR_RATE_LIMIT_SECONDS)
    incr_daily_notification_count(uid)

    return notification_text


def _process_proactive_notification(uid: str, app: App, data):
    """Process proactive notifications for external/third-party apps."""
    if not app.has_capability("proactive_notification") or not data:
        logger.error(f"App {app.id} is not proactive_notification or data invalid {uid}")
        return None

    # rate limits
    if _hit_proactive_notification_rate_limits(uid, app):
        logger.info(f"App {app.id} is reach rate limits 1 noti per user per {PROACTIVE_NOTI_LIMIT_SECONDS}s {uid}")
        return None

    # Daily cap: third-party proactive notifications share the same per-user daily
    # budget as mentor notifications, so a user with several proactive apps cannot
    # blow past the limit. Developers are exempt (#3346).
    if _proactive_daily_cap_reached(uid):
        logger.info(f"App {app.id} proactive daily_cap_reached {uid}")
        return None

    max_prompt_char_limit = 128000
    min_message_char_limit = 5

    prompt = data.get('prompt', '')
    if len(prompt) > max_prompt_char_limit:
        send_app_notification(
            uid,
            app.name,
            app.id,
            f"Prompt too long: {len(prompt)}/{max_prompt_char_limit} characters. Please shorten.",
        )
        logger.info(f"App {app.id}, prompt too long, length: {len(prompt)}/{max_prompt_char_limit} {uid}")
        return None

    filter_scopes = app.filter_proactive_notification_scopes(data.get('params', []))

    user_name, user_facts = get_prompt_memories(uid)

    context = None
    if 'user_context' in filter_scopes:
        memories = _retrieve_contextual_memories(uid, data.get('context', {}))
        if len(memories) > 0:
            context = conversations_to_string(deserialize_conversations(memories))

    chat_messages = []
    if 'user_chat' in filter_scopes:
        # Skip any malformed/legacy stored message rather than letting one bad record raise a
        # ValidationError that aborts the whole notification. The sole caller swallows exceptions
        # from here, so an unguarded build silently dropped the proactive notification every run
        # until the bad row aged out of the last-10 window. deserialize_many_safe (#8882) is the
        # shared safe-deserialize path for exactly this class.
        chat_messages = list(reversed(Message.deserialize_many_safe(get_app_messages(uid, app.id, limit=10))))

    # Build prompt with substitutions
    for param in filter_scopes:
        if param == "user_name":
            prompt = prompt.replace("{{user_name}}", user_name)
        elif param == "user_facts":
            prompt = prompt.replace("{{user_facts}}", user_facts)
        elif param == "user_context":
            prompt = prompt.replace("{{user_context}}", context if context else "")
        elif param == "user_chat":
            prompt = prompt.replace(
                "{{user_chat}}", Message.get_messages_as_string(chat_messages) if chat_messages else ""
            )
    prompt = prompt.replace('    ', '').strip()

    with track_usage(uid, Features.PROACTIVE_NOTIFICATION):
        message = get_llm('app_integration').invoke(prompt).content
    if not message or len(message) < min_message_char_limit:
        logger.info(f"Plugins {app.id}, message too short {uid}")
        return None

    send_app_notification(uid, app.name, app.id, message)

    _set_proactive_noti_sent_at(uid, app)
    # Count this against the user's daily proactive budget so mentor + app
    # notifications share one ceiling rather than each having their own.
    incr_daily_notification_count(uid)
    return message


async def _async_trigger_realtime_audio_bytes(uid: str, sample_rate: int, data: bytearray):
    apps: List[App] = await run_blocking(db_executor, get_available_apps, uid)
    filtered_apps = [app for app in apps if app.triggers_realtime_audio_bytes() and app.enabled]
    if not filtered_apps:
        return {}

    version = latest_wins_start(uid)

    async def _single(app: App):
        if not latest_wins_check(uid, version):
            return  # Newer call superseded this one

        if not app.external_integration.webhook_url:
            return

        if await run_blocking(db_executor, is_app_webhook_disabled, app.id):
            return

        url = app.external_integration.webhook_url
        # The configured webhook_url may already carry a query string (auth token,
        # routing param), so pick the right separator instead of always using '?'.
        separator = '&' if '?' in url else '?'
        url += f'{separator}sample_rate={sample_rate}&uid={uid}'

        # SSRF guard (see trigger_external_integrations): a non-public
        # developer-configured webhook URL is a config error, not a delivery
        # failure — reject without recording failure or tripping the breaker.
        try:
            pinned_url, pin_kwargs = await run_blocking(db_executor, safe_request_target, url)
        except UnsafeWebhookURLError as e:
            logger.warning('Rejected non-public webhook URL for app %s: %s', app.id, e)
            return

        cb = get_webhook_circuit_breaker(url)
        if not cb.allow_request():
            return

        try:
            headers = dict(pin_kwargs['headers'])
            headers['Content-Type'] = 'application/octet-stream'
            async with get_webhook_semaphore():
                if not latest_wins_check(uid, version):
                    return  # Check again after acquiring semaphore
                client = get_webhook_client()
                response = await client.post(
                    pinned_url,
                    content=bytes(data),
                    headers=headers,
                    extensions=pin_kwargs['extensions'],
                    follow_redirects=False,
                )
            if response.status_code >= 200 and response.status_code < 300:
                cb.record_success()
                await run_blocking(db_executor, record_app_webhook_success, app.id)
            else:
                cb.record_failure()
                error_str = f'HTTP {response.status_code}'
                action = await run_blocking(
                    db_executor, record_app_webhook_failure, app.id, response.status_code, error_str
                )
                await run_blocking(db_executor, _handle_webhook_health_action, app.id, action, error_str)
            logger.info(f'trigger_realtime_audio_bytes {app.id} status: {response.status_code}')
        except Exception as e:
            cb.record_failure()
            error_str = type(e).__name__
            action = await run_blocking(db_executor, record_app_webhook_failure, app.id, 0, error_str)
            await run_blocking(db_executor, _handle_webhook_health_action, app.id, action, error_str)
            logger.error(f"Plugin integration error: {e}")

    chunk_size = 8
    for i in range(0, len(filtered_apps), chunk_size):
        chunk = filtered_apps[i : i + chunk_size]
        await gather_safe(*[_single(app) for app in chunk], label="realtime_audio_bytes", max_concurrency=8)
        if not latest_wins_check(uid, version):
            break
    return {}


# Self-host patch (lane7): wall-clock budget for one run of the whole
# gate→generate→critic chain.
#
# The chain is awaited by the pusher's per-connection transcript task, so it holds up
# realtime transcript dispatch for that user while it runs; the queue behind it is a
# bounded deque that drops the oldest item when it overflows. Each step already carries
# its own deadline (see proactive_notification._step_timeout_seconds), but a step can be
# retried once by the structured-output parser, so the sum needs its own ceiling.
# A healthy full run measured ~15s.
MENTOR_PIPELINE_TIMEOUT_SECONDS = 150.0


async def _async_trigger_realtime_integrations(
    uid: str,
    segments: List[dict],
    conversation_id: str | None,
    source: str | None = None,
    *,
    client_kind: ClientKind = 'unknown',
) -> dict:
    # Paywall: skip mentor + third-party proactive notifications when this
    # transcription session belongs to a paywalled desktop user.
    # Reactivates automatically when the user upgrades or activates BYOK.
    if await run_blocking(db_executor, is_trial_paywalled, uid, source):
        return {}

    # Process mentor notification first (built-in feature) — sync, runs in thread
    mentor_results = {}
    conversation_messages = await run_blocking(db_executor, process_mentor_notification, uid, segments)
    if conversation_messages:
        mentor_message = None
        with track_usage(uid, Features.REALTIME_INTEGRATIONS):
            try:
                mentor_message = await asyncio.wait_for(
                    run_blocking(
                        postprocess_executor,
                        _process_mentor_proactive_notification,
                        uid,
                        conversation_messages,
                    ),
                    timeout=MENTOR_PIPELINE_TIMEOUT_SECONDS,
                )
            except asyncio.TimeoutError:
                # Self-host patch: the worker thread keeps running to completion (threads
                # are not cancellable) — what this releases is the transcript path, which
                # must not wait on a slow LLM backend (у нас это мост Claude).
                logger.warning(
                    f"mentor_proactive pipeline_timeout uid={uid} after={MENTOR_PIPELINE_TIMEOUT_SECONDS:.0f}s"
                )
        if mentor_message:
            mentor_results['mentor'] = mentor_message
            logger.info(f"Sent mentor notification to user {uid}")

    apps: List[App] = await run_blocking(db_executor, get_available_apps, uid)
    filtered_apps = [app for app in apps if app.triggers_realtime() and app.enabled]
    if not filtered_apps:
        # Return mentor results if any, even if no external apps
        if mentor_results:
            messages = []
            for key, message in mentor_results.items():
                if not message or key in _SELF_STORING_RESULT_KEYS:
                    continue
                messages.append(await run_blocking(db_executor, add_app_message, message, key, uid))
            return messages
        return {}

    results = {}

    async def _single(app: App):
        if not app.external_integration.webhook_url:
            return

        if await run_blocking(db_executor, is_app_webhook_disabled, app.id):
            return

        url = app.external_integration.webhook_url
        journey_attempt = ClientJourneyAttempt('app_webhook_delivery', bounded_client_kind(client_kind))
        if '?' in url:
            url += '&uid=' + uid
        else:
            url += '?uid=' + uid

        # SSRF guard (see trigger_external_integrations): a non-public
        # developer-configured webhook URL is a config error, not a delivery
        # failure — reject without recording failure or tripping the breaker.
        try:
            pinned_url, pin_kwargs = await run_blocking(db_executor, safe_request_target, url)
        except UnsafeWebhookURLError as e:
            journey_attempt.fail('invalid_response')
            logger.warning('Rejected non-public webhook URL for app %s: %s', app.id, e)
            return

        cb = get_webhook_circuit_breaker(url)
        if not cb.allow_request():
            journey_attempt.fail('dependency_unavailable')
            logger.info(f'trigger_realtime_integrations: circuit breaker open for {app.id}')
            return

        try:
            async with get_webhook_semaphore():
                client = get_webhook_client()
                response = await client.post(
                    pinned_url,
                    json={"session_id": uid, "segments": segments},
                    headers=pin_kwargs['headers'],
                    extensions=pin_kwargs['extensions'],
                    follow_redirects=False,
                )
            if response.status_code < 200 or response.status_code >= 300:
                journey_attempt.fail('upstream_rejected')
                cb.record_failure()
                error_str = f'HTTP {response.status_code}'
                action = await run_blocking(
                    db_executor, record_app_webhook_failure, app.id, response.status_code, error_str
                )
                await run_blocking(db_executor, _handle_webhook_health_action, app.id, action, error_str)
                logger.info(
                    f'trigger_realtime_integrations {app.id} status: {response.status_code} results: {sanitize(response.text[:100])}'
                )
                return

            journey_attempt.succeed()
            cb.record_success()
            await run_blocking(db_executor, record_app_webhook_success, app.id)

            if (app.uid is None or app.uid != uid) and conversation_id is not None:
                await run_blocking(
                    db_executor,
                    record_app_usage,
                    uid,
                    app.id,
                    UsageHistoryType.transcript_processed_external_integration,
                    conversation_id=conversation_id,
                )

            try:
                response_data = response.json()
                if not response_data:
                    return

                # message
                message = response_data.get('message', '')
                if message and len(message) > 5:
                    await send_app_notification_async(uid, app.name, app.id, message)
                    results[app.id] = message

                # proactive_notification
                noti = response_data.get('notification', None)
                if app.has_capability("proactive_notification"):
                    with track_usage(uid, Features.REALTIME_INTEGRATIONS):
                        message = await run_blocking(
                            postprocess_executor,
                            _process_proactive_notification,
                            uid,
                            app,
                            noti,
                        )
                    if message:
                        results[app.id] = message
            except Exception:
                pass

        except Exception as e:
            journey_attempt.fail('upstream_timeout' if isinstance(e, TimeoutError) else 'provider_error')
            cb.record_failure()
            error_str = type(e).__name__
            action = await run_blocking(db_executor, record_app_webhook_failure, app.id, 0, error_str)
            await run_blocking(db_executor, _handle_webhook_health_action, app.id, action, error_str)
            logger.error(f"App integration error: {e}")
            return

    await gather_safe(*[_single(app) for app in filtered_apps], label="realtime_integrations", max_concurrency=10)

    # Merge mentor results with app results
    all_results = {**mentor_results, **results}

    messages = []
    for key, message in all_results.items():
        if not message or key in _SELF_STORING_RESULT_KEYS:
            continue
        messages.append(await run_blocking(db_executor, add_app_message, message, key, uid))

    return messages


def _build_app_notification_payload(
    app_name: str, app_id: str, message: str, target: str, title: str | None = None
) -> tuple[str, dict[str, object]]:
    navigate_to = '/chat/omi' if target == 'main' else f'/chat/{app_id}'
    ai_message = NotificationMessage(
        text=message,
        plugin_id=app_id,
        from_integration='true',
        type='text',
        notification_type='plugin',
        navigate_to=navigate_to,
    )
    return (title or app_name + ' says'), NotificationMessage.get_message_as_dict(ai_message)


def send_app_notification(
    user_id: str, app_name: str, app_id: str, message: str, target: str = 'app', title: str | None = None
):
    title, data = _build_app_notification_payload(app_name, app_id, message, target, title)
    send_notification(user_id, title, message, data)


async def send_app_notification_async(
    user_id: str, app_name: str, app_id: str, message: str, target: str = 'app'
) -> None:
    """Async notification boundary for realtime integration coordinators."""
    title, data = _build_app_notification_payload(app_name, app_id, message, target)
    await send_notification_async(user_id, title, message, data)
