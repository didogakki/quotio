import Foundation

/// A user-configured, read-only quota source: a remote CLIProxyAPI instance whose
/// Management API is polled for pooled account quotas. Holds no secrets — the
/// admin/management key is stored separately behind a credential vault, keyed by `id`.
public struct RemoteQuotaSourceConfig: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var baseURL: String
    public var isEnabled: Bool

    public init(
        id: String = UUID().uuidString,
        name: String,
        baseURL: String,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.isEnabled = isEnabled
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

/// Identifies menu bar / quota-snapshot entries that represent an aggregated pool
/// of accounts fetched from a remote quota source, as opposed to a single local account.
public enum RemoteQuotaPoolIdentity {
    /// The literal `accountKey` used on `MenuBarQuotaItem` for pool entries.
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
