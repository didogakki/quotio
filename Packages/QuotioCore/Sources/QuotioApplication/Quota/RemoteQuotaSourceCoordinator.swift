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
        /// sourceId -> provider -> raw remote account key -> that account's own quota
        /// (never a plan-level aggregate).
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

    /// The exact display name of the one, already-existing remote source
    /// `QuotaPolicy.legacyGrokPlanDefault` applies to. Only ever consulted to *find* the
    /// confirmed source the first time; once found, `RemoteQuotaSourceConfig.isLegacyGrokPlusSource`
    /// is persisted on it and this name is never consulted again for that source.
    private static let legacyGrokPlusSourceName = "CLIProxyAPI Plus"

    /// Mirrors whichever saved source (if any) carries `isLegacyGrokPlusSource == true` —
    /// kept in memory only as a fast lookup for `refresh(sourceId:isAutomatic:)`. The
    /// actual confirmed identity lives on `RemoteQuotaSourceConfig.isLegacyGrokPlusSource`
    /// itself, persisted via `repository.save`, so it survives a cold relaunch and any
    /// later rename of that source — a rename can never cause a different, unrelated
    /// source that happens to share the original name to take it over, since the flag is
    /// only ever assigned to a source once, the first time it is resolved by name.
    private var legacyGrokPlusSourceId: String?

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
        // Actor initializers run outside the actor's isolated context in Swift 6, so an
        // `await`-free call into an actor-isolated instance method (like
        // `captureLegacyGrokPlusSourceIdIfNeeded()`) does not type-check here — hence the
        // logic is inlined via the static, non-isolated helper below instead.
        if let match = Self.resolvingLegacyGrokPlusSource(in: sources) {
            legacyGrokPlusSourceId = match.id
            if match.sources != sources {
                state.sources = match.sources
                repository.save(match.sources)
            }
        }
    }

    /// Finds the confirmed legacy Grok "Plus" source among `sources` — a source already
    /// flagged `isLegacyGrokPlusSource == true` wins unconditionally; only when none is
    /// flagged yet does this fall back to a one-time resolution by exact display name,
    /// which flags that source (returned in `.sources`) so the caller can persist it.
    /// The by-name fallback only resolves when exactly one source carries that name —
    /// two or more candidates means the name alone can't identify which one is the real
    /// legacy source, so this returns `nil` rather than guessing via `firstIndex`, which
    /// would arbitrarily (and permanently, once persisted) pick one.
    /// `static` and non-isolated so it can be called from the actor's own `init`, where
    /// isolated instance methods cannot be invoked synchronously.
    private static func resolvingLegacyGrokPlusSource(
        in sources: [RemoteQuotaSourceConfig]
    ) -> (sources: [RemoteQuotaSourceConfig], id: String)? {
        if let confirmed = sources.first(where: { $0.isLegacyGrokPlusSource == true }) {
            return (sources, confirmed.id)
        }
        let candidates = sources.indices.filter { sources[$0].name == legacyGrokPlusSourceName }
        guard candidates.count == 1, let index = candidates.first else {
            return nil
        }
        var updated = sources
        updated[index].isLegacyGrokPlusSource = true
        return (updated, updated[index].id)
    }

    private func captureLegacyGrokPlusSourceIdIfNeeded() {
        guard let match = Self.resolvingLegacyGrokPlusSource(in: state.sources) else { return }
        legacyGrokPlusSourceId = match.id
        guard match.sources != state.sources else { return }
        state.sources = match.sources
        repository.save(match.sources)
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
        var newSource = source
        // Preserve the same confirmed identity as `updateSource` does, for the same
        // reason, on the rare path where `addSource` is used to replace an
        // already-existing id.
        if let existingIndex = sources.firstIndex(where: { $0.id == source.id }) {
            newSource.isLegacyGrokPlusSource = sources[existingIndex].isLegacyGrokPlusSource
        }
        sources.removeAll { $0.id == source.id }
        sources.append(newSource)
        state.sources = sources
        repository.save(sources)
        captureLegacyGrokPlusSourceIdIfNeeded()
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
        // `isLegacyGrokPlusSource` is an internal, coordinator-only confirmed identity —
        // callers editing a source (e.g. renaming it in Settings) build `source` with no
        // knowledge of it, so it must always be carried forward from the previously
        // stored config rather than taken from the incoming value, or every edit to the
        // confirmed source would silently erase its confirmation.
        var updatedSource = source
        updatedSource.isLegacyGrokPlusSource = state.sources[index].isLegacyGrokPlusSource
        state.sources[index] = updatedSource
        repository.save(state.sources)
        captureLegacyGrokPlusSourceIdIfNeeded()
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

            // Grok has no per-account plan field of its own on the remote listing; the
            // narrowly source-scoped legacy default (see `QuotaPolicy.legacyGrokPlanDefault`)
            // is applied here — by this source's own stable `id`, not its display name —
            // rather than inside the fetcher, which has no memory of that identity across
            // refreshes.
            var freshQuotas = result.quotasByProviderAndAccount
            if let grokAccounts = freshQuotas[.grok] {
                freshQuotas[.grok] = grokAccounts.mapValues { quota in
                    var updated = quota
                    updated.planType = QuotaPolicy.legacyGrokPlanDefault(
                        sourceId: sourceId,
                        knownLegacySourceId: legacyGrokPlusSourceId,
                        rawPlanType: quota.planType
                    )
                    return updated
                }
            }

            // Merge only the accounts that succeeded this round on top of the last-known-good
            // reading; a provider/account absent from `result` (because that account's
            // fetch failed) keeps its previous value instead of disappearing. Per account
            // that refreshed successfully in both rounds, `mergingCodexResetCredits` also
            // re-attaches a Codex account's previous `codexResetCreditSummary`/analytics
            // rows when only that round's separate reset-credit request failed — usage
            // still refreshes normally, it just doesn't blank out reset-credit data it
            // simply failed to re-fetch this one time.
            var pools = state.poolQuotas[sourceId] ?? [:]
            for (provider, accountQuotas) in freshQuotas {
                pools[provider, default: [:]].merge(accountQuotas) { old, new in
                    QuotaPolicy.mergingCodexResetCredits(old: old, new: new)
                }
            }
            // A frozen account that produced no reading of its own gets an identity-only
            // stand-in, but only where nothing is known yet: a reading already in the pool
            // — this round's or a previous one's — always wins, so freezing never costs an
            // account the numbers it last reported.
            for (provider, placeholders) in result.placeholderQuotas {
                for (accountKey, placeholder) in placeholders where pools[provider]?[accountKey] == nil {
                    pools[provider, default: [:]][accountKey] = placeholder
                }
            }
            // `knownAccountKeys` is this round's authoritative listing (a listing that
            // could not be obtained throws instead of returning a result), so every
            // provider it mentions is pruned down to exactly the accounts that still
            // exist — including down to nothing, which drops the provider entirely.
            // This runs for a failed round too: quota requests failing says nothing
            // about which accounts exist. A provider the listing says nothing about is
            // left untouched, as is an account that is still listed but whose own quota
            // request merely failed (it keeps its last-known-good reading).
            for (provider, knownKeys) in result.knownAccountKeys {
                guard let existing = pools[provider] else { continue }
                let retained = existing.filter { knownKeys.contains($0.key) }
                if retained.isEmpty {
                    pools.removeValue(forKey: provider)
                } else {
                    pools[provider] = retained
                }
            }
            // Applied after the prune, over whatever survived it, because the state must
            // describe this round's listing rather than the round a given reading came
            // from — the pool can legitimately hold a previous round's quota object.
            // Clearing back to `nil` is what lets an account that recovered stop reading
            // as frozen without waiting for its next successful fetch. `availabilityRecoveryDate`
            // is re-stamped from this round's own authoritative `availabilityRecoveryDates`
            // right alongside `isTemporarilyUnavailable` — every other field on `quota`
            // (models, plan, etc.) is left untouched — precisely so an account whose own
            // quota request merely failed again (keeping its last-known-good reading via
            // the merge above, never a placeholder, since it already has one) doesn't keep
            // showing an earlier round's stale recovery estimate: a round with no fresh
            // signal for it reports that as `nil` here, same as when it recovers.
            for (provider, frozenKeys) in result.temporarilyUnavailableAccountKeys {
                guard let byAccount = pools[provider] else { continue }
                let recoveryDates = result.availabilityRecoveryDates[provider] ?? [:]
                pools[provider] = byAccount.reduce(into: [String: ProviderQuota]()) { stamped, entry in
                    var quota = entry.value
                    let isFrozen = frozenKeys.contains(entry.key)
                    quota.isTemporarilyUnavailable = isFrozen ? true : nil
                    quota.availabilityRecoveryDate = isFrozen ? recoveryDates[entry.key] : nil
                    stamped[entry.key] = quota
                }
            }
            // Authentication state is intentionally stickier than a quota fetch result:
            // only an explicit classified failure sets it and only a successful usage
            // reading clears it. A transient cache/network error observes neither, so the
            // previous issue remains visible instead of making a broken login look healthy.
            for (provider, observedKeys) in result.accountIssueObservedKeys {
                guard let byAccount = pools[provider] else { continue }
                let issues = result.accountIssues[provider] ?? [:]
                pools[provider] = byAccount.reduce(into: [String: ProviderQuota]()) { stamped, entry in
                    var quota = entry.value
                    if observedKeys.contains(entry.key) {
                        quota.remoteAccountIssue = issues[entry.key]
                    }
                    stamped[entry.key] = quota
                }
            }
            state.poolQuotas[sourceId] = pools
            if let failureKey = result.failureLocalizationKey {
                state.statuses[sourceId] = .error(failureKey)
            } else {
                state.statuses[sourceId] = .connected
            }
            // The server was reached and its account list read, so this is genuinely
            // when the source was last synchronized — even if some or all of its quota
            // requests failed (which the error status above already reports).
            state.lastUpdated[sourceId] = clock.now()
            recordOutcome(sourceId: sourceId, succeeded: !result.isFailure, isAutomatic: isAutomatic)
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
