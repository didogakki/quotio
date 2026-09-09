import QuotioDomain
import XCTest

@testable import QuotioPresentation

@MainActor
final class RemoteQuotaAggregatePinDisplayMapperTests: XCTestCase {
    /// Codex's "Plus" plan normalizes to `planKey == "plus"` and, unlike Claude, has no
    /// provider-specific override — it must render as the plain "Plus" label.
    func testCodexPlusPlanLabel() {
        let item = RemoteQuotaAggregatePinDisplayMapper.displayItem(
            itemId: "item",
            provider: .codex,
            planKey: "plus",
            aggregate: Self.aggregate(planType: "Plus", percentage: 40, accountCount: 2),
            totalUsagePercent: { _ in 40 }
        )

        XCTAssertEqual(item.groupLabel, "Plus")
    }

    /// Claude's "Plus" plan has always displayed as "Pro" in this app's UI — the one
    /// provider-specific override in `QuotaPolicy.planGroupDisplayLabel`.
    func testClaudeProPlanLabel() {
        let item = RemoteQuotaAggregatePinDisplayMapper.displayItem(
            itemId: "item",
            provider: .claude,
            planKey: "plus",
            aggregate: Self.aggregate(planType: "Plus", percentage: 40, accountCount: 1),
            totalUsagePercent: { _ in 40 }
        )

        XCTAssertEqual(item.groupLabel, "Pro")
    }

    /// `planKey == "unknown"` must always render the explicit, localized "unknown" label
    /// — never a guessed plan name derived from the (absent) raw plan type — matching
    /// `ProvidersScreen`'s handling of the same aggregate.
    func testUnknownPlanRendersExplicitLocalizedLabel() {
        let item = RemoteQuotaAggregatePinDisplayMapper.displayItem(
            itemId: "item",
            provider: .codex,
            planKey: "unknown",
            aggregate: Self.aggregate(planType: nil, percentage: 10, accountCount: 1),
            totalUsagePercent: { _ in 10 }
        )

        XCTAssertEqual(item.groupLabel, "providers.aggregate.planUnknown".localizedStatic())
    }

    /// The plan label belongs in `groupLabel` — the field the compact menu bar row
    /// actually renders — never as a guessed value in an unrelated field.
    func testPlanLabelGoesInGroupLabelNotElsewhere() {
        let item = RemoteQuotaAggregatePinDisplayMapper.displayItem(
            itemId: "item",
            provider: .codex,
            planKey: "plus",
            aggregate: Self.aggregate(planType: "Plus", percentage: 40, accountCount: 2),
            totalUsagePercent: { _ in 40 }
        )

        XCTAssertEqual(item.groupLabel, "Plus")
        XCTAssertNotEqual(item.accountShort, "Plus")
    }

    /// An aggregate has no account identity of its own, so provider/icon identity must
    /// carry through untouched and `accountShort` must fall back to the provider's own
    /// display name — mirroring `RemoteQuotaPoolDisplayMapper`'s pattern for the same
    /// no-identity case.
    func testProviderAndIconIdentityArePreservedAndAccountShortFallsBackToProviderName() {
        let item = RemoteQuotaAggregatePinDisplayMapper.displayItem(
            itemId: "item",
            provider: .claude,
            planKey: "pro",
            aggregate: Self.aggregate(planType: "Pro", percentage: 40, accountCount: 3),
            totalUsagePercent: { _ in 40 }
        )

        XCTAssertEqual(item.provider, .claude)
        XCTAssertEqual(item.providerSymbol, QuotaProvider.claude.menuBarSymbol)
        XCTAssertEqual(item.accountShort, QuotaProvider.claude.displayName)
    }

    /// The aggregate is a plan-level summary, never one real account, so its display
    /// must never leak a contributing account's own email/display name anywhere.
    func testNoAccountEmailOrDisplayNameLeaksIntoTheDisplayItem() {
        let aggregate = RemoteQuotaPlanAggregate(
            quota: ProviderQuota(
                models: [QuotaMetric(name: "usage", percentage: 40, resetTime: "")],
                planType: "Plus",
                accountDisplayName: "leaked@example.com"
            ),
            accountCount: 2
        )
        let item = RemoteQuotaAggregatePinDisplayMapper.displayItem(
            itemId: "item",
            provider: .codex,
            planKey: "plus",
            aggregate: aggregate,
            totalUsagePercent: { _ in 40 }
        )

        XCTAssertNotEqual(item.accountShort, "leaked@example.com")
        XCTAssertNotEqual(item.groupLabel, "leaked@example.com")
        XCTAssertEqual(item.accountShort, QuotaProvider.codex.displayName)
    }

    /// Percentage is derived only from the aggregate's own models via the injected
    /// closure — never a hardcoded or stale value.
    func testPercentageIsComputedFromAggregateModels() {
        let item = RemoteQuotaAggregatePinDisplayMapper.displayItem(
            itemId: "item",
            provider: .codex,
            planKey: "plus",
            aggregate: Self.aggregate(planType: "Plus", percentage: 77, accountCount: 1),
            totalUsagePercent: { models in models.first?.percentage ?? -1 }
        )

        XCTAssertEqual(item.percentage, 77)
    }

    /// An aggregate with no fetched models yet must render as unknown (-1), never as a
    /// misleading 0%, and must never invoke the percentage closure at all.
    func testEmptyModelsStayUnknownNotZero() {
        var closureCalled = false
        let item = RemoteQuotaAggregatePinDisplayMapper.displayItem(
            itemId: "item",
            provider: .codex,
            planKey: "plus",
            aggregate: RemoteQuotaPlanAggregate(
                quota: ProviderQuota(planType: "Plus"),
                accountCount: 1
            ),
            totalUsagePercent: { _ in
                closureCalled = true
                return 0
            }
        )

        XCTAssertEqual(item.percentage, -1)
        XCTAssertFalse(closureCalled)
    }

    /// A forbidden aggregate (every contributing account forbidden) must render as
    /// forbidden, never masked as a healthy reading.
    func testForbiddenAggregatePropagatesForbiddenFlag() {
        let aggregate = RemoteQuotaPlanAggregate(
            quota: ProviderQuota(isForbidden: true, planType: "Plus"),
            accountCount: 1
        )
        let item = RemoteQuotaAggregatePinDisplayMapper.displayItem(
            itemId: "item",
            provider: .codex,
            planKey: "plus",
            aggregate: aggregate,
            totalUsagePercent: { _ in 0 }
        )

        XCTAssertTrue(item.isForbidden)
    }

    private static func aggregate(
        planType: String?,
        percentage: Double,
        accountCount: Int
    ) -> RemoteQuotaPlanAggregate {
        RemoteQuotaPlanAggregate(
            quota: ProviderQuota(
                models: [QuotaMetric(name: "usage", percentage: percentage, resetTime: "")],
                planType: planType
            ),
            accountCount: accountCount
        )
    }
}
