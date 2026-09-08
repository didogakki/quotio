import Foundation
import Observation
import QuotioApplication
import QuotioDomain

@MainActor
@Observable
public final class RemoteQuotaSourceScreenModel {
    @ObservationIgnored private let coordinator: RemoteQuotaSourceCoordinator
    @ObservationIgnored private let refreshSettings: RefreshSettingsManager
    @ObservationIgnored private var observationTask: Task<Void, Never>?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var didChangeHandler: (@MainActor () -> Void)?
    @ObservationIgnored private var isLifecycleActive: Bool
    @ObservationIgnored private var isAutomaticRefreshActive = false
    @ObservationIgnored private var lifecycleGeneration = 0

    public private(set) var sources: [RemoteQuotaSourceConfig] = []
    public private(set) var statuses: [String: RemoteQuotaSourceConnectionStatus] = [:]
    public private(set) var poolQuotas: [String: [QuotaProvider: [String: ProviderQuota]]] = [:]
    public private(set) var failureCounts: [String: Int] = [:]
    public private(set) var isRefreshing = false

    /// `modeManager`, when supplied, makes this screen model own its own start/stop
    /// lifecycle: it registers a persistent handler (via `addDidChangeHandler`, so it
    /// never collides with the status bar's separate `setDidChangeHandler` slot) that
    /// starts automatic refresh on entering Monitor mode and stops it on leaving —
    /// effective the moment the mode changes, regardless of whether Settings is open or
    /// the app was launched headless. Callers are still responsible for the initial
    /// `initialize()` call at startup when already launching into Monitor mode; this
    /// hook only reacts to subsequent transitions.
    public init(
        coordinator: RemoteQuotaSourceCoordinator,
        refreshSettings: RefreshSettingsManager,
        modeManager: OperatingModeManager? = nil
    ) {
        self.coordinator = coordinator
        self.refreshSettings = refreshSettings
        self.isLifecycleActive = modeManager?.isMonitorMode ?? false
        observe()
        refreshSettings.addCadenceChangeHandler { [weak self] _ in
            guard let self, self.isAutomaticRefreshActive else { return }
            self.restartAutomaticRefresh()
        }
        if let modeManager {
            modeManager.addDidChangeHandler { [weak self] preferences in
                self?.applyModeLifecycle(isMonitor: preferences.mode == .monitor)
            }
        }
    }

    deinit {
        observationTask?.cancel()
        refreshTask?.cancel()
    }

    public func isVisible(sourceId: String) -> Bool {
        guard sources.first(where: { $0.id == sourceId })?.isEnabled == true else { return false }
        return (failureCounts[sourceId] ?? 0) < RemoteQuotaSourceCoordinator.failureThreshold
    }

    /// Pooled remote quotas reshaped to match `QuotaScreenModel.providerQuotas`
    /// (`[QuotaProvider: [String: ProviderQuota]]`), keyed with
    /// `RemoteQuotaPoolIdentity.storageKey(sourceId:planKey:)` so callers can merge by
    /// dictionary union without colliding with local account keys, other sources'
    /// pools, or other plan groups within the same source/provider. Sources that are
    /// disabled or past the automatic-failure threshold are omitted until they recover.
    public var visibleProviderQuotas: [QuotaProvider: [String: ProviderQuota]] {
        var result: [QuotaProvider: [String: ProviderQuota]] = [:]
        let names = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0.name) })
        for (sourceId, byProvider) in poolQuotas where isVisible(sourceId: sourceId) {
            for (provider, byPlan) in byProvider {
                for (planKey, quota) in byPlan {
                    var quota = quota
                    quota.accountDisplayName = names[sourceId] ?? quota.accountDisplayName
                    let key = RemoteQuotaPoolIdentity.storageKey(sourceId: sourceId, planKey: planKey)
                    result[provider, default: [:]][key] = quota
                }
            }
        }
        return result
    }

    public func setDidChangeHandler(_ handler: (@MainActor () -> Void)?) {
        didChangeHandler = handler
    }

    /// Exposes whether the automatic-refresh loop is currently scheduled, for
    /// regression coverage of the Monitor-mode lifecycle without reaching into
    /// private state. Not part of the public API surface consumed outside tests.
    var hasActiveAutomaticRefreshTask: Bool { refreshTask != nil }

    public func initialize() async {
        await performInitialize(generation: lifecycleGeneration)
    }

    public func shutdown() {
        lifecycleGeneration += 1
        isAutomaticRefreshActive = false
        refreshTask?.cancel()
        refreshTask = nil
    }

    /// Runs the initial sync/refresh, then restarts automatic refresh only if
    /// `generation` still matches the current lifecycle generation. `shutdown()`
    /// bumps the generation, so an `initialize()` that was already in flight when
    /// Monitor mode was left (started via the unstructured `Task` in
    /// `applyModeLifecycle`) finishes its network work but can no longer resurrect
    /// automatic refresh after the fact.
    private func performInitialize(generation: Int) async {
        sync(await coordinator.state)
        await refreshAll(isAutomatic: false)
        guard generation == lifecycleGeneration else { return }
        isAutomaticRefreshActive = true
        restartAutomaticRefresh()
    }

    @discardableResult
    public func addSource(_ source: RemoteQuotaSourceConfig, managementKey: String) async -> Bool {
        guard await coordinator.addSource(source, managementKey: managementKey) else { return false }
        await refresh(sourceId: source.id)
        return true
    }

    @discardableResult
    public func updateSource(_ source: RemoteQuotaSourceConfig, managementKey: String?) async -> Bool {
        guard await coordinator.updateSource(source, managementKey: managementKey) else { return false }
        await refresh(sourceId: source.id)
        return true
    }

    public func removeSource(_ sourceId: String) async {
        await coordinator.removeSource(sourceId)
    }

    @discardableResult
    public func testConnection(_ sourceId: String) async -> Bool {
        await coordinator.testConnection(sourceId)
    }

    public func refresh(sourceId: String) async {
        await coordinator.refresh(sourceId: sourceId, isAutomatic: false)
    }

    public func refreshAll(isAutomatic: Bool = false) async {
        isRefreshing = true
        await coordinator.refreshAll(isAutomatic: isAutomatic)
        isRefreshing = false
    }

    private func applyModeLifecycle(isMonitor: Bool) {
        guard isMonitor != isLifecycleActive else { return }
        isLifecycleActive = isMonitor
        if isMonitor {
            let generation = lifecycleGeneration
            Task { [weak self] in
                await self?.performInitialize(generation: generation)
            }
        } else {
            shutdown()
        }
    }

    private func restartAutomaticRefresh() {
        refreshTask?.cancel()
        guard let interval = refreshSettings.refreshCadence.intervalNanoseconds else {
            refreshTask = nil
            return
        }
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: interval)
                guard !Task.isCancelled else { return }
                await self?.refreshAll(isAutomatic: true)
            }
        }
    }

    private func observe() {
        let coordinator = coordinator
        observationTask = Task { [weak self] in
            let states = await coordinator.states()
            for await state in states {
                guard !Task.isCancelled, let self else { return }
                self.sync(state)
            }
        }
    }

    private func sync(_ state: RemoteQuotaSourceCoordinator.State) {
        sources = state.sources
        statuses = state.statuses
        poolQuotas = state.poolQuotas
        failureCounts = state.failureCounts
        didChangeHandler?()
    }
}
