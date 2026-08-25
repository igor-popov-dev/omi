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
         {"type": "error", "code": "usage_limit", "message": "...", "resets_at": 1787541000}
             -> no "done" follows; the answer does not exist. Raised here as
                ClaudeBridgeUpstreamError so a provider outage looks like one.
    GET {base_url}/health -> {"status": "ok", "backend": "fake"|"real"}
"""

import json
import logging
import os
import re
import threading
import time
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


class ClaudeBridgeUpstreamError(RuntimeError):
    """The bridge refused to answer — the personal Claude subscription window is spent.

    Why this is an exception and not just text: the bridge used to stream the CLI's
    "You've hit your session limit · resets 6:10am" notice as if it were the model's
    answer, HTTP 200. Conversation structuring then tried to parse that sentence as
    JSON, blew up with OutputParserException, and the conversation was rolled back to
    `in_progress` forever — invisible to the user with no error anywhere they could
    see (two conversations lost that way on 2026-08-24, see ~/omi-jarvis lane2 log).
    A provider outage has to surface as a provider outage.
    """

    # Read by utils.llm.gateway_error_contract. Every refusal the bridge reports
    # is the subscription window or the CLI being unable to answer right now, so
    # the same conversation is still finalizable once the window resets. Without
    # this marker the durable finalizer spends its whole attempt budget during an
    # outage and discards the conversation (three of Igor's were hidden that way
    # on 2026-08-24 between 14:05 and 15:27 MSK).
    provider_unavailable = True

    def __init__(self, message: str, code: str = 'upstream_error', resets_at: Optional[int] = None):
        super().__init__(message)
        self.message = message
        self.code = code
        self.resets_at = resets_at


# --- Subscription-window circuit breaker -------------------------------------
#
# When the personal subscription window is spent, the bridge answers every call
# with the same refusal and a `resets_at` epoch. The backend does not know that:
# on 2026-08-25 between 03:00 and 04:00 it made 259 consecutive rejected calls
# (measured from the CLI journals, marathon/lane5-finding-quota-burn.md), each
# one spawning a `claude -p` process on the mini just to be told the door is
# locked. Background finalization is the bulk of it and retries on its own
# schedule, so the storm lasts as long as the outage does.
#
# While a refusal carries a future `resets_at`, calls fail fast with the same
# ClaudeBridgeUpstreamError (still `provider_unavailable`, so the durable
# finalizer keeps deferring the conversation instead of discarding it). The
# breaker is half-open: one real call is allowed through every
# CLAUDE_BRIDGE_QUOTA_PROBE_SECONDS, because the window slides and can reopen
# earlier than the announced reset. Any successful answer clears it.
CLAUDE_BRIDGE_QUOTA_BREAKER_ENV_VAR = 'CLAUDE_BRIDGE_QUOTA_BREAKER'
CLAUDE_BRIDGE_QUOTA_PROBE_ENV_VAR = 'CLAUDE_BRIDGE_QUOTA_PROBE_SECONDS'
DEFAULT_QUOTA_PROBE_SECONDS = 60.0

_quota_lock = threading.Lock()
_quota_block: Optional[Dict[str, Any]] = None


def _quota_breaker_enabled() -> bool:
    return os.environ.get(CLAUDE_BRIDGE_QUOTA_BREAKER_ENV_VAR, '1').strip().lower() not in ('0', 'false', 'no')


def _quota_probe_seconds() -> float:
    raw = os.environ.get(CLAUDE_BRIDGE_QUOTA_PROBE_ENV_VAR, '').strip()
    if not raw:
        return DEFAULT_QUOTA_PROBE_SECONDS
    try:
        return max(0.0, float(raw))
    except ValueError:
        logger.warning(
            '%s=%r is not a number, using default %.0fs',
            CLAUDE_BRIDGE_QUOTA_PROBE_ENV_VAR,
            raw,
            DEFAULT_QUOTA_PROBE_SECONDS,
        )
        return DEFAULT_QUOTA_PROBE_SECONDS


def reset_quota_breaker() -> None:
    """Forget a recorded outage (used by tests and by a successful answer)."""
    global _quota_block
    with _quota_lock:
        _quota_block = None


def _record_quota_block(error: 'ClaudeBridgeUpstreamError') -> None:
    """Remember a refusal that announced when the window reopens."""
    global _quota_block
    if not _quota_breaker_enabled() or not isinstance(error.resets_at, (int, float)):
        return
    now = time.time()
    if error.resets_at <= now:
        return
    with _quota_lock:
        _quota_block = {
            'resets_at': float(error.resets_at),
            'message': error.message,
            'code': error.code,
            # The refusal that opened the breaker counts as this interval's probe.
            'last_probe_at': now,
        }
    logger.warning(
        'claude bridge quota window closed until %s — failing fast until then (code=%s)',
        time.strftime('%Y-%m-%d %H:%M:%S', time.localtime(error.resets_at)),
        error.code,
    )


def _quota_gate() -> None:
    """Fail fast while the window is known-closed, letting one probe through per interval."""
    global _quota_block
    if not _quota_breaker_enabled():
        return
    now = time.time()
    with _quota_lock:
        block = _quota_block
        if block is None:
            return
        if block['resets_at'] <= now:
            _quota_block = None
            logger.info('claude bridge quota window reset reached — retrying for real')
            return
        if now - block['last_probe_at'] >= _quota_probe_seconds():
            block['last_probe_at'] = now
            return
        message, code, resets_at = block['message'], block['code'], block['resets_at']
    raise ClaudeBridgeUpstreamError(message, code=code, resets_at=int(resets_at))


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
        _quota_gate()
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
                    elif event_type == 'error':
                        # No answer exists: whatever deltas arrived before this are a
                        # truncated fragment at best, so they are dropped, not returned.
                        upstream_error = ClaudeBridgeUpstreamError(
                            event.get('message') or 'claude bridge upstream error',
                            code=event.get('code') or 'upstream_error',
                            resets_at=event.get('resets_at'),
                        )
                        _record_quota_block(upstream_error)
                        raise upstream_error
                    elif event_type == 'done':
                        # The bridge currently emits one delta covering the whole answer
                        # (no --include-partial-messages yet — see ask-claude-bridge.md),
                        # so 'done' duplicates it. Prefer 'done' as ground truth over the
                        # concatenated deltas in case that ever changes to true chunking.
                        full_text = event.get('text')
                        if full_text is not None:
                            text_parts = [full_text]

        # An answer proves the window is open again, whatever the announced reset said.
        reset_quota_breaker()
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
