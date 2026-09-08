import XCTest

@testable import QuotioDomain

final class RemoteQuotaSourceTests: XCTestCase {
    // MARK: - RemoteQuotaPoolIdentity

    func testStorageKeyRoundTripsSourceIdAndPlanKey() {
        let key = RemoteQuotaPoolIdentity.storageKey(sourceId: "src-1", planKey: "pro")
        let components = RemoteQuotaPoolIdentity.components(fromStorageKey: key)

        XCTAssertEqual(components?.sourceId, "src-1")
        XCTAssertEqual(components?.planKey, "pro")
    }

    func testComponentsReturnsNilForUnrelatedKeys() {
        XCTAssertNil(RemoteQuotaPoolIdentity.components(fromStorageKey: "some-local-account"))
        XCTAssertNil(RemoteQuotaPoolIdentity.components(fromStorageKey: "__pool__"))
    }

    // MARK: - RemoteQuotaSourceURLValidation

    func testValidatesAbsoluteHTTPAndHTTPSURLs() {
        XCTAssertTrue(RemoteQuotaSourceURLValidation.isValid("https://example.com:8317"))
        XCTAssertTrue(RemoteQuotaSourceURLValidation.isValid("http://192.168.1.5:8080"))
    }

    func testRejectsNonHTTPSchemes() {
        XCTAssertFalse(RemoteQuotaSourceURLValidation.isValid("file:///etc/passwd"))
        XCTAssertFalse(RemoteQuotaSourceURLValidation.isValid("javascript:alert(1)"))
    }

    func testRejectsRelativeOrHostlessURLs() {
        XCTAssertFalse(RemoteQuotaSourceURLValidation.isValid("/just/a/path"))
        XCTAssertFalse(RemoteQuotaSourceURLValidation.isValid("example.com"))
        XCTAssertFalse(RemoteQuotaSourceURLValidation.isValid("https://"))
        XCTAssertFalse(RemoteQuotaSourceURLValidation.isValid(""))
        XCTAssertFalse(RemoteQuotaSourceURLValidation.isValid("   "))
    }
}
