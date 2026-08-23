"""Self-host patch, not for upstream: persist the voice-mode dialogue into chat.

WHY THIS FILE EXISTS SEPARATELY
-------------------------------
The free-form voice mode talks to Gemini Live over its own socket, so nothing it
says or hears ever reaches the chat history. From the user's side that reads as two
disconnected assistants: the voice one remembers the last ten minutes, the chat one
has never heard of them.

Upstream has no endpoint for "just store these turns" — `POST /v2/messages` exists to
*generate* a reply, which is exactly what we must not do here (the reply already
happened, out loud). Hence this narrow route.

Kept in its own file so upstream merges cannot conflict with it; the only upstream
file touched is `main.py`, by one `include_router` line. See `docs/selfhost-patches.md`.
"""

import uuid
from datetime import datetime, timezone
from typing import List, Literal, Optional

from fastapi import APIRouter, Depends
from pydantic import BaseModel, Field

import database.chat as chat_db
from models.chat import Message
from utils.other import endpoints as auth

router = APIRouter()

# A voice session can be long; this caps one request, not the conversation.
_MAX_TURNS_PER_CALL = 50


class VoiceTurn(BaseModel):
    sender: Literal['human', 'ai']
    text: str
    # Client-side timestamp so turns keep their real order even when a batch is
    # flushed late (the mode buffers while the socket is busy speaking).
    spoken_at: Optional[datetime] = None


class VoiceLogRequest(BaseModel):
    turns: List[VoiceTurn] = Field(..., max_length=_MAX_TURNS_PER_CALL)


class VoiceLogResponse(BaseModel):
    stored: int


@router.post('/v1/selfhost/voice-log', tags=['selfhost'], response_model=VoiceLogResponse)
def log_voice_turns(
    data: VoiceLogRequest,
    uid: str = Depends(auth.get_current_user_uid),
):
    """Append already-spoken voice turns to the chat feed verbatim.

    Deliberately does NOT run the chat pipeline: no reply generation, no app
    routing, no quota — the exchange already happened out loud, this only records
    it. Empty texts are dropped rather than stored as blank bubbles.
    """
    session = chat_db.get_chat_session(uid)
    chat_session_id = session['id'] if session else None

    stored = 0
    for turn in data.turns:
        text = turn.text.strip()
        if not text:
            continue
        message = Message(
            id=str(uuid.uuid4()),
            text=text,
            created_at=turn.spoken_at or datetime.now(timezone.utc),
            sender=turn.sender,  # type: ignore[reportArgumentType]  # pydantic accepts str for the enum
            type='text',  # type: ignore[reportArgumentType]
            from_external_integration=False,
            memories_id=[],
            chat_session_id=chat_session_id,
        )
        chat_db.add_message(uid, message.model_dump())
        if chat_session_id:
            chat_db.add_message_to_chat_session(uid, chat_session_id, message.id)
        stored += 1

    return VoiceLogResponse(stored=stored)
