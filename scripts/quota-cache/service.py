#!/usr/bin/env python3
"""Quotio quota-cache service.

A single local, read-only, GET-only HTTP service that sits between Quotio (and
the New API balance/recovery scripts) and CLIProxyAPI's `/v0/management/api-call`
pass-through, so all three consumers share one upstream fetch per account and
resource instead of each polling CLIProxyAPI — and, transitively, the real
provider — on their own schedule.

Contract (see README.md for the full write-up):
  * GET /quota-cache/v1/{pool}/{resource}?auth_index=...[&require_fresh=1]
  * `pool` and `resource` are both closed whitelists (see `resources.py`);
    nothing about the outbound URL or headers is ever derived from a request.
  * Authorization: Bearer <pool's existing CLIProxyAPI management key> — the
    same secret each pool's consumers already hold; no new secret is created.
  * Only GET is accepted; POST/PUT/DELETE/... all get 405.
  * A resource whose TTL has not elapsed is served straight from the local
    cache and never triggers an upstream call ("fresh reads never go to
    origin"). A stale/missing entry triggers at most one upstream call per
    (pool, resource, account) at a time — every other concurrent reader for
    the same key waits on that one call instead of issuing its own.
  * `require_fresh=1` (used by the balance/recovery schedulers, never by casual
    UI reads) forces a real attempt and returns 503 on failure instead of ever
    handing back a stale body — a scheduler must never rebalance or reset
    quota against data it cannot confirm is current.
  * Every error response is one of a small set of sanitized codes; no upstream
    body, header, or exception text is ever echoed back.
"""

from __future__ import annotations

import argparse
import hmac
import json
import logging
import math
import os
import re
import threading
import time
import urllib.error
import urllib.request
from dataclasses import dataclass
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any, Dict, Optional, Tuple
from urllib.parse import parse_qs, urlsplit

from auth_files import AuthFileResolver, ResolvedAccount
from resources import RESOURCES, sanitize_body, window_reset_bound
from store import CacheRow, CacheStore

LOG = logging.getLogger("quota-cache")

_AUTH_INDEX_RE = re.compile(r"^[A-Za-z0-9._:-]{1,256}$")


class UpstreamError(Exception):
    pass


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args: Any, **kwargs: Any) -> None:  # noqa: D401
        return None


class CPAUpstreamClient:
    """Minimal, header-preserving CLIProxyAPI management client.

    Deliberately separate from `cpa_quota_recovery.ManagementClient` (which the
    balance/recovery scripts still use unmodified) because this service also
    needs the upstream response's own headers (for `Retry-After`), which that
    client's `api_call` never returns — extending its public return shape would
    risk touching the recovery/balance call sites this task must leave alone.
    """

    def __init__(self, base_url: str, management_key: str, timeout: float, max_response_bytes: int) -> None:
        self._base_url = base_url.rstrip("/")
        self._key = management_key
        self._timeout = timeout
        self._max_response_bytes = max_response_bytes

    def list_auth_files(self) -> list:
        _, payload = self._request("GET", "/v0/management/auth-files", None)
        files = payload.get("files") if isinstance(payload, dict) else None
        return [f for f in files if isinstance(f, dict)] if isinstance(files, list) else []

    def api_call(self, auth_index: str, method: str, url: str, header: Dict[str, str]) -> Tuple[int, Dict[str, Any], str]:
        payload = {"auth_index": auth_index, "method": method, "url": url, "header": header}
        _, parsed = self._request("POST", "/v0/management/api-call", payload)
        if not isinstance(parsed, dict):
            raise UpstreamError("invalid api-call response")
        status = parsed.get("status_code")
        if not isinstance(status, int):
            raise UpstreamError("api-call response missing status_code")
        result_header = parsed.get("header") if isinstance(parsed.get("header"), dict) else {}
        result_body = parsed.get("body") if isinstance(parsed.get("body"), str) else ""
        return status, result_header, result_body

    def _request(self, method: str, path: str, payload: Optional[dict]) -> Tuple[int, Any]:
        url = f"{self._base_url}{path}"
        data = json.dumps(payload).encode("utf-8") if payload is not None else None
        headers = {"Authorization": f"Bearer {self._key}"}
        if data is not None:
            headers["Content-Type"] = "application/json"
        request = urllib.request.Request(url, data=data, method=method, headers=headers)
        opener = urllib.request.build_opener(_NoRedirect)
        try:
            with opener.open(request, timeout=self._timeout) as response:
                status = response.getcode()
                body = response.read(self._max_response_bytes + 1)
        except urllib.error.HTTPError as exc:
            try:
                exc.read(self._max_response_bytes)
            except Exception:
                pass
            raise UpstreamError(f"management {method} {path} http {exc.code}") from None
        except urllib.error.URLError as exc:
            raise UpstreamError(f"management {method} {path} failed: {exc.reason}") from None
        except OSError as exc:
            raise UpstreamError(f"management {method} {path} failed: {exc}") from None
        if len(body) > self._max_response_bytes:
            raise UpstreamError("management response exceeded size limit")
        if status < 200 or status >= 300:
            raise UpstreamError(f"management {method} {path} http {status}")
        try:
            parsed = json.loads(body.decode("utf-8")) if body else {}
        except (ValueError, UnicodeDecodeError) as exc:
            raise UpstreamError("management response invalid json") from exc
        return status, parsed


@dataclass
class PoolRuntime:
    name: str
    management_key: str
    upstream: CPAUpstreamClient
    resolver: AuthFileResolver


class ServiceError(Exception):
    def __init__(self, http_status: int, code: str, failure: Optional[Dict[str, Any]] = None) -> None:
        super().__init__(code)
        self.http_status = http_status
        self.code = code
        self.failure = failure


def _classified_auth_failure(status: Optional[int], body: str) -> Tuple[Optional[str], Optional[int]]:
    """Return only a fixed, non-sensitive failure category.

    The raw upstream body is inspected in memory and is never persisted or returned.
    Every 401 is an unusable credential. A 403 is classified only when it carries
    an explicit OAuth-token invalidation marker, because a generic 403 can also mean
    an entitlement or policy denial rather than a broken login.
    """
    if status == 401:
        return "auth_invalid", 401
    lowered = body.lower()
    if status == 403 and (
        "invalidated oauth token" in lowered
        or "invalid oauth token" in lowered
        or "oauth token has been invalidated" in lowered
    ):
        return "auth_invalid", 403
    return None, None


def _failure_payload(row: Optional[CacheRow]) -> Optional[Dict[str, Any]]:
    if row is None or row.failure_kind != "auth_invalid":
        return None
    payload: Dict[str, Any] = {"kind": "auth_invalid"}
    if row.failure_status_code in (401, 403):
        payload["status_code"] = row.failure_status_code
    return payload


def _http_date_to_epoch(value: str) -> Optional[float]:
    from email.utils import parsedate_to_datetime

    try:
        dt = parsedate_to_datetime(value)
    except (TypeError, ValueError):
        return None
    if dt is None:
        return None
    return dt.timestamp()


def _retry_after_seconds(header: Dict[str, Any], now: float) -> Optional[float]:
    value = None
    for key, values in (header or {}).items():
        if key.lower() == "retry-after" and values:
            value = values[0] if isinstance(values, list) else values
            break
    if not value:
        return None
    value = str(value).strip()
    if not value:
        return None
    try:
        seconds = float(value)
    except ValueError:
        seconds = None
    if seconds is not None:
        # `float()` also accepts "inf"/"nan" — reject anything non-finite rather
        # than letting it become an effectively-permanent (or nonsensical)
        # backoff window. An explicit `0` is a valid RFC 7231 delta-seconds
        # value (retry immediately) and must not be dropped.
        if not math.isfinite(seconds):
            return None
        return seconds if seconds >= 0 else None
    epoch = _http_date_to_epoch(value)
    if epoch is not None and math.isfinite(epoch) and epoch > now:
        return epoch - now
    return None


# Only ever consumed downstream: `_retry_after_seconds` above (server-side backoff)
# and `RemoteManagementQuotaFetcher.recoveryDate` (client-side, over the direct
# `/api-call` path). No other response header is ever read by any consumer, so
# nothing else — Set-Cookie included — is ever worth persisting, and persisting
# it would just be forwarding upstream's raw headers into local storage for free.
_PERSISTED_RESPONSE_HEADERS = {"retry-after"}


def _filtered_response_headers(header: Optional[Dict[str, Any]]) -> Dict[str, list]:
    filtered: Dict[str, list] = {}
    for key, values in (header or {}).items():
        if not isinstance(key, str) or key.lower() not in _PERSISTED_RESPONSE_HEADERS:
            continue
        if isinstance(values, list):
            values = [str(v) for v in values if isinstance(v, (str, int, float)) and not isinstance(v, bool)]
        elif isinstance(values, (str, int, float)) and not isinstance(values, bool):
            values = [str(values)]
        else:
            continue
        if values:
            filtered[key] = values
    return filtered


class QuotaCacheService:
    """Framework-agnostic request handling — every branch in the contract lives
    here so it can be exercised directly by tests without a real socket."""

    def __init__(
        self,
        pools: Dict[str, PoolRuntime],
        store: CacheStore,
        *,
        now: Any = time.time,
        upstream_semaphore: Optional[threading.Semaphore] = None,
        failure_backoff_seconds: float = 30.0,
        failure_backoff_max_seconds: float = 1800.0,
        max_retry_after_seconds: float = 604_800.0,
    ) -> None:
        self._pools = pools
        self._store = store
        self._now = now
        self._semaphore = upstream_semaphore or threading.Semaphore(8)
        self._failure_backoff_seconds = failure_backoff_seconds
        self._failure_backoff_max_seconds = failure_backoff_max_seconds
        # A deliberately much more generous cap than the exponential-backoff
        # ceiling (`failure_backoff_max_seconds`, typically 30 minutes): an
        # upstream-provided `Retry-After` is a real, explicit signal (unlike a
        # guessed exponential delay) and must be honored close to as-is, or a
        # request would prematurely retry an account upstream already asked to
        # be left alone for longer — this only guards against a truly
        # implausible value. Defaults to 7 days, matching the largest real
        # quota-window magnitude observed from these upstreams (a weekly reset
        # window); a genuine `Retry-After` should never legitimately exceed it.
        self._max_retry_after_seconds = max_retry_after_seconds
        self._inflight: Dict[tuple, threading.Event] = {}
        self._inflight_lock = threading.Lock()
        self.metrics = {"hits": 0, "upstream_calls": 0, "coalesced": 0, "errors": 0}
        self._metrics_lock = threading.Lock()

    def _bump(self, key: str) -> None:
        with self._metrics_lock:
            self.metrics[key] += 1

    def _is_fresh(self, resource_name: str, row: CacheRow, now: float) -> bool:
        """A cached success is fresh only until whichever comes first: the
        resource's own flat TTL, or the reset boundary of any quota window
        actually present in the cached body (`window_reset_bound`). Crossing
        a window's own reset means the percentages inside it are no longer a
        reading of the *current* window even though the flat TTL has not
        elapsed yet, so this must fall through to a real upstream refresh —
        never synthesize a "reset" reading here. A window this cache cannot
        determine a reset time for contributes no bound, so it never forces
        staleness on a guessed schedule (see `window_reset_bound`'s own
        doc comment for why a weekly-only account is never constrained by a
        fictitious five-hour boundary this way either).
        """
        if not row.has_success:
            return False
        ttl_bound = row.fetched_at + RESOURCES[resource_name].ttl_seconds
        window_bound = window_reset_bound(resource_name, row.body, row.fetched_at)
        fresh_until = ttl_bound if window_bound is None else min(ttl_bound, window_bound)
        return now < fresh_until

    def handle(
        self, pool_name: str, resource_name: str, auth_index: Optional[str], require_fresh: bool
    ) -> Dict[str, Any]:
        pool = self._pools.get(pool_name)
        if pool is None:
            raise ServiceError(404, "unknown_pool")
        spec = RESOURCES.get(resource_name)
        if spec is None:
            raise ServiceError(404, "unknown_resource")
        if not auth_index or not _AUTH_INDEX_RE.match(auth_index):
            raise ServiceError(400, "bad_request")

        account = pool.resolver.resolve(auth_index, now=self._now())
        if account is None:
            raise ServiceError(404, "unknown_account")
        if account.disabled:
            raise ServiceError(403, "account_disabled")
        if account.provider != spec.provider:
            raise ServiceError(400, "provider_mismatch")

        key = (pool_name, resource_name, auth_index)
        row = self._store.get(pool_name, resource_name, auth_index)
        if row is not None and row.identity != account.identity:
            self._store.delete(pool_name, resource_name, auth_index)
            row = None

        now = self._now()
        # TTL-fresh data is served to every caller, `require_fresh` or not — the
        # whole point of the cache is that a scheduler polling on a schedule no
        # longer needs its own upstream call just because it asked for
        # freshness; `require_fresh` only changes what happens once the entry
        # actually has gone stale (see below).
        if row is not None and self._is_fresh(resource_name, row, now):
            self._bump("hits")
            return self._envelope(row, stale=False)

        if row is not None and row.next_retry_at is not None and now < row.next_retry_at:
            if row.has_success and not require_fresh:
                self._bump("hits")
                return self._envelope(row, stale=True)
            raise ServiceError(503, "not_ready", _failure_payload(row))

        self._refresh(pool, spec, resource_name, auth_index, account, key)

        row = self._store.get(pool_name, resource_name, auth_index)
        if row is not None and row.has_success:
            fresh = row.next_retry_at is None and self._is_fresh(resource_name, row, self._now())
            if fresh or not require_fresh:
                return self._envelope(row, stale=not fresh)
        raise ServiceError(503, "upstream_unavailable", _failure_payload(row))

    def _envelope(self, row: CacheRow, *, stale: bool) -> Dict[str, Any]:
        header = json.loads(row.header_json) if row.header_json else {}
        envelope = {
            "result": {"status_code": row.status_code, "header": header, "body": row.body},
            "fetched_at": row.fetched_at,
            "stale": stale,
            "last_attempt": row.last_attempt,
            "next_retry_at": row.next_retry_at,
        }
        failure = _failure_payload(row)
        if failure is not None:
            envelope["failure"] = failure
        return envelope

    def _refresh(
        self,
        pool: PoolRuntime,
        spec: Any,
        resource_name: str,
        auth_index: str,
        account: ResolvedAccount,
        key: tuple,
    ) -> None:
        with self._inflight_lock:
            event = self._inflight.get(key)
            if event is not None:
                is_leader = False
            else:
                event = threading.Event()
                self._inflight[key] = event
                is_leader = True

        if not is_leader:
            self._bump("coalesced")
            event.wait(timeout=60)
            return

        try:
            # A request can observe a stale/backing-off row in `handle()`, then
            # lose the race to become leader here until *after* an earlier
            # leader already finished refreshing that same key (the earlier
            # leader's `finally` below already popped `key` out of `_inflight`
            # by the time this one acquires the lock above). Re-check right
            # here, under the current time, before spending another real
            # upstream call on data that just became fresh — otherwise a burst
            # of late-arriving concurrent requests can each trigger their own
            # redundant round-trip to origin, one after another.
            existing = self._store.get(pool.name, resource_name, auth_index)
            now = self._now()
            if existing is not None and existing.identity == account.identity:
                if self._is_fresh(resource_name, existing, now):
                    return
                if existing.next_retry_at is not None and now < existing.next_retry_at:
                    return
            self._do_refresh(pool, spec, resource_name, auth_index, account)
        finally:
            event.set()
            with self._inflight_lock:
                self._inflight.pop(key, None)

    def _do_refresh(
        self, pool: PoolRuntime, spec: Any, resource_name: str, auth_index: str, account: ResolvedAccount
    ) -> None:
        existing = self._store.get(pool.name, resource_name, auth_index)
        expected_generation = existing.generation if existing else None
        header = dict(spec.headers)
        if spec.account_header and account.account:
            header[spec.account_header] = account.account

        self._bump("upstream_calls")
        attempted_at = self._now()
        with self._semaphore:
            try:
                status, resp_header, body = pool.upstream.api_call(auth_index, spec.method, spec.url, header)
            except UpstreamError:
                self._record_failure(pool, resource_name, auth_index, account, attempted_at, {}, expected_generation)
                return

        # The account may have been replaced (or disabled) while the upstream
        # call was in flight; force a genuinely new listing rather than one
        # that might still be within the resolver's own short TTL, so this
        # decision is never made against a mapping that is already stale by up
        # to `auth_files_ttl_seconds`. Refuse to write a result for an identity
        # that is no longer current, rather than overwrite a newer account's
        # state.
        current = pool.resolver.resolve(auth_index, now=self._now(), force_refresh=True)
        if current is None or current.identity != account.identity or current.disabled:
            self._bump("errors")
            return

        if 200 <= status < 300:
            sanitized = sanitize_body(resource_name, body)
            if sanitized is None:
                # A 2xx with a body that doesn't parse/shape into anything this
                # resource actually needs is not a usable reading — treat it
                # exactly like an upstream failure (backoff, never overwrite an
                # existing success) instead of caching a bogus "success".
                self._record_failure(pool, resource_name, auth_index, account, attempted_at, resp_header, expected_generation)
                return
            self._store.record_success(
                pool.name, resource_name, auth_index, account.identity,
                status_code=status, header_json=json.dumps(_filtered_response_headers(resp_header)), body=sanitized,
                fetched_at=attempted_at, expected_generation=expected_generation,
            )
        else:
            self._record_failure(
                pool, resource_name, auth_index, account, attempted_at, resp_header,
                expected_generation, status=status, body=body,
            )

    def _record_failure(
        self,
        pool: PoolRuntime,
        resource_name: str,
        auth_index: str,
        account: ResolvedAccount,
        attempted_at: float,
        header: Dict[str, Any],
        expected_generation: Optional[int],
        *,
        status: Optional[int] = None,
        body: str = "",
    ) -> None:
        self._bump("errors")
        existing = self._store.get(pool.name, resource_name, auth_index)
        failures = (existing.consecutive_failures + 1) if existing and existing.identity == account.identity else 1
        retry_after = _retry_after_seconds(header, attempted_at)
        if retry_after is not None:
            backoff = min(retry_after, self._max_retry_after_seconds)
        else:
            # `failures` grows without bound for an account that keeps failing
            # for the service's entire uptime; capping the exponent (rather
            # than the already-computed power) avoids computing an enormous
            # integer and then raising `OverflowError` converting it to a
            # float — the backoff is clamped to `failure_backoff_max_seconds`
            # right after anyway, so nothing beyond a small exponent ever
            # matters.
            capped_exponent = min(failures - 1, 32)
            backoff = min(self._failure_backoff_seconds * (2 ** capped_exponent), self._failure_backoff_max_seconds)
        failure_kind, failure_status_code = _classified_auth_failure(status, body)
        self._store.record_failure(
            pool.name, resource_name, auth_index, account.identity,
            attempted_at=attempted_at, next_retry_at=attempted_at + backoff, consecutive_failures=failures,
            expected_generation=expected_generation,
            failure_kind=failure_kind, failure_status_code=failure_status_code,
        )

    def authorize(self, pool_name: str, authorization_header: Optional[str]) -> bool:
        pool = self._pools.get(pool_name)
        if pool is None or not authorization_header or not authorization_header.startswith("Bearer "):
            return False
        token = authorization_header[len("Bearer "):]
        return hmac.compare_digest(token, pool.management_key)

    def authorize_any_pool(self, authorization_header: Optional[str]) -> bool:
        """Used by `/quota-cache/health`, which has no `{pool}` in its path: any
        one configured pool's own management key is accepted. A loopback peer
        alone (the other half of that endpoint's gate, see `_handle_health`) is
        not a trustworthy boundary by itself — a same-host reverse-tunnel
        process (e.g. cloudflared) also connects from loopback, so an
        unauthenticated observer reaching this service *through* one would
        otherwise see it as a local, implicitly-trusted caller."""
        if not authorization_header or not authorization_header.startswith("Bearer "):
            return False
        token = authorization_header[len("Bearer "):]
        return any(hmac.compare_digest(token, pool.management_key) for pool in self._pools.values())


def _parse_path(path: str) -> Optional[Tuple[str, str]]:
    parts = [p for p in path.split("/") if p]
    if len(parts) != 4 or parts[0] != "quota-cache" or parts[1] != "v1":
        return None
    return parts[2], parts[3]


class _Handler(BaseHTTPRequestHandler):
    service: QuotaCacheService  # set by make_server
    # A bounded semaphore, not an unbounded thread pool: `ThreadingHTTPServer`
    # still spawns one OS thread per accepted connection (no extra dependency
    # needed to change that), but every one of those threads must acquire this
    # slot before doing any real work — once the configured concurrency is in
    # use, a new request fails fast with `503 busy` instead of piling up
    # unboundedly behind the upstream semaphore. Set by `make_server`.
    request_slots: threading.Semaphore

    def log_message(self, format: str, *args: Any) -> None:  # noqa: A002
        LOG.info("%s - %s", self.address_string(), format % args)

    def _send_json(self, status: int, payload: Dict[str, Any]) -> None:
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:  # noqa: N802
        if not self.request_slots.acquire(timeout=0.5):
            self._send_json(503, {"error": "busy"})
            return
        try:
            self._do_GET()
        finally:
            self.request_slots.release()

    def _do_GET(self) -> None:
        split = urlsplit(self.path)
        if split.path == "/quota-cache/health":
            self._handle_health()
            return

        parsed = _parse_path(split.path)
        if parsed is None:
            self._send_json(404, {"error": "not_found"})
            return
        pool_name, resource_name = parsed

        if not self.service.authorize(pool_name, self.headers.get("Authorization")):
            self._send_json(401, {"error": "unauthorized"})
            return

        query = parse_qs(split.query, keep_blank_values=True)
        allowed_params = {"auth_index", "require_fresh"}
        if any(k not in allowed_params for k in query):
            self._send_json(400, {"error": "bad_request"})
            return
        auth_index_values = query.get("auth_index") or []
        if len(auth_index_values) != 1:
            self._send_json(400, {"error": "bad_request"})
            return
        require_fresh = (query.get("require_fresh") or ["0"])[0] == "1"

        try:
            envelope = self.service.handle(pool_name, resource_name, auth_index_values[0], require_fresh)
        except ServiceError as exc:
            payload: Dict[str, Any] = {"error": exc.code}
            if exc.failure is not None:
                payload["failure"] = exc.failure
            self._send_json(exc.http_status, payload)
            return
        except Exception as exc:
            # Never log the exception message/traceback: either can embed
            # request/response content (a body, a header, an account identity)
            # depending on where the failure happened. A fixed error code plus
            # the exception's own class name is enough to diagnose from
            # metrics/alerts without risking that leak.
            LOG.error("unhandled error: %s", type(exc).__name__)
            self._send_json(500, {"error": "internal_error"})
            return
        self._send_json(200, envelope)

    def _handle_health(self) -> None:
        peer = self.client_address[0]
        if peer not in ("127.0.0.1", "::1"):
            self._send_json(403, {"error": "forbidden"})
            return
        # Loopback alone is not a trustworthy boundary here — see
        # `QuotaCacheService.authorize_any_pool`'s docstring — so this also
        # requires a real pool key, on top of the loopback check kept as
        # defense in depth.
        if not self.service.authorize_any_pool(self.headers.get("Authorization")):
            self._send_json(401, {"error": "unauthorized"})
            return
        self._send_json(200, dict(self.service.metrics))

    def do_POST(self) -> None:  # noqa: N802
        self._send_json(405, {"error": "method_not_allowed"})

    do_PUT = do_POST
    do_DELETE = do_POST
    do_PATCH = do_POST


def make_server(
    host: str, port: int, service: QuotaCacheService, *, max_concurrent_requests: int = 64
) -> ThreadingHTTPServer:
    handler = type(
        "_BoundHandler", (_Handler,),
        {"service": service, "request_slots": threading.Semaphore(max_concurrent_requests)},
    )
    server = ThreadingHTTPServer((host, port), handler)
    server.daemon_threads = True
    return server


def build_pools(config: Dict[str, Any]) -> Dict[str, PoolRuntime]:
    import cpa_quota_recovery as qr

    pools: Dict[str, PoolRuntime] = {}
    timeout = float(config.get("upstream_timeout_seconds", 10))
    max_bytes = int(config.get("max_upstream_response_bytes", 1_048_576))
    auth_files_ttl = float(config.get("auth_files_ttl_seconds", 5))
    for name, pool_cfg in config["pools"].items():
        secret_key = str(pool_cfg.get("secret_key") or "CLIPROXYAPI_MANAGEMENT_KEY")
        management_key = qr.read_management_key(str(pool_cfg["secrets_env"]), secret_key)
        upstream = CPAUpstreamClient(str(pool_cfg["base_url"]), management_key, timeout, max_bytes)
        # A dedicated client with the same key drives the auth-files listing —
        # ManagementClient already exists for exactly this purpose.
        management_client = qr.ManagementClient(str(pool_cfg["base_url"]), management_key, timeout)
        resolver = AuthFileResolver(management_client, ttl_seconds=auth_files_ttl)
        pools[name] = PoolRuntime(name=name, management_key=management_key, upstream=upstream, resolver=resolver)
    return pools


def main(argv: Optional[list] = None) -> int:
    parser = argparse.ArgumentParser(description="Quotio quota-cache service")
    parser.add_argument("--config", "-c", required=True)
    args = parser.parse_args(argv)

    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")

    with open(args.config, "r", encoding="utf-8") as fh:
        config = json.load(fh)

    pools = build_pools(config)
    default_state_db = os.path.expanduser("~/.local/state/quotio-quota-cache/state.db")
    store = CacheStore(str(config.get("state_db") or default_state_db))
    service = QuotaCacheService(
        pools, store,
        upstream_semaphore=threading.Semaphore(int(config.get("max_concurrent_upstream_calls", 8))),
        failure_backoff_seconds=float(config.get("failure_backoff_seconds", 30)),
        failure_backoff_max_seconds=float(config.get("failure_backoff_max_seconds", 1800)),
        max_retry_after_seconds=float(config.get("max_retry_after_seconds", 604_800)),
    )
    host = str(config.get("listen_host", "127.0.0.1"))
    port = int(config.get("listen_port", 8328))
    server = make_server(
        host, port, service, max_concurrent_requests=int(config.get("max_concurrent_requests", 64))
    )
    LOG.info("quota-cache listening on %s:%d", host, port)
    try:
        server.serve_forever()
    finally:
        store.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
