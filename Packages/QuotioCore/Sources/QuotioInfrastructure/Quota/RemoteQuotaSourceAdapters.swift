import Foundation
import LocalAuthentication
import QuotioApplication
import QuotioDomain
@preconcurrency import Security

public final class UserDefaultsRemoteQuotaSourceRepository: RemoteQuotaSourceRepository, @unchecked Sendable {
    public static let storageKey = "remoteQuotaSources"
    /// Pre-multi-source-config legacy key: an array of `LegacyRemoteMonitorSource`.
    public static let legacyStorageKey = "remoteMonitorSources"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> [RemoteQuotaSourceConfig] {
        // The new key, once written, is authoritative — even an empty array means the
        // user deliberately removed every source, and must not be overwritten by a
        // resurrected legacy source on the next launch. Migration only ever applies
        // when the new key is entirely absent or unreadable.
        if let data = defaults.data(forKey: Self.storageKey),
           let sources = try? JSONDecoder().decode([RemoteQuotaSourceConfig].self, from: data) {
            return sources
        }
        guard let migrated = migrateLegacySources() else { return [] }
        save(migrated)
        return migrated
    }

    public func save(_ sources: [RemoteQuotaSourceConfig]) {
        guard let data = try? JSONEncoder().encode(sources) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }

    /// Decodes the old single-source `remoteMonitorSources` payload and maps it onto
    /// today's `RemoteQuotaSourceConfig`. The old key is left untouched — this only
    /// ever writes to the new key, so a rollback to an older build still finds its data.
    private func migrateLegacySources() -> [RemoteQuotaSourceConfig]? {
        guard let data = defaults.data(forKey: Self.legacyStorageKey),
              let legacy = try? JSONDecoder().decode([LegacyRemoteMonitorSource].self, from: data),
              !legacy.isEmpty else { return nil }
        return legacy.map {
            RemoteQuotaSourceConfig(id: $0.id, name: $0.displayName, baseURL: $0.endpointURL, isEnabled: true)
        }
    }
}

/// Shape of the pre-multi-source `remoteMonitorSources` entries. Only the fields needed
/// to construct a `RemoteQuotaSourceConfig` are decoded; `verifySSL`, `timeoutSeconds`,
/// and `lastConnected` have no equivalent in the new model and are dropped.
private struct LegacyRemoteMonitorSource: Decodable {
    let id: String
    let endpointURL: String
    let displayName: String

    private enum CodingKeys: String, CodingKey {
        case id, endpointURL, displayName
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let stringId = try? container.decode(String.self, forKey: .id) {
            id = stringId
        } else if let uuidId = try? container.decode(UUID.self, forKey: .id) {
            id = uuidId.uuidString
        } else {
            id = UUID().uuidString
        }
        endpointURL = try container.decode(String.self, forKey: .endpointURL)
        displayName = (try? container.decodeIfPresent(String.self, forKey: .displayName)) ?? endpointURL
    }
}

/// Wraps the app's existing Keychain-backed credential store; each remote source's
/// admin key lives at its own `accountID`, scoped under one Keychain service. Falls
/// back to the pre-migration `remote-management` service/account convention
/// (`management-key-<sourceId>`) when the new location has nothing yet, and forward-
/// migrates the value — the legacy entry itself is never deleted, so downgrading to an
/// older build still finds its key.
public actor KeychainRemoteQuotaSourceCredentialVault: RemoteQuotaSourceCredentialVault {
    private let dataStore: any CredentialDataStoring
    private let legacyReader: (any LegacyKeychainReading)?
    private let legacyService: String?

    public init(
        dataStore: any CredentialDataStoring,
        legacyReader: (any LegacyKeychainReading)? = nil,
        legacyService: String? = nil
    ) {
        self.dataStore = dataStore
        self.legacyReader = legacyReader
        self.legacyService = legacyService
    }

    public func loadManagementKey(sourceId: String) async -> String? {
        if let record = await dataStore.read(accountID: sourceId),
           let value = String(data: record.data, encoding: .utf8) {
            return value
        }
        guard let legacyReader, let legacyService,
              let legacyValue = await legacyReader.read(
                service: legacyService,
                account: "management-key-\(sourceId)"
              )
        else { return nil }
        _ = await saveManagementKey(legacyValue, sourceId: sourceId)
        return legacyValue
    }

    public func saveManagementKey(_ key: String, sourceId: String) async -> Bool {
        guard let data = key.data(using: .utf8) else { return false }
        return await dataStore.save(data, accountID: sourceId) != nil
    }

    public func deleteManagementKey(sourceId: String) async {
        await dataStore.delete(accountID: sourceId)
    }
}

/// Read-only raw Keychain lookup by explicit (service, account), used solely to find a
/// pre-migration management key. Never writes or deletes — the caller decides whether
/// and where to migrate the value.
public actor RawKeychainStringReader: LegacyKeychainReading {
    public init() {}

    /// Reads without ever surfacing an interactive Keychain prompt: `read` calls happen
    /// during launch (including headless), and a blocking auth dialog there would hang
    /// startup. A miss just falls through to "nil" — the user re-saves the key in Settings.
    public func read(service: String, account: String) async -> String? {
        var result: AnyObject?
        var previousInteractionAllowed: DarwinBoolean = true
        SecKeychainGetUserInteractionAllowed(&previousInteractionAllowed)
        SecKeychainSetUserInteractionAllowed(false)
        defer { SecKeychainSetUserInteractionAllowed(previousInteractionAllowed.boolValue) }
        guard SecItemCopyMatching(Self.query(service: service, account: account) as CFDictionary, &result)
            == errSecSuccess,
            let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Split out from `read` so tests can assert the query disables interactive
    /// Keychain UI without touching the real Keychain.
    public nonisolated static func query(service: String, account: String) -> [String: Any] {
        let context = LAContext()
        context.interactionNotAllowed = true
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context,
        ]
    }
}

public final class UserDefaultsRemoteQuotaPoolSnapshotStore: RemoteQuotaPoolSnapshotStoring, @unchecked Sendable {
    private struct Payload: Codable {
        var quotasBySource: [String: [String: [String: ProviderQuota]]]
    }

    public static let storageKey = "remoteQuotaPoolSnapshot"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> RemoteQuotaPoolSnapshot {
        guard let data = defaults.data(forKey: Self.storageKey),
              let payload = try? JSONDecoder().decode(Payload.self, from: data)
        else { return RemoteQuotaPoolSnapshot() }
        let decoded = payload.quotasBySource.reduce(into: [String: [QuotaProvider: [String: ProviderQuota]]]()) {
            result, entry in
            let byProvider = entry.value.reduce(into: [QuotaProvider: [String: ProviderQuota]]()) {
                result, pair in
                guard let provider = QuotaProvider(rawValue: pair.key) else { return }
                result[provider] = pair.value
            }
            result[entry.key] = byProvider
        }
        return RemoteQuotaPoolSnapshot(quotasBySource: decoded)
    }

    public func save(_ snapshot: RemoteQuotaPoolSnapshot) {
        let encoded = snapshot.quotasBySource.reduce(into: [String: [String: [String: ProviderQuota]]]()) {
            result, entry in
            result[entry.key] = entry.value.reduce(into: [String: [String: ProviderQuota]]()) { result, pair in
                result[pair.key.rawValue] = pair.value
            }
        }
        guard let data = try? JSONEncoder().encode(Payload(quotasBySource: encoded)) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}
