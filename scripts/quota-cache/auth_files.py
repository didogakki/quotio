"""Short-TTL cache over CPA's `/v0/management/auth-files` listing.

Resolving `auth_index -> {provider, disabled, account, stable identity}` needs a
recent listing, but calling CPA on every single incoming request would multiply
load on CLIProxyAPI by the number of quota-cache readers — exactly what this
service exists to avoid. A short TTL (seconds, not the resource TTLs of
minutes) keeps the listing "recent enough" for auth/provider/disabled checks
and for detecting an account replacement, without re-fetching on every request.
Never caches a token: CPA's `/api-call` pass-through takes `$TOKEN$` and
substitutes the real credential itself, so no token ever reaches this process
— the auth-files listing itself carries none either.
"""

from __future__ import annotations

import hashlib
import threading
import time
from dataclasses import dataclass
from typing import Any, Dict, List, Optional


@dataclass(frozen=True)
class ResolvedAccount:
    auth_index: str
    provider: str  # normalized: "claude" | "codex" | "grok" | other
    disabled: bool
    account: Optional[str]  # Codex's ChatGPT-Account-Id, when present
    identity: str  # stable across auth_index reassignment; see `_identity_of`


def _normalized_provider(entry: Dict[str, Any]) -> str:
    raw = str(entry.get("provider") or entry.get("type") or "").strip().lower()
    if raw == "xai":
        return "grok"
    return raw


def _identity_of(entry: Dict[str, Any]) -> Optional[str]:
    """A hash of the account's own stable, non-sensitive fields — never the raw
    `auth_index` (which CPA may reassign to a different account after a
    deletion/replacement) and never just the file's `id`/`name` alone (which a
    deleted-and-recreated file can end up reusing for a genuinely different
    underlying account). Folding in `account`/`email` — real per-account fields
    that differ between two different accounts but stay stable across an
    ordinary token refresh — means a same-`id`/same-`name` swap to a different
    real account still changes the identity, without the false-positive churn
    a last-updated timestamp would cause on every refresh. Returns `None` when
    the entry carries no stable identifier at all (neither an id/name nor an
    account/email); the caller must conservatively drop such an entry rather
    than resolve it under an ambiguous identity.
    """
    stable_id = str(entry.get("id") or entry.get("name") or "").strip()
    if not stable_id:
        return None
    account = str(entry.get("account") or "").strip()
    email = str(entry.get("email") or "").strip()
    digest_input = "\x1f".join((stable_id, account, email))
    return hashlib.sha256(digest_input.encode("utf-8")).hexdigest()


class AuthFileResolver:
    def __init__(
        self,
        management_client: Any,
        ttl_seconds: float = 5.0,
        *,
        max_stale_seconds: Optional[float] = None,
    ) -> None:
        self._client = management_client
        self._ttl_seconds = ttl_seconds
        # How long a mapping may keep being served purely from the last
        # successful listing while every subsequent refresh attempt fails,
        # before this resolver fails closed (see `resolve`) instead of trusting
        # an arbitrarily old snapshot for an authorization/quota decision.
        self._max_stale_seconds = ttl_seconds * 12 if max_stale_seconds is None else max_stale_seconds
        self._lock = threading.Lock()
        self._by_auth_index: Dict[str, ResolvedAccount] = {}
        self._fetched_at: float = 0.0
        self._last_success_at: float = 0.0
        self._refresh_event: Optional[threading.Event] = None

    def resolve(
        self, auth_index: str, *, now: Optional[float] = None, force_refresh: bool = False
    ) -> Optional[ResolvedAccount]:
        now = time.time() if now is None else now
        with self._lock:
            stale = force_refresh or (now - self._fetched_at) >= self._ttl_seconds
        refreshed = True
        if stale:
            refreshed = self._refresh(now)
        with self._lock:
            if force_refresh and not refreshed:
                # The caller explicitly demanded a listing proven current as of
                # `now` — `service.py`'s `_do_refresh` uses `force_refresh=True`
                # for exactly this, to detect an account that was
                # swapped/disabled while its own upstream quota call was in
                # flight. A refresh that failed to actually produce that proof
                # must never fall back to whatever mapping happened to exist
                # before, even if that old mapping is itself still within
                # `max_stale_seconds` — silently trusting it here would let a
                # request reach an account under a mapping this call could not
                # confirm is still current, defeating the entire purpose of
                # asking for `force_refresh` in the first place.
                return None
            if (now - self._last_success_at) > self._max_stale_seconds:
                # The listing has been failing for longer than is safe to trust
                # for an authorization/quota decision — fail closed rather than
                # silently reusing an indefinitely old mapping. A caller that
                # only wants to *display* the last-known accounts (never to
                # authorize a live quota read against them) needs a separate,
                # explicitly-labeled snapshot path, not this one.
                return None
            return self._by_auth_index.get(auth_index)

    def _refresh(self, now: float) -> bool:
        """Returns whether the listing attempt this call triggered or waited
        on actually succeeded — `resolve` uses this to fail closed on a forced
        refresh that didn't (see its own doc comment), instead of inferring
        success from timestamps a concurrent leader/follower pair could
        otherwise observe at slightly different `now` values.
        """
        with self._lock:
            event = self._refresh_event
            if event is not None:
                leader = False
            else:
                event = threading.Event()
                event.success = False  # type: ignore[attr-defined]
                self._refresh_event = event
                leader = True

        if not leader:
            # Singleflight: every other thread that finds the mapping stale at
            # roughly the same time waits on the one in-flight listing call
            # instead of each issuing its own — the same reasoning as the main
            # service's per-resource refresh coalescing.
            event.wait(timeout=10)
            return event.success  # type: ignore[attr-defined]

        try:
            try:
                files: List[Dict[str, Any]] = self._client.list_auth_files()
            except Exception:
                # A listing failure must never wipe out an existing, still-useful
                # mapping outright — callers keep using the last-known mapping,
                # but only up to `max_stale_seconds` (see `resolve`), after which
                # this resolver fails closed instead of trusting it forever.
                return False
            resolved: Dict[str, ResolvedAccount] = {}
            for entry in files:
                auth_index = str(entry.get("auth_index") or "").strip()
                if not auth_index:
                    continue
                identity = _identity_of(entry)
                if identity is None:
                    # No reliable non-sensitive identifier for this entry —
                    # conservatively drop it rather than resolve it under an
                    # identity that could collide with an unrelated account.
                    continue
                resolved[auth_index] = ResolvedAccount(
                    auth_index=auth_index,
                    provider=_normalized_provider(entry),
                    disabled=bool(entry.get("disabled")),
                    account=(str(entry.get("account")) if entry.get("account") else None),
                    identity=identity,
                )
            with self._lock:
                self._by_auth_index = resolved
                self._fetched_at = now
                self._last_success_at = now
            event.success = True  # type: ignore[attr-defined]
            return True
        finally:
            with self._lock:
                self._refresh_event = None
            event.set()
