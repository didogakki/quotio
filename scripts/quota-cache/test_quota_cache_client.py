"""Unit tests for the consumer-side quota-cache client. Stdlib `unittest` only,
no real network access — `service.make_server` runs a real loopback server
backed entirely by an in-memory fake CPA client."""

from __future__ import annotations

import http.client
import json
import threading
import unittest

import quota_cache_client
from service import PoolRuntime, QuotaCacheService, make_server
from store import CacheStore
from test_service import FakeCPA, _account
from auth_files import AuthFileResolver
import os
import tempfile


class QuotaCacheClientTests(unittest.TestCase):
    def setUp(self):
        cpa = FakeCPA(
            [_account("claude-a", provider="claude")],
            {"claude-a": (200, {}, '{"five_hour":{"utilization":10}}')},
        )
        self.cpa = cpa
        resolver = AuthFileResolver(cpa, ttl_seconds=9999)
        pool = PoolRuntime("plus", "secret-plus", cpa, resolver)
        self.store = CacheStore(os.path.join(tempfile.mkdtemp(), "state.db"))
        self.service = QuotaCacheService({"plus": pool}, self.store)
        self.server = make_server("127.0.0.1", 0, self.service)
        self.port = self.server.server_address[1]
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.base_url = f"http://127.0.0.1:{self.port}/quota-cache/v1/plus"

    def tearDown(self):
        self.server.shutdown()
        self.thread.join(timeout=5)

    def test_fetch_returns_the_envelope_for_a_valid_request(self):
        envelope = quota_cache_client.fetch(self.base_url, "secret-plus", "claude-usage", "claude-a")
        self.assertEqual(envelope["result"]["status_code"], 200)
        self.assertIn("fetched_at", envelope)

    def test_fetch_raises_on_wrong_management_key(self):
        with self.assertRaises(quota_cache_client.QuotaCacheError):
            quota_cache_client.fetch(self.base_url, "wrong-key", "claude-usage", "claude-a")

    def test_fetch_raises_on_unknown_resource(self):
        with self.assertRaises(quota_cache_client.QuotaCacheError):
            quota_cache_client.fetch(self.base_url, "secret-plus", "not-a-resource", "claude-a")

    def test_require_fresh_reaches_the_service_and_forces_a_real_check(self):
        quota_cache_client.fetch(self.base_url, "secret-plus", "claude-usage", "claude-a", require_fresh=True)
        self.assertEqual(self.cpa.call_count, 1)


class RequireFreshValidationTests(unittest.TestCase):
    """Covers the client-side belt-and-suspenders validation added on top of the
    service's own `require_fresh` contract — never trust a 200 status code
    alone for a decision-critical read."""

    def _serve(self, body: str):
        import http.server
        import threading as _threading

        payload = body.encode("utf-8")

        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_GET(self):  # noqa: N802
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)

        server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
        thread = _threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(server.shutdown)
        self.addCleanup(lambda: thread.join(timeout=5))
        return f"http://127.0.0.1:{server.server_address[1]}"

    def test_require_fresh_rejects_a_200_envelope_that_claims_stale_true(self):
        base_url = self._serve(
            '{"result":{"status_code":200,"header":{},"body":"{}"},'
            '"fetched_at":1700000000,"stale":true,"last_attempt":1700000000,"next_retry_at":null}'
        )
        with self.assertRaises(quota_cache_client.QuotaCacheError):
            quota_cache_client.fetch(base_url, "k", "claude-usage", "a", require_fresh=True)

    def test_require_fresh_rejects_a_200_envelope_missing_fetched_at(self):
        base_url = self._serve(
            '{"result":{"status_code":200,"header":{},"body":"{}"},'
            '"stale":false,"last_attempt":1700000000,"next_retry_at":null}'
        )
        with self.assertRaises(quota_cache_client.QuotaCacheError):
            quota_cache_client.fetch(base_url, "k", "claude-usage", "a", require_fresh=True)

    def test_require_fresh_rejects_a_200_envelope_missing_the_result_body(self):
        base_url = self._serve(
            '{"result":{"status_code":200,"header":{}},'
            '"fetched_at":1700000000,"stale":false,"last_attempt":1700000000,"next_retry_at":null}'
        )
        with self.assertRaises(quota_cache_client.QuotaCacheError):
            quota_cache_client.fetch(base_url, "k", "claude-usage", "a", require_fresh=True)

    def test_require_fresh_accepts_a_genuinely_fresh_envelope(self):
        base_url = self._serve(
            '{"result":{"status_code":200,"header":{},"body":"{}"},'
            '"fetched_at":1700000000,"stale":false,"last_attempt":1700000000,"next_retry_at":null}'
        )
        envelope = quota_cache_client.fetch(base_url, "k", "claude-usage", "a", require_fresh=True)
        self.assertFalse(envelope["stale"])

    def test_a_non_require_fresh_read_still_accepts_a_stale_envelope(self):
        base_url = self._serve(
            '{"result":{"status_code":200,"header":{},"body":"{}"},'
            '"fetched_at":1700000000,"stale":true,"last_attempt":1700000000,"next_retry_at":null}'
        )
        envelope = quota_cache_client.fetch(base_url, "k", "claude-usage", "a", require_fresh=False)
        self.assertTrue(envelope["stale"])


if __name__ == "__main__":
    unittest.main()
