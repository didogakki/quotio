# Quotio quota-cache service

A single local, **read-only**, **GET-only** HTTP service that sits between
CLIProxyAPI's (CPA) `/v0/management/api-call` pass-through and its three real
consumers — Quotio's `RemoteManagementQuotaFetcher`, `cpa_quota_recovery.py`,
and `cpa_newapi_balance.py` — so all three share **one** upstream fetch per
account/resource instead of each polling CPA (and, transitively, the real
provider) on its own schedule.

This directory is source only. Nothing here is wired into a running deploy by
this change; deployment (systemd unit install, config values, TLS/reverse
proxy in front of the two source hosts, actual secrets) is a separate,
infra-side step.

## Contract

```
GET /quota-cache/v1/{pool}/{resource}?auth_index=...[&require_fresh=1]
Authorization: Bearer <pool's existing CLIProxyAPI management key>
```

- **`pool`**: `plus` | `business` — must be a pool this service was configured
  with (`config.json`'s `pools` map). Any other value is rejected as if the
  Authorization header were simply wrong (401) — the service never reveals
  whether a pool name exists.
- **`resource`**: a closed whitelist, each mapped to exactly one upstream
  method/URL/header set (see `resources.py` — never derived from the request):
  `codex-usage`, `codex-reset-credits`, `claude-usage`, `claude-profile`,
  `grok-usage`, `grok-settings`. Unknown resource → `404 unknown_resource`.
- **`auth_index`**: required, `^[A-Za-z0-9._:-]{1,256}$`. Resolved against a
  short-TTL (`auth_files_ttl_seconds`, default 5s) local cache of CPA's own
  `/v0/management/auth-files` listing — never trusted from the client beyond
  "which account to look up". Unknown → `404 unknown_account`; disabled →
  `403 account_disabled`; provider doesn't match the resource → `400
  provider_mismatch`.
- **`require_fresh=1`**: for callers that make a decision from the result
  (the balance/recovery schedulers) — TTL-fresh data is still served
  instantly either way, but once the entry has actually gone stale this flag
  forces a real upstream attempt and returns `503 upstream_unavailable`
  instead of ever handing back the old body. A normal (UI) read without this
  flag may receive the old body with `"stale": true` once its TTL has
  elapsed and a refresh attempt has failed.
- Every request accepts **only** `auth_index` and `require_fresh` as query
  parameters — anything else (e.g. an attempted `url=`) is `400 bad_request`
  before any account lookup happens. Combined with the fixed resource→URL
  mapping, nothing about the outbound request is ever influenced by the
  client, which is what makes the outbound side immune to SSRF.
- Only `GET` is accepted on `/quota-cache/v1/...`; every other method is
  `405 method_not_allowed`.

### Response envelope

```json
{
  "result": {"status_code": 200, "header": {"...": ["..."]}, "body": "..."},
  "fetched_at": 1737400000.0,
  "stale": false,
  "last_attempt": 1737400000.0,
  "next_retry_at": null
}
```

- `result` mirrors CPA's own `/api-call` response shape (`status_code`,
  `header`, `body`) exactly, so every existing consumer-side response mapper
  works unchanged.
- `fetched_at` is the real wall-clock time the cached value was **last
  actually obtained from upstream** — never the moment this response was
  read from cache. A `Retry-After` header inside `result.header` must be
  interpreted relative to `fetched_at`, not to "now".
- `stale` is `true` only when the TTL has elapsed and the most recent refresh
  attempt failed (so this is the last-known-good value, not a fresh one).
- `last_attempt` / `next_retry_at` describe the refresh attempt itself
  (whether or not it produced the `result` currently being served).
- Only a successful upstream attempt is ever cached/returned as
  `"stale": false`; a failed attempt never overwrites `result` and is never
  reported as fresh.

### Errors

Every error is one fixed, sanitized `{"error": "<code>"}` body — never an
upstream body, header, or exception message:

| HTTP | code | when |
|---|---|---|
| 400 | `bad_request` | missing/malformed `auth_index`, or an unexpected query parameter |
| 400 | `provider_mismatch` | the account's own provider doesn't match the resource |
| 401 | `unauthorized` | missing/wrong `Authorization` bearer for the pool in the path |
| 403 | `account_disabled` | the auth-file listing reports this account as disabled |
| 403 | `forbidden` | `/quota-cache/health` requested from a non-loopback peer |
| 404 | `not_found` | path doesn't match `/quota-cache/v1/{pool}/{resource}` or `/quota-cache/health` |
| 404 | `unknown_resource` / `unknown_account` | resource not in the whitelist / auth_index not found in the listing |
| 405 | `method_not_allowed` | non-GET |
| 500 | `internal_error` | unexpected server-side exception (never leaks detail or a stack trace) |
| 503 | `not_ready` / `upstream_unavailable` | in backoff with no cached success yet, or (with `require_fresh=1`) a real attempt just failed |
| 503 | `busy` | `max_concurrent_requests` in-flight requests already; the service is bounded rather than queueing unboundedly |

### `/quota-cache/health`

`GET`, only ever answered for a loopback peer (`127.0.0.1`/`::1`) **and**
`Authorization: Bearer <any one configured pool's management key>` — loopback
alone is not a trustworthy boundary, since a same-host reverse tunnel (e.g.
cloudflared) also connects from loopback, so it is defense in depth on top of
the auth check, not a replacement for it. Returns `{"hits", "upstream_calls",
"coalesced", "errors"}` — counters only, never an account identity or secret.

## TTLs

| resource | TTL | rationale |
|---|---|---|
| `codex-usage`, `claude-usage`, `grok-usage` | 300s | matches the shared "collect once" cadence the balance/recovery scripts and Quotio's UI both need |
| `codex-reset-credits`, `claude-profile`, `grok-settings` | 1800s | slow-changing supplementary data (plan/credits), safe to refresh far less often |

Both are configurable per-resource only by editing `resources.py`'s
`RESOURCES` table — there is intentionally no per-request TTL override.

A cached success is actually fresh only until whichever comes first: this
flat TTL, or the reset boundary of any quota window present in the cached
body (`resources.window_reset_bound`, e.g. Codex's `primary_window`/
`secondary_window` or Claude's `five_hour`/`seven_day*`). Once a window's own
`reset_at` (or `reset_after_seconds`, anchored to the row's `fetched_at` —
never to "now", so a still-cached body read again later never has its
countdown extended) has passed, the percentages inside it are no longer a
reading of the *current* window even if the flat TTL has not elapsed yet, so
the row is treated as stale and a real refresh is triggered — this cache
never synthesizes a "the window reset" value itself. `primary_window`/
`secondary_window` are positions, not window kinds: a window is only ever
identified by its own `limit_window_seconds`/`reset_at`, so an account
reporting a lone weekly window with no five-hour limit at all is never held
to a fabricated five-hour boundary, and swapping which slot the five-hour vs.
weekly window arrives in never changes the computed bound. A window that is
legitimately absent (`null`) or carries neither a `reset_at`/`resets_at` nor a
`reset_after_seconds` contributes no bound at all — never a guessed one.

## How refresh actually happens

There is no background poller. A request that finds its cached entry
stale or missing triggers the refresh itself, coalesced per
`(pool, resource, auth_index)` key: concurrent readers for the same key all
wait on the one in-flight upstream call instead of issuing their own
("singleflight"). A request that finds fresh (within-TTL) data never
triggers an upstream call at all, `require_fresh` or not.

On failure, the entry backs off before the next attempt: an upstream `429`'s
own `Retry-After` header (delta-seconds or HTTP-date) is honored as the
backoff window (capped at `max_retry_after_seconds`); anything else backs off
exponentially from `failure_backoff_seconds`, doubling per consecutive
failure, capped at `failure_backoff_max_seconds`. A request that arrives
inside an active backoff window never re-attempts upstream — it gets the old
`stale: true` result (non-scheduler reads) or `503 not_ready` (`require_fresh`
reads, or no success has ever been recorded).

If the account behind `auth_index` gets replaced on CPA's side (a different
underlying auth-file identity reassigned to the same index), the next request
detects the identity mismatch and invalidates the old cached row instead of
serving/mixing data from the wrong account. A refresh that was already
in-flight when the swap happened discards its own result rather than writing
it over the newer account's state. That check itself requires a listing
proven current as of the refresh (`AuthFileResolver.resolve(...,
force_refresh=True)`); if that forced listing attempt fails, the refresh
fails closed (never writes a result) rather than falling back to whatever
mapping existed before — a forced refresh exists specifically to prove the
mapping is current, so silently trusting an unconfirmed old one would defeat
the isolation it exists to provide.

Passing the resource's field allowlist (`resources.py`'s `keep_paths`) is
necessary but not sufficient for a response to be cached as a success:
`sanitize_body` also structurally validates every kept value — a percentage
field (`used_percent`/`utilization`) must be a real, finite number in
`[0, 100]` (JSON's `true`/`false` never counts, even though `bool` is a
subclass of `int`), and a duration field (`reset_after_seconds`/
`limit_window_seconds`) must be a non-negative finite number. A response that
fails this — an out-of-range percentage, a boolean masquerading as a number,
or a wrong-shaped 2xx — is treated exactly like an upstream failure: rejected,
backed off, and never allowed to overwrite the last known-good cached
success.

## Persistence

State lives in one SQLite file (`state_db`) so `success` and backoff survive a
restart — refusing to relearn backoff state on every restart would otherwise
let a service bounce turn into a burst of retries against a still-failing
upstream. The parent directory is created `0700` and the database file is
`chmod 0600`. Only the fields in each resource's `keep_paths` allowlist
(`resources.py`) are ever persisted from a successful response body — e.g.
`claude-profile` keeps only the two plan-determining boolean flags and the
organization type, never the account's email/uuid/org name. Auth-file
listings themselves (and, always, provider tokens) are **never** persisted —
only the short-lived in-memory `AuthFileResolver` cache holds them, and even
that only holds the fields needed to answer "which account, which provider,
disabled?", never a token.

## Deployment (infra-owned; not part of this change)

1. Copy this directory to both `plus` and `business` hosts (or one host
   serving both pools, if colocated) alongside `config.json` (start from
   `config.example.json`; do not commit real `base_url`/`secrets_env` values).
2. `quotio-quota-cache.service` is a **user-level** (`systemctl --user`)
   template — install it to `~/.config/systemd/user/quotio-quota-cache.service`
   under the account that should run it, adjust every path in it for that
   account's home directory, then `systemctl --user enable --now
   quotio-quota-cache`. It runs as that user directly (no `DynamicUser=`,
   which is system-unit-only), so any `secrets_env` file it needs must already
   be readable by that same user — no extra `ReadOnlyPaths` needed unless one
   lives outside that user's own home directory.
3. Put a reverse proxy path in front of it on the existing HTTPS domain each
   pool's consumers already reach (e.g. `.../quota-cache/v1/plus/...` →
   `127.0.0.1:8328/quota-cache/v1/plus/...`) if consumers reach this pool over
   a network hop; same-host consumers can talk to `127.0.0.1:8328` directly.
4. Point Quotio's `RemoteQuotaSourceConfig.quotaCacheBaseURL` at the
   pool-scoped base (e.g. `https://<domain>/quota-cache/v1/plus` — **not**
   including a trailing resource segment; Quotio appends `/{resource}`
   itself) for the two sources that should read through the cache. Leave it
   unset on every other source.
5. Add `"quota_cache_base_url": "http://127.0.0.1:8328/quota-cache/v1/plus"`
   (same pool-scoped base convention) to the corresponding pool entry in
   `cpa_quota_recovery.py`'s own `--config` JSON — `cpa_newapi_balance.py`
   picks up the same field automatically since it loads that same recovery
   config for pool definitions.

## Testing

Stdlib `unittest` only; every test injects a fake CPA client — nothing here
ever makes a real network request:

```bash
cd scripts/quota-cache
python3 -B -m unittest discover -s . -p 'test_*.py'
```

Covers: singleflight coalescing (5 concurrent readers → 1 upstream call),
pool isolation (shared `auth_index` across pools never cross-authenticates or
cross-caches), auth/method/unknown-resource/SSRF-query-param/disabled-account
rejection, TTL fresh→stale transitions, 429 `Retry-After` and exponential
backoff (including the backoff window itself blocking a second upstream
call), SQLite restart persistence (including file/directory permissions),
`require_fresh` returning 503 instead of stale data, account-replacement
cache invalidation, and the persisted-field allowlist stripping identity
fields from a profile response.

Also covers the window-aware freshness cutoff added on top of the flat TTL
(`WindowBoundaryFreshnessTests` in `test_service.py`, `WindowResetBoundTests`
in `test_resources.py`): a window's own reset forcing a refresh before the
flat TTL elapses, each window invalidating independently of the others, a
weekly-only account never going stale on a fabricated five-hour schedule, the
bound being identical regardless of which slot the five-hour/weekly window
arrives in, and a relative `reset_after_seconds` countdown never being
extended by re-reading the same still-cached body later. `SanitizeBodyTests`
also covers the structural validation added to the persisted-field allowlist
(a boolean masquerading as a percentage, an out-of-range percentage, a
negative/boolean duration) and a legitimately absent window round-tripping as
`null` rather than being coerced into `{}`. `ForceRefreshFailureTests` in
`test_auth_files.py` covers `AuthFileResolver` failing closed — never falling
back to the previous mapping — when a `force_refresh=True` listing attempt
itself fails.

## Files

- `service.py` — the HTTP service (`python3 service.py --config config.json`).
- `resources.py` — the resource whitelist and the persisted-field allowlist.
- `auth_files.py` — the short-TTL CPA auth-files resolver.
- `store.py` — the SQLite-backed cache state.
- `quota_cache_client.py` — the consumer-side HTTP client, shared by the two
  scripts below (and a reference for any other future consumer).
- `cpa_quota_recovery.py`, `cpa_newapi_balance.py` — minimally patched copies
  of the two scripts read from the production host: each gained one optional
  `quota_cache_base_url` pool config field that, when set, routes only the
  usage probe/collection call through this cache with `require_fresh=1`.
  Every decision function, weighting formula, retry, and rollback path is
  byte-for-byte unchanged; the recovery timer these scripts implement stays
  disabled by this change, as before.
- `config.example.json`, `quotio-quota-cache.service` — deployment templates.
- `test_*.py` — the unit test suite described above.


## Mixed-window balancing policy (opt-in)

`scoring_policy: "weekly_headroom_v1"` evaluates the actual 604800-second
window regardless of its primary/secondary position. All eligible accounts
must supply a valid unexpired weekly window; invalid/unknown observations
abort the entire round without writes. A missing 18000-second window means
no five-hour restriction, not missing quota.

Score = `(weekly_remaining_percent - reserve)_+ / max(weekly_reset_hours, 2)`
multiplied by `(five_hour_remaining_percent - reserve)_+ / (100 - reserve)`
only when a five-hour window exists. Any exhausted window or explicit
unavailability produces zero. Thus only weekly percentages are compared per
hour; the five-hour signal is a dimensionless headroom penalty, not another
incompatible percent/hour budget. Equal normalized weekly percentages are an
allocation policy, **not evidence that Plus and Business have equal token
capacity**. No unverified plan capacity multiplier is invented. This is a
conservative scheduling heuristic, not a guarantee of equal token throughput
or of finishing every account exactly at reset.

The existing integer weight bounds, update thresholds and rollback remain.
`quota_cache_base_urls` in the balance config maps `plus` and `business` to
loopback cache paths; this avoids editing or activating recovery config.
All reads require fresh cache entries. Keep recovery timers disabled.
