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
