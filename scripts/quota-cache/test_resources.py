"""Unit tests for the persisted-field allowlist (`resources.sanitize_body`) and
the window-boundary freshness helper (`resources.window_reset_bound`)."""

from __future__ import annotations

import json
import unittest
from datetime import datetime, timedelta, timezone

from resources import sanitize_body, window_reset_bound

# Desensitized fixture: account "ab741ebb" (Plus pool), read 2026-09-15
# 15:17:44 JST. A five-hour window (9% used, resets 2026-09-15 18:30:13 JST)
# and a weekly window (96% used, resets 2026-09-19 17:09:45 JST).
_JST = timezone(timedelta(hours=9))


def _jst_epoch(text: str) -> float:
    return datetime.strptime(text, "%Y-%m-%d %H:%M:%S").replace(tzinfo=_JST).timestamp()


_AB741EBB_FETCHED_AT = _jst_epoch("2026-09-15 15:17:44")
_AB741EBB_FIVE_HOUR_RESET = _jst_epoch("2026-09-15 18:30:13")
_AB741EBB_WEEKLY_RESET = _jst_epoch("2026-09-19 17:09:45")

# Desensitized fixture: account "Plus21e63259", read 2026-09-20 07:24:04 JST —
# a weekly-only account (no five-hour limit at all, not missing data).
_21E63259_FETCHED_AT = _jst_epoch("2026-09-20 07:24:04")
_21E63259_WEEKLY_RESET_AT = 1790460294
_21E63259_WEEKLY_RESET_AFTER = 603650

# Desensitized fixtures reconstructed from fields measured across four real
# accounts in the same 2026-09-15 15:17:44 JST sampling pass as "ab741ebb"
# above (so they share its `_AB741EBB_FETCHED_AT`): two Plus-pool accounts and
# two Business-pool accounts, covering both a normal reading and an account
# genuinely at its weekly limit.
#
#   "86f0b99d" (Plus):     5h  12% used, resets 2026-09-15 17:37:05 JST
#                          weekly 98% used, resets 2026-09-19 17:09:45 JST
#   "d6ddca19" (Business): 5h  29% used, resets 2026-09-15 19:26:47 JST
#                          weekly  5% used, resets 2026-09-22 14:26:47 JST
#   "3cc85b99" (Business): 5h  22% used, resets 2026-09-15 18:29:55 JST
#                          weekly 100% used, resets 2026-09-19 17:10:59 JST,
#                          allowed=false, limit_reached=true
_86F0B99D_FIVE_HOUR_RESET = _jst_epoch("2026-09-15 17:37:05")
_86F0B99D_WEEKLY_RESET = _jst_epoch("2026-09-19 17:09:45")

_D6DDCA19_FIVE_HOUR_RESET = _jst_epoch("2026-09-15 19:26:47")
_D6DDCA19_WEEKLY_RESET = _jst_epoch("2026-09-22 14:26:47")

_3CC85B99_FIVE_HOUR_RESET = _jst_epoch("2026-09-15 18:29:55")
_3CC85B99_WEEKLY_RESET = _jst_epoch("2026-09-19 17:10:59")


class SanitizeBodyTests(unittest.TestCase):
    def test_claude_profile_strips_every_identity_field(self):
        raw = json.dumps({
            "account": {
                "has_claude_pro": True,
                "has_claude_max": False,
                "email": "someone@example.com",
                "uuid": "11111111-2222-3333-4444-555555555555",
            },
            "organization": {"organization_type": "claude_pro", "name": "Acme Corp", "uuid": "org-uuid"},
        })

        sanitized = json.loads(sanitize_body("claude-profile", raw))

        self.assertEqual(sanitized, {
            "account": {"has_claude_pro": True, "has_claude_max": False},
            "organization": {"organization_type": "claude_pro"},
        })
        self.assertNotIn("email", json.dumps(sanitized))
        self.assertNotIn("uuid", json.dumps(sanitized))
        self.assertNotIn("Acme Corp", json.dumps(sanitized))

    def test_codex_reset_credits_keeps_only_the_allowed_list_fields(self):
        raw = json.dumps({
            "available_count": 2,
            "account_id": "acct-123",
            "credits": [
                {"id": "c1", "status": "available", "expires_at": "2026-01-01T00:00:00Z", "amount": 500},
                {"id": "c2", "status": "used", "expires_at": None, "amount": 100},
            ],
        })

        sanitized = json.loads(sanitize_body("codex-reset-credits", raw))

        self.assertEqual(sanitized["available_count"], 2)
        self.assertNotIn("account_id", sanitized)
        self.assertEqual(len(sanitized["credits"]), 2)
        for credit in sanitized["credits"]:
            self.assertEqual(set(credit.keys()), {"id", "status", "expires_at"})

    def test_claude_usage_keeps_utilization_and_reset_fields_only(self):
        raw = json.dumps({
            "type": "usage",
            "five_hour": {"utilization": 40, "resets_at": "2026-01-01T00:00:00Z", "internal_debug": "x"},
            "unrelated_top_level_field": "should be dropped",
        })

        sanitized = json.loads(sanitize_body("claude-usage", raw))

        self.assertEqual(sanitized["five_hour"], {"utilization": 40, "resets_at": "2026-01-01T00:00:00Z"})
        self.assertNotIn("unrelated_top_level_field", sanitized)

    def test_unparsable_body_returns_none_for_the_caller_to_treat_as_a_failed_attempt(self):
        self.assertIsNone(sanitize_body("claude-usage", "not json"))

    def test_scalar_json_body_returns_none(self):
        self.assertIsNone(sanitize_body("claude-usage", "42"))
        self.assertIsNone(sanitize_body("claude-usage", '"just a string"'))
        self.assertIsNone(sanitize_body("claude-usage", "[1, 2, 3]"))

    def test_body_matching_no_keep_paths_returns_none(self):
        self.assertIsNone(sanitize_body("claude-usage", json.dumps({"unrelated": "field"})))

    def test_non_finite_json_constants_are_rejected(self):
        for raw in ('{"five_hour":{"utilization":NaN}}', '{"five_hour":{"utilization":Infinity}}',
                    '{"five_hour":{"utilization":-Infinity}}'):
            self.assertIsNone(sanitize_body("claude-usage", raw), raw)

    def test_codex_usage_keeps_the_fields_the_real_swift_mapper_and_balance_script_need(self):
        raw = json.dumps({
            "plan_type": "plus",
            "rate_limit": {
                "limit_reached": False,
                "allowed": True,
                "primary_window": {
                    "used_percent": 27,
                    "limit_window_seconds": 18000,
                    "reset_at": 1789297855,
                    "reset_after_seconds": 12300,
                },
                "secondary_window": {
                    "used_percent": 10,
                    "limit_window_seconds": 604800,
                    "reset_at": 1789900000,
                    "reset_after_seconds": 600000,
                },
            },
            "additional_rate_limits": [
                {
                    "limit_name": "spark",
                    "metered_feature": "spark",
                    "rate_limit": {
                        "limit_reached": False,
                        "primary_window": {"used_percent": 5, "reset_at": 1, "reset_after_seconds": 2, "limit_window_seconds": 3},
                    },
                }
            ],
            "credits": {"balance": 12.5, "has_credits": True},
            "rate_limit_reset_credits": {"available_count": 3},
            # Never kept: no keep_paths entry references these.
            "account_id": "acct-secret",
            "email": "someone@example.com",
        })

        sanitized = json.loads(sanitize_body("codex-usage", raw))

        self.assertEqual(sanitized["rate_limit"]["allowed"], True)
        self.assertEqual(sanitized["rate_limit"]["primary_window"]["limit_window_seconds"], 18000)
        self.assertEqual(sanitized["rate_limit"]["primary_window"]["reset_after_seconds"], 12300)
        self.assertNotIn("window_minutes", json.dumps(sanitized))
        self.assertNotIn("resets_in_seconds", json.dumps(sanitized))
        self.assertEqual(sanitized["credits"], {"balance": 12.5, "has_credits": True})
        self.assertEqual(sanitized["rate_limit_reset_credits"], {"available_count": 3})
        self.assertEqual(
            sanitized["additional_rate_limits"][0]["rate_limit"]["primary_window"]["used_percent"], 5
        )
        self.assertNotIn("account_id", json.dumps(sanitized))
        self.assertNotIn("email", json.dumps(sanitized))

    def test_a_legitimately_null_secondary_window_is_preserved_as_null_not_coerced_to_an_empty_object(self):
        # Desensitized fixture: account "Plus21e63259" — a weekly-only account
        # (`limit_window_seconds: 604800` in the *primary* slot) with no
        # five-hour limit at all. `secondary_window: null` here must round-trip
        # as `None`, never as `{}` — an empty object would make a consumer that
        # decodes a *present* window as a required, non-optional shape (e.g.
        # Swift's `CodexQuotaFetcher.Window`) fail on it, which would then fail
        # the whole surrounding `rate_limit` and silently drop the primary
        # window that was perfectly valid.
        raw = json.dumps({
            "plan_type": "plus",
            "rate_limit": {
                "limit_reached": False,
                "allowed": True,
                "primary_window": {
                    "used_percent": 0,
                    "limit_window_seconds": 604800,
                    "reset_at": _21E63259_WEEKLY_RESET_AT,
                    "reset_after_seconds": _21E63259_WEEKLY_RESET_AFTER,
                },
                "secondary_window": None,
            },
        })

        sanitized = json.loads(sanitize_body("codex-usage", raw))

        self.assertIsNone(sanitized["rate_limit"]["secondary_window"])
        self.assertEqual(sanitized["rate_limit"]["primary_window"]["used_percent"], 0)

    def test_used_percent_as_a_boolean_is_rejected_not_treated_as_a_number(self):
        # JSON `true`/`false` decode to Python `bool`, which subclasses `int` —
        # a naive `isinstance(x, (int, float))` check alone would wrongly
        # accept this as a real percentage.
        raw = json.dumps({"rate_limit": {"primary_window": {"used_percent": True, "limit_window_seconds": 18000}}})
        self.assertIsNone(sanitize_body("codex-usage", raw))

    def test_utilization_above_one_hundred_percent_is_rejected(self):
        raw = json.dumps({"five_hour": {"utilization": 150}})
        self.assertIsNone(sanitize_body("claude-usage", raw))

    def test_utilization_below_zero_percent_is_rejected(self):
        raw = json.dumps({"five_hour": {"utilization": -5}})
        self.assertIsNone(sanitize_body("claude-usage", raw))

    def test_boundary_percentages_zero_and_one_hundred_are_accepted(self):
        # Desensitized fixture: account "Business3cc85b99" — genuinely at its
        # weekly limit (100% used, `allowed: false`, `limit_reached: true`),
        # not an invalid reading.
        raw = json.dumps({
            "rate_limit": {
                "limit_reached": True,
                "allowed": False,
                "primary_window": {"used_percent": 0, "limit_window_seconds": 18000},
                "secondary_window": {"used_percent": 100, "limit_window_seconds": 604800},
            },
        })
        sanitized = json.loads(sanitize_body("codex-usage", raw))
        self.assertEqual(sanitized["rate_limit"]["primary_window"]["used_percent"], 0)
        self.assertEqual(sanitized["rate_limit"]["secondary_window"]["used_percent"], 100)

    def test_a_negative_or_boolean_duration_field_is_rejected(self):
        for bad_value in (True, -1):
            raw = json.dumps({"rate_limit": {"primary_window": {"used_percent": 10, "reset_after_seconds": bad_value}}})
            self.assertIsNone(sanitize_body("codex-usage", raw), bad_value)

    def test_used_percent_as_an_empty_object_or_list_is_rejected_not_vacuously_accepted(self):
        # `_validate_structure` used to recurse into dict/list values before
        # checking the field's own expected type — an empty container
        # satisfies `all(...)` over nothing and was wrongly accepted as a
        # valid `used_percent` reading.
        for bad_value in ({}, [], {"nested": "junk"}, [1, 2]):
            raw = json.dumps({"rate_limit": {"primary_window": {"used_percent": bad_value, "limit_window_seconds": 18000}}})
            self.assertIsNone(sanitize_body("codex-usage", raw), bad_value)

    def test_used_percent_explicitly_null_inside_a_present_window_is_rejected(self):
        # Unlike the *window itself* being null (a legitimately absent
        # five-hour limit), `used_percent: null` inside a window that is
        # present is a required numeric reading gone missing, not an
        # optional absence, and must not silently pass.
        raw = json.dumps({"rate_limit": {"primary_window": {"used_percent": None, "limit_window_seconds": 18000}}})
        self.assertIsNone(sanitize_body("codex-usage", raw))

    def test_a_bool_flag_field_that_is_not_actually_a_boolean_is_rejected(self):
        raw = json.dumps({
            "rate_limit": {
                "limit_reached": "false",
                "primary_window": {"used_percent": 10, "limit_window_seconds": 18000},
            },
        })
        self.assertIsNone(sanitize_body("codex-usage", raw))

    def test_a_null_bool_flag_is_rejected_not_treated_as_legitimately_absent(self):
        # Unlike an optional *window* (`secondary_window: null` is a real,
        # legitimate reading), there is no "flag exists but its value is
        # unknown" case for `allowed`/`limit_reached` — an explicit `null`
        # here must be rejected exactly like any other wrong-typed value, not
        # waved through as if the field had never been sent at all.
        raw = json.dumps({
            "rate_limit": {
                "allowed": None,
                "primary_window": {"used_percent": 10, "limit_window_seconds": 18000},
            },
        })
        self.assertIsNone(sanitize_body("codex-usage", raw))

    def test_an_unparsable_reset_at_string_is_rejected_not_treated_as_a_valid_timestamp(self):
        # A non-empty string alone is not a timestamp — `bool(value.strip())`
        # would wrongly accept garbage like "not-a-date" just because it is
        # non-blank.
        raw = json.dumps({
            "rate_limit": {
                "primary_window": {
                    "used_percent": 1,
                    "limit_window_seconds": 604800,
                    "reset_at": "not-a-date",
                },
            },
        })
        self.assertIsNone(sanitize_body("codex-usage", raw))

    def test_an_empty_secondary_window_is_rejected_even_though_the_primary_window_is_valid(self):
        # A malformed sibling window (present, but carrying no actual
        # `used_percent` reading) must reject the whole body even when the
        # other window in the same `rate_limit` is perfectly valid — one good
        # window must never excuse a bad one from being caught.
        raw = json.dumps({
            "rate_limit": {
                "primary_window": {"used_percent": 1, "limit_window_seconds": 604800},
                "secondary_window": {},
            },
        })
        self.assertIsNone(sanitize_body("codex-usage", raw))

    def test_a_fully_valid_body_with_both_windows_present_still_sanitizes_successfully(self):
        # Regression guard for the two fixes above: a real success — both
        # windows present, each carrying a genuine reading, real flags, real
        # reset_at — must still sanitize and must not be caught by the new
        # per-sibling-window or bool-null checks.
        raw = json.dumps({
            "rate_limit": {
                "limit_reached": False,
                "allowed": True,
                "primary_window": {
                    "used_percent": 27,
                    "limit_window_seconds": 18000,
                    "reset_at": 1789297855,
                },
                "secondary_window": {
                    "used_percent": 10,
                    "limit_window_seconds": 604800,
                    "reset_at": 1789900000,
                },
            },
        })
        sanitized = json.loads(sanitize_body("codex-usage", raw))
        self.assertEqual(sanitized["rate_limit"]["allowed"], True)
        self.assertEqual(sanitized["rate_limit"]["primary_window"]["used_percent"], 27)
        self.assertEqual(sanitized["rate_limit"]["secondary_window"]["used_percent"], 10)

    def test_a_body_with_only_plan_type_and_no_window_is_rejected_despite_matching_a_keep_path(self):
        # `plan_type` alone matches a `keep_paths` entry and has nothing for
        # `_validate_structure` to reject, but it carries no actual quota
        # reading and must not sanitize "successfully".
        raw = json.dumps({"plan_type": "plus"})
        self.assertIsNone(sanitize_body("codex-usage", raw))

    def test_an_empty_rate_limit_object_with_no_window_is_rejected(self):
        raw = json.dumps({"rate_limit": {}})
        self.assertIsNone(sanitize_body("codex-usage", raw))

    def test_a_rate_limit_with_only_null_windows_is_rejected(self):
        raw = json.dumps({"rate_limit": {"primary_window": None, "secondary_window": None}})
        self.assertIsNone(sanitize_body("codex-usage", raw))

    def test_claude_usage_with_no_valid_usage_window_is_rejected(self):
        raw = json.dumps({"type": "usage"})
        self.assertIsNone(sanitize_body("claude-usage", raw))

    def test_claude_usage_with_at_least_one_valid_window_is_accepted_even_if_others_are_absent(self):
        raw = json.dumps({"five_hour": {"utilization": 40, "resets_at": None}})
        sanitized = json.loads(sanitize_body("claude-usage", raw))
        self.assertEqual(sanitized["five_hour"]["utilization"], 40)

    def test_a_weekly_window_genuinely_at_its_limit_keeps_allowed_false_and_limit_reached_true(self):
        # Desensitized fixture: account "Business3cc85b99" — weekly window
        # truly exhausted (100% used, `allowed: false`, `limit_reached: true`).
        # `sanitize_body` must pass these flags through exactly as upstream
        # reported them; nothing here recomputes or infers them from the
        # percentage or from any elapsed time.
        raw = json.dumps({
            "rate_limit": {
                "limit_reached": True,
                "allowed": False,
                "primary_window": {"used_percent": 22, "limit_window_seconds": 18000, "reset_at": _3CC85B99_FIVE_HOUR_RESET},
                "secondary_window": {"used_percent": 100, "limit_window_seconds": 604800, "reset_at": _3CC85B99_WEEKLY_RESET},
            },
        })
        sanitized = json.loads(sanitize_body("codex-usage", raw))
        self.assertEqual(sanitized["rate_limit"]["allowed"], False)
        self.assertEqual(sanitized["rate_limit"]["limit_reached"], True)
        self.assertEqual(sanitized["rate_limit"]["secondary_window"]["used_percent"], 100)
        self.assertEqual(sanitized["rate_limit"]["primary_window"]["used_percent"], 22)


class WindowResetBoundTests(unittest.TestCase):
    """Covers `resources.window_reset_bound`, which the cache service uses to
    compute the real freshness cutoff as
    `min(fetched_at + ttl_seconds, window_reset_bound(...))`."""

    def test_resources_without_quota_windows_have_no_bound(self):
        body = json.dumps({"available_count": 3})
        self.assertIsNone(window_reset_bound("codex-reset-credits", body, fetched_at=1_700_000_000))

    def test_a_present_window_with_neither_reset_at_nor_reset_after_seconds_contributes_no_bound(self):
        body = json.dumps({"rate_limit": {"primary_window": {"used_percent": 10}}})
        self.assertIsNone(window_reset_bound("codex-usage", body, fetched_at=1_700_000_000))

    def test_a_weekly_only_account_never_gets_a_fictitious_five_hour_bound(self):
        # Desensitized fixture: account "Plus21e63259" (weekly-only, no
        # five-hour limit) — the only bound must come from the weekly window
        # actually present, never from a fabricated five-hour window.
        body = json.dumps({
            "rate_limit": {
                "primary_window": {
                    "used_percent": 0,
                    "limit_window_seconds": 604800,
                    "reset_at": _21E63259_WEEKLY_RESET_AT,
                    "reset_after_seconds": _21E63259_WEEKLY_RESET_AFTER,
                },
                "secondary_window": None,
            },
        })
        bound = window_reset_bound("codex-usage", body, fetched_at=_21E63259_FETCHED_AT)
        self.assertEqual(bound, _21E63259_WEEKLY_RESET_AT)

    def test_absolute_reset_at_wins_over_reset_after_seconds_when_both_are_present(self):
        body = json.dumps({
            "rate_limit": {
                "primary_window": {"used_percent": 9, "reset_at": _AB741EBB_FIVE_HOUR_RESET, "reset_after_seconds": 999},
            },
        })
        bound = window_reset_bound("codex-usage", body, fetched_at=_AB741EBB_FETCHED_AT)
        self.assertEqual(bound, _AB741EBB_FIVE_HOUR_RESET)

    def test_reset_after_seconds_is_anchored_to_fetched_at_not_to_whatever_now_is(self):
        # Same still-cached body read twice at two different real times must
        # produce the same bound both times — a relative countdown must never
        # extend just because the cache happened to be read again.
        body = json.dumps({"rate_limit": {"primary_window": {"used_percent": 9, "reset_after_seconds": 18000}}})
        first = window_reset_bound("codex-usage", body, fetched_at=1_700_000_000)
        second = window_reset_bound("codex-usage", body, fetched_at=1_700_000_000)  # same fetched_at, as a real re-read would pass
        self.assertEqual(first, 1_700_000_000 + 18000)
        self.assertEqual(first, second)
        # A caller that (incorrectly) anchored to "now" instead of the row's
        # own fetched_at would have produced a larger value here.
        self.assertNotEqual(window_reset_bound("codex-usage", body, fetched_at=1_700_000_100), first)

    def test_bound_is_independent_of_which_slot_the_five_hour_and_weekly_windows_arrive_in(self):
        # Desensitized fixture: account "ab741ebb", windows swapped from their
        # usual primary/secondary slots — the combined bound (the sooner of
        # the two real resets) must be identical either way.
        normal = json.dumps({
            "rate_limit": {
                "primary_window": {"used_percent": 9, "reset_at": _AB741EBB_FIVE_HOUR_RESET},
                "secondary_window": {"used_percent": 96, "reset_at": _AB741EBB_WEEKLY_RESET},
            },
        })
        swapped = json.dumps({
            "rate_limit": {
                "primary_window": {"used_percent": 96, "reset_at": _AB741EBB_WEEKLY_RESET},
                "secondary_window": {"used_percent": 9, "reset_at": _AB741EBB_FIVE_HOUR_RESET},
            },
        })
        self.assertEqual(
            window_reset_bound("codex-usage", normal, fetched_at=_AB741EBB_FETCHED_AT),
            window_reset_bound("codex-usage", swapped, fetched_at=_AB741EBB_FETCHED_AT),
        )
        self.assertEqual(
            window_reset_bound("codex-usage", normal, fetched_at=_AB741EBB_FETCHED_AT), _AB741EBB_FIVE_HOUR_RESET
        )

    def test_claude_resets_at_iso8601_strings_are_parsed(self):
        body = json.dumps({"five_hour": {"utilization": 40, "resets_at": "2026-09-15T09:30:13Z"}})
        bound = window_reset_bound("claude-usage", body, fetched_at=1_700_000_000)
        self.assertEqual(bound, datetime(2026, 9, 15, 9, 30, 13, tzinfo=timezone.utc).timestamp())

    def test_the_earliest_boundary_across_four_real_accounts_is_each_accounts_own_five_hour_reset(self):
        # Desensitized fixtures reconstructed from fields measured across four
        # real accounts in the 2026-09-15 15:17:44 JST sampling pass described
        # above the fixture constants. For every one of the four, the
        # five-hour window's own `reset_at` lands sooner than the weekly
        # window's — so the *actual* earliest refresh boundary must always be
        # the five-hour reset, never the weekly one, and never something
        # guessed from `reset_after_seconds` or the read time. This holds even
        # for "3cc85b99", whose weekly window is genuinely at 100% used with
        # `allowed: false` — reaching the limit does not change which window
        # governs the boundary.
        cases = [
            ("ab741ebb", 9, _AB741EBB_FIVE_HOUR_RESET, 96, _AB741EBB_WEEKLY_RESET),
            ("86f0b99d", 12, _86F0B99D_FIVE_HOUR_RESET, 98, _86F0B99D_WEEKLY_RESET),
            ("d6ddca19", 29, _D6DDCA19_FIVE_HOUR_RESET, 5, _D6DDCA19_WEEKLY_RESET),
            ("3cc85b99", 22, _3CC85B99_FIVE_HOUR_RESET, 100, _3CC85B99_WEEKLY_RESET),
        ]
        for account, five_hour_used, five_hour_reset, weekly_used, weekly_reset in cases:
            body = json.dumps({
                "rate_limit": {
                    "primary_window": {"used_percent": five_hour_used, "limit_window_seconds": 18000, "reset_at": five_hour_reset},
                    "secondary_window": {"used_percent": weekly_used, "limit_window_seconds": 604800, "reset_at": weekly_reset},
                },
            })
            bound = window_reset_bound("codex-usage", body, fetched_at=_AB741EBB_FETCHED_AT)
            self.assertEqual(bound, five_hour_reset, account)

    def test_a_weekly_window_genuinely_at_its_limit_still_reports_its_real_reset_boundary(self):
        # Desensitized fixture: account "Business3cc85b99" — weekly window at
        # 100% used, allowed=false, limit_reached=true. Reaching the limit
        # must never make the window look already-reset (no bound) or push
        # the bound to "now" — the sanitized body still carries its own real
        # `reset_at`, which `window_reset_bound` must surface unchanged.
        raw = json.dumps({
            "rate_limit": {
                "limit_reached": True,
                "allowed": False,
                "primary_window": {"used_percent": 22, "limit_window_seconds": 18000, "reset_at": _3CC85B99_FIVE_HOUR_RESET},
                "secondary_window": {"used_percent": 100, "limit_window_seconds": 604800, "reset_at": _3CC85B99_WEEKLY_RESET},
            },
        })
        sanitized = sanitize_body("codex-usage", raw)
        bound = window_reset_bound("codex-usage", sanitized, fetched_at=_AB741EBB_FETCHED_AT)
        self.assertEqual(
            bound, _3CC85B99_FIVE_HOUR_RESET,
            "the sooner five-hour reset governs even though the weekly window is the one at its limit",
        )


if __name__ == "__main__":
    unittest.main()


class DisabledExtraUsageRegressionTests(unittest.TestCase):
    def test_disabled_extra_usage_null_is_valid_but_enabled_null_is_not(self):
        import json
        base = {"five_hour": {"utilization": 99, "resets_at": "2026-09-20T03:30:00+00:00"},
                "seven_day": {"utilization": 65, "resets_at": "2026-09-22T16:00:00+00:00"},
                "extra_usage": {"is_enabled": False, "utilization": None, "used_credits": None, "monthly_limit": None}}
        self.assertIsNotNone(sanitize_body("claude-usage", json.dumps(base)))
        base["extra_usage"]["is_enabled"] = True
        self.assertIsNone(sanitize_body("claude-usage", json.dumps(base)))
        base["extra_usage"]["is_enabled"] = False
        base["five_hour"]["utilization"] = None
        self.assertIsNone(sanitize_body("claude-usage", json.dumps(base)))
