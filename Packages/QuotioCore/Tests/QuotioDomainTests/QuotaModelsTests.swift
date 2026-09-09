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

    // MARK: - QuotaPolicy.aggregate

    func testAggregateLowestPicksTheWorstReadingPerMetric() {
        let a = ProviderQuota(models: [QuotaMetric(name: "session", percentage: 70, resetTime: "")])
        let b = ProviderQuota(models: [QuotaMetric(name: "session", percentage: 20, resetTime: "")])

        let result = QuotaPolicy.aggregate([a, b], mode: .lowest)

        XCTAssertEqual(result.models.first?.percentage, 20)
        XCTAssertFalse(result.isForbidden)
    }

    func testAggregateAveragePicksTheMeanReadingPerMetric() {
        let a = ProviderQuota(models: [QuotaMetric(name: "session", percentage: 80, resetTime: "")])
        let b = ProviderQuota(models: [QuotaMetric(name: "session", percentage: 20, resetTime: "")])

        let result = QuotaPolicy.aggregate([a, b], mode: .average)

        XCTAssertEqual(result.models.first?.percentage, 50)
    }

    /// A forbidden account must never contribute a fabricated "healthy" number — its
    /// metrics are excluded from the math entirely, not treated as 0% or -1%.
    func testAggregateExcludesForbiddenAccountsFromTheMath() {
        let healthy = ProviderQuota(models: [QuotaMetric(name: "session", percentage: 90, resetTime: "")])
        let forbidden = ProviderQuota(
            models: [QuotaMetric(name: "session", percentage: 1, resetTime: "")],
            isForbidden: true
        )

        let result = QuotaPolicy.aggregate([healthy, forbidden], mode: .lowest)

        XCTAssertEqual(result.models.first?.percentage, 90)
        XCTAssertFalse(result.isForbidden)
    }

    /// When every contributing account is forbidden there is nothing usable to average —
    /// the aggregate must report forbidden with no models, never a synthetic reading.
    func testAggregateIsForbiddenOnlyWhenEveryAccountIsForbidden() {
        let a = ProviderQuota(models: [QuotaMetric(name: "session", percentage: 1, resetTime: "")], isForbidden: true)
        let b = ProviderQuota(models: [QuotaMetric(name: "session", percentage: 2, resetTime: "")], isForbidden: true)

        let result = QuotaPolicy.aggregate([a, b], mode: .lowest)

        XCTAssertTrue(result.isForbidden)
        XCTAssertTrue(result.models.isEmpty)
    }

    /// The summary must never claim to be fresher than its stalest contributing account.
    func testAggregateLastUpdatedIsTheEarliestContributingTimestamp() {
        let stale = ProviderQuota(lastUpdated: Date(timeIntervalSince1970: 1_000))
        let fresh = ProviderQuota(lastUpdated: Date(timeIntervalSince1970: 2_000))

        let result = QuotaPolicy.aggregate([stale, fresh], mode: .lowest)

        XCTAssertEqual(result.lastUpdated, stale.lastUpdated)
    }

    /// Accounts with no `planType` at all must bucket under "unknown" — the plan label
    /// must never be guessed from something else (e.g. the provider or another
    /// account's plan); it stays an explicit "Unknown", matching the existing
    /// `planGroupDisplayLabel` contract for the legacy pool path.
    func testAggregateOfAccountsWithUnknownPlanTypeStillAggregatesAndLabelsAsUnknown() {
        let a = ProviderQuota(models: [QuotaMetric(name: "session", percentage: 60, resetTime: "")], planType: nil)
        let b = ProviderQuota(models: [QuotaMetric(name: "session", percentage: 40, resetTime: "")], planType: nil)
        XCTAssertEqual(QuotaPolicy.normalizedPlanKey(a.planType), "unknown")

        let result = QuotaPolicy.aggregate([a, b], mode: .lowest)

        XCTAssertNil(result.planType)
        XCTAssertEqual(result.models.first?.percentage, 40)
        XCTAssertEqual(
            QuotaPolicy.planGroupDisplayLabel(provider: .claude, planKey: "unknown", rawPlanType: result.planType),
            "Unknown"
        )
    }

    /// A metric only some accounts report (e.g. one account is missing "extra-usage")
    /// still aggregates using only the accounts that actually reported it.
    func testAggregateHandlesMetricsPresentOnOnlySomeAccounts() {
        let a = ProviderQuota(models: [
            QuotaMetric(name: "session", percentage: 60, resetTime: ""),
            QuotaMetric(name: "extra-usage", percentage: 10, resetTime: ""),
        ])
        let b = ProviderQuota(models: [QuotaMetric(name: "session", percentage: 40, resetTime: "")])

        let result = QuotaPolicy.aggregate([a, b], mode: .average)

        XCTAssertEqual(result.models.first { $0.name == "session" }?.percentage, 50)
        XCTAssertEqual(result.models.first { $0.name == "extra-usage" }?.percentage, 10)
    }
}
