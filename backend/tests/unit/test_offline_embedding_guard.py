"""The offline placeholder OpenAI key must not turn into an outbound request.

Self-host finding (lane7): under PROVIDER_MODE=offline the harness injects a fake
OPENAI_API_KEY so backend modules import cleanly. generate_embedding still built a real
request and shipped the payload — raw conversation text — to api.openai.com, which only
then answered 401. On a self-hosted box that is a data leak dressed up as a failed call.
"""

from types import SimpleNamespace
from unittest.mock import MagicMock

import pytest

import utils.llm.clients as clients

PLACEHOLDER = clients._OFFLINE_PLACEHOLDER_OPENAI_KEY


@pytest.fixture
def spy_embeddings(monkeypatch):
    # The module-level `embeddings` is a proxy with read-only attributes — swap the whole
    # object rather than one method.
    spy = MagicMock(return_value=[[0.1, 0.2, 0.3]])
    monkeypatch.setattr(clients, 'embeddings', SimpleNamespace(embed_documents=spy))
    monkeypatch.setattr(clients, 'get_byok_key', lambda provider: None)
    return spy


def test_offline_placeholder_key_blocks_outbound_embedding(monkeypatch, spy_embeddings):
    monkeypatch.setenv('OPENAI_API_KEY', PLACEHOLDER)

    with pytest.raises(RuntimeError, match='refusing to send content'):
        clients.generate_embedding('приватный текст разговора')

    spy_embeddings.assert_not_called()


def test_real_key_still_embeds(monkeypatch, spy_embeddings):
    monkeypatch.setenv('OPENAI_API_KEY', 'sk-a-real-looking-key')

    assert clients.generate_embedding('hello') == [0.1, 0.2, 0.3]

    spy_embeddings.assert_called_once_with(['hello'])


def test_byok_key_overrides_the_placeholder(monkeypatch, spy_embeddings):
    """A request carrying its own OpenAI key is a real caller — the guard must step aside."""
    monkeypatch.setenv('OPENAI_API_KEY', PLACEHOLDER)
    monkeypatch.setattr(clients, 'get_byok_key', lambda provider: 'sk-byok-from-the-request')

    assert clients.generate_embedding('hello') == [0.1, 0.2, 0.3]

    spy_embeddings.assert_called_once()
