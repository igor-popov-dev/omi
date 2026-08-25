"""Self-host patch: чат без месячного потолка подписки (`OMI_SELFHOST_UNLIMITED_CHAT`).

Врезка стоила суток немого чата 25.08: счётчик Free-плана дотикал до 39/30, и
телефон вместо ответа получал канонную реплику «лимит исчерпан». Отказ живёт
ДО провайдера, поэтому в логах моста было ноль ошибок, а `POST /v2/messages`
отвечал 200 OK — искать причину шли не туда.

Тест держит обе границы: с рубильником чат не блокируется никогда (в том числе
когда чтение расхода упало), без рубильника правило upstream работает слово в
слово.

Стиль загрузки модуля повторяет tests/unit/test_chat_quota.py: utils.subscription
связывает свои зависимости на импорте, а database.users импортирует его обратно,
поэтому фейки должны стоять раньше exec модуля (backend/docs/test_isolation.md).
"""

import os
from datetime import datetime, timezone
from pathlib import Path
from types import ModuleType, SimpleNamespace
from unittest.mock import MagicMock

import pytest
from fastapi import HTTPException

from models.users import PlanType, Subscription
from testing.import_isolation import load_module_fresh, stub_modules
from utils.selfhost_chat_quota import SELFHOST_UNLIMITED_CHAT_ENV

_BACKEND = Path(__file__).resolve().parents[2]
_SUBSCRIPTION_PATH = os.path.join(str(_BACKEND), "utils", "subscription.py")

_RESET_AT = 1756684800  # 2026-09-01 UTC — начало следующего месяца
_FREE_CAP_QUESTIONS = 39  # то, что реально было на mini 25.08 при потолке 30


def _compare_versions(a, b):
    a_parts = [int(x) for x in a.split('.')]
    b_parts = [int(x) for x in b.split('.')]
    for x, y in zip(a_parts, b_parts):
        if x != y:
            return 1 if x > y else -1
    return len(a_parts) - len(b_parts)


_db_users_mod = SimpleNamespace(get_user_valid_subscription=MagicMock(), is_byok_active=MagicMock(return_value=False))
_db_user_usage_mod = SimpleNamespace(get_monthly_chat_usage=MagicMock())

_announcements_mod = ModuleType("database.announcements")
_announcements_mod._compare_versions = _compare_versions
_announcements_mod.compare_versions = _compare_versions

_byok_mod = ModuleType("utils.byok")
_byok_mod.get_byok_key = MagicMock(return_value=None)
_byok_mod.get_byok_keys = MagicMock(return_value={})

_sub_mod_ref = None


@pytest.fixture(scope="module", autouse=True)
def _setup_subscription_module():
    global _sub_mod_ref
    fakes = {
        "database.users": _db_users_mod,
        "database.user_usage": _db_user_usage_mod,
        "database.announcements": _announcements_mod,
        "utils.byok": _byok_mod,
    }
    with stub_modules(fakes):
        _sub_mod_ref = load_module_fresh("utils.subscription", _SUBSCRIPTION_PATH)
        yield
        _sub_mod_ref = None


@pytest.fixture(autouse=True)
def _exhausted_free_user():
    """Тот самый пользователь: план Free, 39 вопросов за месяц, потолок 30."""
    _db_users_mod.get_user_valid_subscription = MagicMock(
        return_value=Subscription(
            plan=PlanType.basic,
            status="active",
            created_at=datetime(2026, 1, 1, tzinfo=timezone.utc),
        )
    )
    _db_users_mod.is_byok_active = MagicMock(return_value=False)
    _db_user_usage_mod.get_monthly_chat_usage = MagicMock(
        return_value={'questions': _FREE_CAP_QUESTIONS, 'cost_usd': 0.0, 'reset_at': _RESET_AT}
    )


def test_without_the_optin_the_free_cap_still_blocks(monkeypatch):
    """Опт-ин не должен менять поведение тем, кто его не ставил."""
    monkeypatch.delenv(SELFHOST_UNLIMITED_CHAT_ENV, raising=False)

    snapshot = _sub_mod_ref.get_chat_quota_snapshot("uid-phone")
    assert snapshot['allowed'] is False
    assert snapshot['limit'] == 30.0

    with pytest.raises(HTTPException) as exc:
        _sub_mod_ref.enforce_chat_quota("uid-phone", platform="android")
    assert exc.value.status_code == 402
    assert exc.value.detail['error'] == 'quota_exceeded'


def test_the_optin_removes_the_cap_and_keeps_the_real_usage(monkeypatch):
    """Потолка нет, но расход остаётся честным: врезку можно снять, не потеряв истории."""
    monkeypatch.setenv(SELFHOST_UNLIMITED_CHAT_ENV, "1")

    snapshot = _sub_mod_ref.get_chat_quota_snapshot("uid-phone")

    assert snapshot['allowed'] is True
    assert snapshot['limit'] is None
    assert snapshot['used'] == float(_FREE_CAP_QUESTIONS)
    assert snapshot['unit'] == 'questions'
    assert snapshot['reset_at'] == _RESET_AT


def test_the_optin_lets_an_exhausted_phone_chat_again(monkeypatch):
    """Главный симптом: телефон на Free-плане перестаёт получать 402 -> «лимит исчерпан»."""
    monkeypatch.setenv(SELFHOST_UNLIMITED_CHAT_ENV, "1")

    assert _sub_mod_ref.enforce_chat_quota("uid-phone", platform="android") is None


def test_a_broken_usage_read_never_blocks_chat(monkeypatch):
    """Fail-open: врезка существует ради того, чтобы не уметь отказывать."""
    monkeypatch.setenv(SELFHOST_UNLIMITED_CHAT_ENV, "1")
    _db_user_usage_mod.get_monthly_chat_usage = MagicMock(side_effect=RuntimeError("mongo is down"))

    snapshot = _sub_mod_ref.get_chat_quota_snapshot("uid-phone")

    assert snapshot['allowed'] is True
    assert snapshot['limit'] is None
    assert snapshot['used'] == 0.0
    assert _sub_mod_ref.enforce_chat_quota("uid-phone", platform="android") is None
