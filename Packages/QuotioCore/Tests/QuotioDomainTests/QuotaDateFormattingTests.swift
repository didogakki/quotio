import XCTest
@testable import QuotioDomain

final class QuotaDateFormattingTests: XCTestCase {
    func testAbsoluteJSTFormatsFixedTimezoneAndLocale() {
        // 2026-09-21T07:22:00Z == 2026-09-21 16:22 JST (UTC+9).
        let date = Date(timeIntervalSince1970: 1_789_975_320)
        XCTAssertEqual(QuotaDateFormatting.absoluteJST(date), "2026-09-21 16:22 JST")
    }

    /// A day-boundary-crossing UTC time (JST is UTC+9) must roll the date forward, not
    /// just the time-of-day.
    func testAbsoluteJSTCrossesDayBoundaryFromUTC() {
        // 2026-09-20T20:00:00Z == 2026-09-21 05:00 JST — the calendar day advances.
        let date = Date(timeIntervalSince1970: 1_789_934_400)
        XCTAssertEqual(QuotaDateFormatting.absoluteJST(date), "2026-09-21 05:00 JST")
    }

    func testAbsoluteJSTFromISO8601StringParsesStandardAndFractionalForms() {
        XCTAssertEqual(QuotaDateFormatting.absoluteJST("2026-09-21T07:22:00Z"), "2026-09-21 16:22 JST")
        XCTAssertEqual(QuotaDateFormatting.absoluteJST("2026-09-21T07:22:00.500Z"), "2026-09-21 16:22 JST")
    }

    /// Never fabricate a date for missing/unparseable input.
    func testAbsoluteJSTReturnsNilForEmptyOrInvalidInput() {
        XCTAssertNil(QuotaDateFormatting.absoluteJST(""))
        XCTAssertNil(QuotaDateFormatting.absoluteJST("not-a-date"))
    }
}
