#!/usr/bin/env python3
"""CPA quota recovery tool.

Host-side helper for CLIProxyAPI (CPA) that probes Claude and Codex OAuth
accounts whose routing state has gone non-active (quota cooling) and, once the
upstream provider confirms the quota window has actually recovered, clears the
local cooldown via the CPA Management API.

Design constraints (see README.md):
  * Python 3 standard library only.
  * Default behaviour is a dry run. Quota is reset only with --apply.
  * The management key, upstream token, Authorization header, cookies and the
    raw upstream response body are kept in memory only and are NEVER logged.
  * Any uncertainty (missing fields, parse error, non-2xx, 401/403/429/5xx)
    results in NO reset.
"""

from __future__ import annotations

import argparse
import json
import logging
import os
import sys
import tempfile
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from typing import Any, Dict, List, Optional, Tuple

import quota_cache_client

LOG = logging.getLogger("cpa-quota-recovery")

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------

DEFAULT_DEBOUNCE_SECONDS = 1800
DEFAULT_GRACE_SECONDS = 120
DEFAULT_REQUEST_TIMEOUT_SECONDS = 30
DEFAULT_FAILURE_BACKOFF_SECONDS = 300
DEFAULT_FAILURE_BACKOFF_MAX_SECONDS = 3600
DEFAULT_STATE_FILE = "/var/lib/cpa-quota-recovery/state.json"
DEFAULT_SECRET_KEY = "CLIPROXYAPI_MANAGEMENT_KEY"

# Provider account types we know how to probe.
SUPPORTED_PROVIDERS = ("claude", "codex")

CLAUDE_USAGE_URL = "https://api.anthropic.com/api/oauth/usage"
CLAUDE_USAGE_HEADERS = {
    "Authorization": "Bearer $TOKEN$",
    "anthropic-beta": "oauth-2025-04-20",
}
# Windows reported by the Anthropic OAuth usage endpoint.
CLAUDE_WINDOWS = ("five_hour", "seven_day", "seven_day_sonnet", "seven_day_opus")
# utilization is reported as a percentage (0-100); >= this counts as exhausted.
CLAUDE_EXHAUSTED_UTILIZATION = 100.0

CODEX_USAGE_URL = "https://chatgpt.com/backend-api/wham/usage"


# ---------------------------------------------------------------------------
# Decision result
# ---------------------------------------------------------------------------


class Decision:
    """Outcome of evaluating a single account."""

    RESET = "reset"  # quota recovered, reset is warranted
    SKIP = "skip"  # not eligible for reset (still cooling / debounced / disabled)
    NO_DATA = "no_data"  # could not determine state -> never reset

    def __init__(self, action: str, reason: str) -> None:
        self.action = action
        self.reason = reason

    def __str__(self) -> str:
        return f"{self.action}:{self.reason}"


# ---------------------------------------------------------------------------
# Helpers: time / parsing
# ---------------------------------------------------------------------------


def now_ts() -> float:
    return time.time()


def iso(ts: Optional[float]) -> Optional[str]:
    if ts is None:
        return None
    return datetime.fromtimestamp(ts, tz=timezone.utc).isoformat()


def parse_timestamp(value: Any) -> Optional[float]:
    """Parse an upstream reset timestamp into a unix epoch (seconds).

    Accepts ISO-8601 strings (with or without a trailing Z) and numeric epoch
    values in seconds or milliseconds. Returns None when it cannot be parsed.
    """
    if value is None:
        return None
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        num = float(value)
        # Heuristic: treat very large numbers as milliseconds.
        if num > 1e12:
            num /= 1000.0
        if num <= 0:
            return None
        return num
    if isinstance(value, str):
        raw = value.strip()
        if not raw:
            return None
        # Numeric string?
        try:
            return parse_timestamp(float(raw))
        except ValueError:
            pass
        normalized = raw
        if normalized.endswith("Z"):
            normalized = normalized[:-1] + "+00:00"
        try:
            dt = datetime.fromisoformat(normalized)
        except ValueError:
            return None
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=timezone.utc)
        return dt.timestamp()
    return None


def to_float(value: Any) -> Optional[float]:
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        return float(value)
    if isinstance(value, str):
        raw = value.strip()
        if not raw:
            return None
        try:
            return float(raw)
        except ValueError:
            return None
    return None


def to_bool(value: Any) -> Optional[bool]:
    if isinstance(value, bool):
        return value
    if isinstance(value, (int, float)):
        return value != 0
    if isinstance(value, str):
        raw = value.strip().lower()
        if raw in ("true", "1", "yes"):
            return True
        if raw in ("false", "0", "no"):
            return False
    return None


# ---------------------------------------------------------------------------
# Config / secrets
# ---------------------------------------------------------------------------


class ConfigError(Exception):
    pass


def load_config(path: str) -> Dict[str, Any]:
    try:
        with open(path, "r", encoding="utf-8") as fh:
            cfg = json.load(fh)
    except FileNotFoundError as exc:
        raise ConfigError(f"config file not found: {path}") from exc
    except json.JSONDecodeError as exc:
        raise ConfigError(f"config file is not valid JSON: {path}: {exc}") from exc
    if not isinstance(cfg, dict):
        raise ConfigError("config root must be a JSON object")
    pools = cfg.get("pools")
    if not isinstance(pools, list) or not pools:
        raise ConfigError("config.pools must be a non-empty array")
    for i, pool in enumerate(pools):
        if not isinstance(pool, dict):
            raise ConfigError(f"config.pools[{i}] must be an object")
        for key in ("name", "base_url", "secrets_env"):
            if not isinstance(pool.get(key), str) or not pool.get(key).strip():
                raise ConfigError(f"config.pools[{i}].{key} is required")
    return cfg


def read_management_key(secrets_env_path: str, secret_key: str) -> str:
    """Read the management key from a secrets.env file (in memory only).

    The value is returned to the caller but never logged. Parsing follows the
    simple KEY=VALUE convention used by docker --env-file / systemd EnvironmentFile.
    """
    try:
        with open(secrets_env_path, "r", encoding="utf-8") as fh:
            lines = fh.readlines()
    except FileNotFoundError as exc:
        raise ConfigError(f"secrets.env not found: {secrets_env_path}") from exc
    except OSError as exc:
        raise ConfigError(f"failed to read secrets.env {secrets_env_path}: {exc}") from exc

    for line in lines:
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        if stripped.startswith("export "):
            stripped = stripped[len("export "):].strip()
        if "=" not in stripped:
            continue
        key, _, value = stripped.partition("=")
        if key.strip() != secret_key:
            continue
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in ("'", '"'):
            value = value[1:-1]
        if not value:
            raise ConfigError(f"{secret_key} is empty in {secrets_env_path}")
        return value
    raise ConfigError(f"{secret_key} not found in {secrets_env_path}")


# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------


def state_key(pool_name: str, auth_index: str) -> str:
    # Use the ASCII unit-separator (escaped, no literal control byte in source)
    # as a delimiter unlikely to occur in pool names or auth indices.
    return f"{pool_name}\x1f{auth_index}"


def load_state(path: str) -> Dict[str, Any]:
    try:
        with open(path, "r", encoding="utf-8") as fh:
            data = json.load(fh)
    except FileNotFoundError:
        return {"version": 1, "entries": {}}
    except json.JSONDecodeError:
        LOG.warning("state file is corrupt, starting from empty state: %s", path)
        return {"version": 1, "entries": {}}
    if not isinstance(data, dict):
        return {"version": 1, "entries": {}}
    data.setdefault("version", 1)
    if not isinstance(data.get("entries"), dict):
        data["entries"] = {}
    return data


def save_state(path: str, state: Dict[str, Any]) -> None:
    directory = os.path.dirname(os.path.abspath(path))
    os.makedirs(directory, exist_ok=True)
    fd, tmp_path = tempfile.mkstemp(prefix=".cpa-quota-state-", dir=directory)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(state, fh, indent=2, sort_keys=True)
            fh.write("\n")
            fh.flush()
            os.fsync(fh.fileno())
        os.replace(tmp_path, path)
    except Exception:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
        raise


# ---------------------------------------------------------------------------
# Management API client
# ---------------------------------------------------------------------------


class ManagementError(Exception):
    """Raised when a management API call cannot be completed."""


class ManagementClient:
    def __init__(self, base_url: str, management_key: str, timeout: float) -> None:
        self._base_url = base_url.rstrip("/")
        self._key = management_key
        self._timeout = timeout

    def _request(self, method: str, path: str, payload: Optional[dict]) -> Tuple[int, Any]:
        url = f"{self._base_url}{path}"
        data = None
        headers = {"Authorization": f"Bearer {self._key}"}
        if payload is not None:
            data = json.dumps(payload).encode("utf-8")
            headers["Content-Type"] = "application/json"
        req = urllib.request.Request(url, data=data, method=method, headers=headers)
        try:
            with urllib.request.urlopen(req, timeout=self._timeout) as resp:
                status = resp.getcode()
                body = resp.read()
        except urllib.error.HTTPError as exc:
            # Read but do not surface the body content (avoid leaking secrets).
            try:
                exc.read()
            except Exception:
                pass
            raise ManagementError(f"management {method} {path} returned HTTP {exc.code}") from None
        except urllib.error.URLError as exc:
            raise ManagementError(f"management {method} {path} failed: {exc.reason}") from None
        except OSError as exc:
            raise ManagementError(f"management {method} {path} failed: {exc}") from None

        if status < 200 or status >= 300:
            raise ManagementError(f"management {method} {path} returned HTTP {status}")
        try:
            parsed = json.loads(body.decode("utf-8")) if body else {}
        except (json.JSONDecodeError, UnicodeDecodeError) as exc:
            raise ManagementError(f"management {method} {path} returned invalid JSON") from exc
        return status, parsed

    def list_auth_files(self) -> List[Dict[str, Any]]:
        _, parsed = self._request("GET", "/v0/management/auth-files", None)
        files = parsed.get("files") if isinstance(parsed, dict) else None
        if not isinstance(files, list):
            raise ManagementError("auth-files response missing 'files' array")
        return [f for f in files if isinstance(f, dict)]

    def api_call(self, auth_index: str, method: str, url: str, header: Dict[str, str]) -> Tuple[int, str]:
        """Proxy an upstream request through a credential.

        Returns (upstream_status_code, upstream_body). The body is returned to
        the caller for parsing but must never be logged.
        """
        payload = {
            "auth_index": auth_index,
            "method": method,
            "url": url,
            "header": header,
        }
        _, parsed = self._request("POST", "/v0/management/api-call", payload)
        if not isinstance(parsed, dict):
            raise ManagementError("api-call response is not an object")
        status = parsed.get("status_code")
        body = parsed.get("body")
        if not isinstance(status, int):
            raise ManagementError("api-call response missing status_code")
        if not isinstance(body, str):
            body = ""
        return status, body

    def reset_quota(self, auth_index: str) -> None:
        self._request("POST", "/v0/management/reset-quota", {"auth_index": auth_index})


# ---------------------------------------------------------------------------
# Candidate selection
# ---------------------------------------------------------------------------


def account_provider(entry: Dict[str, Any]) -> str:
    provider = entry.get("provider") or entry.get("type") or ""
    return str(provider).strip().lower()


def is_candidate(entry: Dict[str, Any], check_all: bool) -> bool:
    provider = account_provider(entry)
    if provider not in SUPPORTED_PROVIDERS:
        return False
    if entry.get("disabled") is True:
        # Explicitly disabled credentials are an account-management decision,
        # not a quota cooldown. Recovery must never reactivate them.
        return False
    if check_all:
        return True
    # `status=error` can be model-scoped while the credential remains routable.
    # Only CPA's aggregate unavailable/next-retry signals identify a real
    # account-level cooldown eligible for reset-quota.
    if entry.get("unavailable") is True:
        return True
    next_retry = parse_timestamp(entry.get("next_retry_after"))
    if next_retry is not None and next_retry > now_ts():
        return True
    return False


# ---------------------------------------------------------------------------
# Usage evaluation
# ---------------------------------------------------------------------------


def evaluate_claude(body: str, grace_seconds: float, probe_ts: float) -> Decision:
    try:
        data = json.loads(body)
    except (json.JSONDecodeError, TypeError):
        return Decision(Decision.NO_DATA, "claude usage body not valid JSON")
    if not isinstance(data, dict):
        return Decision(Decision.NO_DATA, "claude usage body not an object")

    parsed_windows = 0
    blocking: List[str] = []
    for name in CLAUDE_WINDOWS:
        window = data.get(name)
        if window is None:
            continue
        if not isinstance(window, dict):
            return Decision(Decision.NO_DATA, f"claude window {name} malformed")
        util = to_float(window.get("utilization"))
        if util is None:
            return Decision(Decision.NO_DATA, f"claude window {name} missing utilization")
        parsed_windows += 1
        if util < CLAUDE_EXHAUSTED_UTILIZATION:
            # This window has recovered (utilization back below full).
            continue
        # Window is exhausted: only treat as recovered if its reset time elapsed.
        reset_ts = parse_timestamp(window.get("resets_at"))
        if reset_ts is None:
            return Decision(Decision.NO_DATA, f"claude window {name} exhausted with no resets_at")
        if probe_ts < reset_ts + grace_seconds:
            blocking.append(name)

    if parsed_windows == 0:
        return Decision(Decision.NO_DATA, "claude usage contained no known windows")
    if blocking:
        return Decision(Decision.SKIP, "claude windows still cooling: " + ",".join(blocking))
    return Decision(Decision.RESET, "claude quota windows recovered")


def evaluate_codex(
    body: str,
    grace_seconds: float,
    probe_ts: float,
    fetched_at: Optional[float] = None,
) -> Decision:
    try:
        data = json.loads(body)
    except (json.JSONDecodeError, TypeError):
        return Decision(Decision.NO_DATA, "codex usage body not valid JSON")
    if not isinstance(data, dict):
        return Decision(Decision.NO_DATA, "codex usage body not an object")

    rate_limit = data.get("rate_limit")
    if not isinstance(rate_limit, dict):
        return Decision(Decision.NO_DATA, "codex usage missing rate_limit")
    limit_reached = to_bool(rate_limit.get("limit_reached"))
    if limit_reached is None:
        return Decision(Decision.NO_DATA, "codex rate_limit.limit_reached missing")

    if limit_reached is False:
        return Decision(Decision.RESET, "codex rate limit not reached")

    # limit_reached is True: collect every reset time we can find and require
    # that all of them have elapsed (plus grace) before allowing a reset.
    reset_times: List[float] = []
    relative_anchor = fetched_at if fetched_at is not None else probe_ts

    # primary/secondary windows may appear at the top level or nested under
    # rate_limit, depending on the upstream response shape.
    for source in (data, rate_limit):
        for name in ("primary_window", "secondary_window"):
            window = source.get(name)
            if not isinstance(window, dict):
                continue
            ts = parse_timestamp(window.get("reset_at"))
            if ts is None:
                reset_after = to_float(window.get("reset_after_seconds"))
                if reset_after is not None and reset_after >= 0:
                    ts = relative_anchor + reset_after
            if ts is not None:
                reset_times.append(ts)

    # usage_limit_reached may appear at the top level, or nested under error
    # when error.type == usage_limit_reached.
    usage_limit_reached = data.get("usage_limit_reached")
    if not isinstance(usage_limit_reached, dict):
        error = data.get("error")
        if isinstance(error, dict) and str(error.get("type") or "").strip().lower() == "usage_limit_reached":
            nested = error.get("usage_limit_reached")
            usage_limit_reached = nested if isinstance(nested, dict) else error
    if isinstance(usage_limit_reached, dict):
        ts = parse_timestamp(usage_limit_reached.get("resets_at"))
        if ts is not None:
            reset_times.append(ts)
        resets_in = to_float(usage_limit_reached.get("resets_in_seconds"))
        if resets_in is not None:
            reset_times.append(relative_anchor + resets_in)

    if not reset_times:
        return Decision(Decision.NO_DATA, "codex limit reached with no known reset time")

    for reset_ts in reset_times:
        if probe_ts < reset_ts + grace_seconds:
            return Decision(Decision.SKIP, "codex window still cooling")
    return Decision(Decision.RESET, "codex reset windows elapsed")


def probe_account(
    client: ManagementClient,
    provider: str,
    auth_index: str,
    grace_seconds: float,
    cache_base_url: Optional[str] = None,
    management_key: Optional[str] = None,
) -> Decision:
    """Read one account's usage and decide whether to reset.

    When a cache URL is configured, recovery is fail-closed and never bypasses
    the shared cache. `require_fresh=1` guarantees that stale last-known-good
    data cannot reactivate an account.
    """
    if provider == "claude":
        url = CLAUDE_USAGE_URL
        header = dict(CLAUDE_USAGE_HEADERS)
        resource = "claude-usage"
    elif provider == "codex":
        url = CODEX_USAGE_URL
        header = {"Authorization": "Bearer $TOKEN$"}
        resource = "codex-usage"
    else:
        return Decision(Decision.NO_DATA, f"unsupported provider {provider}")

    fetched_at: Optional[float] = None
    if cache_base_url:
        if not management_key:
            return Decision(Decision.NO_DATA, "quota-cache management key missing")
        try:
            envelope = quota_cache_client.fetch(
                cache_base_url,
                management_key,
                resource,
                auth_index,
                require_fresh=True,
                timeout=client._timeout,
            )
        except quota_cache_client.QuotaCacheError as exc:
            if exc.is_auth_invalid:
                # Authentication failure is a known, non-recoverable state for the
                # reset stage. Do not count it as missing data and block the balance
                # stage; balance will soft-quarantine it at weight 0.
                return Decision(Decision.SKIP, "OAuth authentication invalid; awaiting re-login")
            return Decision(Decision.NO_DATA, f"quota-cache probe failed: {exc}")
        result = envelope["result"]
        status = result.get("status_code")
        body = result.get("body") or ""
        fetched_at = to_float(envelope.get("fetched_at"))
    else:
        try:
            status, body = client.api_call(auth_index, "GET", url, header)
        except ManagementError as exc:
            return Decision(Decision.NO_DATA, f"usage probe failed: {exc}")

    if not isinstance(status, int) or status < 200 or status >= 300:
        # 401/403/429/5xx and any other non-2xx -> cannot confirm recovery.
        return Decision(Decision.NO_DATA, f"usage endpoint returned HTTP {status}")

    probe_ts = now_ts()
    if provider == "claude":
        return evaluate_claude(body, grace_seconds, probe_ts)
    return evaluate_codex(body, grace_seconds, probe_ts, fetched_at=fetched_at)


# ---------------------------------------------------------------------------
# Per-account processing
# ---------------------------------------------------------------------------


def verify_reset_applied(
    client: ManagementClient,
    auth_index: str,
    attempts: int = 4,
    delay_seconds: float = 0.25,
) -> bool:
    """Confirm CPA cleared the aggregate account cooldown before balancing."""
    for attempt in range(attempts):
        try:
            entries = client.list_auth_files()
        except ManagementError:
            entries = []
        for entry in entries:
            if str(entry.get("auth_index") or "").strip() != auth_index:
                continue
            if entry.get("unavailable") is not True:
                return True
            break
        # reset-quota state propagation may be asynchronous. Retry both when
        # the account is still unavailable and when it is temporarily absent.
        if attempt + 1 < attempts:
            time.sleep(delay_seconds)
    return False


def process_account(
    client: ManagementClient,
    pool_name: str,
    entry: Dict[str, Any],
    state_entries: Dict[str, Any],
    settings: Dict[str, Any],
    apply: bool,
    cache_base_url: Optional[str] = None,
    management_key: Optional[str] = None,
) -> str:
    """Process a single candidate account. Returns the action taken."""
    auth_index = str(entry.get("auth_index") or "").strip()
    provider = account_provider(entry)
    if not auth_index:
        LOG.warning("[%s] %s account has no auth_index, skipping", pool_name, provider)
        return Decision.SKIP

    key = state_key(pool_name, auth_index)
    record = state_entries.get(key)
    if not isinstance(record, dict):
        record = {}
    now = now_ts()

    # Respect failure backoff window.
    disabled_until = to_float(record.get("disabled_until"))
    if disabled_until is not None and now < disabled_until:
        LOG.info(
            "[%s] %s %s: quota data still in failure backoff until %s "
            "(consecutive_failures=%s); blocking chained balance",
            pool_name, provider, auth_index, iso(disabled_until),
            record.get("consecutive_failures"),
        )
        # This backoff only exists because a previous probe returned NO_DATA.
        # Treating it as an ordinary cooling SKIP would let the chained balance
        # run without a confirmed-fresh recovery decision. Keep the stage
        # fail-closed until the backoff expires and a fresh probe succeeds.
        return Decision.NO_DATA

    decision = probe_account(
        client,
        provider,
        auth_index,
        settings["grace_seconds"],
        cache_base_url=cache_base_url,
        management_key=management_key,
    )

    if decision.action == Decision.NO_DATA:
        failures = int(record.get("consecutive_failures") or 0) + 1
        backoff = min(
            settings["failure_backoff_seconds"] * (2 ** (failures - 1)),
            settings["failure_backoff_max_seconds"],
        )
        record["consecutive_failures"] = failures
        record["disabled_until"] = now + backoff
        record["last_decision"] = str(decision)
        state_entries[key] = record
        LOG.info(
            "[%s] %s %s: no reset (%s); backoff %.0fs",
            pool_name, provider, auth_index, decision.reason, backoff,
        )
        return Decision.NO_DATA

    # A successful probe clears the failure backoff.
    record["consecutive_failures"] = 0
    record["disabled_until"] = 0
    record["last_decision"] = str(decision)

    if decision.action == Decision.SKIP:
        state_entries[key] = record
        LOG.info("[%s] %s %s: still cooling (%s)", pool_name, provider, auth_index, decision.reason)
        return Decision.SKIP

    # decision.action == RESET. Apply debounce.
    last_reset = to_float(record.get("last_reset_at"))
    if last_reset is not None and now - last_reset < settings["debounce_seconds"]:
        state_entries[key] = record
        LOG.info(
            "[%s] %s %s: recovered but debounced (last_reset_at=%s)",
            pool_name, provider, auth_index, iso(last_reset),
        )
        return Decision.SKIP

    if not apply:
        state_entries[key] = record
        LOG.info(
            "[%s] %s %s: DRY-RUN would reset quota (%s)",
            pool_name, provider, auth_index, decision.reason,
        )
        return Decision.RESET

    try:
        client.reset_quota(auth_index)
    except ManagementError as exc:
        record["last_decision"] = f"reset_failed:{exc}"
        state_entries[key] = record
        LOG.error("[%s] %s %s: reset-quota call failed: %s", pool_name, provider, auth_index, exc)
        return Decision.NO_DATA

    if not verify_reset_applied(client, auth_index):
        record["last_decision"] = "reset_unverified"
        state_entries[key] = record
        LOG.error("[%s] %s %s: reset-quota was not verified; blocking chained balance", pool_name, provider, auth_index)
        return Decision.NO_DATA

    record["last_reset_at"] = now
    record["last_decision"] = str(decision)
    state_entries[key] = record
    LOG.info("[%s] %s %s: RESET quota verified (%s)", pool_name, provider, auth_index, decision.reason)
    return Decision.RESET


# ---------------------------------------------------------------------------
# Pool processing
# ---------------------------------------------------------------------------


def process_pool(
    pool: Dict[str, Any],
    state_entries: Dict[str, Any],
    settings: Dict[str, Any],
    apply: bool,
) -> Dict[str, int]:
    counts = {"candidates": 0, "reset": 0, "skip": 0, "no_data": 0, "errors": 0}
    pool_name = pool["name"].strip()
    secret_key = str(pool.get("secret_key") or settings["secret_key"]).strip() or DEFAULT_SECRET_KEY

    try:
        management_key = read_management_key(pool["secrets_env"].strip(), secret_key)
    except ConfigError as exc:
        LOG.error("[%s] %s", pool_name, exc)
        counts["errors"] += 1
        return counts

    client = ManagementClient(pool["base_url"].strip(), management_key, settings["request_timeout_seconds"])
    cache_base_url = str(pool.get("quota_cache_base_url") or "").strip() or None
    if settings.get("require_cache") and not cache_base_url:
        LOG.error("[%s] quota_cache_base_url is required for recovery", pool_name)
        counts["errors"] += 1
        return counts

    try:
        files = client.list_auth_files()
    except ManagementError as exc:
        LOG.error("[%s] failed to list auth files: %s", pool_name, exc)
        counts["errors"] += 1
        return counts

    allowed_providers = pool.get("providers")
    if isinstance(allowed_providers, list) and allowed_providers:
        allowed = {str(p).strip().lower() for p in allowed_providers}
    else:
        allowed = set(SUPPORTED_PROVIDERS)

    for entry in files:
        if account_provider(entry) not in allowed:
            continue
        auth_filter = settings.get("auth_index_filter")
        if auth_filter is not None and str(entry.get("auth_index") or "").strip() not in auth_filter:
            continue
        if not is_candidate(entry, settings["check_all_accounts"]):
            continue
        counts["candidates"] += 1
        action = process_account(
            client,
            pool_name,
            entry,
            state_entries,
            settings,
            apply,
            cache_base_url=cache_base_url,
            management_key=management_key,
        )
        if action == Decision.RESET:
            counts["reset"] += 1
        elif action == Decision.NO_DATA:
            counts["no_data"] += 1
        else:
            counts["skip"] += 1

    LOG.info(
        "[%s] candidates=%d reset=%d skip=%d no_data=%d errors=%d",
        pool_name, counts["candidates"], counts["reset"], counts["skip"], counts["no_data"], counts["errors"],
    )
    return counts


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


def build_settings(cfg: Dict[str, Any]) -> Dict[str, Any]:
    def num(key: str, default: float) -> float:
        value = to_float(cfg.get(key))
        return value if value is not None and value >= 0 else default

    return {
        "debounce_seconds": num("debounce_seconds", DEFAULT_DEBOUNCE_SECONDS),
        "grace_seconds": num("grace_seconds", DEFAULT_GRACE_SECONDS),
        "request_timeout_seconds": num("request_timeout_seconds", DEFAULT_REQUEST_TIMEOUT_SECONDS),
        "failure_backoff_seconds": num("failure_backoff_seconds", DEFAULT_FAILURE_BACKOFF_SECONDS),
        "failure_backoff_max_seconds": num("failure_backoff_max_seconds", DEFAULT_FAILURE_BACKOFF_MAX_SECONDS),
        "check_all_accounts": bool(cfg.get("check_all_accounts", False)),
        "secret_key": str(cfg.get("secret_key") or DEFAULT_SECRET_KEY).strip() or DEFAULT_SECRET_KEY,
    }


def parse_args(argv: List[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        prog="cpa_quota_recovery.py",
        description="Probe Claude/Codex accounts and reset CPA quota cooldown once upstream quota has recovered.",
    )
    parser.add_argument("--config", "-c", required=True, help="Path to the JSON config file.")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument(
        "--apply",
        action="store_true",
        help="Actually POST /v0/management/reset-quota. Without this flag the tool only performs a dry run.",
    )
    mode.add_argument(
        "--dry-run",
        action="store_true",
        help="Probe and report only; never reset quota. This is the default; mutually exclusive with --apply.",
    )
    parser.add_argument(
        "--state",
        help="Path to the JSON state file (overrides config.state_file).",
    )
    parser.add_argument(
        "--pool",
        action="append",
        help="Only process the named pool. May be repeated.",
    )
    parser.add_argument(
        "--auth-index",
        action="append",
        help="Only process the given auth_index. May be repeated to select several accounts.",
    )
    parser.add_argument(
        "--fail-on-no-data",
        action="store_true",
        help="Exit non-zero when any recovery candidate lacks confirmed-fresh quota data.",
    )
    parser.add_argument(
        "--require-cache",
        action="store_true",
        help="Fail instead of directly probing upstream when a pool lacks quota_cache_base_url.",
    )
    parser.add_argument("--verbose", "-v", action="store_true", help="Enable debug logging.")
    return parser.parse_args(argv)


def configure_logging(verbose: bool, log_file: Optional[str]) -> None:
    """Configure logging to stdout and, optionally, an additional file.

    Only derived, non-sensitive facts are ever logged (see module docstring), so
    the file handler carries the same guarantee as stdout: no keys, tokens,
    Authorization headers, cookies, or raw upstream response bodies.
    """
    handlers: List[logging.Handler] = [logging.StreamHandler(sys.stdout)]
    if log_file:
        directory = os.path.dirname(os.path.abspath(log_file))
        if directory:
            os.makedirs(directory, exist_ok=True)
        handlers.append(logging.FileHandler(log_file, encoding="utf-8"))
    # force=True (Python 3.8+) removes and closes any handlers already attached
    # to the root logger before installing ours. Without it a second call (e.g.
    # the bootstrap stdout-only call followed by the log_file call) is a no-op,
    # so the file handler is never installed and nothing is written to the file.
    logging.basicConfig(
        level=logging.DEBUG if verbose else logging.INFO,
        format="%(asctime)s %(levelname)s %(message)s",
        handlers=handlers,
        force=True,
    )


def main(argv: Optional[List[str]] = None) -> int:
    args = parse_args(argv if argv is not None else sys.argv[1:])

    # Bootstrap stdout logging so config-load errors are visible; the optional
    # log_file handler is added once the config has been read.
    configure_logging(args.verbose, None)

    try:
        cfg = load_config(args.config)
    except ConfigError as exc:
        LOG.error("%s", exc)
        return 2

    log_file = cfg.get("log_file")
    if log_file is not None and not isinstance(log_file, str):
        LOG.error("config.log_file must be a string")
        return 2
    log_file = log_file.strip() if isinstance(log_file, str) else ""
    if log_file:
        try:
            configure_logging(args.verbose, log_file)
        except OSError as exc:
            LOG.error("failed to open log_file %s: %s", log_file, exc)
            return 2

    settings = build_settings(cfg)
    settings["require_cache"] = bool(args.require_cache)
    state_path = args.state or str(cfg.get("state_file") or DEFAULT_STATE_FILE)

    auth_filter = None
    if args.auth_index:
        auth_filter = {a.strip() for a in args.auth_index if a.strip()}
    settings["auth_index_filter"] = auth_filter

    apply = bool(args.apply) and not args.dry_run

    pools = cfg["pools"]
    if args.pool:
        wanted = {p.strip() for p in args.pool}
        pools = [p for p in pools if p.get("name", "").strip() in wanted]
        if not pools:
            LOG.error("no configured pool matched --pool %s", sorted(wanted))
            return 2

    if not apply:
        LOG.info("running in DRY-RUN mode; pass --apply to perform quota resets")

    state = load_state(state_path)
    entries = state["entries"]

    totals = {"candidates": 0, "reset": 0, "skip": 0, "no_data": 0, "errors": 0}
    for pool in pools:
        counts = process_pool(pool, entries, settings, apply)
        for key in totals:
            totals[key] += counts[key]

    try:
        save_state(state_path, state)
    except OSError as exc:
        LOG.error("failed to persist state file %s: %s", state_path, exc)
        return 1

    LOG.info(
        "done: candidates=%d reset=%d skip=%d no_data=%d errors=%d (apply=%s)",
        totals["candidates"], totals["reset"], totals["skip"], totals["no_data"], totals["errors"], apply,
    )
    if args.fail_on_no_data and (totals["no_data"] or totals["errors"]):
        LOG.error(
            "recovery stage incomplete: no_data=%d errors=%d",
            totals["no_data"],
            totals["errors"],
        )
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
