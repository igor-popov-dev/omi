"""Chat model client for the private ask_claude_bridge HTTP service.

The bridge (private, lives outside this repo — see `~/omi-jarvis/docs/ask-claude-bridge.md`
and `~/omi-jarvis/marathon/ask_claude_bridge.py`) forwards a question + retrieved context to
`claude -p` under a personal Claude subscription and streams the answer back. This module is
the ``BaseChatModel`` adapter so ``utils.llm.clients.get_llm()`` can route a feature to it like
any other provider — see PLAN.md §4: this glue is intentionally private and never goes upstream.

Bridge contract:
    POST {base_url}/ask {"question": str, "context": str, "model": str, "tools_enabled": bool}
    -> text/event-stream, "data: <json>\\n\\n" lines:
         {"type": "delta", "text": "..."}  (may arrive as a single chunk today)
         {"type": "done", "text": "<full response>"}
    GET {base_url}/health -> {"status": "ok", "backend": "fake"|"real"}
"""

import json
import logging
import os
from typing import Any, Dict, List, Optional, Tuple

import httpx

try:
    from langchain_core.callbacks import CallbackManagerForLLMRun
except ImportError:

    class CallbackManagerForLLMRun:
        pass


from langchain_core.language_models import BaseChatModel
from langchain_core.messages import AIMessage, BaseMessage
from langchain_core.outputs import ChatGeneration, ChatResult

logger = logging.getLogger(__name__)

CLAUDE_BRIDGE_URL_ENV_VAR = 'CLAUDE_BRIDGE_URL'
CLAUDE_BRIDGE_TIMEOUT_ENV_VAR = 'CLAUDE_BRIDGE_TIMEOUT_SECONDS'
DEFAULT_CLAUDE_BRIDGE_URL = 'http://127.0.0.1:8766'
DEFAULT_TIMEOUT_SECONDS = 120.0


def get_claude_bridge_url() -> str:
    return os.environ.get(CLAUDE_BRIDGE_URL_ENV_VAR, '').strip() or DEFAULT_CLAUDE_BRIDGE_URL


def get_claude_bridge_timeout_seconds() -> float:
    raw = os.environ.get(CLAUDE_BRIDGE_TIMEOUT_ENV_VAR, '').strip()
    if not raw:
        return DEFAULT_TIMEOUT_SECONDS
    try:
        return float(raw)
    except ValueError:
        logger.warning(
            '%s=%r is not a number, using default %.0fs', CLAUDE_BRIDGE_TIMEOUT_ENV_VAR, raw, DEFAULT_TIMEOUT_SECONDS
        )
        return DEFAULT_TIMEOUT_SECONDS


def _message_text(message: BaseMessage) -> str:
    content = message.content
    return content if isinstance(content, str) else str(content)


def _messages_to_question_and_context(messages: List[BaseMessage]) -> Tuple[str, str]:
    """Split a LangChain message list into (question, context) for the bridge's contract.

    The bridge has no chat-turn concept — one question plus optional context text. The
    last message is the question; everything before it (system prompt + earlier turns,
    which is where retrieval context already lives for this codebase's prompt builders)
    is joined as context.
    """
    if not messages:
        return '', ''
    *context_messages, last = messages
    question = _message_text(last)
    context = '\n\n'.join(_message_text(m) for m in context_messages)
    return question, context


class ClaudeBridgeChatModel(BaseChatModel):
    """LangChain chat model backed by the private ask_claude_bridge HTTP service."""

    base_url: str
    model_name: str
    timeout_seconds: float = DEFAULT_TIMEOUT_SECONDS
    # Gates MCP tool access on the bridge side — see model_config.py's
    # CLAUDE_BRIDGE_PROFILE comment. Default False: a construction site that
    # forgets to set this explicitly gets the safe, tool-free behavior. Only
    # the explicit chat channel (chat_responses) should ever pass True.
    tools_enabled: bool = False
    # Test-only hook: inject an httpx.MockTransport to avoid a real bridge process,
    # matching this repo's convention for HTTP-client unit tests (see
    # tests/unit/test_llm_gateway_openai_provider.py).
    transport: Any = None

    @property
    def _llm_type(self) -> str:
        return 'claude-bridge'

    def _generate(
        self,
        messages: List[BaseMessage],
        stop: Optional[List[str]] = None,
        run_manager: Optional[CallbackManagerForLLMRun] = None,
        **kwargs: Any,
    ) -> ChatResult:
        question, context = _messages_to_question_and_context(messages)
        payload: Dict[str, Any] = {
            'question': question,
            'context': context,
            'model': self.model_name,
            'tools_enabled': self.tools_enabled,
        }

        text_parts: List[str] = []
        with httpx.Client(timeout=self.timeout_seconds, transport=self.transport) as client:
            with client.stream('POST', f'{self.base_url}/ask', json=payload) as response:
                response.raise_for_status()
                for line in response.iter_lines():
                    if not line or not line.startswith('data:'):
                        continue
                    event = json.loads(line[len('data:') :].strip())
                    event_type = event.get('type')
                    if event_type == 'delta':
                        delta = event.get('text', '')
                        text_parts.append(delta)
                        if run_manager:
                            run_manager.on_llm_new_token(delta)
                    elif event_type == 'done':
                        # The bridge currently emits one delta covering the whole answer
                        # (no --include-partial-messages yet — see ask-claude-bridge.md),
                        # so 'done' duplicates it. Prefer 'done' as ground truth over the
                        # concatenated deltas in case that ever changes to true chunking.
                        full_text = event.get('text')
                        if full_text is not None:
                            text_parts = [full_text]

        message = AIMessage(content=''.join(text_parts))
        return ChatResult(generations=[ChatGeneration(message=message)])
