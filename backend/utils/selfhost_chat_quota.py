"""Self-host patch (docs/selfhost-patches.md): чат без месячного потолка подписки.

Логика живёт в отдельном файле, которого нет в upstream, — он не может дать
конфликт при `git merge upstream/main`. В `utils/subscription.py` остаются две
короткие врезки, помеченные `Self-host patch`.

ПОЧЕМУ. Upstream меряет чат помесячно, потому что каждый вопрос стоит ему денег
у платного провайдера: план `basic` («Free») — 30 вопросов в месяц. У нас этого
провайдера нет вовсе: чат уходит в `claude-bridge` на подписку Игоря, и
серверная стоимость вопроса равна нулю. Мерить было нечего, а счётчик всё это
время исправно тикал — к 25.08 он дотикал до 39/30, и телефон стал получать
вместо ответа канонную реплику «лимит исчерпан».

Симптом обманчив, поэтому его стоит описать: `enforce_chat_quota` срабатывает
ДО провайдера, `routers/chat.py` превращает свой же 402 в готовый текст
ассистента, и наружу уходит `POST /v2/messages 200 OK`. В логах моста при этом
ноль запросов и ноль ошибок, в логах бэкенда — ноль отказов. Ищущий причину
идёт в мост и в провайдера, а её там нет.

Опт-ин явный (`OMI_SELFHOST_UNLIMITED_CHAT`): без переменной поведение upstream
сохраняется слово в слово, включая платные планы и overage.

Счётчик расхода мы НЕ глушим: `used` в снапшоте остаётся настоящим, снимается
только потолок (`limit=None`, `allowed=True`). Это диагностика — видно, сколько
вопросов реально задано, и врезку можно снять в любой момент, не потеряв
истории. Чтение расхода обёрнуто в fail-open: если источник расхода недоступен,
чат всё равно НЕ блокируется. Ради этого врезка и существует — она не должна
уметь отказывать.
"""

from __future__ import annotations

import logging
import os
from typing import Any, Dict

logger = logging.getLogger(__name__)

SELFHOST_UNLIMITED_CHAT_ENV = 'OMI_SELFHOST_UNLIMITED_CHAT'

_TRUTHY = ('1', 'true', 'yes', 'on')


def selfhost_chat_quota_unlimited() -> bool:
    """True, когда self-host снял месячный потолок чата.

    Читается на каждом вызове, а не кэшируется: рубильник должен быть виден
    сразу после рестарта службы и не зависеть от порядка импортов.
    """

    return os.environ.get(SELFHOST_UNLIMITED_CHAT_ENV, '').strip().lower() in _TRUTHY


def unlimited_chat_snapshot(uid: str, *, firestore_client: Any = None) -> Dict[str, Any]:
    """Снапшот квоты вида «расход честный, потолка нет».

    Форма словаря — ровно та же, что у `utils.subscription.get_chat_quota_snapshot`:
    вызывающие (`/v1/users/me/usage-quota`, `/v1/users/me/subscription`,
    `routers/omni_relay.py`, `enforce_chat_quota`) не должны знать о врезке.

    Импорты локальные: наш файл не участвует в графе импортов upstream и не
    может внести цикл.
    """

    from models.users import PlanType

    used = 0.0
    reset_at = None
    try:
        import database.user_usage as user_usage_db

        usage = user_usage_db.get_monthly_chat_usage(uid, firestore_client=firestore_client)
        used = float(usage['questions'])
        reset_at = usage['reset_at']
    except Exception:
        # Fail-open и молча-но-заметно: расход это только показание приборов,
        # а решение «пускать» принято выше по причине, от базы не зависящей.
        logger.warning('selfhost unlimited chat: usage read failed, reporting used=0', exc_info=True)

    return {
        'plan': PlanType.unlimited,
        'unit': 'questions',
        'used': used,
        'limit': None,
        'allowed': True,
        'reset_at': reset_at,
    }
