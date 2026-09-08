import Foundation
import QuotioDomain

/// Owns CRUD, connectivity testing, and periodic refresh for the user's remote
/// (read-only) quota sources. Deliberately independent of `QuotaRefreshCoordinator`:
/// local and remote quota data are merged only at presentation time, so a remote
/// refresh can never race with — or clobber — a concurrent local refresh.
public actor RemoteQuotaSourceCoordinator {
    /// Consecutive **automatic** refresh failures at which a source's pool is hidden
    /// from the menu bar until it succeeds again. Matches the legacy monitor behavior.
    public static let failureThreshold = 3

    public struct State: Equatable, Sendable {
        public var sources: [RemoteQuotaSourceConfig]
        public var statuses: [String: RemoteQuotaSourceConnectionStatus]
        /// sourceId -> provider -> normalized plan key -> aggregated pool quota.
        public var poolQuotas: [String: [QuotaProvider: [String: ProviderQuota]]]
        public var failureCounts: [String: Int]
        public var lastUpdated: [String: Date]

        public init(
            sources: [RemoteQuotaSourceConfig] = [],
            statuses: [String: RemoteQuotaSourceConnectionStatus] = [:],
            poolQuotas: [String: [QuotaProvider: [String: ProviderQuota]]] = [:],
            failureCounts: [String: Int] = [:],
            lastUpdated: [String: Date] = [:]
        ) {
            self.sources = sources
            self.statuses = statuses
            self.poolQuotas = poolQuotas
            self.failureCounts = failureCounts
            self.lastUpdated = lastUpdated
        }

        /// A source is visible when it's enabled and hasn't exceeded the automatic
        /// consecutive-failure threshold. Disabled sources never surface stale pools.
        public func isVisible(sourceId: String) -> Bool {
            guard sources.first(where: { $0.id == sourceId })?.isEnabled == true else { return false }
            return (failureCounts[sourceId] ?? 0) < RemoteQuotaSourceCoordinator.failureThreshold
        }
    }

    private let repository: any RemoteQuotaSourceRepository
    private let credentials: any RemoteQuotaSourceCredentialVault
    private let fetcher: any RemoteQuotaSourceFetching
    private let snapshotStore: any RemoteQuotaPoolSnapshotStoring
    private let clock: any DateProviding

    private var continuations: [UUID: AsyncStream<State>.Continuation] = [:]
    public private(set) var state: State

    public init(
        repository: any RemoteQuotaSourceRepository,
        credentials: any RemoteQuotaSourceCredentialVault,
        fetcher: any RemoteQuotaSourceFetching,
        snapshotStore: any RemoteQuotaPoolSnapshotStoring,
        clock: any DateProviding
    ) {
        self.repository = repository
        self.credentials = credentials
        self.fetcher = fetcher
        self.snapshotStore = snapshotStore
        self.clock = clock
        let sources = repository.load()
        state = State(sources: sources, poolQuotas: snapshotStore.load().quotasBySource)
    }

    public func states() -> AsyncStream<State> {
        let id = UUID()
        return AsyncStream { continuation in
            continuation.yield(state)
            continuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeContinuation(id) }
            }
        }
    }

    /// Returns `false` (without adding the source) if the management key could not be
    /// saved to the credential vault — a source must never be created if its key is
    /// unreachable, since it would silently sit there failing every refresh.
    @discardableResult
    public func addSource(_ source: RemoteQuotaSourceConfig, managementKey: String) async -> Bool {
        guard await credentials.saveManagementKey(managementKey, sourceId: source.id) else {
            state.statuses[source.id] = .error(RemoteQuotaSourceFailure.credentialSaveFailed.localizationKey)
            publish()
            return false
        }
        var sources = state.sources
        sources.removeAll { $0.id == source.id }
        sources.append(source)
        state.sources = sources
        repository.save(sources)
        publish()
        return true
    }

    /// `managementKey` is nil to keep the previously saved key (edit-without-replacing).
    /// Returns `false` if a non-nil key was supplied but failed to save — the config
    /// change is not applied in that case, so the UI can surface the failure.
    @discardableResult
    public func updateSource(_ source: RemoteQuotaSourceConfig, managementKey: String?) async -> Bool {
        guard let index = state.sources.firstIndex(where: { $0.id == source.id }) else { return false }
        if let managementKey, !managementKey.isEmpty {
            guard await credentials.saveManagementKey(managementKey, sourceId: source.id) else {
                state.statuses[source.id] = .error(RemoteQuotaSourceFailure.credentialSaveFailed.localizationKey)
                publish()
                return false
            }
        }
        state.sources[index] = source
        repository.save(state.sources)
        publish()
        return true
    }

    public func removeSource(_ sourceId: String) async {
        state.sources.removeAll { $0.id == sourceId }
        state.statuses.removeValue(forKey: sourceId)
        state.poolQuotas.removeValue(forKey: sourceId)
        state.failureCounts.removeValue(forKey: sourceId)
        state.lastUpdated.removeValue(forKey: sourceId)
        repository.save(state.sources)
        await credentials.deleteManagementKey(sourceId: sourceId)
        persistSnapshot()
        publish()
    }

    @discardableResult
    public func testConnection(_ sourceId: String) async -> Bool {
        guard let source = state.sources.first(where: { $0.id == sourceId }) else { return false }
        guard let key = await credentials.loadManagementKey(sourceId: sourceId) else {
            state.statuses[sourceId] = .error(RemoteQuotaSourceFailure.missingKey.localizationKey)
            publish()
            return false
        }
        state.statuses[sourceId] = .connecting
        publish()
        let responding = await fetcher.isResponding(source, managementKey: key)
        state.statuses[sourceId] = responding
            ? .connected
            : .error(RemoteQuotaSourceFailure.cannotConnect.localizationKey)
        publish()
        return responding
    }

    public func refreshAll(isAutomatic: Bool = false) async {
        for source in state.sources where source.isEnabled {
            await refresh(sourceId: source.id, isAutomatic: isAutomatic)
        }
    }

    public func refresh(sourceId: String, isAutomatic: Bool = false) async {
        guard let source = state.sources.first(where: { $0.id == sourceId }), source.isEnabled else {
            return
        }
        guard let key = await credentials.loadManagementKey(sourceId: sourceId) else {
            state.statuses[sourceId] = .error(RemoteQuotaSourceFailure.missingKey.localizationKey)
            recordOutcome(sourceId: sourceId, succeeded: false, isAutomatic: isAutomatic)
            publish()
            return
        }
        state.statuses[sourceId] = .connecting
        publish()
        do {
            let result = try await fetcher.fetchPool(source, managementKey: key)
            // Merge only the groups that succeeded this round on top of the last-known-good
            // reading; a provider/plan absent from `result` (because every account in that
            // group failed) keeps its previous value instead of disappearing.
            var pools = state.poolQuotas[sourceId] ?? [:]
            for (provider, planGroups) in result.quotasByProviderAndPlan {
                pools[provider, default: [:]].merge(planGroups) { _, new in new }
            }
            state.poolQuotas[sourceId] = pools
            state.statuses[sourceId] = result.hasPartialFailure
                ? .error(RemoteQuotaSourceFailure.partialFailure.localizationKey)
                : .connected
            state.lastUpdated[sourceId] = clock.now()
            recordOutcome(sourceId: sourceId, succeeded: !result.hasPartialFailure, isAutomatic: isAutomatic)
            persistSnapshot()
        } catch {
            // Keep the last successful pool reading — never overwrite it with a failure.
            // Map to a known, non-sensitive localization key rather than surfacing the
            // raw error (which may bridge to an opaque NSError description, or embed
            // response/connection detail that must never reach the UI).
            let key = (error as? RemoteQuotaFetchError)?.localizationKey
                ?? RemoteQuotaSourceFailure.unknownFetchFailure.localizationKey
            state.statuses[sourceId] = .error(key)
            recordOutcome(sourceId: sourceId, succeeded: false, isAutomatic: isAutomatic)
        }
        publish()
    }

    private func recordOutcome(sourceId: String, succeeded: Bool, isAutomatic: Bool) {
        if isAutomatic {
            state.failureCounts[sourceId] = succeeded ? 0 : (state.failureCounts[sourceId] ?? 0) + 1
        } else if succeeded {
            state.failureCounts[sourceId] = 0
        }
    }

    private func persistSnapshot() {
        snapshotStore.save(RemoteQuotaPoolSnapshot(quotasBySource: state.poolQuotas))
    }

    private func publish() {
        for continuation in continuations.values {
            continuation.yield(state)
        }
    }

    private func removeContinuation(_ id: UUID) {
        continuations.removeValue(forKey: id)
    }
}

public enum RemoteQuotaSourceFailure: Error, Equatable, Sendable {
    case missingKey
    case cannotConnect
    case credentialSaveFailed
    case partialFailure
    /// Fallback for any refresh failure that isn't a known `RemoteQuotaFetchError` —
    /// must never surface the underlying error's own message.
    case unknownFetchFailure

    /// A Localizable.xcstrings key — Presentation is responsible for localizing it.
    public var localizationKey: String {
        switch self {
        case .missingKey: "remote.quotaSource.error.missingKey"
        case .cannotConnect: "remote.quotaSource.error.cannotConnect"
        case .credentialSaveFailed: "remote.quotaSource.error.credentialSaveFailed"
        case .partialFailure: "remote.quotaSource.error.partialFailure"
        case .unknownFetchFailure: "remote.quotaSource.error.unknownFetchFailure"
        }
    }
}
