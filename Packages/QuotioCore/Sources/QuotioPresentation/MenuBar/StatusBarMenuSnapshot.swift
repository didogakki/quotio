import Foundation
import QuotioApplication
import QuotioDomain

/// Where one menu bar account row's quota came from — a local, directly-fetched
/// account, or one real account fetched from a configured remote quota source. Never
/// represents an aggregated pool; each remote-origin snapshot is one real account.
enum StatusBarMenuAccountOrigin: Equatable, Sendable {
    case local
    case remote(sourceId: String, sourceName: String)
}

struct StatusBarMenuAccountSnapshot: Equatable, Sendable {
    let id: QuotaAccountID
    let email: String
    let quota: ProviderQuota
    let subscription: QuotaSubscriptionInfo?
    let isActiveInIDE: Bool
    let isRefreshing: Bool
    let isRefreshBlocked: Bool
    let origin: StatusBarMenuAccountOrigin
}

/// One source-of-truth grouping within a provider's account list — the local group (if
/// any local accounts exist) followed by one group per remote source that currently has
/// visible accounts for this provider. Grouping accounts this way (rather than one flat
/// list) is what lets the menu keep local and remote accounts from different sources
/// visually distinct even when a raw account key/email happens to repeat across them.
struct StatusBarMenuAccountGroup: Equatable, Sendable, Identifiable {
    let origin: StatusBarMenuAccountOrigin
    let accounts: [StatusBarMenuAccountSnapshot]

    var id: String {
        switch origin {
        case .local: "local"
        case .remote(let sourceId, _): "remote:\(sourceId)"
        }
    }
}

struct StatusBarMenuProviderSnapshot: Equatable, Sendable {
    let provider: QuotaProvider
    let groups: [StatusBarMenuAccountGroup]
    let isRefreshing: Bool
    let supportsScopedRefresh: Bool

    /// Flattened view for callers that only need the raw account list (e.g. the empty
    /// state check), irrespective of local/remote grouping.
    var accounts: [StatusBarMenuAccountSnapshot] { groups.flatMap(\.accounts) }
}

struct StatusBarMenuDisplaySettings: Equatable, Sendable {
    let quotaDisplayMode: QuotaDisplayMode
    let quotaDisplayStyle: QuotaDisplayStyle
    let hideSensitiveInfo: Bool
    let modelAggregationMode: ModelAggregationMode

    func aggregateModelPercentages(_ percentages: [Double]) -> Double {
        let validPercentages = percentages.filter { $0 >= 0 }
        guard !validPercentages.isEmpty else { return -1 }

        switch modelAggregationMode {
        case .lowest:
            return validPercentages.min() ?? -1
        case .average:
            return validPercentages.reduce(0, +) / Double(validPercentages.count)
        }
    }
}

public struct StatusBarMenuSnapshot: Equatable, Sendable {
    let isLocalProxyMode: Bool
    let proxyPort: UInt16
    let isProxyRunning: Bool
    let tunnel: CloudflareTunnelSnapshot
    let providers: [StatusBarMenuProviderSnapshot]
    let selectedProvider: QuotaProvider?
    let isLoadingQuotas: Bool
    let displaySettings: StatusBarMenuDisplaySettings
    let appearanceMode: AppearanceMode
    let language: AppLanguage
}

public enum StatusBarMenuSnapshotMapper {
    nonisolated public static func makeSnapshot(
        mode: OperatingMode,
        proxyPort: UInt16,
        isProxyRunning: Bool,
        tunnel: CloudflareTunnelSnapshot,
        directAuthProviders: Set<QuotaProvider>,
        monitorAccounts: [Account],
        quota: QuotaSnapshot,
        installedAgents: Set<CLIAgent>,
        activeAntigravityEmail: String?,
        menuBarPreferences: MenuBarPreferences,
        appearanceMode: AppearanceMode,
        language: AppLanguage,
        remoteSourceNames: [String: String] = [:],
        isRemoteRefreshing: Bool = false,
        hiddenDropdownKeys: Set<String> = []
    ) -> StatusBarMenuSnapshot {
        var availableProviders = directAuthProviders
        availableProviders.formUnion(quota.quotas.compactMap { provider, accounts in
            accounts.isEmpty ? nil : provider
        })
        if mode == .monitor {
            availableProviders.formUnion(monitorProviders(monitorAccounts))
        }

        let providers = filterProviders(
            availableProviders,
            isMonitorMode: mode == .monitor,
            installedAgents: installedAgents
        ).map { provider in
            let groups = accountGroups(
                quota.quotas[provider] ?? [:],
                provider: provider,
                activeAntigravityEmail: activeAntigravityEmail,
                remoteSourceNames: remoteSourceNames,
                hiddenDropdownKeys: hiddenDropdownKeys
            ).map { group in
                StatusBarMenuAccountGroup(
                    origin: group.origin,
                    accounts: group.accounts.map { account in
                        let accountID = QuotaAccountID(provider: provider, accountKey: account.accountKey)
                        return StatusBarMenuAccountSnapshot(
                            id: accountID,
                            email: account.email,
                            quota: account.data,
                            subscription: quota.subscriptions[provider]?[account.accountKey],
                            isActiveInIDE: group.origin == .local && provider == .antigravity
                                && emailsMatch(account.email, activeAntigravityEmail),
                            isRefreshing: group.origin == .local
                                ? quota.refreshingProviders.contains(provider)
                                : isRemoteRefreshing,
                            isRefreshBlocked: group.origin == .local
                                ? quota.refreshingProviders.contains(provider)
                                : isRemoteRefreshing,
                            origin: group.origin
                        )
                    }
                )
            }
            return StatusBarMenuProviderSnapshot(
                provider: provider,
                groups: groups,
                isRefreshing: quota.refreshingProviders.contains(provider),
                supportsScopedRefresh: provider.supportsQuotaOnlyMode
            )
        }

        return StatusBarMenuSnapshot(
            isLocalProxyMode: mode == .localProxy,
            proxyPort: proxyPort,
            isProxyRunning: isProxyRunning,
            tunnel: tunnel,
            providers: providers,
            selectedProvider: menuBarPreferences.selectedProvider.flatMap { selected in
                providers.contains(where: { $0.provider == selected }) ? selected : nil
            },
            isLoadingQuotas: !quota.refreshingProviders.isEmpty,
            displaySettings: StatusBarMenuDisplaySettings(
                quotaDisplayMode: menuBarPreferences.quotaDisplayMode,
                quotaDisplayStyle: menuBarPreferences.quotaDisplayStyle,
                hideSensitiveInfo: menuBarPreferences.hideSensitiveInfo,
                modelAggregationMode: menuBarPreferences.modelAggregationMode
            ),
            appearanceMode: appearanceMode,
            language: language
        )
    }

    nonisolated static func monitorProviders(_ accounts: [Account]) -> Set<QuotaProvider> {
        Set(accounts.lazy.filter { !$0.isDisabled }.map(\.provider))
    }

    nonisolated static func filterProviders(
        _ providers: Set<QuotaProvider>,
        isMonitorMode: Bool,
        installedAgents: Set<CLIAgent>
    ) -> [QuotaProvider] {
        let sorted = providers.sorted { $0.displayName < $1.displayName }
        guard !isMonitorMode else { return sorted }
        return sorted.filter { provider in
            guard let agent = provider.cliAgent else { return true }
            return installedAgents.contains(agent)
        }
    }

    /// Splits one provider's merged quota dictionary (local accounts and, in Monitor
    /// mode, real accounts from every visible remote source, all merged by
    /// `CompositionRoot`) into ordered groups: the local group first (if any local
    /// accounts exist), then one group per remote source — sorted by that source's own
    /// display name — each containing its real per-account entries sorted by email.
    /// Detecting remote origin from the key itself (rather than a passed-in flag) keeps
    /// this pure and testable without threading extra per-key metadata through.
    ///
    /// `hiddenDropdownKeys` drops individually-hidden real accounts — local or remote —
    /// from this dropdown listing: a display-only filter that never reaches the quota
    /// dictionary itself, so fetch/refresh and every other consumer of `quotas` are
    /// unaffected. Entries are matched by `MenuBarQuotaItem.id` (built the same way the
    /// dropdown's own toggle button builds it from an `AccountRowData`) rather than the
    /// raw `key`, so a raw key/email that happens to repeat across providers or between
    /// a local and a remote account can never cause an unrelated account to be hidden. A
    /// remote source whose every account ends up hidden this way contributes no group at
    /// all, rather than an empty one.
    nonisolated static func accountGroups(
        _ quotas: [String: ProviderQuota],
        provider: QuotaProvider,
        activeAntigravityEmail: String?,
        remoteSourceNames: [String: String],
        hiddenDropdownKeys: Set<String> = []
    ) -> [(origin: StatusBarMenuAccountOrigin, accounts: [(accountKey: String, email: String, data: ProviderQuota)])] {
        var localEntries: [(accountKey: String, email: String, data: ProviderQuota)] = []
        var remoteEntriesBySource: [String: [(accountKey: String, email: String, data: ProviderQuota)]] = [:]
        var remoteSourceOrder: [String] = []

        for (key, data) in quotas {
            if let components = RemoteQuotaAccountIdentity.components(fromStorageKey: key) {
                let itemId = MenuBarQuotaItem(
                    provider: provider.rawValue,
                    accountKey: key,
                    sourceConfigId: components.sourceId
                ).id
                guard !hiddenDropdownKeys.contains(itemId) else { continue }
                let entry = (accountKey: key, email: data.accountDisplayName ?? components.accountKey, data: data)
                if remoteEntriesBySource[components.sourceId] == nil {
                    remoteSourceOrder.append(components.sourceId)
                }
                remoteEntriesBySource[components.sourceId, default: []].append(entry)
            } else {
                let itemId = MenuBarQuotaItem(provider: provider.rawValue, accountKey: key, sourceConfigId: nil).id
                guard !hiddenDropdownKeys.contains(itemId) else { continue }
                localEntries.append((accountKey: key, email: data.accountDisplayName ?? key, data: data))
            }
        }

        func ordered(
            _ entries: [(accountKey: String, email: String, data: ProviderQuota)]
        ) -> [(accountKey: String, email: String, data: ProviderQuota)] {
            let sorted = entries.sorted { $0.email < $1.email }
            guard provider == .antigravity else { return sorted }
            return AccountSorting.prioritizingActive(sorted) {
                emailsMatch($0.email, activeAntigravityEmail)
            }
        }

        var groups: [(origin: StatusBarMenuAccountOrigin, accounts: [(accountKey: String, email: String, data: ProviderQuota)])] = []
        if !localEntries.isEmpty {
            groups.append((origin: .local, accounts: ordered(localEntries)))
        }
        for sourceId in remoteSourceOrder.sorted(by: {
            (remoteSourceNames[$0] ?? $0) < (remoteSourceNames[$1] ?? $1)
        }) {
            guard let entries = remoteEntriesBySource[sourceId] else { continue }
            let sourceName = remoteSourceNames[sourceId] ?? sourceId
            groups.append((origin: .remote(sourceId: sourceId, sourceName: sourceName), accounts: ordered(entries)))
        }
        return groups
    }

    nonisolated private static func emailsMatch(_ email: String, _ activeEmail: String?) -> Bool {
        guard let activeEmail, !email.isEmpty, !activeEmail.isEmpty else { return false }
        return email.caseInsensitiveCompare(activeEmail) == .orderedSame
    }
}
