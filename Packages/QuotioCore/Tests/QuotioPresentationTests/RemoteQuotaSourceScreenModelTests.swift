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
            return RemoteQuotaPoolFetchResult(quotasByProviderAndAccount: quotas, outcome: .complete)
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
    /// Regression: this used to expand into one key per **plan group** (an aggregate
    /// masquerading as an account); it must now expose each real remote account under
    /// its own key with its own untouched reading — never merged/aggregated together.
    func testVisibleProviderQuotasExpandsIntoOneKeyPerRealRemoteAccount() async {
        let fetcher = StubFetcher()
        let coordinator = makeCoordinator(fetcher: fetcher)
        let source = RemoteQuotaSourceConfig(id: "s1", name: "Pool", baseURL: "https://a.test")
        await coordinator.addSource(source, managementKey: "k")
        await fetcher.enqueue(
            .success([.codex: ["codex-a": Self.quota(70), "codex-b": Self.quota(20)]]),
            for: "s1"
        )
        let model = RemoteQuotaSourceScreenModel(coordinator: coordinator, refreshSettings: makeRefreshSettings())

        await model.initialize()
        // `initialize()` snapshots state before triggering the refresh; the refreshed
        // pool arrives asynchronously via the coordinator's state stream.
        await waitUntil { !((model.visibleProviderQuotas[.codex] ?? [:]).isEmpty) }

        let codexEntries = model.visibleProviderQuotas[.codex] ?? [:]
        XCTAssertEqual(codexEntries.count, 2)
        let accountAKey = RemoteQuotaAccountIdentity.storageKey(sourceId: "s1", accountKey: "codex-a")
        let accountBKey = RemoteQuotaAccountIdentity.storageKey(sourceId: "s1", accountKey: "codex-b")
        XCTAssertEqual(codexEntries[accountAKey]?.models.first?.percentage, 70)
        XCTAssertEqual(codexEntries[accountBKey]?.models.first?.percentage, 20)
    }

    /// Two different remote sources both surfacing an account under the same raw key
    /// (e.g. the same email) must never collide in `visibleProviderQuotas` — this is
    /// the exact scenario `RemoteQuotaAccountIdentity`'s composite key exists to prevent.
    func testVisibleProviderQuotasIsolatesSameRawAccountKeyAcrossDifferentSources() async {
        let fetcher = StubFetcher()
        let coordinator = makeCoordinator(fetcher: fetcher)
        let sourceA = RemoteQuotaSourceConfig(id: "src-a", name: "A", baseURL: "https://a.test")
        let sourceB = RemoteQuotaSourceConfig(id: "src-b", name: "B", baseURL: "https://b.test")
        await coordinator.addSource(sourceA, managementKey: "k")
        await coordinator.addSource(sourceB, managementKey: "k")
        await fetcher.enqueue(.success([.claude: ["same@example.com": Self.quota(70)]]), for: "src-a")
        await fetcher.enqueue(.success([.claude: ["same@example.com": Self.quota(20)]]), for: "src-b")
        let model = RemoteQuotaSourceScreenModel(coordinator: coordinator, refreshSettings: makeRefreshSettings())

        await model.initialize()
        await waitUntil { (model.visibleProviderQuotas[.claude] ?? [:]).count >= 2 }

        let claudeEntries = model.visibleProviderQuotas[.claude] ?? [:]
        XCTAssertEqual(claudeEntries.count, 2)
        let keyA = RemoteQuotaAccountIdentity.storageKey(sourceId: "src-a", accountKey: "same@example.com")
        let keyB = RemoteQuotaAccountIdentity.storageKey(sourceId: "src-b", accountKey: "same@example.com")
        XCTAssertEqual(claudeEntries[keyA]?.models.first?.percentage, 70)
        XCTAssertEqual(claudeEntries[keyB]?.models.first?.percentage, 20)
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

    /// A provider-scoped refresh (the Quota screen's per-provider button and the menu
    /// bar's provider header) has to reach that provider's remote accounts too, without
    /// dragging in sources that carry an unrelated provider.
    func testProviderScopedRefreshHitsOnlySourcesCarryingThatProvider() async {
        let fetcher = StubFetcher()
        let coordinator = makeCoordinator(fetcher: fetcher)
        await coordinator.addSource(
            RemoteQuotaSourceConfig(id: "codex-src", name: "A", baseURL: "https://a.test"),
            managementKey: "k"
        )
        await coordinator.addSource(
            RemoteQuotaSourceConfig(id: "claude-src", name: "B", baseURL: "https://b.test"),
            managementKey: "k"
        )
        await fetcher.enqueue(.success([.codex: ["a": Self.quota(70)]]), for: "codex-src")
        await fetcher.enqueue(.success([.claude: ["b": Self.quota(30)]]), for: "claude-src")
        let model = RemoteQuotaSourceScreenModel(coordinator: coordinator, refreshSettings: makeRefreshSettings())
        await model.initialize()
        await waitUntil { model.hasVisibleAccounts(provider: .claude) }

        XCTAssertTrue(model.hasVisibleAccounts(provider: .codex))
        XCTAssertTrue(model.hasVisibleAccounts(provider: .claude))
        XCTAssertFalse(model.hasVisibleAccounts(provider: .grok))

        await fetcher.resetFetchLog()
        await model.refresh(provider: .codex)

        let fetched = await fetcher.fetchedSourceIds
        XCTAssertEqual(fetched, ["codex-src"])
    }

    /// A source with no accounts for the provider (or none at all) offers no remote
    /// work, so the caller can fall back to whatever the local side supports instead of
    /// showing a refresh action that would do nothing.
    func testHasVisibleAccountsIsFalseWhenNoSourceCarriesTheProvider() async {
        let fetcher = StubFetcher()
        let coordinator = makeCoordinator(fetcher: fetcher)
        await coordinator.addSource(
            RemoteQuotaSourceConfig(id: "s1", name: "Pool", baseURL: "https://a.test"),
            managementKey: "k"
        )
        let model = RemoteQuotaSourceScreenModel(coordinator: coordinator, refreshSettings: makeRefreshSettings())
        await model.initialize()

        XCTAssertFalse(model.hasVisibleAccounts(provider: .codex))

        await fetcher.resetFetchLog()
        await model.refresh(provider: .codex)
        let fetched = await fetcher.fetchedSourceIds
        XCTAssertTrue(fetched.isEmpty)
    }

    // MARK: - planAggregates

    /// Two accounts sharing a normalized plan key produce exactly one aggregate row,
    /// keyed with `RemoteQuotaAggregateIdentity`, combining their readings via the
    /// requested mode — while `visibleProviderQuotas` keeps both real accounts untouched.
    func testPlanAggregatesCombinesAccountsSharingANormalizedPlanKey() async {
        let fetcher = StubFetcher()
        let coordinator = makeCoordinator(fetcher: fetcher)
        let source = RemoteQuotaSourceConfig(id: "s1", name: "Pool", baseURL: "https://a.test")
        await coordinator.addSource(source, managementKey: "k")
        await fetcher.enqueue(
            .success([.claude: [
                "a": Self.quota(80, plan: "Pro"),
                "b": Self.quota(20, plan: "Pro 20x"),
            ]]),
            for: "s1"
        )
        let model = RemoteQuotaSourceScreenModel(coordinator: coordinator, refreshSettings: makeRefreshSettings())
        await model.initialize()
        await waitUntil { (model.visibleProviderQuotas[.claude] ?? [:]).count == 2 }

        let aggregates = model.planAggregates(mode: .lowest)
        let key = RemoteQuotaAggregateIdentity.storageKey(sourceId: "s1", planKey: "pro")
        let aggregate = aggregates[.claude]?[key]

        XCTAssertEqual(aggregate?.accountCount, 2)
        XCTAssertEqual(aggregate?.quota.models.first?.percentage, 20)
        // Both real accounts must still be present and untouched.
        XCTAssertEqual((model.visibleProviderQuotas[.claude] ?? [:]).count, 2)
    }

    /// A plan group with exactly one account still produces its own aggregate row — a
    /// single-account plan (e.g. one Claude Pro account) is exactly the summary users
    /// expect to see, not just a group that happens to have two or more members.
    func testPlanAggregatesIncludesSingleAccountGroups() async {
        let fetcher = StubFetcher()
        let coordinator = makeCoordinator(fetcher: fetcher)
        let source = RemoteQuotaSourceConfig(id: "s1", name: "Pool", baseURL: "https://a.test")
        await coordinator.addSource(source, managementKey: "k")
        await fetcher.enqueue(.success([.claude: ["a": Self.quota(80, plan: "Pro")]]), for: "s1")
        let model = RemoteQuotaSourceScreenModel(coordinator: coordinator, refreshSettings: makeRefreshSettings())
        await model.initialize()
        await waitUntil { !((model.visibleProviderQuotas[.claude] ?? [:]).isEmpty) }

        let aggregates = model.planAggregates(mode: .lowest)[.claude] ?? [:]
        let key = RemoteQuotaAggregateIdentity.storageKey(sourceId: "s1", planKey: "pro")
        XCTAssertEqual(aggregates[key]?.accountCount, 1)
        XCTAssertEqual(aggregates[key]?.quota.models.first?.percentage, 80)
    }

    /// Regression: the aggregate identity (`RemoteQuotaAggregateIdentity.storageKey`,
    /// derived from source + plan key only) must stay exactly the same as the group's
    /// account count changes — 1 account, then 2, then back down to 1 — so a menu bar
    /// pin targeting this aggregate never silently disappears or gets replaced just
    /// because a second account joined and later left the same plan.
    func testPlanAggregateIdentityIsStableAsAccountCountChanges() async {
        let fetcher = StubFetcher()
        let coordinator = makeCoordinator(fetcher: fetcher)
        let source = RemoteQuotaSourceConfig(id: "s1", name: "Pool", baseURL: "https://a.test")
        await coordinator.addSource(source, managementKey: "k")
        let model = RemoteQuotaSourceScreenModel(coordinator: coordinator, refreshSettings: makeRefreshSettings())
        let key = RemoteQuotaAggregateIdentity.storageKey(sourceId: "s1", planKey: "pro")

        // 1 account.
        await fetcher.enqueue(.success([.claude: ["a": Self.quota(80, plan: "Pro")]]), for: "s1")
        await model.initialize()
        await waitUntil { (model.visibleProviderQuotas[.claude] ?? [:]).count == 1 }
        XCTAssertEqual(model.planAggregates(mode: .lowest)[.claude]?[key]?.accountCount, 1)

        // Grows to 2 accounts on the same plan — same key, updated count.
        await fetcher.enqueue(
            .success([.claude: [
                "a": Self.quota(80, plan: "Pro"),
                "b": Self.quota(40, plan: "Pro"),
            ]]),
            for: "s1"
        )
        await model.refresh(sourceId: "s1")
        await waitUntil { (model.visibleProviderQuotas[.claude] ?? [:]).count == 2 }
        XCTAssertEqual(model.planAggregates(mode: .lowest)[.claude]?[key]?.accountCount, 2)

        // Shrinks back to 1 account — the aggregate must still exist under the exact
        // same key, not vanish and reappear as a different identity.
        await fetcher.enqueue(.success([.claude: ["a": Self.quota(80, plan: "Pro")]]), for: "s1")
        await model.refresh(sourceId: "s1")
        await waitUntil { (model.visibleProviderQuotas[.claude] ?? [:]).count == 1 }
        XCTAssertEqual(model.planAggregates(mode: .lowest)[.claude]?[key]?.accountCount, 1)
    }

    /// Accounts on different plans within the same source/provider never merge together.
    func testPlanAggregatesKeepsDifferentPlansSeparate() async {
        let fetcher = StubFetcher()
        let coordinator = makeCoordinator(fetcher: fetcher)
        let source = RemoteQuotaSourceConfig(id: "s1", name: "Pool", baseURL: "https://a.test")
        await coordinator.addSource(source, managementKey: "k")
        await fetcher.enqueue(
            .success([.claude: [
                "a": Self.quota(80, plan: "Pro"),
                "b": Self.quota(20, plan: "Team"),
                "c": Self.quota(50, plan: "Pro"),
            ]]),
            for: "s1"
        )
        let model = RemoteQuotaSourceScreenModel(coordinator: coordinator, refreshSettings: makeRefreshSettings())
        await model.initialize()
        await waitUntil { (model.visibleProviderQuotas[.claude] ?? [:]).count == 3 }

        let aggregates = model.planAggregates(mode: .lowest)[.claude] ?? [:]
        // Both plan groups get their own aggregate — "Team" has one account, "Pro" has
        // two — but they must never merge into each other.
        XCTAssertEqual(aggregates.count, 2)
        let proKey = RemoteQuotaAggregateIdentity.storageKey(sourceId: "s1", planKey: "pro")
        let teamKey = RemoteQuotaAggregateIdentity.storageKey(sourceId: "s1", planKey: "team")
        XCTAssertEqual(aggregates[proKey]?.accountCount, 2)
        XCTAssertEqual(aggregates[teamKey]?.accountCount, 1)
    }

    /// A source hidden past the automatic-failure threshold must not contribute an
    /// aggregate either — the same visibility rule `visibleProviderQuotas` already
    /// applies to real accounts.
    func testPlanAggregatesOmitsDisabledSource() async {
        let fetcher = StubFetcher()
        let coordinator = makeCoordinator(fetcher: fetcher)
        var source = RemoteQuotaSourceConfig(id: "s1", name: "Pool", baseURL: "https://a.test")
        await coordinator.addSource(source, managementKey: "k")
        await fetcher.enqueue(
            .success([.claude: ["a": Self.quota(80, plan: "Pro"), "b": Self.quota(20, plan: "Pro")]]),
            for: "s1"
        )
        let model = RemoteQuotaSourceScreenModel(coordinator: coordinator, refreshSettings: makeRefreshSettings())
        await model.initialize()
        await waitUntil { !(model.planAggregates(mode: .lowest)[.claude] ?? [:]).isEmpty }

        source.isEnabled = false
        await coordinator.updateSource(source, managementKey: nil)
        await waitUntil { (model.visibleProviderQuotas[.claude] ?? [:]).isEmpty }

        XCTAssertTrue((model.planAggregates(mode: .lowest)[.claude] ?? [:]).isEmpty)
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

    private static func quota(_ percentage: Double, plan: String? = nil) -> ProviderQuota {
        ProviderQuota(models: [QuotaMetric(name: "usage", percentage: percentage, resetTime: "")], planType: plan)
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
    /// Source ids in fetch order, so a provider-scoped refresh can be checked for
    /// reaching exactly the sources that carry that provider.
    private(set) var fetchedSourceIds: [String] = []

    func enqueue(_ outcome: Outcome, for sourceId: String) {
        queues[sourceId, default: []].append(outcome)
    }

    func resetFetchLog() {
        fetchedSourceIds = []
    }

    func isResponding(_ source: RemoteQuotaSourceConfig, managementKey: String) async -> Bool { true }

    func fetchPool(
        _ source: RemoteQuotaSourceConfig,
        managementKey: String
    ) async throws -> RemoteQuotaPoolFetchResult {
        fetchedSourceIds.append(source.id)
        guard var queue = queues[source.id], !queue.isEmpty else {
            return RemoteQuotaPoolFetchResult()
        }
        let outcome = queue.removeFirst()
        queues[source.id] = queue
        switch outcome {
        case .success(let quotas):
            // `.success` represents a fully authoritative listing round, so every
            // account key handed to `enqueue` is this round's complete roster —
            // otherwise the coordinator treats an omitted provider as "the listing
            // said nothing about it" and keeps stale accounts around forever
            // (see `RemoteQuotaPoolFetchResult.knownAccountKeys`).
            let knownAccountKeys = quotas.mapValues { Set($0.keys) }
            return RemoteQuotaPoolFetchResult(
                quotasByProviderAndAccount: quotas,
                outcome: .complete,
                knownAccountKeys: knownAccountKeys
            )
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
