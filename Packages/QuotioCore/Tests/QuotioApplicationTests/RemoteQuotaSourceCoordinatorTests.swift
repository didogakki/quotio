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
            .partial(quotasByProviderAndPlan: [.codex: ["pro": Self.quota(50)]]),
            for: "s1"
        )
        await coordinator.refresh(sourceId: "s1", isAutomatic: true)

        let state = await coordinator.state
        XCTAssertEqual(state.poolQuotas["s1"]?[.codex]?["pro"]?.models.first?.percentage, 50)
        XCTAssertEqual(state.poolQuotas["s1"]?[.codex]?["team"]?.models.first?.percentage, 20)
        XCTAssertEqual(state.failureCounts["s1"], 1, "a partial failure must still count toward the hide threshold")
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
        case partial(quotasByProviderAndPlan: [QuotaProvider: [String: ProviderQuota]])
        case failure
        case customFailure(Error)
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
            return RemoteQuotaPoolFetchResult(quotasByProviderAndPlan: quotas, hasPartialFailure: false)
        case .partial(let quotas):
            return RemoteQuotaPoolFetchResult(quotasByProviderAndPlan: quotas, hasPartialFailure: true)
        case .failure:
            throw StubFetcherError.simulatedFailure
        case .customFailure(let error):
            throw error
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
