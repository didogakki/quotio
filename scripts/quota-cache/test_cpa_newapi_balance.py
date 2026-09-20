"""Unit tests for `cpa_newapi_balance.collect_pool`'s quota-cache integration.
Stdlib `unittest` only — `quota_cache_client.fetch` is monkeypatched so
nothing here ever makes a real network request, and the weighting formulas
(`bounded_integer_weights`, `assign_account_weights`, `target_channel_weights`)
are never touched by these tests, matching the constraint that this task must
leave them byte-for-byte unchanged.
"""

from __future__ import annotations

import unittest
from unittest.mock import patch

import quota_cache_client
from cpa_newapi_balance import collect_pool, reset_seconds


class FakeManagementClient:
    def __init__(self, files):
        self.files = files

    def list_auth_files(self):
        return list(self.files)


class FakeQR:
    CODEX_USAGE_URL = "https://example.com/usage"

    def __init__(self, client):
        self._client = client

    def read_management_key(self, path, key):
        return "mgmt-key"

    def ManagementClient(self, base_url, management_key, timeout):  # noqa: N802
        return self._client

    @staticmethod
    def account_provider(entry):
        return str(entry.get("provider") or "").strip().lower()


def _entry(auth_index, name=None, disabled=False):
    return {"auth_index": auth_index, "name": name or f"{auth_index}.json", "provider": "codex", "disabled": disabled}


def _pool_config(cache_base_url=None):
    pool = {"name": "plus", "base_url": "https://cpa.example.com", "secrets_env": "/dev/null"}
    if cache_base_url:
        pool["quota_cache_base_url"] = cache_base_url
    return pool


class CacheEnabledAbortsRoundTests(unittest.TestCase):
    def test_a_quota_cache_error_for_one_account_aborts_the_whole_round(self):
        client = FakeManagementClient([_entry("a"), _entry("b")])
        qr = FakeQR(client)
        pool = _pool_config(cache_base_url="http://127.0.0.1:8328/quota-cache/v1/plus")

        def fake_fetch(*args, **kwargs):
            raise quota_cache_client.QuotaCacheError("upstream_unavailable")

        with patch.object(quota_cache_client, "fetch", side_effect=fake_fetch):
            with self.assertRaises(RuntimeError):
                collect_pool(qr, pool, {}, {}, timeout=5, now=1_700_000_000)

    def test_an_unusable_cached_reading_aborts_the_whole_round_rather_than_excluding_the_account(self):
        client = FakeManagementClient([_entry("a")])
        qr = FakeQR(client)
        pool = _pool_config(cache_base_url="http://127.0.0.1:8328/quota-cache/v1/plus")

        def fake_fetch(*args, **kwargs):
            return {"result": {"status_code": 200, "header": {}, "body": "{}"}, "fetched_at": 1_700_000_000, "stale": False}

        with patch.object(quota_cache_client, "fetch", side_effect=fake_fetch):
            with self.assertRaises(RuntimeError):
                collect_pool(qr, pool, {}, {}, timeout=5, now=1_700_000_000)

    def test_a_successful_cached_reading_for_every_account_produces_normal_metrics(self):
        client = FakeManagementClient([_entry("a")])
        qr = FakeQR(client)
        pool = _pool_config(cache_base_url="http://127.0.0.1:8328/quota-cache/v1/plus")
        body = '{"rate_limit":{"limit_reached":false,"allowed":true,"primary_window":{"used_percent":20,"reset_after_seconds":3600}}}'

        def fake_fetch(*args, **kwargs):
            return {
                "result": {"status_code": 200, "header": {}, "body": body},
                "fetched_at": 1_700_000_000, "stale": False,
            }

        with patch.object(quota_cache_client, "fetch", side_effect=fake_fetch):
            metrics = collect_pool(qr, pool, {}, {}, timeout=5, now=1_700_000_000)

        self.assertEqual(metrics.valid_accounts, 1)
        self.assertEqual(metrics.invalid_accounts, 0)


class CachePathAnchorsResetToEnvelopeFetchedAtTests(unittest.TestCase):
    def test_a_cache_hit_served_well_after_the_original_fetch_anchors_reset_after_seconds_to_fetched_at_not_now(self):
        client = FakeManagementClient([_entry("a")])
        qr = FakeQR(client)
        pool = _pool_config(cache_base_url="http://127.0.0.1:8328/quota-cache/v1/plus")
        # The upstream reading was originally fetched at 1_700_000_000 with a
        # five-hour window 3600s from its own reset; this round's call
        # happens 1000s later than that fetch (a fresh TTL/window-bound cache
        # hit serving the same body without any new upstream call).
        body = '{"rate_limit":{"limit_reached":false,"allowed":true,"primary_window":{"used_percent":20,"reset_after_seconds":3600}}}'

        def fake_fetch(*args, **kwargs):
            return {
                "result": {"status_code": 200, "header": {}, "body": body},
                "fetched_at": 1_700_000_000, "stale": False,
            }

        with patch.object(quota_cache_client, "fetch", side_effect=fake_fetch):
            metrics = collect_pool(qr, pool, {}, {}, timeout=5, now=1_700_001_000)

        account = metrics.accounts[0]
        # Anchored to fetched_at: absolute reset = 1_700_000_000 + 3600 =
        # 1_700_003_600; remaining as of now (1_700_001_000) = 2600s — not the
        # raw 3600s the upstream body reported, which would double-count the
        # 1000s that already elapsed since the real fetch.
        self.assertEqual(account.reset_at, 1_700_003_600)
        self.assertEqual(account.reset_after_seconds, 2600)


class DirectPathKeepsLenientBehaviorTests(unittest.TestCase):
    def test_without_a_cache_base_url_a_failed_account_is_still_only_counted_invalid_not_aborted(self):
        class FailingClient(FakeManagementClient):
            def api_call(self, auth_index, method, url, header):
                raise RuntimeError("upstream down")

        client = FailingClient([_entry("a"), _entry("b")])
        qr = FakeQR(client)
        pool = _pool_config(cache_base_url=None)

        with self.assertRaises(RuntimeError) as ctx:
            collect_pool(qr, pool, {}, {}, timeout=5, now=1_700_000_000)
        # Both accounts fail -> "no valid observations", not the cache-path
        # abort message — proving the lenient per-account path ran, not the
        # cache-enabled abort-the-round path.
        self.assertIn("no valid Codex quota observations", str(ctx.exception))


class ResetSecondsAnchoringTests(unittest.TestCase):
    """Direct coverage of `reset_seconds`'s anchoring rules: absolute `reset_at`
    always wins when present, and a relative `reset_after_seconds` is
    anchored to `fetched_at` (when this window's data was actually fetched),
    never to `now` (whenever this call happens to run)."""

    def test_absolute_reset_at_wins_over_relative_reset_after_seconds(self):
        window = {"reset_at": 1_700_010_000, "reset_after_seconds": 999}
        remaining, reset_at = reset_seconds(window, now=1_700_000_000, fetched_at=1_700_000_000, fallback_seconds=999_999)
        self.assertEqual(reset_at, 1_700_010_000)
        self.assertEqual(remaining, 10_000)

    def test_relative_countdown_shrinks_correctly_as_now_advances_past_fetched_at(self):
        window = {"reset_after_seconds": 18_000}
        fetched_at = 1_700_000_000
        remaining_at_fetch, reset_at_first = reset_seconds(
            window, now=fetched_at, fetched_at=fetched_at, fallback_seconds=999_999)
        remaining_later, reset_at_second = reset_seconds(
            window, now=fetched_at + 3_600, fetched_at=fetched_at, fallback_seconds=999_999)

        # Reading the same still-cached body 3600s later must not move the
        # absolute reset point this window implies...
        self.assertEqual(reset_at_first, reset_at_second)
        self.assertEqual(reset_at_first, fetched_at + 18_000)
        # ...but the *remaining* time must shrink by exactly the elapsed
        # time, matching real elapsed wall-clock time rather than being
        # extended just because the cache happened to be read again.
        self.assertEqual(remaining_at_fetch, 18_000)
        self.assertEqual(remaining_later, 18_000 - 3_600)

    def test_anchoring_to_now_instead_of_fetched_at_would_have_wrongly_extended_the_reset(self):
        # Regression guard for the exact bug this fixes: a caller that
        # (incorrectly) anchored the relative countdown to `now` would
        # recompute a *later* absolute reset point on every subsequent read
        # of the same cached body, instead of counting down towards a fixed
        # point.
        window = {"reset_after_seconds": 18_000}
        fetched_at = 1_700_000_000
        _, reset_at_first = reset_seconds(window, now=fetched_at, fetched_at=fetched_at, fallback_seconds=999_999)
        _, reset_at_second = reset_seconds(
            window, now=fetched_at + 3_600, fetched_at=fetched_at, fallback_seconds=999_999)
        wrongly_anchored_to_now = (fetched_at + 3_600) + 18_000
        self.assertNotEqual(reset_at_second, wrongly_anchored_to_now)
        self.assertEqual(reset_at_second, reset_at_first)

    def test_falls_back_to_fallback_seconds_when_neither_signal_is_present(self):
        remaining, reset_at = reset_seconds({}, now=1_700_000_000, fetched_at=1_700_000_000, fallback_seconds=600)
        self.assertEqual(remaining, 600)
        self.assertEqual(reset_at, 1_700_000_600)

    def test_falls_back_when_the_relative_countdown_has_already_elapsed_by_now(self):
        window = {"reset_after_seconds": 100}
        remaining, reset_at = reset_seconds(
            window, now=1_700_000_500, fetched_at=1_700_000_000, fallback_seconds=600)
        self.assertEqual(remaining, 600)
        self.assertEqual(reset_at, 1_700_000_500 + 600)


if __name__ == "__main__":
    unittest.main()
