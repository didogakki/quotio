import XCTest

@testable import QuotioDomain

final class RemoteQuotaSourceTests: XCTestCase {
    func testFormEditPreservesCacheAndMetadataThroughPersistence() throws {
        let original = RemoteQuotaSourceConfig(
            id: "source", name: "Old", baseURL: "https://cpa.example.com",
            isLegacyGrokPlusSource: true,
            quotaCacheBaseURL: "https://cpa.example.com/quota-cache/v1/plus"
        )
        let edited = original.updatingEditableFields(
            name: "Renamed", baseURL: "https://cpa.example.com/v0/management", isEnabled: false
        )
        let restored = try JSONDecoder().decode(RemoteQuotaSourceConfig.self, from: JSONEncoder().encode(edited))
        XCTAssertEqual(restored.name, "Renamed")
        XCTAssertEqual(restored.baseURL, "https://cpa.example.com/v0/management")
        XCTAssertFalse(restored.isEnabled)
        XCTAssertEqual(restored.id, original.id)
        XCTAssertEqual(restored.quotaCacheBaseURL, original.quotaCacheBaseURL)
        XCTAssertEqual(restored.isLegacyGrokPlusSource, true)
        XCTAssertEqual(original.name, "Old")
    }

    func testFormEditDoesNotInventCacheForDirectSources() {
        let original = RemoteQuotaSourceConfig(id: "direct", name: "Direct", baseURL: "https://cpa.example.com")
        let edited = original.updatingEditableFields(name: "Changed", baseURL: original.baseURL, isEnabled: true)
        XCTAssertNil(edited.quotaCacheBaseURL)
        XCTAssertNil(edited.isLegacyGrokPlusSource)
    }

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

    // MARK: - RemoteQuotaAccountIdentity

    func testAccountStorageKeyRoundTripsSourceIdAndAccountKey() {
        let key = RemoteQuotaAccountIdentity.storageKey(sourceId: "src-1", accountKey: "claude-a")
        let components = RemoteQuotaAccountIdentity.components(fromStorageKey: key)

        XCTAssertEqual(components?.sourceId, "src-1")
        XCTAssertEqual(components?.accountKey, "claude-a")
    }

    /// The raw account key may itself contain the `::` separator (e.g. an email-derived
    /// key); only the first segment after the prefix must be treated as the source id.
    func testAccountStorageKeyPreservesSeparatorInsideAccountKey() {
        let key = RemoteQuotaAccountIdentity.storageKey(sourceId: "src-1", accountKey: "weird::key")
        let components = RemoteQuotaAccountIdentity.components(fromStorageKey: key)

        XCTAssertEqual(components?.sourceId, "src-1")
        XCTAssertEqual(components?.accountKey, "weird::key")
    }

    /// Same raw account key from two different sources must never collide — this is the
    /// exact "same email/name across sources" isolation the storage key exists to protect.
    func testAccountStorageKeyIsolatesSameAccountKeyAcrossDifferentSources() {
        let keyA = RemoteQuotaAccountIdentity.storageKey(sourceId: "src-a", accountKey: "same@example.com")
        let keyB = RemoteQuotaAccountIdentity.storageKey(sourceId: "src-b", accountKey: "same@example.com")

        XCTAssertNotEqual(keyA, keyB)
        XCTAssertEqual(RemoteQuotaAccountIdentity.components(fromStorageKey: keyA)?.sourceId, "src-a")
        XCTAssertEqual(RemoteQuotaAccountIdentity.components(fromStorageKey: keyB)?.sourceId, "src-b")
    }

    func testAccountComponentsReturnsNilForUnrelatedOrLegacyPoolKeys() {
        XCTAssertNil(RemoteQuotaAccountIdentity.components(fromStorageKey: "some-local-account"))
        XCTAssertNil(RemoteQuotaAccountIdentity.components(fromStorageKey: "__pool__::src-1::pro"))
    }

    // MARK: - RemoteQuotaAggregateIdentity

    func testAggregateStorageKeyRoundTripsSourceIdAndPlanKey() {
        let key = RemoteQuotaAggregateIdentity.storageKey(sourceId: "src-1", planKey: "pro")
        let components = RemoteQuotaAggregateIdentity.components(fromStorageKey: key)

        XCTAssertEqual(components?.sourceId, "src-1")
        XCTAssertEqual(components?.planKey, "pro")
    }

    /// The whole point of the distinct `aggr::` prefix: an aggregate pin must never be
    /// mistaken for a real account pin or a legacy pool pin, and vice versa.
    func testAggregateStorageKeyNeverCollidesWithAccountOrPoolKeys() {
        let aggregateKey = RemoteQuotaAggregateIdentity.storageKey(sourceId: "src-1", planKey: "pro")
        let accountKey = RemoteQuotaAccountIdentity.storageKey(sourceId: "src-1", accountKey: "pro")
        let poolKey = RemoteQuotaPoolIdentity.storageKey(sourceId: "src-1", planKey: "pro")

        XCTAssertNotEqual(aggregateKey, accountKey)
        XCTAssertNotEqual(aggregateKey, poolKey)
        XCTAssertNil(RemoteQuotaAccountIdentity.components(fromStorageKey: aggregateKey))
        XCTAssertNil(RemoteQuotaPoolIdentity.components(fromStorageKey: aggregateKey))
        XCTAssertNil(RemoteQuotaAggregateIdentity.components(fromStorageKey: accountKey))
        XCTAssertNil(RemoteQuotaAggregateIdentity.components(fromStorageKey: poolKey))
    }

    func testAggregateComponentsReturnsNilForUnrelatedKeys() {
        XCTAssertNil(RemoteQuotaAggregateIdentity.components(fromStorageKey: "some-local-account"))
        XCTAssertNil(RemoteQuotaAggregateIdentity.components(fromStorageKey: "__pool__"))
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
