"""Lightweight helpers for conversation data that avoid importing models.conversation."""

from typing import Any, Dict, List, Mapping, cast

from models.chat import MessageConversation, MessageConversationStructured


def extract_memory_ids(memories: List[Any], limit: int = 5) -> List[str]:
    """Extract IDs from a list of memories (may be dicts or objects).

    Used by chat routers to get conversation IDs without importing Conversation.
    """
    result: List[str] = []
    for m in memories[:limit]:
        if isinstance(m, dict):
            d = cast(Dict[str, Any], m)
            result.append(d.get('id', ''))
        else:
            result.append(m.id)
    return result


def _field(source: Any, name: str) -> Any:
    if isinstance(source, Mapping):
        return cast(Mapping[str, Any], source).get(name)
    return getattr(source, name, None)


def to_message_conversations(memories: List[Any], limit: int = 5) -> List[MessageConversation]:
    """Build the front-facing citation list from memories that may be dicts or objects.

    Retrieval routes disagree on the shape they collect: the agentic tools append plain
    dicts (utils/retrieval/tools/conversation_tools.py), while the qa_rag route hands back
    deserialized Conversation objects (utils/retrieval/graph.py). ``MessageConversation(**m)``
    accepts only the first and raises ``TypeError`` on the second, which used to turn a
    delivered answer into a persistence failure. Reading the three displayed fields by name
    works for both shapes -- and skips dumping whole transcripts just to render a title.
    """
    result: List[MessageConversation] = []
    for m in memories[:limit]:
        structured = _field(m, 'structured')
        result.append(
            MessageConversation(
                id=_field(m, 'id') or '',
                created_at=_field(m, 'created_at'),
                structured=MessageConversationStructured(
                    title=_field(structured, 'title') or '',
                    emoji=_field(structured, 'emoji') or '',
                ),
            )
        )
    return result
