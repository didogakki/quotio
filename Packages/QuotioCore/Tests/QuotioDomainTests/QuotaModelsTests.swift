import Foundation
import XCTest
@testable import QuotioDomain

final class QuotaModelsTests: XCTestCase {
    func testLegacyQuotaMetricDecodesWithoutTypedPresentation() throws {
        let data = Data(
            #"{"name":"legacy","percentage":42,"resetTime":"","used":3,"limit":10}"#.utf8
        )

        let metric = try JSONDecoder().decode(QuotaMetric.self, from: data)

        XCTAssertNil(metric.presentation)
        XCTAssertEqual(metric.percentage, 42)
        XCTAssertEqual(metric.used, 3)
        XCTAssertEqual(metric.limit, 10)
    }

    func testMetricPresentationsRoundTripThroughCodableSchema() throws {
        let values: [QuotaMetricPresentation] = [
            .progress(used: 1.25, limit: 10.5, unit: .usd),
            .amount(value: 4.75, unit: .credits, semantics: .balance),
            .status(text: "Enabled"),
        ]

        for value in values {
            let encoded = try JSONEncoder().encode(value)
            XCTAssertEqual(try JSONDecoder().decode(QuotaMetricPresentation.self, from: encoded), value)
        }
    }

    func testImportedIDEPolicyUpdatesOnlyExistingAccounts() {
        let old = ProviderQuota(models: [QuotaMetric(name: "usage", percentage: 10, resetTime: "")])
        let fresh = ProviderQuota(models: [QuotaMetric(name: "usage", percentage: 80, resetTime: "")])

        let result = QuotaPolicy.mergeImportedIDEQuotas(
            fetched: ["kept": fresh, "deleted": fresh],
            into: ["kept": old]
        )

        XCTAssertEqual(result, ["kept": fresh])
    }

    func testImportedIDEPolicyDoesNotImportWithoutConsent() {
        let fresh = ProviderQuota(models: [QuotaMetric(name: "usage", percentage: 80, resetTime: "")])

        XCTAssertTrue(QuotaPolicy.mergeImportedIDEQuotas(fetched: ["new": fresh], into: [:]).isEmpty)
    }

    func testImportedIDEPolicyKeepsAccountMissingFromFetch() {
        let existing = ProviderQuota(models: [QuotaMetric(name: "usage", percentage: 10, resetTime: "")])

        let result = QuotaPolicy.mergeImportedIDEQuotas(
            fetched: [:],
            into: ["kept": existing]
        )

        XCTAssertEqual(result, ["kept": existing])
    }

    func testCanonicalizedAccountsPromotesNewestAliasValue() {
        let stale = ProviderQuota(lastUpdated: Date(timeIntervalSince1970: 1_000))
        let fresh = ProviderQuota(lastUpdated: Date(timeIntervalSince1970: 2_000))

        let result = QuotaPolicy.canonicalizedAccounts(
            ["github-copilot-user.json": fresh, "user": stale],
            aliases: ["github-copilot-user.json": "user"]
        )

        XCTAssertEqual(result, ["user": fresh])
    }

    func testLastUpdatedDoesNotBorrowSiblingTimestamp() {
        let sibling = ProviderQuota(lastUpdated: Date(timeIntervalSince1970: 1_000))
        let account = QuotaAccountID(provider: .claude, accountKey: "failed@example.com")

        let updated = QuotaPolicy.lastUpdated(
            for: account,
            in: [.claude: ["successful@example.com": sibling]]
        )

        XCTAssertNil(updated)
    }

    func testLowestAvailablePercentageIgnoresUnknownMetrics() {
        let quota = ProviderQuota(models: [
            QuotaMetric(name: "unknown", percentage: -1, resetTime: ""),
            QuotaMetric(name: "monthly", percentage: 70, resetTime: ""),
            QuotaMetric(name: "weekly", percentage: 40, resetTime: ""),
        ])

        XCTAssertEqual(QuotaPolicy.lowestAvailablePercentage(in: quota), 40)
    }

    func testProviderTraitsKeepIDEImportAndRoutingRulesSeparate() {
        XCTAssertTrue(QuotaProvider.cursor.isImportedFromLocalIDE)
        XCTAssertTrue(QuotaProvider.trae.isImportedFromLocalIDE)
        XCTAssertFalse(QuotaProvider.cursor.supportsManualAuth)
        XCTAssertTrue(QuotaProvider.warp.isQuotaTrackingOnly)
        for provider in [
            QuotaProvider.factoryDroid, .devin, .grok, .openRouter, .amp, .warp,
        ] {
            XCTAssertFalse(provider.supportsLocalProxySetup)
        }
        XCTAssertTrue(QuotaProvider.codex.supportsLocalProxySetup)
        XCTAssertEqual(
            Set(QuotaProvider.allCases.filter(\.isImportedFromLocalIDE)),
            [.cursor, .trae]
        )
    }

    func testAggregatePoolReturnsNilForEmptyInput() {
        XCTAssertNil(QuotaPolicy.aggregatePool([]))
    }

    func testAggregatePoolKeepsWorstCasePercentagePerMetricAndMajorityPlan() {
        let depleted = ProviderQuota(
            models: [QuotaMetric(name: "codex-session", percentage: 20, resetTime: "")],
            planType: "plus"
        )
        let healthy = ProviderQuota(
            models: [QuotaMetric(name: "codex-session", percentage: 90, resetTime: "")],
            planType: "plus"
        )
        let differentPlan = ProviderQuota(
            models: [QuotaMetric(name: "codex-session", percentage: 60, resetTime: "")],
            planType: "business"
        )

        let aggregated = QuotaPolicy.aggregatePool([healthy, depleted, differentPlan])

        XCTAssertEqual(aggregated?.models.first(where: { $0.name == "codex-session" })?.percentage, 20)
        XCTAssertEqual(aggregated?.planType, "plus", "majority plan across the pool wins")
    }

    func testAggregatePoolIsForbiddenOnlyWhenEveryAccountIsForbidden() {
        let forbidden = ProviderQuota(isForbidden: true)
        let ok = ProviderQuota(models: [QuotaMetric(name: "m", percentage: 50, resetTime: "")])

        XCTAssertFalse(QuotaPolicy.aggregatePool([forbidden, ok])?.isForbidden ?? true)
        XCTAssertTrue(QuotaPolicy.aggregatePool([forbidden])?.isForbidden ?? false)
    }

    func testNormalizedPlanKeyBucketsEquivalentRawLabels() {
        XCTAssertEqual(QuotaPolicy.normalizedPlanKey("Plus"), "plus")
        XCTAssertEqual(QuotaPolicy.normalizedPlanKey("Business"), "business")
        XCTAssertEqual(QuotaPolicy.normalizedPlanKey("Pro"), "pro")
        XCTAssertEqual(QuotaPolicy.normalizedPlanKey("Pro 20x"), "pro")
        XCTAssertEqual(QuotaPolicy.normalizedPlanKey("Team"), "team")
        XCTAssertEqual(QuotaPolicy.normalizedPlanKey("Enterprise"), "enterprise")
        XCTAssertEqual(QuotaPolicy.normalizedPlanKey("Free"), "free")
        XCTAssertEqual(QuotaPolicy.normalizedPlanKey("Standard"), "free")
        XCTAssertEqual(QuotaPolicy.normalizedPlanKey(nil), "unknown")
        XCTAssertEqual(QuotaPolicy.normalizedPlanKey(""), "unknown")
        XCTAssertEqual(QuotaPolicy.normalizedPlanKey("Some Odd Label"), "some_odd_label")
    }

    /// Regression: a flat `contains("pro")` check used to collapse every Pro tier
    /// (5x and 20x) into a single "pro" bucket, hiding one plan's quota behind the
    /// other's in the pooled/grouped menu bar display.
    func testNormalizedPlanKeyDistinguishesProTiers() {
        XCTAssertEqual(QuotaPolicy.normalizedPlanKey("Pro 5x"), "pro_lite")
        XCTAssertEqual(QuotaPolicy.normalizedPlanKey("pro_lite"), "pro_lite")
        XCTAssertEqual(QuotaPolicy.normalizedPlanKey("pro-lite"), "pro_lite")
        XCTAssertEqual(QuotaPolicy.normalizedPlanKey("prolite"), "pro_lite")
        XCTAssertEqual(QuotaPolicy.normalizedPlanKey("Pro 20x"), "pro")
        XCTAssertEqual(QuotaPolicy.normalizedPlanKey("pro20x"), "pro")
        XCTAssertEqual(QuotaPolicy.normalizedPlanKey("Pro"), "pro")
        XCTAssertNotEqual(
            QuotaPolicy.normalizedPlanKey("Pro 5x"),
            QuotaPolicy.normalizedPlanKey("Pro 20x")
        )
    }

    /// Regression: an unrecognized plan label used to only replace spaces, so a label
    /// containing `::` or `/` would corrupt `RemoteQuotaPoolIdentity`'s `::`-delimited
    /// composite storage key. The slugified key must only ever contain letters, digits,
    /// and underscores.
    func testNormalizedPlanKeySlugifiesUnsafeCharacters() {
        let key = QuotaPolicy.normalizedPlanKey("weird::plan/name")
        XCTAssertTrue(key.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" })
        XCTAssertFalse(key.contains("::"))
        XCTAssertFalse(key.contains("/"))

        let components = RemoteQuotaPoolIdentity.components(
            fromStorageKey: RemoteQuotaPoolIdentity.storageKey(sourceId: "s1", planKey: key)
        )
        XCTAssertEqual(components?.sourceId, "s1")
        XCTAssertEqual(components?.planKey, key)
    }

    func testPlanGroupDisplayLabelShowsClaudePlusAsPro() {
        XCTAssertEqual(
            QuotaPolicy.planGroupDisplayLabel(provider: .claude, planKey: "plus", rawPlanType: "Plus"),
            "Pro"
        )
        XCTAssertEqual(
            QuotaPolicy.planGroupDisplayLabel(provider: .codex, planKey: "plus", rawPlanType: "Plus"),
            "Plus"
        )
        XCTAssertEqual(
            QuotaPolicy.planGroupDisplayLabel(provider: .codex, planKey: "business", rawPlanType: "Business"),
            "Business"
        )
        XCTAssertEqual(
            QuotaPolicy.planGroupDisplayLabel(provider: .codex, planKey: "team", rawPlanType: "Team"),
            "Team"
        )
    }

    func testPlanGroupDisplayLabelDistinguishesProTiers() {
        XCTAssertEqual(
            QuotaPolicy.planGroupDisplayLabel(provider: .codex, planKey: "pro", rawPlanType: "Pro 20x"),
            "Pro 20x"
        )
        XCTAssertEqual(
            QuotaPolicy.planGroupDisplayLabel(provider: .codex, planKey: "pro_lite", rawPlanType: "Pro 5x"),
            "Pro 5x"
        )
    }
}
