import Foundation
import LocalAuthentication
import QuotioApplication
import QuotioDomain
@preconcurrency import Security
import XCTest

@testable import QuotioInfrastructure

final class RemoteQuotaSourceAdaptersTests: XCTestCase {
    // MARK: - Repository migration

    func testLoadMigratesLegacyRemoteMonitorSourcesWhenNewKeyIsEmpty() {
        let defaults = makeDefaults()
        let legacyJSON = """
        [
          {"id":"legacy-1","endpointURL":"https://old.example.com","displayName":"Old Server","verifySSL":true,"timeoutSeconds":30,"lastConnected":"2026-01-01T00:00:00Z"}
        ]
        """
        defaults.set(Data(legacyJSON.utf8), forKey: "remoteMonitorSources")
        let repository = UserDefaultsRemoteQuotaSourceRepository(defaults: defaults)

        let sources = repository.load()

        XCTAssertEqual(sources.count, 1)
        XCTAssertEqual(sources.first?.id, "legacy-1")
        XCTAssertEqual(sources.first?.name, "Old Server")
        XCTAssertEqual(sources.first?.baseURL, "https://old.example.com")
        XCTAssertTrue(sources.first?.isEnabled ?? false)

        // The migration must write the new key without touching the legacy one.
        XCTAssertNotNil(defaults.data(forKey: "remoteMonitorSources"))
        let newSources = UserDefaultsRemoteQuotaSourceRepository(defaults: defaults).load()
        XCTAssertEqual(newSources.map(\.id), ["legacy-1"])
    }

    func testLoadIgnoresLegacyDataOnceNewKeyHasSources() {
        let defaults = makeDefaults()
        let repository = UserDefaultsRemoteQuotaSourceRepository(defaults: defaults)
        repository.save([RemoteQuotaSourceConfig(id: "new-1", name: "New", baseURL: "https://new.test")])
        defaults.set(Data(#"[{"id":"legacy-1","endpointURL":"https://old.test","displayName":"Old"}]"#.utf8), forKey: "remoteMonitorSources")

        let sources = repository.load()

        XCTAssertEqual(sources.map(\.id), ["new-1"])
    }

    func testLoadReturnsEmptyWhenNeitherKeyHasData() {
        let repository = UserDefaultsRemoteQuotaSourceRepository(defaults: makeDefaults())
        XCTAssertTrue(repository.load().isEmpty)
    }

    /// Regression: once the new key exists and decodes, it is authoritative even when
    /// the user has deleted every source — an empty array must NOT fall through to
    /// resurrecting a stale legacy `remoteMonitorSources` entry.
    func testLoadKeepsNewKeyAuthoritativeWhenUserDeletedAllSources() {
        let defaults = makeDefaults()
        defaults.set(
            Data(#"[{"id":"legacy-1","endpointURL":"https://old.test","displayName":"Old"}]"#.utf8),
            forKey: "remoteMonitorSources"
        )
        let repository = UserDefaultsRemoteQuotaSourceRepository(defaults: defaults)
        repository.save([])

        let sources = repository.load()

        XCTAssertTrue(sources.isEmpty)
        // A second load must stay empty too — no resurrection on a later launch either.
        XCTAssertTrue(UserDefaultsRemoteQuotaSourceRepository(defaults: defaults).load().isEmpty)
    }

    // MARK: - Credential vault legacy fallback

    func testLoadManagementKeyFallsBackToLegacyServiceAndAccountConvention() async {
        let dataStore = MemoryCredentialDataStore()
        let legacyReader = MemoryLegacyKeychainReader(store: [
            "legacy-service": ["management-key-src-1": "legacy-secret"]
        ])
        let vault = KeychainRemoteQuotaSourceCredentialVault(
            dataStore: dataStore,
            legacyReader: legacyReader,
            legacyService: "legacy-service"
        )

        let key = await vault.loadManagementKey(sourceId: "src-1")

        XCTAssertEqual(key, "legacy-secret")
        // Forward-migrated into the new location.
        let migrated = await dataStore.read(accountID: "src-1")
        XCTAssertEqual(migrated.map { String(data: $0.data, encoding: .utf8) }, "legacy-secret")
        // The legacy value itself must never be deleted — it stays available as a rollback path.
        let stillThere = await legacyReader.read(service: "legacy-service", account: "management-key-src-1")
        XCTAssertEqual(stillThere, "legacy-secret")
    }

    func testLoadManagementKeyPrefersNewLocationOverLegacy() async {
        let dataStore = MemoryCredentialDataStore()
        _ = await dataStore.save(Data("new-secret".utf8), accountID: "src-1")
        let legacyReader = MemoryLegacyKeychainReader(store: [
            "legacy-service": ["management-key-src-1": "legacy-secret"]
        ])
        let vault = KeychainRemoteQuotaSourceCredentialVault(
            dataStore: dataStore,
            legacyReader: legacyReader,
            legacyService: "legacy-service"
        )

        let key = await vault.loadManagementKey(sourceId: "src-1")

        XCTAssertEqual(key, "new-secret")
    }

    func testLoadManagementKeyReturnsNilWhenNeitherLocationHasAValue() async {
        let vault = KeychainRemoteQuotaSourceCredentialVault(
            dataStore: MemoryCredentialDataStore(),
            legacyReader: MemoryLegacyKeychainReader(store: [:]),
            legacyService: "legacy-service"
        )

        let key = await vault.loadManagementKey(sourceId: "src-1")

        XCTAssertNil(key)
    }

    // MARK: - Legacy Keychain read query

    /// Regression: the legacy migration read must never surface an interactive
    /// Keychain prompt during (possibly headless) launch. Asserts the query shape
    /// rather than touching the real Keychain.
    func testRawKeychainStringReaderQueryDisablesInteractiveAuth() {
        let query = RawKeychainStringReader.query(service: "svc", account: "acct")

        let context = query[kSecUseAuthenticationContext as String] as? LAContext
        XCTAssertEqual(context?.interactionNotAllowed, true)
        XCTAssertEqual(query[kSecAttrService as String] as? String, "svc")
        XCTAssertEqual(query[kSecAttrAccount as String] as? String, "acct")
    }

    // MARK: - Pool snapshot versioning

    /// The pre-versioning payload keyed each provider's entries by **plan group** — an
    /// aggregate across accounts — with byte-identical JSON to today's per-account
    /// shape. Decoding it would resurrect those aggregates as if they were real
    /// accounts, so an unversioned payload must be discarded outright.
    func testLoadDiscardsUnversionedLegacyAggregateSnapshot() {
        let defaults = makeDefaults()
        // Deliberately still decodable as today's payload minus `version` — that is
        // exactly what makes the version marker, not a decode failure, the thing doing
        // the work here.
        let legacyJSON = """
        {"quotasBySource":{"src-1":{"codex":{"pro":{"models":[],"lastUpdated":0,"isForbidden":false}}}}}
        """
        defaults.set(Data(legacyJSON.utf8), forKey: UserDefaultsRemoteQuotaPoolSnapshotStore.storageKey)
        let store = UserDefaultsRemoteQuotaPoolSnapshotStore(defaults: defaults)

        XCTAssertTrue(
            store.load().quotasBySource.isEmpty,
            "a v1 plan-group aggregate must never load back as a per-account entry"
        )
    }

    /// Discarding the stale cache must not reach beyond it: the source list and its
    /// management key live under their own keys and have to survive untouched.
    func testDiscardingLegacySnapshotLeavesSourcesAndCredentialsAlone() async {
        let defaults = makeDefaults()
        let legacyJSON = #"{"quotasBySource":{"src-1":{"codex":{"pro":{"models":[],"lastUpdated":0,"isForbidden":false}}}}}"#
        defaults.set(Data(legacyJSON.utf8), forKey: UserDefaultsRemoteQuotaPoolSnapshotStore.storageKey)
        let repository = UserDefaultsRemoteQuotaSourceRepository(defaults: defaults)
        repository.save([RemoteQuotaSourceConfig(id: "src-1", name: "Pool", baseURL: "https://a.test")])
        let vault = KeychainRemoteQuotaSourceCredentialVault(dataStore: MemoryCredentialDataStore())
        _ = await vault.saveManagementKey("admin-key", sourceId: "src-1")

        _ = UserDefaultsRemoteQuotaPoolSnapshotStore(defaults: defaults).load()

        XCTAssertEqual(repository.load().map(\.id), ["src-1"])
        let storedKey = await vault.loadManagementKey(sourceId: "src-1")
        XCTAssertEqual(storedKey, "admin-key")
    }

    func testSaveThenLoadRoundTripsCurrentVersionSnapshot() {
        let defaults = makeDefaults()
        let store = UserDefaultsRemoteQuotaPoolSnapshotStore(defaults: defaults)
        let quota = ProviderQuota(models: [QuotaMetric(name: "usage", percentage: 42, resetTime: "")])
        store.save(RemoteQuotaPoolSnapshot(quotasBySource: ["src-1": [.codex: ["acct-a": quota]]]))

        let loaded = UserDefaultsRemoteQuotaPoolSnapshotStore(defaults: defaults).load()

        XCTAssertEqual(loaded.quotasBySource["src-1"]?[.codex]?["acct-a"]?.models.first?.percentage, 42)
    }

    // MARK: - Helpers

    private func makeDefaults() -> UserDefaults {
        let suiteName = "RemoteQuotaSourceAdaptersTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}

// MARK: - Test doubles

private actor MemoryCredentialDataStore: CredentialDataStoring {
    private var storage: [String: Data] = [:]

    func read(accountID: String) async -> CredentialDataRecord? {
        storage[accountID].map { CredentialDataRecord(data: $0, generation: "g") }
    }

    func save(_ data: Data, accountID: String) async -> CredentialDataRecord? {
        storage[accountID] = data
        return CredentialDataRecord(data: data, generation: "g")
    }

    func compareAndSwap(_ data: Data, accountID: String, expectedGeneration: String) async -> CredentialDataRecord? {
        guard storage[accountID] != nil else { return nil }
        storage[accountID] = data
        return CredentialDataRecord(data: data, generation: "g")
    }

    func delete(accountID: String) async {
        storage.removeValue(forKey: accountID)
    }
}

private actor MemoryLegacyKeychainReader: LegacyKeychainReading {
    private var store: [String: [String: String]]

    init(store: [String: [String: String]]) {
        self.store = store
    }

    func read(service: String, account: String) async -> String? {
        store[service]?[account]
    }
}
