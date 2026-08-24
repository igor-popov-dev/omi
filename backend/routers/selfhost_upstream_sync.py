"""Self-host patch, not for upstream: пульт апстрим-синка внутри приложения.

WHY THIS FILE EXISTS SEPARATELY
-------------------------------
Форк живёт рядом с очень быстрым upstream (десятки коммитов в день), и цена
отставания растёт нелинейно: чем дольше не синкались, тем больше конфликтов
получит каждая полоса при вливании. Значит синк должен быть регулярным — а
регулярным он станет только если о нём напоминают там, где человек и так
бывает каждый день, то есть в самом приложении.

Механику делает `~/omi-jarvis/bin/omi-sync-upstream` — отдельный скрипт, а не
код бэкенда: он должен работать и из терминала, и по расписанию, когда сервер
лежит. Роутер здесь — только пульт: показать статус, нажать «синкать», забрать
отчёт, подтвердить вливание.

ЧЕГО ЭТОТ РОУТЕР НЕ ДЕЛАЕТ: не вливает ничего в `private` сам. `/land` —
отдельный вызов с явно названной веткой, ровно потому, что `private` это ствол
для всех полос разработки, и автоматическая запись в него стоила бы дороже, чем
всё, что этот пульт экономит.

Живёт в своём файле, чтобы мержи upstream не могли его задеть; в upstream-файлах
трогается только `main.py`, одной строкой `include_router`.
См. `docs/selfhost-patches.md`.
"""

import asyncio
import json
import os
import subprocess
from typing import Any, Dict, List, Optional

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel

from utils.executors import start_background_task
from utils.notifications import send_notification_async
from utils.other import endpoints as auth

router = APIRouter()

_HOME = os.path.expanduser('~')
_SCRIPT = os.environ.get('SELFHOST_SYNC_SCRIPT', os.path.join(_HOME, 'omi-jarvis', 'bin', 'omi-sync-upstream'))
_OUT_DIR = os.environ.get('SELFHOST_SYNC_DIR', os.path.join(_HOME, 'omi-jarvis', 'docs', 'upstream-sync'))
_STATUS_PATH = os.path.join(_OUT_DIR, 'status.json')
_LOCK_PATH = os.path.join(_OUT_DIR, '.lock')

# Пульт разработчика на пользовательском сервере. Если задан — отвечаем только
# владельцу; иначе роут доступен любому аутентифицированному пользователю этого
# self-hosted сервера (что для одного человека и есть владелец).
_OWNER_UID = os.environ.get('SELFHOST_SYNC_UID')

# Классы исхода из скрипта. Держим здесь копию, а не импортируем: скрипт живёт
# вне репозитория и на сервере может отсутствовать вовсе.
_CLASSES = {
    0: ('CLEAN', False),
    10: ('AUTO', False),
    20: ('CONFLICTS', True),
    30: ('TESTS_RED', True),
    35: ('TESTS_SKIP', True),
    40: ('ERROR', True),
}

_NOTIFY_TITLE = {
    'CONFLICTS': 'Апстрим-синк ждёт решения',
    'TESTS_RED': 'Апстрим-синк: тесты красные',
    'TESTS_SKIP': 'Апстрим-синк: тесты не прогнаны',
    'ERROR': 'Апстрим-синк не смог отработать',
}


class SyncRunRequest(BaseModel):
    # dry — только посчитать; full — подготовить ветку и прогнать тесты.
    mode: str = 'full'


class SyncLandRequest(BaseModel):
    branch: str


class SyncStatus(BaseModel):
    available: bool
    running: bool
    stamp: Optional[str] = None
    started: Optional[str] = None
    mode: Optional[str] = None
    outcome: Optional[str] = None
    needs_attention: bool = False
    behind: int = 0
    ahead: int = 0
    auto_resolved: int = 0
    conflicts_code: int = 0
    branch: Optional[str] = None
    base_ref: Optional[str] = None
    error: Optional[str] = None
    # Прогон, который не состоялся ДО работы (занято, нет сети). Цифры при этом
    # остаются от прошлого удачного прогона — врать «всё сломалось» нельзя, но и
    # молчать нельзя: плашка иначе тихо стареет.
    last_error: Optional[str] = None
    last_error_at: Optional[str] = None
    next_steps: List[str] = []
    files: List[Dict[str, Any]] = []


def _guard(uid: str) -> None:
    if not os.path.exists(_SCRIPT):
        # Не 500: приложение должно уметь показать «на этом сервере не настроено»
        # вместо красной ошибки, потому что это ожидаемое состояние на чужой машине.
        raise HTTPException(status_code=503, detail='upstream sync is not configured on this server')
    if _OWNER_UID and uid != _OWNER_UID:
        raise HTTPException(status_code=404, detail='not found')


def _read_status() -> Dict[str, Any]:
    try:
        with open(_STATUS_PATH, encoding='utf-8') as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return {}


def _to_status(raw: Dict[str, Any]) -> SyncStatus:
    outcome, needs = _CLASSES.get(raw.get('klass'), (None, False))
    conflicts = raw.get('conflicts') or []
    code = [c for c in conflicts if not c.get('generated')]
    return SyncStatus(
        available=os.path.exists(_SCRIPT),
        # Замок ставит сам скрипт, поэтому «идёт» остаётся правдой даже если
        # бэкенд перезапустили посреди прогона или синк запустили из терминала.
        running=os.path.isdir(_LOCK_PATH),
        stamp=raw.get('stamp'),
        started=raw.get('started'),
        mode=raw.get('mode'),
        outcome=outcome,
        needs_attention=needs,
        behind=raw.get('behind', 0),
        ahead=raw.get('ahead', 0),
        auto_resolved=raw.get('auto_resolved', 0),
        conflicts_code=len(code),
        branch=raw.get('branch'),
        base_ref=raw.get('base_ref'),
        error=raw.get('error'),
        last_error=raw.get('last_error'),
        last_error_at=raw.get('last_error_at'),
        next_steps=raw.get('next_steps') or [],
        files=[
            {
                'file': c.get('file'),
                'hunks': c.get('hunks', 0),
                # Конфликт с нашим же вмерженным PR — самый частый класс здесь и
                # самый дешёвый в разборе. Приложению стоит показывать их отдельно.
                'ours_upstream': bool(c.get('ours_upstream')),
            }
            for c in code
        ],
    )


async def _notify_when_done(uid: str, args: List[str]) -> None:
    """Прогон в фоне + пуш, но ТОЛЬКО когда нужен человек.

    Зелёный результат намеренно молчит: если синк начнёт присылать «всё хорошо»
    каждый день, уведомления перестанут читать — и первое красное тоже.

    Подпроцесс именно асинхронный, а не поток и не executor: полный синк идёт
    минутами (мерж, регенерация, оба набора тестов), и занять на это время поток
    из общего пула значило бы отнять его у запросов. Здесь не занимается ничего.
    """
    launch_error = None
    try:
        proc = await asyncio.create_subprocess_exec(
            *args, stdout=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.DEVNULL
        )
        await proc.wait()
        outcome, needs = _CLASSES.get(proc.returncode, ('ERROR', True))
    except OSError as exc:
        outcome, needs, launch_error = 'ERROR', True, str(exc)
    if not needs:
        return
    raw = _read_status()
    conflicts = [c for c in (raw.get('conflicts') or []) if not c.get('generated')]
    body = (
        launch_error
        or raw.get('error')
        or 'Файлов с конфликтами: %d, отставание было %d.'
        % (
            len(conflicts),
            raw.get('behind', 0),
        )
    )
    await send_notification_async(
        uid,
        _NOTIFY_TITLE.get(outcome, 'Апстрим-синк'),
        body,
        data={'type': 'upstream_sync', 'outcome': outcome, 'stamp': str(raw.get('stamp') or '')},
    )


@router.get('/v1/selfhost/upstream-sync/status', tags=['selfhost'], response_model=SyncStatus)
def upstream_sync_status(uid: str = Depends(auth.get_current_user_uid)):
    """Что показывать на плашке: отставание, исход последнего прогона, идёт ли сейчас."""
    _guard(uid)
    return _to_status(_read_status())


@router.post('/v1/selfhost/upstream-sync/run', tags=['selfhost'], response_model=SyncStatus)
async def upstream_sync_run(data: SyncRunRequest, uid: str = Depends(auth.get_current_user_uid)):
    """Кнопка «Синхронизировать». Возвращается сразу — прогон идёт в фоне.

    Долгий ответ здесь был бы хуже бесполезного: тесты идут минутами, мобильный
    клиент отвалится по таймауту и человек решит, что синк упал.
    """
    _guard(uid)
    if os.path.isdir(_LOCK_PATH):
        raise HTTPException(status_code=409, detail='sync is already running')
    if data.mode not in ('dry', 'full'):
        raise HTTPException(status_code=400, detail='mode must be dry or full')

    args = [_SCRIPT] + (['--dry'] if data.mode == 'dry' else [])
    start_background_task(_notify_when_done(uid, args), name=f'upstream-sync:{data.mode}')

    status = _to_status(_read_status())
    status.running = True
    return status


@router.post('/v1/selfhost/upstream-sync/land', tags=['selfhost'], response_model=SyncStatus)
def upstream_sync_land(data: SyncLandRequest, uid: str = Depends(auth.get_current_user_uid)):
    """Второе подтверждение: влить названную ветку синка в `private`.

    Ветка называется явно, а не берётся из последнего статуса, чтобы нажатие
    старой кнопки в давно открытом экране не влило неожиданно другое.
    """
    _guard(uid)
    if os.path.isdir(_LOCK_PATH):
        raise HTTPException(status_code=409, detail='sync is already running')
    if not data.branch.startswith('sync/upstream-'):
        raise HTTPException(status_code=400, detail='only sync/upstream-* branches can be landed')

    proc = subprocess.run([_SCRIPT, '--land', data.branch], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    status = _to_status(_read_status())
    if proc.returncode not in (0, 10):
        raise HTTPException(status_code=409, detail=status.error or 'land failed: %s' % status.outcome)
    return status


@router.get('/v1/selfhost/upstream-sync/report', tags=['selfhost'])
def upstream_sync_report(stamp: Optional[str] = None, uid: str = Depends(auth.get_current_user_uid)):
    """Markdown-отчёт: последний или названный по метке."""
    _guard(uid)
    stamp = stamp or _read_status().get('stamp')
    if not stamp:
        raise HTTPException(status_code=404, detail='no report yet')
    # Метка приходит с клиента и попадает в путь — пускаем только тот алфавит,
    # который скрипт действительно порождает (ГГГГ-ММ-ДД-ЧЧММ).
    if not all(ch.isdigit() or ch == '-' for ch in stamp):
        raise HTTPException(status_code=400, detail='bad stamp')
    path = os.path.join(_OUT_DIR, '%s.md' % stamp)
    if not os.path.exists(path):
        raise HTTPException(status_code=404, detail='no such report')
    with open(path, encoding='utf-8') as fh:
        return {'stamp': stamp, 'markdown': fh.read()}
