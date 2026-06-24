//
//  StatusBarManager.swift
//  Quotio
//
//  Custom NSStatusBar manager with native NSMenu for Liquid Glass appearance.
//  Uses NSMenu with SwiftUI hosting views for native macOS styling.
//

import AppKit
import SwiftUI

@MainActor
@Observable
final class StatusBarManager: NSObject, NSMenuDelegate {
    static let shared = StatusBarManager()
    
    private var statusItem: NSStatusItem?
    private var menu: NSMenu?
    private var menuContentVersion: Int = 0
    private var isRebuildingMenu = false
    private var hasPendingMenuRebuild = false
    
    // Native menu builder
    private var menuBuilder: StatusBarMenuBuilder?
    private weak var viewModel: QuotaViewModel?
    
    private override init() {
        super.init()
    }
    
    func setViewModel(_ viewModel: QuotaViewModel) {
        self.viewModel = viewModel
        self.menuBuilder = StatusBarMenuBuilder(viewModel: viewModel)
        MenuActionHandler.shared.viewModel = viewModel
    }
    
    func updateStatusBar(
        items: [MenuBarQuotaDisplayItem],
        colorMode: MenuBarColorMode,
        isRunning: Bool,
        showMenuBarIcon: Bool,
        showQuota: Bool
    ) {
        guard showMenuBarIcon else {
            removeStatusItem()
            return
        }
        
        if statusItem == nil {
            statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        }
        
        self.menuContentVersion += 1
        
        // Create or update menu
        if menu == nil {
            menu = NSMenu()
            menu?.autoenablesItems = false
            menu?.delegate = self
        }
        
        statusItem?.menu = menu

        guard let button = statusItem?.button else { return }

        button.subviews.forEach { $0.removeFromSuperview() }
        button.title = ""
        button.image = nil
        let contentView: AnyView
        if !showQuota || !isRunning || items.isEmpty {
            contentView = AnyView(
                StatusBarDefaultView(isRunning: isRunning)
            )
        } else {
            contentView = AnyView(
                StatusBarQuotaView(items: items, colorMode: colorMode)
            )
        }
        
        let hostingView = NSHostingView(rootView: contentView)
        hostingView.setFrameSize(hostingView.intrinsicContentSize)
        
        let horizontalPadding: CGFloat = 1
        let contentSize = hostingView.intrinsicContentSize
        let containerSize = NSSize(
            width: contentSize.width + horizontalPadding * 2,
            height: max(22, contentSize.height)
        )
        
        let containerView = StatusBarContainerView(frame: NSRect(origin: .zero, size: containerSize))
        containerView.addSubview(hostingView)
        hostingView.frame = NSRect(
            x: horizontalPadding,
            y: (containerSize.height - contentSize.height) / 2,
            width: contentSize.width,
            height: contentSize.height
        )
        
        button.addSubview(containerView)
        statusItem?.length = containerSize.width
    }
    
    // MARK: - NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        hasPendingMenuRebuild = false
        performMenuRebuild(using: menu)
    }

    func menuDidClose(_ menu: NSMenu) {
    }

    /// Force rebuild menu while it's open (e.g., when provider changes)
    func rebuildMenuInPlace() {
        guard let menu = menu else { return }

        if statusItem?.button?.isHighlighted != true {
            hasPendingMenuRebuild = true
            return
        }

        if isRebuildingMenu {
            hasPendingMenuRebuild = true
            return
        }

        performMenuRebuild(using: menu)
    }

    /// Close the menu programmatically
    func closeMenu() {
        menu?.cancelTracking()
    }

    private func performMenuRebuild(using menu: NSMenu) {
        if isRebuildingMenu {
            hasPendingMenuRebuild = true
            return
        }

        isRebuildingMenu = true
        defer {
            isRebuildingMenu = false
            if hasPendingMenuRebuild, statusItem?.button?.isHighlighted == true {
                hasPendingMenuRebuild = false
                DispatchQueue.main.async { [weak self] in
                    self?.rebuildMenuInPlace()
                }
            }
        }

        menu.removeAllItems()

        guard let builder = menuBuilder else { return }
        
        let nativeMenu = builder.buildMenu()
        for item in nativeMenu.items {
            nativeMenu.removeItem(item)
            menu.addItem(item)
        }
    }
    
    // MARK: - Menu Actions
    
    /// Force refresh menu content on next open
    func invalidateMenuContent() {
        menuContentVersion += 1
    }
    
    func removeStatusItem() {
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
        menu = nil
    }
}

// MARK: - Status Bar Container View

final class StatusBarContainerView: NSView {
    override var allowsVibrancy: Bool { true }

    override func mouseDown(with event: NSEvent) {
        superview?.mouseDown(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        superview?.mouseUp(with: event)
    }
}

// MARK: - Status Bar Default View

struct StatusBarDefaultView: View {
    let isRunning: Bool
    
    var body: some View {
        Image(systemName: isRunning ? "gauge.with.dots.needle.67percent" : "gauge.with.dots.needle.0percent")
            .font(.system(size: 14))
            .frame(height: 22)
    }
}

// MARK: - Status Bar Quota View

struct StatusBarQuotaView: View {
    let items: [MenuBarQuotaDisplayItem]
    let colorMode: MenuBarColorMode

    var body: some View {
        HStack(spacing: 6) {
            ForEach(items) { item in
                StatusBarQuotaItemView(item: item, colorMode: colorMode)
            }
        }
        .padding(.horizontal, 1)
        .fixedSize()
    }
}

// MARK: - Status Bar Quota Item View

struct StatusBarQuotaItemView: View {
    let item: MenuBarQuotaDisplayItem
    let colorMode: MenuBarColorMode

    var body: some View {
        // Always use used-percent semantics for both display and color
        let usedPercent = item.percentage >= 0 ? (100.0 - item.percentage) : -1.0

        HStack(spacing: 5) {
            if let assetName = item.provider.menuBarIconAsset {
                Image(assetName)
                    .resizable()
                    .renderingMode(.template)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 13, height: 13)
                    .foregroundStyle(colorMode == .colored ? iconTint : Color.primary)
            } else {
                Text(item.provider.menuBarSymbol)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(colorMode == .colored ? iconTint : Color.primary)
                    .fixedSize()
            }

            if let planLabel = item.groupLabel {
                Text(planLabel)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.primary.opacity(0.55))
                    .fixedSize()
            }

            if item.isForbidden {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
            } else if item.percentage >= 0 {
                Text(formatPercentage(usedPercent))
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(colorMode == .colored ? percentColor(usedPercent) : Color.primary)
                    .fixedSize()
            }
        }
        .fixedSize()
    }

    private var iconTint: Color {
        switch item.provider {
        case .claude:
            return Color(red: 0xe0 / 255.0, green: 0x8c / 255.0, blue: 0x66 / 255.0)
        case .codex:
            return Color(red: 0xec / 255.0, green: 0xec / 255.0, blue: 0xee / 255.0)
        default:
            return Color.primary
        }
    }

    private func percentColor(_ usedPercent: Double) -> Color {
        guard usedPercent >= 0 else { return Color.primary }
        if usedPercent >= 85 {
            return Color(red: 0xff / 255.0, green: 0x45 / 255.0, blue: 0x3a / 255.0)
        }
        if usedPercent >= 60 {
            return Color(red: 0xff / 255.0, green: 0xd6 / 255.0, blue: 0x0a / 255.0)
        }
        return Color(red: 0x30 / 255.0, green: 0xd1 / 255.0, blue: 0x58 / 255.0)
    }

    private func formatPercentage(_ value: Double) -> String {
        if value < 0 { return "--%"}
        let clamped = min(100, max(0, value))
        return String(format: "%.0f%%", clamped.rounded())
    }
}
