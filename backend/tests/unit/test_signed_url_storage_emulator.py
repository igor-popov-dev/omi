"""_get_signed_url must hand back a direct emulator URL under STORAGE_EMULATOR_HOST.

V4 signing (blob.generate_signed_url) always resolves to storage.googleapis.com and
requires a real service-account private key; against fake-gcs-server (self-host
deployment, see marathon/deploy/ai.omi-jarvis.fake-gcs.mini.plist) that host is
unreachable even when ADC creds happen to be able to sign, so profile screens 500
without this fallback.
"""

from unittest.mock import MagicMock

import pytest

from utils.other import storage as storage_mod


@pytest.fixture(autouse=True)
def _mock_storage_client(monkeypatch):
    monkeypatch.setattr(storage_mod, 'storage_client', MagicMock())


@pytest.fixture(autouse=True)
def _no_redis_cache(monkeypatch):
    """_get_signed_url reads/writes a Redis-backed cache; keep it inert per test."""
    monkeypatch.setattr(storage_mod, 'get_cached_signed_url', lambda _blob_path: '')
    monkeypatch.setattr(storage_mod, 'cache_signed_url', lambda *_args, **_kwargs: None)


def _fake_blob(name: str, bucket_name: str = 'speech-profiles'):
    blob = MagicMock()
    blob.name = name
    blob.bucket.name = bucket_name
    blob.generate_signed_url.side_effect = AssertionError('must not attempt real V4 signing against an emulator')
    return blob


def test_returns_direct_emulator_url_when_storage_emulator_host_set(monkeypatch):
    monkeypatch.setenv('STORAGE_EMULATOR_HOST', 'http://127.0.0.1:4443')
    blob = _fake_blob('users/local-dev-user/speech_profile.wav')

    url = storage_mod._get_signed_url(blob, 60)

    assert (
        url
        == 'http://127.0.0.1:4443/storage/v1/b/speech-profiles/o/users%2Flocal-dev-user%2Fspeech_profile.wav?alt=media'
    )
    blob.generate_signed_url.assert_not_called()


def test_falls_back_to_v4_signing_without_storage_emulator_host(monkeypatch):
    monkeypatch.delenv('STORAGE_EMULATOR_HOST', raising=False)
    blob = _fake_blob('users/real-user/speech_profile.wav')
    blob.generate_signed_url.side_effect = None
    blob.generate_signed_url.return_value = 'https://storage.googleapis.com/signed-url'

    url = storage_mod._get_signed_url(blob, 60)

    assert url == 'https://storage.googleapis.com/signed-url'
    blob.generate_signed_url.assert_called_once()
