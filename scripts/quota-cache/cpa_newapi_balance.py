#!/usr/bin/env python3
"""Balance New API pools and CPA Codex accounts by quota reset urgency.

The controller reads non-sensitive Codex quota-window metadata through
the shared quota-cache and applies two layers of weighting. Cooldown recovery
is intentionally handled by the separate recovery stage before this script:

1. Per-account smooth weighted round-robin weights inside each CPA pool.
2. New API channel weights between the Plus and Business CPA pools.

The opt-in weekly_headroom_v1 policy uses normalized weekly remaining quota
per hour, multiplied by an independent five-hour headroom factor when present.
Legacy primary-only scoring remains available for rollback.
Secrets, account names, emails, auth indexes, and raw upstream bodies are never
logged.

Optional quota-cache integration (see scripts/quota-cache/README.md): when a
pool config sets "quota_cache_base_url", `collect_pool` reads each account's
Codex usage through the shared local quota-cache service (with
require_fresh=1, since a rebalance decision must never act on stale data)
instead of calling CPA's `/api-call` pass-through directly. The weighting
formulas below (`bounded_integer_weights`, `assign_account_weights`,
`target_channel_weights`) and every retry/rollback path are unchanged — only
where the usage reading comes from changes.
"""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import logging
import math
import os
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass, field
from typing import Any, Dict, List, Optional, Sequence, Tuple

import quota_cache_client

LOG = logging.getLogger("cpa-newapi-balance")
DEFAULT_AUTH_WEIGHT = 1


@dataclass
class AccountMetrics:
    label: str
    file_name: str = field(repr=False)
    auth_index: str = field(repr=False)
    used_percent: float = 0.0
    remaining_percent: float = 0.0
    usable_remaining_percent: float = 0.0
    reset_after_seconds: float = 0.0
    reset_at: float = 0.0
    urgency_score: float = 0.0
    limit_reached: bool = False
    fetched_at: float = 0.0
    cpa_unavailable: bool = False
    auth_invalid: bool = False
    current_weight: Optional[int] = None
    target_weight: int = 0

    @property
    def effective_current_weight(self) -> int:
        return DEFAULT_AUTH_WEIGHT if self.current_weight is None else self.current_weight


@dataclass
class PoolMetrics:
    name: str
    client: Any = field(repr=False)
    accounts: List[AccountMetrics]
    valid_accounts: int
    invalid_accounts: int
    remaining_score: float
    usable_remaining_score: float
    urgency_score: float
    average_used_percent: float
    reached_accounts: int
    failed_accounts: int = 0
    auth_invalid_accounts: int = 0


@dataclass
class AccountWeightChange:
    pool: PoolMetrics = field(repr=False)
    account: AccountMetrics = field(repr=False)
    old_weight: Optional[int]
    new_weight: int


def load_json(path: str) -> Dict[str, Any]:
    with open(path, "r", encoding="utf-8") as fh:
        value = json.load(fh)
    if not isinstance(value, dict):
        raise ValueError("config root must be an object")
    return value


def load_quota_module(path: str):
    spec = importlib.util.spec_from_file_location("cpa_quota_recovery", path)
    if spec is None or spec.loader is None:
        raise RuntimeError("cannot load quota recovery module")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def load_balance_state(path: str) -> Dict[str, Any]:
    try:
        with open(path, "r", encoding="utf-8") as fh:
            value = json.load(fh)
    except (FileNotFoundError, json.JSONDecodeError, OSError):
        return {"version": 1}
    if not isinstance(value, dict):
        return {"version": 1}
    value.setdefault("version", 1)
    return value


def save_balance_state(path: str, state: Dict[str, Any]) -> None:
    directory = os.path.dirname(os.path.abspath(path))
    os.makedirs(directory, mode=0o700, exist_ok=True)
    fd, tmp_path = tempfile.mkstemp(prefix=".cpa-balance-state-", dir=directory)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(state, fh, indent=2, sort_keys=True)
            fh.write("\n")
            fh.flush()
            os.fsync(fh.fileno())
        os.chmod(tmp_path, 0o600)
        os.replace(tmp_path, path)
    except Exception:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
        raise


def snapshot_fingerprint(
    pools: Sequence["PoolMetrics"],
    current_channels: Dict[str, int],
    strategies: Dict[str, str],
) -> str:
    rows = []
    for pool in sorted(pools, key=lambda item: item.name):
        for account in sorted(pool.accounts, key=lambda item: item.label):
            rows.append({
                "pool": pool.name,
                "account": account.label,
                "fetched_at": round(account.fetched_at, 6),
                "unavailable": account.cpa_unavailable,
                "current_weight": account.current_weight,
                "limit_reached": account.limit_reached,
                "auth_invalid": account.auth_invalid,
            })
    payload = {
        "accounts": rows,
        "channels": current_channels,
        "strategies": strategies,
    }
    encoded = json.dumps(payload, sort_keys=True, separators=(",", ":")).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def to_number(value: Any) -> Optional[float]:
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)) and math.isfinite(float(value)):
        return float(value)
    if isinstance(value, str):
        try:
            parsed = float(value.strip())
        except (TypeError, ValueError):
            return None
        return parsed if math.isfinite(parsed) else None
    return None


def parse_optional_weight(value: Any) -> Optional[int]:
    parsed = to_number(value)
    if parsed is None or not parsed.is_integer():
        return None
    weight = int(parsed)
    if 0 <= weight <= 1_000_000:
        return weight
    return None


def account_label(pool_name: str, entry: Dict[str, Any]) -> str:
    identity = str(entry.get("name") or entry.get("id") or entry.get("auth_index") or "unknown")
    digest = hashlib.sha256(f"{pool_name}:{identity}".encode("utf-8")).hexdigest()[:8]
    return digest


def reset_seconds(
    window: Dict[str, Any], now: float, fetched_at: float, fallback_seconds: float
) -> Tuple[float, float]:
    """Returns `(remaining_seconds_until_reset, absolute_reset_at)` for one
    quota window, as of `now` (the real current time).

    An absolute `reset_at` always wins when present and still in the future —
    it names a fixed point in time, so `reset_at - now` is exactly correct
    regardless of when this window's data was actually fetched.

    Only when `reset_at` is missing/invalid does the relative
    `reset_after_seconds` apply, and it is anchored to `fetched_at` — the
    moment this window's own reading was actually fetched upstream (which,
    for a quota-cache-served reading, can be well before `now`, since a
    fresh cache hit serves an earlier fetch's body without a new upstream
    call) — never to `now` itself. Anchoring the relative countdown to `now`
    instead would silently push the reset further into the future every time
    the same still-cached body happened to be read again, which is exactly
    the double-counted delay this must avoid; anchoring to `fetched_at`
    keeps the derived absolute point fixed across repeated reads of the same
    cached body, so the *remaining* time it implies correctly shrinks as
    `now` advances.
    """
    reset_at = to_number(window.get("reset_at"))
    if reset_at is not None and reset_at > now:
        return reset_at - now, reset_at
    reset_after = to_number(window.get("reset_after_seconds"))
    if reset_after is not None and reset_after > 0:
        absolute = fetched_at + reset_after
        if absolute > now:
            return absolute - now, absolute
    return fallback_seconds, now + fallback_seconds


def mixed_window_metrics(rate_limit, now, fetched_at, reserve, minimum_seconds):
    """Weekly pacing with an independent, dimensionless 5h headroom gate.

    Equal normalized weekly budgets are a scheduling policy, not a claim that
    different subscriptions have equal token capacity. No 5h percent/hour is
    ever compared with weekly percent/hour. Missing 5h means no 5h constraint.
    Unknown windows or expired observations are rejected; callers isolate the account.
    """
    if not isinstance(rate_limit, dict):
        raise ValueError("missing rate limit")
    for flag in ("allowed", "limit_reached"):
        if flag in rate_limit and not isinstance(rate_limit[flag], bool):
            raise ValueError("invalid availability flag")
    windows = {}
    for key in ("primary_window", "secondary_window"):
        window = rate_limit.get(key)
        if window is None:
            continue
        if not isinstance(window, dict):
            raise ValueError("invalid window")
        duration = to_number(window.get("limit_window_seconds"))
        used = to_number(window.get("used_percent"))
        if duration not in (18000, 604800) or duration in windows:
            raise ValueError("unknown or duplicate window duration")
        if used is None or not 0 <= used <= 100:
            raise ValueError("invalid percentage")
        if window.get("reset_at") is not None:
            reset = to_number(window["reset_at"])
            if reset is None or reset <= 0:
                raise ValueError("invalid reset timestamp")
        else:
            relative = to_number(window.get("reset_after_seconds"))
            if relative is None or relative < 0:
                raise ValueError("missing reset timestamp")
            reset = fetched_at + relative
        if reset <= now:
            raise ValueError("expired quota observation")
        windows[duration] = (used, reset)
    if 604800 not in windows:
        raise ValueError("weekly budget required for normalized weekly policy")
    weekly_used, weekly_reset = windows[604800]
    reached = rate_limit.get("allowed") is False or rate_limit.get("limit_reached") is True
    reached = reached or any(used >= 100 for used, _ in windows.values())
    remaining = 0.0 if reached else 100.0 - weekly_used
    usable = max(0.0, remaining - reserve)
    short_gate = 1.0
    if 18000 in windows:
        short_gate = max(0.0, 100.0 - windows[18000][0] - reserve) / (100.0 - reserve)
    score = usable / (max(weekly_reset - now, minimum_seconds) / 3600.0) * short_gate
    return weekly_used, remaining, usable, weekly_reset - now, weekly_reset, score, reached


def collect_pool(
    qr,
    pool: Dict[str, Any],
    quota_cfg: Dict[str, Any],
    config: Dict[str, Any],
    timeout: float,
    now: Optional[float] = None,
) -> PoolMetrics:
    if config.get("scoring_policy") not in (None, "weekly_headroom_v1"):
        raise ValueError("unsupported scoring policy")
    name = str(pool.get("name") or "").strip()
    if not name:
        raise RuntimeError("pool name is missing")
    secret_name = str(quota_cfg.get("secret_key") or "CLIPROXYAPI_MANAGEMENT_KEY")
    management_key = qr.read_management_key(str(pool["secrets_env"]), secret_name)
    client = qr.ManagementClient(str(pool["base_url"]), management_key, timeout)
    cache_base_url = str(pool.get("quota_cache_base_url") or "").strip() or None

    # The former five-percentage-point hard reserve is intentionally disabled.
    # Keep the config hook only for explicit rollback experiments; omitted/current
    # production configuration means every confirmed remaining percentage is usable.
    reserve_percent = max(0.0, min(99.0, float(config.get("reserve_percent", 0))))
    minimum_reset_seconds = max(60.0, float(config.get("minimum_reset_hours", 2)) * 3600.0)
    fallback_reset_seconds = max(
        minimum_reset_seconds,
        float(config.get("fallback_reset_hours", 168)) * 3600.0,
    )
    now = time.time() if now is None else now

    accounts: List[AccountMetrics] = []
    invalid = 0
    failed = 0
    auth_invalid_count = 0
    reached = 0
    remaining_score = 0.0
    usable_remaining_score = 0.0
    urgency_score = 0.0
    used_values: List[float] = []

    for entry in client.list_auth_files():
        if qr.account_provider(entry) != "codex":
            continue
        auth_index = str(entry.get("auth_index") or entry.get("index") or "").strip()
        file_name = str(entry.get("name") or "").strip()
        if not auth_index or not file_name:
            invalid += 1
            failed += 1
            continue
        if bool(entry.get("disabled")):
            invalid += 1
            continue

        try:
            if cache_base_url:
                envelope = quota_cache_client.fetch(
                    cache_base_url, management_key, "codex-usage", auth_index, require_fresh=True, timeout=timeout
                )
                result = envelope["result"]
                status = result.get("status_code")
                body = result.get("body") or ""
                if not isinstance(status, int):
                    raise quota_cache_client.QuotaCacheError("quota-cache result missing status_code")
                # A cache hit can serve a body an earlier call already fetched
                # upstream — `reset_seconds` must anchor this window's own
                # relative `reset_after_seconds` to the moment it was actually
                # fetched, never to `now` (this call's own time), or the
                # derived reset point would drift later on every subsequent
                # cache hit that happens to land after that original fetch.
                envelope_fetched_at = to_number(envelope.get("fetched_at"))
                fetched_at = envelope_fetched_at if envelope_fetched_at is not None else now
            else:
                status, body = client.api_call(
                    auth_index,
                    "GET",
                    qr.CODEX_USAGE_URL,
                    {"Authorization": "Bearer $TOKEN$"},
                )
                # A direct call just fetched this reading right now.
                fetched_at = now
            if status != 200:
                raise RuntimeError(f"usage read returned HTTP {status}")
            data = json.loads(body)
            rate_limit = data.get("rate_limit") if isinstance(data, dict) else None
            if config.get("scoring_policy") == "weekly_headroom_v1":
                used, remaining, usable_remaining, reset_after, reset_at, score, reached_now = mixed_window_metrics(
                    rate_limit, now, fetched_at, reserve_percent, minimum_reset_seconds
                )
                cpa_unavailable = entry.get("unavailable") is True
                if cpa_unavailable:
                    remaining = usable_remaining = score = 0.0
                    reached_now = True
            else:
                window = rate_limit.get("primary_window") if isinstance(rate_limit, dict) else None
                used = window.get("used_percent") if isinstance(window, dict) else None
                if not isinstance(window, dict) or not isinstance(used, (int, float)):
                    raise RuntimeError("usage read missing rate_limit.primary_window.used_percent")
                used = float(used)
                if not 0 <= used <= 100:
                    raise RuntimeError("usage read used_percent out of range")

                limit_reached = bool(rate_limit.get("limit_reached"))
                allowed = rate_limit.get("allowed")
                reached_now = limit_reached or allowed is False
                remaining = 0.0 if reached_now else max(0.0, 100.0 - used)
                usable_remaining = max(0.0, remaining - reserve_percent)
                reset_after, reset_at = reset_seconds(window, now, fetched_at, fallback_reset_seconds)
                effective_hours = max(reset_after, minimum_reset_seconds) / 3600.0
                score = usable_remaining / effective_hours if usable_remaining > 0 else 0.0
                cpa_unavailable = entry.get("unavailable") is True
            metric = AccountMetrics(
                label=account_label(name, entry),
                file_name=file_name,
                auth_index=auth_index,
                used_percent=used,
                remaining_percent=remaining,
                usable_remaining_percent=usable_remaining,
                reset_after_seconds=reset_after,
                reset_at=reset_at,
                urgency_score=score,
                limit_reached=reached_now,
                fetched_at=fetched_at,
                cpa_unavailable=cpa_unavailable,
                current_weight=parse_optional_weight(entry.get("weight")),
            )
            accounts.append(metric)
            reached += int(reached_now)
            used_values.append(used)
            remaining_score += remaining
            usable_remaining_score += usable_remaining
            urgency_score += score
        except Exception as exc:
            if isinstance(exc, quota_cache_client.QuotaCacheError) and exc.is_auth_invalid:
                # A confirmed invalid OAuth credential is not unknown quota. Keep the
                # auth file enabled so a replacement login can rejoin automatically,
                # but remove it from routing immediately by giving it a known zero score.
                accounts.append(AccountMetrics(
                    label=account_label(name, entry),
                    file_name=file_name,
                    auth_index=auth_index,
                    urgency_score=0.0,
                    fetched_at=now,
                    auth_invalid=True,
                    current_weight=parse_optional_weight(entry.get("weight")),
                ))
                invalid += 1
                auth_invalid_count += 1
                LOG.warning("pool=%s account=%s quota_failure=auth_invalid action=quarantine_weight_zero",
                            name, account_label(name, entry))
                continue
            if cache_base_url or config.get("scoring_policy") == "weekly_headroom_v1":
                # Unknown is not exhausted: leave this account untouched and
                # redistribute only the healthy accounts' existing weight budget.
                failed += 1
                invalid += 1
                LOG.warning("pool=%s account=%s quota_unknown=%s action=freeze_account",
                            name, account_label(name, entry), type(exc).__name__)
                continue
            # Raw upstream errors may contain sensitive account data.
            invalid += 1

    if not accounts and not failed:
        raise RuntimeError(f"pool {name} has no valid Codex quota observations")

    return PoolMetrics(
        name=name,
        client=client,
        accounts=accounts,
        valid_accounts=len(used_values),
        invalid_accounts=invalid,
        remaining_score=remaining_score,
        usable_remaining_score=usable_remaining_score,
        urgency_score=urgency_score,
        average_used_percent=sum(used_values) / len(used_values) if used_values else 0.0,
        reached_accounts=reached,
        failed_accounts=failed,
        auth_invalid_accounts=auth_invalid_count,
    )


def bounded_integer_weights(
    labelled_scores: Sequence[Tuple[str, float]],
    total: int,
    minimum_nonzero: int,
    maximum_share: int,
) -> Dict[str, int]:
    result = {label: 0 for label, _ in labelled_scores}
    if total <= 0:
        return result
    positive = [(label, float(score)) for label, score in labelled_scores if score > 0]
    if not positive:
        return result
    if len(positive) == 1:
        result[positive[0][0]] = total
        return result

    count = len(positive)
    lower = max(0, min(int(minimum_nonzero), total // count))
    upper = max(int(maximum_share), math.ceil(total / count))
    upper = min(total, upper)

    def projected(scale: float) -> List[float]:
        return [max(lower, min(upper, scale * score)) for _, score in positive]

    lo, hi = 0.0, 1.0
    while sum(projected(hi)) < total:
        hi *= 2.0
        if hi > 1e12:
            raise RuntimeError("cannot normalize account weights")
    for _ in range(100):
        mid = (lo + hi) / 2.0
        if sum(projected(mid)) < total:
            lo = mid
        else:
            hi = mid

    values = projected((lo + hi) / 2.0)
    integers = [int(math.floor(value)) for value in values]
    remainder = total - sum(integers)
    order = sorted(
        range(count),
        key=lambda idx: (values[idx] - integers[idx], positive[idx][0]),
        reverse=True,
    )
    while remainder > 0:
        changed = False
        for idx in order:
            if integers[idx] < upper:
                integers[idx] += 1
                remainder -= 1
                changed = True
                if remainder == 0:
                    break
        if not changed:
            raise RuntimeError("cannot distribute account weight remainder")

    for (label, _), weight in zip(positive, integers):
        result[label] = weight
    return result


def assign_account_weights(config: Dict[str, Any], pool: PoolMetrics) -> None:
    normal_total = int(config.get("account_weight_total", 100))
    total = normal_total
    if pool.failed_accounts:
        # Keep the unknown accounts' relative share from being inflated simply
        # by renormalizing a partial pool back to 100. Never infer their quota.
        total = sum(account.effective_current_weight for account in pool.accounts)
    scale = total / max(1, normal_total)
    targets = bounded_integer_weights(
        [(account.label, account.urgency_score) for account in pool.accounts],
        total=total,
        minimum_nonzero=int(int(config.get("minimum_nonzero_account_weight", 5)) * scale),
        maximum_share=math.ceil(int(config.get("maximum_account_weight", 80)) * scale),
    )
    for account in pool.accounts:
        account.target_weight = targets[account.label]


def psql(config: Dict[str, Any], sql: str, capture: bool = True) -> str:
    docker = str(config.get("docker_bin") or "/usr/bin/docker")
    container = str(config.get("postgres_container") or "new-api-postgres")
    command = [
        docker,
        "exec",
        "-i",
        container,
        "sh",
        "-lc",
        'psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -X -P pager=off -AtF "|"',
    ]
    proc = subprocess.run(command, input=sql, text=True, capture_output=capture, check=True)
    return proc.stdout.strip() if capture else ""


def current_channel_weights(config: Dict[str, Any]) -> Dict[str, int]:
    channels = config["channels"]
    ids = [int(channels["plus"]["id"]), int(channels["business"]["id"])]
    rows = psql(config, f"select id,weight from channels where id in ({ids[0]},{ids[1]}) order by id;")
    by_id: Dict[int, int] = {}
    for line in rows.splitlines():
        parts = line.split("|")
        if len(parts) == 2:
            by_id[int(parts[0])] = int(parts[1])
    if any(channel_id not in by_id for channel_id in ids):
        raise RuntimeError("configured New API channels were not found")
    return {"plus": by_id[ids[0]], "business": by_id[ids[1]]}


def target_channel_weights(config: Dict[str, Any], plus: PoolMetrics, business: PoolMetrics) -> Dict[str, int]:
    total = plus.urgency_score + business.urgency_score
    if total <= 0:
        raise RuntimeError("both pools have no usable quota before reset; preserving current weights")
    if plus.urgency_score <= 0:
        return {"plus": 0, "business": 100}
    if business.urgency_score <= 0:
        return {"plus": 100, "business": 0}

    plus_weight = int(round(100.0 * plus.urgency_score / total))
    maximum = max(50, min(99, int(config.get("maximum_pool_weight", 75))))
    plus_weight = max(100 - maximum, min(maximum, plus_weight))
    return {"plus": plus_weight, "business": 100 - plus_weight}


def apply_channel_weights(config: Dict[str, Any], weights: Dict[str, int]) -> None:
    plus = config["channels"]["plus"]
    business = config["channels"]["business"]
    plus_id, business_id = int(plus["id"]), int(business["id"])
    plus_name = str(plus["name"]).replace("'", "''")
    business_name = str(business["name"]).replace("'", "''")
    sql = f"""
begin;
update channels set weight={int(weights['plus'])} where id={plus_id} and name='{plus_name}';
update channels set weight={int(weights['business'])} where id={business_id} and name='{business_name}';
commit;
"""
    psql(config, sql, capture=True)


def account_weight_changes(config: Dict[str, Any], pools: Sequence[PoolMetrics]) -> List[AccountWeightChange]:
    minimum_delta = max(0, int(config.get("account_minimum_update_delta", 3)))
    changes: List[AccountWeightChange] = []
    for pool in pools:
        for account in pool.accounts:
            current = account.effective_current_weight
            target = account.target_weight
            force_boundary = current == 0 or target == 0
            missing_explicit_weight = account.current_weight is None
            if missing_explicit_weight or force_boundary or abs(current - target) >= minimum_delta:
                if missing_explicit_weight or current != target:
                    changes.append(
                        AccountWeightChange(
                            pool=pool,
                            account=account,
                            old_weight=account.current_weight,
                            new_weight=target,
                        )
                    )
    return changes


def get_routing_strategy(client: Any) -> str:
    _, payload = client._request("GET", "/v0/management/routing/strategy", None)
    if not isinstance(payload, dict):
        raise RuntimeError("routing strategy response is invalid")
    return str(payload.get("strategy") or "").strip().lower()


def patch_account_weight(client: Any, file_name: str, weight: Optional[int]) -> None:
    client._request(
        "PATCH",
        "/v0/management/auth-files/fields",
        {"name": file_name, "weight": weight},
    )


def verify_account_changes(changes: Sequence[AccountWeightChange]) -> None:
    by_pool: Dict[str, Tuple[PoolMetrics, List[AccountWeightChange]]] = {}
    for change in changes:
        by_pool.setdefault(change.pool.name, (change.pool, []))[1].append(change)
    for pool, pool_changes in by_pool.values():
        entries = {str(entry.get("name") or ""): entry for entry in pool.client.list_auth_files()}
        for change in pool_changes:
            entry = entries.get(change.account.file_name)
            if entry is None:
                raise RuntimeError(f"account weight verification failed in pool {pool.name}")
            actual = parse_optional_weight(entry.get("weight"))
            if actual != change.new_weight:
                raise RuntimeError(f"account weight verification failed in pool {pool.name}")


def rollback_account_changes(changes: Sequence[AccountWeightChange]) -> None:
    for change in reversed(changes):
        try:
            patch_account_weight(change.pool.client, change.account.file_name, change.old_weight)
        except Exception:
            LOG.error("rollback failed for pool=%s account=%s", change.pool.name, change.account.label)


def configure_logging(log_file: str, verbose: bool) -> None:
    handlers: List[logging.Handler] = [logging.StreamHandler(sys.stdout)]
    if log_file:
        os.makedirs(os.path.dirname(log_file), mode=0o700, exist_ok=True)
        handlers.append(logging.FileHandler(log_file, encoding="utf-8"))
    logging.basicConfig(
        level=logging.DEBUG if verbose else logging.INFO,
        format="%(asctime)s %(levelname)s %(message)s",
        handlers=handlers,
        force=True,
    )


def should_update_channels(config: Dict[str, Any], current: Dict[str, int], target: Dict[str, int]) -> bool:
    delta = max(abs(current["plus"] - target["plus"]), abs(current["business"] - target["business"]))
    minimum_delta = max(0, int(config.get("minimum_update_delta", 3)))
    force_boundary = 0 in current.values() or 0 in target.values()
    if delta < minimum_delta and not force_boundary:
        LOG.info("no channel update: delta=%d is below threshold=%d", delta, minimum_delta)
        return False
    return current != target


def log_plan(pools: Sequence[PoolMetrics], current: Dict[str, int], target: Dict[str, int], mode: str) -> None:
    for pool in pools:
        LOG.info(
            "pool=%s valid=%d invalid=%d avg_used=%.1f remaining=%.1f usable=%.1f urgency=%.3f reached=%d",
            pool.name,
            pool.valid_accounts,
            pool.invalid_accounts,
            pool.average_used_percent,
            pool.remaining_score,
            pool.usable_remaining_score,
            pool.urgency_score,
            pool.reached_accounts,
        )
        for account in sorted(pool.accounts, key=lambda item: item.label):
            LOG.info(
                "pool=%s account=%s used=%.1f usable=%.1f reset_hours=%.2f urgency=%.3f current_weight=%d target_weight=%d reached=%s unavailable=%s auth_invalid=%s fetched_age=%.1fs",
                pool.name,
                account.label,
                account.used_percent,
                account.usable_remaining_percent,
                account.reset_after_seconds / 3600.0,
                account.urgency_score,
                account.effective_current_weight,
                account.target_weight,
                str(account.limit_reached).lower(),
                str(account.cpa_unavailable).lower(),
                str(account.auth_invalid).lower(),
                max(0.0, time.time() - account.fetched_at),
            )
    LOG.info(
        "channel_weights current_plus=%d current_business=%d target_plus=%d target_business=%d mode=%s",
        current["plus"],
        current["business"],
        target["plus"],
        target["business"],
        mode,
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", required=True)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--apply", action="store_true")
    mode.add_argument("--dry-run", action="store_true")
    parser.add_argument("--verbose", action="store_true")
    args = parser.parse_args()

    cfg = load_json(args.config)
    configure_logging(str(cfg.get("log_file") or ""), args.verbose)
    qr = load_quota_module(str(cfg["quota_recovery_module"]))
    quota_cfg = qr.load_config(str(cfg["quota_recovery_config"]))
    timeout = float(cfg.get("request_timeout_seconds", 20))
    pools_cfg = {str(pool.get("name")): pool for pool in quota_cfg.get("pools", []) if isinstance(pool, dict)}
    if "plus" not in pools_cfg or "business" not in pools_cfg:
        raise RuntimeError("plus/business pools missing from quota recovery config")

    for pool_name, cache_url in cfg.get("quota_cache_base_urls", {}).items():
        if pool_name in pools_cfg:
            pools_cfg[pool_name] = dict(pools_cfg[pool_name], quota_cache_base_url=cache_url)
    LOG.info("scoring_policy=%s", cfg.get("scoring_policy", "legacy_primary"))
    plus = collect_pool(qr, pools_cfg["plus"], quota_cfg, cfg, timeout)
    business = collect_pool(qr, pools_cfg["business"], quota_cfg, cfg, timeout)
    pools = (plus, business)
    strategies = {pool.name: get_routing_strategy(pool.client) for pool in pools}
    current_channels = current_channel_weights(cfg)
    state_path = str(
        cfg.get("state_file")
        or "/home/gakki/.local/state/cpa-newapi-balance/state.json"
    )
    state = load_balance_state(state_path)
    fingerprint = snapshot_fingerprint(pools, current_channels, strategies)
    incomplete = any(pool.failed_accounts for pool in pools)
    if (
        args.apply
        and not incomplete
        and state.get("last_snapshot_fingerprint") == fingerprint
    ):
        LOG.info("quota snapshot and routing state unchanged; skip rebalance")
        return 0

    for pool in pools:
        assign_account_weights(cfg, pool)

    no_usable_pool_score = plus.urgency_score + business.urgency_score <= 0
    target_channels = (
        dict(current_channels)
        if incomplete or no_usable_pool_score
        else target_channel_weights(cfg, plus, business)
    )
    if incomplete:
        LOG.warning("partial quota observations: freeze channel weights; plus_failed=%d business_failed=%d",
                    plus.failed_accounts, business.failed_accounts)
    elif no_usable_pool_score:
        # Still apply per-account zero boundaries (including auth-invalid
        # quarantine) even when neither pool can receive traffic. Channel weights
        # remain unchanged because there is no safe positive destination.
        LOG.warning("all pools have zero usable score: preserve channel weights")
    changes = account_weight_changes(cfg, pools)
    update_channels = should_update_channels(cfg, current_channels, target_channels)
    mode_name = "apply" if args.apply else "dry-run"
    log_plan(pools, current_channels, target_channels, mode_name)
    for pool in pools:
        LOG.info("pool=%s routing_strategy=%s", pool.name, strategies[pool.name] or "unknown")

    if args.apply and any(strategy != "weighted-round-robin" for strategy in strategies.values()):
        raise RuntimeError("all CPA pools must use weighted-round-robin before apply")

    if not args.apply:
        LOG.info(
            "dry-run: would update account_weights=%d channel_weights=%s",
            len(changes),
            str(update_channels).lower(),
        )
        return 0
    if not changes and not update_channels:
        LOG.info("no update required")
        if not incomplete:
            save_balance_state(
                state_path,
                {
                    "version": 1,
                    "last_snapshot_fingerprint": fingerprint,
                    "last_processed_at": time.time(),
                },
            )
        return 0

    applied_accounts: List[AccountWeightChange] = []
    channel_changed = False
    try:
        for change in changes:
            # Include ambiguous writes (e.g. response lost after server applied).
            applied_accounts.append(change)
            patch_account_weight(change.pool.client, change.account.file_name, change.new_weight)
        if applied_accounts:
            verify_account_changes(applied_accounts)
            LOG.info("updated CPA account weights: count=%d", len(applied_accounts))

        if update_channels:
            channel_changed = True
            apply_channel_weights(cfg, target_channels)
            after_channels = current_channel_weights(cfg)
            if after_channels != target_channels:
                raise RuntimeError("New API channel weight verification failed")
            LOG.info(
                "updated New API channel weights: plus=%d business=%d",
                after_channels["plus"],
                after_channels["business"],
            )
        if not incomplete:
            save_balance_state(
                state_path,
                {
                    "version": 1,
                    "last_snapshot_fingerprint": snapshot_fingerprint(
                        pools,
                        target_channels if update_channels else current_channels,
                        strategies,
                    ),
                    "last_processed_at": time.time(),
                },
            )
        return 0
    except Exception as exc:
        LOG.error("apply failed; attempting rollback: %s", type(exc).__name__)
        if channel_changed:
            try:
                apply_channel_weights(cfg, current_channels)
            except Exception:
                LOG.error("New API channel weight rollback failed")
        rollback_account_changes(applied_accounts)
        raise RuntimeError("balance apply failed and rollback was attempted") from None


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
        LOG.error("balance failed: %s", exc)
        raise SystemExit(1)
