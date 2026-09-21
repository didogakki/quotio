"""Unit tests for the quota-cache service. Stdlib `unittest` only.

Every test injects a fake CPA client (`FakeCPA`) in place of the real
`CPAUpstreamClient`/`ManagementClient` — nothing here ever performs a real
network request. Run with:

    cd scripts/quota-cache && python3 -B -m unittest discover -s . -p 'test_*.py'
"""

from __future__ import annotations

import http.client
import json
import os
import stat
import tempfile
import threading
import time
import unittest
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta, timezone

from auth_files import AuthFileResolver
from resources import RESOURCES
from service import PoolRuntime, QuotaCacheService, ServiceError, UpstreamError, make_server
from store import CacheStore

# Desensitized fixture reconstructed from fields measured 2026-09-15 15:17:44
# JST: account "Business3cc85b99" — weekly window genuinely at its limit
# (100% used, allowed=false, limit_reached=true), five-hour window at 22%
# used resetting 2026-09-15 18:29:55 JST.
_JST = timezone(timedelta(hours=9))


def _jst_epoch(text: str) -> float:
    return datetime.strptime(text, "%Y-%m-%d %H:%M:%S").replace(tzinfo=_JST).timestamp()


_3CC85B99_FETCHED_AT = _jst_epoch("2026-09-15 15:17:44")
_3CC85B99_FIVE_HOUR_RESET = _jst_epoch("2026-09-15 18:29:55")
_3CC85B99_WEEKLY_RESET = _jst_epoch("2026-09-19 17:10:59")


class FakeCPA:
    """Stands in for both `CPAUpstreamClient` and the `ManagementClient` the
    auth-file resolver wraps — both only need `list_auth_files`/`api_call`."""

    def __init__(self, files, responses=None):
        self.files = files
        self.responses = dict(responses or {})
        self.call_count = 0
        self._lock = threading.Lock()
        self.block_calls = False
        self.call_started = threading.Event()
        self.release_event = threading.Event()

    def list_auth_files(self):
        return list(self.files)

    def api_call(self, auth_index, method, url, header):
        with self._lock:
            self.call_count += 1
        if self.block_calls:
            self.call_started.set()
            self.release_event.wait(timeout=5)
        response = self.responses.get(auth_index)
        if isinstance(response, Exception):
            raise response
        if response is None:
            raise UpstreamError("no stubbed response for " + auth_index)
        return response


def _account(auth_index, provider="claude", disabled=False, account=None, name=None):
    return {
        "auth_index": auth_index,
        "provider": provider,
        "disabled": disabled,
        "account": account,
        "name": name or f"{auth_index}.json",
    }


class ClockStub:
    def __init__(self, start: float) -> None:
        self.value = start

    def __call__(self) -> float:
        return self.value

    def advance(self, seconds: float) -> None:
        self.value += seconds


def make_service(files, responses, clock=None, **kwargs):
    cpa = FakeCPA(files, responses)
    resolver = AuthFileResolver(cpa, ttl_seconds=9999)
    pool = PoolRuntime(name="plus", management_key="secret-plus", upstream=cpa, resolver=resolver)
    tmp_dir = tempfile.mkdtemp()
    store = CacheStore(os.path.join(tmp_dir, "state.db"))
    service = QuotaCacheService(
        {"plus": pool}, store,
        now=clock or (lambda: time.time()),
        failure_backoff_seconds=kwargs.pop("failure_backoff_seconds", 1),
        failure_backoff_max_seconds=kwargs.pop("failure_backoff_max_seconds", 10),
        **kwargs,
    )
    return service, cpa, store, tmp_dir


class SingleflightTests(unittest.TestCase):
    def test_concurrent_requests_for_the_same_key_trigger_exactly_one_upstream_call(self):
        files = [_account("claude-a")]
        body = json.dumps({"five_hour": {"utilization": 10}})
        cpa = FakeCPA(files, {"claude-a": (200, {}, body)})
        cpa.block_calls = True
        resolver = AuthFileResolver(cpa, ttl_seconds=9999)
        pool = PoolRuntime(name="plus", management_key="k", upstream=cpa, resolver=resolver)
        store = CacheStore(os.path.join(tempfile.mkdtemp(), "state.db"))
        service = QuotaCacheService({"plus": pool}, store)

        results = []

        def call():
            results.append(service.handle("plus", "claude-usage", "claude-a", False))

        threads = [threading.Thread(target=call) for _ in range(5)]
        for t in threads:
            t.start()
        self.assertTrue(cpa.call_started.wait(timeout=5))
        time.sleep(0.05)  # let the other four threads pile onto the singleflight wait
        cpa.release_event.set()
        for t in threads:
            t.join(timeout=5)

        self.assertEqual(cpa.call_count, 1, "five concurrent readers must coalesce into one upstream call")
        self.assertEqual(len(results), 5)
        for envelope in results:
            self.assertEqual(envelope["result"]["status_code"], 200)


class PoolIsolationTests(unittest.TestCase):
    def test_two_pools_never_share_cached_state_or_secrets_even_with_the_same_auth_index(self):
        plus_cpa = FakeCPA([_account("shared-index", provider="claude")], {"shared-index": (200, {}, '{"five_hour":{"utilization":10}}')})
        biz_cpa = FakeCPA([_account("shared-index", provider="codex")], {"shared-index": (200, {}, '{"rate_limit":{"primary_window":{"used_percent":40}}}')})
        store = CacheStore(os.path.join(tempfile.mkdtemp(), "state.db"))
        pools = {
            "plus": PoolRuntime("plus", "secret-plus", plus_cpa, AuthFileResolver(plus_cpa, ttl_seconds=9999)),
            "business": PoolRuntime("business", "secret-biz", biz_cpa, AuthFileResolver(biz_cpa, ttl_seconds=9999)),
        }
        service = QuotaCacheService(pools, store)

        self.assertTrue(service.authorize("plus", "Bearer secret-plus"))
        self.assertFalse(service.authorize("plus", "Bearer secret-biz"), "one pool's secret must never authorize another pool")
        self.assertTrue(service.authorize("business", "Bearer secret-biz"))

        with self.assertRaises(ServiceError) as ctx:
            service.handle("plus", "codex-usage", "shared-index", False)
        self.assertEqual(ctx.exception.code, "provider_mismatch", "the 'plus' pool's account is a claude account")

        biz_result = service.handle("business", "codex-usage", "shared-index", False)
        self.assertEqual(biz_cpa.call_count, 1)
        self.assertEqual(plus_cpa.call_count, 0, "resolving the business pool must never touch the plus pool's client")
        self.assertEqual(biz_result["result"]["status_code"], 200)


class RejectionTests(unittest.TestCase):
    def setUp(self):
        self.files = [_account("claude-a", provider="claude"), _account("claude-b", provider="claude", disabled=True)]
        self.service, self.cpa, self.store, _ = make_service(
            self.files, {"claude-a": (200, {}, '{"five_hour":{"utilization":10}}')}
        )

    def test_wrong_management_key_is_rejected(self):
        self.assertFalse(self.service.authorize("plus", "Bearer wrong-key"))
        self.assertFalse(self.service.authorize("plus", None))
        self.assertFalse(self.service.authorize("plus", "not-bearer-scheme"))

    def test_unknown_pool_is_rejected(self):
        self.assertFalse(self.service.authorize("unknown-pool", "Bearer secret-plus"))

    def test_unknown_resource_is_rejected(self):
        with self.assertRaises(ServiceError) as ctx:
            self.service.handle("plus", "totally-unknown-resource", "claude-a", False)
        self.assertEqual((ctx.exception.http_status, ctx.exception.code), (404, "unknown_resource"))

    def test_unknown_account_is_rejected(self):
        with self.assertRaises(ServiceError) as ctx:
            self.service.handle("plus", "claude-usage", "no-such-account", False)
        self.assertEqual((ctx.exception.http_status, ctx.exception.code), (404, "unknown_account"))

    def test_disabled_account_is_rejected(self):
        with self.assertRaises(ServiceError) as ctx:
            self.service.handle("plus", "claude-usage", "claude-b", False)
        self.assertEqual((ctx.exception.http_status, ctx.exception.code), (403, "account_disabled"))
        self.assertEqual(self.cpa.call_count, 0, "a disabled account must never reach the upstream call")

    def test_provider_mismatch_is_rejected(self):
        with self.assertRaises(ServiceError) as ctx:
            self.service.handle("plus", "codex-usage", "claude-a", False)
        self.assertEqual((ctx.exception.http_status, ctx.exception.code), (400, "provider_mismatch"))

    def test_malformed_auth_index_is_rejected(self):
        with self.assertRaises(ServiceError) as ctx:
            self.service.handle("plus", "claude-usage", "has spaces/../etc", False)
        self.assertEqual((ctx.exception.http_status, ctx.exception.code), (400, "bad_request"))


class HTTPWireTests(unittest.TestCase):
    """A handful of true end-to-end tests over a real loopback socket, still
    backed by `FakeCPA` — this is what actually proves method rejection, the
    Authorization gate, and the query-parameter SSRF guard at the wire level."""

    def setUp(self):
        self.service, self.cpa, self.store, _ = make_service(
            [_account("claude-a", provider="claude")], {"claude-a": (200, {}, '{"five_hour":{"utilization":10}}')}
        )
        self.server = make_server("127.0.0.1", 0, self.service)
        self.port = self.server.server_address[1]
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def tearDown(self):
        self.server.shutdown()
        self.thread.join(timeout=5)

    def _get(self, path, authorization="Bearer secret-plus"):
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        headers = {"Authorization": authorization} if authorization else {}
        conn.request("GET", path, headers=headers)
        response = conn.getresponse()
        body = json.loads(response.read().decode("utf-8"))
        conn.close()
        return response.status, body

    def test_missing_authorization_is_rejected(self):
        status, body = self._get("/quota-cache/v1/plus/claude-usage?auth_index=claude-a", authorization=None)
        self.assertEqual((status, body["error"]), (401, "unauthorized"))

    def test_non_get_method_is_rejected(self):
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        conn.request("POST", "/quota-cache/v1/plus/claude-usage?auth_index=claude-a", headers={"Authorization": "Bearer secret-plus"})
        response = conn.getresponse()
        body = json.loads(response.read().decode("utf-8"))
        conn.close()
        self.assertEqual((response.status, body["error"]), (405, "method_not_allowed"))

    def test_extra_query_parameters_are_rejected_ssrf_guard(self):
        # Only auth_index/require_fresh are ever accepted — a client can never
        # smuggle a URL, header, or token for the service to forward upstream.
        status, body = self._get(
            "/quota-cache/v1/plus/claude-usage?auth_index=claude-a&url=http://169.254.169.254/latest/meta-data")
        self.assertEqual((status, body["error"]), (400, "bad_request"))
        self.assertEqual(self.cpa.call_count, 0)

    def test_successful_request_returns_the_documented_envelope_shape(self):
        status, body = self._get("/quota-cache/v1/plus/claude-usage?auth_index=claude-a")
        self.assertEqual(status, 200)
        self.assertEqual(body["result"]["status_code"], 200)
        self.assertIn("fetched_at", body)
        self.assertIn("stale", body)
        self.assertIn("last_attempt", body)
        self.assertIn("next_retry_at", body)

    def test_health_endpoint_requires_a_valid_pool_key_even_from_loopback(self):
        # Loopback alone must never be treated as trusted: a same-host reverse
        # tunnel (e.g. cloudflared) also connects from loopback.
        status, body = self._get("/quota-cache/health", authorization=None)
        self.assertEqual((status, body["error"]), (401, "unauthorized"))

        status, body = self._get("/quota-cache/health", authorization="Bearer wrong-key")
        self.assertEqual((status, body["error"]), (401, "unauthorized"))

    def test_health_endpoint_is_reachable_locally_with_a_valid_pool_key_and_carries_no_secrets(self):
        status, body = self._get("/quota-cache/health", authorization="Bearer secret-plus")
        self.assertEqual(status, 200)
        self.assertEqual(set(body.keys()), {"hits", "upstream_calls", "coalesced", "errors"})


class TTLTests(unittest.TestCase):
    def test_fresh_read_never_calls_upstream_twice_within_ttl(self):
        clock = ClockStub(1_700_000_000)
        service, cpa, store, _ = make_service(
            [_account("claude-a")], {"claude-a": (200, {}, '{"five_hour":{"utilization":10}}')}, clock=clock
        )
        first = service.handle("plus", "claude-usage", "claude-a", False)
        clock.advance(60)  # well within the 300s TTL
        second = service.handle("plus", "claude-usage", "claude-a", False)

        self.assertEqual(cpa.call_count, 1, "a read inside the TTL window must never re-hit upstream")
        self.assertFalse(first["stale"])
        self.assertFalse(second["stale"])
        self.assertEqual(first["fetched_at"], second["fetched_at"])

    def test_expired_ttl_triggers_exactly_one_refetch_and_marks_the_result_fresh_again(self):
        clock = ClockStub(1_700_000_000)
        service, cpa, store, _ = make_service(
            [_account("claude-a")], {"claude-a": (200, {}, '{"five_hour":{"utilization":10}}')}, clock=clock
        )
        service.handle("plus", "claude-usage", "claude-a", False)
        clock.advance(301)  # past the 300s claude-usage TTL
        result = service.handle("plus", "claude-usage", "claude-a", False)

        self.assertEqual(cpa.call_count, 2)
        self.assertFalse(result["stale"])

    def test_stale_read_serves_old_body_marked_stale_when_refresh_fails(self):
        clock = ClockStub(1_700_000_000)
        service, cpa, store, _ = make_service(
            [_account("claude-a")], {"claude-a": (200, {}, '{"five_hour":{"utilization":10}}')}, clock=clock
        )
        first = service.handle("plus", "claude-usage", "claude-a", False)
        cpa.responses["claude-a"] = UpstreamError("upstream down")
        clock.advance(301)

        second = service.handle("plus", "claude-usage", "claude-a", False)

        self.assertTrue(second["stale"])
        self.assertEqual(second["result"]["body"], first["result"]["body"], "old body must be preserved on a failed refresh")
        self.assertEqual(second["last_attempt"], clock.value)
        self.assertIsNotNone(second["next_retry_at"])


class BackoffTests(unittest.TestCase):
    def test_retry_after_seconds_header_drives_the_backoff_window(self):
        clock = ClockStub(1_700_000_000)
        service, cpa, store, _ = make_service(
            [_account("claude-a")], {"claude-a": (429, {"Retry-After": ["45"]}, "rate limited")}, clock=clock,
        )
        with self.assertRaises(ServiceError) as ctx:
            service.handle("plus", "claude-usage", "claude-a", True)
        self.assertEqual(ctx.exception.code, "upstream_unavailable")

        row = store.get("plus", "claude-usage", "claude-a")
        self.assertEqual(row.next_retry_at, clock.value + 45)

    def test_repeated_failures_without_retry_after_back_off_exponentially_up_to_the_cap(self):
        clock = ClockStub(1_700_000_000)
        service, cpa, store, _ = make_service(
            [_account("claude-a")], {"claude-a": UpstreamError("down")}, clock=clock,
            failure_backoff_seconds=2, failure_backoff_max_seconds=6,
        )

        def fail_once_and_read_backoff():
            with self.assertRaises(ServiceError):
                service.handle("plus", "claude-usage", "claude-a", True)
            row = store.get("plus", "claude-usage", "claude-a")
            return row.next_retry_at - clock.value

        first_backoff = fail_once_and_read_backoff()
        self.assertEqual(first_backoff, 2)  # 2 * 2**0
        clock.advance(first_backoff + 1)  # clear the backoff window before the next attempt

        second_backoff = fail_once_and_read_backoff()
        self.assertEqual(second_backoff, 4)  # 2 * 2**1
        clock.advance(second_backoff + 1)

        third_backoff = fail_once_and_read_backoff()
        self.assertEqual(third_backoff, 6, "backoff must clamp at the configured maximum (2 * 2**2 = 8, capped to 6)")

        row = store.get("plus", "claude-usage", "claude-a")
        self.assertEqual(row.consecutive_failures, 3)

    def test_backoff_window_prevents_a_second_upstream_call_before_it_elapses(self):
        clock = ClockStub(1_700_000_000)
        service, cpa, store, _ = make_service(
            [_account("claude-a")], {"claude-a": UpstreamError("down")}, clock=clock,
            failure_backoff_seconds=100, failure_backoff_max_seconds=1000,
        )
        with self.assertRaises(ServiceError):
            service.handle("plus", "claude-usage", "claude-a", True)
        self.assertEqual(cpa.call_count, 1)

        clock.advance(1)  # still well inside the 100s backoff window
        with self.assertRaises(ServiceError) as ctx:
            service.handle("plus", "claude-usage", "claude-a", True)
        self.assertEqual(ctx.exception.code, "not_ready")
        self.assertEqual(cpa.call_count, 1, "a request inside the backoff window must never retry upstream")


class RequireFreshTests(unittest.TestCase):
    def test_require_fresh_returns_503_instead_of_stale_data_on_failure(self):
        clock = ClockStub(1_700_000_000)
        service, cpa, store, _ = make_service(
            [_account("claude-a")], {"claude-a": (200, {}, '{"five_hour":{"utilization":10}}')}, clock=clock
        )
        service.handle("plus", "claude-usage", "claude-a", False)
        cpa.responses["claude-a"] = UpstreamError("down")
        clock.advance(301)

        with self.assertRaises(ServiceError) as ctx:
            service.handle("plus", "claude-usage", "claude-a", True)
        self.assertEqual((ctx.exception.http_status, ctx.exception.code), (503, "upstream_unavailable"))

        # A normal (non-scheduler) read is still allowed to see the stale copy.
        normal = service.handle("plus", "claude-usage", "claude-a", False)
        self.assertTrue(normal["stale"])

    def test_require_fresh_succeeds_when_a_real_refresh_succeeds(self):
        clock = ClockStub(1_700_000_000)
        service, cpa, store, _ = make_service(
            [_account("claude-a")], {"claude-a": (200, {}, '{"five_hour":{"utilization":10}}')}, clock=clock
        )
        service.handle("plus", "claude-usage", "claude-a", False)
        clock.advance(301)

        result = service.handle("plus", "claude-usage", "claude-a", True)
        self.assertFalse(result["stale"])
        self.assertEqual(cpa.call_count, 2)


class PersistenceTests(unittest.TestCase):
    def test_state_survives_a_process_restart(self):
        tmp_dir = tempfile.mkdtemp()
        db_path = os.path.join(tmp_dir, "state.db")
        store = CacheStore(db_path)
        store.record_success(
            "plus", "claude-usage", "claude-a", "identity-1",
            status_code=200, header_json="{}", body='{"five_hour":{"utilization":10}}',
            fetched_at=1_700_000_000, expected_generation=None,
        )
        store.record_failure(
            "plus", "codex-usage", "codex-a", "identity-2",
            attempted_at=1_700_000_500, next_retry_at=1_700_000_800, consecutive_failures=3,
            expected_generation=None,
        )
        store.close()

        reopened = CacheStore(db_path)
        success_row = reopened.get("plus", "claude-usage", "claude-a")
        self.assertIsNotNone(success_row)
        self.assertEqual(success_row.status_code, 200)
        self.assertEqual(success_row.fetched_at, 1_700_000_000)

        failure_row = reopened.get("plus", "codex-usage", "codex-a")
        self.assertEqual(failure_row.consecutive_failures, 3)
        self.assertEqual(failure_row.next_retry_at, 1_700_000_800)
        reopened.close()

    def test_database_file_and_parent_directory_have_private_permissions(self):
        tmp_dir = tempfile.mkdtemp()
        db_path = os.path.join(tmp_dir, "nested", "state.db")
        store = CacheStore(db_path)
        store.record_success(
            "plus", "claude-usage", "claude-a", "identity-1",
            status_code=200, header_json="{}", body="{}", fetched_at=1.0, expected_generation=None,
        )
        store.close()

        self.assertEqual(stat.S_IMODE(os.stat(db_path).st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(os.stat(os.path.dirname(db_path)).st_mode), 0o700)

    def test_account_replacement_invalidates_the_previous_identitys_cached_row(self):
        clock = ClockStub(1_700_000_000)
        files = [_account("claude-a", name="original-file.json")]
        service, cpa, store, _ = make_service(
            files, {"claude-a": (200, {}, '{"five_hour":{"utilization":10}}')}, clock=clock
        )
        first = service.handle("plus", "claude-usage", "claude-a", False)

        # CPA reassigns the same auth_index to a different, newly-added account.
        cpa.files = [_account("claude-a", name="replacement-file.json")]
        cpa.responses["claude-a"] = (200, {}, '{"five_hour":{"utilization":70}}')
        cpa.resolver_ttl_bust = True
        # Force the resolver to see the new listing immediately (its own short
        # TTL would otherwise still be within its window in a real deployment).
        service._pools["plus"].resolver._fetched_at = 0  # noqa: SLF001

        second = service.handle("plus", "claude-usage", "claude-a", False)

        self.assertNotEqual(first["result"]["body"], second["result"]["body"])
        self.assertEqual(cpa.call_count, 2, "the replaced account must trigger its own fresh fetch, not reuse the old cache row")


class AuthInvalidClassificationTests(unittest.TestCase):
    def test_401_is_persisted_as_safe_sticky_failure_and_cleared_by_success(self):
        clock = ClockStub(1_700_000_000)
        raw = '{"error":{"message":"Encountered invalidated oauth token for user, failing request"}}'
        service, cpa, store, _ = make_service(
            [_account("codex-a", provider="codex")],
            {"codex-a": (401, {}, raw)},
            clock=clock,
            failure_backoff_seconds=1,
        )

        with self.assertRaises(ServiceError) as ctx:
            service.handle("plus", "codex-usage", "codex-a", True)
        self.assertEqual(ctx.exception.failure, {"kind": "auth_invalid", "status_code": 401})
        row = store.get("plus", "codex-usage", "codex-a")
        self.assertEqual((row.failure_kind, row.failure_status_code), ("auth_invalid", 401))
        self.assertNotIn("invalidated oauth token", repr(row).lower())

        # A generic transport failure does not clear a confirmed auth quarantine.
        clock.advance(2)
        cpa.responses["codex-a"] = UpstreamError("temporary")
        with self.assertRaises(ServiceError) as retry_ctx:
            service.handle("plus", "codex-usage", "codex-a", True)
        self.assertEqual(retry_ctx.exception.failure, {"kind": "auth_invalid", "status_code": 401})

        # A successful reading is the only thing that clears the failure for the
        # same identity, allowing the account to rejoin automatically.
        clock.advance(3)
        cpa.responses["codex-a"] = (
            200,
            {},
            '{"rate_limit":{"primary_window":{"used_percent":20,"limit_window_seconds":604800,"reset_at":1700604800}}}',
        )
        envelope = service.handle("plus", "codex-usage", "codex-a", True)
        self.assertNotIn("failure", envelope)
        row = store.get("plus", "codex-usage", "codex-a")
        self.assertIsNone(row.failure_kind)
        self.assertIsNone(row.failure_status_code)


class HeaderAllowlistTests(unittest.TestCase):
    def test_only_retry_after_is_persisted_from_a_successful_response_never_set_cookie_or_others(self):
        clock = ClockStub(1_700_000_000)
        service, cpa, store, _ = make_service(
            [_account("claude-a")],
            {
                "claude-a": (
                    200,
                    {"Set-Cookie": ["session=secret"], "Retry-After": ["30"], "X-Internal-Debug": ["trace-id-1"]},
                    '{"five_hour":{"utilization":10}}',
                ),
            },
            clock=clock,
        )
        service.handle("plus", "claude-usage", "claude-a", False)

        row = store.get("plus", "claude-usage", "claude-a")
        headers = json.loads(row.header_json)
        self.assertEqual(headers, {"Retry-After": ["30"]})


class InvalidBodySuccessGuardTests(unittest.TestCase):
    def test_2xx_with_a_body_matching_no_keep_paths_is_treated_as_failure_and_never_overwrites_success(self):
        clock = ClockStub(1_700_000_000)
        service, cpa, store, _ = make_service(
            [_account("claude-a")], {"claude-a": (200, {}, '{"five_hour":{"utilization":10}}')}, clock=clock
        )
        first = service.handle("plus", "claude-usage", "claude-a", False)
        # A 2xx whose body carries none of claude-usage's whitelisted fields —
        # e.g. an unexpected upstream response shape — must never be cached as
        # a fresh "success".
        cpa.responses["claude-a"] = (200, {}, '{"unrelated_field": "x"}')
        clock.advance(301)

        second = service.handle("plus", "claude-usage", "claude-a", False)

        self.assertTrue(second["stale"])
        self.assertEqual(
            second["result"]["body"], first["result"]["body"],
            "an unusable 2xx body must never overwrite the previous real success",
        )
        row = store.get("plus", "claude-usage", "claude-a")
        self.assertEqual(row.consecutive_failures, 1)
        self.assertIsNotNone(row.next_retry_at)

    def test_a_2xx_body_with_no_actual_usage_window_never_overwrites_a_prior_success(self):
        # `{"plan_type": "plus"}` (and, likewise, `{"rate_limit": {}}`) both
        # match at least one codex-usage `keep_paths` entry, so they are not
        # caught by the "matches no keep_paths" guard above — but neither
        # carries an actual quota-window reading, so this must be treated as
        # a failed attempt, exactly like the no-keep-paths-match case, never
        # as a fresh success that overwrites the real reading already cached.
        clock = ClockStub(1_700_000_000)
        service, cpa, store, _ = make_service(
            [_account("codex-a", provider="codex")],
            {"codex-a": (200, {}, '{"rate_limit":{"primary_window":{"used_percent":25,"limit_window_seconds":18000}}}')},
            clock=clock,
        )
        first = service.handle("plus", "codex-usage", "codex-a", False)

        for bogus_body in ('{"plan_type": "plus"}', '{"rate_limit": {}}'):
            cpa.responses["codex-a"] = (200, {}, bogus_body)
            clock.advance(301)

            second = service.handle("plus", "codex-usage", "codex-a", False)

            self.assertTrue(second["stale"])
            self.assertEqual(
                second["result"]["body"], first["result"]["body"],
                "a windowless 2xx body must never overwrite the previous real success",
            )
            row = store.get("plus", "codex-usage", "codex-a")
            self.assertGreaterEqual(row.consecutive_failures, 1)
            self.assertIsNotNone(row.next_retry_at)


class LeaderRecheckRaceTests(unittest.TestCase):
    """Deterministic coverage for the race where a request loses the leader
    election until *after* an earlier leader already refreshed the same key
    (its `finally` already popped the key out of `_inflight`) — `_refresh`
    must re-check freshness/backoff before spending a second, redundant
    upstream call on data that is already current."""

    def test_late_leader_skips_a_redundant_call_when_the_row_is_already_fresh(self):
        clock = ClockStub(1_700_000_000)
        service, cpa, store, _ = make_service(
            [_account("claude-a")], {"claude-a": (200, {}, '{"five_hour":{"utilization":10}}')}, clock=clock
        )
        pool = service._pools["plus"]  # noqa: SLF001
        spec = RESOURCES["claude-usage"]
        account = pool.resolver.resolve("claude-a", now=clock.value)
        store.record_success(
            "plus", "claude-usage", "claude-a", account.identity,
            status_code=200, header_json="{}", body="{}", fetched_at=clock.value,
            expected_generation=None,
        )

        service._refresh(pool, spec, "claude-usage", "claude-a", account, ("plus", "claude-usage", "claude-a"))  # noqa: SLF001

        self.assertEqual(cpa.call_count, 0, "a late leader must never re-hit upstream for data that is already fresh")

    def test_late_leader_skips_a_redundant_call_during_an_active_backoff_window(self):
        clock = ClockStub(1_700_000_000)
        service, cpa, store, _ = make_service(
            [_account("claude-a")], {"claude-a": (200, {}, '{"five_hour":{"utilization":10}}')}, clock=clock
        )
        pool = service._pools["plus"]  # noqa: SLF001
        spec = RESOURCES["claude-usage"]
        account = pool.resolver.resolve("claude-a", now=clock.value)
        store.record_failure(
            "plus", "claude-usage", "claude-a", account.identity,
            attempted_at=clock.value, next_retry_at=clock.value + 100, consecutive_failures=1,
            expected_generation=None,
        )

        service._refresh(pool, spec, "claude-usage", "claude-a", account, ("plus", "claude-usage", "claude-a"))  # noqa: SLF001

        self.assertEqual(cpa.call_count, 0, "a late leader must never re-hit upstream inside an active backoff window")


class RetryAfterEdgeCaseTests(unittest.TestCase):
    def test_retry_after_zero_is_honored_as_an_immediate_retry(self):
        clock = ClockStub(1_700_000_000)
        service, cpa, store, _ = make_service(
            [_account("claude-a")], {"claude-a": (429, {"Retry-After": ["0"]}, "rate limited")}, clock=clock,
            failure_backoff_seconds=100,
        )
        with self.assertRaises(ServiceError):
            service.handle("plus", "claude-usage", "claude-a", True)
        row = store.get("plus", "claude-usage", "claude-a")
        self.assertEqual(row.next_retry_at, clock.value, "an explicit Retry-After: 0 must not fall back to exponential backoff")

    def test_non_finite_retry_after_is_rejected_and_falls_back_to_exponential_backoff(self):
        clock = ClockStub(1_700_000_000)
        service, cpa, store, _ = make_service(
            [_account("claude-a")], {"claude-a": (429, {"Retry-After": ["Infinity"]}, "rate limited")}, clock=clock,
            failure_backoff_seconds=5, failure_backoff_max_seconds=50,
        )
        with self.assertRaises(ServiceError):
            service.handle("plus", "claude-usage", "claude-a", True)
        row = store.get("plus", "claude-usage", "claude-a")
        self.assertEqual(row.next_retry_at, clock.value + 5, "a non-finite Retry-After must never be honored")

    def test_a_multi_hour_explicit_retry_after_is_honored_not_truncated_to_one_hour(self):
        clock = ClockStub(1_700_000_000)
        service, cpa, store, _ = make_service(
            [_account("claude-a")], {"claude-a": (429, {"Retry-After": ["18000"]}, "rate limited")}, clock=clock,
        )
        with self.assertRaises(ServiceError):
            service.handle("plus", "claude-usage", "claude-a", True)
        row = store.get("plus", "claude-usage", "claude-a")
        self.assertEqual(
            row.next_retry_at, clock.value + 18000,
            "a real 5-hour upstream Retry-After must not be truncated down to the old 3600s cap",
        )

    def test_exponential_backoff_exponent_is_capped_and_never_raises_overflowerror(self):
        clock = ClockStub(1_700_000_000)
        service, cpa, store, _ = make_service(
            [_account("claude-a")], {"claude-a": UpstreamError("down")}, clock=clock,
            failure_backoff_seconds=1, failure_backoff_max_seconds=10,
        )
        pool = service._pools["plus"]  # noqa: SLF001
        account = pool.resolver.resolve("claude-a", now=clock.value)
        # Seeding a huge consecutive_failures count directly stands in for a
        # service that has been failing for a very long uptime — reaching it
        # through real attempts would make this test impractically slow, and
        # the whole point is that the exponent must never be allowed to grow
        # without bound in the first place.
        store.record_failure(
            "plus", "claude-usage", "claude-a", account.identity,
            attempted_at=clock.value, next_retry_at=clock.value, consecutive_failures=10_000,
            expected_generation=None,
        )

        with self.assertRaises(ServiceError):
            service.handle("plus", "claude-usage", "claude-a", True)

        row = store.get("plus", "claude-usage", "claude-a")
        self.assertEqual(row.next_retry_at, clock.value + 10, "backoff must still clamp to the configured maximum")


class WindowBoundaryFreshnessTests(unittest.TestCase):
    """Covers the window-boundary-aware freshness cutoff added to `handle()`:
    a cached success is fresh only until `min(fetched_at + ttl_seconds,
    window_reset_bound(...))` — crossing a quota window's own reset, not just
    the flat TTL, must force a real refresh."""

    def test_a_window_going_stale_forces_a_refresh_before_the_flat_ttl_elapses(self):
        clock = ClockStub(1_700_000_000)
        body = json.dumps({
            "rate_limit": {"primary_window": {"used_percent": 9, "limit_window_seconds": 18000, "reset_at": clock.value + 120}},
        })
        service, cpa, store, _ = make_service(
            [_account("codex-a", provider="codex")], {"codex-a": (200, {}, body)}, clock=clock,
        )
        first = service.handle("plus", "codex-usage", "codex-a", False)
        self.assertFalse(first["stale"])

        clock.advance(119)  # 1s before the window's own reset_at; well within the 300s TTL
        second = service.handle("plus", "codex-usage", "codex-a", False)
        self.assertFalse(second["stale"])
        self.assertEqual(cpa.call_count, 1, "must never re-hit upstream before the window's own boundary")

        clock.advance(2)  # now past reset_at (121s elapsed); nowhere near the 300s TTL
        cpa.responses["codex-a"] = (200, {}, json.dumps({
            "rate_limit": {"primary_window": {"used_percent": 40, "limit_window_seconds": 18000, "reset_at": clock.value + 18000}},
        }))
        third = service.handle("plus", "codex-usage", "codex-a", False)
        self.assertFalse(third["stale"])
        self.assertEqual(
            cpa.call_count, 2,
            "crossing the window's own reset_at must trigger a real refresh even though the flat TTL has not elapsed",
        )

    def test_each_window_invalidates_independently_of_the_others_own_boundary(self):
        clock = ClockStub(1_700_000_000)
        body = json.dumps({
            "rate_limit": {
                "primary_window": {"used_percent": 9, "limit_window_seconds": 18000, "reset_at": clock.value + 100},
                "secondary_window": {"used_percent": 96, "limit_window_seconds": 604800, "reset_at": clock.value + 500_000},
            },
        })
        service, cpa, store, _ = make_service(
            [_account("codex-a", provider="codex")], {"codex-a": (200, {}, body)}, clock=clock,
        )
        service.handle("plus", "codex-usage", "codex-a", False)

        clock.advance(101)  # past the five-hour window's reset_at; the weekly bound and the 300s TTL are both nowhere close
        cpa.responses["codex-a"] = (200, {}, json.dumps({
            "rate_limit": {
                "primary_window": {"used_percent": 3, "limit_window_seconds": 18000, "reset_at": clock.value + 18000},
                "secondary_window": {"used_percent": 96, "limit_window_seconds": 604800, "reset_at": clock.value + 500_000},
            },
        }))
        result = service.handle("plus", "codex-usage", "codex-a", False)

        self.assertEqual(
            cpa.call_count, 2,
            "the five-hour window rolling over must force a refresh independent of the weekly window's own, far-away boundary",
        )
        self.assertFalse(result["stale"])

    def test_a_weekly_only_account_is_governed_by_the_flat_ttl_not_a_fabricated_five_hour_boundary(self):
        # Desensitized fixture shape: account "Plus21e63259" — a weekly-only
        # account (no five-hour limit at all, not missing data). The weekly
        # reset itself is far in the future, so if this ever went stale before
        # the plain 300s TTL, the only possible cause would be a fabricated
        # shorter (e.g. five-hour) boundary invented for the *missing* window
        # — exercised on both sides of the exact 300s TTL boundary to prove
        # nothing shorter is silently in effect.
        clock = ClockStub(1_700_000_000)
        body = json.dumps({
            "rate_limit": {
                "primary_window": {"used_percent": 0, "limit_window_seconds": 604800, "reset_at": clock.value + 500_000},
                "secondary_window": None,
            },
        })
        service, cpa, store, _ = make_service(
            [_account("codex-a", provider="codex")], {"codex-a": (200, {}, body)}, clock=clock,
        )
        service.handle("plus", "codex-usage", "codex-a", False)

        clock.advance(299)  # just inside the 300s TTL
        still_fresh = service.handle("plus", "codex-usage", "codex-a", False)
        self.assertFalse(still_fresh["stale"])
        self.assertEqual(
            cpa.call_count, 1,
            "an account with no five-hour window must never go stale before the plain TTL elapses",
        )

        clock.advance(2)  # now 301s since fetch: past the plain TTL, still nowhere near the real weekly reset
        cpa.responses["codex-a"] = (200, {}, json.dumps({
            "rate_limit": {
                "primary_window": {"used_percent": 0, "limit_window_seconds": 604800, "reset_at": clock.value + 500_000},
                "secondary_window": None,
            },
        }))
        after_ttl = service.handle("plus", "codex-usage", "codex-a", False)
        self.assertFalse(after_ttl["stale"])
        self.assertEqual(
            cpa.call_count, 2,
            "the plain 300s TTL must still be the governing bound for a weekly-only account",
        )

    def test_repeated_cache_hits_never_push_a_relative_reset_after_seconds_boundary_further_out(self):
        clock = ClockStub(1_700_000_000)
        body = json.dumps({"rate_limit": {"primary_window": {"used_percent": 9, "reset_after_seconds": 200}}})
        service, cpa, store, _ = make_service(
            [_account("codex-a", provider="codex")], {"codex-a": (200, {}, body)}, clock=clock,
        )
        first = service.handle("plus", "codex-usage", "codex-a", False)
        self.assertFalse(first["stale"])

        clock.advance(150)  # a repeated cache hit well before the original 200s countdown elapses
        second = service.handle("plus", "codex-usage", "codex-a", False)
        self.assertFalse(second["stale"])
        self.assertEqual(cpa.call_count, 1, "a cache hit must never re-anchor the countdown to the read time")

        clock.advance(51)  # now 201s after the original fetch — past the boundary anchored to it
        cpa.responses["codex-a"] = (200, {}, json.dumps({"rate_limit": {"primary_window": {"used_percent": 15, "reset_after_seconds": 200}}}))
        third = service.handle("plus", "codex-usage", "codex-a", False)

        self.assertEqual(
            cpa.call_count, 2,
            "the boundary anchored to the original fetched_at must still force a refresh at the right time, "
            "proving the earlier repeated hits never extended it",
        )
        self.assertFalse(third["stale"])

    def test_a_weekly_window_genuinely_at_its_limit_is_served_unchanged_once_its_boundary_passes_and_upstream_keeps_failing(self):
        # Desensitized fixture: account "Business3cc85b99" — weekly window at
        # 100% used, allowed=false, limit_reached=true, sampled 2026-09-15
        # 15:17:44 JST. Once the account's own (sooner, five-hour) boundary
        # has passed and a real refresh cannot be obtained, the cache must
        # keep serving exactly this cached reading marked `stale`: elapsed
        # wall-clock time alone must never turn a genuinely exhausted weekly
        # window into partial usage, or flip `allowed`/`limit_reached` — only
        # a real successful upstream response is permitted to change those
        # numbers.
        clock = ClockStub(_3CC85B99_FETCHED_AT)
        body = json.dumps({
            "rate_limit": {
                "limit_reached": True,
                "allowed": False,
                "primary_window": {"used_percent": 22, "limit_window_seconds": 18000, "reset_at": _3CC85B99_FIVE_HOUR_RESET},
                "secondary_window": {"used_percent": 100, "limit_window_seconds": 604800, "reset_at": _3CC85B99_WEEKLY_RESET},
            },
        })
        service, cpa, store, _ = make_service(
            [_account("codex-a", provider="codex")], {"codex-a": (200, {}, body)}, clock=clock,
        )
        first = service.handle("plus", "codex-usage", "codex-a", False)
        self.assertFalse(first["stale"])

        clock.value = _3CC85B99_FIVE_HOUR_RESET + 1  # past the account's own, sooner five-hour boundary
        cpa.responses["codex-a"] = UpstreamError("still failing")
        second = service.handle("plus", "codex-usage", "codex-a", False)

        self.assertTrue(second["stale"], "a real refresh must be attempted and fail before old data is served")
        served = json.loads(second["result"]["body"])
        self.assertEqual(
            served["rate_limit"]["secondary_window"]["used_percent"], 100,
            "elapsed time must never turn a genuinely exhausted weekly window into partial usage",
        )
        self.assertEqual(
            served["rate_limit"]["allowed"], False,
            "elapsed time alone must never flip allowed to true without a real successful refresh",
        )
        self.assertEqual(served["rate_limit"]["limit_reached"], True)


class BoundedHandlerTests(unittest.TestCase):
    def test_a_request_beyond_the_configured_concurrency_gets_503_busy(self):
        cpa = FakeCPA([_account("claude-a")], {"claude-a": (200, {}, '{"five_hour":{"utilization":10}}')})
        cpa.block_calls = True
        resolver = AuthFileResolver(cpa, ttl_seconds=9999)
        pool = PoolRuntime(name="plus", management_key="secret-plus", upstream=cpa, resolver=resolver)
        store = CacheStore(os.path.join(tempfile.mkdtemp(), "state.db"))
        service = QuotaCacheService({"plus": pool}, store)
        server = make_server("127.0.0.1", 0, service, max_concurrent_requests=1)
        port = server.server_address[1]
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(lambda: thread.join(timeout=5))
        self.addCleanup(server.shutdown)

        statuses = []

        def get():
            conn = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
            conn.request(
                "GET", "/quota-cache/v1/plus/claude-usage?auth_index=claude-a",
                headers={"Authorization": "Bearer secret-plus"},
            )
            response = conn.getresponse()
            statuses.append(response.status)
            response.read()
            conn.close()

        first = threading.Thread(target=get)
        first.start()
        self.assertTrue(cpa.call_started.wait(timeout=5), "the first request must occupy the only request slot")

        second = threading.Thread(target=get)
        second.start()
        second.join(timeout=5)

        cpa.release_event.set()
        first.join(timeout=5)

        self.assertIn(503, statuses, "a request beyond the configured concurrency must get 503 busy")


if __name__ == "__main__":
    unittest.main()
