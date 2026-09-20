"""Unit tests for `AuthFileResolver`. Stdlib `unittest` only, no real network
access — every test injects a fake management client."""

from __future__ import annotations

import threading
import time
import unittest

from auth_files import AuthFileResolver


class FakeManagementClient:
    def __init__(self, files=None, fail=False):
        self.files = files or []
        self.fail = fail
        self.call_count = 0
        self._lock = threading.Lock()
        self.block_calls = False
        self.call_started = threading.Event()
        self.release_event = threading.Event()

    def list_auth_files(self):
        with self._lock:
            self.call_count += 1
        if self.block_calls:
            self.call_started.set()
            self.release_event.wait(timeout=5)
        if self.fail:
            raise RuntimeError("listing failed")
        return list(self.files)


def _entry(auth_index, id=None, name=None, account=None, email=None, disabled=False, provider="claude"):
    return {
        "auth_index": auth_index,
        "id": id,
        "name": name,
        "account": account,
        "email": email,
        "disabled": disabled,
        "provider": provider,
    }


class ResolveBasicsTests(unittest.TestCase):
    def test_resolves_a_known_account(self):
        client = FakeManagementClient([_entry("a", id="1", name="a.json")])
        resolver = AuthFileResolver(client, ttl_seconds=5)

        account = resolver.resolve("a", now=1_000.0)

        self.assertIsNotNone(account)
        self.assertEqual(account.auth_index, "a")
        self.assertFalse(account.disabled)

    def test_unknown_auth_index_resolves_to_none(self):
        client = FakeManagementClient([_entry("a", id="1", name="a.json")])
        resolver = AuthFileResolver(client, ttl_seconds=5)

        self.assertIsNone(resolver.resolve("no-such-index", now=1_000.0))

    def test_entry_with_no_stable_identifier_at_all_is_conservatively_dropped(self):
        client = FakeManagementClient([{"auth_index": "a", "disabled": False}])
        resolver = AuthFileResolver(client, ttl_seconds=5)

        self.assertIsNone(
            resolver.resolve("a", now=1_000.0),
            "an entry with neither id/name nor account/email must never resolve",
        )


class SameNameReplacementTests(unittest.TestCase):
    def test_a_different_real_account_reusing_the_same_file_id_and_name_gets_a_different_identity(self):
        client = FakeManagementClient([_entry("a", id="1", name="codex-a.json", account="acct-old")])
        resolver = AuthFileResolver(client, ttl_seconds=5)
        first = resolver.resolve("a", now=1_000.0)

        # CPA reuses the exact same auth-file id/name slot for a newly-added,
        # genuinely different account.
        client.files = [_entry("a", id="1", name="codex-a.json", account="acct-new")]
        second = resolver.resolve("a", now=1_000.0, force_refresh=True)

        self.assertNotEqual(
            first.identity, second.identity,
            "identity must change when the same id/name slot now points at a different account",
        )

    def test_a_token_refresh_of_the_same_account_keeps_the_same_identity(self):
        # Regression guard: identity must be stable across ordinary metadata
        # churn (a token refresh), not just across account/email — folding in
        # something like an updated-at timestamp would defeat caching entirely.
        client = FakeManagementClient([_entry("a", id="1", name="codex-a.json", account="acct-1", email="user@example.com")])
        resolver = AuthFileResolver(client, ttl_seconds=5)
        first = resolver.resolve("a", now=1_000.0)

        second = resolver.resolve("a", now=1_000.0, force_refresh=True)

        self.assertEqual(first.identity, second.identity)


class DisabledMidFlightTests(unittest.TestCase):
    def test_force_refresh_observes_a_disabled_flag_that_changed_since_the_last_ttl_window(self):
        client = FakeManagementClient([_entry("a", id="1", name="a.json", disabled=False)])
        resolver = AuthFileResolver(client, ttl_seconds=100)
        first = resolver.resolve("a", now=1_000.0)
        self.assertFalse(first.disabled)

        client.files = [_entry("a", id="1", name="a.json", disabled=True)]
        # A plain resolve() would still be within the (huge) TTL window and
        # would never see this; force_refresh must bypass that.
        stale = resolver.resolve("a", now=1_000.5)
        self.assertFalse(stale.disabled, "sanity check: the TTL window really is still open")

        forced = resolver.resolve("a", now=1_000.5, force_refresh=True)
        self.assertTrue(forced.disabled)


class ListingFailureTests(unittest.TestCase):
    def test_a_transient_listing_failure_keeps_serving_the_last_known_mapping(self):
        client = FakeManagementClient([_entry("a", id="1", name="a.json")])
        resolver = AuthFileResolver(client, ttl_seconds=1, max_stale_seconds=100)
        resolver.resolve("a", now=1_000.0)

        client.fail = True
        account = resolver.resolve("a", now=1_005.0)  # past the 1s ttl, still within max_stale

        self.assertIsNotNone(account, "a short listing failure must not immediately blank the mapping")

    def test_a_listing_failure_beyond_max_stale_seconds_fails_closed(self):
        client = FakeManagementClient([_entry("a", id="1", name="a.json")])
        resolver = AuthFileResolver(client, ttl_seconds=1, max_stale_seconds=10)
        resolver.resolve("a", now=1_000.0)

        client.fail = True
        account = resolver.resolve("a", now=1_020.0)  # well past max_stale_seconds

        self.assertIsNone(account, "a mapping that has been failing to refresh for too long must fail closed")

    def test_listing_never_wipes_the_mapping_to_empty_just_because_it_failed_once(self):
        client = FakeManagementClient([_entry("a", id="1", name="a.json")])
        resolver = AuthFileResolver(client, ttl_seconds=1, max_stale_seconds=100)
        before = resolver.resolve("a", now=1_000.0)
        self.assertIsNotNone(before)

        client.fail = True
        after = resolver.resolve("a", now=1_002.0)

        self.assertEqual(before.identity, after.identity)


class ForceRefreshFailureTests(unittest.TestCase):
    """`force_refresh=True` (used by `service.py`'s `_do_refresh` to prove an
    account's mapping is current as of `now`, closing the race where the
    account was swapped/disabled mid-upstream-call) must fail closed when the
    underlying listing attempt itself fails — never silently fall back to
    whatever mapping existed before, even when that old mapping is itself
    still well within `max_stale_seconds`."""

    def test_a_failed_forced_refresh_never_falls_back_to_the_old_mapping(self):
        client = FakeManagementClient([_entry("a", id="1", name="a.json")])
        resolver = AuthFileResolver(client, ttl_seconds=1, max_stale_seconds=100)
        first = resolver.resolve("a", now=1_000.0)
        self.assertIsNotNone(first)

        client.fail = True
        # The old mapping is still comfortably within max_stale_seconds, so a
        # plain (non-forced) stale resolve would still serve it — proving the
        # rejection below comes specifically from `force_refresh`, not from
        # the mapping having gone generally too old.
        still_serves_old = resolver.resolve("a", now=1_000.5)
        self.assertIsNotNone(still_serves_old, "sanity check: max_stale_seconds has not been exceeded")

        forced = resolver.resolve("a", now=1_000.5, force_refresh=True)
        self.assertIsNone(forced, "a failed forced refresh must fail closed, never reuse the unconfirmed old mapping")

    def test_a_successful_forced_refresh_still_resolves_normally(self):
        client = FakeManagementClient([_entry("a", id="1", name="a.json")])
        resolver = AuthFileResolver(client, ttl_seconds=1, max_stale_seconds=100)
        resolver.resolve("a", now=1_000.0)

        forced = resolver.resolve("a", now=1_000.5, force_refresh=True)

        self.assertIsNotNone(forced)


class SingleflightTests(unittest.TestCase):
    def test_concurrent_stale_resolves_collapse_into_one_listing_call(self):
        client = FakeManagementClient([_entry("a", id="1", name="a.json")])
        client.block_calls = True
        resolver = AuthFileResolver(client, ttl_seconds=1)

        results = []

        def call():
            results.append(resolver.resolve("a", now=1_000.0))

        threads = [threading.Thread(target=call) for _ in range(8)]
        for t in threads:
            t.start()
        self.assertTrue(client.call_started.wait(timeout=5))
        time.sleep(0.05)  # let the other seven threads pile onto the singleflight wait
        client.release_event.set()
        for t in threads:
            t.join(timeout=5)

        self.assertEqual(client.call_count, 1, "eight concurrent stale resolves must coalesce into one listing call")
        self.assertEqual(len(results), 8)
        for account in results:
            self.assertIsNotNone(account)


if __name__ == "__main__":
    unittest.main()
