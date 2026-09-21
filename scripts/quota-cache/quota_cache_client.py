#!/usr/bin/env python3
"""Minimal consumer client for the Quotio quota-cache service.

Shared by `cpa_quota_recovery.py` and `cpa_newapi_balance.py` so both scripts —
and Quotio itself — read one collected value per account/resource instead of
each polling CLIProxyAPI (and, transitively, the real provider) on its own
schedule. Python 3 standard library only, matching every other script here.
"""

from __future__ import annotations

import json
import math
import urllib.error
import urllib.parse
import urllib.request
from typing import Any, Dict


class QuotaCacheError(Exception):
    """A cache failure with an optional fixed, non-sensitive account category."""

    def __init__(
        self,
        message: str,
        *,
        http_status: int | None = None,
        failure_kind: str | None = None,
        failure_status_code: int | None = None,
    ) -> None:
        super().__init__(message)
        self.http_status = http_status
        self.failure_kind = failure_kind
        self.failure_status_code = failure_status_code

    @property
    def is_auth_invalid(self) -> bool:
        return self.failure_kind == "auth_invalid" and self.failure_status_code in (401, 403)


def _safe_failure(body: bytes) -> tuple[str | None, int | None]:
    try:
        payload = json.loads(body.decode("utf-8"))
    except (ValueError, UnicodeDecodeError):
        return None, None
    failure = payload.get("failure") if isinstance(payload, dict) else None
    if not isinstance(failure, dict) or failure.get("kind") != "auth_invalid":
        return None, None
    status = failure.get("status_code")
    if isinstance(status, bool) or status not in (401, 403):
        return None, None
    return "auth_invalid", status


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args: Any, **kwargs: Any) -> None:  # noqa: D401
        return None


def fetch(
    cache_base_url: str,
    management_key: str,
    resource: str,
    auth_index: str,
    *,
    require_fresh: bool = False,
    timeout: float = 10.0,
) -> Dict[str, Any]:
    """GETs `{cache_base_url}/{resource}?auth_index=...[&require_fresh=1]` and
    returns the decoded envelope: `{"result": {"status_code", "header", "body"},
    "fetched_at", "stale", "last_attempt", "next_retry_at"}`.

    `require_fresh=True` is for callers that make a decision from the result
    (quota recovery, account weighting) — the service returns HTTP 503 instead
    of stale data when it cannot confirm freshness, which surfaces here as a
    `QuotaCacheError`, never as a fabricated/old result.
    """
    base = cache_base_url.rstrip("/")
    query = {"auth_index": auth_index}
    if require_fresh:
        query["require_fresh"] = "1"
    url = f"{base}/{resource}?{urllib.parse.urlencode(query)}"
    request = urllib.request.Request(
        url, method="GET", headers={"Authorization": f"Bearer {management_key}"}
    )
    opener = urllib.request.build_opener(_NoRedirect())
    try:
        with opener.open(request, timeout=timeout) as response:
            status = response.getcode()
            body = response.read()
    except urllib.error.HTTPError as exc:
        try:
            error_body = exc.read(16_384)
        except Exception:
            error_body = b""
        failure_kind, failure_status_code = _safe_failure(error_body)
        raise QuotaCacheError(
            f"quota-cache returned HTTP {exc.code}",
            http_status=exc.code,
            failure_kind=failure_kind,
            failure_status_code=failure_status_code,
        ) from None
    except urllib.error.URLError as exc:
        raise QuotaCacheError(f"quota-cache unreachable: {exc.reason}") from None
    except OSError as exc:
        raise QuotaCacheError(f"quota-cache request failed: {exc}") from None

    if status != 200:
        failure_kind, failure_status_code = _safe_failure(body)
        raise QuotaCacheError(
            f"quota-cache returned HTTP {status}",
            http_status=status,
            failure_kind=failure_kind,
            failure_status_code=failure_status_code,
        )
    try:
        envelope = json.loads(body.decode("utf-8"))
    except (ValueError, UnicodeDecodeError) as exc:
        raise QuotaCacheError("quota-cache returned invalid JSON") from exc
    if not isinstance(envelope, dict) or not isinstance(envelope.get("result"), dict):
        raise QuotaCacheError("quota-cache returned a malformed envelope")
    result = envelope["result"]
    if not isinstance(result.get("status_code"), int) or isinstance(result.get("status_code"), bool):
        raise QuotaCacheError("quota-cache result is missing a valid status_code")
    if not isinstance(result.get("body"), str):
        raise QuotaCacheError("quota-cache result is missing a body")
    fetched_at = envelope.get("fetched_at")
    if (
        not isinstance(fetched_at, (int, float))
        or isinstance(fetched_at, bool)
        or not math.isfinite(fetched_at)
    ):
        raise QuotaCacheError("quota-cache envelope is missing a valid fetched_at")
    if require_fresh and envelope.get("stale") is not False:
        # Belt-and-suspenders: the service's own contract already guarantees
        # `require_fresh=1` never returns HTTP 200 with `stale: true` (it
        # returns 503 instead — see service.py's `handle`). A caller on this
        # path makes a real decision (quota recovery, account weighting) from
        # the result, so it must never trust a 200 status code alone; a future
        # service bug, a version mismatch, or a misbehaving cache endpoint
        # must still never be silently treated as a confirmed-fresh reading.
        raise QuotaCacheError("quota-cache returned a non-fresh result for a require_fresh request")
    return envelope
