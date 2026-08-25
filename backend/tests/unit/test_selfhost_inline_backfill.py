"""Self-host patch: historical recovery may run inline, without Cloud Tasks.

Upstream fails closed — backfill runs only on the dedicated queue, so a
deployment without Cloud Tasks answers every historical upload with 503
backfill_capacity and the recordings never leave the device. The flag is off by
default, so the hosted deployment keeps failing closed.
"""

from utils.sync import backfill


def test_disabled_by_default(monkeypatch):
    monkeypatch.delenv("OMI_SELFHOST_INLINE_BACKFILL", raising=False)
    assert backfill.selfhost_inline_backfill_enabled() is False


def test_enabled_by_env(monkeypatch):
    monkeypatch.setenv("OMI_SELFHOST_INLINE_BACKFILL", "true")
    assert backfill.selfhost_inline_backfill_enabled() is True


def test_case_insensitive_and_other_values_stay_off(monkeypatch):
    monkeypatch.setenv("OMI_SELFHOST_INLINE_BACKFILL", "TRUE")
    assert backfill.selfhost_inline_backfill_enabled() is True
    monkeypatch.setenv("OMI_SELFHOST_INLINE_BACKFILL", "1")
    assert backfill.selfhost_inline_backfill_enabled() is False
