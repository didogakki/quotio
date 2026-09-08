import QuotioDomain
import XCTest

@testable import QuotioPresentation

final class RemoteQuotaPoolDisplayMapperTests: XCTestCase {
    /// Regression: a single-plan pool used to render with `groupLabel == nil`, so the
    /// menu bar row was indistinguishable from an ordinary local account. It must
    /// always carry a plan label, even with exactly one group.
    func testSinglePlanGroupStillCarriesAGroupLabel() {
        let items = RemoteQuotaPoolDisplayMapper.displayItems(
            itemId: "item",
            provider: .codex,
            groups: [.init(planKey: "plus", quota: Self.quota(50, planType: "Plus"))],
            stackPairedQuotaMetrics: false,
            totalUsagePercent: { _ in 50 }
        )

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.groupLabel, "Plus")
    }

    func testGroupLabelsMatchExpectedProviderPlanMapping() {
        let claudePlus = RemoteQuotaPoolDisplayMapper.displayItems(
            itemId: "a",
            provider: .claude,
            groups: [.init(planKey: "plus", quota: Self.quota(10, planType: "Plus"))],
            stackPairedQuotaMetrics: false,
            totalUsagePercent: { _ in 10 }
        )
        XCTAssertEqual(claudePlus.first?.groupLabel, "Pro")

        let codexPlus = RemoteQuotaPoolDisplayMapper.displayItems(
            itemId: "b",
            provider: .codex,
            groups: [.init(planKey: "plus", quota: Self.quota(10, planType: "Plus"))],
            stackPairedQuotaMetrics: false,
            totalUsagePercent: { _ in 10 }
        )
        XCTAssertEqual(codexPlus.first?.groupLabel, "Plus")

        let codexBusiness = RemoteQuotaPoolDisplayMapper.displayItems(
            itemId: "c",
            provider: .codex,
            groups: [.init(planKey: "business", quota: Self.quota(10, planType: "Business"))],
            stackPairedQuotaMetrics: false,
            totalUsagePercent: { _ in 10 }
        )
        XCTAssertEqual(codexBusiness.first?.groupLabel, "Business")
    }

    /// Regression: `accountShort` used to be the literal `MenuBarQuotaItem.accountKey`,
    /// which for a pool selection is the internal `RemoteQuotaPoolIdentity.accountKey`
    /// sentinel ("__pool__") — never meant to reach display or accessibility text.
    func testAccountShortNeverExposesThePoolSentinel() {
        let items = RemoteQuotaPoolDisplayMapper.displayItems(
            itemId: "item",
            provider: .codex,
            groups: [.init(planKey: "pro", quota: Self.quota(50, planType: "Pro", accountDisplayName: "My Server"))],
            stackPairedQuotaMetrics: false,
            totalUsagePercent: { _ in 50 }
        )

        XCTAssertEqual(items.first?.accountShort, "My Server")
        XCTAssertNotEqual(items.first?.accountShort, RemoteQuotaPoolIdentity.accountKey)
    }

    func testMultipleGroupsExpandDeterministicallySortedByPlanKey() {
        let items = RemoteQuotaPoolDisplayMapper.displayItems(
            itemId: "item",
            provider: .codex,
            groups: [
                .init(planKey: "team", quota: Self.quota(30, planType: "Team")),
                .init(planKey: "pro", quota: Self.quota(60, planType: "Pro 20x")),
            ],
            stackPairedQuotaMetrics: false,
            totalUsagePercent: { models in models.first?.percentage ?? -1 }
        )

        XCTAssertEqual(items.map(\.groupLabel), ["Pro 20x", "Team"])
        XCTAssertEqual(items.map(\.id), ["item:pro", "item:team"])
    }

    private static func quota(
        _ percentage: Double,
        planType: String,
        accountDisplayName: String? = nil
    ) -> ProviderQuota {
        ProviderQuota(
            models: [QuotaMetric(name: "usage", percentage: percentage, resetTime: "")],
            planType: planType,
            accountDisplayName: accountDisplayName
        )
    }
}
