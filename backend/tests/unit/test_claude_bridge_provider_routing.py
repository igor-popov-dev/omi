"""Wiring tests for the claude-bridge provider: QoS profile entry + provider dispatch.

Full env-driven activation (MODEL_QOS=claude_bridge) isn't exercised here because the
active profile is resolved once at `utils.llm.model_config` import time; these tests
instead verify the two pieces that make activation work — the profile table has the
right route, and the dispatcher in `providers.get_default_client` builds the right
client for that route — matching this repo's existing test_llm_gateway_config.py style
of importing utils.llm modules directly (no heavy stubbing needed).
"""

from __future__ import annotations

from utils.llm.claude_bridge_client import ClaudeBridgeChatModel
from utils.llm.model_config import CLAUDE_BRIDGE_PROFILE, MODEL_QOS_PROFILES, get_route_options
from utils.llm.providers import get_default_client, get_or_create_claude_bridge_llm


def test_claude_bridge_profile_routes_chat_responses_only():
    profile = CLAUDE_BRIDGE_PROFILE
    assert profile['chat_responses'] == ('opus', 'claude-bridge')
    # Agentic tool-calling chat must stay on real Anthropic — the bridge has no
    # tool-use support, only plain question+context.
    assert profile['chat_agent'] == ('claude-sonnet-4-6', 'anthropic')


def test_claude_bridge_profile_routes_conversation_finalize_features():
    # conv_discard/conv_structure/conv_action_items/conv_app_result all parse a plain
    # text reply with a PydanticOutputParser rather than .with_structured_output(),
    # so they work over the bridge — without this, self-host conversations never
    # leave in_progress (OpenAI 401 under PROVIDER_MODE=offline).
    profile = CLAUDE_BRIDGE_PROFILE
    for feature in ('conv_discard', 'conv_structure', 'conv_action_items', 'conv_app_result'):
        assert profile[feature] == ('opus', 'claude-bridge')
    # conv_app_select calls .with_structured_output() — the bridge can't serve that,
    # so it must stay on its two-tier default.
    assert profile['conv_app_select'] == ('gpt-5-nano', 'openai')


def test_claude_bridge_profile_routes_memory_pipeline_features():
    # memories/learnings/memory_category/memory_conflict/memory_l1/memory_l2 all parse
    # a plain text reply (PydanticOutputParser, or a bare word for memory_category) —
    # same shape as the conversation-finalize features above, so they work over the
    # bridge unchanged. Without this, memory_l1 (canonical L1 archive extraction)
    # silently no-ops under offline OpenAI (AuthenticationError, swallowed by its caller).
    profile = CLAUDE_BRIDGE_PROFILE
    for feature in (
        'memories',
        'learnings',
        'memory_category',
        'memory_conflict',
        'memory_l1',
        'memory_l2',
    ):
        assert profile[feature] == ('opus', 'claude-bridge')
    # The '_flex' siblings inherit the untouched two-tier default (still 'openai'): they
    # bypass get_llm()/this profile entirely at the call site (utils/memory/promotion_flex.py
    # calls get_or_create_omi_gateway_llm() directly), so rerouting the map entry here
    # would be a no-op for them either way — confirm we didn't accidentally reroute it.
    for flex_feature in ('memory_l2_flex', 'memory_conflict_flex', 'x_memory_extraction_flex'):
        assert profile[flex_feature][1] == 'openai'


def test_claude_bridge_profile_routes_conv_folder():
    # conv_folder (assign_conversation_to_folder) is a single
    # `prompt | get_llm('conv_folder') | folder_parser` chain, same PydanticOutputParser
    # shape as the conversation-finalize features above — works over the bridge unchanged.
    assert CLAUDE_BRIDGE_PROFILE['conv_folder'] == ('opus', 'claude-bridge')


def test_only_chat_responses_gets_bridge_tool_access():
    # The bridge (ask_claude_bridge.py) is a single undifferentiated HTTP endpoint — it
    # can't tell which feature is calling it, so tools_enabled is the only thing that
    # keeps MCP tools out of background/ambient-transcript processing (conv_discard,
    # conv_folder, the memory pipeline, ...). Only the explicit chat channel
    # (chat_responses) may ever get tools_enabled=True.
    assert get_route_options('chat_responses', 'sonnet', 'claude-bridge')['tools_enabled'] is True
    background_bridge_features = (
        'conv_discard',
        'conv_structure',
        'conv_action_items',
        'conv_app_result',
        'conv_folder',
        'memories',
        'learnings',
        'memory_category',
        'memory_conflict',
        'memory_l1',
        'memory_l2',
    )
    for feature in background_bridge_features:
        assert CLAUDE_BRIDGE_PROFILE[feature][1] == 'claude-bridge'
        assert get_route_options(feature, 'sonnet', 'claude-bridge')['tools_enabled'] is False


def test_claude_bridge_profile_leaves_shipped_profiles_untouched():
    assert MODEL_QOS_PROFILES['premium']['chat_responses'] == ('gpt-5.6-luna', 'openai')
    assert MODEL_QOS_PROFILES['max']['chat_responses'] == ('gpt-5.6-luna', 'openai')
    assert MODEL_QOS_PROFILES['byok']['chat_responses'] == ('gpt-5.6-luna', 'openai')


def test_claude_bridge_profile_is_not_in_the_authorized_enumeration():
    # test_omi_qos_tiers.py::test_three_profiles_exist treats MODEL_QOS_PROFILES as the
    # closed {premium, max, byok} set; the private bridge profile must stay out of it.
    assert 'claude_bridge' not in MODEL_QOS_PROFILES


def test_get_default_client_dispatches_claude_bridge_provider(monkeypatch):
    monkeypatch.setenv('CLAUDE_BRIDGE_URL', 'http://mini.local:8766')

    client = get_default_client('sonnet', 'claude-bridge', streaming=False)

    assert isinstance(client, ClaudeBridgeChatModel)
    assert client.model_name == 'sonnet'
    assert client.base_url == 'http://mini.local:8766'
    # No options passed -> safe default, no MCP tool access.
    assert client.tools_enabled is False


def test_get_default_client_passes_tools_enabled_option_through(monkeypatch):
    monkeypatch.setenv('CLAUDE_BRIDGE_URL', 'http://mini.local:8766')

    client = get_default_client('sonnet', 'claude-bridge', streaming=False, options={'tools_enabled': True})

    assert client.tools_enabled is True


def test_get_or_create_claude_bridge_llm_caches_by_model_name(monkeypatch):
    monkeypatch.setenv('CLAUDE_BRIDGE_URL', 'http://mini.local:8766')

    first = get_or_create_claude_bridge_llm('sonnet')
    second = get_or_create_claude_bridge_llm('sonnet')
    different = get_or_create_claude_bridge_llm('opus')

    assert first is second
    assert first is not different


def test_get_or_create_claude_bridge_llm_caches_separately_by_tools_enabled(monkeypatch):
    monkeypatch.setenv('CLAUDE_BRIDGE_URL', 'http://mini.local:8766')

    without_tools = get_or_create_claude_bridge_llm('sonnet', tools_enabled=False)
    with_tools = get_or_create_claude_bridge_llm('sonnet', tools_enabled=True)

    assert without_tools is not with_tools
    assert without_tools.tools_enabled is False
    assert with_tools.tools_enabled is True


def test_bridge_client_honours_a_route_request_timeout():
    """A feature that passes get_llm(request_timeout=...) must bound the bridge call.

    Before this, the bridge factory ignored request_timeout and every route got the
    process-wide 120s deadline — too long for the mentor chain, which runs on the
    live transcript path (see utils/llm/proactive_notification._step_timeout_seconds).
    """
    options = {**get_route_options('proactive_notification', 'sonnet', 'claude-bridge'), 'request_timeout': 45.0}
    client = get_default_client('sonnet', 'claude-bridge', False, options)
    assert isinstance(client, ClaudeBridgeChatModel)
    assert client.timeout_seconds == 45.0

    # A different deadline must not be served from the cached client of the first one.
    other = get_default_client('sonnet', 'claude-bridge', False, {**options, 'request_timeout': 10.0})
    assert other.timeout_seconds == 10.0
    assert client.timeout_seconds == 45.0

    # No request_timeout in the route options -> the process-wide default still applies.
    default_client = get_or_create_claude_bridge_llm('sonnet')
    assert default_client.timeout_seconds == 120.0
