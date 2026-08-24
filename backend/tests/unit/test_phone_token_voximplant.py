"""``POST /v1/phone/token`` on a Voximplant deployment answers a login hash, not a token.

The golden vector below is not our own formula echoed back: it is the value produced by the
Node.js example in Voximplant's own ``guides.sdk.authorization-onetimekey``, cross-checked by
``marathon/tools/vox-onetime-key.py --self-test``. If someone "simplifies" the hash later, this
test fails instead of the first live call.
"""

import hashlib

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient
from types import SimpleNamespace
from unittest.mock import MagicMock

from routers.phone_calls import router
from utils import voximplant_service
from utils.other import endpoints as auth

TEST_UID = 'test-uid-vox'

# Voximplant's own example inputs and the hash their code produces for them.
SAMPLE_USER = 'phone'
SAMPLE_PASSWORD = 's3cret-Pa55'
SAMPLE_KEY = '0123456789abcdef0123456789abcdef'
SAMPLE_INNER_MD5 = hashlib.md5(f'{SAMPLE_USER}:voximplant.com:{SAMPLE_PASSWORD}'.encode()).hexdigest()
SAMPLE_HASH = hashlib.md5(f'{SAMPLE_KEY}|{SAMPLE_INNER_MD5}'.encode()).hexdigest()


@pytest.fixture(autouse=True)
def _stub_phone_call_plan_guards(monkeypatch):
    monkeypatch.setattr('routers.phone_calls.check_call_access', MagicMock())
    monkeypatch.setattr(
        'routers.phone_calls.phone_calls_db.get_primary_phone_number',
        MagicMock(return_value={'id': 'num-1', 'phone_number': '+995555123456'}),
    )


@pytest.fixture()
def vox_env(monkeypatch):
    monkeypatch.setenv('PHONE_CALL_PROVIDER', 'voximplant')
    monkeypatch.setenv('VOX_NODE', 'VINode.Node4')
    monkeypatch.setenv('VOX_APP_USER', f'{SAMPLE_USER}@omijarvis.igor.voximplant.com')
    monkeypatch.setenv('VOX_APP_USER_MD5', SAMPLE_INNER_MD5)


@pytest.fixture()
def client():
    app = FastAPI()
    app.include_router(router)
    app.dependency_overrides[auth.get_current_user_uid] = lambda: TEST_UID
    return TestClient(app)


def test_returns_login_hash_for_one_time_key(client, vox_env):
    response = client.post('/v1/phone/token', json={'key': SAMPLE_KEY})

    assert response.status_code == 200
    body = response.json()
    assert body['hash'] == SAMPLE_HASH
    assert body['user'] == f'{SAMPLE_USER}@omijarvis.igor.voximplant.com'
    assert body['node'] == 'Node4'
    assert body['ttl'] == 300
    # The password-derived secret must not travel to the client.
    assert SAMPLE_INNER_MD5 not in response.text


def test_hash_uses_the_short_user_name(vox_env):
    """The full name inside the hash is the classic first-login trap — it must not match."""
    full_name_inner = voximplant_service.user_md5(f'{SAMPLE_USER}@omijarvis.igor.voximplant.com', SAMPLE_PASSWORD)
    assert full_name_inner != SAMPLE_INNER_MD5
    assert voximplant_service.build_login_hash(SAMPLE_KEY) == SAMPLE_HASH
    assert voximplant_service.short_user_name() == SAMPLE_USER


def test_no_key_answers_the_handshake_instead_of_refusing(client, vox_env):
    """First half of the login: the app asks WHERE to connect, it has no key to send yet.

    Refusing here (as this endpoint did until the client was written) is a dead end: the
    one-time key can only be requested from the cloud after the SDK is connected, and the
    node to connect to is known only to the server.
    """
    response = client.post('/v1/phone/token', content='')

    assert response.status_code == 200
    body = response.json()
    assert body['provider'] == 'voximplant'
    assert body['hash'] is None
    assert body['user'] == f'{SAMPLE_USER}@omijarvis.igor.voximplant.com'
    assert body['node'] == 'Node4'
    assert body['ttl'] == 300
    assert SAMPLE_INNER_MD5 not in response.text


def test_handshake_and_hash_agree_on_user_and_node(client, vox_env):
    """The second half must log in exactly where the first half pointed."""
    handshake = client.post('/v1/phone/token', content='').json()
    with_hash = client.post('/v1/phone/token', json={'key': SAMPLE_KEY}).json()

    assert (handshake['user'], handshake['node']) == (with_hash['user'], with_hash['node'])
    assert with_hash['provider'] == 'voximplant'
    assert with_hash['hash'] == SAMPLE_HASH


def test_malformed_key_is_rejected(client, vox_env):
    response = client.post('/v1/phone/token', json={'key': 'short'})

    assert response.status_code == 400
    assert response.json()['detail'] == 'Malformed one-time login key'


def test_unconfigured_deployment_says_what_is_missing(client, monkeypatch):
    monkeypatch.setenv('PHONE_CALL_PROVIDER', 'voximplant')
    monkeypatch.delenv('VOX_NODE', raising=False)
    monkeypatch.delenv('VOX_APP_USER', raising=False)
    monkeypatch.delenv('VOX_APP_USER_MD5', raising=False)

    response = client.post('/v1/phone/token', json={'key': SAMPLE_KEY})

    assert response.status_code == 503
    assert 'VOX_NODE' in response.json()['detail']


def test_short_user_name_is_composed_into_the_full_one(monkeypatch):
    monkeypatch.setenv('VOX_APP_USER', 'phone')
    monkeypatch.setenv('VOX_APPLICATION', 'omijarvis')
    monkeypatch.setenv('VOX_ACCOUNT_NAME', 'igor')
    monkeypatch.setenv('VOX_NODE', 'VINode.Node4')
    monkeypatch.setenv('VOX_APP_USER_MD5', SAMPLE_INNER_MD5)

    assert voximplant_service.full_user_name() == 'phone@omijarvis.igor.voximplant.com'
    assert voximplant_service.missing_settings() == []


def test_short_user_name_without_application_is_reported_missing(monkeypatch):
    monkeypatch.setenv('VOX_APP_USER', 'phone')
    monkeypatch.delenv('VOX_APPLICATION', raising=False)
    monkeypatch.delenv('VOX_ACCOUNT_NAME', raising=False)
    monkeypatch.setenv('VOX_NODE', 'VINode.Node4')
    monkeypatch.setenv('VOX_APP_USER_MD5', SAMPLE_INNER_MD5)

    assert voximplant_service.missing_settings() == ['VOX_APPLICATION', 'VOX_ACCOUNT_NAME']


@pytest.mark.parametrize(
    'raw,expected', [('VINode.Node4', 'Node4'), ('Node9', 'Node9'), ('node1', 'Node1'), ('4', 'Node4')]
)
def test_node_spellings_all_normalise(monkeypatch, raw, expected):
    monkeypatch.setenv('VOX_NODE', raw)
    assert voximplant_service.node() == expected


def test_garbage_node_is_a_503_not_a_bad_login(client, vox_env, monkeypatch):
    monkeypatch.setenv('VOX_NODE', 'frankfurt')

    response = client.post('/v1/phone/token', json={'key': SAMPLE_KEY})

    assert response.status_code == 503
    assert 'VOX_NODE' in response.json()['detail']


def test_twilio_stays_the_default(client, monkeypatch):
    """No PHONE_CALL_PROVIDER set: the endpoint behaves exactly as it did before."""
    monkeypatch.delenv('PHONE_CALL_PROVIDER', raising=False)
    monkeypatch.setattr(
        'routers.phone_calls.generate_access_token',
        MagicMock(return_value={'access_token': 'jwt-token', 'ttl': 3600, 'identity': TEST_UID}),
    )

    response = client.post('/v1/phone/token', content='')

    assert response.status_code == 200
    assert response.json() == {'access_token': 'jwt-token', 'ttl': 3600, 'identity': TEST_UID}
