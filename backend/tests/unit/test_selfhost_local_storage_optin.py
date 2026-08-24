"""Self-host patch: локальное хранилище блобов на НАСТОЯЩЕМ Firestore.

Эта врезка стоила живого простоя 24.08: апстрим-мерж принёс проверку, которая
разрешает `OMI_LOCAL_STORAGE_ROOT` только эмуляторному стенду (demo-проект плюс
FIRESTORE_EMULATOR_HOST), бэкенд на mini не поднялся с RuntimeError прямо в
импорте `main.py`, и телефон остался без сервера. Тест держит границу: опт-ин
работает, чужое поведение не меняется, а проверка вложенности остаётся.
"""

from __future__ import annotations

import pytest

from utils.other.local_storage import (
    LOCAL_STORAGE_ROOT_ENV,
    HARNESS_STATE_ROOT_ENV,
    SELFHOST_LOCAL_STORAGE_ENV,
    local_storage_root_from_env,
)


def _env(monkeypatch, tmp_path, *, selfhost=None, project=None, emulator=None):
    state_root = tmp_path / 'state'
    root = state_root / 'storage'
    root.mkdir(parents=True)
    monkeypatch.setenv(HARNESS_STATE_ROOT_ENV, str(state_root))
    monkeypatch.setenv(LOCAL_STORAGE_ROOT_ENV, str(root))
    for name, value in (
        (SELFHOST_LOCAL_STORAGE_ENV, selfhost),
        ('FIREBASE_PROJECT_ID', project),
        ('FIRESTORE_EMULATOR_HOST', emulator),
    ):
        if value is None:
            monkeypatch.delenv(name, raising=False)
        else:
            monkeypatch.setenv(name, value)
    return root


def test_selfhost_optin_allows_local_storage_on_a_real_project(monkeypatch, tmp_path):
    """Свой сервер держит блобы на диске: GCS — платный вендор, которого в
    self-host нет, а без локального корня профили голоса отвечают 500."""
    root = _env(monkeypatch, tmp_path, selfhost='1', project='omi-jarvis-igor')

    assert local_storage_root_from_env() == root


def test_without_the_optin_the_upstream_rule_holds_word_for_word(monkeypatch, tmp_path):
    """Опт-ин не должен ослаблять правило для тех, кто его не ставил."""
    _env(monkeypatch, tmp_path, project='omi-jarvis-igor')

    with pytest.raises(RuntimeError, match='owned local emulator harness'):
        local_storage_root_from_env()


def test_the_emulator_harness_path_still_works_untouched(monkeypatch, tmp_path):
    root = _env(monkeypatch, tmp_path, project='demo-omi-local', emulator='127.0.0.1:8085')

    assert local_storage_root_from_env() == root


@pytest.mark.parametrize('value', ['1', 'true', 'yes', 'TRUE'])
def test_the_optin_accepts_the_usual_spellings(monkeypatch, tmp_path, value):
    root = _env(monkeypatch, tmp_path, selfhost=value, project='omi-jarvis-igor')

    assert local_storage_root_from_env() == root


def test_the_optin_does_not_unlock_an_arbitrary_directory(monkeypatch, tmp_path):
    """Ослабляется ТОЛЬКО требование эмулятора. Вложенность корня в состояние
    стенда — это то, что не даёт увести блобы куда угодно, и она остаётся."""
    outside = tmp_path / 'somewhere-else'
    outside.mkdir()
    monkeypatch.setenv(HARNESS_STATE_ROOT_ENV, str(tmp_path / 'state'))
    (tmp_path / 'state').mkdir()
    monkeypatch.setenv(LOCAL_STORAGE_ROOT_ENV, str(outside))
    monkeypatch.setenv(SELFHOST_LOCAL_STORAGE_ENV, '1')
    monkeypatch.setenv('FIREBASE_PROJECT_ID', 'omi-jarvis-igor')

    with pytest.raises(RuntimeError, match='must be a child of'):
        local_storage_root_from_env()


def test_the_optin_still_requires_the_state_root(monkeypatch, tmp_path):
    monkeypatch.delenv(HARNESS_STATE_ROOT_ENV, raising=False)
    monkeypatch.setenv(LOCAL_STORAGE_ROOT_ENV, str(tmp_path))
    monkeypatch.setenv(SELFHOST_LOCAL_STORAGE_ENV, '1')

    with pytest.raises(RuntimeError, match=HARNESS_STATE_ROOT_ENV):
        local_storage_root_from_env()
