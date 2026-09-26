import Foundation
import QuotioDomain
import XCTest

@testable import QuotioPresentation

@MainActor
final class CodexResetCreditSummaryFormattingTests: XCTestCase {
    /// Missing data (`nil` summary) is a distinct concept from a genuine zero reading —
    /// callers must check `codexResetCreditSummary` for `nil` themselves; this type only
    /// ever formats an already-successful summary.
    func testFormattedSummaryShowsExactJSTDateForAPositiveReadingWithExpiry() {
        // 2026-09-21T07:22:00Z == 2026-09-21 16:22 JST.
        let date = Date(timeIntervalSince1970: 1_789_975_320)
        let summary = CodexResetCreditSummary(availableCount: 2, nearestExpiryAt: date)

        let expected = String(
            format: "providers.codex.resetCredits".localizedStatic(),
            2, "2026-09-21 16:22 JST"
        )
        XCTAssertEqual(summary.formattedSummary, expected)
    }

    /// A zero reading is a real, successful result — it must say so explicitly rather
    /// than falling back to the "no expiry" text, which only applies when credits exist
    /// but genuinely carry no expiry.
    func testFormattedSummaryDoesNotConflateZeroCreditsWithNoExpiry() {
        let summary = CodexResetCreditSummary(availableCount: 0, nearestExpiryAt: nil)

        XCTAssertEqual(summary.formattedSummary, "providers.codex.resetCredits.none".localizedStatic())
        XCTAssertNotEqual(summary.formattedSummary, "providers.codex.resetCredits.noExpiry".localizedStatic())
    }

    /// Available credits that genuinely carry no expiry get the distinct "no expiry"
    /// fallback — never confused with the zero-credits case above.
    func testFormattedSummaryShowsNoExpiryWhenCreditsExistWithoutOne() {
        let summary = CodexResetCreditSummary(availableCount: 3, nearestExpiryAt: nil)

        let expected = String(
            format: "providers.codex.resetCredits".localizedStatic(),
            3, "providers.codex.resetCredits.noExpiry".localizedStatic()
        )
        XCTAssertEqual(summary.formattedSummary, expected)
    }

    /// The menu-dropdown-only variant drops the year/`JST` suffix via `compactJST`,
    /// unlike `formattedSummary`'s full `absoluteJST` date.
    func testCompactFormattedSummaryUsesCompactJSTDate() {
        let date = Date(timeIntervalSince1970: 1_789_975_320)
        let summary = CodexResetCreditSummary(availableCount: 2, nearestExpiryAt: date)

        let expected = String(format: "providers.codex.resetCredits".localizedStatic(), 2, "09-21 16:22")
        XCTAssertEqual(summary.compactFormattedSummary, expected)
    }
}

final class ProviderQuotaAvailabilityStatusTests: XCTestCase {
    func testAvailabilityStatusIsNilForANormalAccount() {
        let quota = ProviderQuota()
        XCTAssertNil(quota.availabilityStatus)
    }

    func testAvailabilityStatusIsAuthInvalidForClassifiedOAuthFailure() {
        let quota = ProviderQuota(remoteAccountIssue: .invalidOAuth)
        XCTAssertEqual(quota.availabilityStatus, .authInvalid)
    }

    func testAvailabilityStatusPrefersAuthInvalidOverOtherUnavailableStates() {
        let quota = ProviderQuota(
            isForbidden: true,
            remoteAccountIssue: .invalidOAuth,
            isTemporarilyUnavailable: true
        )
        XCTAssertEqual(quota.availabilityStatus, .authInvalid)
    }

    func testAvailabilityStatusIsFrozenWhenForbidden() {
        let quota = ProviderQuota(isForbidden: true)
        XCTAssertEqual(quota.availabilityStatus, .frozen)
    }

    func testAvailabilityStatusIsCoolingWhenTemporarilyUnavailable() {
        let quota = ProviderQuota(isTemporarilyUnavailable: true)
        XCTAssertEqual(quota.availabilityStatus, .cooling)
    }

    /// A rejected credential is the more severe condition, so it must win when a remote
    /// source's last-known-good reading also carries a stale `isTemporarilyUnavailable`.
    func testAvailabilityStatusPrefersFrozenOverCooling() {
        let quota = ProviderQuota(isForbidden: true, isTemporarilyUnavailable: true)
        XCTAssertEqual(quota.availabilityStatus, .frozen)
    }

    func testAvailabilityStatusIsNilWhenTemporarilyUnavailableIsExplicitlyFalse() {
        let quota = ProviderQuota(isTemporarilyUnavailable: false)
        XCTAssertNil(quota.availabilityStatus)
    }

    // MARK: - Codex session/weekly exhaustion

    func testAvailabilityStatusIsSessionExhaustedWhenCodexSessionMetricIsZero() {
        let quota = ProviderQuota(models: [
            QuotaMetric(name: "codex-session", percentage: 0, resetTime: ""),
            QuotaMetric(name: "codex-weekly", percentage: 40, resetTime: ""),
        ])
        XCTAssertEqual(quota.availabilityStatus, .sessionExhausted)
    }

    func testAvailabilityStatusIsWeeklyExhaustedWhenCodexWeeklyMetricIsZero() {
        let quota = ProviderQuota(models: [
            QuotaMetric(name: "codex-session", percentage: 40, resetTime: ""),
            QuotaMetric(name: "codex-weekly", percentage: 0, resetTime: ""),
        ])
        XCTAssertEqual(quota.availabilityStatus, .weeklyExhausted)
    }

    func testAvailabilityStatusIsSessionAndWeeklyExhaustedWhenBothMetricsAreZero() {
        let quota = ProviderQuota(models: [
            QuotaMetric(name: "codex-session", percentage: 0, resetTime: ""),
            QuotaMetric(name: "codex-weekly", percentage: 0, resetTime: ""),
        ])
        XCTAssertEqual(quota.availabilityStatus, .sessionAndWeeklyExhausted)
    }

    /// A Claude account's own analogous "five-hour-session" metric must never trigger
    /// the Codex-only exhausted status — the metric-name match is deliberately narrow.
    func testAvailabilityStatusIgnoresNonCodexMetricNamesWhenExhausted() {
        let quota = ProviderQuota(models: [QuotaMetric(name: "five-hour-session", percentage: 0, resetTime: "")])
        XCTAssertNil(quota.availabilityStatus)
    }

    /// A rejected credential or a cooling account is the more severe condition, so it
    /// must win over an exhausted metric reading.
    func testAvailabilityStatusPrefersFrozenAndCoolingOverExhausted() {
        let frozenAndExhausted = ProviderQuota(
            models: [QuotaMetric(name: "codex-session", percentage: 0, resetTime: "")],
            isForbidden: true
        )
        XCTAssertEqual(frozenAndExhausted.availabilityStatus, .frozen)

        let coolingAndExhausted = ProviderQuota(
            models: [QuotaMetric(name: "codex-weekly", percentage: 0, resetTime: "")],
            isTemporarilyUnavailable: true
        )
        XCTAssertEqual(coolingAndExhausted.availabilityStatus, .cooling)
    }
}

final class ProviderQuotaExhaustionCountdownTests: XCTestCase {
    func testRecoveryDateUsesTheExhaustedMetricsOwnResetTime() {
        let resetTime = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: 2_000))
        let quota = ProviderQuota(models: [QuotaMetric(name: "codex-session", percentage: 0, resetTime: resetTime)])

        XCTAssertEqual(quota.quotaExhaustionRecoveryDate, Date(timeIntervalSince1970: 2_000))
    }

    /// When both windows are exhausted, the account only reads as usable again once
    /// neither reset has passed — so the badge must count down to the *later* of the
    /// two resets, never the earlier one.
    func testRecoveryDateIsTheLaterResetWhenBothWindowsAreExhausted() {
        let earlier = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: 1_000))
        let later = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: 5_000))
        let quota = ProviderQuota(models: [
            QuotaMetric(name: "codex-session", percentage: 0, resetTime: earlier),
            QuotaMetric(name: "codex-weekly", percentage: 0, resetTime: later),
        ])

        XCTAssertEqual(quota.quotaExhaustionRecoveryDate, Date(timeIntervalSince1970: 5_000))
    }

    /// Never a fabricated fallback: an exhausted metric with no parseable `resetTime`
    /// leaves the recovery date/countdown/absolute text all `nil`.
    func testRecoveryDateIsNilWhenTheExhaustedMetricsResetTimeIsUnparseable() {
        let quota = ProviderQuota(models: [QuotaMetric(name: "codex-session", percentage: 0, resetTime: "")])

        XCTAssertNil(quota.quotaExhaustionRecoveryDate)
        XCTAssertNil(quota.formattedQuotaExhaustionCountdown)
        XCTAssertNil(quota.formattedQuotaExhaustionAbsolute)
    }

    /// Both windows exhausted, but only one reset is parseable: this must never fall
    /// back to the one date it *could* parse — that would report the account as
    /// available again the moment that single window resets, while the other exhausted
    /// window (whose real reset is simply unknown) is silently ignored. Both must
    /// resolve before either is trusted.
    func testRecoveryDateIsNilWhenOnlyOneOfBothExhaustedWindowsResetTimeIsParseable() {
        let parseable = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: 5_000))
        let quota = ProviderQuota(models: [
            QuotaMetric(name: "codex-session", percentage: 0, resetTime: ""),
            QuotaMetric(name: "codex-weekly", percentage: 0, resetTime: parseable),
        ])

        XCTAssertNil(quota.quotaExhaustionRecoveryDate)
        XCTAssertNil(quota.formattedQuotaExhaustionCountdown)
        XCTAssertNil(quota.formattedQuotaExhaustionAbsolute)
    }
}

final class ProviderQuotaAvailabilityCountdownTests: XCTestCase {
    /// Never a fabricated guess: neither `isForbidden` nor `isTemporarilyUnavailable`
    /// carries its own recovery timestamp, so an account with no real
    /// `availabilityRecoveryDate` has no countdown/absolute estimate at all — regardless
    /// of what its quota models' own reset times say.
    func testNoCountdownOrAbsoluteWhenNoRealRecoveryDateIsKnown() {
        let quota = ProviderQuota(isForbidden: true)
        XCTAssertNil(quota.formattedAvailabilityCountdown)
        XCTAssertNil(quota.formattedAvailabilityAbsolute)
    }

    /// Regression: a quota model's own `resetTime` (the provider's usage-window reset,
    /// e.g. Claude's 5-hour session window) must never be mistaken for the account's
    /// freeze/cooldown recovery time, even when it is the only time-like value on the
    /// reading. Only `availabilityRecoveryDate` may drive the countdown.
    func testModelResetTimeIsNeverUsedAsAvailabilityRecoveryTime() {
        let soon = ISO8601DateFormatter().string(from: Date().addingTimeInterval(3 * 3600 + 32 * 60))
        let quota = ProviderQuota(
            models: [QuotaMetric(name: "codex-session", percentage: 10, resetTime: soon)],
            isForbidden: true,
            isTemporarilyUnavailable: true,
            availabilityRecoveryDate: nil
        )
        XCTAssertNil(quota.formattedAvailabilityCountdown)
        XCTAssertNil(quota.formattedAvailabilityAbsolute)
    }

    /// A recovery time already in the past (the source's own signal has lapsed since
    /// this last-known-good reading was captured) is not a usable estimate either.
    func testNoCountdownWhenTheRecoveryDateIsInThePast() {
        let past = Date().addingTimeInterval(-3600)
        let quota = ProviderQuota(isTemporarilyUnavailable: true, availabilityRecoveryDate: past)
        XCTAssertNil(quota.formattedAvailabilityCountdown)
        XCTAssertNil(quota.formattedAvailabilityAbsolute)
    }

    /// The real, still-upcoming `availabilityRecoveryDate` drives the countdown,
    /// formatted with the same compact h/m style as the menu bar's own reset countdown.
    func testCountdownUsesTheRealAvailabilityRecoveryDate() {
        // A 30s cushion keeps the elapsed test time from ever crossing a minute
        // boundary between building this fixture and the countdown reading the clock.
        let soon = Date().addingTimeInterval(3 * 3600 + 32 * 60 + 30)
        let quota = ProviderQuota(isTemporarilyUnavailable: true, availabilityRecoveryDate: soon)
        XCTAssertEqual(quota.formattedAvailabilityCountdown, "3h32m")
        XCTAssertNotNil(quota.formattedAvailabilityAbsolute)
    }
}

/// `menuAvailabilityStatus` is the menu-dropdown-only override of `availabilityStatus`
/// for a Codex account whose limit-reached provenance is known. It must never change
/// `availabilityStatus` itself (aggregate math, the main window, and the pinned status
/// bar all keep reading the unmodified `frozen`/`cooling` signal).
final class ProviderQuotaMenuAvailabilityStatusTests: XCTestCase {
    /// OAuth-invalid must win even over a known-reached, truly-zero-metric account —
    /// a rejected credential is unrelated to which quota window happens to be spent.
    func testMenuStatusPrefersAuthInvalidOverReachedAndZeroMetric() {
        let quota = ProviderQuota(
            models: [QuotaMetric(name: "codex-weekly", percentage: 0, resetTime: "")],
            isForbidden: true,
            remoteAccountIssue: .invalidOAuth,
            codexLimitReached: true
        )
        XCTAssertEqual(quota.menuAvailabilityStatus, .authInvalid)
    }

    /// The core bug this field fixes: a known-reached Codex account whose own weekly
    /// metric is truly (not rounded) zero must present as exhausted, not frozen.
    func testMenuStatusOverridesFrozenWhenLimitReachedIsKnownAndWeeklyMetricIsZero() {
        let quota = ProviderQuota(
            models: [QuotaMetric(name: "codex-weekly", percentage: 0, resetTime: "")],
            isForbidden: true,
            codexLimitReached: true
        )
        XCTAssertEqual(quota.availabilityStatus, .frozen, "the shared base status must stay frozen")
        XCTAssertEqual(quota.menuAvailabilityStatus, .weeklyExhausted)
    }

    func testMenuStatusOverridesFrozenWhenLimitReachedIsKnownAndSessionMetricIsZero() {
        let quota = ProviderQuota(
            models: [QuotaMetric(name: "codex-session", percentage: 0, resetTime: "")],
            isForbidden: true,
            codexLimitReached: true
        )
        XCTAssertEqual(quota.menuAvailabilityStatus, .sessionExhausted)
    }

    func testMenuStatusOverridesFrozenWhenLimitReachedIsKnownAndBothMetricsAreZero() {
        let quota = ProviderQuota(
            models: [
                QuotaMetric(name: "codex-session", percentage: 0, resetTime: ""),
                QuotaMetric(name: "codex-weekly", percentage: 0, resetTime: ""),
            ],
            isForbidden: true,
            codexLimitReached: true
        )
        XCTAssertEqual(quota.menuAvailabilityStatus, .sessionAndWeeklyExhausted)
    }

    /// The override also applies to a cooling (rather than frozen) reading — the design
    /// explicitly calls out "generic cooling" as something the known-reached-and-zero
    /// signal must override, not just a rejected credential.
    func testMenuStatusOverridesCoolingWhenLimitReachedIsKnownAndMetricIsZero() {
        let quota = ProviderQuota(
            models: [QuotaMetric(name: "codex-weekly", percentage: 0, resetTime: "")],
            isTemporarilyUnavailable: true,
            codexLimitReached: true
        )
        XCTAssertEqual(quota.availabilityStatus, .cooling)
        XCTAssertEqual(quota.menuAvailabilityStatus, .weeklyExhausted)
    }

    /// A cooling account with a strictly-zero weekly metric must present as exhausted
    /// even when `codexLimitReached` is unknown (`nil`) rather than positively `true` —
    /// unlike the forbidden/frozen case, cooling carries no credential-rejection risk to
    /// protect, so the real zero-metric signal always wins over the generic cooling flag.
    func testMenuStatusOverridesCoolingWhenWeeklyMetricIsZeroEvenWithUnknownLimitReachedProvenance() {
        let quota = ProviderQuota(
            models: [QuotaMetric(name: "codex-weekly", percentage: 0, resetTime: "")],
            isTemporarilyUnavailable: true,
            codexLimitReached: nil
        )
        XCTAssertEqual(quota.availabilityStatus, .cooling)
        XCTAssertEqual(quota.menuAvailabilityStatus, .weeklyExhausted)
    }

    /// Same as above but with `codexLimitReached` explicitly `false`, and the session
    /// metric (rather than weekly) at zero.
    func testMenuStatusOverridesCoolingWhenSessionMetricIsZeroAndLimitReachedIsExplicitlyFalse() {
        let quota = ProviderQuota(
            models: [QuotaMetric(name: "codex-session", percentage: 0, resetTime: "")],
            isTemporarilyUnavailable: true,
            codexLimitReached: false
        )
        XCTAssertEqual(quota.availabilityStatus, .cooling)
        XCTAssertEqual(quota.menuAvailabilityStatus, .sessionExhausted)
    }

    /// Both windows zero while cooling, with no limit-reached provenance at all.
    func testMenuStatusOverridesCoolingWhenBothMetricsAreZeroAndLimitReachedIsUnknown() {
        let quota = ProviderQuota(
            models: [
                QuotaMetric(name: "codex-session", percentage: 0, resetTime: ""),
                QuotaMetric(name: "codex-weekly", percentage: 0, resetTime: ""),
            ],
            isTemporarilyUnavailable: true
        )
        XCTAssertEqual(quota.availabilityStatus, .cooling)
        XCTAssertEqual(quota.menuAvailabilityStatus, .sessionAndWeeklyExhausted)
    }

    /// A cooling account with no metric at exactly zero must remain the plain `.cooling`
    /// reading, not fall through to a frozen/limit-reached case it has no provenance for.
    func testMenuStatusStaysCoolingWhenNoMetricIsExactlyZero() {
        let quota = ProviderQuota(
            models: [QuotaMetric(name: "codex-weekly", percentage: 5, resetTime: "")],
            isTemporarilyUnavailable: true
        )
        XCTAssertEqual(quota.menuAvailabilityStatus, .cooling)
    }

    /// An unproven legacy `isForbidden` reading (no Codex-limit provenance at all,
    /// e.g. a snapshot written before `codexLimitReached` existed) must stay frozen
    /// even if a metric happens to read zero — never silently cleared without a
    /// successful refresh that actually proves the reached-and-zero case.
    func testMenuStatusKeepsLegacyForbiddenFrozenWhenProvenanceIsUnknown() {
        let quota = ProviderQuota(
            models: [QuotaMetric(name: "codex-weekly", percentage: 0, resetTime: "")],
            isForbidden: true,
            codexLimitReached: nil
        )
        XCTAssertEqual(quota.menuAvailabilityStatus, .frozen)
    }

    /// `limit_reached: true` without either metric at exactly zero (still mid-usage,
    /// or a rounding artifact rather than a true zero) is a generic limit-reached
    /// reading with an unknown countdown — it must never be misreported as `.frozen`
    /// (that would call a spent quota window a rejected credential) nor as a weekly/
    /// session exhaustion it cannot actually back with a real reset time. The shared
    /// `availabilityStatus` must still read `.frozen` unchanged, since this override is
    /// menu-only.
    func testMenuStatusIsGenericLimitReachedWhenLimitReachedIsKnownButNoMetricIsExactlyZero() {
        let quota = ProviderQuota(
            models: [
                QuotaMetric(name: "codex-session", percentage: 10, resetTime: ""),
                QuotaMetric(name: "codex-weekly", percentage: 1, resetTime: ""),
            ],
            isForbidden: true,
            codexLimitReached: true
        )
        XCTAssertEqual(quota.availabilityStatus, .frozen, "the shared base status must stay frozen")
        XCTAssertEqual(quota.menuAvailabilityStatus, .limitReachedUnknownWindow)
    }

    /// Same generic reading applies when the account carries no `codex-session`/
    /// `codex-weekly` metrics at all — e.g. a Codex response that reported the reached
    /// limit through some other field. There is still no metric at exactly 0% to
    /// justify one of the specific exhausted cases.
    func testMenuStatusIsGenericLimitReachedWhenLimitReachedIsKnownAndMetricsAreMissing() {
        let quota = ProviderQuota(isForbidden: true, codexLimitReached: true)
        XCTAssertEqual(quota.menuAvailabilityStatus, .limitReachedUnknownWindow)
    }

    /// The generic reached status must never fabricate a recovery date/countdown: there
    /// is no exhausted metric to derive one from, unlike the `.sessionExhausted`/
    /// `.weeklyExhausted`/`.sessionAndWeeklyExhausted` cases.
    func testMenuStatusGenericLimitReachedNeverFabricatesARecoveryDate() {
        let quota = ProviderQuota(
            models: [
                QuotaMetric(name: "codex-session", percentage: 10, resetTime: ""),
                QuotaMetric(name: "codex-weekly", percentage: 1, resetTime: ""),
            ],
            isForbidden: true,
            codexLimitReached: true
        )
        XCTAssertNil(quota.quotaExhaustionRecoveryDate)
        XCTAssertNil(quota.formattedQuotaExhaustionCountdown)
        XCTAssertNil(quota.formattedQuotaExhaustionAbsolute)
    }

    /// The override must never fabricate a countdown either: a reached-and-zero
    /// account whose own metric carries no parseable `resetTime` still reports an
    /// unknown recovery date, exactly like the pre-existing exhaustion-countdown
    /// contract, even though it reached this status via the frozen-override path.
    func testMenuStatusOverrideRecoveryDateIsNilWithoutAParseableResetTime() {
        let quota = ProviderQuota(
            models: [QuotaMetric(name: "codex-weekly", percentage: 0, resetTime: "")],
            isForbidden: true,
            codexLimitReached: true
        )
        XCTAssertNil(quota.quotaExhaustionRecoveryDate)
        XCTAssertNil(quota.formattedQuotaExhaustionCountdown)
        XCTAssertNil(quota.formattedQuotaExhaustionAbsolute)
    }

    /// The override's recovery date reads the exhausted metric's own `resetTime`,
    /// never `availabilityRecoveryDate` — even though the base status arrived here via
    /// `isForbidden`, which does carry an (unrelated) `availabilityRecoveryDate` here.
    func testMenuStatusOverrideRecoveryDateUsesTheMetricsOwnResetTimeNotAvailabilityRecoveryDate() {
        let resetTime = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: 9_000))
        let unrelatedRecovery = Date(timeIntervalSince1970: 1_000)
        let quota = ProviderQuota(
            models: [QuotaMetric(name: "codex-weekly", percentage: 0, resetTime: resetTime)],
            isForbidden: true,
            availabilityRecoveryDate: unrelatedRecovery,
            codexLimitReached: true
        )
        XCTAssertEqual(quota.quotaExhaustionRecoveryDate, Date(timeIntervalSince1970: 9_000))
    }
}

/// Whether the menu's frozen/cooling countdown line renders at all — the "解封时间未知"
/// text must disappear entirely for an unknown-countdown frozen account, while an
/// unknown-countdown cooling account keeps its own explicit fallback line unchanged.
final class ProviderQuotaShowsAvailabilityCountdownLineTests: XCTestCase {
    func testHidesLineWhenFrozenWithNoKnownCountdown() {
        let quota = ProviderQuota(isForbidden: true)
        XCTAssertNil(quota.formattedAvailabilityCountdown)
        XCTAssertFalse(quota.showsAvailabilityCountdownLine)
    }

    func testShowsLineWhenFrozenWithAKnownCountdown() {
        let soon = Date().addingTimeInterval(3600)
        let quota = ProviderQuota(isForbidden: true, availabilityRecoveryDate: soon)
        XCTAssertTrue(quota.showsAvailabilityCountdownLine)
    }

    /// Unchanged behavior: cooling with no known countdown still shows its line, which
    /// falls back to the "cooling unknown" text rather than being hidden.
    func testShowsLineWhenCoolingWithNoKnownCountdown() {
        let quota = ProviderQuota(isTemporarilyUnavailable: true)
        XCTAssertNil(quota.formattedAvailabilityCountdown)
        XCTAssertTrue(quota.showsAvailabilityCountdownLine)
    }

    func testHidesLineForANormalAccount() {
        let quota = ProviderQuota()
        XCTAssertFalse(quota.showsAvailabilityCountdownLine)
    }

    /// The exhausted-window statuses render their own `exhaustionBadge` instead of
    /// this frozen/cooling-only line.
    func testHidesLineWhenStatusIsExhausted() {
        let quota = ProviderQuota(models: [QuotaMetric(name: "codex-weekly", percentage: 0, resetTime: "")])
        XCTAssertEqual(quota.menuAvailabilityStatus, .weeklyExhausted)
        XCTAssertFalse(quota.showsAvailabilityCountdownLine)
    }

    /// The generic limit-reached status also renders its own `exhaustionBadge`
    /// (with a "—" unknown countdown) instead of this frozen/cooling-only line, so the
    /// two never render at the same time.
    func testHidesLineWhenStatusIsGenericLimitReached() {
        let quota = ProviderQuota(isForbidden: true, codexLimitReached: true)
        XCTAssertEqual(quota.menuAvailabilityStatus, .limitReachedUnknownWindow)
        XCTAssertFalse(quota.showsAvailabilityCountdownLine)
    }
}

/// `menuCompactSummary` is the menu-only reading of a Codex account's reset-credit
/// summary: it hides a genuine zero reading entirely rather than showing "没有可用的
/// 重置卡" as a permanent footer line, while leaving `formattedSummary`/
/// `compactFormattedSummary` themselves fully intact for any other surface.
@MainActor
final class CodexResetCreditSummaryMenuCompactSummaryTests: XCTestCase {
    func testMenuCompactSummaryIsNilForAZeroReading() {
        let summary = CodexResetCreditSummary(availableCount: 0, nearestExpiryAt: nil)
        XCTAssertNil(summary.menuCompactSummary)
        XCTAssertNotNil(summary.compactFormattedSummary, "the underlying formatter's own zero-case text must stay intact")
    }

    func testMenuCompactSummaryMatchesCompactFormattedSummaryForAPositiveReading() {
        let date = Date(timeIntervalSince1970: 1_789_975_320)
        let summary = CodexResetCreditSummary(availableCount: 2, nearestExpiryAt: date)
        XCTAssertEqual(summary.menuCompactSummary, summary.compactFormattedSummary)
    }
}
