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
