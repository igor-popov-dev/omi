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
import re
from typing import Any, Dict, List, Optional, Tuple, Type, Union

import httpx

try:
    from langchain_core.callbacks import CallbackManagerForLLMRun
except ImportError:

    class CallbackManagerForLLMRun:
        pass


from langchain_core.exceptions import OutputParserException
from langchain_core.language_models import BaseChatModel
from langchain_core.messages import AIMessage, BaseMessage
from langchain_core.output_parsers import BaseOutputParser, JsonOutputParser, PydanticOutputParser
from langchain_core.outputs import ChatGeneration, ChatResult
from langchain_core.prompt_values import PromptValue
from langchain_core.runnables import Runnable
from pydantic import BaseModel

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

    def with_structured_output(
        self,
        schema: Union[Type[BaseModel], dict],
        *,
        include_raw: bool = False,
        **kwargs: Any,
    ) -> Runnable:
        """Prompt-and-parse stand-in for the tool-calling structured output the bridge lacks.

        See the module-level notes below _BridgeStructuredOutput. `include_raw=True` (which
        returns {'raw', 'parsed', 'parsing_error'} instead of the model) has no caller on the
        bridge path today, so it is rejected loudly rather than silently ignored.
        """
        if include_raw:
            raise NotImplementedError('claude-bridge structured output does not support include_raw=True')
        if isinstance(schema, type) and issubclass(schema, BaseModel):
            parser: BaseOutputParser = PydanticOutputParser(pydantic_object=schema)
        elif isinstance(schema, dict):
            parser = JsonOutputParser()
        else:
            raise TypeError(f'claude-bridge structured output needs a pydantic model or JSON schema, got {schema!r}')
        return _BridgeStructuredOutput(self, parser)


# ---------------------------------------------------------------------------
# Structured output over the bridge
# ---------------------------------------------------------------------------
#
# `.with_structured_output()` is the one BaseChatModel method the bridge could not
# serve, which is why model_config.py's CLAUDE_BRIDGE_PROFILE comment lists it as
# the reason conv_app_select and the proactive-notification chain stayed on
# 'openai'. Under self-host there is no OpenAI key, so those features were dead
# (lane7: mentor notifications never fired at all).
#
# The bridge has no tool-calling and no response_format knob — it is one text
# question in, one text answer out. So we do what the rest of this codebase already
# does for bridge-routed features: ask for JSON in the prompt (PydanticOutputParser's
# schema instructions) and parse the reply. The difference from a plain
# `prompt | llm | parser` chain is that this keeps the *call site* unchanged —
# proactive_notification.py still writes `.with_structured_output(Model).invoke(...)`
# and gets a validated model back, on either provider.
#
# `claude -p` likes to wrap JSON in ``` fences or introduce it with a sentence, so
# _extract_json_blob() peels that off before parsing, and a failed parse is retried
# once with an explicit "JSON only" reminder before giving up.

_JSON_FENCE_RE = re.compile(r'```(?:json)?\s*(.+?)\s*```', re.DOTALL)

_STRUCTURED_INSTRUCTION_TEMPLATE = """

Answer with a single JSON object and nothing else — no preamble, no explanation, no markdown fences.

{format_instructions}"""

_STRUCTURED_RETRY_REMINDER = """

Your previous answer could not be parsed as JSON. Output the JSON object only, starting with {{ and ending with }}."""


def _extract_json_blob(text: str) -> str:
    """Pull the JSON object out of a chat reply that may be fenced or prefaced with prose."""
    fenced = _JSON_FENCE_RE.search(text)
    if fenced:
        return fenced.group(1).strip()
    start = text.find('{')
    end = text.rfind('}')
    if start != -1 and end > start:
        return text[start : end + 1]
    return text.strip()


def _append_to_prompt(prompt_input: Any, suffix: str) -> Any:
    """Return `prompt_input` with `suffix` appended to the text the bridge treats as the question.

    _messages_to_question_and_context() makes the LAST message the question and folds
    everything before it into context, so the schema instructions have to land on the
    last message or the model may never see them as the actual ask.
    """
    if isinstance(prompt_input, str):
        return prompt_input + suffix
    if isinstance(prompt_input, PromptValue):
        prompt_input = prompt_input.to_messages()
    if isinstance(prompt_input, BaseMessage):
        prompt_input = [prompt_input]
    if isinstance(prompt_input, list) and prompt_input and isinstance(prompt_input[-1], BaseMessage):
        head, last = list(prompt_input[:-1]), prompt_input[-1]
        patched = last.model_copy(update={'content': _message_text(last) + suffix})
        return head + [patched]
    raise TypeError(f'claude-bridge structured output does not support prompt input of type {type(prompt_input)!r}')


class _BridgeStructuredOutput(Runnable):
    """What ClaudeBridgeChatModel.with_structured_output() hands back: prompt -> parsed model."""

    def __init__(self, llm: 'ClaudeBridgeChatModel', parser: BaseOutputParser, attempts: int = 2):
        self._llm = llm
        self._parser = parser
        self._attempts = max(1, attempts)
        self._instruction = _STRUCTURED_INSTRUCTION_TEMPLATE.format(
            format_instructions=parser.get_format_instructions()
        )

    def invoke(self, input: Any, config: Optional[Any] = None, **kwargs: Any) -> Any:
        last_error: Optional[Exception] = None
        for attempt in range(self._attempts):
            suffix = self._instruction if attempt == 0 else self._instruction + _STRUCTURED_RETRY_REMINDER
            reply = self._llm.invoke(_append_to_prompt(input, suffix), config=config, **kwargs)
            text = _message_text(reply) if isinstance(reply, BaseMessage) else str(reply)
            try:
                return self._parser.parse(_extract_json_blob(text))
            except Exception as e:  # OutputParserException + pydantic ValidationError
                last_error = e
                logger.warning(
                    'claude-bridge structured output parse failed (attempt %d/%d): %s',
                    attempt + 1,
                    self._attempts,
                    e,
                )
        raise OutputParserException(
            f'claude-bridge returned no parseable JSON after {self._attempts} attempts: {last_error}'
        )
