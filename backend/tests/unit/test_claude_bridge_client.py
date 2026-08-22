from __future__ import annotations

import json

import httpx
import pytest

from utils.llm.claude_bridge_client import (
    ClaudeBridgeChatModel,
    _messages_to_question_and_context,
    get_claude_bridge_timeout_seconds,
    get_claude_bridge_url,
)
from langchain_core.callbacks import BaseCallbackHandler
from langchain_core.messages import HumanMessage, SystemMessage


def _sse_body(*events: dict) -> bytes:
    return b''.join(f'data: {json.dumps(event)}\n\n'.encode() for event in events)


def _fake_bridge(events: list[dict], seen_requests: list[httpx.Request] | None = None):
    def handler(request: httpx.Request) -> httpx.Response:
        if seen_requests is not None:
            seen_requests.append(request)
        return httpx.Response(200, content=_sse_body(*events), headers={'content-type': 'text/event-stream'})

    return httpx.MockTransport(handler)


def test_messages_to_question_and_context_splits_last_message_as_question():
    messages = [
        SystemMessage(content='ctx line 1'),
        HumanMessage(content='ctx line 2'),
        HumanMessage(content='the question'),
    ]
    question, context = _messages_to_question_and_context(messages)
    assert question == 'the question'
    assert context == 'ctx line 1\n\nctx line 2'


def test_messages_to_question_and_context_empty_list():
    assert _messages_to_question_and_context([]) == ('', '')


def test_invoke_concatenates_deltas_and_prefers_done_text():
    events = [
        {'type': 'delta', 'text': 'Hello '},
        {'type': 'delta', 'text': 'world'},
        {'type': 'done', 'text': 'Hello world'},
    ]
    model = ClaudeBridgeChatModel(base_url='http://bridge.test', model_name='sonnet', transport=_fake_bridge(events))

    result = model.invoke([HumanMessage(content='hi')])

    assert result.content == 'Hello world'


def test_invoke_sends_question_context_and_model_in_payload():
    seen_requests: list[httpx.Request] = []
    events = [{'type': 'done', 'text': 'ok'}]
    model = ClaudeBridgeChatModel(
        base_url='http://bridge.test', model_name='sonnet', transport=_fake_bridge(events, seen_requests)
    )

    model.invoke([SystemMessage(content='some context'), HumanMessage(content='what time is it')])

    assert len(seen_requests) == 1
    request = seen_requests[0]
    assert request.url.path == '/ask'
    body = json.loads(request.content)
    assert body == {
        'question': 'what time is it',
        'context': 'some context',
        'model': 'sonnet',
        'tools_enabled': False,
    }


def test_invoke_sends_tools_enabled_true_when_constructed_with_it():
    seen_requests: list[httpx.Request] = []
    events = [{'type': 'done', 'text': 'ok'}]
    model = ClaudeBridgeChatModel(
        base_url='http://bridge.test',
        model_name='sonnet',
        tools_enabled=True,
        transport=_fake_bridge(events, seen_requests),
    )

    model.invoke([HumanMessage(content='what time is it')])

    body = json.loads(seen_requests[0].content)
    assert body['tools_enabled'] is True


def test_tools_enabled_defaults_to_false():
    model = ClaudeBridgeChatModel(base_url='http://bridge.test', model_name='sonnet')
    assert model.tools_enabled is False


def test_invoke_reports_deltas_to_run_manager_callback():
    events = [
        {'type': 'delta', 'text': 'a'},
        {'type': 'delta', 'text': 'b'},
        {'type': 'done', 'text': 'ab'},
    ]
    model = ClaudeBridgeChatModel(base_url='http://bridge.test', model_name='sonnet', transport=_fake_bridge(events))
    seen_tokens: list[str] = []

    class _Recorder(BaseCallbackHandler):
        def on_llm_new_token(self, token, **kwargs):
            seen_tokens.append(token)

    model.invoke([HumanMessage(content='hi')], {'callbacks': [_Recorder()]})

    assert seen_tokens == ['a', 'b']


def test_invoke_raises_on_http_error():
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(500, text='bridge down')

    model = ClaudeBridgeChatModel(
        base_url='http://bridge.test', model_name='sonnet', transport=httpx.MockTransport(handler)
    )

    with pytest.raises(httpx.HTTPStatusError):
        model.invoke([HumanMessage(content='hi')])


def test_get_claude_bridge_url_defaults_when_unset(monkeypatch):
    monkeypatch.delenv('CLAUDE_BRIDGE_URL', raising=False)
    assert get_claude_bridge_url() == 'http://127.0.0.1:8766'


def test_get_claude_bridge_url_reads_env(monkeypatch):
    monkeypatch.setenv('CLAUDE_BRIDGE_URL', 'http://mini.local:8766')
    assert get_claude_bridge_url() == 'http://mini.local:8766'


def test_get_claude_bridge_timeout_seconds_default(monkeypatch):
    monkeypatch.delenv('CLAUDE_BRIDGE_TIMEOUT_SECONDS', raising=False)
    assert get_claude_bridge_timeout_seconds() == 120.0


def test_get_claude_bridge_timeout_seconds_invalid_falls_back(monkeypatch):
    monkeypatch.setenv('CLAUDE_BRIDGE_TIMEOUT_SECONDS', 'not-a-number')
    assert get_claude_bridge_timeout_seconds() == 120.0
