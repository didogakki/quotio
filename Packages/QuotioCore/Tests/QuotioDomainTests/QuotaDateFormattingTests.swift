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

    func testParseISO8601ParsesStandardAndFractionalForms() {
        XCTAssertNotNil(QuotaDateFormatting.parseISO8601("2026-09-21T07:22:00Z"))
        XCTAssertNotNil(QuotaDateFormatting.parseISO8601("2026-09-21T07:22:00.500Z"))
        XCTAssertNil(QuotaDateFormatting.parseISO8601(""))
        XCTAssertNil(QuotaDateFormatting.parseISO8601("not-a-date"))
    }

    func testRelativeCompactFormatsHoursMinutesWithNoSpace() {
        let now = Date(timeIntervalSince1970: 0)
        let in3h32m = now.addingTimeInterval(3 * 3600 + 32 * 60)
        XCTAssertEqual(QuotaDateFormatting.relativeCompact(to: in3h32m, from: now), "3h32m")
    }

    func testRelativeCompactFormatsDaysAndHours() {
        let now = Date(timeIntervalSince1970: 0)
        let in2d5h = now.addingTimeInterval(2 * 86_400 + 5 * 3600)
        XCTAssertEqual(QuotaDateFormatting.relativeCompact(to: in2d5h, from: now), "2d5h")
    }

    func testRelativeCompactFormatsMinutesOnlyUnderAnHour() {
        let now = Date(timeIntervalSince1970: 0)
        let in12m = now.addingTimeInterval(12 * 60)
        XCTAssertEqual(QuotaDateFormatting.relativeCompact(to: in12m, from: now), "12m")
    }

    /// Drops the year and `JST` suffix that `absoluteJST` carries — the dropdown-only
    /// compact companion.
    func testCompactJSTFormatsWithoutYearOrSuffix() {
        // 2026-09-21T07:22:00Z == 2026-09-21 16:22 JST (UTC+9).
        let date = Date(timeIntervalSince1970: 1_789_975_320)
        XCTAssertEqual(QuotaDateFormatting.compactJST(date), "09-21 16:22")
    }

    func testCompactJSTFromISO8601StringParsesStandardAndFractionalForms() {
        XCTAssertEqual(QuotaDateFormatting.compactJST("2026-09-21T07:22:00Z"), "09-21 16:22")
        XCTAssertEqual(QuotaDateFormatting.compactJST("2026-09-21T07:22:00.500Z"), "09-21 16:22")
    }

    /// Never fabricate a date for missing/unparseable input.
    func testCompactJSTReturnsNilForEmptyOrInvalidInput() {
        XCTAssertNil(QuotaDateFormatting.compactJST(""))
        XCTAssertNil(QuotaDateFormatting.compactJST("not-a-date"))
    }
}
