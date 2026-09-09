import QuotioDomain
import XCTest

@testable import QuotioPresentation

final class RemoteQuotaPoolDisplayMapperTests: XCTestCase {
    /// A single real account behind a legacy pool pin still carries a group label, so
    /// the row identifies itself next to the provider icon instead of reading as an
    /// anonymous entry.
    func testSingleAccountStillCarriesAGroupLabel() {
        let items = RemoteQuotaPoolDisplayMapper.displayItems(
            itemId: "item",
            provider: .codex,
            accounts: [.init(accountKey: "codex-a", quota: Self.quota(50, accountDisplayName: "work@example.com"))],
            stackPairedQuotaMetrics: false,
            totalUsagePercent: { _ in 50 }
        )

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.groupLabel, "work@example.com")
    }

    /// Regression: `accountShort`/`groupLabel` used to be a synthesized plan bucket
    /// label (e.g. "Plus", "Pro 20x") that masqueraded as an account. It must now be
    /// the real account's own identity — never the internal pool sentinel either.
    func testAccountShortNeverExposesThePoolSentinelOrASyntheticPlanLabel() {
        let items = RemoteQuotaPoolDisplayMapper.displayItems(
            itemId: "item",
            provider: .codex,
            accounts: [.init(accountKey: "codex-a", quota: Self.quota(50, accountDisplayName: "My Account"))],
            stackPairedQuotaMetrics: false,
            totalUsagePercent: { _ in 50 }
        )

        XCTAssertEqual(items.first?.accountShort, "My Account")
        XCTAssertNotEqual(items.first?.accountShort, RemoteQuotaPoolIdentity.accountKey)
    }

    /// Missing plan/display metadata must fall back to the provider's own name, never
    /// a guessed plan label, and must never leak the raw internal storage key either.
    func testMissingDisplayNameFallsBackToProviderNameNotRawKey() {
        let items = RemoteQuotaPoolDisplayMapper.displayItems(
            itemId: "item",
            provider: .codex,
            accounts: [.init(accountKey: "codex-a", quota: Self.quota(50, accountDisplayName: nil))],
            stackPairedQuotaMetrics: false,
            totalUsagePercent: { _ in 50 }
        )

        XCTAssertEqual(items.first?.accountShort, QuotaProvider.codex.displayName)
    }

    func testMultipleAccountsExpandDeterministicallySortedByDisplayName() {
        let items = RemoteQuotaPoolDisplayMapper.displayItems(
            itemId: "item",
            provider: .codex,
            accounts: [
                .init(accountKey: "codex-b", quota: Self.quota(30, accountDisplayName: "zeta@example.com")),
                .init(accountKey: "codex-a", quota: Self.quota(60, accountDisplayName: "alpha@example.com")),
            ],
            stackPairedQuotaMetrics: false,
            totalUsagePercent: { models in models.first?.percentage ?? -1 }
        )

        XCTAssertEqual(items.map(\.groupLabel), ["alpha@example.com", "zeta@example.com"])
        XCTAssertEqual(items.map(\.id), ["item:codex-a", "item:codex-b"])
    }

    /// Each account keeps its own independent reading — never worst-case-aggregated
    /// with any other account under the same legacy pool pin.
    func testEachAccountKeepsItsOwnIndependentPercentage() {
        let items = RemoteQuotaPoolDisplayMapper.displayItems(
            itemId: "item",
            provider: .claude,
            accounts: [
                .init(accountKey: "claude-a", quota: Self.quota(90, accountDisplayName: "a@example.com")),
                .init(accountKey: "claude-b", quota: Self.quota(10, accountDisplayName: "b@example.com")),
            ],
            stackPairedQuotaMetrics: false,
            totalUsagePercent: { models in models.first?.percentage ?? -1 }
        )

        XCTAssertEqual(items.first(where: { $0.id == "item:claude-a" })?.percentage, 90)
        XCTAssertEqual(items.first(where: { $0.id == "item:claude-b" })?.percentage, 10)
    }

    /// An account with no fetched models yet must render as unknown (-1), never as a
    /// misleading 0%.
    func testAccountWithNoModelsStaysUnknownNotZero() {
        let items = RemoteQuotaPoolDisplayMapper.displayItems(
            itemId: "item",
            provider: .claude,
            accounts: [.init(accountKey: "claude-a", quota: ProviderQuota(accountDisplayName: "a@example.com"))],
            stackPairedQuotaMetrics: false,
            totalUsagePercent: { _ in 0 }
        )

        XCTAssertEqual(items.first?.percentage, -1)
    }

    func testEmptyAccountsProduceNoItems() {
        let items = RemoteQuotaPoolDisplayMapper.displayItems(
            itemId: "item",
            provider: .claude,
            accounts: [],
            stackPairedQuotaMetrics: false,
            totalUsagePercent: { _ in 0 }
        )

        XCTAssertTrue(items.isEmpty)
    }

    private static func quota(
        _ percentage: Double,
        accountDisplayName: String?
    ) -> ProviderQuota {
        ProviderQuota(
            models: [QuotaMetric(name: "usage", percentage: percentage, resetTime: "")],
            accountDisplayName: accountDisplayName
        )
    }
}
