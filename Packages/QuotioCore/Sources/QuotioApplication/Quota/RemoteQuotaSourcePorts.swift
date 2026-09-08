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

/// Last-known-good pooled quotas per source, grouped by provider and normalized plan
/// key, so a failed refresh never has to discard the previous successful reading and
/// distinct plans (Plus/Business/Team/...) never get merged into one another.
public struct RemoteQuotaPoolSnapshot: Equatable, Sendable {
    public var quotasBySource: [String: [QuotaProvider: [String: ProviderQuota]]]

    public init(quotasBySource: [String: [QuotaProvider: [String: ProviderQuota]]] = [:]) {
        self.quotasBySource = quotasBySource
    }
}

public protocol RemoteQuotaPoolSnapshotStoring: Sendable {
    func load() -> RemoteQuotaPoolSnapshot
    func save(_ snapshot: RemoteQuotaPoolSnapshot)
}

/// Result of one pool fetch: only the provider/plan groups that were successfully
/// fetched and aggregated this round. `hasPartialFailure` is true when at least one
/// ready, supported auth file failed to produce a quota — the coordinator merges
/// `quotasByProviderAndPlan` on top of the last-known-good reading rather than
/// replacing it, and still records the round as a failure for the hide-threshold.
public struct RemoteQuotaPoolFetchResult: Equatable, Sendable {
    public var quotasByProviderAndPlan: [QuotaProvider: [String: ProviderQuota]]
    public var hasPartialFailure: Bool

    public init(
        quotasByProviderAndPlan: [QuotaProvider: [String: ProviderQuota]] = [:],
        hasPartialFailure: Bool = false
    ) {
        self.quotasByProviderAndPlan = quotasByProviderAndPlan
        self.hasPartialFailure = hasPartialFailure
    }
}

/// Talks directly to a remote CLIProxyAPI's Management API (never through ProxyBridge)
/// to test connectivity and pull pooled `ProviderQuota` groups, one per provider/plan
/// combination. Throws only when nothing at all could be fetched (auth-file listing
/// failed, no supported ready files exist, or every quota request failed) — a total
/// failure must never be allowed to silently look like an empty-but-successful pool.
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
    case noSupportedReadyFiles
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
