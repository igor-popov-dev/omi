"""The daily summary must be generated for users who cannot receive a push.

The recap is content, not just a notification: it has its own screen, a home card, a list
endpoint and a share link. Selection nonetheless dropped users with no FCM token
(``database/notifications.py``: "Skip users with no tokens"), and the cron is the only
writer of ``daily_summaries``. A user who declined notification permission — or an iOS
client that returns before ``saveFcmToken`` because APNS has no token yet — therefore had
an empty recap screen forever, with the "daily summary" toggle still reading as enabled.

These tests pin the split: the summary is generated and stored regardless of delivery, and
the push is sent only when the user actually has tokens.
"""

from datetime import datetime, timedelta, timezone, tzinfo
from pathlib import Path
from types import ModuleType, SimpleNamespace
from typing import Any, Iterator
from unittest.mock import MagicMock

import pytest

from testing.import_isolation import AutoMockModule, stub_modules, load_module_fresh

BACKEND_DIR = Path(__file__).resolve().parents[2]


def _module(name: str, **attributes: Any) -> ModuleType:
    module = ModuleType(name)
    for key, value in attributes.items():
        setattr(module, key, value)
    return module


class _FixedTimezone(tzinfo):
    def __init__(self, offset: timedelta, name: str):
        self._offset = offset
        self._name = name

    def utcoffset(self, dt):
        return self._offset

    def dst(self, dt):
        return timedelta(0)

    def tzname(self, dt):
        return self._name

    def fromutc(self, value):
        return (value + self._offset).replace(tzinfo=self)

    def localize(self, value):
        return value.replace(tzinfo=self)


_UTC = _FixedTimezone(timedelta(0), 'UTC')


@pytest.fixture
def cron_harness() -> Iterator[SimpleNamespace]:
    """Load utils/other/notifications.py with its leaf dependencies faked."""
    pytz_stub = _module('pytz', utc=_UTC, all_timezones=['UTC'], timezone=lambda name: _UTC)

    conversation = MagicMock()
    conversation.transcript_segments = [{'text': 'hello'}]
    conversation.discarded = False

    conversations_db = _module('database.conversations', get_conversations=MagicMock(return_value=[{'id': 'c1'}]))
    daily_summaries_db = _module(
        'database.daily_summaries',
        get_daily_summary_by_date=MagicMock(return_value=None),
        create_daily_summary=MagicMock(return_value='summary-1'),
    )
    send_notification = MagicMock()
    notification_message = MagicMock()
    notification_message.get_message_as_dict = MagicMock(return_value={})

    stubs = {
        'pytz': pytz_stub,
        'database.conversations': conversations_db,
        'database.notifications': AutoMockModule('database.notifications'),
        'database.daily_summaries': daily_summaries_db,
        'database.redis_db': _module('database.redis_db', try_acquire_daily_summary_lock=MagicMock(return_value=True)),
        'models.notification_message': _module('models.notification_message', NotificationMessage=notification_message),
        'utils.conversations.factory': _module(
            'utils.conversations.factory', deserialize_conversation=MagicMock(return_value=conversation)
        ),
        'utils.llm.external_integrations': _module(
            'utils.llm.external_integrations',
            generate_comprehensive_daily_summary=MagicMock(
                return_value={'day_emoji': '🌙', 'headline': 'A day', 'overview': 'It happened'}
            ),
        ),
        'utils.notifications': _module(
            'utils.notifications', send_notification=send_notification, send_bulk_notification=MagicMock()
        ),
        'utils.webhooks': _module('utils.webhooks', day_summary_webhook=MagicMock()),
        'utils.executors': _module(
            'utils.executors',
            db_executor=MagicMock(),
            postprocess_executor=MagicMock(),
            run_blocking=MagicMock(),
        ),
    }

    with stub_modules(stubs):
        module = load_module_fresh(
            'utils.other.notifications',
            str(BACKEND_DIR / 'utils' / 'other' / 'notifications.py'),
        )
        yield SimpleNamespace(
            send_summary=module._send_summary_notification,
            daily_summaries_db=daily_summaries_db,
            send_notification=send_notification,
        )


def test_summary_is_stored_for_a_user_without_tokens(cron_harness: SimpleNamespace) -> None:
    cron_harness.send_summary(('uid-no-devices', [], 'UTC'))

    cron_harness.daily_summaries_db.create_daily_summary.assert_called_once()
    assert cron_harness.daily_summaries_db.create_daily_summary.call_args.args[0] == 'uid-no-devices'
    cron_harness.send_notification.assert_not_called()


def test_summary_is_still_pushed_when_the_user_has_tokens(cron_harness: SimpleNamespace) -> None:
    cron_harness.send_summary(('uid-with-device', ['token-1'], 'UTC'))

    cron_harness.daily_summaries_db.create_daily_summary.assert_called_once()
    cron_harness.send_notification.assert_called_once()
    assert cron_harness.send_notification.call_args.kwargs['tokens'] == ['token-1']


class _FakeDoc:
    def __init__(self, doc_id: str, data: dict):
        self.id = doc_id
        self._data = data

    def to_dict(self) -> dict:
        return self._data


class _FakeTokenCollection:
    def __init__(self, tokens: list):
        self._tokens = tokens

    def stream(self):
        return [_FakeDoc(f'device-{i}', {'token': token}) for i, token in enumerate(self._tokens)]


class _FakeUserDocument:
    def __init__(self, tokens: list):
        self._tokens = tokens

    def collection(self, _name: str) -> _FakeTokenCollection:
        return _FakeTokenCollection(self._tokens)


class _FakeQuery:
    def __init__(self, users: list):
        self._users = users

    def where(self, *_args, **_kwargs) -> '_FakeQuery':
        return self

    def stream(self):
        return [_FakeDoc(uid, data) for uid, data, _tokens in self._users]


class _FakeCollection(_FakeQuery):
    def document(self, uid: str) -> _FakeUserDocument:
        for candidate, _data, tokens in self._users:
            if candidate == uid:
                return _FakeUserDocument(tokens)
        return _FakeUserDocument([])


class _FakeDb:
    def __init__(self, users: list):
        self._users = users

    def collection(self, _name: str) -> _FakeCollection:
        return _FakeCollection(self._users)


@pytest.fixture
def notifications_db_module() -> Iterator[ModuleType]:
    stubs = {
        'google.cloud': AutoMockModule('google.cloud'),
        'google.cloud.firestore': AutoMockModule('google.cloud.firestore'),
        'google.cloud.firestore_v1': AutoMockModule('google.cloud.firestore_v1'),
        'google.cloud.firestore_v1.base_query': AutoMockModule('google.cloud.firestore_v1.base_query'),
        'database._client': _module('database._client', db=MagicMock()),
        'database.cache': _module('database.cache', get_memory_cache=MagicMock()),
    }
    with stub_modules(stubs):
        yield load_module_fresh(
            'database.notifications',
            str(BACKEND_DIR / 'database' / 'notifications.py'),
        )


def test_selection_keeps_users_without_tokens(notifications_db_module: ModuleType) -> None:
    users = [
        ('uid-no-devices', {'time_zone': 'UTC', 'daily_summary_enabled': True}, []),
        ('uid-with-device', {'time_zone': 'UTC', 'daily_summary_enabled': True}, ['token-1']),
    ]
    notifications_db_module.db = _FakeDb(users)

    selected = notifications_db_module.get_users_for_daily_summary(
        ['UTC'], notifications_db_module.DEFAULT_DAILY_SUMMARY_HOUR_LOCAL
    )

    by_uid = {uid: tokens for uid, tokens, _tz in selected}
    assert by_uid == {'uid-no-devices': [], 'uid-with-device': ['token-1']}


def test_selection_still_honours_the_disabled_flag(notifications_db_module: ModuleType) -> None:
    users = [('uid-opted-out', {'time_zone': 'UTC', 'daily_summary_enabled': False}, [])]
    notifications_db_module.db = _FakeDb(users)

    assert (
        notifications_db_module.get_users_for_daily_summary(
            ['UTC'], notifications_db_module.DEFAULT_DAILY_SUMMARY_HOUR_LOCAL
        )
        == []
    )
