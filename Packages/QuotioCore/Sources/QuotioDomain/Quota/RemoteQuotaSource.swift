import Foundation

/// A user-configured, read-only quota source: a remote CLIProxyAPI instance whose
/// Management API is polled for pooled account quotas. Holds no secrets — the
/// admin/management key is stored separately behind a credential vault, keyed by `id`.
public struct RemoteQuotaSourceConfig: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var baseURL: String
    public var isEnabled: Bool
    /// Set (and persisted, via `RemoteQuotaSourceRepository.save`) exactly once, on
    /// whichever already-saved source is first resolved by
    /// `RemoteQuotaSourceCoordinator` as the one confirmed to be the legacy Grok "Plus"
    /// default's source (see `QuotaPolicy.legacyGrokPlanDefault`). Kept `nil`/absent for
    /// every other source, including a different, unrelated source that merely shares
    /// that one source's original display name. Once set, this — not the name — is the
    /// stable, cold-relaunch-safe identity that survives that source being renamed;
    /// `Optional` so a config persisted before this flag existed decodes with it simply
    /// absent (never as `false`, which would be indistinguishable from "confirmed not
    /// this source").
    public var isLegacyGrokPlusSource: Bool?
    /// Base URL of a local, read-only quota-cache service (`scripts/quota-cache`) that
    /// this source's usage/profile/credits requests should go through instead of the
    /// remote CLIProxyAPI's `/api-call` pass-through directly. `nil` (the default)
    /// preserves the original direct-fetch behavior — every other source, and every
    /// config persisted before this field existed, decodes with it absent. Never
    /// guessed/derived: only set when the operator has actually deployed a cache for
    /// this specific source. Auth-file listing and account control always stay direct
    /// regardless of this setting, so cache availability never affects which accounts
    /// are known to exist.
    public var quotaCacheBaseURL: String?

    public init(
        id: String = UUID().uuidString,
        name: String,
        baseURL: String,
        isEnabled: Bool = true,
        isLegacyGrokPlusSource: Bool? = nil,
        quotaCacheBaseURL: String? = nil
    ) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.isEnabled = isEnabled
        self.isLegacyGrokPlusSource = isLegacyGrokPlusSource
        self.quotaCacheBaseURL = quotaCacheBaseURL
    }

    /// Edits only form-owned fields, retaining cache configuration and internal metadata.
    public func updatingEditableFields(name: String, baseURL: String, isEnabled: Bool) -> Self {
        var updated = self
        updated.name = name
        updated.baseURL = baseURL
        updated.isEnabled = isEnabled
        return updated
    }

    /// Normalizes the configured base URL to the CLIProxyAPI management root,
    /// mirroring the `/v0/management` convention used by ProxyManagementConnection.
    public var managementBaseURL: String {
        var url = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while url.hasSuffix("/") { url.removeLast() }
        guard !url.hasSuffix("/v0/management") else { return url }
        return url.hasSuffix("/v0") ? url + "/management" : url + "/v0/management"
    }
}

/// Legacy identity for menu bar / quota-snapshot entries that represented an
/// **aggregated pool** of accounts fetched from a remote quota source (one entry per
/// plan group, never a real account). Superseded by `RemoteQuotaAccountIdentity`, which
/// keys per real remote account instead of per plan-level aggregate. Kept only so
/// previously-persisted `MenuBarQuotaItem` pins (`accountKey == "__pool__"`) still decode
/// and can be migrated/expanded — new code must never mint pool-style entries.
public enum RemoteQuotaPoolIdentity {
    /// The literal `accountKey` used on `MenuBarQuotaItem` for legacy pool entries.
    public static let accountKey = "__pool__"
    private static let separator = "::"

    /// The composite key used inside quota snapshot dictionaries (`[String: ProviderQuota]`)
    /// so pools from different remote sources — and different plan groups within the
    /// same source/provider — never collide.
    public static func storageKey(sourceId: String, planKey: String) -> String {
        "\(accountKey)\(separator)\(sourceId)\(separator)\(planKey)"
    }

    public static func components(fromStorageKey key: String) -> (sourceId: String, planKey: String)? {
        let prefix = "\(accountKey)\(separator)"
        guard key.hasPrefix(prefix) else { return nil }
        let rest = String(key.dropFirst(prefix.count))
        let parts = rest.components(separatedBy: separator)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        return (parts[0], parts[1])
    }
}

/// Identifies menu bar / quota-snapshot entries that represent one real account fetched
/// from a remote quota source — never a plan-level aggregate. `accountKey` is the raw
/// per-account key the remote source's fetcher assigned (e.g. its auth-file index),
/// carried unchanged so the same real account's identity survives from fetch through
/// display.
public enum RemoteQuotaAccountIdentity {
    private static let prefix = "acct"
    private static let separator = "::"

    /// The composite key used inside quota snapshot dictionaries (`[String: ProviderQuota]`)
    /// so real accounts from different remote sources — or a remote account and a local
    /// account that happen to share a raw key/email — never collide. Only the first
    /// `::`-delimited segment after the prefix is treated as the source id; the
    /// remainder is the raw account key verbatim, so an account key that itself
    /// contains `::` still round-trips.
    public static func storageKey(sourceId: String, accountKey: String) -> String {
        "\(prefix)\(separator)\(sourceId)\(separator)\(accountKey)"
    }

    public static func components(fromStorageKey key: String) -> (sourceId: String, accountKey: String)? {
        let fullPrefix = "\(prefix)\(separator)"
        guard key.hasPrefix(fullPrefix) else { return nil }
        let rest = String(key.dropFirst(fullPrefix.count))
        guard let range = rest.range(of: separator) else { return nil }
        let sourceId = String(rest[rest.startIndex..<range.lowerBound])
        let accountKey = String(rest[range.upperBound...])
        guard !sourceId.isEmpty, !accountKey.isEmpty else { return nil }
        return (sourceId, accountKey)
    }
}

/// Identifies a **derived, read-only** summary row that combines every real remote
/// account sharing one source + provider + normalized plan key (see
/// `QuotaPolicy.normalizedPlanKey`) into a single display entry. Unlike
/// `RemoteQuotaPoolIdentity`, this is not a legacy artifact and never appears inside a
/// quota-snapshot dictionary that feeds fetch/refresh/local+remote merge — it exists only
/// in presentation-layer, on-the-fly aggregation (`QuotaPolicy.aggregate`), so the prefix
/// only needs to stay distinct from `acct::`/`__pool__` to be pinnable without collision.
public enum RemoteQuotaAggregateIdentity {
    private static let prefix = "aggr"
    private static let separator = "::"

    public static func storageKey(sourceId: String, planKey: String) -> String {
        "\(prefix)\(separator)\(sourceId)\(separator)\(planKey)"
    }

    public static func components(fromStorageKey key: String) -> (sourceId: String, planKey: String)? {
        let fullPrefix = "\(prefix)\(separator)"
        guard key.hasPrefix(fullPrefix) else { return nil }
        let rest = String(key.dropFirst(fullPrefix.count))
        let parts = rest.components(separatedBy: separator)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        return (parts[0], parts[1])
    }
}

/// Validates a remote quota source's configured base URL before it is saved: must be an
/// absolute `http`/`https` URL with a non-empty host. Rejects relative URLs and other
/// schemes (`file:`, `javascript:`, etc.) that would never reach a CLIProxyAPI server.
public enum RemoteQuotaSourceURLValidation {
    public static func isValid(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed), let scheme = url.scheme?.lowercased() else {
            return false
        }
        guard scheme == "http" || scheme == "https" else { return false }
        guard let host = url.host, !host.isEmpty else { return false }
        return true
    }
}

public enum RemoteQuotaSourceConnectionStatus: Equatable, Sendable {
    case unknown
    case connecting
    case connected
    case error(String)
}
