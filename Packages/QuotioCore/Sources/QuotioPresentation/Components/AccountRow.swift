//
//  AccountRow.swift
//  QuotioPresentation
//
//  Unified account row component for ProvidersScreen.
//  Replaces: AuthFileRow, DirectAuthFileRow, AutoDetectedAccountRow
//

import QuotioApplication
import QuotioDomain
import SwiftUI

/// Represents the source/type of an account for display purposes
enum AccountRowSource: Equatable {
    case proxy           // From proxy API (AuthFile)
    case direct          // From disk auth files (DirectAuthFile)
    case autoDetected    // Auto-detected from IDE (Cursor, Trae)
    case monitor(AccountSource)
    /// A real account fetched from a configured remote quota source (Settings ▸ Remote
    /// Quota Sources), identified by that source's own display name. Read-only: it must
    /// never expose local login/disable/delete actions — its identity and quota are
    /// entirely owned by `RemoteQuotaSourceScreenModel`.
    case remoteQuotaSource(String)
    /// A derived, read-only summary row combining every real remote account that shares
    /// one source + provider + plan — never a real account in its own right. Owned by
    /// `RemoteQuotaSourceScreenModel.planAggregates`, so it is exactly as read-only as
    /// `remoteQuotaSource`, plus it can never be individually hidden from the dropdown
    /// (there is nothing beneath it to hide — hiding applies to the real accounts it
    /// summarizes).
    case remoteQuotaSourceAggregate(sourceName: String, planLabel: String)

    @MainActor
    var displayName: String {
        switch self {
        case .proxy: return "providers.source.proxy".localizedStatic()
        case .direct: return "providers.source.disk".localizedStatic()
        case .autoDetected: return "providers.autoDetected".localizedStatic()
        case .monitor(let source): return source.displayName
        case .remoteQuotaSource(let sourceName): return sourceName
        case .remoteQuotaSourceAggregate(let sourceName, _): return sourceName
        }
    }

    var supportsDisable: Bool {
        switch self {
        case .proxy, .monitor: true
        case .direct, .autoDetected, .remoteQuotaSource, .remoteQuotaSourceAggregate: false
        }
    }

    /// Whether this row gets the "hide from the menu bar dropdown" ✓/✕ toggle, shown
    /// inline for every real account regardless of whether it also has a real
    /// enable/disable action — the two controls are independent: this one only ever
    /// changes whether the account shows up in the menu bar's per-provider dropdown
    /// list, never whether the account itself keeps fetching. Every real account source
    /// (proxy, direct, monitor, remoteQuotaSource) gets it; an aggregate row does not,
    /// since it is already just a derived view of accounts that can each be hidden
    /// individually and has nothing of its own to hide.
    var supportsDropdownVisibilityToggle: Bool {
        switch self {
        case .proxy, .direct, .monitor, .remoteQuotaSource: true
        case .autoDetected, .remoteQuotaSourceAggregate: false
        }
    }

    /// The configured source's own name for a remote-quota-source row; nil for every
    /// local source. Lets callers order rows so one source's accounts stay together
    /// without reaching for the localized, main-actor-bound `displayName`.
    var remoteSourceName: String? {
        switch self {
        case .remoteQuotaSource(let name), .remoteQuotaSourceAggregate(let name, _): return name
        default: return nil
        }
    }

    /// Whether this row is a derived plan summary rather than a real account. Every
    /// account count shown to the user (provider badges, total counts) must exclude
    /// aggregate rows — otherwise the accounts they summarize would be counted twice.
    var isAggregate: Bool {
        if case .remoteQuotaSourceAggregate = self { return true }
        return false
    }
}

/// Unified data model for account display
struct AccountRowData: Identifiable, Hashable {
    let id: String
    let provider: QuotaProvider
    let displayName: String       // Email or account identifier
    let menuBarAccountKey: String
    let authFileName: String?
    let source: AccountRowSource
    let status: String?           // "ready", "cooling", "error", etc.
    let statusMessage: String?
    let isDisabled: Bool
    let canDelete: Bool           // Only proxy accounts can be deleted
    let canEdit: Bool             // Whether this account can be edited (GLM only)
    let canSwitch: Bool           // Whether this account can be switched (Antigravity only)
    /// The `RemoteQuotaSourceConfig.id` this account's quota was fetched from, if any.
    /// `nil` for every local source — only remote-quota-source rows set this, so their
    /// menu bar pin carries the source id `RemoteQuotaSourceCoordinator`/refresh routing
    /// needs, instead of being indistinguishable from a local account.
    let sourceConfigId: String?

    // Custom initializer to handle canEdit parameter
    init(
        id: String,
        provider: QuotaProvider,
        displayName: String,
        menuBarAccountKey: String? = nil,
        authFileName: String? = nil,
        source: AccountRowSource,
        status: String?,
        statusMessage: String?,
        isDisabled: Bool,
        canDelete: Bool,
        canEdit: Bool = false,
        canSwitch: Bool = false,
        sourceConfigId: String? = nil
    ) {
        self.id = id
        self.provider = provider
        self.displayName = displayName
        self.menuBarAccountKey = menuBarAccountKey ?? displayName
        self.authFileName = authFileName
        self.source = source
        self.status = status
        self.statusMessage = statusMessage
        self.isDisabled = isDisabled
        self.canDelete = canDelete
        self.canEdit = canEdit
        self.canSwitch = canSwitch
        self.sourceConfigId = sourceConfigId
    }

    // For menu bar selection
    var menuBarItem: MenuBarQuotaItem {
        MenuBarQuotaItem(provider: provider.rawValue, accountKey: menuBarAccountKey, sourceConfigId: sourceConfigId)
    }

    var canDownloadAuthFile: Bool {
        authFileName != nil
    }

    // MARK: - Factory Methods
    
    /// Create from AuthFile (proxy mode)
    static func from(authFile: ManagedAuthFile, provider: QuotaProvider) -> AccountRowData {
        let name = authFile.email ?? authFile.name
        return AccountRowData(
            id: authFile.id,
            provider: provider,
            displayName: name,
            menuBarAccountKey: authFile.menuBarAccountKey,
            authFileName: authFile.name,
            source: .proxy,
            status: authFile.status,
            statusMessage: authFile.statusMessage,
            isDisabled: authFile.disabled,
            canDelete: true
        )
    }
    
    /// Create from an auth file read directly from disk (quota-only mode or proxy stopped).
    static func from(directAuthFile: AuthFileDescriptor) -> AccountRowData? {
        guard let provider = QuotaProvider(rawValue: directAuthFile.providerID.rawValue) else {
            return nil
        }
        let name = directAuthFile.email ?? directAuthFile.filename
        return AccountRowData(
            id: directAuthFile.id,
            provider: provider,
            displayName: name,
            menuBarAccountKey: directAuthFile.menuBarAccountKey,
            authFileName: directAuthFile.filename,
            source: .direct,
            status: nil,
            statusMessage: nil,
            isDisabled: false,
            canDelete: false
        )
    }
    
    /// Create from auto-detected account (Cursor, Trae)
    /// Cursor/Trae accounts are imported from local IDE databases via "Scan for IDEs";
    /// deleting them removes the imported quota data from Quotio (issue #213).
    static func from(provider: QuotaProvider, accountKey: String) -> AccountRowData {
        AccountRowData(
            id: "\(provider.rawValue)_\(accountKey)",
            provider: provider,
            displayName: accountKey,
            menuBarAccountKey: accountKey,
            source: .autoDetected,
            status: nil,
            statusMessage: nil,
            isDisabled: false,
            canDelete: provider.isImportedFromLocalIDE
        )
    }

    static func from(
        monitorAccount: Account,
        status: String?,
        statusMessage: String?
    ) -> AccountRowData {
        AccountRowData(
            id: monitorAccount.id,
            provider: monitorAccount.provider,
            displayName: monitorAccount.displayName,
            menuBarAccountKey: monitorAccount.accountKey,
            source: .monitor(monitorAccount.source),
            status: status,
            statusMessage: statusMessage,
            isDisabled: monitorAccount.isDisabled,
            canDelete: monitorAccount.canDelete,
            canEdit: monitorAccount.source == .quotioKeychain
                && [.factoryDroid, .openRouter, .amp].contains(monitorAccount.provider)
        )
    }

    /// Create from one real account fetched from a configured remote quota source.
    /// `storageKey` is the exact `RemoteQuotaAccountIdentity` composite key already
    /// present in the merged quota dictionary, so the resulting `menuBarItem` pins
    /// precisely that account — never a source-wide/plan-level aggregate.
    static func from(
        provider: QuotaProvider,
        sourceId: String,
        sourceName: String,
        rawAccountKey: String,
        storageKey: String,
        quota: ProviderQuota
    ) -> AccountRowData {
        AccountRowData(
            id: "remote:\(sourceId):\(rawAccountKey)",
            provider: provider,
            displayName: quota.accountDisplayName ?? rawAccountKey,
            menuBarAccountKey: storageKey,
            source: .remoteQuotaSource(sourceName),
            status: nil,
            statusMessage: nil,
            isDisabled: false,
            canDelete: false,
            sourceConfigId: sourceId
        )
    }

    /// Create one derived summary row for every real account sharing `sourceId` +
    /// `provider` + `planKey`. `storageKey` is the exact `RemoteQuotaAggregateIdentity`
    /// composite key, so pinning this row (via the normal `menuBarItem`/`MenuBarBadge`
    /// path already used by every other row) targets that source + provider + plan
    /// aggregate specifically — never one of the real accounts it summarizes.
    @MainActor
    static func aggregate(
        provider: QuotaProvider,
        sourceId: String,
        sourceName: String,
        planLabel: String,
        accountCount: Int,
        storageKey: String,
        quota: ProviderQuota
    ) -> AccountRowData {
        AccountRowData(
            id: "remote-aggregate:\(sourceId):\(provider.rawValue):\(storageKey)",
            provider: provider,
            displayName: String(format: "providers.aggregate.rowTitle".localizedStatic(), planLabel, accountCount),
            menuBarAccountKey: storageKey,
            source: .remoteQuotaSourceAggregate(sourceName: sourceName, planLabel: planLabel),
            status: nil,
            statusMessage: nil,
            isDisabled: quota.isForbidden,
            canDelete: false,
            sourceConfigId: sourceId
        )
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(authFileName)
        hasher.combine(isDisabled)
        hasher.combine(status)
    }

    static func == (lhs: AccountRowData, rhs: AccountRowData) -> Bool {
        lhs.id == rhs.id &&
        lhs.authFileName == rhs.authFileName &&
        lhs.isDisabled == rhs.isDisabled &&
        lhs.status == rhs.status
    }
}

// MARK: - AccountRow View

struct AccountRow: View {
    let account: AccountRowData
    var onDelete: (() -> Void)?
    var onEdit: (() -> Void)?
    var onSwitch: (() -> Void)?
    var onToggleDisabled: (() -> Void)?
    var onDownload: (() -> Void)?
    var isActiveInIDE: Bool = false
    
    @Environment(MenuBarSettingsManager.self) private var settings
    @State private var showWarning = false
    @State private var showMaxItemsAlert = false
    @State private var showDeleteConfirmation = false
    
    private var isMenuBarSelected: Bool {
        settings.isSelected(account.menuBarItem)
    }

    /// Every real account gets this — see `AccountRowSource.supportsDropdownVisibilityToggle`.
    /// Keyed by `menuBarItem.id` (not the raw `menuBarAccountKey`) so the same raw
    /// key/email used by two different local sources, or by a local and a remote
    /// account, can never collide in the hidden set — `menuBarItem.id` already namespaces
    /// by provider and, for remote accounts, by source id.
    private var isHiddenFromDropdown: Bool {
        settings.isHiddenFromDropdown(account.menuBarItem.id)
    }
    
    /// An aggregate row's `displayName` is a synthesized title ("Pro (3 accounts)"), not
    /// a real account identifier, so it is never masked — only a real account's own
    /// email/name is sensitive here.
    private var maskedDisplayName: String {
        account.displayName.masked(if: settings.hideSensitiveInfo && !account.source.isAggregate)
    }
    
    private var statusColor: Color {
        switch account.status {
        case "ready": return account.isDisabled ? .gray : .green
        case "cooling", "outdated": return .orange
        case "error": return .red
        default: return .gray
        }
    }
    
    var body: some View {
        HStack(spacing: 12) {
            // Provider icon
            ProviderIcon(provider: account.provider, size: 24)
            
            // Account info
            VStack(alignment: .leading, spacing: 2) {
                Text(maskedDisplayName)
                    .fontWeight(.medium)
                    .lineLimit(1)
                
                HStack(spacing: 6) {
                    // Provider name
                    Text(account.provider.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    
                    // Status indicator (only for proxy accounts)
                    if let status = account.status {
                        Circle()
                            .fill(statusColor)
                            .frame(width: 6, height: 6)
                        
                        Text(status)
                            .font(.caption)
                            .foregroundStyle(statusColor)
                    } else {
                        // Source indicator for non-proxy accounts
                        Text("•")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        
                        Text(account.source.displayName)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }

                if let message = account.statusMessage, !message.isEmpty {
                    Text(message)
                        .font(.caption2)
                        .foregroundStyle(account.status == "error" ? .red : .secondary)
                        .lineLimit(1)
                }
            }
            
            Spacer()
            
            // Disabled badge
            if account.isDisabled {
                Text("providers.disabled".localized())
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.secondary.opacity(0.2))
                    .clipShape(Capsule())
            }
            
            // Active in IDE badge (Antigravity only)
            if account.provider == .antigravity && isActiveInIDE {
                Text("antigravity.active".localized())
                    .font(.caption2)
                    .fontWeight(.medium)
                    .foregroundStyle(Color(red: 0.13, green: 0.55, blue: 0.13))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color(red: 0.85, green: 0.95, blue: 0.85))
                    .clipShape(Capsule())
            }
            
            // Switch button (Antigravity only, for proxy/direct accounts that are not active)
            if account.provider == .antigravity && !isActiveInIDE && account.source != .autoDetected {
                Button {
                    onSwitch?()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "rectangle.portrait.and.arrow.right")
                            .font(.caption2)
                        Text("antigravity.useInIDE".localized())
                            .font(.caption2)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.blue.opacity(0.1))
                    .foregroundStyle(.blue)
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("antigravity.switch.title".localized())
            }
            
            // Menu bar toggle
            MenuBarBadge(
                isSelected: isMenuBarSelected,
                onTap: handleMenuBarToggle
            )

            // Dropdown-visibility ✓/✕ toggle (every real account). This only controls
            // whether the account shows up in the menu bar's per-provider dropdown list —
            // never the account's real enable/disable state, which (for sources that
            // support it) lives in the context menu only, reachable via right-click.
            if account.source.supportsDropdownVisibilityToggle {
                Button {
                    settings.toggleDropdownVisibility(account.menuBarItem.id)
                } label: {
                    ZStack {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(isHiddenFromDropdown ? Color.red.opacity(0.1) : Color.clear)
                            .frame(width: 28, height: 28)

                        Image(systemName: isHiddenFromDropdown ? "xmark.circle.fill" : "checkmark.circle")
                            .font(.system(size: 14))
                            .foregroundStyle(isHiddenFromDropdown ? .red : .secondary)
                    }
                }
                .buttonStyle(.rowAction)
                .help(isHiddenFromDropdown ? "providers.dropdown.show".localized() : "providers.dropdown.hide".localized())
                .accessibilityLabel(isHiddenFromDropdown ? "providers.dropdown.show".localized() : "providers.dropdown.hide".localized())
            }

            // Edit button (GLM only)
            if account.canEdit, let onEdit = onEdit {
                Button {
                    onEdit()
                } label: {
                    Image(systemName: "pencil")
                        .foregroundStyle(.blue)
                }
                .buttonStyle(.rowAction)
                .help("action.edit".localized())
            }

            // Delete button (only for proxy accounts)
            if account.canDelete, onDelete != nil {
                Button(role: .destructive) {
                    showDeleteConfirmation = true
                } label: {
                    Image(systemName: "trash")
                        .foregroundStyle(.red.opacity(0.8))
                }
                .buttonStyle(.rowActionDestructive)
                .help("action.delete".localized())
            }
        }
        .contentShape(Rectangle())
        .contextMenu {
            // Switch account option (Antigravity only)
            if account.provider == .antigravity && !isActiveInIDE && account.source != .autoDetected {
                Button {
                    onSwitch?()
                } label: {
                    Label("antigravity.switch.title".localized(), systemImage: "arrow.triangle.2.circlepath")
                }
                
                Divider()
            }
            
            if let onDownload {
                Button {
                    onDownload()
                } label: {
                    Label("action.download".localized(), systemImage: "arrow.down.circle")
                }
            }

            // Menu bar toggle
            Button {
                handleMenuBarToggle()
            } label: {
                if isMenuBarSelected {
                    Label("menubar.hideFromMenuBar".localized(), systemImage: "chart.bar")
                } else {
                    Label("menubar.showOnMenuBar".localized(), systemImage: "chart.bar.fill")
                }
            }

            // Disable/Enable toggle (only for proxy accounts)
            if account.source.supportsDisable, let onToggleDisabled = onToggleDisabled {
                Button {
                    onToggleDisabled()
                } label: {
                    if account.isDisabled {
                        Label("providers.enable".localized(), systemImage: "checkmark.circle")
                    } else {
                        Label("providers.disable".localized(), systemImage: "minus.circle")
                    }
                }
            } else if account.source.supportsDropdownVisibilityToggle {
                Button {
                    settings.toggleDropdownVisibility(account.menuBarItem.id)
                } label: {
                    if isHiddenFromDropdown {
                        Label("providers.dropdown.show".localized(), systemImage: "checkmark.circle")
                    } else {
                        Label("providers.dropdown.hide".localized(), systemImage: "minus.circle")
                    }
                }
            }

            // Delete option (only for proxy accounts)
            if account.canDelete, onDelete != nil {
                Divider()
                
                Button(role: .destructive) {
                    showDeleteConfirmation = true
                } label: {
                    Label("action.delete".localized(), systemImage: "trash")
                }
            }
        }
        .confirmationDialog("providers.deleteConfirm".localized(), isPresented: $showDeleteConfirmation) {
            Button("action.delete".localized(), role: .destructive) {
                onDelete?()
            }
            Button("action.cancel".localized(), role: .cancel) {}
        } message: {
            Text("providers.deleteMessage".localized())
        }
        .alert("menubar.warning.title".localized(), isPresented: $showWarning) {
            Button("menubar.warning.confirm".localized()) {
                settings.toggleItem(account.menuBarItem)
            }
            Button("menubar.warning.cancel".localized(), role: .cancel) {}
        } message: {
            Text("menubar.warning.message".localized())
        }
        .alert("menubar.maxItems.title".localized(), isPresented: $showMaxItemsAlert) {
            Button("action.ok".localized(), role: .cancel) {}
        } message: {
            Text(String(
                format: "menubar.maxItems.message".localized(),
                settings.menuBarMaxItems
            ))
        }
    }
    
    private func handleMenuBarToggle() {
        // Turning an account off never consumes a menu bar slot, and restoring an
        // account covered by a legacy pool pin only consumes one if that pool pin is
        // currently empty (occupies no slot yet) — `toggleWouldOccupyNewSlot` captures
        // exactly that distinction, so the warning/limit checks only apply when the
        // toggle would actually grow effective occupancy.
        if !settings.toggleWouldOccupyNewSlot(account.menuBarItem) {
            settings.toggleItem(account.menuBarItem)
        } else if settings.isAtMaxItems {
            showMaxItemsAlert = true
        } else if settings.shouldWarnOnAdd {
            showWarning = true
        } else {
            settings.toggleItem(account.menuBarItem)
        }
    }
}

// MARK: - Preview

#Preview {
    List {
        AccountRow(
            account: AccountRowData(
                id: "1",
                provider: .antigravity,
                displayName: "user@gmail.com",
                source: .proxy,
                status: "ready",
                statusMessage: nil,
                isDisabled: false,
                canDelete: true
            ),
            onDelete: {}
        )
        
        AccountRow(
            account: AccountRowData(
                id: "2",
                provider: .claude,
                displayName: "work@company.com",
                source: .direct,
                status: nil,
                statusMessage: nil,
                isDisabled: false,
                canDelete: false
            )
        )
        
        AccountRow(
            account: AccountRowData(
                id: "3",
                provider: .cursor,
                displayName: "dev@example.com",
                source: .autoDetected,
                status: nil,
                statusMessage: nil,
                isDisabled: false,
                canDelete: false
            )
        )
    }
}
