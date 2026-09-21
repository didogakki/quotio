import Foundation
import QuotioDomain

/// Persists the list of configured remote quota sources (no secrets — see
/// `RemoteQuotaSourceCredentialVault` for the admin/management key).
public protocol RemoteQuotaSourceRepository: Sendable {
    func load() -> [RemoteQuotaSourceConfig]
    func save(_ sources: [RemoteQuotaSourceConfig])
}

/// Stores each remote source's management-API admin key behind the app's Keychain
/// abstraction, keyed by `RemoteQuotaSourceConfig.id`.
public protocol RemoteQuotaSourceCredentialVault: Sendable {
    func loadManagementKey(sourceId: String) async -> String?
    func saveManagementKey(_ key: String, sourceId: String) async -> Bool
    func deleteManagementKey(sourceId: String) async
}

/// Reads a previously-stored secret from a legacy Keychain (service, account) pair
/// without ever deleting it, so the pre-migration value stays available as a fallback.
/// Kept as its own injectable port purely so Keychain access can be faked in tests.
public protocol LegacyKeychainReading: Sendable {
    func read(service: String, account: String) async -> String?
}

/// Last-known-good quotas per source, grouped by provider and by each real remote
/// account's own raw key (never a plan-level aggregate), so a failed refresh never has
/// to discard the previous successful reading and distinct accounts never get merged
/// into one another.
public struct RemoteQuotaPoolSnapshot: Equatable, Sendable {
    public var quotasBySource: [String: [QuotaProvider: [String: ProviderQuota]]]

    public init(quotasBySource: [String: [QuotaProvider: [String: ProviderQuota]]] = [:]) {
        self.quotasBySource = quotasBySource
    }
}

/// Implementations must treat a snapshot persisted by an older, incompatibly-keyed
/// build as absent rather than decoding it: the innermost key changed meaning (it used
/// to identify a plan-level aggregate, it now identifies one real account), so a stale
/// payload would resurface aggregates masquerading as accounts. This applies only to
/// this cache — source configs, management keys, and menu bar pins are stored elsewhere
/// and must never be discarded by it.
public protocol RemoteQuotaPoolSnapshotStoring: Sendable {
    func load() -> RemoteQuotaPoolSnapshot
    func save(_ snapshot: RemoteQuotaPoolSnapshot)
}

/// Result of one fetch round. A result is only ever returned when the auth-file listing
/// itself succeeded, so `knownAccountKeys` is **always** this round's authoritative
/// account list — even when no account produced a quota, and even when the list is
/// empty. Quota failures are reported separately in `outcome` and never weaken that
/// authority: the coordinator merges `quotasByProviderAndAccount` on top of the
/// last-known-good reading (so an account that merely failed keeps its old value) while
/// still pruning whatever the listing no longer contains.
public struct RemoteQuotaPoolFetchResult: Equatable, Sendable {
    /// How much of this round's *quota* work succeeded. Independent of the listing,
    /// which always succeeded when a result exists (a listing failure throws instead).
    public enum QuotaOutcome: Equatable, Sendable {
        /// Every listed account produced a quota this round.
        case complete
        /// Some — but not all — listed accounts produced a quota.
        case partial
        /// The listing reported accounts, but none of them produced a quota.
        case allFailed
        /// The listing reported no supported, trackable account at all. Still
        /// authoritative: the source genuinely has nothing left, so stale entries must be
        /// pruned rather than kept forever.
        case noAccountsListed
    }

    public var quotasByProviderAndAccount: [QuotaProvider: [String: ProviderQuota]]
    public var outcome: QuotaOutcome
    /// This round's complete account listing: one entry for every provider the fetcher
    /// supports, whose value is every account key that provider currently has as a
    /// ready, supported auth file — **including an empty set** when it has none left.
    /// That is what lets the coordinator drop a provider's last remaining account (and
    /// the provider itself) instead of leaving a stale reading behind forever. A
    /// provider absent from this dictionary is one the listing said nothing about, so
    /// its previous accounts are left untouched. A frozen account stays in this list:
    /// being temporarily unusable is a state, never an absence, so it is listed here and
    /// additionally named in `temporarilyUnavailableAccountKeys`.
    public var knownAccountKeys: [QuotaProvider: Set<String>]
    /// Which of `knownAccountKeys` the source currently reports as frozen (cooling after
    /// a rate limit, or otherwise flagged unavailable). Seeded for every provider the
    /// fetcher supports — **including an empty set** — so the coordinator can clear the
    /// state off an account that recovered, not just set it on one that just froze.
    /// Carried separately from the quotas rather than stamped onto them because a quota
    /// left in the pool may be a *previous* round's reading, while this state must always
    /// come from this round's authoritative listing.
    public var temporarilyUnavailableAccountKeys: [QuotaProvider: Set<String>]
    /// Identity-only stand-ins for frozen accounts that produced no reading of their own
    /// this round. Never carry fabricated metrics, and never replace a reading the
    /// coordinator already holds — they exist so an account that froze before it was ever
    /// read successfully still shows up as a row instead of silently not existing.
    public var placeholderQuotas: [QuotaProvider: [String: ProviderQuota]]
    /// This round's authoritative freeze/cooldown recovery time for every account named
    /// in `temporarilyUnavailableAccountKeys`, when one could actually be resolved (see
    /// `ManagedAuthFile.recoveryDate(fetchedAt:)`). An entry missing here for a frozen
    /// account means this round found no real signal for it, never that its previous
    /// recovery time should be kept — the coordinator applies this dictionary to *every*
    /// frozen account each round, freshly, precisely so a stale recovery time from an
    /// earlier round can never linger on an account whose own quota request merely failed
    /// again without producing a fresh reading of its own (see `placeholderQuotas`, which
    /// only ever covers an account with no reading in the pool at all).
    public var availabilityRecoveryDates: [QuotaProvider: [String: Date]]
    /// Current safe account issues observed this round, keyed exactly like quota rows.
    /// Only keys also present in `accountIssueObservedKeys` are authoritative.
    public var accountIssues: [QuotaProvider: [String: RemoteQuotaAccountIssue]]
    /// Accounts whose authentication state was definitively observed this round: either
    /// a successful usage reading (which clears any old issue) or an explicit classified
    /// auth failure. Accounts omitted here keep their previous issue across transient
    /// cache/network failures.
    public var accountIssueObservedKeys: [QuotaProvider: Set<String>]

    public init(
        quotasByProviderAndAccount: [QuotaProvider: [String: ProviderQuota]] = [:],
        outcome: QuotaOutcome = .complete,
        knownAccountKeys: [QuotaProvider: Set<String>] = [:],
        temporarilyUnavailableAccountKeys: [QuotaProvider: Set<String>] = [:],
        placeholderQuotas: [QuotaProvider: [String: ProviderQuota]] = [:],
        availabilityRecoveryDates: [QuotaProvider: [String: Date]] = [:],
        accountIssues: [QuotaProvider: [String: RemoteQuotaAccountIssue]] = [:],
        accountIssueObservedKeys: [QuotaProvider: Set<String>] = [:]
    ) {
        self.quotasByProviderAndAccount = quotasByProviderAndAccount
        self.outcome = outcome
        self.knownAccountKeys = knownAccountKeys
        self.temporarilyUnavailableAccountKeys = temporarilyUnavailableAccountKeys
        self.placeholderQuotas = placeholderQuotas
        self.availabilityRecoveryDates = availabilityRecoveryDates
        self.accountIssues = accountIssues
        self.accountIssueObservedKeys = accountIssueObservedKeys
    }

    /// Whether this round counts as a failure for the status badge and the
    /// consecutive-failure hide threshold.
    public var isFailure: Bool { outcome != .complete }

    /// The non-sensitive `Localizable.xcstrings` key to surface for this round, or nil
    /// when everything succeeded.
    public var failureLocalizationKey: String? {
        switch outcome {
        case .complete: nil
        case .partial: RemoteQuotaSourceFailure.partialFailure.localizationKey
        case .allFailed: RemoteQuotaFetchError.allRequestsFailed.localizationKey
        case .noAccountsListed: RemoteQuotaFetchError.noSupportedReadyFiles.localizationKey
        }
    }
}

/// Talks directly to a remote CLIProxyAPI's Management API (never through ProxyBridge)
/// to test connectivity and pull each real remote account's own `ProviderQuota`, one per
/// account — never aggregated into a plan-level pool. Throws **only** when the auth-file
/// listing itself could not be obtained, since that is the one case where the returned
/// account list would be a guess. "No supported trackable files" and "every quota request
/// failed" both return a result instead: the listing succeeded, so it is authoritative
/// and must still be allowed to prune, while `outcome` keeps the round marked as a
/// failure so it can never look like a successful refresh. Accounts the source reports as
/// frozen are listed like any other — they are simply not expected to produce a reading,
/// so their failure to do so never counts against `outcome`.
public protocol RemoteQuotaSourceFetching: Sendable {
    func isResponding(_ source: RemoteQuotaSourceConfig, managementKey: String) async -> Bool
    func fetchPool(
        _ source: RemoteQuotaSourceConfig,
        managementKey: String
    ) async throws -> RemoteQuotaPoolFetchResult
}

/// Classifies why a pool fetch failed into actionable, non-sensitive categories.
/// Never carries the underlying error's message — HTTP bodies, auth headers, and raw
/// connection strings must never reach the UI or logs.
public enum RemoteQuotaFetchError: Error, Equatable, Sendable {
    /// 401/403 from the management API — the management key is missing or rejected.
    case unauthorized
    /// 404 on a management endpoint — likely an incompatible or misconfigured
    /// `/v0/management` reverse proxy.
    case endpointNotFound
    /// The response body could not be parsed, or the API returned something other
    /// than a well-formed management response.
    case invalidResponse
    /// The management API could not be reached at all (network/connection failure).
    case connectivityUnavailable
    /// Listing auth files failed for a reason that doesn't fit the categories above.
    case authFilesUnavailable
    /// Never thrown — the listing that reported "nothing supported and trackable"
    /// succeeded, so it comes back as
    /// `RemoteQuotaPoolFetchResult.QuotaOutcome.noAccountsListed` and this case exists
    /// only to name that outcome's localization key.
    case noSupportedReadyFiles
    /// Never thrown, for the same reason: see
    /// `RemoteQuotaPoolFetchResult.QuotaOutcome.allFailed`.
    case allRequestsFailed

    /// A Localizable.xcstrings key — Presentation is responsible for localizing it.
    public var localizationKey: String {
        switch self {
        case .unauthorized: "remote.quotaSource.error.unauthorized"
        case .endpointNotFound: "remote.quotaSource.error.endpointNotFound"
        case .invalidResponse: "remote.quotaSource.error.invalidResponse"
        case .connectivityUnavailable: "remote.quotaSource.error.connectivityUnavailable"
        case .authFilesUnavailable: "remote.quotaSource.error.authFilesUnavailable"
        case .noSupportedReadyFiles: "remote.quotaSource.error.noSupportedReadyFiles"
        case .allRequestsFailed: "remote.quotaSource.error.allRequestsFailed"
        }
    }
}
