import AppKit
import QuotioApplication
import QuotioDomain
import XCTest

@testable import QuotioPresentation

@MainActor
final class StatusBarMenuSnapshotMapperTests: XCTestCase {
    func testMonitorSnapshotMapsProvidersAccountsStateAndDisplaySettings() throws {
        let enabledMonitorAccount = Account.make(
            providerID: AccountProviderID(rawValue: QuotaProvider.amp.rawValue),
            accountKey: "monitor@example.com",
            source: .nativeCredential
        )
        let disabledMonitorAccount = Account.make(
            providerID: AccountProviderID(rawValue: QuotaProvider.codex.rawValue),
            accountKey: "disabled@example.com",
            source: .nativeCredential,
            status: .disabled
        )
        let tunnel = CloudflareTunnelSnapshot(
            status: .active,
            publicURL: "https://example.trycloudflare.com",
            startTime: Date(timeIntervalSince1970: 1_000),
            installation: CloudflaredInstallation(
                isInstalled: true,
                path: "/usr/local/bin/cloudflared",
                version: "2026.9.0"
            )
        )
        let quota = QuotaSnapshot(
            quotas: [
                .antigravity: [
                    "alpha-key": ProviderQuota(accountDisplayName: "alpha@example.com"),
                    "zulu-key": ProviderQuota(accountDisplayName: "Zulu@example.com"),
                ],
                .claude: [
                    "claude-key": ProviderQuota(accountDisplayName: "claude@example.com"),
                ],
            ],
            refreshingProviders: [.antigravity]
        )
        let preferences = MenuBarPreferences(
            selectedProvider: .amp,
            quotaDisplayMode: .remaining,
            quotaDisplayStyle: .ring,
            hideSensitiveInfo: true,
            modelAggregationMode: .average
        )

        let snapshot = StatusBarMenuSnapshotMapper.makeSnapshot(
            mode: .monitor,
            proxyPort: 8317,
            isProxyRunning: true,
            tunnel: tunnel,
            directAuthProviders: [.antigravity, .claude],
            monitorAccounts: [enabledMonitorAccount, disabledMonitorAccount],
            quota: quota,
            installedAgents: [],
            activeAntigravityEmail: "zulu@example.com",
            menuBarPreferences: preferences,
            appearanceMode: .dark,
            language: .vietnamese
        )

        XCTAssertFalse(snapshot.isLocalProxyMode)
        XCTAssertEqual(snapshot.proxyPort, 8317)
        XCTAssertTrue(snapshot.isProxyRunning)
        XCTAssertEqual(snapshot.tunnel, tunnel)
        XCTAssertEqual(snapshot.providers.map(\.provider), [.amp, .antigravity, .claude])
        XCTAssertEqual(snapshot.selectedProvider, .amp)
        XCTAssertTrue(snapshot.isLoadingQuotas)
        XCTAssertEqual(snapshot.displaySettings.quotaDisplayMode, .remaining)
        XCTAssertEqual(snapshot.displaySettings.quotaDisplayStyle, .ring)
        XCTAssertTrue(snapshot.displaySettings.hideSensitiveInfo)
        XCTAssertEqual(snapshot.displaySettings.modelAggregationMode, .average)
        XCTAssertEqual(snapshot.appearanceMode, .dark)
        XCTAssertEqual(snapshot.language, .vietnamese)

        let antigravity = try XCTUnwrap(snapshot.providers.first { $0.provider == .antigravity })
        XCTAssertTrue(antigravity.isRefreshing)
        XCTAssertTrue(antigravity.supportsScopedRefresh)
        XCTAssertEqual(antigravity.accounts.map(\.email), [
            "Zulu@example.com",
            "alpha@example.com",
        ])
        XCTAssertTrue(antigravity.accounts[0].isActiveInIDE)
        XCTAssertTrue(antigravity.accounts.allSatisfy(\.isRefreshing))
        XCTAssertTrue(antigravity.accounts.allSatisfy(\.isRefreshBlocked))
    }

    func testMonitorSnapshotPreservesRemoteOAuthIssueForTheDropdownCard() throws {
        let storageKey = RemoteQuotaAccountIdentity.storageKey(sourceId: "src-1", accountKey: "codex-a")
        let quota = QuotaSnapshot(quotas: [
            .codex: [
                storageKey: ProviderQuota(
                    accountDisplayName: "a@example.com",
                    remoteAccountIssue: .invalidOAuth
                ),
            ],
        ])

        let snapshot = StatusBarMenuSnapshotMapper.makeSnapshot(
            mode: .monitor,
            proxyPort: 8317,
            isProxyRunning: false,
            tunnel: CloudflareTunnelSnapshot(),
            directAuthProviders: [],
            monitorAccounts: [],
            quota: quota,
            installedAgents: [],
            activeAntigravityEmail: nil,
            menuBarPreferences: MenuBarPreferences(selectedProvider: .codex),
            appearanceMode: .system,
            language: .chinese,
            remoteSourceNames: ["src-1": "Business"]
        )

        let codex = try XCTUnwrap(snapshot.providers.first { $0.provider == .codex })
        let account = try XCTUnwrap(codex.accounts.first)
        XCTAssertEqual(account.email, "a@example.com")
        XCTAssertEqual(account.quota.remoteAccountIssue, .invalidOAuth)
        XCTAssertEqual(account.quota.availabilityStatus, .authInvalid)
    }

    func testLocalProxySnapshotFiltersCLIProvidersByInstalledAgents() {
        let snapshot = StatusBarMenuSnapshotMapper.makeSnapshot(
            mode: .localProxy,
            proxyPort: 8317,
            isProxyRunning: false,
            tunnel: CloudflareTunnelSnapshot(),
            directAuthProviders: [.antigravity, .claude, .codex],
            monitorAccounts: [],
            quota: QuotaSnapshot(),
            installedAgents: [.codexCLI],
            activeAntigravityEmail: nil,
            menuBarPreferences: MenuBarPreferences(selectedProvider: .claude),
            appearanceMode: .system,
            language: .english
        )

        XCTAssertTrue(snapshot.isLocalProxyMode)
        XCTAssertEqual(snapshot.providers.map(\.provider), [.antigravity, .codex])
        XCTAssertNil(snapshot.selectedProvider)
    }

    /// The dropdown must group by source (local, then each remote source) within one
    /// provider — never a flat merged list — and a remote account must never be
    /// confused with a local account that happens to share the same raw key/email.
    func testMonitorSnapshotGroupsLocalAndRemoteAccountsSeparatelyWithinOneProvider() throws {
        let sharedRemoteKey = RemoteQuotaAccountIdentity.storageKey(sourceId: "src-1", accountKey: "same@example.com")
        let quota = QuotaSnapshot(quotas: [
            .claude: [
                "same@example.com": ProviderQuota(accountDisplayName: "same@example.com"),
                sharedRemoteKey: ProviderQuota(accountDisplayName: "same@example.com"),
            ],
        ])

        let snapshot = StatusBarMenuSnapshotMapper.makeSnapshot(
            mode: .monitor,
            proxyPort: 8317,
            isProxyRunning: false,
            tunnel: CloudflareTunnelSnapshot(),
            directAuthProviders: [.claude],
            monitorAccounts: [],
            quota: quota,
            installedAgents: [],
            activeAntigravityEmail: nil,
            menuBarPreferences: MenuBarPreferences(),
            appearanceMode: .system,
            language: .english,
            remoteSourceNames: ["src-1": "My Server"]
        )

        let claude = try XCTUnwrap(snapshot.providers.first { $0.provider == .claude })
        XCTAssertEqual(claude.groups.count, 2, "local and remote must be separate groups, never merged")
        XCTAssertEqual(claude.groups[0].origin, .local)
        XCTAssertEqual(claude.groups[0].accounts.count, 1)
        XCTAssertEqual(claude.groups[1].origin, .remote(sourceId: "src-1", sourceName: "My Server"))
        XCTAssertEqual(claude.groups[1].accounts.count, 1)
        // Same email on both sides must not collapse into one row.
        XCTAssertEqual(claude.accounts.count, 2)
    }

    /// Remote accounts must never drive local refresh/IDE-switch semantics: their
    /// `isRefreshing`/`isRefreshBlocked` reflect the remote refresh flag passed in, not
    /// the local provider's `refreshingProviders` set.
    func testRemoteGroupUsesRemoteRefreshingFlagNotLocalProviderRefreshState() throws {
        let remoteKey = RemoteQuotaAccountIdentity.storageKey(sourceId: "src-1", accountKey: "acct-a")
        let quota = QuotaSnapshot(
            quotas: [.claude: [remoteKey: ProviderQuota(accountDisplayName: "remote@example.com")]],
            refreshingProviders: []
        )

        let snapshot = StatusBarMenuSnapshotMapper.makeSnapshot(
            mode: .monitor,
            proxyPort: 8317,
            isProxyRunning: false,
            tunnel: CloudflareTunnelSnapshot(),
            directAuthProviders: [.claude],
            monitorAccounts: [],
            quota: quota,
            installedAgents: [],
            activeAntigravityEmail: nil,
            menuBarPreferences: MenuBarPreferences(),
            appearanceMode: .system,
            language: .english,
            remoteSourceNames: ["src-1": "My Server"],
            isRemoteRefreshing: true
        )

        let claude = try XCTUnwrap(snapshot.providers.first { $0.provider == .claude })
        let account = try XCTUnwrap(claude.accounts.first)
        XCTAssertTrue(account.isRefreshing)
        XCTAssertTrue(account.isRefreshBlocked)
        XCTAssertEqual(account.origin, .remote(sourceId: "src-1", sourceName: "My Server"))
    }

    /// A remote account hidden from the dropdown must disappear from this listing —
    /// while `quota.quotas` (the dictionary fetch/refresh/CompositionRoot's own merge
    /// still see) is untouched, since the filter only ever runs on the copy the mapper
    /// builds groups from. The hidden set is keyed by the same `MenuBarQuotaItem.id`
    /// the dropdown's own toggle button computes from an `AccountRowData`.
    func testHiddenRemoteAccountIsExcludedFromItsProviderGroup() throws {
        let visibleKey = RemoteQuotaAccountIdentity.storageKey(sourceId: "src-1", accountKey: "visible")
        let hiddenKey = RemoteQuotaAccountIdentity.storageKey(sourceId: "src-1", accountKey: "hidden")
        let quota = QuotaSnapshot(quotas: [
            .claude: [
                visibleKey: ProviderQuota(accountDisplayName: "visible@example.com"),
                hiddenKey: ProviderQuota(accountDisplayName: "hidden@example.com"),
            ],
        ])
        let hiddenItemId = MenuBarQuotaItem(provider: "claude", accountKey: hiddenKey, sourceConfigId: "src-1").id

        let snapshot = StatusBarMenuSnapshotMapper.makeSnapshot(
            mode: .monitor,
            proxyPort: 8317,
            isProxyRunning: false,
            tunnel: CloudflareTunnelSnapshot(),
            directAuthProviders: [.claude],
            monitorAccounts: [],
            quota: quota,
            installedAgents: [],
            activeAntigravityEmail: nil,
            menuBarPreferences: MenuBarPreferences(),
            appearanceMode: .system,
            language: .english,
            remoteSourceNames: ["src-1": "My Server"],
            hiddenDropdownKeys: [hiddenItemId]
        )

        let claude = try XCTUnwrap(snapshot.providers.first { $0.provider == .claude })
        XCTAssertEqual(claude.accounts.map(\.email), ["visible@example.com"])
        // The dictionary itself must still carry both entries — only the mapper's own
        // output is filtered, never the source data fetch/refresh reads.
        XCTAssertEqual(quota.quotas[.claude]?.count, 2)
    }

    /// When every account in a remote source's group is hidden, that source must
    /// contribute no group at all — never an empty one.
    func testSourceWithEveryAccountHiddenContributesNoGroup() throws {
        let hiddenKey = RemoteQuotaAccountIdentity.storageKey(sourceId: "src-1", accountKey: "hidden")
        let quota = QuotaSnapshot(quotas: [
            .claude: [
                "local-key": ProviderQuota(accountDisplayName: "local@example.com"),
                hiddenKey: ProviderQuota(accountDisplayName: "hidden@example.com"),
            ],
        ])
        let hiddenItemId = MenuBarQuotaItem(provider: "claude", accountKey: hiddenKey, sourceConfigId: "src-1").id

        let snapshot = StatusBarMenuSnapshotMapper.makeSnapshot(
            mode: .monitor,
            proxyPort: 8317,
            isProxyRunning: false,
            tunnel: CloudflareTunnelSnapshot(),
            directAuthProviders: [.claude],
            monitorAccounts: [],
            quota: quota,
            installedAgents: [],
            activeAntigravityEmail: nil,
            menuBarPreferences: MenuBarPreferences(),
            appearanceMode: .system,
            language: .english,
            remoteSourceNames: ["src-1": "My Server"],
            hiddenDropdownKeys: [hiddenItemId]
        )

        let claude = try XCTUnwrap(snapshot.providers.first { $0.provider == .claude })
        XCTAssertEqual(claude.groups.count, 1, "the fully-hidden remote source must not appear as an empty group")
        XCTAssertEqual(claude.groups[0].origin, .local)
    }

    /// A custom `sourceGroupOrder` must reorder the dropdown's remote-source subgroups
    /// within one provider — the same persisted order the status bar icon's own pinned
    /// items use (`RemoteQuotaSourceGroupOrdering.orderedSelectedItems`), so both share
    /// one arrangement instead of the dropdown staying stuck on alphabetical-by-name.
    func testMonitorSnapshotOrdersRemoteSourceGroupsByPersistedOrder() throws {
        let businessKey = RemoteQuotaAccountIdentity.storageKey(sourceId: "business", accountKey: "b")
        let plusKey = RemoteQuotaAccountIdentity.storageKey(sourceId: "plus", accountKey: "a")
        let quota = QuotaSnapshot(quotas: [
            .codex: [
                businessKey: ProviderQuota(accountDisplayName: "business@example.com"),
                plusKey: ProviderQuota(accountDisplayName: "plus@example.com"),
            ],
        ])
        // Alphabetically "Business" would sort before "Plus" — the persisted order must
        // override that default.
        let preferences = MenuBarPreferences(
            sourceGroupOrder: [RemoteQuotaSourceGroupIdentity.key(sourceId: "plus", provider: .codex)]
        )

        let snapshot = StatusBarMenuSnapshotMapper.makeSnapshot(
            mode: .monitor,
            proxyPort: 8317,
            isProxyRunning: false,
            tunnel: CloudflareTunnelSnapshot(),
            directAuthProviders: [.codex],
            monitorAccounts: [],
            quota: quota,
            installedAgents: [],
            activeAntigravityEmail: nil,
            menuBarPreferences: preferences,
            appearanceMode: .system,
            language: .english,
            remoteSourceNames: ["business": "Business", "plus": "Plus"]
        )

        let codex = try XCTUnwrap(snapshot.providers.first { $0.provider == .codex })
        XCTAssertEqual(
            codex.groups.map(\.origin),
            [.remote(sourceId: "plus", sourceName: "Plus"), .remote(sourceId: "business", sourceName: "Business")]
        )
    }

    /// A custom `accountOrder` must reorder the accounts *inside* one dropdown group —
    /// the order the user arranged on the Accounts page — instead of the group staying
    /// stuck on alphabetical-by-email. An account with no persisted rank keeps that
    /// alphabetical fallback and sorts after the ones the user placed.
    func testMonitorSnapshotOrdersAccountsWithinAGroupByPersistedOrder() throws {
        let keys = ["a", "b", "c"].map {
            RemoteQuotaAccountIdentity.storageKey(sourceId: "plus", accountKey: $0)
        }
        let quota = QuotaSnapshot(quotas: [
            .codex: [
                keys[0]: ProviderQuota(accountDisplayName: "a@example.com"),
                keys[1]: ProviderQuota(accountDisplayName: "b@example.com"),
                keys[2]: ProviderQuota(accountDisplayName: "c@example.com"),
            ],
        ])
        let itemId: (String) -> String = {
            MenuBarQuotaItem(provider: QuotaProvider.codex.rawValue, accountKey: $0, sourceConfigId: "plus").id
        }
        // "c" then "b" explicitly placed; "a" never ranked, so it keeps the fallback.
        let preferences = MenuBarPreferences(accountOrder: [itemId(keys[2]), itemId(keys[1])])

        let snapshot = StatusBarMenuSnapshotMapper.makeSnapshot(
            mode: .monitor,
            proxyPort: 8317,
            isProxyRunning: false,
            tunnel: CloudflareTunnelSnapshot(),
            directAuthProviders: [.codex],
            monitorAccounts: [],
            quota: quota,
            installedAgents: [],
            activeAntigravityEmail: nil,
            menuBarPreferences: preferences,
            appearanceMode: .system,
            language: .english,
            remoteSourceNames: ["plus": "Plus"]
        )

        let codex = try XCTUnwrap(snapshot.providers.first { $0.provider == .codex })
        XCTAssertEqual(
            codex.groups.first?.accounts.map(\.email),
            ["c@example.com", "b@example.com", "a@example.com"]
        )
    }

    /// One group's `accountOrder` entries must never reach another group: a remote
    /// account and a local account are keyed by distinct `MenuBarQuotaItem.id`s, so
    /// ranking the remote one leaves the local group on its own alphabetical sort.
    func testAccountOrderNeverLeaksAcrossGroups() throws {
        let remoteKey = RemoteQuotaAccountIdentity.storageKey(sourceId: "plus", accountKey: "z")
        let quota = QuotaSnapshot(quotas: [
            .codex: [
                "local-b": ProviderQuota(accountDisplayName: "b@example.com"),
                "local-a": ProviderQuota(accountDisplayName: "a@example.com"),
                remoteKey: ProviderQuota(accountDisplayName: "z@example.com"),
            ],
        ])
        let preferences = MenuBarPreferences(accountOrder: [
            MenuBarQuotaItem(provider: QuotaProvider.codex.rawValue, accountKey: remoteKey, sourceConfigId: "plus").id
        ])

        let snapshot = StatusBarMenuSnapshotMapper.makeSnapshot(
            mode: .monitor,
            proxyPort: 8317,
            isProxyRunning: false,
            tunnel: CloudflareTunnelSnapshot(),
            directAuthProviders: [.codex],
            monitorAccounts: [],
            quota: quota,
            installedAgents: [],
            activeAntigravityEmail: nil,
            menuBarPreferences: preferences,
            appearanceMode: .system,
            language: .english,
            remoteSourceNames: ["plus": "Plus"]
        )

        let codex = try XCTUnwrap(snapshot.providers.first { $0.provider == .codex })
        XCTAssertEqual(codex.groups.first?.origin, .local)
        XCTAssertEqual(codex.groups.first?.accounts.map(\.email), ["a@example.com", "b@example.com"])
    }

    /// A raw account key/email that happens to also appear (verbatim, with no provider
    /// namespacing) in `hiddenDropdownKeys` must never accidentally match — entries only
    /// ever match by the full `MenuBarQuotaItem.id`, so a bare string collision is inert.
    func testRawKeyInHiddenSetNeverAccidentallyMatchesAnAccount() throws {
        let quota = QuotaSnapshot(quotas: [
            .claude: ["local-key": ProviderQuota(accountDisplayName: "local@example.com")],
        ])

        let snapshot = StatusBarMenuSnapshotMapper.makeSnapshot(
            mode: .monitor,
            proxyPort: 8317,
            isProxyRunning: false,
            tunnel: CloudflareTunnelSnapshot(),
            directAuthProviders: [.claude],
            monitorAccounts: [],
            quota: quota,
            installedAgents: [],
            activeAntigravityEmail: nil,
            menuBarPreferences: MenuBarPreferences(),
            appearanceMode: .system,
            language: .english,
            hiddenDropdownKeys: ["local-key"]
        )

        let claude = try XCTUnwrap(snapshot.providers.first { $0.provider == .claude })
        XCTAssertEqual(claude.accounts.map(\.email), ["local@example.com"])
    }

    /// Local accounts now get the same dropdown-visibility filter as remote ones, keyed
    /// by their own `MenuBarQuotaItem.id` (provider + raw account key, no source id).
    func testHiddenDropdownKeyFiltersALocalAccountToo() throws {
        let quota = QuotaSnapshot(quotas: [
            .claude: [
                "visible-key": ProviderQuota(accountDisplayName: "visible@example.com"),
                "hidden-key": ProviderQuota(accountDisplayName: "hidden@example.com"),
            ],
        ])
        let hiddenItemId = MenuBarQuotaItem(provider: "claude", accountKey: "hidden-key").id

        let snapshot = StatusBarMenuSnapshotMapper.makeSnapshot(
            mode: .monitor,
            proxyPort: 8317,
            isProxyRunning: false,
            tunnel: CloudflareTunnelSnapshot(),
            directAuthProviders: [.claude],
            monitorAccounts: [],
            quota: quota,
            installedAgents: [],
            activeAntigravityEmail: nil,
            menuBarPreferences: MenuBarPreferences(),
            appearanceMode: .system,
            language: .english,
            hiddenDropdownKeys: [hiddenItemId]
        )

        let claude = try XCTUnwrap(snapshot.providers.first { $0.provider == .claude })
        XCTAssertEqual(claude.accounts.map(\.email), ["visible@example.com"])
    }

    /// The same raw account key hidden under one provider must not hide the equivalent
    /// key under a different provider — `MenuBarQuotaItem.id` namespaces by provider.
    func testHidingALocalAccountUnderOneProviderDoesNotHideItUnderAnother() throws {
        let quota = QuotaSnapshot(quotas: [
            .claude: ["shared-key": ProviderQuota(accountDisplayName: "shared@example.com")],
            .codex: ["shared-key": ProviderQuota(accountDisplayName: "shared@example.com")],
        ])
        let hiddenItemId = MenuBarQuotaItem(provider: "claude", accountKey: "shared-key").id

        let snapshot = StatusBarMenuSnapshotMapper.makeSnapshot(
            mode: .monitor,
            proxyPort: 8317,
            isProxyRunning: false,
            tunnel: CloudflareTunnelSnapshot(),
            directAuthProviders: [.claude, .codex],
            monitorAccounts: [],
            quota: quota,
            installedAgents: [],
            activeAntigravityEmail: nil,
            menuBarPreferences: MenuBarPreferences(),
            appearanceMode: .system,
            language: .english,
            hiddenDropdownKeys: [hiddenItemId]
        )

        let claude = try XCTUnwrap(snapshot.providers.first { $0.provider == .claude })
        let codex = try XCTUnwrap(snapshot.providers.first { $0.provider == .codex })
        XCTAssertTrue(claude.accounts.isEmpty)
        XCTAssertEqual(codex.accounts.map(\.email), ["shared@example.com"])
    }
}

@MainActor
final class StatusBarMenuRendererTests: XCTestCase {
    func testSelectedProviderRendersOnlyItsAccountGroup() {
        let unfiltered = makeSnapshot(selectedProvider: nil)
        let filtered = makeSnapshot(selectedProvider: .claude)
        let dispatcher = makeNoopDispatcher()

        let unfilteredMenu = StatusBarMenuRenderer(
            snapshot: unfiltered,
            commands: dispatcher
        ).buildMenu()
        let filteredMenu = StatusBarMenuRenderer(
            snapshot: filtered,
            commands: dispatcher
        ).buildMenu()

        XCTAssertEqual(unfilteredMenu.items.count, 11)
        XCTAssertEqual(unfilteredMenu.items.filter(Self.isDecorativeSeparatorItem).count, 4)
        XCTAssertEqual(filteredMenu.items.count, 7)
        XCTAssertEqual(filteredMenu.items.filter(Self.isDecorativeSeparatorItem).count, 3)
    }

    /// `StatusBarMenuRenderer.separatorItem()` replaced native `NSMenuItem.separator()`
    /// with a custom-view, disabled item so its background matches every other row.
    /// `isSeparatorItem` no longer sees it, so this identifies it the same way the
    /// renderer builds it: a hosted `MenuSeparatorView` on a disabled item.
    private static func isDecorativeSeparatorItem(_ item: NSMenuItem) -> Bool {
        guard !item.isEnabled, let view = item.view else { return false }
        return String(describing: type(of: view)).contains("MenuSeparatorView")
    }

    /// Filtering to one provider must still keep local and remote accounts grouped by
    /// source — a single-provider filter must not silently collapse a source's own
    /// sub-header back into an undifferentiated list.
    func testSingleProviderFilterStillShowsSourceSubheadersWhenMultipleSourcesArePresent() {
        let remoteKey = RemoteQuotaAccountIdentity.storageKey(sourceId: "src-1", accountKey: "acct-a")
        let snapshot = StatusBarMenuSnapshotMapper.makeSnapshot(
            mode: .monitor,
            proxyPort: 8317,
            isProxyRunning: false,
            tunnel: CloudflareTunnelSnapshot(),
            directAuthProviders: [.claude],
            monitorAccounts: [],
            quota: QuotaSnapshot(quotas: [
                .claude: [
                    "local-key": ProviderQuota(accountDisplayName: "local@example.com"),
                    remoteKey: ProviderQuota(accountDisplayName: "remote@example.com"),
                ],
            ]),
            installedAgents: [],
            activeAntigravityEmail: nil,
            menuBarPreferences: MenuBarPreferences(selectedProvider: .claude),
            appearanceMode: .system,
            language: .english,
            remoteSourceNames: ["src-1": "My Server"]
        )

        let menu = StatusBarMenuRenderer(snapshot: snapshot, commands: makeNoopDispatcher()).buildMenu()

        // Header + separator + picker + separator + [subheader, account] x2 + separator + actions
        // = 2 (header) + 2 (picker) + 4 (subheaders+accounts) + 1 (separator) + 1 (actions) = 10
        XCTAssertEqual(menu.items.count, 10)
    }

    private func makeSnapshot(selectedProvider: QuotaProvider?) -> StatusBarMenuSnapshot {
        StatusBarMenuSnapshotMapper.makeSnapshot(
            mode: .monitor,
            proxyPort: 8317,
            isProxyRunning: false,
            tunnel: CloudflareTunnelSnapshot(),
            directAuthProviders: [.claude, .codex],
            monitorAccounts: [],
            quota: QuotaSnapshot(quotas: [
                .claude: [
                    "claude-key": ProviderQuota(accountDisplayName: "claude@example.com"),
                ],
                .codex: [
                    "codex-key": ProviderQuota(accountDisplayName: "codex@example.com"),
                ],
            ]),
            installedAgents: [],
            activeAntigravityEmail: nil,
            menuBarPreferences: MenuBarPreferences(selectedProvider: selectedProvider),
            appearanceMode: .system,
            language: .english
        )
    }

    private func makeNoopDispatcher() -> StatusBarCommandDispatcher {
        StatusBarCommandDispatcher(handlers: StatusBarCommandHandlers(
            refreshAll: {},
            refreshProvider: { _ in },
            refreshAccount: { _ in },
            toggleProxy: {},
            toggleTunnel: { _ in },
            copyText: { _ in },
            switchAntigravityAccount: { _ in },
            isAntigravityIDERunning: { false },
            confirmAntigravitySwitch: { _, _ in true },
            selectProvider: { _ in },
            openApp: {},
            quit: {},
            menuNeedsRebuild: {}
        ))
    }
}

@MainActor
final class StatusBarCommandDispatcherTests: XCTestCase {
    func testAsyncCommandsRouteAndRebuildAfterCompletion() async {
        let recorder = StatusBarCommandRecorder()
        let rebuilds = expectation(description: "menu rebuilt after async commands")
        rebuilds.expectedFulfillmentCount = 6
        let dispatcher = makeDispatcher(recorder: recorder) {
            recorder.rebuildCount += 1
            rebuilds.fulfill()
        }

        dispatcher.dispatch(.refreshAll)
        dispatcher.dispatch(.refreshProvider(.claude))
        dispatcher.dispatch(.refreshAccount(QuotaAccountID(provider: .codex, accountKey: "person@example.com")))
        dispatcher.dispatch(.toggleProxy)
        dispatcher.dispatch(.toggleTunnel(port: 8317))
        dispatcher.dispatch(.useAntigravityAccount(email: "active@example.com"))

        await fulfillment(of: [rebuilds], timeout: 1)
        XCTAssertEqual(Set(recorder.asyncCommands), Set([
            "refreshAll",
            "refreshProvider:claude",
            "refreshAccount:codex:person@example.com",
            "toggleProxy",
            "toggleTunnel:8317",
            "switchAntigravity:active@example.com",
        ]))
        XCTAssertEqual(recorder.rebuildCount, 6)
    }

    func testSynchronousCommandsRouteWithoutUnnecessaryRebuilds() {
        let recorder = StatusBarCommandRecorder()
        let dispatcher = makeDispatcher(recorder: recorder) {
            recorder.rebuildCount += 1
        }

        dispatcher.dispatch(.copyProxyURL("http://localhost:8317"))
        dispatcher.dispatch(.copyTunnelURL("https://example.trycloudflare.com"))
        dispatcher.dispatch(.openApp)
        dispatcher.dispatch(.quit)
        dispatcher.dispatch(.selectProvider(.claude))
        dispatcher.dispatch(.selectProvider(nil))

        XCTAssertEqual(recorder.copiedText, [
            "http://localhost:8317",
            "https://example.trycloudflare.com",
        ])
        XCTAssertEqual(recorder.selectedProviders, [.claude, nil])
        XCTAssertEqual(recorder.openAppCount, 1)
        XCTAssertEqual(recorder.quitCount, 1)
        XCTAssertEqual(recorder.rebuildCount, 0)
    }

    func testCancelledAntigravityConfirmationDoesNotSwitchOrRebuild() {
        let recorder = StatusBarCommandRecorder()
        recorder.confirmSwitch = false
        let dispatcher = makeDispatcher(recorder: recorder) {
            recorder.rebuildCount += 1
        }

        dispatcher.dispatch(.useAntigravityAccount(email: "person@example.com"))

        XCTAssertEqual(recorder.ideRunningChecks, 1)
        XCTAssertEqual(recorder.confirmations, ["person@example.com:true"])
        XCTAssertTrue(recorder.asyncCommands.isEmpty)
        XCTAssertEqual(recorder.rebuildCount, 0)
    }

    private func makeDispatcher(
        recorder: StatusBarCommandRecorder,
        menuNeedsRebuild: @escaping () -> Void
    ) -> StatusBarCommandDispatcher {
        StatusBarCommandDispatcher(handlers: StatusBarCommandHandlers(
            refreshAll: { recorder.asyncCommands.append("refreshAll") },
            refreshProvider: { provider in
                recorder.asyncCommands.append("refreshProvider:\(provider.rawValue)")
            },
            refreshAccount: { account in
                recorder.asyncCommands.append(
                    "refreshAccount:\(account.provider.rawValue):\(account.accountKey)"
                )
            },
            toggleProxy: { recorder.asyncCommands.append("toggleProxy") },
            toggleTunnel: { port in recorder.asyncCommands.append("toggleTunnel:\(port)") },
            copyText: { recorder.copiedText.append($0) },
            switchAntigravityAccount: { email in
                recorder.asyncCommands.append("switchAntigravity:\(email)")
            },
            isAntigravityIDERunning: {
                recorder.ideRunningChecks += 1
                return true
            },
            confirmAntigravitySwitch: { email, isRunning in
                recorder.confirmations.append("\(email):\(isRunning)")
                return recorder.confirmSwitch
            },
            selectProvider: { recorder.selectedProviders.append($0) },
            openApp: { recorder.openAppCount += 1 },
            quit: { recorder.quitCount += 1 },
            menuNeedsRebuild: menuNeedsRebuild
        ))
    }
}

@MainActor
private final class StatusBarCommandRecorder {
    var asyncCommands: [String] = []
    var copiedText: [String] = []
    var confirmations: [String] = []
    var selectedProviders: [QuotaProvider?] = []
    var confirmSwitch = true
    var ideRunningChecks = 0
    var openAppCount = 0
    var quitCount = 0
    var rebuildCount = 0
}
