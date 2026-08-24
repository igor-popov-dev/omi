"""Self-host patch: тесты пульта апстрим-синка (routers/selfhost_upstream_sync.py).

Проверяется в первую очередь то, что делает пульт безопасным: он не вливает
ничего сам, не пускает в `private` произвольную ветку, не будит человека
зелёными прогонами и не превращает отсутствие скрипта в 500.
"""

from __future__ import annotations

import json
import os

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient

from routers import selfhost_upstream_sync as sync
from utils.other import endpoints as auth

UID = 'test-uid'


def _client(monkeypatch, tmp_path, *, script_exists=True, owner=None):
    out_dir = tmp_path / 'upstream-sync'
    out_dir.mkdir()
    script = tmp_path / 'omi-sync-upstream'
    if script_exists:
        script.write_text('#!/bin/sh\nexit 0\n')
        script.chmod(0o755)

    monkeypatch.setattr(sync, '_SCRIPT', str(script))
    monkeypatch.setattr(sync, '_OUT_DIR', str(out_dir))
    monkeypatch.setattr(sync, '_STATUS_PATH', str(out_dir / 'status.json'))
    monkeypatch.setattr(sync, '_LOCK_PATH', str(out_dir / '.lock'))
    monkeypatch.setattr(sync, '_OWNER_UID', owner)

    app = FastAPI()
    app.include_router(sync.router)
    app.dependency_overrides[auth.get_current_user_uid] = lambda: UID
    return TestClient(app), out_dir


def _write_status(out_dir, **overrides):
    status = {
        'stamp': '2026-08-24-2058',
        'started': '2026-08-24 20:58',
        'mode': 'dry',
        'klass': 20,
        'behind': 292,
        'ahead': 198,
        'auto_resolved': 51,
        'next_steps': ['разобрать конфликты'],
        'conflicts': [
            {'file': 'app/lib/l10n/app_en.arb', 'hunks': 3, 'generated': True, 'ours_upstream': False},
            {
                'file': 'app/lib/services/sockets/pure_polling.dart',
                'hunks': 8,
                'generated': False,
                'ours_upstream': True,
            },
            {'file': 'backend/utils/retrieval/graph.py', 'hunks': 1, 'generated': False, 'ours_upstream': False},
        ],
    }
    status.update(overrides)
    (out_dir / 'status.json').write_text(json.dumps(status), encoding='utf-8')
    return status


def test_missing_script_reads_as_not_configured_not_as_a_crash(monkeypatch, tmp_path):
    """На чужом сервере скрипта нет — это ожидаемое состояние, а не ошибка:
    приложение должно уметь показать «не настроено», а не красный экран."""
    client, _ = _client(monkeypatch, tmp_path, script_exists=False)

    response = client.get('/v1/selfhost/upstream-sync/status')

    assert response.status_code == 503


def test_status_separates_code_conflicts_from_generated_ones(monkeypatch, tmp_path):
    """Плашка должна показывать число файлов, которые ждут ЧЕЛОВЕКА. Локализация
    и генерённое снимаются драйверами и в этот счёт входить не должны."""
    client, out_dir = _client(monkeypatch, tmp_path)
    _write_status(out_dir)

    body = client.get('/v1/selfhost/upstream-sync/status').json()

    assert body['outcome'] == 'CONFLICTS'
    assert body['needs_attention'] is True
    assert body['behind'] == 292
    assert body['auto_resolved'] == 51
    assert body['conflicts_code'] == 2
    assert [f['file'] for f in body['files']] == [
        'app/lib/services/sockets/pure_polling.dart',
        'backend/utils/retrieval/graph.py',
    ]
    assert body['files'][0]['ours_upstream'] is True


def test_green_outcomes_do_not_ask_for_attention(monkeypatch, tmp_path):
    client, out_dir = _client(monkeypatch, tmp_path)
    _write_status(out_dir, klass=10, conflicts=[])

    body = client.get('/v1/selfhost/upstream-sync/status').json()

    assert body['outcome'] == 'AUTO'
    assert body['needs_attention'] is False


def test_running_is_read_from_the_lock_not_from_process_memory(monkeypatch, tmp_path):
    """Замок ставит сам скрипт, поэтому «идёт» остаётся правдой и когда синк
    запустили из терминала, и когда бэкенд перезапустили посреди прогона."""
    client, out_dir = _client(monkeypatch, tmp_path)
    _write_status(out_dir)
    os.mkdir(out_dir / '.lock')

    assert client.get('/v1/selfhost/upstream-sync/status').json()['running'] is True


def test_run_refuses_while_another_sync_holds_the_lock(monkeypatch, tmp_path):
    client, out_dir = _client(monkeypatch, tmp_path)
    os.mkdir(out_dir / '.lock')

    response = client.post('/v1/selfhost/upstream-sync/run', json={'mode': 'full'})

    assert response.status_code == 409


def test_run_rejects_an_unknown_mode(monkeypatch, tmp_path):
    client, _ = _client(monkeypatch, tmp_path)

    assert client.post('/v1/selfhost/upstream-sync/run', json={'mode': 'rebase'}).status_code == 400


def test_run_returns_immediately_and_starts_the_script(monkeypatch, tmp_path):
    """Тесты идут минутами: синхронный ответ отвалился бы по таймауту клиента и
    человек решил бы, что синк упал."""
    client, _ = _client(monkeypatch, tmp_path)
    started = {}

    def fake_start(coro, *, name):
        started['name'] = name
        # Корутину надо закрыть явно, иначе pytest ругается на неожидаемую.
        coro.close()

    monkeypatch.setattr(sync, 'start_background_task', fake_start)
    monkeypatch.setattr(sync, '_SCRIPT_ARGS_SPY', None, raising=False)

    body = client.post('/v1/selfhost/upstream-sync/run', json={'mode': 'dry'}).json()

    assert started['name'] == 'upstream-sync:dry'
    assert body['running'] is True


@pytest.mark.anyio
async def test_the_sync_subprocess_never_occupies_a_worker_thread(monkeypatch, tmp_path):
    """Полный синк идёт минутами. Поток из общего пула на это время — отнятый у
    запросов поток, поэтому подпроцесс должен быть асинхронным."""
    _client(monkeypatch, tmp_path)
    seen = {}

    class _Proc:
        returncode = 10

        async def wait(self):
            return 10

    async def fake_exec(*args, **kwargs):
        seen['args'] = args
        return _Proc()

    monkeypatch.setattr(sync.asyncio, 'create_subprocess_exec', fake_exec)
    sent = []

    async def fake_notify(*a, **kw):
        sent.append(a)

    monkeypatch.setattr(sync, 'send_notification_async', fake_notify)

    await sync._notify_when_done(UID, ['/bin/true', '--dry'])

    assert seen['args'] == ('/bin/true', '--dry')
    # Исход 10 — зелёный, значит человека не будим.
    assert sent == []


@pytest.mark.parametrize('branch', ['private', 'main', 'feat/whatever', 'sync/base-2026-08-24'])
def test_land_only_accepts_branches_the_sync_itself_produced(monkeypatch, tmp_path, branch):
    """`private` — ствол для всех полос. Влить в него можно только ветку синка,
    и только ту, что названа явно."""
    client, _ = _client(monkeypatch, tmp_path)

    response = client.post('/v1/selfhost/upstream-sync/land', json={'branch': branch})

    assert response.status_code == 400


def test_land_surfaces_the_scripts_refusal_instead_of_reporting_success(monkeypatch, tmp_path):
    client, out_dir = _client(monkeypatch, tmp_path)
    _write_status(out_dir, klass=20, error='private ушёл вперёд')

    class _Proc:
        returncode = 20

    monkeypatch.setattr(sync.subprocess, 'run', lambda *a, **kw: _Proc())

    response = client.post('/v1/selfhost/upstream-sync/land', json={'branch': 'sync/upstream-2026-08-24'})

    assert response.status_code == 409
    assert 'ушёл вперёд' in response.json()['detail']


def test_report_stamp_cannot_escape_the_report_directory(monkeypatch, tmp_path):
    """Метка приходит с клиента и попадает в путь."""
    client, _ = _client(monkeypatch, tmp_path)

    response = client.get('/v1/selfhost/upstream-sync/report', params={'stamp': '../../../etc/passwd'})

    assert response.status_code == 400


def test_report_returns_the_markdown_of_the_named_run(monkeypatch, tmp_path):
    client, out_dir = _client(monkeypatch, tmp_path)
    _write_status(out_dir)
    (out_dir / '2026-08-24-2058.md').write_text('# отчёт', encoding='utf-8')

    body = client.get('/v1/selfhost/upstream-sync/report').json()

    assert body['stamp'] == '2026-08-24-2058'
    assert body['markdown'] == '# отчёт'


def test_a_foreign_uid_does_not_learn_the_console_exists(monkeypatch, tmp_path):
    """Пульт разработчика на пользовательском сервере: чужому — 404, а не 403,
    чтобы не подтверждать наличие роута."""
    client, _ = _client(monkeypatch, tmp_path, owner='someone-else')

    assert client.get('/v1/selfhost/upstream-sync/status').status_code == 404


@pytest.mark.anyio
async def test_a_green_run_stays_silent(monkeypatch, tmp_path):
    """Если синк начнёт присылать «всё хорошо» ежедневно, уведомления перестанут
    читать — и первое красное тоже."""
    _client(monkeypatch, tmp_path)
    sent = []

    class _Proc:
        returncode = 10

        async def wait(self):
            return 10

    async def fake_exec(*a, **kw):
        return _Proc()

    monkeypatch.setattr(sync.asyncio, 'create_subprocess_exec', fake_exec)

    async def fake_notify(*a, **kw):
        sent.append(a)

    monkeypatch.setattr(sync, 'send_notification_async', fake_notify)

    await sync._notify_when_done(UID, ['/bin/true'])

    assert sent == []


@pytest.mark.anyio
async def test_a_run_that_needs_a_decision_reaches_the_phone(monkeypatch, tmp_path):
    _client(monkeypatch, tmp_path)
    _write_status(tmp_path / 'upstream-sync')
    sent = []

    class _Proc:
        returncode = 20

        async def wait(self):
            return 20

    async def fake_exec(*a, **kw):
        return _Proc()

    monkeypatch.setattr(sync.asyncio, 'create_subprocess_exec', fake_exec)

    async def fake_notify(uid, title, body, data=None):
        sent.append((title, data))

    monkeypatch.setattr(sync, 'send_notification_async', fake_notify)

    await sync._notify_when_done(UID, ['/bin/true'])

    assert len(sent) == 1
    title, data = sent[0]
    assert 'решения' in title
    assert data['type'] == 'upstream_sync'
    assert data['outcome'] == 'CONFLICTS'
