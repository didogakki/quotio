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
    """Raised for any non-200 or unparsable quota-cache response. Callers must
    treat this exactly like an upstream failure — never invent a result."""


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
            exc.read()
        except Exception:
            pass
        raise QuotaCacheError(f"quota-cache returned HTTP {exc.code}") from None
    except urllib.error.URLError as exc:
        raise QuotaCacheError(f"quota-cache unreachable: {exc.reason}") from None
    except OSError as exc:
        raise QuotaCacheError(f"quota-cache request failed: {exc}") from None

    if status != 200:
        raise QuotaCacheError(f"quota-cache returned HTTP {status}")
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
