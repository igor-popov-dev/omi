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
from utils.llm.model_config import CLAUDE_BRIDGE_PROFILE, MODEL_QOS_PROFILES
from utils.llm.providers import get_default_client, get_or_create_claude_bridge_llm


def test_claude_bridge_profile_routes_chat_responses_only():
    profile = CLAUDE_BRIDGE_PROFILE
    assert profile['chat_responses'] == ('sonnet', 'claude-bridge')
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
        assert profile[feature] == ('sonnet', 'claude-bridge')
    # conv_app_select calls .with_structured_output() — the bridge can't serve that,
    # so it must stay on its two-tier default.
    assert profile['conv_app_select'] == ('gpt-5-nano', 'openai')


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


def test_get_or_create_claude_bridge_llm_caches_by_model_name(monkeypatch):
    monkeypatch.setenv('CLAUDE_BRIDGE_URL', 'http://mini.local:8766')

    first = get_or_create_claude_bridge_llm('sonnet')
    second = get_or_create_claude_bridge_llm('sonnet')
    different = get_or_create_claude_bridge_llm('opus')

    assert first is second
    assert first is not different
