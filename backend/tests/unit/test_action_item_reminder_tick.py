"""Выборка и идемпотентность серверного тика напоминаний (self-host, 02.09).

Скрипт живёт вне дерева бэкенда (~/omi-jarvis-backend/bin/action_item_reminder_tick.py),
бэкенд он импортирует лениво внутри run_tick, поэтому здесь грузим модуль по пути и
проверяем чистые функции: select_due_items (окно, completed, reminded_at, naive-даты)
и remind_user (send -> mark, ошибка одной задачи не валит остальные).
"""

from __future__ import annotations

import importlib.util
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest

_SCRIPT = Path(__file__).resolve().parents[4] / 'bin' / 'action_item_reminder_tick.py'
if not _SCRIPT.is_file():
    pytest.skip(f'self-host tick script not found: {_SCRIPT}', allow_module_level=True)

_spec = importlib.util.spec_from_file_location('action_item_reminder_tick', _SCRIPT)
assert _spec is not None and _spec.loader is not None
tick = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(tick)

NOW = datetime(2026, 9, 2, 12, 0, tzinfo=timezone.utc)


def _item(id_: str, due_offset: timedelta, **extra):
    return {'id': id_, 'description': f'task {id_}', 'due_at': NOW + due_offset, 'completed': False, **extra}


def test_select_due_items_window_and_flags():
    items = [
        _item('due_now', timedelta(0)),
        _item('due_5m_ago', timedelta(minutes=-5)),
        _item('future', timedelta(minutes=1)),
        _item('too_old', timedelta(hours=-24, minutes=-1)),
        _item('edge_24h', timedelta(hours=-24)),
        _item('done', timedelta(minutes=-2), completed=True),
        _item('done_status', timedelta(minutes=-2), completed=None, status='completed'),
        _item('already', timedelta(minutes=-3), reminded_at=NOW - timedelta(minutes=1)),
        {'id': 'no_due', 'description': 'x', 'completed': False},
        {'id': 'bad_due', 'description': 'x', 'completed': False, 'due_at': '2026-09-02T11:00:00Z'},
    ]
    picked = [i['id'] for i in tick.select_due_items(items, NOW)]
    # Самая старая — первой, edge ровно на границе окна включается.
    assert picked == ['edge_24h', 'due_5m_ago', 'due_now']


def test_select_due_items_treats_naive_due_at_as_utc():
    naive = {
        'id': 'naive',
        'description': 'x',
        'completed': False,
        'due_at': (NOW - timedelta(minutes=1)).replace(tzinfo=None),
    }
    assert [i['id'] for i in tick.select_due_items([naive], NOW)] == ['naive']


def test_select_due_items_custom_lookback():
    items = [_item('old', timedelta(hours=-2)), _item('fresh', timedelta(minutes=-30))]
    assert [i['id'] for i in tick.select_due_items(items, NOW, lookback=timedelta(hours=1))] == ['fresh']


def test_remind_user_sends_then_marks_and_is_idempotent():
    sent, marked = [], []

    def send(uid, title, body, data=None, tokens=None):
        sent.append((uid, title, body, data, tokens))

    def mark(uid, item_id, now):
        marked.append((uid, item_id, now))

    items = [_item('a', timedelta(minutes=-1)), _item('b', timedelta(minutes=-2), description='')]
    assert tick.remind_user('u1', items, NOW, send=send, mark_reminded=mark, tokens=['t1']) == (2, 0)
    assert sent[0] == ('u1', 'Напоминание', 'task a', {'navigate_to': '/action-items', 'action_item_id': 'a'}, ['t1'])
    assert sent[1][2] == tick.EMPTY_DESCRIPTION
    assert marked == [('u1', 'a', NOW), ('u1', 'b', NOW)]

    # Второй тик: помеченные задачи в выборку уже не попадают — ничего не уходит.
    for item, (_, _, now) in zip(items, marked):
        item['reminded_at'] = now
    assert tick.select_due_items(items, NOW + timedelta(minutes=1)) == []


def test_remind_user_isolates_failures():
    calls = []

    def send(uid, title, body, data=None, tokens=None):
        if data['action_item_id'] == 'boom':
            raise RuntimeError('fcm down')
        calls.append(('send', data['action_item_id']))

    def mark(uid, item_id, now):
        if item_id == 'mark_fail':
            raise RuntimeError('mongo down')
        calls.append(('mark', item_id))

    items = [
        _item('boom', timedelta(minutes=-3)),
        _item('mark_fail', timedelta(minutes=-2)),
        _item('ok', timedelta(minutes=-1)),
    ]
    assert tick.remind_user('u1', items, NOW, send=send, mark_reminded=mark) == (1, 2)
    # Упавшая отправка не помечается; упавшая пометка не блокирует следующую задачу.
    assert calls == [('send', 'mark_fail'), ('send', 'ok'), ('mark', 'ok')]


def test_remind_user_dry_run_touches_nothing():
    def boom(*a, **k):
        raise AssertionError('must not be called in dry-run')

    assert tick.remind_user('u1', [_item('a', timedelta(0))], NOW, send=boom, mark_reminded=boom, dry_run=True) == (
        0,
        0,
    )
