"""Whitelisted quota-cache resources.

Every resource this service will ever fetch is enumerated here — never derived
from a client request. This is what makes the service's outbound side immune to
SSRF: the URL and header shape depend only on the resource name, never on
anything the caller sends. Each resource also carries an explicit allowlist of
response fields to persist, so a profile response's email/identity fields, or
any field a mapper does not actually need, is never written to disk.

Mirrors the same upstream endpoints Quotio's `RemoteManagementQuotaFetcher`
(Packages/QuotioCore/Sources/QuotioInfrastructure/Quota/RemoteManagementQuotaFetcher.swift)
already calls through CLIProxyAPI's `/api-call` pass-through.
"""

from __future__ import annotations

import math
from dataclasses import dataclass, field
from typing import Any, Dict, List, Optional


@dataclass(frozen=True)
class ResourceSpec:
    provider: str  # "claude" | "codex" | "grok" — must match the auth-file's own provider.
    method: str
    url: str
    ttl_seconds: float
    # Extra static headers sent upstream. "$TOKEN$" is CLIProxyAPI's own
    # placeholder, substituted server-side by CLIProxyAPI itself — the real
    # provider token never reaches this service either.
    headers: Dict[str, str]
    # Set when the resource needs the auth-file's own "account" field forwarded
    # as a header (Codex's ChatGPT-Account-Id) — never anything client-supplied.
    account_header: Optional[str] = None
    # Dotted paths (dicts only, "." separated, "*" for "every list element") kept
    # when persisting a successful response body. Everything else is dropped.
    keep_paths: List[str] = field(default_factory=list)


RESOURCES: Dict[str, ResourceSpec] = {
    "codex-usage": ResourceSpec(
        provider="codex",
        method="GET",
        url="https://chatgpt.com/backend-api/wham/usage",
        ttl_seconds=300,
        headers={"Authorization": "Bearer $TOKEN$", "Accept": "application/json"},
        account_header="ChatGPT-Account-Id",
        # Field names verified against the actual consumers of this resource, not
        # guessed: `CodexQuotaFetcher.mapUsage`'s `Response`/`Limit`/`Window`/
        # `Additional` Codable types (RemoteManagementQuotaFetcher.swift /
        # CodexQuotaFetcher.swift) and `cpa_newapi_balance.py`'s `collect_pool`
        # (which also reads `rate_limit.allowed`, not just `limit_reached`). Real
        # upstream window shape is `{used_percent, limit_window_seconds, reset_at,
        # reset_after_seconds}` — there is no `window_minutes`/`resets_in_seconds`.
        keep_paths=[
            "plan_type",
            "rate_limit.limit_reached",
            "rate_limit.allowed",
            "rate_limit.primary_window.used_percent",
            "rate_limit.primary_window.limit_window_seconds",
            "rate_limit.primary_window.reset_at",
            "rate_limit.primary_window.reset_after_seconds",
            "rate_limit.secondary_window.used_percent",
            "rate_limit.secondary_window.limit_window_seconds",
            "rate_limit.secondary_window.reset_at",
            "rate_limit.secondary_window.reset_after_seconds",
            "additional_rate_limits.*.limit_name",
            "additional_rate_limits.*.metered_feature",
            "additional_rate_limits.*.rate_limit.limit_reached",
            "additional_rate_limits.*.rate_limit.primary_window.used_percent",
            "additional_rate_limits.*.rate_limit.primary_window.limit_window_seconds",
            "additional_rate_limits.*.rate_limit.primary_window.reset_at",
            "additional_rate_limits.*.rate_limit.primary_window.reset_after_seconds",
            "additional_rate_limits.*.rate_limit.secondary_window.used_percent",
            "additional_rate_limits.*.rate_limit.secondary_window.limit_window_seconds",
            "additional_rate_limits.*.rate_limit.secondary_window.reset_at",
            "additional_rate_limits.*.rate_limit.secondary_window.reset_after_seconds",
            "credits.balance",
            "credits.has_credits",
            "rate_limit_reset_credits.available_count",
        ],
    ),
    "codex-reset-credits": ResourceSpec(
        provider="codex",
        method="GET",
        url="https://chatgpt.com/backend-api/wham/rate-limit-reset-credits",
        ttl_seconds=1800,
        headers={
            "Authorization": "Bearer $TOKEN$",
            "Accept": "application/json",
            "OpenAI-Beta": "codex-1",
            "originator": "Codex Desktop",
        },
        account_header="ChatGPT-Account-Id",
        keep_paths=["available_count", "credits.*.id", "credits.*.status", "credits.*.expires_at"],
    ),
    "claude-usage": ResourceSpec(
        provider="claude",
        method="GET",
        url="https://api.anthropic.com/api/oauth/usage",
        ttl_seconds=300,
        headers={
            "Authorization": "Bearer $TOKEN$",
            "Accept": "application/json",
            "Content-Type": "application/json",
            "anthropic-beta": "oauth-2025-04-20",
            "User-Agent": "claude-code/2.1.69",
        },
        keep_paths=[
            "type",
            "five_hour.utilization",
            "five_hour.resets_at",
            "seven_day.utilization",
            "seven_day.resets_at",
            "seven_day_sonnet.utilization",
            "seven_day_sonnet.resets_at",
            "seven_day_opus.utilization",
            "seven_day_opus.resets_at",
            "extra_usage.is_enabled",
            "extra_usage.utilization",
            "extra_usage.used_credits",
            "extra_usage.monthly_limit",
        ],
    ),
    "claude-profile": ResourceSpec(
        provider="claude",
        method="GET",
        url="https://api.anthropic.com/api/oauth/profile",
        ttl_seconds=1800,
        headers={
            "Authorization": "Bearer $TOKEN$",
            "Accept": "application/json",
            "Content-Type": "application/json",
            "anthropic-beta": "oauth-2025-04-20",
            "User-Agent": "claude-code/2.1.69",
        },
        # Deliberately excludes every identity field (email, uuid, org name) the
        # real profile response carries — only the plan-determining flags survive.
        keep_paths=["account.has_claude_pro", "account.has_claude_max", "organization.organization_type"],
    ),
    "grok-usage": ResourceSpec(
        provider="grok",
        method="GET",
        url="https://cli-chat-proxy.grok.com/v1/billing?format=credits",
        ttl_seconds=300,
        headers={
            "Authorization": "Bearer $TOKEN$",
            "X-XAI-Token-Auth": "xai-grok-cli",
            "Accept": "application/json",
            "User-Agent": "Quotio",
        },
        keep_paths=[
            "config.currentPeriod.type",
            "config.currentPeriod.end",
            "config.creditUsagePercent",
            "config.onDemandCap.val",
        ],
    ),
    "grok-settings": ResourceSpec(
        provider="grok",
        method="GET",
        url="https://cli-chat-proxy.grok.com/v1/settings",
        ttl_seconds=1800,
        headers={
            "Authorization": "Bearer $TOKEN$",
            "X-XAI-Token-Auth": "xai-grok-cli",
            "Accept": "application/json",
            "User-Agent": "Quotio",
        },
        keep_paths=["subscription_tier_display"],
    ),
}


def sanitize_body(resource: str, raw_body: str) -> Optional[str]:
    """Filters a raw upstream JSON body down to `keep_paths` before it is ever
    persisted. Returns `None` — never the raw body, never a guess — when the
    body cannot be trusted as a real, structured success: not valid JSON, a
    non-finite `NaN`/`Infinity` JSON extension, not a JSON object, an object
    that matched none of `keep_paths` at all (an upstream 2xx with a body
    shaped nothing like this resource is not a usable reading), or a value
    that matched a `keep_paths` field name but fails `_validate_structure`
    (a boolean masquerading as a percentage, an out-of-range percentage, or a
    non-finite/negative duration), or a body that only matched cosmetic
    fields (e.g. a bare `plan_type`, or `rate_limit: {}`) without carrying an
    actual usage window (`_has_valid_usage_window`). Passing the allowlist
    only proves a field's *name* was expected; it never proves the *value* is
    a real reading, which is what actually gates whether this response may
    overwrite the last known-good cached success. The caller MUST treat a
    `None` return exactly like an upstream failure — it must never be
    persisted or reported as a success.
    """
    import json

    spec = RESOURCES[resource]
    try:
        parsed = json.loads(raw_body, parse_constant=_reject_non_finite_constant)
    except (ValueError, TypeError):
        return None
    if not isinstance(parsed, dict):
        return None
    kept: Dict[str, Any] = {}
    for path in spec.keep_paths:
        _copy_path(parsed, path.split("."), kept)
    if (
        not kept
        or not _all_finite(kept)
        or not _validate_structure(kept)
        or not _has_valid_usage_window(resource, kept)
    ):
        return None
    return json.dumps(kept, sort_keys=True)


# Field names validated by `_validate_structure` below, keyed by the kind of
# check they need. Matched by leaf key name only (not by full dotted path) —
# every one of these names means the same thing everywhere it appears across
# every resource's `keep_paths` (e.g. `additional_rate_limits.*.rate_limit.
# primary_window.used_percent` is exactly as much a percentage as the
# top-level `rate_limit.primary_window.used_percent`).
_PERCENT_KEYS = {"used_percent", "utilization"}
_DURATION_KEYS = {"reset_after_seconds", "limit_window_seconds"}
_TIMESTAMP_KEYS = {"reset_at", "resets_at"}
# Fields that are only ever a plain JSON boolean when present. Unlike the
# percent/duration/timestamp keys above, a `bool` field carries no "window
# exists but its reading is unknown" case worth distinguishing — there is no
# such thing as "the flag exists but its value is unknown" the way an
# optional *window* can legitimately be `null`, so an explicit `null` here is
# rejected exactly like a string/container/number would be. A field that
# never appears in the upstream body at all is simply absent from `kept` and
# never reaches this check in the first place.
_BOOL_KEYS = {"limit_reached", "allowed", "has_credits", "is_enabled", "has_claude_pro", "has_claude_max"}

# codex-usage/claude-usage windows a resource-level check (`_has_valid_usage_window`
# below) requires at least one of, present with a genuinely numeric reading —
# see that function's own doc comment for why `_validate_structure` alone
# cannot enforce this.
_CODEX_WINDOW_KEYS = ("primary_window", "secondary_window")
_CLAUDE_WINDOW_KEYS = ("five_hour", "seven_day", "seven_day_sonnet", "seven_day_opus")


def _validate_structure(value: Any, key: Optional[str] = None) -> bool:
    """Rejects a value that matched a `keep_paths` field name but isn't
    actually trustworthy as that field. The type check for a recognized
    scalar field name (`key` in one of the sets above) always runs *before*
    any dict/list recursion, so a field that should be a number/string/bool
    but instead arrived as a container (e.g. `used_percent: {}` or
    `used_percent: []`) is rejected outright rather than recursed into and
    vacuously accepted (an empty dict/list satisfies `all(...)` over nothing).
    Only a field name this module does not otherwise recognize is treated as
    a genuine nested container and recursed into.

    JSON's `true`/`false` decode to Python `bool`, which `isinstance(x, (int,
    float))` alone cannot tell apart from a real number (`bool` subclasses
    `int`) — so a percentage or duration that arrived as a boolean must be
    checked for explicitly. A percentage outside `[0, 100]` and a
    negative/non-finite duration are rejected the same way.

    A *window* that is legitimately absent (`None`, e.g. an account with no
    five-hour limit reporting `secondary_window: null`) is never a violation.
    A percentage is different: `used_percent` is a required numeric reading
    of a window that does exist, so an explicit `null` there (as opposed to
    the whole window being `null`) is rejected, not treated as optional —
    this is the distinction between an optional absent *window* and a
    required-but-missing *value* inside a present one.
    """
    # Disabled optional paid extra usage legitimately has null utilization.
    # This exception does not apply to actual quota windows or enabled usage.
    if key == "extra_usage" and isinstance(value, dict) and value.get("is_enabled") is False:
        return all(_validate_structure(v, k) for k, v in value.items()
                   if not (k == "utilization" and v is None))
    if key in _PERCENT_KEYS:
        if isinstance(value, bool) or not isinstance(value, (int, float)):
            return False
        return math.isfinite(value) and 0 <= value <= 100
    if key in _DURATION_KEYS:
        if value is None:
            return True
        if isinstance(value, bool) or not isinstance(value, (int, float)):
            return False
        return math.isfinite(value) and value >= 0
    if key in _TIMESTAMP_KEYS:
        if value is None:
            return True
        if isinstance(value, bool):
            return False
        if isinstance(value, (int, float)):
            return math.isfinite(value) and value > 0
        if isinstance(value, str):
            # Must actually parse as one of the formats `_window_bound` below
            # can consume (Codex's `reset_at` as a unix epoch arrives as a
            # JSON number, handled above; Claude's `resets_at` arrives as
            # ISO-8601) — a non-empty-but-unparsable string like `"not-a-date"`
            # is garbage, not a timestamp, and must not pass just because it
            # is non-blank.
            return _parse_iso8601(value) is not None
        return False
    if key in _BOOL_KEYS:
        return isinstance(value, bool)
    if value is None:
        return True
    if isinstance(value, dict):
        return all(_validate_structure(v, k) for k, v in value.items())
    if isinstance(value, list):
        return all(_validate_structure(item, key) for item in value)
    return True


def _has_valid_usage_window(resource: str, kept: Dict[str, Any]) -> bool:
    """`_validate_structure` only proves that whichever fields *are* present
    in `kept` are well-typed — it says nothing about whether `kept` actually
    carries a usage reading at all. A raw body containing only `plan_type`,
    or a `rate_limit: {}` with neither window present, matches at least one
    `keep_paths` entry (so `sanitize_body`'s emptiness check does not catch
    it) and has nothing left for `_validate_structure` to reject, so it would
    otherwise sanitize "successfully" and overwrite the last known-good
    cached snapshot with a reading that carries no actual quota signal.

    `codex-usage` requires a `rate_limit` object with at least one of
    `primary_window`/`secondary_window` present and carrying a numeric
    `used_percent` (a `None` window — no five-hour limit on this account — is
    fine and simply does not count towards "at least one"). `claude-usage`
    requires the analogous non-null `utilization` in at least one of its
    known usage windows. Every other resource (profile/reset-credits/grok-*)
    carries no such window concept and is left to `_validate_structure` alone.

    Critically, a *present* (non-null) window that lacks a genuine numeric
    reading (e.g. `secondary_window: {}`, with no `used_percent` inside) must
    reject the whole body even when its sibling window is perfectly valid —
    `_validate_structure` alone would wrongly accept this, since it recurses
    into `{}` and `all(...)` over zero items is vacuously true. One good
    window must never excuse a malformed sibling from being caught.
    """
    if resource == "codex-usage":
        rate_limit = kept.get("rate_limit")
        if not isinstance(rate_limit, dict):
            return False
        return _all_present_windows_have_valid_reading(
            (rate_limit.get(name) for name in _CODEX_WINDOW_KEYS), "used_percent"
        )
    if resource == "claude-usage":
        return _all_present_windows_have_valid_reading(
            (kept.get(name) for name in _CLAUDE_WINDOW_KEYS), "utilization"
        )
    return True


def _all_present_windows_have_valid_reading(windows: Any, percent_key: str) -> bool:
    """Every window in `windows` that is *present* (non-null) must itself be
    an object carrying a genuinely numeric `percent_key` reading; a window
    that is `None` (legitimately absent, e.g. no five-hour limit on this
    account) contributes nothing and is skipped. At least one present, valid
    window is still required overall — an all-absent set of windows carries
    no quota signal at all.
    """
    saw_valid = False
    for window in windows:
        if window is None:
            continue
        if not isinstance(window, dict):
            return False
        value = window.get(percent_key)
        if not isinstance(value, (int, float)) or isinstance(value, bool):
            return False
        saw_valid = True
    return saw_valid


def window_reset_bound(resource: str, kept_body_json: Optional[str], fetched_at: float) -> Optional[float]:
    """Returns the earliest absolute epoch at which any quota window actually
    present inside `kept_body_json` (the sanitized body already persisted for
    this resource) resets, or `None` when this resource carries no window
    this cache needs to track (e.g. `claude-profile`, `codex-reset-credits`)
    or none of its windows carry a determinable reset time.

    Used by the cache service to compute the real freshness cutoff as
    `min(fetched_at + ttl_seconds, window_reset_bound(...))`: once *any*
    window inside the cached body has actually rolled over, the percentages
    it reports are no longer a reading of the *current* window even if the
    flat TTL has not elapsed yet, so the cache must treat the entry as stale
    and trigger a real refresh — never synthesize a "reset" percentage itself.

    A window that is legitimately absent (JSON `null` — an account with no
    five-hour limit reporting `secondary_window: null`) contributes no bound,
    which is exactly what lets a weekly-only account's freshness never be
    constrained by a fictitious five-hour boundary. A window that is present
    but carries neither `reset_at`/`resets_at` nor `reset_after_seconds` is
    unknown/corrupted and likewise contributes no bound — it is never treated
    as if it resets in five hours or any other guessed duration.
    """
    if not kept_body_json:
        return None
    import json

    try:
        body = json.loads(kept_body_json)
    except (ValueError, TypeError):
        return None
    if not isinstance(body, dict):
        return None

    windows: List[Dict[str, Any]] = []
    if resource == "codex-usage":
        rate_limit = body.get("rate_limit")
        if isinstance(rate_limit, dict):
            for name in ("primary_window", "secondary_window"):
                window = rate_limit.get(name)
                if isinstance(window, dict):
                    windows.append(window)
        for extra in body.get("additional_rate_limits") or []:
            if not isinstance(extra, dict):
                continue
            extra_rate_limit = extra.get("rate_limit")
            if not isinstance(extra_rate_limit, dict):
                continue
            for name in ("primary_window", "secondary_window"):
                window = extra_rate_limit.get(name)
                if isinstance(window, dict):
                    windows.append(window)
    elif resource == "claude-usage":
        for name in ("five_hour", "seven_day", "seven_day_sonnet", "seven_day_opus"):
            window = body.get(name)
            if isinstance(window, dict):
                windows.append(window)
    else:
        return None

    bounds = [bound for bound in (_window_bound(window, fetched_at) for window in windows) if bound is not None]
    return min(bounds) if bounds else None


def _window_bound(window: Dict[str, Any], fetched_at: float) -> Optional[float]:
    """One window's own reset boundary: an absolute `reset_at`/`resets_at`
    always wins when present (`reset_at` for Codex is a unix epoch;
    `resets_at` for Claude is ISO-8601). Only when neither is present does a
    relative `reset_after_seconds` apply — anchored to `fetched_at` (the
    original upstream fetch time this row was written with), never to
    whatever moment this function happens to be called at, so that reading
    the same still-cached body on a later cache hit never pushes this
    boundary further into the future purely from being read again.
    """
    reset_at = window.get("reset_at")
    if reset_at is None:
        reset_at = window.get("resets_at")
    if isinstance(reset_at, (int, float)) and not isinstance(reset_at, bool) and math.isfinite(reset_at) and reset_at > 0:
        return float(reset_at)
    if isinstance(reset_at, str) and reset_at.strip():
        parsed = _parse_iso8601(reset_at)
        if parsed is not None:
            return parsed
    reset_after = window.get("reset_after_seconds")
    if isinstance(reset_after, (int, float)) and not isinstance(reset_after, bool) and math.isfinite(reset_after) and reset_after >= 0:
        return fetched_at + float(reset_after)
    return None


def _parse_iso8601(value: str) -> Optional[float]:
    from datetime import datetime, timezone

    raw = value.strip()
    if raw.endswith("Z"):
        raw = raw[:-1] + "+00:00"
    try:
        parsed = datetime.fromisoformat(raw)
    except ValueError:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed.timestamp()


def _reject_non_finite_constant(token: str) -> float:
    # json.loads treats "NaN"/"Infinity"/"-Infinity" as valid numbers by
    # default (a non-standard extension) — reject them outright rather than
    # silently persisting a value that isn't valid JSON once re-serialized.
    raise ValueError(f"non-finite JSON constant in upstream body: {token}")


def _all_finite(value: Any) -> bool:
    if isinstance(value, float):
        return math.isfinite(value)
    if isinstance(value, dict):
        return all(_all_finite(v) for v in value.values())
    if isinstance(value, list):
        return all(_all_finite(v) for v in value)
    return True


def _copy_path(source: Any, parts: List[str], dest: Dict[str, Any]) -> None:
    """Copies one dotted `keep_paths` entry from `source` into `dest`, merging
    into whatever an earlier `keep_paths` entry already placed there — several
    entries commonly share the same list (e.g. `credits.*.id` and
    `credits.*.status`), so this must accumulate fields per list index rather
    than overwrite the previous entry's work.
    """
    if not parts:
        return
    head, rest = parts[0], parts[1:]
    if not isinstance(source, dict) or head not in source:
        return
    value = source[head]
    if not rest:
        dest[head] = value
        return
    if rest[0] == "*":
        if not isinstance(value, list):
            return
        kept_list = dest.get(head)
        if not isinstance(kept_list, list):
            kept_list = [{} for _ in value]
            dest[head] = kept_list
        for item, kept_item in zip(value, kept_list):
            if isinstance(item, dict):
                _copy_path(item, rest[1:], kept_item)
        return
    if value is None:
        # A legitimately absent nested window (e.g. `secondary_window: null`
        # for an account with no five-hour limit) must be kept as `None`, not
        # coerced into `{}` — an empty object here would make every consumer
        # that decodes a *present* window as a required, non-optional shape
        # (e.g. `CodexQuotaFetcher.Window`) fail on it, which would then fail
        # the whole surrounding `rate_limit` and silently drop the sibling
        # window that *was* valid.
        dest.setdefault(head, None)
        return
    dest.setdefault(head, {})
    _copy_path(value, rest, dest[head])
