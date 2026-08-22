"""Voximplant flavour of the phone-call provider (private fork feature).

Twilio hands the client a short-lived AccessToken; Voximplant has no such thing. Its SDK
logs in either with the application user's permanent password — which must never reach the
app — or with a one-time key: the client asks the platform for a key, sends it to us, and we
answer with ``md5(key + "|" + md5(user + ":voximplant.com:" + password))``. Only the inner
md5 is stored here, so the password itself never lives on the server either.

Two traps that cost an hour each on the first login (both verified against Voximplant's own
reference app and their docs example, see ``marathon/tools/vox-onetime-key.py --self-test``):

* the user name is spelled differently in the two places — the SDK asks for the key and logs
  in with the FULL name (``user@application.account.voximplant.com``), while the hash is built
  from the SHORT one;
* the key lives 5 minutes and dies if the same account requests a key from another device, so
  the client must call this right before dialling, not at startup.
"""

import hashlib
import os
import re
from typing import List, Optional

# Voximplant's one-time key lifetime; ours to report, not to enforce.
ONE_TIME_KEY_TTL_SECONDS = 300

# The key is a hex blob today, but the platform never promised a shape — keep the guard wide
# enough to survive a change and narrow enough to keep junk out of the hash input.
ONE_TIME_KEY_PATTERN = re.compile(r'^[A-Za-z0-9._~-]{8,256}$')

_NODE_PATTERN = re.compile(r'^(?:VINode\.)?[Nn]ode(\d{1,2})$|^(\d{1,2})$')


def _env(name: str) -> Optional[str]:
    # Read lazily rather than at import: the process loads .env after some modules are already
    # imported, and tests flip these with monkeypatch.
    value = os.getenv(name)
    return value.strip() if value else None


def is_selected() -> bool:
    """True when this deployment dials through Voximplant instead of Twilio."""
    return (_env('PHONE_CALL_PROVIDER') or 'twilio').lower() == 'voximplant'


def missing_settings() -> List[str]:
    """Which environment variables still have to be filled in before a call can be placed."""
    missing = [name for name in ('VOX_NODE', 'VOX_APP_USER', 'VOX_APP_USER_MD5') if not _env(name)]
    user = _env('VOX_APP_USER')
    if user and '@' not in user:
        missing += [name for name in ('VOX_APPLICATION', 'VOX_ACCOUNT_NAME') if not _env(name)]
    return missing


def full_user_name() -> str:
    """``user@application.account.voximplant.com`` — what the SDK logs in with.

    ``VOX_APP_USER`` may hold the full name already (that is how the console shows it); a bare
    name is composed with the application and account names.
    """
    user = _env('VOX_APP_USER') or ''
    if '@' in user:
        return user
    application = _env('VOX_APPLICATION') or ''
    account = _env('VOX_ACCOUNT_NAME') or ''
    return f'{user}@{application}.{account}.voximplant.com'


def short_user_name() -> str:
    """The bare user name — the one that goes INSIDE the hash, never into the login call."""
    return (_env('VOX_APP_USER') or '').split('@', 1)[0]


def node() -> str:
    """Media node of the account, normalised to ``NodeN``.

    The console prints it as ``VINode.Node4``, the Flutter plugin wants an enum member; the
    client picks the enum by this suffix, so accept every spelling instead of making the
    deployment guess which one we meant.
    """
    raw = _env('VOX_NODE') or ''
    match = _NODE_PATTERN.match(raw)
    if not match:
        raise ValueError(f'VOX_NODE is not a node number: {raw!r} (expected e.g. VINode.Node4)')
    return f'Node{match.group(1) or match.group(2)}'


def build_login_hash(one_time_key: str) -> str:
    """Answer for ``VIClient.loginWithOneTimeKey``: md5(key + '|' + md5(user:voximplant.com:password))."""
    inner = _env('VOX_APP_USER_MD5')
    if not inner:
        raise ValueError('VOX_APP_USER_MD5 must be set')
    return hashlib.md5(f'{one_time_key}|{inner}'.encode()).hexdigest()


def user_md5(short_user: str, password: str) -> str:
    """The inner hash — the only Voximplant credential the server has to keep."""
    return hashlib.md5(f'{short_user}:voximplant.com:{password}'.encode()).hexdigest()
