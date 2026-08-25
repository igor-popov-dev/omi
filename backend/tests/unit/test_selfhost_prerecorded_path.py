"""Self-host patch: the pre-recorded transcribe path is overridable by one env var.

Our own engine is a single whisper.cpp-shaped endpoint, so the hosted service`s
two-path layout (/v2/transcribe with a /v1/transcribe fallback) has to collapse
to the one path it actually serves. Without the collapse the first call 404s and
the "fallback" repeats the same 404, which is how offline audio stayed
untranscribable on a self-hosted deployment.
"""

import os

from utils.stt import pre_recorded


def _clear(monkeypatch):
    monkeypatch.delenv(pre_recorded.SELFHOST_PRERECORDED_PATH_ENV, raising=False)


def test_hosted_paths_unchanged_without_override(monkeypatch):
    _clear(monkeypatch)
    assert pre_recorded._prerecorded_transcribe_path(v2=True) == "/v2/transcribe"
    assert pre_recorded._prerecorded_transcribe_path(v2=False) == "/v1/transcribe"


def test_override_collapses_both_paths(monkeypatch):
    monkeypatch.setenv(pre_recorded.SELFHOST_PRERECORDED_PATH_ENV, "/t/secret/inference")
    assert pre_recorded._prerecorded_transcribe_path(v2=True) == "/t/secret/inference"
    assert pre_recorded._prerecorded_transcribe_path(v2=False) == "/t/secret/inference"


def test_override_without_leading_slash_still_joins(monkeypatch):
    monkeypatch.setenv(pre_recorded.SELFHOST_PRERECORDED_PATH_ENV, "inference")
    assert pre_recorded._prerecorded_transcribe_path(v2=True) == "/inference"


def test_blank_override_falls_back_to_hosted_paths(monkeypatch):
    monkeypatch.setenv(pre_recorded.SELFHOST_PRERECORDED_PATH_ENV, "   ")
    assert pre_recorded._prerecorded_transcribe_path(v2=True) == "/v2/transcribe"


def test_base_url_falls_back_to_the_hosted_variable(monkeypatch):
    monkeypatch.delenv(pre_recorded.SELFHOST_PRERECORDED_URL_ENV, raising=False)
    monkeypatch.setenv("HOSTED_PARAKEET_API_URL", "https://parakeet.example")
    assert pre_recorded._prerecorded_api_url() == "https://parakeet.example"


def test_base_url_override_wins_over_the_streaming_endpoint(monkeypatch):
    # The live path pins HOSTED_PARAKEET_API_URL to a WebSocket shim that has no
    # HTTP transcribe route; batch audio sent there 404s and fails the sync job.
    monkeypatch.setenv("HOSTED_PARAKEET_API_URL", "http://127.0.0.1:8771")
    monkeypatch.setenv(pre_recorded.SELFHOST_PRERECORDED_URL_ENV, "http://127.0.0.1:8770")
    assert pre_recorded._prerecorded_api_url() == "http://127.0.0.1:8770"


def test_blank_base_url_override_falls_back(monkeypatch):
    monkeypatch.setenv("HOSTED_PARAKEET_API_URL", "https://parakeet.example")
    monkeypatch.setenv(pre_recorded.SELFHOST_PRERECORDED_URL_ENV, "  ")
    assert pre_recorded._prerecorded_api_url() == "https://parakeet.example"
