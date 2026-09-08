import XCTest
@testable import QuotioDomain

final class PreferenceValuesTests: XCTestCase {
    func testLegacyOperatingModesMapToSupportedModes() {
        XCTAssertEqual(OperatingMode.fromLegacy(appModeRaw: nil, connectionModeRaw: nil), .monitor)
        XCTAssertEqual(OperatingMode.fromLegacy(appModeRaw: "quotaOnly", connectionModeRaw: nil), .monitor)
        XCTAssertEqual(OperatingMode.fromLegacy(appModeRaw: "full", connectionModeRaw: "remote"), .monitor)
        XCTAssertEqual(OperatingMode.fromLegacy(appModeRaw: "full", connectionModeRaw: "local"), .localProxy)
        XCTAssertEqual(OperatingMode.fromLegacy(appModeRaw: "unknown", connectionModeRaw: "local"), .monitor)
    }

    func testPreferenceDefaultsMatchExistingApplicationBehavior() {
        XCTAssertEqual(OperatingModePreferences(), OperatingModePreferences(mode: .monitor))
        XCTAssertEqual(RefreshPreferences().cadence, .tenMinutes)
        XCTAssertEqual(AppearancePreferences().mode, .system)
        XCTAssertEqual(LanguagePreferences().language, .english)
        XCTAssertEqual(UpdatePreferences().channel, .stable)
        XCTAssertEqual(NotificationPreferences().quotaAlertThreshold, 20)
        XCTAssertTrue(NotificationPreferences().notificationsEnabled)
        XCTAssertTrue(AppShellPreferences().autoCheckUpdates)
        XCTAssertTrue(AppShellPreferences().showInDock)
        XCTAssertTrue(ProxyPreferences().loggingToFile)
        XCTAssertFalse(AppShellPreferences().hideGettingStarted)
    }

    func testQuotaDisplayModeClampsValuesAndPreservesUnavailableSentinel() {
        XCTAssertEqual(QuotaDisplayMode.used.displayValue(from: 25), 75)
        XCTAssertEqual(QuotaDisplayMode.remaining.displayValue(from: 125), 100)
        XCTAssertEqual(QuotaDisplayMode.remaining.displayValue(from: -1), -1)
    }

    func testMenuBarQuotaItemDecodesPreExistingJSONWithoutSourceConfigIdAsLocal() throws {
        let legacyJSON = Data(#"{"provider":"claude","accountKey":"user@example.com"}"#.utf8)

        let item = try JSONDecoder().decode(MenuBarQuotaItem.self, from: legacyJSON)

        XCTAssertNil(item.sourceConfigId)
        XCTAssertFalse(item.isRemote)
        XCTAssertFalse(item.isPool)
        XCTAssertEqual(item.id, "claude_user@example.com")
    }

    func testMenuBarQuotaItemRoundTripsSourceConfigIdAndRecognizesPoolAccountKey() throws {
        let item = MenuBarQuotaItem(provider: "codex", accountKey: "__pool__", sourceConfigId: "src-1")

        let data = try JSONEncoder().encode(item)
        let decoded = try JSONDecoder().decode(MenuBarQuotaItem.self, from: data)

        XCTAssertEqual(decoded, item)
        XCTAssertEqual(decoded.sourceConfigId, "src-1")
        XCTAssertTrue(decoded.isRemote)
        XCTAssertTrue(decoded.isPool)
    }

    func testMenuBarQuotaItemIdentityIncludesSourceToAvoidSamePlanCollisionsAcrossServers() {
        // The exact Raycast-written defaults: same provider/accountKey, different servers.
        let plusPool = MenuBarQuotaItem(provider: "codex", accountKey: "__pool__", sourceConfigId: "quotio-monitor-cliproxyapi-plus")
        let businessPool = MenuBarQuotaItem(provider: "codex", accountKey: "__pool__", sourceConfigId: "quotio-monitor-cliproxyapi-business")

        XCTAssertNotEqual(plusPool.id, businessPool.id)
        XCTAssertNotEqual(plusPool, businessPool)
    }

    func testMenuBarQuotaItemDecodesRaycastDefaultConfiguration() throws {
        let json = Data("""
        [
          {"provider":"claude","accountKey":"__pool__","sourceConfigId":"quotio-monitor-cliproxyapi-plus"},
          {"provider":"codex","accountKey":"__pool__","sourceConfigId":"quotio-monitor-cliproxyapi-plus"},
          {"provider":"codex","accountKey":"__pool__","sourceConfigId":"quotio-monitor-cliproxyapi-business"}
        ]
        """.utf8)

        let items = try JSONDecoder().decode([MenuBarQuotaItem].self, from: json)

        XCTAssertEqual(items.count, 3)
        XCTAssertTrue(items.allSatisfy(\.isPool))
        XCTAssertTrue(items.allSatisfy(\.isRemote))
        XCTAssertEqual(Set(items.map(\.id)).count, 3, "all three must have distinct identities")
    }
}
