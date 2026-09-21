import QuotioDomain
import XCTest

@testable import QuotioPresentation

/// Regression coverage for `AccountRowSource`'s two independent row controls:
/// - `supportsDisable` — the *real* enable/disable action, reachable only via the
///   context menu (right-click) for the sources that have one.
/// - `supportsDropdownVisibilityToggle` — the inline ✓/✕ button that only ever changes
///   whether an account shows up in the menu bar's per-provider dropdown list.
/// These must never be conflated: every real account source gets the visibility toggle,
/// regardless of whether it also has a real disable action, and only an aggregate row
/// (which has nothing of its own to hide or disable) gets neither.
@MainActor
final class AccountRowSourceTests: XCTestCase {
    func testProxyAndMonitorSupportBothRealDisableAndDropdownVisibility() {
        for source: AccountRowSource in [.proxy, .monitor(.nativeCredential)] {
            XCTAssertTrue(source.supportsDisable, "\(source) must keep its real enable/disable action")
            XCTAssertTrue(
                source.supportsDropdownVisibilityToggle,
                "\(source) must also get the dropdown-visibility toggle, independent of the real disable action"
            )
        }
    }

    func testDirectAndRemoteQuotaSourceSupportOnlyDropdownVisibility() {
        for source: AccountRowSource in [.direct, .remoteQuotaSource("My Server")] {
            XCTAssertFalse(source.supportsDisable, "\(source) has no real enable/disable action")
            XCTAssertTrue(
                source.supportsDropdownVisibilityToggle,
                "\(source) must still get the dropdown-visibility toggle"
            )
        }
    }

    func testAutoDetectedAndAggregateSupportNeitherControl() {
        for source: AccountRowSource in [.autoDetected, .remoteQuotaSourceAggregate(sourceName: "My Server", planLabel: "Pro")] {
            XCTAssertFalse(source.supportsDisable)
            XCTAssertFalse(
                source.supportsDropdownVisibilityToggle,
                "\(source) has nothing of its own to hide or disable"
            )
        }
    }

    /// The dropdown-visibility hidden set is keyed by `AccountRowData.menuBarItem.id`,
    /// which already namespaces by provider (and, for remote accounts, by source id).
    /// Two local accounts on different providers that happen to share the exact same raw
    /// account key/email must never collide in that set.
    func testMenuBarItemIdNamespacesLocalAccountsByProvider() {
        let claudeAccount = AccountRowData(
            id: "1",
            provider: .claude,
            displayName: "same@example.com",
            menuBarAccountKey: "same@example.com",
            source: .proxy,
            status: nil,
            statusMessage: nil,
            isDisabled: false,
            canDelete: true
        )
        let codexAccount = AccountRowData(
            id: "2",
            provider: .codex,
            displayName: "same@example.com",
            menuBarAccountKey: "same@example.com",
            source: .proxy,
            status: nil,
            statusMessage: nil,
            isDisabled: false,
            canDelete: true
        )

        XCTAssertNotEqual(claudeAccount.menuBarItem.id, codexAccount.menuBarItem.id)
    }

    /// `isAggregate` is the single source of truth every real-account count (provider
    /// badges, total counts) filters on. Only the derived plan-summary row is an
    /// aggregate — every other source, including a real remote-quota-source account,
    /// must count as a real account.
    func testIsAggregateOnlyTrueForRemoteQuotaSourceAggregate() {
        let realSources: [AccountRowSource] = [
            .proxy,
            .direct,
            .autoDetected,
            .monitor(.nativeCredential),
            .remoteQuotaSource("My Server")
        ]
        for source in realSources {
            XCTAssertFalse(source.isAggregate, "\(source) is a real account and must not be counted as an aggregate")
        }
        XCTAssertTrue(
            AccountRowSource.remoteQuotaSourceAggregate(sourceName: "My Server", planLabel: "Pro").isAggregate
        )
    }

    /// Regression: a plan group with 3 real remote accounts plus 2 derived aggregate
    /// rows (e.g. one per model-aggregation mode) must report 3 real accounts, not 5 —
    /// the aggregate rows summarize the same 3 accounts, they are not additional ones.
    func testAggregateRowsAreExcludedFromRealAccountCount() {
        func realAccount(_ id: String) -> AccountRowData {
            AccountRowData.from(
                provider: .claude,
                sourceId: "src-1",
                sourceName: "My Server",
                rawAccountKey: id,
                storageKey: id,
                quota: ProviderQuota(accountDisplayName: "\(id)@example.com")
            )
        }
        func aggregateRow(_ planLabel: String) -> AccountRowData {
            AccountRowData.aggregate(
                provider: .claude,
                sourceId: "src-1",
                sourceName: "My Server",
                planLabel: planLabel,
                accountCount: 3,
                storageKey: "agg-\(planLabel)",
                quota: ProviderQuota()
            )
        }

        let accounts = [
            realAccount("a"),
            realAccount("b"),
            realAccount("c"),
            aggregateRow("Pro"),
            aggregateRow("Pro-strict")
        ]

        let realAccountCount = accounts.filter { !$0.source.isAggregate }.count
        XCTAssertEqual(realAccountCount, 3, "5 rows total, but only 3 are real accounts")
    }

    func testRemoteAuthInvalidAccountIsAnErrorButNeverDisabled() {
        let row = AccountRowData.from(
            provider: .codex,
            sourceId: "src-1",
            sourceName: "Business",
            rawAccountKey: "codex-a",
            storageKey: "remote-key",
            quota: ProviderQuota(
                accountDisplayName: "a@example.com",
                remoteAccountIssue: .invalidOAuth
            )
        )

        XCTAssertEqual(row.status, "error")
        XCTAssertEqual(row.remoteAccountIssue, .invalidOAuth)
        XCTAssertFalse(row.isDisabled, "automatic OAuth quarantine must not become the manual disabled state")
        XCTAssertFalse(row.source.supportsDisable)
    }

    /// A remote account's `menuBarItem.id` must never collide with a local account that
    /// happens to carry the exact same raw storage key text.
    func testMenuBarItemIdNamespacesRemoteAccountsAwayFromLocalOnes() {
        let localAccount = AccountRowData(
            id: "1",
            provider: .claude,
            displayName: "shared-key",
            menuBarAccountKey: "shared-key",
            source: .proxy,
            status: nil,
            statusMessage: nil,
            isDisabled: false,
            canDelete: true
        )
        let remoteAccount = AccountRowData.from(
            provider: .claude,
            sourceId: "src-1",
            sourceName: "My Server",
            rawAccountKey: "raw",
            storageKey: "shared-key",
            quota: ProviderQuota(accountDisplayName: "remote@example.com")
        )

        XCTAssertNotEqual(localAccount.menuBarItem.id, remoteAccount.menuBarItem.id)
    }
}
