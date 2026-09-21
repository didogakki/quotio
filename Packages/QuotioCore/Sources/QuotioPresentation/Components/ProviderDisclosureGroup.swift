//
//  ProviderDisclosureGroup.swift
//  Quotio
//
//  Collapsible group for displaying accounts grouped by provider.
//  Part of ProvidersScreen UI/UX redesign.
//

import QuotioApplication
import QuotioDomain
import SwiftUI

// MARK: - Provider Disclosure Group

/// A collapsible disclosure group that displays all accounts for a specific provider
struct ProviderDisclosureGroup: View {
    let provider: QuotaProvider
    let accounts: [AccountRowData]
    var onDeleteAccount: ((AccountRowData) -> Void)?
    var onEditAccount: ((AccountRowData) -> Void)?
    var onSwitchAccount: ((AccountRowData) -> Void)?
    var onToggleDisabled: ((AccountRowData) -> Void)?
    var onDownloadAccount: ((AccountRowData) -> Void)?
    var isAccountActive: ((AccountRowData) -> Bool)?

    @Environment(MenuBarSettingsManager.self) private var settings
    @State private var isExpanded: Bool = true

    /// Check if all accounts in this group are auto-detected
    private var isAllAutoDetected: Bool {
        accounts.allSatisfy { $0.source == .autoDetected }
    }

    /// Real account count for the header badge. Excludes plan-aggregate rows, which are
    /// a derived summary of the real accounts already counted here — not accounts of
    /// their own.
    private var realAccountCount: Int {
        accounts.filter { !$0.source.isAggregate }.count
    }

    /// Whether this row is one real account fetched from a configured remote quota
    /// source — the only kind of row ever nested beneath a plan-aggregate row.
    private func isRemoteQuotaSourceRow(_ account: AccountRowData) -> Bool {
        if case .remoteQuotaSource = account.source { return true }
        return false
    }

    /// One scope the user can reorder accounts within: a maximal run of adjacent real
    /// (non-aggregate) rows sharing the same origin — every local row of this provider,
    /// or the real remote accounts sitting under one plan-aggregate row. Using adjacency
    /// rather than a computed group id is what keeps a move inside the run the caller
    /// already sorted: an aggregate row separates one plan from the next, so an account
    /// can never be moved out from under the aggregate that summarizes it.
    private struct AccountRun {
        let rows: [AccountRowData]
    }

    /// `accounts` split into `AccountRun`s, with each aggregate row kept as a run of its
    /// own so it always stays directly above the accounts it summarizes.
    private var accountRuns: [AccountRun] {
        var runs: [AccountRun] = []
        var index = accounts.startIndex
        while index < accounts.endIndex {
            let account = accounts[index]
            guard !account.source.isAggregate else {
                runs.append(AccountRun(rows: [account]))
                index = accounts.index(after: index)
                continue
            }
            var end = index
            while end < accounts.endIndex,
                  !accounts[end].source.isAggregate,
                  accounts[end].sourceConfigId == account.sourceConfigId {
                end = accounts.index(after: end)
            }
            runs.append(AccountRun(rows: Array(accounts[index..<end])))
            index = end
        }
        return runs
    }

    /// Accounts in their persisted per-group order (see `MenuBarPreferences.accountOrder`,
    /// the same order the menu bar dropdown applies), with the ones currently in use
    /// floated to the top and the existing order as the tie-breaker. Ranks are applied
    /// run by run, never across the whole provider, so reordering one source's accounts
    /// can't move them past another source's rows or past a plan-aggregate row.
    private var displayedAccounts: [AccountRowData] {
        let order = settings.accountOrder
        let ordered = accountRuns.flatMap { run in
            DisplayOrderRanking.sorted(run.rows, order: order, key: \.menuBarItem.id)
        }
        guard let isAccountActive else { return ordered }
        return AccountSorting.prioritizingActive(ordered, isActive: isAccountActive)
    }

    /// The `MenuBarQuotaItem.id`s of every account the user could move this row past —
    /// its own run, in the order it is displayed right now. Empty for an aggregate row
    /// and for a lone account, which have nothing to reorder against.
    private func accountSiblingIds(for account: AccountRowData) -> [String] {
        guard !account.source.isAggregate else { return [] }
        let order = settings.accountOrder
        guard let run = accountRuns.first(where: { $0.rows.contains(account) }), run.rows.count > 1 else {
            return []
        }
        return DisplayOrderRanking.sorted(run.rows, order: order, key: \.menuBarItem.id).map(\.menuBarItem.id)
    }

    /// Every remote-source group key currently visible under this provider — the scope
    /// `MenuBarSettingsManager.moveSourceGroup` moves a source's rank within, so "move
    /// up/down" only ever reorders relative to sources actually shown here right now.
    private var sourceGroupSiblingKeys: [String] {
        var seen = Set<String>()
        var keys: [String] = []
        for account in accounts {
            guard let sourceConfigId = account.sourceConfigId else { continue }
            let key = RemoteQuotaSourceGroupIdentity.key(sourceId: sourceConfigId, provider: provider)
            if seen.insert(key).inserted { keys.append(key) }
        }
        return keys
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            ForEach(displayedAccounts) { account in
                AccountRow(
                    account: account,
                    onDelete: onDeleteAccount != nil ? { onDeleteAccount?(account) } : nil,
                    onEdit: onEditAccount != nil ? { onEditAccount?(account) } : nil,
                    onSwitch: onSwitchAccount != nil ? { onSwitchAccount?(account) } : nil,
                    onToggleDisabled: onToggleDisabled != nil ? { onToggleDisabled?(account) } : nil,
                    onDownload: account.canDownloadAuthFile && onDownloadAccount != nil
                        ? { onDownloadAccount?(account) }
                        : nil,
                    isActiveInIDE: isAccountActive?(account) ?? false,
                    sourceGroupSiblingKeys: sourceGroupSiblingKeys,
                    accountSiblingIds: accountSiblingIds(for: account)
                )
                // A plan-aggregate row stays at the group's base indent, like a
                // sub-header; the real remote accounts it summarizes sit one step
                // further in, so the "aggregate → real accounts" hierarchy reads
                // without needing a different font or row layout.
                .padding(.leading, isRemoteQuotaSourceRow(account) ? 16 : 4)
            }
        } label: {
            providerHeader
        }
    }
    
    // MARK: - Provider Header
    
    private var providerHeader: some View {
        HStack(spacing: 10) {
            // Provider icon
            ProviderIcon(provider: provider, size: 20)
            
            // Provider name
            Text(provider.displayName)
                .fontWeight(.medium)
            
            // Account count badge
            Text("\(realAccountCount)")
                .font(.caption2)
                .fontWeight(.semibold)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(provider.color.opacity(0.15))
                .foregroundStyle(provider.color)
                .clipShape(Capsule())
            
            Spacer()
            
            // Auto-detected indicator (when all accounts are auto-detected)
            if isAllAutoDetected {
                Text("providers.autoDetected".localized())
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.1))
                    .clipShape(Capsule())
            }
        }
    }
}

// MARK: - Preview

#Preview {
    List {
        ProviderDisclosureGroup(
            provider: .antigravity,
            accounts: [
                AccountRowData(
                    id: "1",
                    provider: .antigravity,
                    displayName: "user@gmail.com",
                    source: .proxy,
                    status: "ready",
                    statusMessage: nil,
                    isDisabled: false,
                    canDelete: true
                ),
                AccountRowData(
                    id: "2",
                    provider: .antigravity,
                    displayName: "work@company.com",
                    source: .proxy,
                    status: "cooling",
                    statusMessage: "Rate limited",
                    isDisabled: false,
                    canDelete: true
                )
            ]
        )
        
        ProviderDisclosureGroup(
            provider: .cursor,
            accounts: [
                AccountRowData(
                    id: "3",
                    provider: .cursor,
                    displayName: "dev@example.com",
                    source: .autoDetected,
                    status: nil,
                    statusMessage: nil,
                    isDisabled: false,
                    canDelete: false
                )
            ]
        )
    }
}
