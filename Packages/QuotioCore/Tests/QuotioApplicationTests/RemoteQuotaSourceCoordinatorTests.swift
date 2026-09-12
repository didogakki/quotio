import Foundation
import XCTest
@testable import QuotioApplication
@testable import QuotioDomain

final class RemoteQuotaSourceCoordinatorTests: XCTestCase {
    func testAddSourcePersistsConfigAndManagementKey() async {
        let repository = MemoryRemoteQuotaSourceRepository()
        let vault = MemoryCredentialVault()
        let coordinator = makeCoordinator(repository: repository, vault: vault)
        let source = RemoteQuotaSourceConfig(id: "s1", name: "Plus", baseURL: "https://a.test")

        await coordinator.addSource(source, managementKey: "secret-key")

        XCTAssertEqual(repository.saved.map(\.id), ["s1"])
        let stored = await vault.loadManagementKey(sourceId: "s1")
        XCTAssertEqual(stored, "secret-key")
    }

    func testTwoSourcesWithSameProviderAndPlanProduceIsolatedPoolEntries() async {
        // Mirrors the exact conflict scenario the composite key must prevent:
        // two different CLIProxyAPI servers both pooling Codex accounts.
        let fetcher = StubFetcher()
        let coordinator = makeCoordinator(fetcher: fetcher)
        let plus = RemoteQuotaSourceConfig(id: "plus", name: "Plus Pool", baseURL: "https://plus.test")
        let business = RemoteQuotaSourceConfig(id: "business", name: "Business Pool", baseURL: "https://biz.test")
        await coordinator.addSource(plus, managementKey: "k1")
        await coordinator.addSource(business, managementKey: "k2")
        await fetcher.enqueue(.success([.codex: ["pro": Self.quota(70)]]), for: "plus")
        await fetcher.enqueue(.success([.codex: ["pro": Self.quota(30)]]), for: "business")

        await coordinator.refreshAll()

        let state = await coordinator.state
        XCTAssertEqual(state.poolQuotas["plus"]?[.codex]?["pro"]?.models.first?.percentage, 70)
        XCTAssertEqual(state.poolQuotas["business"]?[.codex]?["pro"]?.models.first?.percentage, 30)
    }

    func testTwoPlanGroupsForSameSourceAndProviderStayIsolated() async {
        let fetcher = StubFetcher()
        let coordinator = makeCoordinator(fetcher: fetcher)
        let source = RemoteQuotaSourceConfig(id: "s1", name: "Pool", baseURL: "https://a.test")
        await coordinator.addSource(source, managementKey: "k")
        await fetcher.enqueue(
            .success([.codex: ["pro": Self.quota(70), "team": Self.quota(20)]]),
            for: "s1"
        )

        await coordinator.refresh(sourceId: "s1")

        let state = await coordinator.state
        XCTAssertEqual(state.poolQuotas["s1"]?[.codex]?["pro"]?.models.first?.percentage, 70)
        XCTAssertEqual(state.poolQuotas["s1"]?[.codex]?["team"]?.models.first?.percentage, 20)
    }

    func testPartialFailureMergesSuccessfulGroupsAndKeepsOldFailedGroup() async {
        let fetcher = StubFetcher()
        let coordinator = makeCoordinator(fetcher: fetcher)
        let source = RemoteQuotaSourceConfig(id: "s1", name: "Pool", baseURL: "https://a.test")
        await coordinator.addSource(source, managementKey: "k")
        await fetcher.enqueue(
            .success([.codex: ["pro": Self.quota(70), "team": Self.quota(20)]]),
            for: "s1"
        )
        await coordinator.refresh(sourceId: "s1")

        // Second round: only "pro" refreshes (with a partial-failure flag); "team" must
        // keep its last-known-good value instead of disappearing.
        await fetcher.enqueue(
            .partial(quotasByProviderAndAccount: [.codex: ["pro": Self.quota(50)]]),
            for: "s1"
        )
        await coordinator.refresh(sourceId: "s1", isAutomatic: true)

        let state = await coordinator.state
        XCTAssertEqual(state.poolQuotas["s1"]?[.codex]?["pro"]?.models.first?.percentage, 50)
        XCTAssertEqual(state.poolQuotas["s1"]?[.codex]?["team"]?.models.first?.percentage, 20)
        XCTAssertEqual(state.failureCounts["s1"], 1, "a partial failure must still count toward the hide threshold")
    }

    /// An account that drops out of the auth-file listing entirely (deleted or
    /// disabled on the remote server) must be pruned from `poolQuotas` instead of
    /// lingering forever, once the fetcher reports the current round's full
    /// `knownAccountKeys` for that provider.
    func testAccountRemovedFromListingIsPrunedFromPoolQuotas() async {
        let fetcher = StubFetcher()
        let coordinator = makeCoordinator(fetcher: fetcher)
        let source = RemoteQuotaSourceConfig(id: "s1", name: "Pool", baseURL: "https://a.test")
        await coordinator.addSource(source, managementKey: "k")
        await fetcher.enqueue(
            .result(RemoteQuotaPoolFetchResult(
                quotasByProviderAndAccount: [.codex: ["a": Self.quota(70), "b": Self.quota(40)]],
                outcome: .complete,
                knownAccountKeys: [.codex: ["a", "b"]]
            )),
            for: "s1"
        )
        await coordinator.refresh(sourceId: "s1")

        // Round two: "b" was deleted/disabled on the remote server, so it no longer
        // appears in the listing at all — its stale reading must be pruned, not kept.
        await fetcher.enqueue(
            .result(RemoteQuotaPoolFetchResult(
                quotasByProviderAndAccount: [.codex: ["a": Self.quota(60)]],
                outcome: .complete,
                knownAccountKeys: [.codex: ["a"]]
            )),
            for: "s1"
        )
        await coordinator.refresh(sourceId: "s1")

        let state = await coordinator.state
        XCTAssertEqual(state.poolQuotas["s1"]?[.codex]?["a"]?.models.first?.percentage, 60)
        XCTAssertNil(state.poolQuotas["s1"]?[.codex]?["b"], "an account removed from the listing must be pruned")
    }

    /// An account that is still present in the auth-file listing but whose own quota
    /// request merely failed this round must keep its last-known-good reading — this
    /// is the counterpart to pruning: "known but failed" must never be treated the
    /// same as "no longer known at all".
    func testAccountStillListedButQuotaFetchFailedKeepsLastKnownGood() async {
        let fetcher = StubFetcher()
        let coordinator = makeCoordinator(fetcher: fetcher)
        let source = RemoteQuotaSourceConfig(id: "s1", name: "Pool", baseURL: "https://a.test")
        await coordinator.addSource(source, managementKey: "k")
        await fetcher.enqueue(
            .result(RemoteQuotaPoolFetchResult(
                quotasByProviderAndAccount: [.codex: ["a": Self.quota(70), "b": Self.quota(40)]],
                outcome: .complete,
                knownAccountKeys: [.codex: ["a", "b"]]
            )),
            for: "s1"
        )
        await coordinator.refresh(sourceId: "s1")

        // Round two: "b" is still a ready, supported auth file (still known), but its
        // individual quota request failed this round — it must not disappear.
        await fetcher.enqueue(
            .result(RemoteQuotaPoolFetchResult(
                quotasByProviderAndAccount: [.codex: ["a": Self.quota(55)]],
                outcome: .partial,
                knownAccountKeys: [.codex: ["a", "b"]]
            )),
            for: "s1"
        )
        await coordinator.refresh(sourceId: "s1", isAutomatic: true)

        let state = await coordinator.state
        XCTAssertEqual(state.poolQuotas["s1"]?[.codex]?["a"]?.models.first?.percentage, 55)
        XCTAssertEqual(
            state.poolQuotas["s1"]?[.codex]?["b"]?.models.first?.percentage, 40,
            "an account still listed but merely failed this round's quota fetch must keep its last-known-good value"
        )
    }

    /// Deleting a provider's **last** account must remove that provider outright.
    /// Pruning only providers that still have a surviving account left the deleted
    /// one's stale reading visible forever, which is why the listing has to report an
    /// empty set for a provider rather than omitting it.
    func testProviderWhoseLastAccountWasDeletedDisappearsEntirely() async {
        let fetcher = StubFetcher()
        let coordinator = makeCoordinator(fetcher: fetcher)
        await coordinator.addSource(
            RemoteQuotaSourceConfig(id: "s1", name: "Pool", baseURL: "https://a.test"),
            managementKey: "k"
        )
        await fetcher.enqueue(
            .result(RemoteQuotaPoolFetchResult(
                quotasByProviderAndAccount: [.codex: ["a": Self.quota(70)], .claude: ["c": Self.quota(40)]],
                outcome: .complete,
                knownAccountKeys: [.codex: ["a"], .claude: ["c"], .grok: []]
            )),
            for: "s1"
        )
        await coordinator.refresh(sourceId: "s1")

        // "c" — Claude's only account — was deleted remotely. Claude is still listed,
        // now with no accounts at all.
        await fetcher.enqueue(
            .result(RemoteQuotaPoolFetchResult(
                quotasByProviderAndAccount: [.codex: ["a": Self.quota(65)]],
                outcome: .complete,
                knownAccountKeys: [.codex: ["a"], .claude: [], .grok: []]
            )),
            for: "s1"
        )
        await coordinator.refresh(sourceId: "s1")

        let state = await coordinator.state
        XCTAssertEqual(state.poolQuotas["s1"]?[.codex]?["a"]?.models.first?.percentage, 65)
        XCTAssertNil(
            state.poolQuotas["s1"]?[.claude],
            "a provider whose last account was deleted must disappear, not keep a stale reading"
        )
    }

    /// An empty listing is authoritative, not an error: the source genuinely has no
    /// supported ready account left, so every stale entry must go — while the source's
    /// own configuration survives untouched and the round still counts as a failure.
    func testEmptyAuthoritativeListingPrunesEverythingButKeepsTheSource() async {
        let repository = MemoryRemoteQuotaSourceRepository()
        let fetcher = StubFetcher()
        let coordinator = makeCoordinator(repository: repository, fetcher: fetcher)
        await coordinator.addSource(
            RemoteQuotaSourceConfig(id: "s1", name: "Pool", baseURL: "https://a.test"),
            managementKey: "k"
        )
        await fetcher.enqueue(
            .result(RemoteQuotaPoolFetchResult(
                quotasByProviderAndAccount: [.codex: ["a": Self.quota(70)]],
                outcome: .complete,
                knownAccountKeys: [.codex: ["a"], .claude: [], .grok: []]
            )),
            for: "s1"
        )
        await coordinator.refresh(sourceId: "s1")

        await fetcher.enqueue(
            .result(RemoteQuotaPoolFetchResult(
                outcome: .noAccountsListed,
                knownAccountKeys: [.codex: [], .claude: [], .grok: []]
            )),
            for: "s1"
        )
        await coordinator.refresh(sourceId: "s1", isAutomatic: true)

        let state = await coordinator.state
        XCTAssertEqual(
            state.poolQuotas["s1"]?.isEmpty, true,
            "an empty authoritative listing must clear every stale account"
        )
        XCTAssertEqual(repository.saved.map(\.id), ["s1"], "the source's own config must never be discarded")
        XCTAssertEqual(state.failureCounts["s1"], 1)
        guard case .error(let key) = state.statuses["s1"] else {
            return XCTFail("expected an error status")
        }
        XCTAssertEqual(key, RemoteQuotaFetchError.noSupportedReadyFiles.localizationKey)
    }

    /// Every quota request failing says nothing about which accounts exist — the
    /// listing that round still succeeded, so accounts that dropped out of it must be
    /// pruned while accounts that are still listed keep their last-known-good reading.
    func testEveryQuotaRequestFailingStillPrunesUsingTheListing() async {
        let fetcher = StubFetcher()
        let coordinator = makeCoordinator(fetcher: fetcher)
        await coordinator.addSource(
            RemoteQuotaSourceConfig(id: "s1", name: "Pool", baseURL: "https://a.test"),
            managementKey: "k"
        )
        await fetcher.enqueue(
            .result(RemoteQuotaPoolFetchResult(
                quotasByProviderAndAccount: [.codex: ["a": Self.quota(70), "b": Self.quota(40)]],
                outcome: .complete,
                knownAccountKeys: [.codex: ["a", "b"], .claude: [], .grok: []]
            )),
            for: "s1"
        )
        await coordinator.refresh(sourceId: "s1")

        await fetcher.enqueue(
            .result(RemoteQuotaPoolFetchResult(
                outcome: .allFailed,
                knownAccountKeys: [.codex: ["a"], .claude: [], .grok: []]
            )),
            for: "s1"
        )
        await coordinator.refresh(sourceId: "s1", isAutomatic: true)

        let state = await coordinator.state
        XCTAssertEqual(
            state.poolQuotas["s1"]?[.codex]?["a"]?.models.first?.percentage, 70,
            "an account still listed keeps its last-known-good reading when its request fails"
        )
        XCTAssertNil(state.poolQuotas["s1"]?[.codex]?["b"], "an account no longer listed must still be pruned")
        XCTAssertEqual(state.failureCounts["s1"], 1)
        guard case .error(let key) = state.statuses["s1"] else {
            return XCTFail("expected an error status")
        }
        XCTAssertEqual(key, RemoteQuotaFetchError.allRequestsFailed.localizationKey)
    }

    /// The opposite case: when the listing itself could not be obtained, nothing about
    /// the account set is known, so nothing may be pruned — not even an account that a
    /// later successful round would legitimately remove.
    func testListingFailurePrunesNothing() async {
        let fetcher = StubFetcher()
        let coordinator = makeCoordinator(fetcher: fetcher)
        await coordinator.addSource(
            RemoteQuotaSourceConfig(id: "s1", name: "Pool", baseURL: "https://a.test"),
            managementKey: "k"
        )
        await fetcher.enqueue(
            .result(RemoteQuotaPoolFetchResult(
                quotasByProviderAndAccount: [.codex: ["a": Self.quota(70), "b": Self.quota(40)]],
                outcome: .complete,
                knownAccountKeys: [.codex: ["a", "b"], .claude: [], .grok: []]
            )),
            for: "s1"
        )
        await coordinator.refresh(sourceId: "s1")

        await fetcher.enqueue(.customFailure(RemoteQuotaFetchError.authFilesUnavailable), for: "s1")
        await coordinator.refresh(sourceId: "s1", isAutomatic: true)

        let state = await coordinator.state
        XCTAssertEqual(state.poolQuotas["s1"]?[.codex]?["a"]?.models.first?.percentage, 70)
        XCTAssertEqual(
            state.poolQuotas["s1"]?[.codex]?["b"]?.models.first?.percentage, 40,
            "a listing failure must never be treated as an authoritative empty list"
        )
    }

    func testDisabledSourceIsNeverVisibleEvenWithAPriorSnapshot() async {
        let fetcher = StubFetcher()
        let coordinator = makeCoordinator(fetcher: fetcher)
        var source = RemoteQuotaSourceConfig(id: "s1", name: "Pool", baseURL: "https://a.test")
        await coordinator.addSource(source, managementKey: "k")
        await fetcher.enqueue(.success([.claude: ["pro": Self.quota(80)]]), for: "s1")
        await coordinator.refresh(sourceId: "s1")

        source.isEnabled = false
        await coordinator.updateSource(source, managementKey: nil)

        let state = await coordinator.state
        XCTAssertFalse(state.isVisible(sourceId: "s1"))
        XCTAssertNotNil(state.poolQuotas["s1"], "the snapshot itself should survive disabling, just not be visible")
    }

    func testAutomaticFailuresHideSourceAfterThreeAndRestoreOnSuccess() async {
        let fetcher = StubFetcher()
        let coordinator = makeCoordinator(fetcher: fetcher)
        let source = RemoteQuotaSourceConfig(id: "s1", name: "Pool", baseURL: "https://a.test")
        await coordinator.addSource(source, managementKey: "k")

        for _ in 0..<3 {
            await fetcher.enqueue(.failure, for: "s1")
        }

        var state = await coordinator.state
        XCTAssertTrue(state.isVisible(sourceId: "s1"))

        await coordinator.refresh(sourceId: "s1", isAutomatic: true)
        await coordinator.refresh(sourceId: "s1", isAutomatic: true)
        state = await coordinator.state
        XCTAssertTrue(state.isVisible(sourceId: "s1"), "must stay visible below the threshold")

        await coordinator.refresh(sourceId: "s1", isAutomatic: true)
        state = await coordinator.state
        XCTAssertFalse(state.isVisible(sourceId: "s1"), "must hide once automatic failures reach 3")

        await fetcher.enqueue(.success([.claude: ["pro": Self.quota(80)]]), for: "s1")
        await coordinator.refresh(sourceId: "s1", isAutomatic: true)
        state = await coordinator.state
        XCTAssertTrue(state.isVisible(sourceId: "s1"), "must recover immediately on success")
        XCTAssertEqual(state.failureCounts["s1"], 0)
    }

    func testManualRefreshFailuresNeverCountTowardTheHideThreshold() async {
        let fetcher = StubFetcher()
        let coordinator = makeCoordinator(fetcher: fetcher)
        let source = RemoteQuotaSourceConfig(id: "s1", name: "Pool", baseURL: "https://a.test")
        await coordinator.addSource(source, managementKey: "k")
        for _ in 0..<5 {
            await fetcher.enqueue(.failure, for: "s1")
        }

        for _ in 0..<5 {
            await coordinator.refresh(sourceId: "s1", isAutomatic: false)
        }

        let state = await coordinator.state
        XCTAssertEqual(state.failureCounts["s1"] ?? 0, 0)
        XCTAssertTrue(state.isVisible(sourceId: "s1"))
    }

    func testFailedRefreshPreservesLastSuccessfulPoolReading() async {
        let fetcher = StubFetcher()
        let coordinator = makeCoordinator(fetcher: fetcher)
        let source = RemoteQuotaSourceConfig(id: "s1", name: "Pool", baseURL: "https://a.test")
        await coordinator.addSource(source, managementKey: "k")
        await fetcher.enqueue(.success([.claude: ["pro": Self.quota(55)]]), for: "s1")
        await coordinator.refresh(sourceId: "s1", isAutomatic: true)

        await fetcher.enqueue(.failure, for: "s1")
        await coordinator.refresh(sourceId: "s1", isAutomatic: true)

        let state = await coordinator.state
        XCTAssertEqual(state.poolQuotas["s1"]?[.claude]?["pro"]?.models.first?.percentage, 55)
    }

    func testEmptyResultOnTotalFailureNeverOverwritesLastKnownGood() async {
        let fetcher = StubFetcher()
        let coordinator = makeCoordinator(fetcher: fetcher)
        let source = RemoteQuotaSourceConfig(id: "s1", name: "Pool", baseURL: "https://a.test")
        await coordinator.addSource(source, managementKey: "k")
        await fetcher.enqueue(.success([.claude: ["pro": Self.quota(55)]]), for: "s1")
        await coordinator.refresh(sourceId: "s1")

        // A total failure with an empty result must never look like a successful
        // "nothing left" refresh — it must still throw and preserve the old reading.
        await fetcher.enqueue(.failure, for: "s1")
        await coordinator.refresh(sourceId: "s1", isAutomatic: true)

        let state = await coordinator.state
        XCTAssertEqual(state.poolQuotas["s1"]?[.claude]?["pro"]?.models.first?.percentage, 55)
        XCTAssertEqual(state.failureCounts["s1"], 1)
    }

    func testKnownFetchErrorMapsToItsOwnLocalizationKeyNotRawDescription() async {
        let fetcher = StubFetcher()
        let coordinator = makeCoordinator(fetcher: fetcher)
        let source = RemoteQuotaSourceConfig(id: "s1", name: "Pool", baseURL: "https://a.test")
        await coordinator.addSource(source, managementKey: "k")
        await fetcher.enqueue(.customFailure(RemoteQuotaFetchError.unauthorized), for: "s1")

        await coordinator.refresh(sourceId: "s1", isAutomatic: true)

        let state = await coordinator.state
        guard case .error(let key) = state.statuses["s1"] else {
            return XCTFail("expected an error status")
        }
        XCTAssertEqual(key, RemoteQuotaFetchError.unauthorized.localizationKey)
    }

    func testUnknownFetchErrorNeverLeaksItsOpaqueDescriptionAsTheStatusKey() async {
        let fetcher = StubFetcher()
        let coordinator = makeCoordinator(fetcher: fetcher)
        let source = RemoteQuotaSourceConfig(id: "s1", name: "Pool", baseURL: "https://a.test")
        await coordinator.addSource(source, managementKey: "k")
        // A totally unmapped error type — the coordinator must never bridge this to an
        // NSError-style description (e.g. "SomeModule.SomeError error 1").
        await fetcher.enqueue(.failure, for: "s1")

        await coordinator.refresh(sourceId: "s1", isAutomatic: true)

        let state = await coordinator.state
        guard case .error(let key) = state.statuses["s1"] else {
            return XCTFail("expected an error status")
        }
        XCTAssertEqual(key, RemoteQuotaSourceFailure.unknownFetchFailure.localizationKey)
        XCTAssertFalse(key.contains("StubFetcherError"))
        XCTAssertFalse(key.contains("error 1"))
    }

    func testRemoveSourceDeletesCredentialAndClearsState() async {
        let repository = MemoryRemoteQuotaSourceRepository()
        let vault = MemoryCredentialVault()
        let fetcher = StubFetcher()
        let coordinator = makeCoordinator(repository: repository, vault: vault, fetcher: fetcher)
        let source = RemoteQuotaSourceConfig(id: "s1", name: "Pool", baseURL: "https://a.test")
        await coordinator.addSource(source, managementKey: "k")
        await fetcher.enqueue(.success([.claude: ["pro": Self.quota(55)]]), for: "s1")
        await coordinator.refresh(sourceId: "s1", isAutomatic: false)

        await coordinator.removeSource("s1")

        XCTAssertTrue(repository.saved.isEmpty)
        let key = await vault.loadManagementKey(sourceId: "s1")
        XCTAssertNil(key)
        let state = await coordinator.state
        XCTAssertNil(state.poolQuotas["s1"])
    }

    // MARK: - Codex reset-credit preservation on partial failure

    /// A reset-credit fetch failure this round (the fresh reading has no summary of its
    /// own) must preserve the last successful summary — usage still refreshes normally.
    func testResetCreditFailureThisRoundPreservesLastKnownGoodSummary() async {
        let fetcher = StubFetcher()
        let coordinator = makeCoordinator(fetcher: fetcher)
        let source = RemoteQuotaSourceConfig(id: "s1", name: "Pool", baseURL: "https://a.test")
        await coordinator.addSource(source, managementKey: "k")

        var withCredits = Self.quota(70)
        withCredits.codexResetCreditSummary = CodexResetCreditSummary(availableCount: 2, nearestExpiryAt: nil)
        await fetcher.enqueue(.success([.codex: ["a": withCredits]]), for: "s1")
        await coordinator.refresh(sourceId: "s1")

        await fetcher.enqueue(.success([.codex: ["a": Self.quota(50)]]), for: "s1")
        await coordinator.refresh(sourceId: "s1")

        let state = await coordinator.state
        XCTAssertEqual(state.poolQuotas["s1"]?[.codex]?["a"]?.models.first?.percentage, 50)
        XCTAssertEqual(
            state.poolQuotas["s1"]?[.codex]?["a"]?.codexResetCreditSummary?.availableCount, 2,
            "a reset-credit fetch failure this round must not discard the last successful summary"
        )
    }

    /// A genuine successful zero reading must replace an old positive value, never be
    /// mistaken for a failure.
    func testResetCreditValidZeroReplacesOldPositiveSummary() async {
        let fetcher = StubFetcher()
        let coordinator = makeCoordinator(fetcher: fetcher)
        let source = RemoteQuotaSourceConfig(id: "s1", name: "Pool", baseURL: "https://a.test")
        await coordinator.addSource(source, managementKey: "k")

        var withCredits = Self.quota(70)
        withCredits.codexResetCreditSummary = CodexResetCreditSummary(availableCount: 3, nearestExpiryAt: nil)
        await fetcher.enqueue(.success([.codex: ["a": withCredits]]), for: "s1")
        await coordinator.refresh(sourceId: "s1")

        var zeroCredits = Self.quota(50)
        zeroCredits.codexResetCreditSummary = CodexResetCreditSummary(availableCount: 0, nearestExpiryAt: nil)
        await fetcher.enqueue(.success([.codex: ["a": zeroCredits]]), for: "s1")
        await coordinator.refresh(sourceId: "s1")

        let state = await coordinator.state
        XCTAssertEqual(state.poolQuotas["s1"]?[.codex]?["a"]?.codexResetCreditSummary?.availableCount, 0)
    }

    /// An account removed from the listing must stay pruned even though reset-credit
    /// preservation now also runs on every merge.
    func testRemovedAccountStaysGoneDespiteResetCreditPreservation() async {
        let fetcher = StubFetcher()
        let coordinator = makeCoordinator(fetcher: fetcher)
        let source = RemoteQuotaSourceConfig(id: "s1", name: "Pool", baseURL: "https://a.test")
        await coordinator.addSource(source, managementKey: "k")

        var withCredits = Self.quota(70)
        withCredits.codexResetCreditSummary = CodexResetCreditSummary(availableCount: 2, nearestExpiryAt: nil)
        await fetcher.enqueue(
            .result(RemoteQuotaPoolFetchResult(
                quotasByProviderAndAccount: [.codex: ["a": withCredits]],
                outcome: .complete,
                knownAccountKeys: [.codex: ["a"]]
            )),
            for: "s1"
        )
        await coordinator.refresh(sourceId: "s1")

        await fetcher.enqueue(
            .result(RemoteQuotaPoolFetchResult(
                outcome: .noAccountsListed,
                knownAccountKeys: [.codex: [], .claude: [], .grok: []]
            )),
            for: "s1"
        )
        await coordinator.refresh(sourceId: "s1")

        let state = await coordinator.state
        XCTAssertNil(state.poolQuotas["s1"]?[.codex]?["a"])
    }

    // MARK: - Legacy Grok "Premium" default (scoped by stable source id, not display name)

    func testLegacyGrokPremiumDefaultAppliesToTheCapturedSourceAndSurvivesRename() async {
        let fetcher = StubFetcher()
        let coordinator = makeCoordinator(fetcher: fetcher)
        var source = RemoteQuotaSourceConfig(id: "plus-1", name: "CLIProxyAPI Plus", baseURL: "https://a.test")
        await coordinator.addSource(source, managementKey: "k")
        await fetcher.enqueue(.success([.grok: ["a": Self.quota(70)]]), for: "plus-1")
        await coordinator.refresh(sourceId: "plus-1")

        var state = await coordinator.state
        XCTAssertEqual(state.poolQuotas["plus-1"]?[.grok]?["a"]?.planType, "Premium")

        // Rename the same source (same id) — the default must survive.
        source.name = "Renamed Plus"
        await coordinator.updateSource(source, managementKey: nil)
        await fetcher.enqueue(.success([.grok: ["a": Self.quota(60)]]), for: "plus-1")
        await coordinator.refresh(sourceId: "plus-1")

        state = await coordinator.state
        XCTAssertEqual(state.poolQuotas["plus-1"]?[.grok]?["a"]?.planType, "Premium")
    }

    func testLegacyGrokPremiumDefaultNeverAppliesToAnUnrelatedSourceWithTheSameName() async {
        let fetcher = StubFetcher()
        let coordinator = makeCoordinator(fetcher: fetcher)
        let captured = RemoteQuotaSourceConfig(id: "plus-1", name: "CLIProxyAPI Plus", baseURL: "https://a.test")
        let unrelated = RemoteQuotaSourceConfig(id: "plus-2", name: "CLIProxyAPI Plus", baseURL: "https://b.test")
        await coordinator.addSource(captured, managementKey: "k1")
        await coordinator.addSource(unrelated, managementKey: "k2")
        await fetcher.enqueue(.success([.grok: ["a": Self.quota(70)]]), for: "plus-2")

        await coordinator.refresh(sourceId: "plus-2")

        let state = await coordinator.state
        XCTAssertNil(
            state.poolQuotas["plus-2"]?[.grok]?["a"]?.planType,
            "an unrelated source sharing the display name must never get the legacy default"
        )
    }

    /// The confirmed identity must survive a cold relaunch — a fresh coordinator built
    /// on top of the same repository — even after the source was renamed and never
    /// refreshed again in the session that renamed it. A second, unrelated source that
    /// merely shares the original display name must still never qualify, even freshly
    /// resolved from the same on-disk state.
    func testLegacyGrokPremiumDefaultSurvivesColdRelaunchAfterRename() async {
        let repository = MemoryRemoteQuotaSourceRepository()
        let vault = MemoryCredentialVault()
        let fetcher = StubFetcher()
        let coordinator = makeCoordinator(repository: repository, vault: vault, fetcher: fetcher)
        var source = RemoteQuotaSourceConfig(id: "plus-1", name: "CLIProxyAPI Plus", baseURL: "https://a.test")
        await coordinator.addSource(source, managementKey: "k")

        // Rename it, but never refresh again this session — the in-memory capture from
        // `addSource` is gone once this coordinator is discarded below.
        source.name = "Renamed Plus"
        await coordinator.updateSource(source, managementKey: nil)

        // A cold relaunch: a brand-new coordinator instance re-reading the same
        // persisted repository and credential vault state, the way app startup does —
        // only the coordinator's own in-memory state is discarded, not the keychain.
        let relaunched = makeCoordinator(repository: repository, vault: vault, fetcher: fetcher)
        let unrelated = RemoteQuotaSourceConfig(id: "plus-2", name: "CLIProxyAPI Plus", baseURL: "https://b.test")
        await relaunched.addSource(unrelated, managementKey: "k2")

        await fetcher.enqueue(.success([.grok: ["a": Self.quota(70)]]), for: "plus-1")
        await fetcher.enqueue(.success([.grok: ["a": Self.quota(40)]]), for: "plus-2")
        await relaunched.refresh(sourceId: "plus-1")
        await relaunched.refresh(sourceId: "plus-2")

        let state = await relaunched.state
        XCTAssertEqual(
            state.poolQuotas["plus-1"]?[.grok]?["a"]?.planType, "Premium",
            "the renamed, previously-confirmed source must keep the default after a cold relaunch"
        )
        XCTAssertNil(
            state.poolQuotas["plus-2"]?[.grok]?["a"]?.planType,
            "an unrelated source that merely shares the original display name must stay unknown"
        )
    }

    func testLegacyGrokPremiumDefaultNeverOverridesRealMetadata() async {
        let fetcher = StubFetcher()
        let coordinator = makeCoordinator(fetcher: fetcher)
        let source = RemoteQuotaSourceConfig(id: "plus-1", name: "CLIProxyAPI Plus", baseURL: "https://a.test")
        await coordinator.addSource(source, managementKey: "k")
        var withPlan = Self.quota(70)
        withPlan.planType = "Basic"
        await fetcher.enqueue(.success([.grok: ["a": withPlan]]), for: "plus-1")

        await coordinator.refresh(sourceId: "plus-1")

        let state = await coordinator.state
        XCTAssertEqual(state.poolQuotas["plus-1"]?[.grok]?["a"]?.planType, "Basic")
    }

    // MARK: - Helpers

    private func makeCoordinator(
        repository: MemoryRemoteQuotaSourceRepository = MemoryRemoteQuotaSourceRepository(),
        vault: MemoryCredentialVault = MemoryCredentialVault(),
        fetcher: StubFetcher = StubFetcher(),
        snapshotStore: MemorySnapshotStore = MemorySnapshotStore()
    ) -> RemoteQuotaSourceCoordinator {
        RemoteQuotaSourceCoordinator(
            repository: repository,
            credentials: vault,
            fetcher: fetcher,
            snapshotStore: snapshotStore,
            clock: TestClock(now: Date(timeIntervalSince1970: 1_800_000_000))
        )
    }

    private static func quota(_ percentage: Double) -> ProviderQuota {
        ProviderQuota(models: [QuotaMetric(name: "usage", percentage: percentage, resetTime: "")])
    }
}

// MARK: - Test doubles

private final class MemoryRemoteQuotaSourceRepository: RemoteQuotaSourceRepository, @unchecked Sendable {
    private(set) var saved: [RemoteQuotaSourceConfig]

    init(initial: [RemoteQuotaSourceConfig] = []) {
        saved = initial
    }

    func load() -> [RemoteQuotaSourceConfig] { saved }
    func save(_ sources: [RemoteQuotaSourceConfig]) { saved = sources }
}

private actor MemoryCredentialVault: RemoteQuotaSourceCredentialVault {
    private var keys: [String: String] = [:]

    func loadManagementKey(sourceId: String) async -> String? { keys[sourceId] }

    func saveManagementKey(_ key: String, sourceId: String) async -> Bool {
        keys[sourceId] = key
        return true
    }

    func deleteManagementKey(sourceId: String) async {
        keys.removeValue(forKey: sourceId)
    }
}

private final class MemorySnapshotStore: RemoteQuotaPoolSnapshotStoring, @unchecked Sendable {
    private var stored = RemoteQuotaPoolSnapshot()

    func load() -> RemoteQuotaPoolSnapshot { stored }
    func save(_ snapshot: RemoteQuotaPoolSnapshot) { stored = snapshot }
}

private actor StubFetcher: RemoteQuotaSourceFetching {
    enum Outcome {
        case success([QuotaProvider: [String: ProviderQuota]])
        case partial(quotasByProviderAndAccount: [QuotaProvider: [String: ProviderQuota]])
        case failure
        case customFailure(Error)
        /// Full control over the result, including `knownAccountKeys`, for tests that
        /// exercise pruning of accounts that dropped out of the auth-file listing.
        case result(RemoteQuotaPoolFetchResult)
    }

    private var queues: [String: [Outcome]] = [:]

    func enqueue(_ outcome: Outcome, for sourceId: String) {
        queues[sourceId, default: []].append(outcome)
    }

    func isResponding(_ source: RemoteQuotaSourceConfig, managementKey: String) async -> Bool { true }

    func fetchPool(
        _ source: RemoteQuotaSourceConfig,
        managementKey: String
    ) async throws -> RemoteQuotaPoolFetchResult {
        guard var queue = queues[source.id], !queue.isEmpty else {
            throw StubFetcherError.noQueuedOutcome
        }
        let outcome = queue.removeFirst()
        queues[source.id] = queue
        switch outcome {
        case .success(let quotas):
            return RemoteQuotaPoolFetchResult(quotasByProviderAndAccount: quotas, outcome: .complete)
        case .partial(let quotas):
            return RemoteQuotaPoolFetchResult(quotasByProviderAndAccount: quotas, outcome: .partial)
        case .failure:
            throw StubFetcherError.simulatedFailure
        case .customFailure(let error):
            throw error
        case .result(let result):
            return result
        }
    }
}

private enum StubFetcherError: Error {
    case noQueuedOutcome
    case simulatedFailure
}

private struct TestClock: DateProviding {
    let nowValue: Date

    init(now: Date) {
        nowValue = now
    }

    func now() -> Date { nowValue }
}
