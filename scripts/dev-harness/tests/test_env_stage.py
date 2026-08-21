from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from dev_harness import config, safety

REPO_ROOT = Path(__file__).resolve().parents[3]


def test_child_env_for_offline_mode() -> None:
    cfg = config.HarnessConfig(
        repo_root=REPO_ROOT,
        instance="default",
        provider_mode="offline",
        layout=safety.layout_for_instance(REPO_ROOT, "default"),
    )
    child = config.child_env_for(cfg)
    assert child["PROVIDER_MODE"] == "offline"
    assert child["OMI_HARNESS_INSTANCE"] == "default"
    assert child["FIREBASE_API_KEY"] == config.LOCAL_FIREBASE_API_KEY
    assert child["OMI_LLM_GATEWAY_FEATURE_MODE"] == "off"


def test_child_env_for_real_mode() -> None:
    cfg = config.HarnessConfig(
        repo_root=REPO_ROOT,
        instance="default",
        provider_mode="real",
        layout=safety.layout_for_instance(REPO_ROOT, "default"),
    )
    child = config.child_env_for(cfg)
    assert child["PROVIDER_MODE"] == "real"
    assert child["BASE_API_URL"] == cfg.backend_url


def test_model_qos_and_claude_bridge_url_pass_through_when_set(monkeypatch) -> None:
    """MODEL_QOS/CLAUDE_BRIDGE_URL are outside safety._ALLOWED_ENV_KEYS, so the wrapper
    script's export was silently dropped from the child env until _harness_service_extra
    started forwarding them explicitly (mirrors STORAGE_EMULATOR_HOST/HOSTED_SPEAKER_
    EMBEDDING_API_URL above)."""
    monkeypatch.setenv("MODEL_QOS", "claude_bridge")
    monkeypatch.setenv("CLAUDE_BRIDGE_URL", "http://127.0.0.1:8766")
    cfg = config.HarnessConfig(
        repo_root=REPO_ROOT,
        instance="default",
        provider_mode="offline",
        layout=safety.layout_for_instance(REPO_ROOT, "default"),
    )
    child = config.child_env_for(cfg)
    assert child["MODEL_QOS"] == "claude_bridge"
    assert child["CLAUDE_BRIDGE_URL"] == "http://127.0.0.1:8766"


def test_model_qos_and_claude_bridge_url_absent_when_unset(monkeypatch) -> None:
    """Harness instances that never opt into claude-bridge must not see a stray MODEL_QOS=''
    in the child env (model_config.py would log a false 'not a valid profile' warning)."""
    monkeypatch.delenv("MODEL_QOS", raising=False)
    monkeypatch.delenv("CLAUDE_BRIDGE_URL", raising=False)
    cfg = config.HarnessConfig(
        repo_root=REPO_ROOT,
        instance="default",
        provider_mode="offline",
        layout=safety.layout_for_instance(REPO_ROOT, "default"),
    )
    child = config.child_env_for(cfg)
    assert "MODEL_QOS" not in child
    assert "CLAUDE_BRIDGE_URL" not in child


def test_real_gemini_key_passes_through_offline_mode_for_realtime_minting(monkeypatch) -> None:
    """Self-host patch: GEMINI_API_KEY alone survives PROVIDER_MODE=offline so
    /v2/realtime/session can mint real Gemini Live tokens, while every other provider
    (e.g. OPENAI_API_KEY) still gets the offline placeholder."""
    monkeypatch.setenv("GEMINI_API_KEY", "real-gemini-key-not-a-placeholder")
    monkeypatch.setenv("OPENAI_API_KEY", "should-be-ignored-in-offline-mode")
    cfg = config.HarnessConfig(
        repo_root=REPO_ROOT,
        instance="default",
        provider_mode="offline",
        layout=safety.layout_for_instance(REPO_ROOT, "default"),
    )
    child = config.child_env_for(cfg)
    assert child["GEMINI_API_KEY"] == "real-gemini-key-not-a-placeholder"
    assert child["OPENAI_API_KEY"] == "sk-omi-local-harness-offline-not-real"


def test_gemini_key_falls_back_to_offline_placeholder_when_unset(monkeypatch) -> None:
    monkeypatch.delenv("GEMINI_API_KEY", raising=False)
    cfg = config.HarnessConfig(
        repo_root=REPO_ROOT,
        instance="default",
        provider_mode="offline",
        layout=safety.layout_for_instance(REPO_ROOT, "default"),
    )
    child = config.child_env_for(cfg)
    assert child["GEMINI_API_KEY"] == "omi-local-harness-offline-gemini-not-real"


def test_nondefault_port_offset_propagates_to_every_harness_service() -> None:
    cfg = config.load_config(REPO_ROOT, env={"OMI_HARNESS_PORT_OFFSET": "321"})

    assert cfg.firestore_host == "127.0.0.1:8406"
    assert cfg.auth_host == "127.0.0.1:9420"
    assert cfg.redis_port == 6701
    assert cfg.typesense_port == 8429
    assert cfg.backend_url == "http://127.0.0.1:8321"
    assert cfg.desktop_backend_url == "http://127.0.0.1:10522"
    assert cfg.llm_gateway_url == "http://127.0.0.1:9401"
    assert cfg.llm_gateway_service_token == f"{config.LOCAL_LLM_GATEWAY_SERVICE_TOKEN}:{cfg.instance}"

    backend_env = config.child_env_for(cfg)
    desktop_env = config.desktop_backend_child_env_for(cfg)
    assert backend_env["FIRESTORE_EMULATOR_HOST"] == cfg.firestore_host
    assert backend_env["FIREBASE_AUTH_EMULATOR_HOST"] == cfg.auth_host
    assert backend_env["REDIS_DB_PORT"] == "6701"
    assert backend_env["TYPESENSE_HOST_PORT"] == "8429"
    assert backend_env["PORT"] == "8321"
    assert desktop_env["PORT"] == "10522"
    assert backend_env["OMI_LLM_GATEWAY_URL"] == cfg.llm_gateway_url
    assert desktop_env["OMI_LLM_GATEWAY_URL"] == cfg.llm_gateway_url
    assert backend_env["OMI_LLM_GATEWAY_SERVICE_TOKEN"] == cfg.llm_gateway_service_token
    assert desktop_env["OMI_LLM_GATEWAY_SERVICE_TOKEN"] == cfg.llm_gateway_service_token
    assert backend_env["OMI_LLM_GATEWAY_FEATURE_MODE"] == "gateway"
    assert desktop_env["OMI_LLM_GATEWAY_FEATURE_MODE"] == "gateway"


def test_offline_child_env_uses_direct_llm_feature_mode() -> None:
    cfg = config.HarnessConfig(
        repo_root=REPO_ROOT,
        instance="offline-qa",
        provider_mode="offline",
        layout=safety.layout_for_instance(REPO_ROOT, "offline-qa"),
    )
    backend_env = config.child_env_for(cfg)
    desktop_env = config.desktop_backend_child_env_for(cfg)
    assert backend_env["OMI_LLM_GATEWAY_FEATURE_MODE"] == "off"
    assert desktop_env["OMI_LLM_GATEWAY_FEATURE_MODE"] == "off"
    assert desktop_env["OMI_LLM_STUB"] == "1"


def test_llm_gateway_port_override_is_isolated_from_shared_default() -> None:
    cfg = config.load_config(
        REPO_ROOT,
        env={
            "OMI_HARNESS_PORT_OFFSET": "10",
            "OMI_HARNESS_LLM_GATEWAY_PORT": "19080",
            "OMI_LOCAL_INSTANCE": "qa-offset",
        },
    )
    assert cfg.llm_gateway_port == 19080
    assert cfg.llm_gateway_url == "http://127.0.0.1:19080"
    assert cfg.llm_gateway_service_token.endswith(":qa-offset")
    assert config.child_env_for(cfg)["OMI_LLM_GATEWAY_URL"] == "http://127.0.0.1:19080"
