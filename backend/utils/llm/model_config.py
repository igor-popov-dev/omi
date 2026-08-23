"""Model/profile configuration for backend LLM feature routing.

This module is the source of truth for feature → (model, provider) routing.
Provider-specific client construction lives in ``providers.py``; callers should
continue to use ``clients.get_llm(feature)``.
"""

import logging
import os
from dataclasses import dataclass
from typing import Dict, Tuple, Union

from utils.llm.gateway_client import is_auto_lane_id

logger = logging.getLogger(__name__)


@dataclass(frozen=True)
class ExplicitRouteRef:
    feature: str
    model: str
    provider: str
    options: Dict[str, object]


@dataclass(frozen=True)
class AutoLaneRouteRef:
    feature: str
    lane_id: str


RouteRef = Union[ExplicitRouteRef, AutoLaneRouteRef]

# ---------------------------------------------------------------------------
# Model QoS Profile System
#
# Each profile maps every feature to a (model, provider) tuple.
# The profile is the SINGLE SOURCE OF TRUTH for both model and provider.
# Provider is never inferred from model name — it is declared explicitly.
#
# This means the same model can be hosted by different providers:
#   feature_a: ('gemini-2.5-flash', 'gemini')      → Google direct
#   feature_b: ('gemini-2.5-flash', 'openrouter')   → OpenRouter
#
# Global switch:     MODEL_QOS=premium        (selects entire profile)
#
# Profiles:
#   premium  — maximize cost savings while preserving 80% of max quality
#   max      — 100% quality, best models available, no cost optimization
#   byok     — same models as max (BYOK users pay their own API costs)
# ---------------------------------------------------------------------------

# All QoS profiles deliberately share this two-tier map. Keeping independent
# copies below retains profile selection semantics while preventing a higher
# tier or BYOK route from reintroducing a retired OpenAI text model.
_TWO_TIER_MODEL_PROFILE: Dict[str, Tuple[str, str]] = {
    # OpenAI — default intelligence
    'conv_action_items': ('gpt-5.6-luna', 'openai'),
    'conv_structure': ('gpt-5.6-luna', 'openai'),
    'conv_app_result': ('gpt-5.6-luna', 'openai'),
    'daily_summary': ('gpt-5.6-luna', 'openai'),
    'external_structure': ('gpt-5.6-luna', 'openai'),
    'memories': ('gpt-5.6-luna', 'openai'),
    'x_memory_extraction_flex': ('gpt-5.6-luna', 'openai'),
    'learnings': ('gpt-5.6-luna', 'openai'),
    'memory_conflict': ('gpt-5.6-luna', 'openai'),
    'memory_conflict_flex': ('gpt-5.6-luna', 'openai'),
    'knowledge_graph': ('gpt-5.6-luna', 'openai'),
    'memory_l1': ('gpt-5.6-luna', 'openai'),
    'memory_l2': ('gpt-5.6-luna', 'openai'),
    'memory_l2_flex': ('gpt-5.6-luna', 'openai'),
    'chat_responses': ('gpt-5.6-luna', 'openai'),
    'chat_extraction': ('gpt-5.6-luna', 'openai'),
    'chat_graph': ('gpt-5.6-luna', 'openai'),
    'goals': ('gpt-5.6-luna', 'openai'),
    'goals_advice': ('gpt-5.6-luna', 'openai'),
    'notifications': ('gpt-5.6-luna', 'openai'),
    'proactive_notification': ('gpt-5.6-luna', 'openai'),
    'desktop_proactive_reasoning': ('gpt-5.6-luna', 'openai'),
    'what_matters_now': ('gpt-5.6-luna', 'openai'),
    'openglass': ('gpt-5.6-luna', 'openai'),
    'app_generator': ('gpt-5.6-luna', 'openai'),
    'persona_clone': ('gpt-5.6-luna', 'openai'),
    'persona_chat_premium': ('gpt-5.6-luna', 'openai'),
    # OpenAI — cheapest light/binary work
    'conv_app_select': ('gpt-5-nano', 'openai'),
    'conv_folder': ('gpt-5-nano', 'openai'),
    'conv_discard': ('gpt-5-nano', 'openai'),
    'daily_summary_simple': ('gpt-5-nano', 'openai'),
    'memory_category': ('gpt-5-nano', 'openai'),
    'smart_glasses': ('gpt-5-nano', 'openai'),
    'persona_chat': ('gpt-5-nano', 'openai'),
    'desktop_proactive_extraction': ('gpt-5-nano', 'openai'),
    # Non-OpenAI routes remain intentionally unchanged.
    'session_titles': ('gemini-2.5-flash-lite', 'gemini'),
    'followup': ('gemini-2.5-flash-lite', 'gemini'),
    'onboarding': ('gemini-2.5-flash-lite', 'gemini'),
    'app_integration': ('gemini-2.5-flash-lite', 'gemini'),
    'trends': ('gemini-2.5-flash-lite', 'gemini'),
    'translation': ('gemini-2.5-flash-lite', 'gemini'),
    'chat_agent': ('claude-sonnet-4-6', 'anthropic'),
    'wrapped_analysis': ('gemini-3-flash-preview', 'openrouter'),
    'web_search': ('sonar-pro', 'perplexity'),
}

MODEL_QOS_PROFILES: Dict[str, Dict[str, Tuple[str, str]]] = {
    profile_name: dict(_TWO_TIER_MODEL_PROFILE) for profile_name in ('premium', 'max', 'byok')
}

# Private/self-host profile (PLAN.md §Этап 1): routes plain chat replies through the
# ask_claude_bridge HTTP service instead of a paid API key — reuses an existing Claude
# Code subscription. Opt-in only via MODEL_QOS=claude_bridge; the shipped profiles
# above are untouched. `chat_responses` (qa_rag/qa_rag_stream — the "context text
# already retrieved, ask a question" path) is rerouted; `chat_agent` (tool-calling
# agentic chat) still needs the real Anthropic Messages API and stays on 'anthropic'.
#
# Also rerouted: the four conversation-finalize features that turn a transcript into
# a title/overview/action-items/app-result. All four call get_llm(feature).invoke(...)
# and parse the plain-text reply with a PydanticOutputParser (see discard_parser.py,
# conversation_processing.py) rather than .with_structured_output() — the one method
# ClaudeBridgeChatModel doesn't implement — so they work over the bridge unchanged.
# Without this, self-host conversations under offline OpenAI never leave in_progress
# (conv_discard/conv_structure 401 → BLOCKERS.md, lane6 22.08). `conv_app_select`
# stays on 'openai': it calls .with_structured_output() (conversation_processing.py),
# which the bridge can't serve.
#
# Also rerouted: conv_folder (conversation_folder.py) — same shape again, a single
# `prompt | get_llm('conv_folder') | folder_parser` chain over a PydanticOutputParser,
# no .with_structured_output(). Under offline OpenAI this silently leaves every new
# conversation in the default folder (assign_conversation_to_folder swallows the 401
# into a plain error string, see validate_folder_assignment's fallback path).
#
# Also rerouted: the memory pipeline (memories.py, working_observations.py,
# promotion_routes.py/promotion_proposals.py). Same reasoning as above — every one of
# these six calls get_llm(feature).invoke(...) and parses the plain-text reply with a
# PydanticOutputParser (or, for memory_category, a bare one-word text reply), never
# .with_structured_output(). Without this, memory_l1 (canonical L1 archive extraction —
# the actual "remembers things about you" feature) silently no-ops under offline OpenAI
# (see BLOCKERS.md/lane2-log.md 22.08 ~21:15: `invoke_failed:AuthenticationError`).
# The '_flex' siblings (memory_l2_flex, memory_conflict_flex, x_memory_extraction_flex)
# are deliberately NOT overridden here (they keep the inherited two-tier 'openai'
# default): their call sites route through get_or_create_omi_gateway_llm() directly
# (utils/memory/promotion_flex.py), bypassing get_llm()/this profile entirely, so an
# override here would be a no-op anyway.
#
# Also rerouted (lane7, 23.08): proactive_notification — the mentor's three-step
# gate/generate/critic chain (utils/llm/proactive_notification.py). This one is the
# exception to the "no .with_structured_output() over the bridge" rule stated above:
# all three steps DO call it, so the reroute only became possible once
# ClaudeBridgeChatModel grew a prompt-and-parse with_structured_output()
# (claude_bridge_client.py). Under offline OpenAI the whole feature was dead — every
# ambient conversation hit the gate, got an AuthenticationError, and
# _process_mentor_proactive_notification swallowed it as `gate_failed`, so Igor never
# saw a single proactive notification.
#
# It stays OUT of _BRIDGE_TOOLS_FEATURES on purpose (Igor's 22.08 decision, restated
# for lane7): the proactive layer only *suggests* — it reads the ambient transcript
# and writes a notification, and must never reach an MCP tool. Ambient audio the user
# did not address to the assistant is exactly the input that must not be able to act.

# Deliberately kept OUT of MODEL_QOS_PROFILES: that dict is the authorized
# premium/max/byok enumeration guarded by test_omi_qos_tiers.py (exact key set,
# every profile's OpenAI routes locked to the two-tier map) — this is an
# opt-in-only private variant, not a shipped profile, so it must not be swept
# into those invariant checks.
#
# IMPORTANT — MCP tool access gate (fixed 22.08, see lane2-log.md ~22:xx):
# docs/ask-claude-bridge.md previously documented "the bridge boundary is the
# feature name — only chat_responses ever resolves to provider=='claude-bridge'"
# as the thing that keeps MCP tools out of background/ambient-transcript
# processing. That was true when it was written (13:07) and became FALSE the
# moment conv_discard/conv_folder/the memory pipeline were added below (20:47-
# 21:35) — the bridge is a single undifferentiated HTTP endpoint
# (ask_claude_bridge.py) that can't tell which feature is calling it, so every
# feature routed to 'claude-bridge' got the SAME MCP tool access as
# chat_responses. That silently violated Igor's 22.08 decision ("инструменты —
# только из явного канала команд, фоновая транскрибция — только данные").
# _BRIDGE_TOOLS_FEATURES below is the real gate now: get_route_options() sets
# options['tools_enabled'] from it, threaded through
# providers.get_or_create_claude_bridge_llm() -> ClaudeBridgeChatModel ->
# the /ask payload -> ask_claude_bridge.py's build_claude_cmd(), which only
# attaches --mcp-config/--allowedTools when tools_enabled is True. Every other
# claude-bridge feature (all background transcript/memory postprocessing) gets
# tools_enabled=False — no MCP servers loaded at all for that call.
_BRIDGE_TOOLS_FEATURES = {'chat_responses'}

CLAUDE_BRIDGE_PROFILE: Dict[str, Tuple[str, str]] = {
    **_TWO_TIER_MODEL_PROFILE,
    'chat_responses': ('sonnet', 'claude-bridge'),
    'conv_discard': ('sonnet', 'claude-bridge'),
    # Решение Игоря 23.08: разбор беседы пробуем на Opus — это единственное, что он
    # читает глазами (заголовок и обзор в списке бесед) и по чему судит о качестве.
    # Остальные фичи остаются на Sonnet: они служебные, а Opus заметно быстрее
    # выедает пятичасовое окно подписки, из которого живёт весь self-host.
    'conv_structure': ('opus', 'claude-bridge'),
    'conv_action_items': ('opus', 'claude-bridge'),
    'conv_app_result': ('sonnet', 'claude-bridge'),
    'conv_folder': ('sonnet', 'claude-bridge'),
    'memories': ('sonnet', 'claude-bridge'),
    'learnings': ('sonnet', 'claude-bridge'),
    'memory_category': ('sonnet', 'claude-bridge'),
    'memory_conflict': ('sonnet', 'claude-bridge'),
    'memory_l1': ('sonnet', 'claude-bridge'),
    'memory_l2': ('sonnet', 'claude-bridge'),
    'proactive_notification': ('sonnet', 'claude-bridge'),
}

# Pinned features — (model, provider) fixed regardless of profile or env override.
_PINNED_FEATURES: Dict[str, Tuple[str, str]] = {
    'fair_use': (os.getenv('FAIR_USE_CLASSIFIER_MODEL', 'gpt-5.6-luna').strip() or 'gpt-5.6-luna', 'openai'),
}

# Resolve active profile once at startup.
_active_profile_name = os.environ.get('MODEL_QOS', 'premium').strip().lower()
if _active_profile_name == 'claude_bridge':
    _active_profile = CLAUDE_BRIDGE_PROFILE
elif _active_profile_name not in MODEL_QOS_PROFILES:
    logger.warning('MODEL_QOS=%s is not a valid profile, falling back to premium', _active_profile_name)
    _active_profile_name = 'premium'
    _active_profile = MODEL_QOS_PROFILES[_active_profile_name]
else:
    _active_profile = MODEL_QOS_PROFILES[_active_profile_name]

# BYOK QoS — all BYOK users get routed to 'byok' profile (top-tier all-OpenAI).
# BYOK users pay their own API costs, so we give them maximum quality models.
_byok_profile_name = 'byok'
_byok_profile = MODEL_QOS_PROFILES[_byok_profile_name]

# Features that can't go through get_llm() (non-ChatOpenAI providers).
_ANTHROPIC_ONLY_FEATURES = {'chat_agent'}
_PERPLEXITY_ONLY_FEATURES = {'web_search'}


# Feature-specific client config (temperature, headers — orthogonal to model choice).
# Only applied when a feature resolves to an OpenRouter model.
_OPENROUTER_TEMPERATURES: Dict[str, float] = {
    'wrapped_analysis': 0.7,
}

# Prompt-cache capability detection.
#
# OpenAI prompt caching is a capability of whole model families, not of specific point
# releases. Gating on exact model names silently breaks when a family member changes,
# so we detect by family prefix.
#
#   prompt_cache_key             — prefix-cache request routing. Supported by the gpt-4o,
#                                  gpt-4o, gpt-5.x and o-series families.
#   prompt_cache_retention='24h' — extended (24h) cache retention. Supported by the
#                                  gpt-5.x and o-series families, except gpt-5.6, which
#                                  uses the explicit prompt_cache_options contract instead
#                                  (see supports_cache_retention).
_CACHE_KEY_MODEL_PREFIXES = ('gpt-5', 'gpt-4o', 'o1', 'o3', 'o4')
_CACHE_RETENTION_MODEL_PREFIXES = ('gpt-5', 'o1', 'o3', 'o4')

# Features that call .with_structured_output() — logged when resolving to Gemini for compat monitoring.
_STRUCTURED_OUTPUT_FEATURES = {
    'chat_extraction',
    'proactive_notification',
    'desktop_proactive_extraction',
    'desktop_proactive_reasoning',
    'conv_app_select',
    'external_structure',
    'trends',
    'what_matters_now',
    'translation',
}
STRUCTURED_OUTPUT_FEATURES = _STRUCTURED_OUTPUT_FEATURES

_DEFAULT_CONFIG: Tuple[str, str] = ('gpt-5.6-luna', 'openai')
DEFAULT_CONFIG = _DEFAULT_CONFIG

# Future migration point for features that should call the gateway via an auto
# lane. Keep empty until a ticket explicitly wires and verifies shadow/live
# traffic; existing direct LLM routing never consults this map.
_AUTO_LANE_FEATURES: Dict[str, str] = {}


def _get_model_config(feature: str) -> Tuple[str, str]:
    """Get the (model, provider) tuple for a feature. Internal — used by get_llm/get_model/get_provider.

    Resolution order: pinned > active profile > fallback.
    """
    if feature in _PINNED_FEATURES:
        return _PINNED_FEATURES[feature]
    return _active_profile.get(feature, _DEFAULT_CONFIG)


def get_model_config(feature: str) -> Tuple[str, str]:
    """Get the (model, provider) tuple for a feature.

    Resolution order: pinned > active profile > fallback.
    """
    return _get_model_config(feature)


def get_model(feature: str) -> str:
    """Get the model name for a feature from the active Model QoS profile.

    Resolution order: pinned > active profile > fallback.

    Args:
        feature: Feature name (e.g. 'conv_action_items', 'chat_agent').

    Returns:
        Model name string (e.g. 'gpt-5.6-luna', 'claude-sonnet-4-6').
    """
    return _get_model_config(feature)[0]


def get_provider(feature: str) -> str:
    """Get the provider for a feature from the active Model QoS profile.

    Returns:
        Provider string: 'openai', 'gemini', 'openrouter', 'anthropic', 'perplexity'.
    """
    return _get_model_config(feature)[1]


def get_route_options(feature: str, model: str, provider: str) -> Dict[str, object]:
    """Return provider/model construction options for a resolved route."""

    options: Dict[str, object] = {}
    if supports_cache_retention(model):
        options['extra_body'] = {"prompt_cache_retention": "24h"}
    if provider == 'openrouter':
        temperature = _OPENROUTER_TEMPERATURES.get(feature)
        if temperature is not None:
            options['temperature'] = temperature
    if provider == 'gemini' and not is_structured_output_feature(feature):
        # Structured-output features use .with_structured_output(), which routes through
        # Completions.parse() and rejects thinking_budget (issue #7898).
        options['thinking_budget'] = 0
    if provider == 'claude-bridge':
        options['tools_enabled'] = feature_wants_bridge_tools(feature)
    return options


def get_route_ref(feature: str) -> RouteRef:
    """Return the typed route reference for a feature without changing legacy routing.

    Existing features resolve to explicit provider/model refs by default. Auto-lane
    refs are opt-in through _AUTO_LANE_FEATURES and are not used by get_model(),
    get_provider(), or get_llm().
    """

    lane_id = _AUTO_LANE_FEATURES.get(feature)
    if lane_id is not None:
        if not is_auto_lane_id(lane_id):
            raise ValueError(f"Auto lane route for feature '{feature}' must use omi:auto: namespace")
        return AutoLaneRouteRef(feature=feature, lane_id=lane_id)

    model, provider = _get_model_config(feature)
    return ExplicitRouteRef(
        feature=feature,
        model=model,
        provider=provider,
        options=get_route_options(feature, model, provider),
    )


def supports_prompt_cache(model: str) -> bool:
    """Whether a model supports OpenAI prompt-cache routing (prompt_cache_key)."""
    return bool(model) and model.startswith(_CACHE_KEY_MODEL_PREFIXES)


def supports_cache_retention(model: str) -> bool:
    """Whether a model supports 24h OpenAI prompt-cache retention (prompt_cache_retention='24h')."""
    # GPT-5.6 uses the explicit cache contract (prompt_cache_options + a
    # breakpoint) rather than the legacy prompt_cache_retention field. Sending
    # both contracts in the same request is rejected by the provider.
    return bool(model) and not model.startswith('gpt-5.6') and model.startswith(_CACHE_RETENTION_MODEL_PREFIXES)


def feature_wants_bridge_tools(feature: str) -> bool:
    """Whether this feature is allowed MCP tool access when routed over claude-bridge.

    Only the explicit chat channel (chat_responses) qualifies — every other
    claude-bridge feature is background/ambient transcript processing and must
    stay tool-free. See the comment above CLAUDE_BRIDGE_PROFILE.
    """
    return feature in _BRIDGE_TOOLS_FEATURES


def is_structured_output_feature(feature: str) -> bool:
    return feature in _STRUCTURED_OUTPUT_FEATURES


def is_anthropic_only_feature(feature: str) -> bool:
    return feature in _ANTHROPIC_ONLY_FEATURES


def is_perplexity_only_feature(feature: str) -> bool:
    return feature in _PERPLEXITY_ONLY_FEATURES


def get_active_profile_name() -> str:
    return _active_profile_name


def get_active_profile() -> Dict[str, Tuple[str, str]]:
    return _active_profile


def get_all_configured_features() -> set[str]:
    return set(_active_profile.keys()) | set(_PINNED_FEATURES.keys())


def get_default_config() -> Tuple[str, str]:
    return _DEFAULT_CONFIG


def get_byok_profile() -> Dict[str, Tuple[str, str]]:
    return _byok_profile


def get_byok_profile_name() -> str:
    return _byok_profile_name


def get_openrouter_temperatures() -> Dict[str, float]:
    return _OPENROUTER_TEMPERATURES


def get_pinned_features() -> Dict[str, Tuple[str, str]]:
    return _PINNED_FEATURES


def get_anthropic_only_features() -> set[str]:
    return _ANTHROPIC_ONLY_FEATURES


def get_perplexity_only_features() -> set[str]:
    return _PERPLEXITY_ONLY_FEATURES
