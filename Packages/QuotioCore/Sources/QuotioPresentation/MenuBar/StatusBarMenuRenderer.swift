//
//  StatusBarMenuRenderer.swift
//  QuotioPresentation
//
//  Native NSMenu renderer that matches MenuBarView layout:
//  - Header
//  - Proxy Info (Full Mode)
//  - Provider Segment Picker
//  - Account Cards (individual items)
//  - Actions
//

import AppKit
import QuotioDomain
import SwiftUI

// MARK: - Status Bar Menu Renderer

@MainActor
final class StatusBarMenuRenderer {
    private let snapshot: StatusBarMenuSnapshot
    private let commands: StatusBarCommandDispatcher
    private let menuWidth: CGFloat = 360

    init(
        snapshot: StatusBarMenuSnapshot,
        commands: StatusBarCommandDispatcher
    ) {
        self.snapshot = snapshot
        self.commands = commands
    }
    
    // MARK: - Build Menu
    
    func buildMenu() -> NSMenu {
        let menu = makeMenu()

        // 1. Header
        menu.addItem(buildHeaderItem())
        menu.addItem(separatorItem())

        // 2. Network info (Proxy + Tunnel) - Local Proxy Mode only
        if snapshot.isLocalProxyMode {
            menu.addItem(buildNetworkInfoItem())
            menu.addItem(separatorItem())
        }

        // 3. Provider picker and account groups
        let providers = snapshot.providers
        if !providers.isEmpty {
            let pickerView = MenuProviderPickerView(
                providers: providers.map(\.provider),
                selectedProvider: selectedProvider(from: providers),
                onProviderChanged: { provider in
                    self.commands.dispatch(.selectProvider(provider))
                }
            )
            menu.addItem(viewItem(for: pickerView))
            menu.addItem(separatorItem())

            let visibleProviders = visibleProviders(from: providers)
            let showsProviderHeaders = selectedProvider(from: providers) == nil
            for (index, providerSnapshot) in visibleProviders.enumerated() {
                if showsProviderHeaders {
                    let headerView = MenuProviderSectionHeader(
                        provider: providerSnapshot.provider,
                        isRefreshing: providerSnapshot.isRefreshing,
                        supportsScopedRefresh: providerSnapshot.supportsScopedRefresh,
                        onRefresh: {
                            self.commands.dispatch(.refreshProvider(providerSnapshot.provider))
                        }
                    )
                    menu.addItem(viewItem(for: headerView))
                }

                if providerSnapshot.groups.isEmpty {
                    menu.addItem(buildEmptyStateItem())
                } else {
                    // Single-source filter still keeps local/remote separated: within
                    // one provider, the local group (if present) renders first, then
                    // each remote source's own group under its own sub-header — so two
                    // sources (or a local + a remote account) sharing a raw key/email
                    // never read as one merged row.
                    let showsSourceSubheaders = providerSnapshot.groups.count > 1
                        || providerSnapshot.groups.first?.origin != .local
                    // Channel color numbering (indigo/teal/pink/sky) restarts per
                    // provider and only advances for multi-account groups — a
                    // single-account group never consumes a color.
                    let presentations = providerSnapshot.groups.map { MenuChannelWeightPresentation(accounts: $0.accounts) }
                    let accents = MenuChannelWeightPresentation.channelAccents(
                        forMultiAccountFlags: presentations.map(\.isMultiAccount)
                    )
                    for (groupIndex, group) in providerSnapshot.groups.enumerated() {
                        let presentation = presentations[groupIndex]
                        let accent = accents[groupIndex]
                        if showsSourceSubheaders {
                            menu.addItem(viewItem(for: MenuAccountGroupSubheader(
                                origin: group.origin,
                                isMultiAccount: presentation.isMultiAccount,
                                channelWeight: presentation.channelWeight,
                                segments: presentation.segments,
                                accent: accent,
                                menuWidth: menuWidth
                            )))
                        }
                        for account in group.accounts {
                            menu.addItem(buildAccountCardItem(account, accountWeightAccent: accent))
                        }
                    }
                }

                // Separator between provider groups (not after the last one)
                if index < visibleProviders.count - 1 {
                    menu.addItem(separatorItem())
                }
            }

            menu.addItem(separatorItem())
        } else {
            menu.addItem(buildEmptyStateItem())
            menu.addItem(separatorItem())
        }
        
        // 4. Action items
        for item in buildActionItems() {
            menu.addItem(item)
        }
        
        return menu
    }
    
    // MARK: - Data Helpers

    private func selectedProvider(
        from providers: [StatusBarMenuProviderSnapshot]
    ) -> QuotaProvider? {
        guard let provider = snapshot.selectedProvider,
              providers.contains(where: { $0.provider == provider }) else {
            return nil
        }
        return provider
    }

    private func visibleProviders(
        from providers: [StatusBarMenuProviderSnapshot]
    ) -> [StatusBarMenuProviderSnapshot] {
        guard let provider = selectedProvider(from: providers) else {
            return providers
        }
        return providers.filter { $0.provider == provider }
    }

    // MARK: - Header Item
    
    private func buildHeaderItem() -> NSMenuItem {
        let headerView = MenuHeaderView(isLoading: snapshot.isLoadingQuotas)
        return viewItem(for: headerView)
    }

    // MARK: - Network Info Item (Proxy + Tunnel combined)

    private func buildNetworkInfoItem() -> NSMenuItem {
        let networkView = MenuNetworkInfoView(
            port: String(snapshot.proxyPort),
            isProxyRunning: snapshot.isProxyRunning,
            tunnelStatus: snapshot.tunnel.status,
            tunnelURL: snapshot.tunnel.publicURL,
            onProxyToggle: {
                self.commands.dispatch(.toggleProxy)
            },
            onCopyProxyURL: {
                self.commands.dispatch(.copyProxyURL("http://127.0.0.1:\(self.snapshot.proxyPort)"))
            },
            onTunnelToggle: {
                self.commands.dispatch(.toggleTunnel(port: self.snapshot.proxyPort))
            },
            onCopyTunnelURL: {
                guard let url = self.snapshot.tunnel.publicURL else { return }
                self.commands.dispatch(.copyTunnelURL(url))
            }
        )
        return viewItem(for: networkView)
    }

    // MARK: - Account Card Item (with submenu for Antigravity)

    private func buildAccountCardItem(
        _ account: StatusBarMenuAccountSnapshot,
        accountWeightAccent: Color?
    ) -> NSMenuItem {
        let provider = account.id.provider
        let cardView = MenuAccountCardView(
            accountKey: account.id.accountKey,
            email: account.email,
            data: account.quota,
            provider: provider,
            subscriptionInfo: account.subscription,
            isActiveInIDE: account.isActiveInIDE,
            isRefreshing: account.isRefreshing,
            canRefresh: !account.isRefreshBlocked && provider.supportsQuotaOnlyMode,
            accountWeightAccent: accountWeightAccent,
            settings: snapshot.displaySettings,
            onRefresh: {
                self.commands.dispatch(.refreshAccount(account.id))
            },
            // A remote-origin account is a read-only reflection of another server's
            // auth file — it must never drive local IDE account switching.
            onUseAccount: account.origin == .local && provider == .antigravity && !account.isActiveInIDE ? {
                self.commands.dispatch(.useAntigravityAccount(email: account.email))
            } : nil
        )

        let item = viewItem(for: cardView)

        let isAntigravitySummary = provider == .antigravity
            && account.quota.models.contains { $0.name.hasPrefix("antigravity-") }

        if provider == .codex, let analytics = account.quota.analytics, !analytics.isEmpty {
            let submenu = buildCodexAnalyticsSubmenu(analytics: analytics)
            item.submenu = submenu
        } else if provider == .antigravity && !account.quota.models.isEmpty && !isAntigravitySummary {
            let submenu = buildAntigravitySubmenu(data: account.quota)
            item.submenu = submenu
        }

        return item
    }

    private func buildCodexAnalyticsSubmenu(analytics: QuotaAnalytics) -> NSMenu {
        let submenu = makeMenu()
        submenu.addItem(viewItem(for: AnalyticsDetailSection(analytics: analytics), width: 640))
        return submenu
    }

    // MARK: - Antigravity Submenu

    private func buildAntigravitySubmenu(data: ProviderQuota) -> NSMenu {
        let submenu = makeMenu()

        let hasSummary = data.models.contains { $0.name.hasPrefix("antigravity-") }
        let allModels = hasSummary ? data.models : data.models.sorted { $0.name < $1.name }

        for model in allModels {
            let isSummary = model.name.hasPrefix("antigravity-")
            let modelItem = viewItem(for: MenuModelDetailView(
                model: model,
                showRawName: !isSummary,
                settings: snapshot.displaySettings
            ))
            submenu.addItem(modelItem)
        }

        return submenu
    }
    
    // MARK: - Empty State
    
    private func buildEmptyStateItem() -> NSMenuItem {
        let emptyView = MenuEmptyStateView()
        return viewItem(for: emptyView)
    }
    
    // MARK: - Action Items
    
    private func buildActionItems() -> [NSMenuItem] {
        let actionsView = MenuActionsView(
            isLoading: snapshot.isLoadingQuotas,
            onRefresh: { self.commands.dispatch(.refreshAll) },
            onOpenApp: { self.commands.dispatch(.openApp) },
            onQuit: { self.commands.dispatch(.quit) }
        )
        return [viewItem(for: actionsView)]
    }
    
    // MARK: - Helpers

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.appearance = snapshot.appearanceMode.appKitAppearance
        return menu
    }
    
    /// Decorative divider between menu sections. A native `NSMenuItem.separator()`
    /// draws through the menu's own translucent window material, so it stayed visibly
    /// lighter than the near-opaque `MenuRowBackground` fill every other row sits on —
    /// this renders the same fill behind a thin line instead, so the whole menu reads
    /// as one consistent surface. Disabled and hidden from VoiceOver since it carries
    /// no action, matching how a native separator is already unselectable.
    private func separatorItem() -> NSMenuItem {
        let item = viewItem(for: MenuSeparatorView())
        item.isEnabled = false
        return item
    }

    private func viewItem<V: View>(for view: V, width: CGFloat? = nil) -> NSMenuItem {
        let effectiveWidth = width ?? menuWidth
        // Native NSMenu draws its own window with a translucent material, which lets
        // whatever sits behind it show through custom SwiftUI rows and hurts legibility.
        // A near-opaque fill behind the row (fully opaque under Reduce Transparency)
        // masks that without touching the row content's own opacity, so text and the
        // hover highlight drawn on top of it stay crisp.
        let locale = snapshot.language.locale
        let rootView = MenuRowBackground {
            view
                .frame(width: effectiveWidth)
                .environment(\.locale, locale)
        }
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.appearance = snapshot.appearanceMode.appKitAppearance
        hostingView.setFrameSize(hostingView.intrinsicContentSize)
        
        let item = NSMenuItem()
        item.view = hostingView
        return item
    }
}

// MARK: - SwiftUI Menu Components

// MARK: Row Background

private struct MenuRowBackground<Content: View>: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .background(Color(nsColor: .windowBackgroundColor).opacity(reduceTransparency ? 1.0 : 0.95))
    }
}

// MARK: Separator Row

/// Thin divider matching a native `NSMenuItem.separator()`'s line/inset, but hosted in
/// `StatusBarMenuRenderer.separatorItem()` behind the same `MenuRowBackground` fill as
/// every other row, so it no longer shows through the menu's translucent window material.
private struct MenuSeparatorView: View {
    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.1))
            .frame(height: 1)
            .padding(.vertical, 4)
            .accessibilityHidden(true)
    }
}

// MARK: Header View

private struct MenuHeaderView: View {
    let isLoading: Bool
    
    var body: some View {
        HStack {
            Text("Quotio")
                .font(.headline)
                .fontWeight(.semibold)
            
            Spacer()
            
            if isLoading {
                ProgressView()
                    .scaleEffect(0.6)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}



// MARK: - Provider Section Header

private struct MenuProviderSectionHeader: View {
    let provider: QuotaProvider
    let isRefreshing: Bool
    let supportsScopedRefresh: Bool
    let onRefresh: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            ProviderIconMono(provider: provider, size: 14)
            Text(provider.displayName)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
            Spacer()

            Button(action: onRefresh) {
                if isRefreshing {
                    ProgressView()
                        .controlSize(.mini)
                        .frame(width: 18, height: 18)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 18, height: 18)
                }
            }
            .buttonStyle(.plain)
            .disabled(isRefreshing || !supportsScopedRefresh)
            .help("action.refreshQuota".localized())
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }
}

// MARK: - Account Group Subheader (local vs. remote source, within one provider)

/// Labels which source a group of account rows came from — "Local" or a configured
/// remote quota source's own name — so accounts never read as an undifferentiated pile
/// once more than one source is visible for the same provider. A multi-account group
/// additionally shows its reconciled channel weight and a per-account weight
/// distribution bar, both in the group's assigned channel color; a single-account group
/// never shows either, since a lone account has no distribution to visualize.
private struct MenuAccountGroupSubheader: View {
    let origin: StatusBarMenuAccountOrigin
    let isMultiAccount: Bool
    let channelWeight: Int?
    let segments: [Int]
    /// This group's assigned channel color — always non-`nil` when `isMultiAccount` is
    /// `true` (assigned by the caller before the weight is known to be shown), unused
    /// otherwise.
    let accent: Color?
    /// `StatusBarMenuRenderer.menuWidth`, passed down so the distribution bar derives its
    /// content width from the single source of truth instead of duplicating it.
    let menuWidth: CGFloat

    private var title: String {
        switch origin {
        case .local:
            return "menubar.source.local".localized()
        case .remote(_, let sourceName):
            return sourceName
        }
    }

    private var originIcon: some View {
        Image(systemName: origin == .local ? "desktopcomputer" : "network")
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.secondary)
    }

    /// `menuWidth` minus this subheader's own 14pt horizontal padding on each side — the
    /// content width `WeightDistributionBar` lays its segments out against.
    private var contentWidth: CGFloat {
        menuWidth - Self.horizontalPadding * 2
    }

    private static let horizontalPadding: CGFloat = 14

    var body: some View {
        if isMultiAccount {
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    originIcon
                    Text(title)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.primary.opacity(0.85))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    if let channelWeight, let accent {
                        Text("menu.weight.channelLabel".localized())
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                        Text(String(channelWeight))
                            .font(.system(size: 14, weight: .bold, design: .monospaced))
                            .foregroundStyle(accent)
                    }
                }
                if !segments.isEmpty, let accent {
                    WeightDistributionBar(segments: segments, accent: accent, contentWidth: contentWidth)
                }
            }
            .padding(.horizontal, Self.horizontalPadding)
            .padding(.top, 6)
            .padding(.bottom, 2)
        } else {
            HStack(spacing: 6) {
                originIcon
                Text(title)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.primary.opacity(0.85))
                    .lineLimit(1)
            }
            .padding(.horizontal, Self.horizontalPadding)
            .padding(.top, 2)
        }
    }
}

/// Fixed-width bar showing each account's positive weight as one proportionally-sized
/// segment, in the order the caller supplies (render order). Segment fill fades by
/// position within a group's own channel color, so an account's rank within its pool
/// is visible at a glance even before reading the numbers.
struct WeightDistributionBar: View {
    let segments: [Int]
    let accent: Color
    /// The width available to lay segments out against — derived by the caller from
    /// `StatusBarMenuRenderer.menuWidth` minus its own horizontal padding, so this bar
    /// never keeps its own copy of the menu width. The menu never resizes live, so this
    /// is a fixed value rather than one read from a `GeometryReader`.
    let contentWidth: CGFloat

    @Environment(\.colorScheme) private var colorScheme

    private static let barHeight: CGFloat = 16
    static let segmentSpacing: CGFloat = 2
    /// Segments narrower than this hide their number but keep their fill — the digits
    /// would otherwise overflow a sliver segment.
    private static let minTextWidth: CGFloat = 18

    /// Proportional width for each segment given its share of `segments`' total, with the
    /// final segment absorbing rounding so the widths sum exactly to `contentWidth` minus
    /// inter-segment spacing instead of drifting from it by a pixel or two. Pure so it can
    /// be tested directly without instantiating a view.
    static func widths(segments: [Int], contentWidth: CGFloat) -> [CGFloat] {
        let total = segments.reduce(0, +)
        guard total > 0 else { return [] }
        let spacingTotal = segmentSpacing * CGFloat(max(segments.count - 1, 0))
        let available = contentWidth - spacingTotal
        var result = segments.map { available * CGFloat($0) / CGFloat(total) }
        if let last = result.indices.last {
            let consumed = result[..<last].reduce(0, +)
            result[last] = available - consumed
        }
        return result
    }

    private var widths: [CGFloat] {
        Self.widths(segments: segments, contentWidth: contentWidth)
    }

    var body: some View {
        HStack(spacing: Self.segmentSpacing) {
            ForEach(segments.indices, id: \.self) { index in
                segment(index: index, weight: segments[index], width: widths[index])
            }
        }
        .frame(height: Self.barHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(distributionAccessibilityLabel)
    }

    private func segment(index: Int, weight: Int, width: CGFloat) -> some View {
        let isDark = colorScheme == .dark
        let opacity = isDark
            ? max(0.4, 1 - 0.16 * Double(index))
            : max(0.10, 0.22 - 0.03 * Double(index))
        let textColor = isDark ? MenuBarPalette.segmentDarkText : accent

        return RoundedRectangle(cornerRadius: 4)
            .fill(accent.opacity(opacity))
            .frame(width: max(width, 0), height: Self.barHeight)
            .overlay(
                Group {
                    if width >= Self.minTextWidth {
                        Text(String(weight))
                            .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                            .foregroundStyle(textColor)
                    }
                }
            )
    }

    private var distributionAccessibilityLabel: String {
        let joined = segments.map(String.init).joined(separator: ", ")
        return String(format: "menu.weight.distribution".localized(), joined)
    }
}

// MARK: - Provider Picker View (separate from accounts list)

private struct MenuProviderPickerView: View {
    let providers: [QuotaProvider]
    let selectedProvider: QuotaProvider?
    let onProviderChanged: (QuotaProvider?) -> Void
    
    var body: some View {
        // Wrap providers in a flexible layout
        FlowLayout(spacing: 6) {
            AllProviderFilterButton(isSelected: selectedProvider == nil) {
                onProviderChanged(nil)
            }

            ForEach(providers) { provider in
                ProviderFilterButton(
                    provider: provider,
                    isSelected: selectedProvider == provider
                ) {
                    onProviderChanged(provider)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

// MARK: All Provider Filter Button

private struct AllProviderFilterButton: View {
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 14, height: 14)
                    .opacity(isSelected ? 1.0 : 0.7)

                Text("menubar.providers.all".localized())
                    .font(.system(size: 11, weight: isSelected ? .semibold : .medium, design: .rounded))
            }
            .foregroundStyle(isSelected ? .primary : .secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(isSelected ? Color.accentColor.opacity(0.1) : Color.secondary.opacity(0.05))
            )
            .overlay(
                Capsule()
                    .strokeBorder(isSelected ? Color.accentColor.opacity(0.3) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: Provider Filter Button

private struct ProviderFilterButton: View {
    let provider: QuotaProvider
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                ProviderIconMono(provider: provider, size: 14)
                    .opacity(isSelected ? 1.0 : 0.7)
                
                Text(provider.shortName)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .medium, design: .rounded))
            }
            .foregroundStyle(isSelected ? .primary : .secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(isSelected ? Color.accentColor.opacity(0.1) : Color.secondary.opacity(0.05))
            )
            .overlay(
                Capsule()
                    .strokeBorder(isSelected ? Color.accentColor.opacity(0.3) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: Monochrome Provider Icon

private struct ProviderIconMono: View {
    let provider: QuotaProvider
    let size: CGFloat
    
    var body: some View {
        Group {
            if let assetName = provider.menuBarIconAsset,
               let nsImage = NSImage(named: assetName) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .colorMultiply(.primary)
            } else {
                Image(systemName: provider.iconName)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            }
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Network Info View (Proxy + Tunnel Combined)

private struct MenuNetworkInfoView: View {
    let port: String
    let isProxyRunning: Bool
    let tunnelStatus: CloudflareTunnelStatus
    let tunnelURL: String?
    let onProxyToggle: () -> Void
    let onCopyProxyURL: () -> Void
    let onTunnelToggle: () -> Void
    let onCopyTunnelURL: () -> Void

    private var proxyURL: String { "http://127.0.0.1:" + port }

    @State private var didCopyProxy = false
    @State private var didCopyTunnel = false

    private enum CopyTarget {
        case proxy
        case tunnel
    }

    var body: some View {
        VStack(spacing: 8) {
            // Proxy Row
            HStack(spacing: 8) {
                Circle()
                    .fill(isProxyRunning ? Color.green : Color.gray)
                    .frame(width: 6, height: 6)

                Text("providers.source.proxy".localized())
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)

                if isProxyRunning {
                    Text(proxyURL)
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    copyButton(
                        isCopied: didCopyProxy,
                        helpText: "action.copy".localized()
                    ) {
                        onCopyProxyURL()
                        triggerCopyState(.proxy)
                    }
                }

                Spacer()

                Button(action: onProxyToggle) {
                    Image(systemName: isProxyRunning ? "stop.fill" : "play.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(isProxyRunning ? .red : .green)
                }
                .buttonStyle(.plain)
            }

            // Tunnel Row (only show when proxy is running)
            if isProxyRunning {
                HStack(spacing: 8) {
                    Circle()
                        .fill(tunnelStatus == .active ? Color.blue : Color.gray)
                        .frame(width: 6, height: 6)

                    Text(tunnelStatus == .active ? "tunnel.action.stop".localized() : "tunnel.action.start".localized())
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)

                    if tunnelStatus == .active, let url = tunnelURL {
                        Text(url.replacingOccurrences(of: "https://", with: ""))
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.blue)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        copyButton(
                            isCopied: didCopyTunnel,
                            helpText: "action.copy".localized()
                        ) {
                            onCopyTunnelURL()
                            triggerCopyState(.tunnel)
                        }
                    } else if tunnelStatus == .starting {
                        Text("status.starting".localized())
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }

                    Spacer()

                    Button(action: onTunnelToggle) {
                        Image(systemName: tunnelStatus == .active || tunnelStatus == .starting ? "stop.fill" : "play.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(tunnelStatus == .active ? .red : .blue)
                    }
                    .buttonStyle(.plain)
                    .disabled(tunnelStatus == .starting || tunnelStatus == .stopping)
                }
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    private func triggerCopyState(_ target: CopyTarget) {
        setCopied(target, value: true)

        Task {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            await MainActor.run {
                setCopied(target, value: false)
            }
        }
    }

    private func setCopied(_ target: CopyTarget, value: Bool) {
        withAnimation(.easeInOut(duration: 0.2)) {
            switch target {
            case .proxy:
                didCopyProxy = value
            case .tunnel:
                didCopyTunnel = value
            }
        }
    }

    @ViewBuilder
    private func copyButton(isCopied: Bool, helpText: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: isCopied ? "checkmark.circle.fill" : "doc.on.doc")
                .font(.system(size: 10))
                .foregroundStyle(isCopied ? .green : .secondary)
                .scaleEffect(isCopied ? 1.05 : 1)
                .animation(.easeInOut(duration: 0.2), value: isCopied)
        }
        .buttonStyle(.plain)
        .help(helpText)
    }
}

// MARK: Account Card View

private struct MenuAccountCardView: View {
    let accountKey: String
    let email: String
    let data: ProviderQuota
    let provider: QuotaProvider
    let subscriptionInfo: QuotaSubscriptionInfo?
    let isActiveInIDE: Bool
    let isRefreshing: Bool
    let canRefresh: Bool
    /// This card's group's channel color, when its group is multi-account and this
    /// card should show its own "权重 N" — `nil` hides the account weight entirely
    /// (single-account group), independent of whether `data.routingWeight` exists.
    let accountWeightAccent: Color?
    let settings: StatusBarMenuDisplaySettings
    let onRefresh: () -> Void
    let onUseAccount: (() -> Void)?

    @State private var isHovered = false
    @State private var isUseHovered = false
    @State private var isUsingAccount = false
    
    private var displayEmail: String {
        email.masked(if: settings.hideSensitiveInfo)
    }
    
    /// Tier/plan badge name — every tier now renders in the same neutral outlined
    /// style (§4 of the A4 handoff), so this only needs the display name, not a
    /// per-tier color.
    private var tierName: String? {
        if let info = subscriptionInfo {
            let tierId = info.tierId.lowercased()
            let tierName = info.tierDisplayName.lowercased()

            if tierId.contains("ultra") || tierName.contains("ultra") {
                return "Ultra"
            }
            if tierId.contains("pro") || tierName.contains("pro") {
                return "Pro"
            }
            if tierId.contains("standard") || tierId.contains("free") ||
               tierName.contains("standard") || tierName.contains("free") {
                return "Free"
            }
            return info.tierDisplayName
        }

        if provider == .codex, let planName = codexPlanDisplayName(data.planType) {
            return neutralPlanName(for: planName)
        }

        guard let planName = data.planDisplayName else { return nil }
        return neutralPlanName(for: planName)
    }

    private func codexPlanDisplayName(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }

        let exact = [
            "pro": "Pro 20x",
            "prolite": "Pro 5x",
            "pro_lite": "Pro 5x",
            "pro-lite": "Pro 5x",
            "pro lite": "Pro 5x"
        ]
        if let value = exact[trimmed.lowercased()] {
            return value
        }

        let cleaned = trimmed
            .replacingOccurrences(of: #"(?i)\b(claude|codex|account|plan)\b"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
            .joined(separator: " ")
        if let value = exact[cleaned.lowercased()] {
            return value
        }

        let display = cleaned.split(separator: " ").map { word -> String in
            let lower = word.lowercased()
            if lower == "cbp" || lower == "k12" { return lower.uppercased() }
            if word == word.uppercased(), word.contains(where: { $0.isLetter }) { return String(word) }
            return word.prefix(1).uppercased() + word.dropFirst()
        }.joined(separator: " ")
        return display.isEmpty ? trimmed : display
    }
    
    private func neutralPlanName(for planName: String) -> String {
        let lowercased = planName.lowercased()

        if lowercased.contains("ultra") { return "Ultra" }
        if lowercased.contains("pro") { return "Pro" }
        if lowercased.contains("plus") { return "Plus" }
        if lowercased.contains("team") { return "Team" }
        if lowercased.contains("enterprise") { return "Enterprise" }
        if lowercased.contains("business") { return "Business" }
        if lowercased.contains("free") || lowercased.contains("standard") { return "Free" }

        return planName
    }
    
    private var isAntigravity: Bool {
        provider == .antigravity && !data.models.isEmpty
    }
    
    private var antigravityGroups: [AntigravityDisplayGroup] {
        guard isAntigravity else { return [] }
        let summaryModels = data.models.filter { $0.name.hasPrefix("antigravity-") }
        if !summaryModels.isEmpty {
            return summaryModels
                .map { AntigravityDisplayGroup(name: $0.displayName, percentage: $0.percentage, resetTime: $0.resetTime) }
        }

        var groups: [AntigravityDisplayGroup] = []

        let gemini3ProModels = data.models.filter {
            $0.name.contains("gemini-3-pro") && !$0.name.contains("image")
        }
        if !gemini3ProModels.isEmpty {
            let aggregatedPercent = settings.aggregateModelPercentages(gemini3ProModels.map(\.percentage))
            let minModel = gemini3ProModels.min(by: { $0.percentage < $1.percentage })
            groups.append(AntigravityDisplayGroup(name: "Gemini 3 Pro", percentage: aggregatedPercent, resetTime: minModel?.resetTime))
        }

        let gemini3FlashModels = data.models.filter { $0.name.contains("gemini-3-flash") }
        if !gemini3FlashModels.isEmpty {
            let aggregatedPercent = settings.aggregateModelPercentages(gemini3FlashModels.map(\.percentage))
            let minModel = gemini3FlashModels.min(by: { $0.percentage < $1.percentage })
            groups.append(AntigravityDisplayGroup(name: "Gemini 3 Flash", percentage: aggregatedPercent, resetTime: minModel?.resetTime))
        }

        let geminiImageModels = data.models.filter { $0.name.contains("image") }
        if !geminiImageModels.isEmpty {
            let aggregatedPercent = settings.aggregateModelPercentages(geminiImageModels.map(\.percentage))
            let minModel = geminiImageModels.min(by: { $0.percentage < $1.percentage })
            groups.append(AntigravityDisplayGroup(name: "Gemini 3 Image", percentage: aggregatedPercent, resetTime: minModel?.resetTime))
        }

        let claudeModels = data.models.filter { $0.name.contains("claude") }
        if !claudeModels.isEmpty {
            let aggregatedPercent = settings.aggregateModelPercentages(claudeModels.map(\.percentage))
            let minModel = claudeModels.min(by: { $0.percentage < $1.percentage })
            groups.append(AntigravityDisplayGroup(name: "Claude 4.5", percentage: aggregatedPercent, resetTime: minModel?.resetTime))
        }

        return groups.sorted { $0.percentage < $1.percentage }
    }
    
    /// "N reset credits · next expiry yyyy-MM-dd HH:mm JST" for a CPA Codex account
    /// whose most recent fetch reported reset-credit data — `nil` (never a fabricated
    /// "0") when that data hasn't been fetched successfully yet. Per-account only,
    /// reusing the same `ProviderQuota.codexResetCreditSummary` already carried by this
    /// card's own `data` — never a separate card or badge.
    private var codexResetCreditsText: String? {
        guard provider == .codex else { return nil }
        return data.codexResetCreditSummary?.compactFormattedSummary
    }

    private static let frozenColor = Color(red: 0.93, green: 0.35, blue: 0.13)

    /// Icon/label/color for the freeze/cooldown status marker shown left of the tier
    /// badge — `nil` for a normal, currently-usable account (`data.availabilityStatus`).
    private var availabilityMarker: (icon: String, label: String, color: Color)? {
        switch data.availabilityStatus {
        case .authInvalid:
            return ("exclamationmark.triangle.fill", "quota.account.oauthInvalid".localized(), MenuBarPalette.quotaDanger)
        case .frozen:
            return ("lock.fill", "quota.account.frozen".localized(), Self.frozenColor)
        case .cooling:
            return ("clock.fill", "quota.account.cooling".localized(), MenuBarPalette.quotaWarning)
        case .sessionExhausted, .weeklyExhausted, .sessionAndWeeklyExhausted:
            // Rendered by `exhaustionBadge` instead — a distinct hourglass/countdown
            // shape, not this icon+label capsule.
            return nil
        case nil:
            return nil
        }
    }

    /// "3h32m 后解封"/"3h48m 后恢复"-style estimate, or the explicit "time unknown"
    /// fallback when this account's last-known-good reading carries no future reset
    /// time to count down to (`data.formattedAvailabilityCountdown`) — never a
    /// fabricated guess. `nil` for a normal, currently-usable account, and for the
    /// exhausted-metric statuses, which get their own `exhaustionBadge` tooltip
    /// instead of this frozen/cooling-only line.
    private var availabilityCountdownText: String? {
        guard let status = data.availabilityStatus else { return nil }
        guard status == .frozen || status == .cooling else { return nil }
        if let countdown = data.formattedAvailabilityCountdown {
            let key = status == .frozen ? "quota.account.frozenCountdown" : "quota.account.coolingCountdown"
            return String(format: key.localized(), countdown)
        }
        let key = status == .frozen ? "quota.account.frozenUnknown" : "quota.account.coolingUnknown"
        return key.localized()
    }

    /// Badge/tooltip/accessibility text for a CPA Codex account whose `codex-session`
    /// and/or `codex-weekly` quota metric has reached 0% — hourglass + compact
    /// countdown to whichever reset(s) still apply (the later of the two when both
    /// windows are exhausted). Scoped to `provider == .codex`: the underlying
    /// `codex-session`/`codex-weekly` metric names are Codex-only, but this guard
    /// keeps the new badge from ever appearing on another provider's card even if
    /// that ever changed. `nil` for every other status.
    private var exhaustionBadge: (countdownText: String, tooltip: String, accessibilityText: String)? {
        guard provider == .codex else { return nil }
        let statusLabelKey: String
        switch data.availabilityStatus {
        case .sessionExhausted: statusLabelKey = "quota.account.sessionExhausted"
        case .weeklyExhausted: statusLabelKey = "quota.account.weeklyExhausted"
        case .sessionAndWeeklyExhausted: statusLabelKey = "quota.account.sessionAndWeeklyExhausted"
        default: return nil
        }
        let statusLabel = statusLabelKey.localized()
        let countdownText = data.formattedQuotaExhaustionCountdown ?? "—"
        let tooltip: String
        if let absolute = data.formattedQuotaExhaustionAbsolute {
            tooltip = String(format: "quota.account.recoversAt".localized(), statusLabel, absolute)
        } else {
            tooltip = statusLabel + " · " + "quota.account.quotaResetUnknown".localized()
        }
        return (countdownText, tooltip, tooltip)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            headerSection

            quotaContentSection

            if let availabilityCountdownText {
                // The absolute recovery time is auxiliary detail, not shown as its own
                // line — it rides along as a hover tooltip on the same countdown text
                // instead, so the two never compete for space. Absent (empty tooltip,
                // which `menuNativeTooltip` treats as "no tooltip") when the countdown
                // itself is already the "time unknown" fallback.
                Text(availabilityCountdownText)
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .menuNativeTooltip(data.formattedAvailabilityAbsolute ?? "")
            }

            footerSection
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isHovered ? Color.secondary.opacity(0.08) : Color.secondary.opacity(0.04))
        )
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .onHover { isHovered = $0 }
    }
    
    // MARK: - Header
    
    private var headerSection: some View {
        HStack(alignment: .center, spacing: 8) {
            // Provider Icon
            ProviderIconMono(provider: provider, size: 16)
                .foregroundStyle(.secondary)
                .opacity(0.8)
            
            // Email
            Text(displayEmail)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(.primary)
                .lineLimit(1)
            
            Spacer()

            Button(action: onRefresh) {
                if isRefreshing {
                    ProgressView()
                        .controlSize(.mini)
                        .frame(width: 20, height: 20)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                }
            }
            .buttonStyle(.plain)
            .disabled(!canRefresh)
            .help("action.refreshQuota".localized())

            // Exhausted-window countdown badge — same slot as the freeze/cooldown
            // marker below (the two are mutually exclusive via `data.availabilityStatus`).
            // Never wraps: the email above gives way first at narrow widths.
            if let initialExhaustionBadge = exhaustionBadge {
                // The countdown text/tooltip are derived from `Date()` at read time, but
                // this view has no state of its own driving a re-render while the menu
                // stays open — `TimelineView` re-reads `exhaustionBadge` every minute so
                // the badge doesn't freeze at whatever value it first rendered with.
                TimelineView(.periodic(from: .now, by: 60)) { _ in
                    let badge = exhaustionBadge ?? initialExhaustionBadge
                    HStack(spacing: 3) {
                        Image(systemName: "hourglass.bottomhalf.filled")
                            .font(.system(size: 9, weight: .semibold))
                        Text(badge.countdownText)
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .foregroundStyle(MenuBarPalette.quotaWarning)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(MenuBarPalette.quotaWarning.opacity(0.15))
                    .clipShape(Capsule())
                    .menuNativeTooltip(badge.tooltip)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(badge.accessibilityText)
                }
            }

            // Freeze/cooldown status marker — placed left of the tier badge, never
            // shown for a normal, currently-usable account.
            if let marker = availabilityMarker {
                HStack(spacing: 3) {
                    Image(systemName: marker.icon)
                        .font(.system(size: 9, weight: .semibold))
                    Text(marker.label)
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                }
                .foregroundStyle(marker.color)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(marker.color.opacity(0.15))
                .clipShape(Capsule())
            }

            // Tier Badge — neutral outlined style for every tier/plan (§4), so the
            // badge never competes with the green/amber/coral quota-state colors or a
            // channel color.
            if let tierName {
                Text(tierName)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .overlay(
                        Capsule()
                            .strokeBorder(Color.primary.opacity(0.16), lineWidth: 1)
                    )
                    .clipShape(Capsule())
            }
            
            // Active/Use Badge
            if isActiveInIDE {
                Text("antigravity.active".localized())
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.green)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.green.opacity(0.12))
                    .overlay(
                        Capsule()
                            .strokeBorder(Color.green.opacity(0.25), lineWidth: 1)
                    )
                    .clipShape(Capsule())
            } else if let onUse = onUseAccount {
                Button {
                    isUsingAccount = true
                    Task { @MainActor in
                        onUse()
                        try? await Task.sleep(nanoseconds: 650_000_000)
                        isUsingAccount = false
                    }
                } label: {
                    HStack(spacing: 6) {
                        if isUsingAccount {
                            ProgressView()
                                .controlSize(.mini)
                        }
                        Text("antigravity.useInIDE".localized() + " " + "→".localized())
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(isUseHovered ? Color.secondary.opacity(0.12) : Color.secondary.opacity(0.06))
                    .overlay(
                        Capsule()
                            .strokeBorder(Color.secondary.opacity(isUseHovered ? 0.45 : 0.25), lineWidth: 1)
                    )
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(isUsingAccount)
                .onHover { isUseHovered = $0 }
            }
        }
    }
    
    // MARK: - Quota Content
    
    private var quotaContentSection: some View {
        let isCardStyle = displayStyle == .card
        let models: [ModelBadgeData] = {
            if isAntigravity {
                return antigravityGroups.map { ModelBadgeData(name: $0.name, percentage: $0.percentage, resetTime: $0.resetTime) }
            } else {
                let meterModels = data.models.filter { !$0.isStandaloneMetric }.map {
                    ModelBadgeData(name: $0.displayName, percentage: $0.percentage, resetTime: $0.resetTime)
                }
                guard isCardStyle else { return meterModels }
                let standaloneModels = data.models.filter(\.isStandaloneMetric).map {
                    ModelBadgeData(name: $0.displayName, percentage: $0.percentage, resetTime: $0.resetTime, usage: $0.formattedUsage)
                }
                return meterModels + standaloneModels
            }
        }()
        let standaloneModels = isAntigravity || isCardStyle ? [] : data.models.filter(\.isStandaloneMetric)
        let factorySections = provider == .factoryDroid
            ? FactoryDroidQuotaSection.sections(from: data.models.filter { !$0.isStandaloneMetric })
            : []
        
        return VStack(spacing: 8) {
            if models.isEmpty && standaloneModels.isEmpty {
                Text("dashboard.noQuotaData".localized())
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 8)
            } else if !factorySections.isEmpty {
                ForEach(factorySections) { section in
                    VStack(alignment: .leading, spacing: 6) {
                        FactoryDroidMenuSectionHeader(title: section.title)
                        quotaLayout(models: section.models.map {
                            ModelBadgeData(name: $0.displayName, percentage: $0.percentage, resetTime: $0.resetTime)
                        })
                    }
                }
            } else if !models.isEmpty {
                quotaLayout(models: models)
            }

            ForEach(standaloneModels) { model in
                HStack(spacing: 8) {
                    Text(model.displayName)
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(model.formattedUsage ?? "—")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.primary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .menuNativeTooltip(model.tooltip ?? "")
            }
        }
    }

    @ViewBuilder
    private func quotaLayout(models: [ModelBadgeData]) -> some View {
        switch settings.quotaDisplayStyle {
        case .lowestBar:
            LowestBarLayout(models: models, displayMode: settings.quotaDisplayMode)
        case .ring:
            RingGridLayout(models: models, displayMode: settings.quotaDisplayMode)
        case .card:
            CardGridLayout(models: models, displayMode: settings.quotaDisplayMode)
        }
    }
    
    // MARK: - Footer

    /// Per-metric reset info lives inside each metric, so the footer carries only the
    /// reset-credit summary and the "last updated" stamp. They share a single row —
    /// summary leading, stamp trailing — whenever both fit on it, and fall back to
    /// stacked lines (stamp still trailing) only when the row is too narrow.
    @ViewBuilder
    private var footerSection: some View {
        if let codexResetCreditsText {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 0) {
                    resetCreditsLabel(codexResetCreditsText)
                        .lineLimit(1)
                    Spacer(minLength: 12)
                    footerTrailingGroup
                }

                VStack(alignment: .leading, spacing: 4) {
                    resetCreditsLabel(codexResetCreditsText)
                        .lineLimit(2)
                    HStack(spacing: 0) {
                        Spacer(minLength: 0)
                        footerTrailingGroup
                    }
                }
            }
        } else {
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                footerTrailingGroup
            }
        }
    }

    private func resetCreditsLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, design: .rounded))
            .foregroundStyle(.secondary)
    }

    /// Account weight (when available) plus the "N分钟前" stamp, 8pt apart. `if let`
    /// (no `else`) around the weight label contributes no spacing when it is hidden —
    /// the same pattern `headerSection`'s own optional badges already rely on — so a
    /// single-account group (`accountWeightAccent == nil`) keeps today's unchanged
    /// footer layout.
    private var footerTrailingGroup: some View {
        HStack(spacing: 8) {
            if let accountWeightAccent, let accountWeightText {
                Group {
                    if (data.routingWeight?.accountWeight ?? 0) > 0 {
                        Text(accountWeightText).foregroundStyle(accountWeightAccent)
                    } else {
                        Text(accountWeightText).foregroundStyle(.tertiary)
                    }
                }
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            }
            lastUpdatedLabel
        }
    }

    /// `menu.weight.account` text for this card's own `data.routingWeight` — `nil`
    /// (hidden entirely, never a placeholder) when the cache has no weight for this
    /// account, the pool errored, or the source isn't cache-enabled. A genuine `0`
    /// reading still renders (in a dimmer color), since it's a real value, not a
    /// missing one. Gated on `accountWeightAccent` in `footerTrailingGroup` above, so a
    /// single-account group never shows this even when the reading exists.
    private var accountWeightText: String? {
        guard let weight = data.routingWeight else { return nil }
        return String(format: "menu.weight.account".localized(), weight.accountWeight)
    }

    private var lastUpdatedLabel: some View {
        Text(data.lastUpdated.formatted(.relative(presentation: .named)))
            .font(.system(size: 10, design: .rounded))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: true, vertical: false)
    }
    
    private var displayStyle: QuotaDisplayStyle { settings.quotaDisplayStyle }
    
    private var primaryResetModel: QuotaMetric? {
        let formatter = ISO8601DateFormatter()
        let now = Date()
        
        let validModels = data.models.filter { model in
            guard let date = formatter.date(from: model.resetTime) else { return false }
            return date > now
        }
        
        return validModels.sorted { m1, m2 in
            if abs(m1.percentage - m2.percentage) > 0.1 {
                return m1.percentage < m2.percentage
            }
            let d1 = formatter.date(from: m1.resetTime) ?? Date.distantFuture
            let d2 = formatter.date(from: m2.resetTime) ?? Date.distantFuture
            return d1 < d2
        }.first
    }
    
    private func formatLocalTime(_ isoString: String) -> String {
        // Try parsing with fractional seconds first, then standard format
        let isoFormatterWithFractional = ISO8601DateFormatter()
        isoFormatterWithFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let isoFormatterStandard = ISO8601DateFormatter()
        isoFormatterStandard.formatOptions = [.withInternetDateTime]

        guard let date = isoFormatterWithFractional.date(from: isoString)
              ?? isoFormatterStandard.date(from: isoString) else { return "" }

        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

private struct FactoryDroidMenuSectionHeader: View {
    let title: String

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 1)
        }
    }
}

private struct AnalyticsDetailSection: View {
    let analytics: QuotaAnalytics

    @State private var trendMode: AnalyticsTrendMode = .daily

    private static let primaryMetricRowIDs = [
        "codex-lifetime-tokens",
        "codex-peak-daily",
        "codex-longest-task",
        "codex-current-streak",
        "codex-longest-streak"
    ]

    private static let usageMetricRowIDs = [
        "codex-extra-usage",
        "today",
        "yesterday",
        "last-30-days"
    ]

    private static let hiddenRowIDs = Set(primaryMetricRowIDs + usageMetricRowIDs)
    private static let resetCreditsSummaryID = "codex-rate-limit-resets"
    private static let resetCreditRowPrefix = "codex-rate-limit-reset-"

    private var metricRows: [QuotaAnalyticsRow] {
        metricRows(for: Self.primaryMetricRowIDs)
    }

    private var usageRows: [QuotaAnalyticsRow] {
        metricRows(for: Self.usageMetricRowIDs)
    }

    private var shouldShowNote: Bool {
        metricRows.isEmpty && usageRows.isEmpty && resetCreditsSummary == nil
    }

    private func metricRows(for ids: [String]) -> [QuotaAnalyticsRow] {
        let rowsByID = analytics.rows.reduce(into: [String: QuotaAnalyticsRow]()) { result, row in
            result[row.id] = result[row.id] ?? row
        }
        return ids.compactMap { rowsByID[$0] }
    }

    private var detailRows: [QuotaAnalyticsRow] {
        analytics.rows.filter {
            !Self.hiddenRowIDs.contains($0.id)
                && $0.id != Self.resetCreditsSummaryID
                && !$0.id.hasPrefix(Self.resetCreditRowPrefix)
        }
    }

    private var resetCreditsSummary: QuotaAnalyticsRow? {
        analytics.rows.first { $0.id == Self.resetCreditsSummaryID }
    }

    private var resetCreditRows: [QuotaAnalyticsRow] {
        analytics.rows.filter { $0.id.hasPrefix(Self.resetCreditRowPrefix) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            if !metricRows.isEmpty {
                AnalyticsMetricStripView(rows: metricRows)
            }

            if !usageRows.isEmpty {
                AnalyticsMetricStripView(rows: usageRows)
            }

            if let resetCreditsSummary {
                ResetCreditsInventoryView(summary: resetCreditsSummary, credits: resetCreditRows)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Usage Trend")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(.primary)

                    Spacer()

                    if analytics.trend.isEmpty {
                        Text("No data")
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                    } else {
                        AnalyticsTrendModePicker(selection: $trendMode)
                    }
                }

                if !analytics.trend.isEmpty {
                    UsageTrendHeatmap(points: analytics.trend, mode: trendMode)
                        .id(trendMode)
                }
            }

            ForEach(detailRows) { row in
                AnalyticsRowView(row: row)
            }

            if shouldShowNote, let note = analytics.note, !note.isEmpty {
                Text(note)
                    .font(.system(size: 9, design: .rounded))
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
    }
}

private struct ResetCreditsInventoryView: View {
    let summary: QuotaAnalyticsRow
    let credits: [QuotaAnalyticsRow]

    private var countLabel: String {
        let count = summary.value.split(separator: " ").first.map(String.init) ?? "0"
        return "\(count) resets available"
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "gift")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.blue)

            Text(countLabel)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)

            Spacer(minLength: 12)

            HStack(spacing: 6) {
                ForEach(Array(credits.enumerated()), id: \.element.id) { index, credit in
                    ResetCreditChip(
                        label: compactRelativeLabel(credit.value),
                        tooltip: creditTooltip(credit),
                        isNext: index == 0
                    )
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.025))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(.separator.opacity(0.45), lineWidth: 1)
        )
    }

    private func compactRelativeLabel(_ value: String) -> String {
        let lowercased = value.lowercased()
        let parts = lowercased.split(separator: " ")
        guard parts.count >= 3, parts.first == "in", let number = parts.dropFirst().first else {
            return value.isEmpty ? "∞" : value
        }

        let unit = parts.dropFirst(2).first ?? ""
        if unit.hasPrefix("day") { return "\(number)d" }
        if unit.hasPrefix("hour") { return "\(number)h" }
        if unit.hasPrefix("minute") { return "\(number)m" }
        return String(number)
    }

    private func creditTooltip(_ credit: QuotaAnalyticsRow) -> String {
        let suffix = credit.value.isEmpty ? "" : " - \(credit.value)"
        return "Expires: \(credit.title)\(suffix)"
    }
}

private struct ResetCreditChip: View {
    let label: String
    let tooltip: String
    let isNext: Bool

    var body: some View {
        Text(label)
            .font(.system(size: 12, weight: .medium, design: .monospaced))
            .foregroundStyle(isNext ? Color.blue : .secondary)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule(style: .continuous)
                    .fill(isNext ? Color.blue.opacity(0.18) : Color.primary.opacity(0.08))
            )
            .contentShape(Capsule(style: .continuous))
            .menuNativeTooltip(tooltip)
    }
}

private struct AnalyticsMetricStripView: View {
    let rows: [QuotaAnalyticsRow]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                AnalyticsMetricTileView(row: row)
                    .frame(maxWidth: .infinity)

                if index < rows.count - 1 {
                    Rectangle()
                        .fill(.separator.opacity(0.45))
                        .frame(width: 1, height: 34)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.025))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(.separator.opacity(0.45), lineWidth: 1)
        )
    }
}

private struct AnalyticsMetricTileView: View {
    let row: QuotaAnalyticsRow

    private var displayValue: String {
        switch row.id {
        case "codex-lifetime-tokens", "codex-peak-daily":
            row.value.replacingOccurrences(of: " tokens", with: "")
        default:
            row.value
        }
    }

    var body: some View {
        VStack(spacing: 4) {
            Text(displayValue)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(row.isAvailable ? .primary : .secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            Text(row.title)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 6)
        .frame(minWidth: 82)
    }
}

private enum AnalyticsTrendMode: String, CaseIterable, Identifiable {
    case daily
    case weekly
    case cumulative

    var id: String { rawValue }

    var title: String {
        switch self {
        case .daily: "Daily"
        case .weekly: "Weekly"
        case .cumulative: "Cumulative"
        }
    }
}

private struct AnalyticsTrendModePicker: View {
    @Binding var selection: AnalyticsTrendMode

    var body: some View {
        HStack(spacing: 8) {
            ForEach(AnalyticsTrendMode.allCases) { mode in
                Button {
                    selection = mode
                } label: {
                    Text(mode.title)
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(selection == mode ? .primary : .tertiary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private enum AnalyticsTrendSeries {
    typealias ParsedPoint = (date: Date, point: QuotaAnalyticsPoint)

    static func dailyPoints(from points: [QuotaAnalyticsPoint]) -> [QuotaAnalyticsPoint] {
        parsedPoints(from: points).map { item in
            QuotaAnalyticsPoint(
                date: dayLabel(for: item.date),
                value: item.point.value,
                label: "on \(shortDateLabel(for: item.date))",
                valueLabel: item.point.valueLabel.isEmpty ? tokenLabel(item.point.value) : item.point.valueLabel
            )
        }
    }

    static func weeklyBuckets(from points: [QuotaAnalyticsPoint], mode: AnalyticsTrendMode) -> [AnalyticsTrendBucket] {
        let parsed = parsedPoints(from: points)
        let grouped = Dictionary(grouping: parsed) { item in
            startOfWeek(containing: item.date)
        }
        switch mode {
        case .daily, .weekly:
            return grouped.keys.sorted().map { weekStart in
                let weeklyValue = grouped[weekStart, default: []].reduce(0) { total, item in
                    total + item.point.value
                }
                return AnalyticsTrendBucket(
                    weekStart: weekStart,
                    value: weeklyValue,
                    valueLabel: tokenLabel(weeklyValue),
                    tooltipLabel: "on week of \(longDateLabel(for: weekStart))"
                )
            }
        case .cumulative:
            let sortedWeeks = grouped.keys.sorted()
            guard let first = sortedWeeks.first, let last = sortedWeeks.last else {
                return []
            }

            var buckets: [AnalyticsTrendBucket] = []
            var runningTotal = 0.0
            var weekStart = first

            while weekStart <= last {
                runningTotal += grouped[weekStart, default: []].reduce(0) { total, item in
                    total + item.point.value
                }
                buckets.append(AnalyticsTrendBucket(
                    weekStart: weekStart,
                    value: runningTotal,
                    valueLabel: tokenLabel(runningTotal),
                    tooltipLabel: "through week of \(longDateLabel(for: weekStart))"
                ))

                guard let nextWeek = calendar.date(byAdding: .day, value: 7, to: weekStart) else {
                    break
                }
                weekStart = nextWeek
            }

            return buckets
        }
    }

    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.firstWeekday = 1
        return calendar
    }

    static func dayLabel(for date: Date) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = components.year, let month = components.month, let day = components.day else {
            return "Unknown"
        }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    private static func parsedPoints(from points: [QuotaAnalyticsPoint]) -> [ParsedPoint] {
        points.compactMap { point in
            guard let date = date(from: point.date) else { return nil }
            return (calendar.startOfDay(for: date), point)
        }
        .sorted { $0.date < $1.date }
    }

    private static func startOfWeek(containing date: Date) -> Date {
        let components = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        return calendar.date(from: components).map { calendar.startOfDay(for: $0) } ?? date
    }

    private static func date(from string: String) -> Date? {
        let day = String(string.prefix(10))
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    private static func shortDateLabel(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d"
        return formatter.string(from: date)
    }

    private static func longDateLabel(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d, yyyy"
        return formatter.string(from: date)
    }

    private static func tokenLabel(_ value: Double) -> String {
        let absoluteValue = abs(value)
        if absoluteValue >= 1_000_000_000 {
            return "\(compactNumber(value / 1_000_000_000))B tokens"
        }
        if absoluteValue >= 1_000_000 {
            return "\(compactNumber(value / 1_000_000))M tokens"
        }
        if absoluteValue >= 1_000 {
            return "\(compactNumber(value / 1_000))K tokens"
        }
        return "\(Int(value.rounded())) tokens"
    }

    private static func compactNumber(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        if rounded.truncatingRemainder(dividingBy: 1) == 0 {
            return "\(Int(rounded))"
        }
        return String(format: "%.1f", rounded)
    }
}

private struct AnalyticsTrendBucket: Identifiable {
    var id: String { AnalyticsTrendSeries.dayLabel(for: weekStart) }
    let weekStart: Date
    let value: Double
    let valueLabel: String
    let tooltipLabel: String
}

private struct UsageTrendHeatmap: View {
    let points: [QuotaAnalyticsPoint]
    let mode: AnalyticsTrendMode

    @State private var hoveredCellID: String?
    @State private var hoveredText: String?

    private let cellSize: CGFloat = 9
    private let spacing: CGFloat = 2.4

    private var calendar: Calendar {
        AnalyticsTrendSeries.calendar
    }

    private var parsedPoints: [(date: Date, point: QuotaAnalyticsPoint)] {
        AnalyticsTrendSeries.dailyPoints(from: points).compactMap { point in
            guard let date = Self.date(from: point.date, calendar: calendar) else { return nil }
            return (calendar.startOfDay(for: date), point)
        }
        .sorted { $0.date < $1.date }
    }

    private var heatmapData: HeatmapData {
        switch mode {
        case .daily:
            dailyHeatmapData()
        case .weekly, .cumulative:
            weeklyHeatmapData()
        }
    }

    private func dailyHeatmapData() -> HeatmapData {
        let parsed = parsedPoints
        guard let last = parsed.last?.date else {
            return HeatmapData(weeks: [], monthLabels: [], width: 0)
        }

        let pointByDate = parsed.reduce(into: [Date: QuotaAnalyticsPoint]()) { result, item in
            result[item.date] = item.point
        }
        let maxValue = max(parsed.map(\.point.value).max() ?? 0, 1)
        let first = displayStartDate(endingAt: last)
        let start = startOfWeek(containing: first)
        let days = max(calendar.dateComponents([.day], from: start, to: last).day ?? 0, 0)
        let weekCount = min((days / 7) + 1, 54)

        let weeks = (0..<weekCount).map { weekIndex in
            let cells = (0..<7).map { weekdayIndex -> HeatmapCell in
                let dayOffset = weekIndex * 7 + weekdayIndex
                let date = calendar.date(byAdding: .day, value: dayOffset, to: start) ?? start
                let point = pointByDate[date]
                let intensity = point.map { point in
                    point.value <= 0 ? 0 : max(0.18, min(point.value / maxValue, 1))
                } ?? 0
                let isInRange = date >= first && date <= last
                return HeatmapCell(
                    id: "\(weekIndex)-\(weekdayIndex)",
                    date: date,
                    point: point,
                    intensity: intensity,
                    isInRange: isInRange
                )
            }
            return HeatmapWeek(id: weekIndex, cells: cells)
        }

        let labels = monthLabels(from: start, first: first, last: last, weekCount: weekCount)
        let width = CGFloat(weekCount) * cellSize + CGFloat(max(weekCount - 1, 0)) * spacing
        return HeatmapData(weeks: weeks, monthLabels: labels, width: width)
    }

    private func weeklyHeatmapData() -> HeatmapData {
        let buckets = AnalyticsTrendSeries.weeklyBuckets(from: points, mode: mode)
        guard let last = buckets.last?.weekStart else {
            return HeatmapData(weeks: [], monthLabels: [], width: 0)
        }

        let bucketByWeek = buckets.reduce(into: [Date: AnalyticsTrendBucket]()) { result, bucket in
            result[bucket.weekStart] = bucket
        }
        let maxValue = max(buckets.map(\.value).max() ?? 0, 1)
        let first = startOfWeek(containing: displayStartDate(endingAt: last))
        let days = max(calendar.dateComponents([.day], from: first, to: last).day ?? 0, 0)
        let weekCount = min((days / 7) + 1, 54)

        let weeks = (0..<weekCount).map { weekIndex in
            let weekStart = calendar.date(byAdding: .day, value: weekIndex * 7, to: first) ?? first
            let bucket = bucketByWeek[weekStart]
            let normalizedValue = bucket.map { $0.value <= 0 ? 0 : max(0.14, min($0.value / maxValue, 1)) } ?? 0
            let filledRows = normalizedValue <= 0 ? 0 : max(1, min(Int((normalizedValue * 7).rounded(.up)), 7))

            let cells = (0..<7).map { rowIndex -> HeatmapCell in
                let isFilled = rowIndex >= 7 - filledRows
                let point = bucket.map { bucket -> QuotaAnalyticsPoint in
                    QuotaAnalyticsPoint(
                        date: AnalyticsTrendSeries.dayLabel(for: weekStart),
                        value: bucket.value,
                        label: bucket.tooltipLabel,
                        valueLabel: bucket.valueLabel
                    )
                }

                return HeatmapCell(
                    id: "\(weekIndex)-\(rowIndex)",
                    date: weekStart,
                    point: isFilled ? point : nil,
                    intensity: isFilled ? normalizedValue : 0,
                    isInRange: true
                )
            }
            return HeatmapWeek(id: weekIndex, cells: cells)
        }

        let labels = monthLabels(from: first, first: first, last: last, weekCount: weekCount)
        let width = CGFloat(weekCount) * cellSize + CGFloat(max(weekCount - 1, 0)) * spacing
        return HeatmapData(weeks: weeks, monthLabels: labels, width: width)
    }

    var body: some View {
        let data = heatmapData

        ZStack(alignment: .topTrailing) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 0) {
                    ForEach(data.monthLabels) { label in
                        Text(label.title)
                            .font(.system(size: 9, weight: .medium, design: .rounded))
                            .foregroundStyle(.tertiary)
                            .frame(width: monthLabelWidth(for: label, in: data), alignment: .leading)
                    }
                }
                .frame(width: data.width, height: 12, alignment: .leading)

                HStack(alignment: .top, spacing: spacing) {
                    ForEach(data.weeks) { week in
                        VStack(spacing: spacing) {
                            ForEach(week.cells) { cell in
                                heatmapCell(cell)
                            }
                        }
                    }
                }
                .frame(width: data.width, alignment: .leading)
            }

            if let hoveredText {
                Text(hoveredText)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(
                        Capsule()
                            .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.16), radius: 8, y: 3)
                    .offset(y: 18)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
    }

    private func heatmapCell(_ cell: HeatmapCell) -> some View {
        RoundedRectangle(cornerRadius: 2.4, style: .continuous)
            .fill(fillColor(for: cell))
            .frame(width: cellSize, height: cellSize)
            .opacity(cell.isInRange ? 1 : 0)
            .overlay {
                if hoveredCellID == cell.id, cell.point != nil {
                    RoundedRectangle(cornerRadius: 2.4, style: .continuous)
                        .stroke(Color.primary.opacity(0.18), lineWidth: 1)
                }
            }
            .onHover { hovering in
                updateHover(hovering, cell: cell)
            }
    }

    private func fillColor(for cell: HeatmapCell) -> Color {
        guard cell.intensity > 0 else {
            return Color.primary.opacity(0.06)
        }
        return Color.accentColor.opacity(0.16 + cell.intensity * 0.78)
    }

    private func updateHover(_ hovering: Bool, cell: HeatmapCell) {
        guard let point = cell.point else {
            if !hovering, hoveredCellID == cell.id {
                hoveredCellID = nil
                hoveredText = nil
            }
            return
        }

        if hovering {
            hoveredCellID = cell.id
            hoveredText = point.label.isEmpty
                ? "\(point.valueLabel) on \(Self.shortDateLabel(for: cell.date))"
                : "\(point.valueLabel) \(point.label)"
        } else if hoveredCellID == cell.id {
            hoveredCellID = nil
            hoveredText = nil
        }
    }

    private func monthLabelWidth(for label: MonthLabel, in data: HeatmapData) -> CGFloat {
        guard let index = data.monthLabels.firstIndex(where: { $0.id == label.id }) else {
            return 0
        }
        let nextColumn = data.monthLabels.dropFirst(index + 1).first?.column ?? data.weeks.count
        let columns = max(nextColumn - label.column, 1)
        return CGFloat(columns) * cellSize + CGFloat(max(columns - 1, 0)) * spacing
    }

    private func startOfWeek(containing date: Date) -> Date {
        let components = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        return calendar.date(from: components).map { calendar.startOfDay(for: $0) } ?? date
    }

    private func displayStartDate(endingAt date: Date) -> Date {
        calendar.date(byAdding: .day, value: -370, to: date)
            .map { calendar.startOfDay(for: $0) } ?? date
    }

    private func monthLabels(from start: Date, first: Date, last: Date, weekCount: Int) -> [MonthLabel] {
        var labels: [MonthLabel] = []
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM"

        var components = calendar.dateComponents([.year, .month], from: first)
        components.day = 1
        var monthStart = calendar.date(from: components) ?? first
        if monthStart < first {
            monthStart = calendar.date(byAdding: .month, value: 1, to: monthStart) ?? first
        }

        while monthStart <= last {
            let column = max(calendar.dateComponents([.day], from: start, to: monthStart).day ?? 0, 0) / 7
            if column < weekCount {
                labels.append(MonthLabel(
                    id: AnalyticsTrendSeries.dayLabel(for: monthStart),
                    title: formatter.string(from: monthStart),
                    column: column
                ))
            }
            guard let nextMonth = calendar.date(byAdding: .month, value: 1, to: monthStart) else { break }
            monthStart = nextMonth
        }
        return labels
    }

    private static func date(from string: String, calendar: Calendar) -> Date? {
        let day = String(string.prefix(10))
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    private static func shortDateLabel(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d"
        return formatter.string(from: date)
    }

    private struct HeatmapData {
        let weeks: [HeatmapWeek]
        let monthLabels: [MonthLabel]
        let width: CGFloat
    }

    private struct HeatmapWeek: Identifiable {
        let id: Int
        let cells: [HeatmapCell]
    }

    private struct HeatmapCell: Identifiable {
        let id: String
        let date: Date
        let point: QuotaAnalyticsPoint?
        let intensity: Double
        let isInRange: Bool
    }

    private struct MonthLabel: Identifiable {
        let id: String
        let title: String
        let column: Int
    }
}

private struct AnalyticsRowView: View {
    let row: QuotaAnalyticsRow

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(row.title)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(row.isAvailable ? .primary : .secondary)
                .lineLimit(1)

            Spacer(minLength: 8)

            Text(row.value)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(row.isAvailable ? .primary : .secondary)
                .multilineTextAlignment(.trailing)
                .lineLimit(1)
        }
    }
}

private struct ModelBadgeData: Identifiable {
    let name: String
    let percentage: Double
    let resetTime: String?
    let usage: String?

    init(name: String, percentage: Double, resetTime: String?, usage: String? = nil) {
        self.name = name
        self.percentage = percentage
        self.resetTime = resetTime
        self.usage = usage
    }

    var id: String { name }

    var formattedResetTime: String? {
        guard let resetTime = resetTime else { return nil }

        // Try parsing with fractional seconds first, then standard format
        let isoFormatterWithFractional = ISO8601DateFormatter()
        isoFormatterWithFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let isoFormatterStandard = ISO8601DateFormatter()
        isoFormatterStandard.formatOptions = [.withInternetDateTime]

        guard let date = isoFormatterWithFractional.date(from: resetTime)
              ?? isoFormatterStandard.date(from: resetTime) else { return nil }

        let now = Date()
        let diff = date.timeIntervalSince(now)
        guard diff > 0 else { return nil }

        let totalMinutes = Int(diff) / 60
        let days = totalMinutes / 1440  // 24 * 60
        let hours = (totalMinutes % 1440) / 60
        let minutes = totalMinutes % 60

        if days > 0 {
            return "\(days)d\(hours)h"
        } else if hours > 0 {
            return "\(hours)h\(minutes)m"
        } else {
            return "\(minutes)m"
        }
    }

    /// Compact reset datetime (fixed Asia/Tokyo, no year/`JST` suffix — this dropdown
    /// card is the only caller) shown below the mini panel's progress bar, alongside
    /// — never instead of — `formattedResetTime`'s relative countdown. `nil` (never a
    /// fabricated date) when `resetTime` is missing/unparseable.
    var formattedAbsoluteResetTime: String? {
        guard let resetTime else { return nil }
        return QuotaDateFormatting.compactJST(resetTime)
    }
}

private struct AntigravityDisplayGroup: Identifiable {
    let name: String
    let percentage: Double
    let resetTime: String?

    var id: String { name }
}

private func menuDisplayPercent(remainingPercent: Double, displayMode: QuotaDisplayMode) -> Double {
    displayMode.displayValue(from: remainingPercent)
}

/// Formatted percentage for menu rows. A negative remaining percentage means
/// "no data yet" and renders as a placeholder instead of a fake value like 101%.
private func menuPercentText(remainingPercent: Double, displayMode: QuotaDisplayMode) -> String {
    guard remainingPercent >= 0 else { return "—" }
    return "\(Int(menuDisplayPercent(remainingPercent: remainingPercent, displayMode: displayMode)))%"
}

private func menuStatusColor(remainingPercent: Double, displayMode: QuotaDisplayMode) -> Color {
    guard remainingPercent >= 0 else { return .secondary }
    let usedPercent = 100 - remainingPercent
    let checkValue = displayMode == .used ? usedPercent : remainingPercent

    if displayMode == .used {
        if checkValue < 70 { return MenuBarPalette.quotaNormal }
        if checkValue < 90 { return MenuBarPalette.quotaWarning }
        return MenuBarPalette.quotaDanger
    } else {
        if checkValue > 50 { return MenuBarPalette.quotaNormal }
        if checkValue > 20 { return MenuBarPalette.quotaWarning }
        return MenuBarPalette.quotaDanger
    }
}

// MARK: - Layout Subviews

private struct LowestBarLayout: View {
    let models: [ModelBadgeData]
    let displayMode: QuotaDisplayMode

    private var sorted: [ModelBadgeData] {
        models.sorted { $0.percentage < $1.percentage }
    }

    private var lowest: ModelBadgeData? {
        sorted.first
    }

    private var others: [ModelBadgeData] {
        Array(sorted.dropFirst())
    }

    var body: some View {
        VStack(spacing: 8) {
            if let lowest = lowest {
                // Hero Row for Lowest with reset time
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(lowest.name)
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(.primary)
                        Spacer()
                        PercentageBadge(
                            percentage: lowest.percentage,
                            displayMode: displayMode,
                            style: .textOnly
                        )
                    }

                    ModernProgressBar(
                        percentage: lowest.percentage,
                        height: 8,
                        displayMode: displayMode
                    )

                    if let resetTime = lowest.formattedResetTime {
                        HStack(spacing: 4) {
                            Image(systemName: "clock.arrow.circlepath")
                                .font(.system(size: 9))
                            Text(resetTime)
                                .font(.system(size: 9, weight: .medium, design: .rounded))
                        }
                        .foregroundStyle(.tertiary)
                    }
                }
                .padding(8)
                .background(menuStatusColor(remainingPercent: lowest.percentage, displayMode: displayMode).opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(menuStatusColor(remainingPercent: lowest.percentage, displayMode: displayMode).opacity(0.2), lineWidth: 1)
                )
            }

            // Others as text rows (one per line)
            if !others.isEmpty {
                VStack(spacing: 4) {
                    ForEach(others, id: \.name) { (model: ModelBadgeData) in
                        HStack(spacing: 6) {
                            Text(model.name)
                                .font(.system(size: 10, weight: .medium, design: .rounded))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Spacer()
                            if let resetTime = model.formattedResetTime {
                                Text(resetTime)
                                    .font(.system(size: 9, design: .rounded))
                                    .foregroundStyle(.tertiary)
                            }
                            Text(menuPercentText(remainingPercent: model.percentage, displayMode: displayMode))
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundStyle(menuStatusColor(remainingPercent: model.percentage, displayMode: displayMode))
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
    }
}

private struct RingGridLayout: View {
    let models: [ModelBadgeData]
    let displayMode: QuotaDisplayMode

    private var columnCount: Int {
        min(max(models.count, 1), 4)
    }

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible()), count: columnCount)
    }

    private var ringSize: CGFloat {
        columnCount >= 4 ? 36 : 40
    }

    var body: some View {
        // Auto-distribute 1-4 columns, cap at 4
        LazyVGrid(columns: columns, spacing: 10) {
            ForEach(models, id: \.name) { (model: ModelBadgeData) in
                VStack(spacing: 4) {
                    RingProgressView(percent: menuDisplayPercent(remainingPercent: model.percentage, displayMode: displayMode), size: ringSize, lineWidth: 4, tint: menuStatusColor(remainingPercent: model.percentage, displayMode: displayMode), showLabel: true)

                    Text(model.name)
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)

                    if let resetTime = model.formattedResetTime {
                        Text(resetTime)
                            .font(.system(size: 8, design: .rounded))
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
    }
}

private struct CardGridLayout: View {
    let models: [ModelBadgeData]
    let displayMode: QuotaDisplayMode

    private var columns: [GridItem] {
        // Single metric: full width. Multiple: 2 columns
        if models.count == 1 {
            return [GridItem(.flexible())]
        } else {
            return [GridItem(.flexible()), GridItem(.flexible())]
        }
    }
    
    var body: some View {
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(models, id: \.name) { (model: ModelBadgeData) in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(model.name)
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer()
                        if let resetTime = model.formattedResetTime {
                            Text(resetTime)
                                .font(.system(size: 9, design: .rounded))
                                .foregroundStyle(.tertiary)
                        }
                        if let usage = model.usage {
                            Text(usage)
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundStyle(.primary)
                        } else {
                            Text(menuPercentText(remainingPercent: model.percentage, displayMode: displayMode))
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundStyle(menuStatusColor(remainingPercent: model.percentage, displayMode: displayMode))
                        }
                    }

                    if model.usage == nil {
                        ModernProgressBar(
                            percentage: model.percentage,
                            height: 4,
                            displayMode: displayMode
                        )

                        // Compact absolute reset datetime, always JST (no year/JST
                        // suffix — this card is the dropdown-only exception) —
                        // allowed to wrap to a second line at the dropdown's native
                        // narrow width rather than truncate.
                        if let absoluteReset = model.formattedAbsoluteResetTime {
                            Text(absoluteReset)
                                .font(.system(size: 8, design: .rounded))
                                .foregroundStyle(.tertiary)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(8)
                .background(Color.secondary.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }

}

// MARK: - Shared Components

private struct ModernProgressBar: View {
    let percentage: Double
    let height: CGFloat
    let displayMode: QuotaDisplayMode
    
    private var displayPercent: Double {
        menuDisplayPercent(remainingPercent: percentage, displayMode: displayMode)
    }
    
    var color: Color {
        menuStatusColor(remainingPercent: percentage, displayMode: displayMode)
    }
    
    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.15))
                
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [color, color.opacity(0.8)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: proxy.size.width * min(1, max(0, displayPercent / 100)))
            }
        }
        .frame(height: height)
    }
}

private struct PercentageBadge: View {
    let percentage: Double
    let displayMode: QuotaDisplayMode
    var style: Style = .pill
    
    enum Style { case pill, textOnly }
    
    var color: Color {
        menuStatusColor(remainingPercent: percentage, displayMode: displayMode)
    }

    private var displayText: String {
        menuPercentText(remainingPercent: percentage, displayMode: displayMode)
    }

    var body: some View {
        switch style {
        case .pill:
            Text(displayText)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(color)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(color.opacity(0.1))
                .clipShape(Capsule())
        case .textOnly:
            Text(displayText)
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(color)
        }
    }
}

// MARK: Model Detail View (for submenu)

private struct MenuModelDetailView: View {
    let model: QuotaMetric
    let showRawName: Bool
    let settings: StatusBarMenuDisplaySettings

    private var statusColor: Color {
        menuStatusColor(remainingPercent: model.percentage, displayMode: settings.quotaDisplayMode)
    }

    var body: some View {
        let displayMode = settings.quotaDisplayMode
        let displayStyle = settings.quotaDisplayStyle
        let displayPercent = menuDisplayPercent(remainingPercent: model.percentage, displayMode: displayMode)

        HStack(spacing: 8) {
            Text(showRawName ? model.name : model.displayName)
                .font(.system(size: 11, weight: .medium, design: showRawName ? .monospaced : .rounded))
                .foregroundStyle(.primary)
                .lineLimit(1)

            Spacer()

            if let usage = model.formattedUsage {
                Text(usage)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }

            if !model.isStandaloneMetric && displayStyle != .ring {
                Text(displayPercent >= 0
                    ? String(format: "%.0f%% %@", displayPercent, displayMode.suffixKey.localized())
                    : "—")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(statusColor)
            }

            if !model.isStandaloneMetric && model.formattedResetTime != "—" && !model.formattedResetTime.isEmpty {
                Text(model.formattedResetTime)
                    .font(.system(size: 9, design: .rounded))
                    .foregroundStyle(.tertiary)
            }

            if !model.isStandaloneMetric && displayStyle == .ring {
                if RingProgressView.isUnknown(displayPercent) {
                    // A 14pt ring has no room for a label, so replace it with the
                    // same placeholder the other display styles render.
                    Text("—")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(statusColor)
                        .accessibilityLabel("usage.ring".localized())
                        .accessibilityValue("quota.noDataYet".localized())
                } else {
                    RingProgressView(percent: displayPercent, size: 14, lineWidth: 2, tint: statusColor)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

// MARK: Empty State View

private struct MenuEmptyStateView: View {
    var body: some View {
        VStack(spacing: 6) {
            Text("menubar.noData".localized())
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .padding(.horizontal, 12)
    }
}

// MARK: View More Accounts

private struct MenuViewMoreAccountsView: View {
    let remainingCount: Int
    let isExpanded: Bool
    let onToggle: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 6) {
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 180 : 0))
                    .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isExpanded)

                Text(isExpanded ? "menubar.hideAccounts".localized() : "menubar.viewMoreAccounts".localized())
                    .font(.system(size: 12, weight: .medium))

                if remainingCount > 0 {
                    Text("+\(remainingCount)")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.08))
                        .clipShape(Capsule())
                        .opacity(isExpanded ? 0 : 1)
                        .animation(.easeInOut(duration: 0.2), value: isExpanded)
                }

                Spacer()
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .background(isHovered ? Color.secondary.opacity(0.1) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .onHover { isHovered = $0 }
    }
}

// MARK: - QuotaProvider Extension

private extension QuotaProvider {
    var shortName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .cursor: return "Cursor"
        case .copilot: return "Copilot"
        case .trae: return "Trae"
        case .antigravity: return "Antigravity"
        case .qwen: return "Qwen"
        case .iflow: return "iFlow"
        case .vertex: return "Vertex"
        case .kiro: return "Kiro"
        case .factoryDroid: return "Factory Droid"
        case .devin: return "Devin"
        case .grok: return "Grok"
        case .openRouter: return "OpenRouter"
        case .amp: return "Amp"
        case .glm: return "Z.ai"
        case .warp: return "Warp"
        case .clinePass: return "ClinePass"
        }
    }
}

// MARK: - Menu Actions View

private struct MenuActionsView: View {
    let isLoading: Bool
    let onRefresh: () -> Void
    let onOpenApp: () -> Void
    let onQuit: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            MenuBarActionButton(
                icon: "arrow.clockwise",
                title: "action.refresh".localized(),
                isLoading: isLoading,
                action: onRefresh
            )
            .disabled(isLoading)
            
            MenuBarActionButton(
                icon: "macwindow",
                title: "action.openApp".localized(),
                action: onOpenApp
            )
            
            Divider()
                .padding(.vertical, 4)
            
            MenuBarActionButton(
                icon: "xmark.circle",
                title: "action.quit".localized(),
                action: onQuit
            )
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }
}

// MARK: - Menu Bar Action Button

private struct MenuBarActionButton: View {
    let icon: String
    let title: String
    var isLoading: Bool = false
    let action: () -> Void
    
    @State private var isHovered = false
    
    var body: some View {
        Button(action: action) {
            HStack {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .frame(width: 14)
                
                Text(title)
                    .font(.system(size: 13))
                
                Spacer()
                
                if isLoading {
                    SmallProgressView(size: 12)
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .background(isHovered ? Color.secondary.opacity(0.1) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isLoading)
        .onHover { isHovered = $0 }
    }
}
