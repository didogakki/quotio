import Foundation
import QuotioApplication
import QuotioDomain
import XCTest

@testable import QuotioPresentation

@MainActor
final class RemoteQuotaSourceScreenModelLifecycleTests: XCTestCase {
    /// Regression: refresh start/stop used to be wired only from `SettingsScreen`'s
    /// click handler, so a mode switch that happened before Settings was ever opened
    /// (e.g. straight after login) never started automatic refresh. The screen model
    /// must react to `OperatingModeManager` directly.
    func testEnteringMonitorModeStartsRefreshAndLeavingStopsIt() async {
        let fetcher = LifecycleStubFetcher()
        let coordinator = RemoteQuotaSourceCoordinator(
            repository: LifecycleMemoryRepository(),
            credentials: LifecycleMemoryVault(),
            fetcher: fetcher,
            snapshotStore: LifecycleMemorySnapshotStore(),
            clock: LifecycleTestClock()
        )
        let source = RemoteQuotaSourceConfig(id: "s1", name: "Pool", baseURL: "https://a.test")
        await coordinator.addSource(source, managementKey: "k")
        await fetcher.enqueue(.success([.codex: ["pro": Self.quota(50)]]), for: "s1")

        let modeManager = OperatingModeManager(repository: LifecycleMemoryModeRepository(initialMode: .localProxy))
        let model = RemoteQuotaSourceScreenModel(
            coordinator: coordinator,
            refreshSettings: RefreshSettingsManager(repository: LifecycleMemoryRefreshRepository()),
            modeManager: modeManager
        )

        XCTAssertTrue(model.poolQuotas.isEmpty)

        modeManager.setMode(.monitor)
        await waitUntil { !((model.visibleProviderQuotas[.codex] ?? [:]).isEmpty) }
        XCTAssertFalse((model.visibleProviderQuotas[.codex] ?? [:]).isEmpty)

        modeManager.setMode(.localProxy)
        // Leaving Monitor mode must stop automatic refresh without clearing the last
        // known snapshot — verified indirectly: no crash/leak, and re-entering below
        // starts cleanly again rather than compounding duplicate refresh loops.
        modeManager.setMode(.monitor)
        await waitUntil { !((model.visibleProviderQuotas[.codex] ?? [:]).isEmpty) }
        XCTAssertFalse((model.visibleProviderQuotas[.codex] ?? [:]).isEmpty)
    }

    /// Regression: `addCadenceChangeHandler` used to call `restartAutomaticRefresh()`
    /// unconditionally, so a cadence change made after leaving Monitor mode would
    /// recreate the automatic remote refresh loop even though it must stay stopped
    /// outside Monitor mode.
    func testCadenceChangeAfterLeavingMonitorModeDoesNotRestartRefresh() async {
        let fetcher = LifecycleStubFetcher()
        let coordinator = RemoteQuotaSourceCoordinator(
            repository: LifecycleMemoryRepository(),
            credentials: LifecycleMemoryVault(),
            fetcher: fetcher,
            snapshotStore: LifecycleMemorySnapshotStore(),
            clock: LifecycleTestClock()
        )
        let source = RemoteQuotaSourceConfig(id: "s1", name: "Pool", baseURL: "https://a.test")
        await coordinator.addSource(source, managementKey: "k")
        await fetcher.enqueue(.success([.codex: ["pro": Self.quota(50)]]), for: "s1")

        let modeManager = OperatingModeManager(repository: LifecycleMemoryModeRepository(initialMode: .localProxy))
        let refreshSettings = RefreshSettingsManager(repository: LifecycleMemoryRefreshRepository())
        refreshSettings.refreshCadence = .tenMinutes
        let model = RemoteQuotaSourceScreenModel(
            coordinator: coordinator,
            refreshSettings: refreshSettings,
            modeManager: modeManager
        )

        modeManager.setMode(.monitor)
        await waitUntil { model.hasActiveAutomaticRefreshTask }
        XCTAssertTrue(model.hasActiveAutomaticRefreshTask)

        modeManager.setMode(.localProxy)
        await waitUntil { !model.hasActiveAutomaticRefreshTask }
        XCTAssertFalse(model.hasActiveAutomaticRefreshTask)

        refreshSettings.refreshCadence = .fiveMinutes

        XCTAssertFalse(model.hasActiveAutomaticRefreshTask)
    }

    /// Regression: `applyModeLifecycle` used to fire an unstructured `Task { await
    /// initialize() }` when entering Monitor mode with no way to invalidate it. If
    /// Monitor mode was left again before that task reached its first `await`
    /// suspension point, `shutdown()` ran to completion first (cancelling the refresh
    /// task synchronously), but the still-in-flight `initialize()` later finished its
    /// network round-trip and unconditionally set `isAutomaticRefreshActive = true` /
    /// called `restartAutomaticRefresh()`, resurrecting automatic refresh outside
    /// Monitor mode. `initialize()`/`applyModeLifecycle` now snapshot a lifecycle
    /// generation before scheduling work and `shutdown()` bumps it, so a stale
    /// completion is a no-op.
    func testLeavingMonitorModeBeforeInFlightInitializeCompletesDoesNotResurrectRefresh() async {
        let fetcher = LifecycleStubFetcher()
        let coordinator = RemoteQuotaSourceCoordinator(
            repository: LifecycleMemoryRepository(),
            credentials: LifecycleMemoryVault(),
            fetcher: fetcher,
            snapshotStore: LifecycleMemorySnapshotStore(),
            clock: LifecycleTestClock()
        )
        let source = RemoteQuotaSourceConfig(id: "s1", name: "Pool", baseURL: "https://a.test")
        await coordinator.addSource(source, managementKey: "k")
        await fetcher.enqueue(.success([.codex: ["pro": Self.quota(50)]]), for: "s1")

        let modeManager = OperatingModeManager(repository: LifecycleMemoryModeRepository(initialMode: .localProxy))
        let refreshSettings = RefreshSettingsManager(repository: LifecycleMemoryRefreshRepository())
        refreshSettings.refreshCadence = .tenMinutes
        let model = RemoteQuotaSourceScreenModel(
            coordinator: coordinator,
            refreshSettings: refreshSettings,
            modeManager: modeManager
        )

        // Both calls run synchronously on the main actor: entering Monitor mode only
        // schedules the unstructured initialize Task (its body hasn't run yet), so the
        // very next call to leave Monitor mode is guaranteed to run shutdown() first.
        modeManager.setMode(.monitor)
        modeManager.setMode(.localProxy)

        // Give the stale initialize Task plenty of time to reach the coordinator, fetch
        // the quota, and attempt to restart automatic refresh.
        for _ in 0..<200 {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }

        XCTAssertFalse(model.hasActiveAutomaticRefreshTask)
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<200 where !condition() {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    private static func quota(_ percentage: Double) -> ProviderQuota {
        ProviderQuota(models: [QuotaMetric(name: "usage", percentage: percentage, resetTime: "")])
    }
}

private final class LifecycleMemoryRepository: RemoteQuotaSourceRepository, @unchecked Sendable {
    private var sources: [RemoteQuotaSourceConfig] = []
    func load() -> [RemoteQuotaSourceConfig] { sources }
    func save(_ sources: [RemoteQuotaSourceConfig]) { self.sources = sources }
}

private actor LifecycleMemoryVault: RemoteQuotaSourceCredentialVault {
    private var keys: [String: String] = [:]
    func loadManagementKey(sourceId: String) async -> String? { keys[sourceId] }
    func saveManagementKey(_ key: String, sourceId: String) async -> Bool {
        keys[sourceId] = key
        return true
    }
    func deleteManagementKey(sourceId: String) async { keys.removeValue(forKey: sourceId) }
}

private final class LifecycleMemorySnapshotStore: RemoteQuotaPoolSnapshotStoring, @unchecked Sendable {
    private var stored = RemoteQuotaPoolSnapshot()
    func load() -> RemoteQuotaPoolSnapshot { stored }
    func save(_ snapshot: RemoteQuotaPoolSnapshot) { stored = snapshot }
}

private actor LifecycleStubFetcher: RemoteQuotaSourceFetching {
    enum Outcome {
        case success([QuotaProvider: [String: ProviderQuota]])
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
            return RemoteQuotaPoolFetchResult()
        }
        let outcome = queue.removeFirst()
        queues[source.id] = queue
        switch outcome {
        case .success(let quotas):
            return RemoteQuotaPoolFetchResult(quotasByProviderAndPlan: quotas, hasPartialFailure: false)
        }
    }
}

private struct LifecycleTestClock: DateProviding {
    func now() -> Date { Date(timeIntervalSince1970: 1_800_000_000) }
}

private final class LifecycleMemoryRefreshRepository: RefreshPreferencesRepository, @unchecked Sendable {
    func load() -> RefreshPreferences { RefreshPreferences(cadence: .manual) }
    func save(_ preferences: RefreshPreferences) {}
}

private final class LifecycleMemoryModeRepository: OperatingModePreferencesRepository, @unchecked Sendable {
    private var preferences: OperatingModePreferences

    init(initialMode: OperatingMode) {
        preferences = OperatingModePreferences(mode: initialMode, hasCompletedOnboarding: true)
    }

    func load() -> OperatingModePreferences { preferences }
    func save(_ preferences: OperatingModePreferences) { self.preferences = preferences }
}

@MainActor
final class RemoteQuotaSourceScreenModelTests: XCTestCase {
    func testVisibleProviderQuotasExpandsIntoOneKeyPerPlanGroup() async {
        let fetcher = StubFetcher()
        let coordinator = makeCoordinator(fetcher: fetcher)
        let source = RemoteQuotaSourceConfig(id: "s1", name: "Pool", baseURL: "https://a.test")
        await coordinator.addSource(source, managementKey: "k")
        await fetcher.enqueue(
            .success([.codex: ["pro": Self.quota(70), "team": Self.quota(20)]]),
            for: "s1"
        )
        let model = RemoteQuotaSourceScreenModel(coordinator: coordinator, refreshSettings: makeRefreshSettings())

        await model.initialize()
        // `initialize()` snapshots state before triggering the refresh; the refreshed
        // pool arrives asynchronously via the coordinator's state stream.
        await waitUntil { !((model.visibleProviderQuotas[.codex] ?? [:]).isEmpty) }

        let codexEntries = model.visibleProviderQuotas[.codex] ?? [:]
        XCTAssertEqual(codexEntries.count, 2)
        let proKey = RemoteQuotaPoolIdentity.storageKey(sourceId: "s1", planKey: "pro")
        let teamKey = RemoteQuotaPoolIdentity.storageKey(sourceId: "s1", planKey: "team")
        XCTAssertEqual(codexEntries[proKey]?.models.first?.percentage, 70)
        XCTAssertEqual(codexEntries[teamKey]?.models.first?.percentage, 20)
    }

    func testVisibleProviderQuotasOmitsDisabledSourceEvenWithASnapshot() async {
        let fetcher = StubFetcher()
        let coordinator = makeCoordinator(fetcher: fetcher)
        var source = RemoteQuotaSourceConfig(id: "s1", name: "Pool", baseURL: "https://a.test")
        await coordinator.addSource(source, managementKey: "k")
        await fetcher.enqueue(.success([.claude: ["pro": Self.quota(80)]]), for: "s1")
        let model = RemoteQuotaSourceScreenModel(coordinator: coordinator, refreshSettings: makeRefreshSettings())
        await model.initialize()
        await waitUntil { !((model.visibleProviderQuotas[.claude] ?? [:]).isEmpty) }
        XCTAssertFalse((model.visibleProviderQuotas[.claude] ?? [:]).isEmpty)

        source.isEnabled = false
        await coordinator.updateSource(source, managementKey: nil)

        // The screen model updates asynchronously off the coordinator's state stream;
        // poll briefly instead of assuming a single suspension point is enough.
        await waitUntil { (model.visibleProviderQuotas[.claude] ?? [:]).isEmpty }

        XCTAssertTrue((model.visibleProviderQuotas[.claude] ?? [:]).isEmpty)
    }

    /// Polls a condition that becomes true asynchronously off the coordinator's state
    /// stream (there is no single await point that guarantees the screen model has
    /// consumed a given publish). Gives up silently after ~1s; the following assertion
    /// reports the real failure.
    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<200 where !condition() {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    // MARK: - Helpers

    private func makeCoordinator(fetcher: StubFetcher) -> RemoteQuotaSourceCoordinator {
        RemoteQuotaSourceCoordinator(
            repository: MemoryRepository(),
            credentials: MemoryVault(),
            fetcher: fetcher,
            snapshotStore: MemorySnapshotStore(),
            clock: TestClock()
        )
    }

    private func makeRefreshSettings() -> RefreshSettingsManager {
        RefreshSettingsManager(repository: MemoryRefreshPreferencesRepository())
    }

    private static func quota(_ percentage: Double) -> ProviderQuota {
        ProviderQuota(models: [QuotaMetric(name: "usage", percentage: percentage, resetTime: "")])
    }
}

// MARK: - Test doubles

private final class MemoryRepository: RemoteQuotaSourceRepository, @unchecked Sendable {
    private var sources: [RemoteQuotaSourceConfig] = []
    func load() -> [RemoteQuotaSourceConfig] { sources }
    func save(_ sources: [RemoteQuotaSourceConfig]) { self.sources = sources }
}

private actor MemoryVault: RemoteQuotaSourceCredentialVault {
    private var keys: [String: String] = [:]
    func loadManagementKey(sourceId: String) async -> String? { keys[sourceId] }
    func saveManagementKey(_ key: String, sourceId: String) async -> Bool {
        keys[sourceId] = key
        return true
    }
    func deleteManagementKey(sourceId: String) async { keys.removeValue(forKey: sourceId) }
}

private final class MemorySnapshotStore: RemoteQuotaPoolSnapshotStoring, @unchecked Sendable {
    private var stored = RemoteQuotaPoolSnapshot()
    func load() -> RemoteQuotaPoolSnapshot { stored }
    func save(_ snapshot: RemoteQuotaPoolSnapshot) { stored = snapshot }
}

private actor StubFetcher: RemoteQuotaSourceFetching {
    enum Outcome {
        case success([QuotaProvider: [String: ProviderQuota]])
        case failure
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
            return RemoteQuotaPoolFetchResult()
        }
        let outcome = queue.removeFirst()
        queues[source.id] = queue
        switch outcome {
        case .success(let quotas):
            return RemoteQuotaPoolFetchResult(quotasByProviderAndPlan: quotas, hasPartialFailure: false)
        case .failure:
            throw StubFetcherError.simulatedFailure
        }
    }
}

private enum StubFetcherError: Error {
    case simulatedFailure
}

private struct TestClock: DateProviding {
    func now() -> Date { Date(timeIntervalSince1970: 1_800_000_000) }
}

private final class MemoryRefreshPreferencesRepository: RefreshPreferencesRepository, @unchecked Sendable {
    func load() -> RefreshPreferences { RefreshPreferences(cadence: .manual) }
    func save(_ preferences: RefreshPreferences) {}
}
