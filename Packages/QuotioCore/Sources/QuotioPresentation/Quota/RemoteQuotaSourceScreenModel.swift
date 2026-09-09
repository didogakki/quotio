import Foundation
import Observation
import QuotioApplication
import QuotioDomain

/// A derived, read-only summary of every real remote account sharing one source,
/// provider, and normalized plan key (`QuotaPolicy.normalizedPlanKey`). Never persisted
/// and never merged into `visibleProviderQuotas` — the real accounts it summarizes stay
/// exactly as they were, so fetch/refresh/local+remote merge are entirely unaffected by
/// its existence.
public struct RemoteQuotaPlanAggregate: Equatable, Sendable {
    public let quota: ProviderQuota
    public let accountCount: Int
}

@MainActor
@Observable
public final class RemoteQuotaSourceScreenModel {
    @ObservationIgnored private let coordinator: RemoteQuotaSourceCoordinator
    @ObservationIgnored private let refreshSettings: RefreshSettingsManager
    /// Fed the latest visible real remote accounts after every sync, purely so it can
    /// tell whether a legacy pool pin still covers a real account (see
    /// `MenuBarSettingsManager.syncKnownRemoteAccountItems`). Optional so existing tests
    /// that construct this model without a menu bar dependency keep working unchanged.
    @ObservationIgnored private let menuBarSettings: MenuBarSettingsManager?
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
        modeManager: OperatingModeManager? = nil,
        menuBarSettings: MenuBarSettingsManager? = nil
    ) {
        self.coordinator = coordinator
        self.refreshSettings = refreshSettings
        self.menuBarSettings = menuBarSettings
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

    /// Remote quotas reshaped to match `QuotaScreenModel.providerQuotas`
    /// (`[QuotaProvider: [String: ProviderQuota]]`), keyed with
    /// `RemoteQuotaAccountIdentity.storageKey(sourceId:accountKey:)` so callers can merge
    /// by dictionary union without colliding with local account keys, other sources'
    /// accounts, or another remote account that happens to share a raw key/email. Each
    /// entry is one real remote account's own quota — never a plan-level aggregate — and
    /// keeps whatever `accountDisplayName` the fetcher assigned it (the account's own
    /// email/name), so identity is never replaced by the source's name. Sources that are
    /// disabled or past the automatic-failure threshold are omitted until they recover.
    public var visibleProviderQuotas: [QuotaProvider: [String: ProviderQuota]] {
        var result: [QuotaProvider: [String: ProviderQuota]] = [:]
        for (sourceId, byProvider) in poolQuotas where isVisible(sourceId: sourceId) {
            for (provider, byAccount) in byProvider {
                for (accountKey, quota) in byAccount {
                    let key = RemoteQuotaAccountIdentity.storageKey(sourceId: sourceId, accountKey: accountKey)
                    result[provider, default: [:]][key] = quota
                }
            }
        }
        return result
    }

    /// One derived summary row per (visible source, provider, normalized plan key) that
    /// currently has **at least one** real account — including a group of exactly one,
    /// so a single-account plan (e.g. one Claude Pro account) still gets the summary row
    /// users expect instead of it only appearing once a second account joins the same
    /// plan. Keyed with `RemoteQuotaAggregateIdentity.storageKey(sourceId:planKey:)`,
    /// which depends only on the source and plan — never the account count — so a pin
    /// targeting this row survives the group shrinking from two accounts back down to
    /// one (or growing from one to several) without its identity ever changing. Never
    /// collides with a real account's `acct::`-prefixed key or a legacy `__pool__` pin.
    /// `mode` is threaded in rather than stored, since aggregation reuses whatever
    /// `ModelAggregationMode` the menu bar already uses for combining a single account's
    /// own metrics — no new aggregation concept, just applied across accounts too.
    public func planAggregates(mode: ModelAggregationMode) -> [QuotaProvider: [String: RemoteQuotaPlanAggregate]] {
        var result: [QuotaProvider: [String: RemoteQuotaPlanAggregate]] = [:]
        for (sourceId, byProvider) in poolQuotas where isVisible(sourceId: sourceId) {
            for (provider, byAccount) in byProvider {
                var groups: [String: [ProviderQuota]] = [:]
                for quota in byAccount.values {
                    groups[QuotaPolicy.normalizedPlanKey(quota.planType), default: []].append(quota)
                }
                for (planKey, quotas) in groups {
                    let key = RemoteQuotaAggregateIdentity.storageKey(sourceId: sourceId, planKey: planKey)
                    result[provider, default: [:]][key] = RemoteQuotaPlanAggregate(
                        quota: QuotaPolicy.aggregate(quotas, mode: mode),
                        accountCount: quotas.count
                    )
                }
            }
        }
        return result
    }

    /// Every real remote account currently visible, expressed as the exact
    /// `MenuBarQuotaItem` `AccountRowData.menuBarItem` would build for it — keyed by its
    /// `RemoteQuotaAccountIdentity` storage key and this source's id. Fed to
    /// `MenuBarSettingsManager` after every sync (see `sync(_:)`) so it can tell whether
    /// a legacy pool pin still covers a real account; never itself persisted or a pin.
    private var visibleAccountMenuBarItems: [MenuBarQuotaItem] {
        visibleProviderQuotas.flatMap { provider, byKey in
            byKey.keys.compactMap { storageKey -> MenuBarQuotaItem? in
                guard let components = RemoteQuotaAccountIdentity.components(fromStorageKey: storageKey) else {
                    return nil
                }
                return MenuBarQuotaItem(
                    provider: provider.rawValue,
                    accountKey: storageKey,
                    sourceConfigId: components.sourceId
                )
            }
        }
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

    /// Whether any currently-visible source contributes at least one account for
    /// `provider` — i.e. whether a provider-scoped refresh has any remote work to do,
    /// and whether the provider's rows can be refreshed at all when the local side
    /// doesn't support scoped refresh.
    public func hasVisibleAccounts(provider: QuotaProvider) -> Bool {
        sources.contains { source in
            isVisible(sourceId: source.id) && poolQuotas[source.id]?[provider]?.isEmpty == false
        }
    }

    public func refresh(sourceId: String) async {
        await coordinator.refresh(sourceId: sourceId, isAutomatic: false)
    }

    /// Refreshes only the visible sources that currently expose an account for
    /// `provider`. A provider-scoped refresh must still reach that provider's remote
    /// accounts, without dragging in unrelated sources the way `refreshAll` would.
    public func refresh(provider: QuotaProvider) async {
        for source in sources
        where isVisible(sourceId: source.id) && poolQuotas[source.id]?[provider]?.isEmpty == false {
            await refresh(sourceId: source.id)
        }
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
        menuBarSettings?.syncKnownRemoteAccountItems(visibleAccountMenuBarItems)
        didChangeHandler?()
    }
}
