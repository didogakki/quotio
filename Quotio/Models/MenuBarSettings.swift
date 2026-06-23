//
//  MenuBarSettings.swift
//  Quotio
//
//  Menu bar quota display settings with persistence
//

import Foundation
import SwiftUI

// MARK: - Privacy String Extension

extension String {
    /// Masks sensitive information with asterisks (*)
    /// Email: `john.doe@gmail.com` → `********@*****.com`
    /// Other: `account-name` → `************`
    func masked() -> String {
        // Check if it's an email
        if self.contains("@") {
            let components = self.split(separator: "@", maxSplits: 1)
            if components.count == 2 {
                let localPart = String(repeating: "*", count: min(components[0].count, 8))
                let domainParts = components[1].split(separator: ".", maxSplits: 1)
                if domainParts.count == 2 {
                    let domainName = String(repeating: "*", count: min(domainParts[0].count, 5))
                    return "\(localPart)@\(domainName).\(domainParts[1])"
                }
                return "\(localPart)@\(String(repeating: "*", count: 5))"
            }
        }
        
        // For non-email strings, mask entirely but keep reasonable length
        let maskedLength = min(self.count, 12)
        return String(repeating: "*", count: max(maskedLength, 4))
    }
    
    /// Conditionally masks the string based on a flag
    func masked(if shouldMask: Bool) -> String {
        shouldMask ? masked() : self
    }
}

// MARK: - Menu Bar Quota Item

/// Represents a single item selected for menu bar display
struct MenuBarQuotaItem: Codable, Identifiable, Hashable {
    let provider: String      // AIProvider.rawValue
    let accountKey: String    // email or account identifier
    
    var id: String { "\(provider)_\(accountKey)" }
    
    /// Get the AIProvider enum value
    var aiProvider: AIProvider? {
        // Handle "copilot" alias
        if provider == "copilot" {
            return .copilot
        }
        return AIProvider(rawValue: provider)
    }
    
    /// Short display symbol for the provider
    var providerSymbol: String {
        aiProvider?.menuBarSymbol ?? "?"
    }
}

// MARK: - Appearance Mode

/// Appearance mode for the app (light/dark/system)
enum AppearanceMode: String, CaseIterable, Identifiable {
    case system = "system"
    case light = "light"
    case dark = "dark"
    
    var id: String { rawValue }
    
    var localizationKey: String {
        switch self {
        case .system: return "settings.appearance.system"
        case .light: return "settings.appearance.light"
        case .dark: return "settings.appearance.dark"
        }
    }
    
    var icon: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max.fill"
        case .dark: return "moon.fill"
        }
    }
}

// MARK: - Appearance Settings Manager

/// Manager for appearance settings with persistence
@MainActor
@Observable
final class AppearanceManager {
    static let shared = AppearanceManager()
    
    private let defaults = UserDefaults.standard
    private let appearanceModeKey = "appearanceMode"
    
    /// Current appearance mode
    var appearanceMode: AppearanceMode {
        didSet {
            defaults.set(appearanceMode.rawValue, forKey: appearanceModeKey)
            applyAppearance()
        }
    }
    
    private init() {
        let saved = defaults.string(forKey: appearanceModeKey) ?? AppearanceMode.system.rawValue
        self.appearanceMode = AppearanceMode(rawValue: saved) ?? .system
    }
    
    /// Apply the current appearance mode to the app
    func applyAppearance() {
        switch appearanceMode {
        case .system:
            NSApp.appearance = nil
        case .light:
            NSApp.appearance = NSAppearance(named: .aqua)
        case .dark:
            NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

// MARK: - Color Mode

/// Color mode for menu bar quota display
enum MenuBarColorMode: String, Codable, CaseIterable, Identifiable {
    case colored = "colored"       // Green/Yellow/Red based on quota %
    case monochrome = "monochrome" // White/Gray only
    
    var id: String { rawValue }
    
    var localizationKey: String {
        switch self {
        case .colored: return "settings.menubar.colored"
        case .monochrome: return "settings.menubar.monochrome"
        }
    }
}

// MARK: - Quota Display Mode

/// Display mode for quota percentage (used vs remaining)
enum QuotaDisplayMode: String, Codable, CaseIterable, Identifiable {
    case used = "used"           // Show percentage used (e.g., "75% used")
    case remaining = "remaining" // Show percentage remaining (e.g., "25% left")
    
    var id: String { rawValue }
    
    var localizationKey: String {
        switch self {
        case .used: return "settings.quota.displayMode.used"
        case .remaining: return "settings.quota.displayMode.remaining"
        }
    }
    
    /// Convert a remaining percentage to the display value based on mode
    func displayValue(from remainingPercent: Double) -> Double {
        switch self {
        case .used: return 100 - remainingPercent
        case .remaining: return remainingPercent
        }
    }
    
    var suffixKey: String {
        switch self {
        case .used: return "settings.quota.used"
        case .remaining: return "settings.quota.left"
        }
    }
}

// MARK: - Quota Display Style

/// Visual style for quota display in the main UI
enum QuotaDisplayStyle: String, Codable, CaseIterable, Identifiable {
    case card = "card"           // Default card with progress bar
    case lowestBar = "lowestBar" // Compact: lowest % bar, others text
    case ring = "ring"           // Circular progress rings

    var id: String { rawValue }

    var localizationKey: String {
        switch self {
        case .card: return "settings.quota.style.card"
        case .lowestBar: return "settings.quota.style.lowestBar"
        case .ring: return "settings.quota.style.ring"
        }
    }

    var iconName: String {
        switch self {
        case .card: return "rectangle.portrait"
        case .lowestBar: return "chart.bar.fill"
        case .ring: return "circle.dotted"
        }
    }
}

// MARK: - Refresh Cadence

/// Refresh cadence options for quota auto-refresh
enum RefreshCadence: String, CaseIterable, Identifiable, Codable {
    case manual = "manual"
    case oneMinute = "1min"
    case twoMinutes = "2min"
    case fiveMinutes = "5min"
    case tenMinutes = "10min"
    case fifteenMinutes = "15min"
    
    var id: String { rawValue }
    
    /// Interval in seconds (nil for manual = no auto-refresh)
    var intervalSeconds: TimeInterval? {
        switch self {
        case .manual: return nil
        case .oneMinute: return 60
        case .twoMinutes: return 120
        case .fiveMinutes: return 300
        case .tenMinutes: return 600
        case .fifteenMinutes: return 900
        }
    }
    
    /// Interval in nanoseconds for Task.sleep
    var intervalNanoseconds: UInt64? {
        guard let seconds = intervalSeconds else { return nil }
        return UInt64(seconds * 1_000_000_000)
    }
    
    var localizationKey: String {
        switch self {
        case .manual: return "settings.refresh.manual"
        case .oneMinute: return "settings.refresh.1min"
        case .twoMinutes: return "settings.refresh.2min"
        case .fiveMinutes: return "settings.refresh.5min"
        case .tenMinutes: return "settings.refresh.10min"
        case .fifteenMinutes: return "settings.refresh.15min"
        }
    }
}

// MARK: - Total Usage Calculation Mode

/// Mode for calculating total usage indicators (session vs extra)
enum TotalUsageMode: String, CaseIterable, Identifiable, Codable {
    case sessionOnly = "sessionOnly"
    case combined = "combined"
    
    var id: String { rawValue }
    
    var localizationKey: String {
        switch self {
        case .sessionOnly: return "settings.usageDisplay.totalMode.sessionOnly"
        case .combined: return "settings.usageDisplay.totalMode.combined"
        }
    }
}

// MARK: - Model Aggregation Mode

/// Mode for aggregating multi-model provider quotas
enum ModelAggregationMode: String, CaseIterable, Identifiable, Codable {
    case lowest = "lowest"
    case average = "average"
    
    var id: String { rawValue }
    
    var localizationKey: String {
        switch self {
        case .lowest: return "settings.usageDisplay.modelAggregation.lowest"
        case .average: return "settings.usageDisplay.modelAggregation.average"
        }
    }
}

// MARK: - Usage Calculation Helpers

extension MenuBarSettingsManager {
    /// Compute total usage percentage using session/extra logic
    /// Treats extra-usage, codex-extra, on-demand as extra models; all others as session
    func totalUsagePercent(models: [(name: String, percentage: Double)]) -> Double {
        let extraModelNames: Set<String> = ["extra-usage", "codex-extra", "on-demand"]
        
        var sessionPercentages: [Double] = []
        var extraPercentages: [Double] = []
        
        for model in models {
            if extraModelNames.contains(model.name) {
                extraPercentages.append(model.percentage)
            } else {
                sessionPercentages.append(model.percentage)
            }
        }
        
        let sessionRemaining = aggregateModelPercentages(sessionPercentages)
        let extraRemaining = aggregateModelPercentages(extraPercentages)
        
        let hasExtraModels = !extraPercentages.isEmpty
        
        switch totalUsageMode {
        case .sessionOnly:
            if sessionRemaining >= 0 {
                return sessionRemaining
            }
            if hasExtraModels {
                return extraRemaining
            }
            return -1
            
        case .combined:
            let session = sessionRemaining >= 0 ? sessionRemaining : -1
            let extra = extraRemaining >= 0 ? extraRemaining : -1
            
            if session < 0 && extra < 0 {
                return -1
            }
            if session < 0 {
                return extra
            }
            if extra < 0 {
                return session
            }
            return max(session, extra)
        }
    }
    
    func calculateTotalUsagePercent(sessionPercent: Double?, extraPercent: Double?) -> Double {
        switch totalUsageMode {
        case .sessionOnly:
            if let session = sessionPercent {
                return session
            }
            return extraPercent ?? -1
            
        case .combined:
            let session = sessionPercent ?? -1
            let extra = extraPercent ?? -1
            
            if session < 0 && extra < 0 {
                return -1
            }
            if session < 0 {
                return extra
            }
            if extra < 0 {
                return session
            }
            return max(session, extra)
        }
    }
    
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

// MARK: - Refresh Settings Manager

/// Manager for refresh cadence settings with persistence
@MainActor
@Observable
final class RefreshSettingsManager {
    static let shared = RefreshSettingsManager()
    
    private let defaults = UserDefaults.standard
    private let refreshCadenceKey = "refreshCadence"
    
    /// Current refresh cadence
    var refreshCadence: RefreshCadence {
        didSet {
            defaults.set(refreshCadence.rawValue, forKey: refreshCadenceKey)
            onRefreshCadenceChanged?(refreshCadence)
        }
    }
    
    /// Callback when refresh cadence changes (for ViewModel to restart timer)
    var onRefreshCadenceChanged: ((RefreshCadence) -> Void)?
    
    private init() {
        let saved = defaults.string(forKey: refreshCadenceKey) ?? RefreshCadence.tenMinutes.rawValue
        self.refreshCadence = RefreshCadence(rawValue: saved) ?? .tenMinutes
    }
}

// MARK: - Menu Bar Quota Display Item

/// Data for displaying a single quota item in menu bar
struct MenuBarQuotaDisplayItem: Identifiable {
    let id: String
    let providerSymbol: String
    let accountShort: String
    let percentage: Double
    let provider: AIProvider
    var isForbidden: Bool = false
    var groupLabel: String? = nil
    var accountCount: Int = 1
    
    var statusColor: Color {
        if isForbidden { return .orange }
        if percentage > 50 { return .green }
        if percentage > 20 { return .orange }
        return .red
    }
}

private struct MenuBarQuotaPlanGroup {
    let key: String
    let label: String
}

private struct AggregatedMenuBarQuotaItem {
    let provider: AIProvider
    let planGroup: MenuBarQuotaPlanGroup
    var percentages: [Double] = []
    var isForbidden = false
    var accountCount = 0

    mutating func add(percentage: Double, isForbidden: Bool) {
        percentages.append(percentage)
        self.isForbidden = self.isForbidden || isForbidden
        accountCount += 1
    }

    var displayItem: MenuBarQuotaDisplayItem {
        let validPercentages = percentages.filter { $0 >= 0 }
        let percentage = validPercentages.min() ?? -1

        return MenuBarQuotaDisplayItem(
            id: "\(provider.rawValue)_plan_\(planGroup.key)",
            providerSymbol: provider.menuBarSymbol,
            accountShort: planGroup.label,
            percentage: percentage,
            provider: provider,
            isForbidden: isForbidden,
            groupLabel: planGroup.label,
            accountCount: accountCount
        )
    }
}

// MARK: - Settings Manager

/// Manager for menu bar display settings with persistence
@MainActor
@Observable
final class MenuBarSettingsManager {
    static let shared = MenuBarSettingsManager()
    
    private let defaults = UserDefaults.standard
    private let selectedItemsKey = "menuBarSelectedQuotaItems"
    private let colorModeKey = "menuBarColorMode"
    private let showMenuBarIconKey = "showMenuBarIcon"
    private let showQuotaKey = "menuBarShowQuota"
    private let menuBarMaxItemsKey = "menuBarMaxItems"
    private let quotaDisplayModeKey = "quotaDisplayMode"
    private let quotaDisplayStyleKey = "quotaDisplayStyle"
    private let hideSensitiveInfoKey = "hideSensitiveInfo"
    private let totalUsageModeKey = "totalUsageMode"
    private let modelAggregationModeKey = "modelAggregationMode"
    private let hasUserModifiedMenuBarKey = "hasUserModifiedMenuBar"
    private let hasUserModifiedShowQuotaKey = "hasUserModifiedShowQuotaInMenuBar"

    static let minMenuBarItems = 1
    static let maxMenuBarItems = 10
    static let defaultMenuBarMaxItems = 3

    /// Whether to show menu bar icon at all
    var showMenuBarIcon: Bool {
        didSet { defaults.set(showMenuBarIcon, forKey: showMenuBarIconKey) }
    }

    /// Whether to show quota in menu bar (only effective when showMenuBarIcon is true)
    var showQuotaInMenuBar: Bool {
        didSet {
            defaults.set(showQuotaInMenuBar, forKey: showQuotaKey)
            defaults.set(true, forKey: hasUserModifiedShowQuotaKey)
        }
    }

    /// Maximum number of items to display in menu bar
    var menuBarMaxItems: Int {
        didSet {
            defaults.set(menuBarMaxItems, forKey: menuBarMaxItemsKey)
            enforceMaxItems()
        }
    }
    
    /// Selected items to display
    var selectedItems: [MenuBarQuotaItem] {
        didSet { saveSelectedItems() }
    }
    
    /// Color mode (colored vs monochrome)
    var colorMode: MenuBarColorMode {
        didSet { defaults.set(colorMode.rawValue, forKey: colorModeKey) }
    }
    
    /// Quota display mode (used vs remaining)
    var quotaDisplayMode: QuotaDisplayMode {
        didSet { defaults.set(quotaDisplayMode.rawValue, forKey: quotaDisplayModeKey) }
    }
    
    /// Visual style for quota display
    var quotaDisplayStyle: QuotaDisplayStyle {
        didSet { defaults.set(quotaDisplayStyle.rawValue, forKey: quotaDisplayStyleKey) }
    }
    
    /// Whether to hide sensitive information (emails, account names)
    var hideSensitiveInfo: Bool {
        didSet { defaults.set(hideSensitiveInfo, forKey: hideSensitiveInfoKey) }
    }
    
    /// Total usage calculation mode (session-only vs combined)
    var totalUsageMode: TotalUsageMode {
        didSet { defaults.set(totalUsageMode.rawValue, forKey: totalUsageModeKey) }
    }
    
    /// Model aggregation mode (lowest vs average)
    var modelAggregationMode: ModelAggregationMode {
        didSet { defaults.set(modelAggregationMode.rawValue, forKey: modelAggregationModeKey) }
    }

    /// Whether user has manually modified the menu bar selection
    /// When true, autoSelectNewAccounts will not add new items
    private(set) var hasUserModifiedMenuBar: Bool {
        didSet { defaults.set(hasUserModifiedMenuBar, forKey: hasUserModifiedMenuBarKey) }
    }

    /// Check if adding another item would exceed the warning threshold
    /// Warning shows when approaching the limit (at maxItems - 1)
    var shouldWarnOnAdd: Bool {
        let threshold = max(menuBarMaxItems - 1, 1)
        return selectedItems.count >= threshold && selectedItems.count < menuBarMaxItems
    }

    /// Check if selection has reached the maximum items
    var isAtMaxItems: Bool {
        selectedItems.count >= menuBarMaxItems
    }
    
    private init() {
        // Show menu bar icon - default true if not set
        if defaults.object(forKey: showMenuBarIconKey) == nil {
            defaults.set(true, forKey: showMenuBarIconKey)
        }
        self.showMenuBarIcon = defaults.bool(forKey: showMenuBarIconKey)
        
        // Show quota in menu bar by default. Older builds may have persisted
        // `false` as the implicit default, so migrate until the user explicitly
        // changes this toggle in this build.
        if defaults.object(forKey: showQuotaKey) == nil || !defaults.bool(forKey: hasUserModifiedShowQuotaKey) {
            defaults.set(true, forKey: showQuotaKey)
        }
        self.showQuotaInMenuBar = defaults.bool(forKey: showQuotaKey)
        
        if defaults.object(forKey: menuBarMaxItemsKey) == nil {
            defaults.set(Self.defaultMenuBarMaxItems, forKey: menuBarMaxItemsKey)
        }

        self.colorMode = MenuBarColorMode(rawValue: defaults.string(forKey: colorModeKey) ?? "") ?? .colored
        self.quotaDisplayMode = QuotaDisplayMode(rawValue: defaults.string(forKey: quotaDisplayModeKey) ?? "") ?? .used
        self.quotaDisplayStyle = QuotaDisplayStyle(rawValue: defaults.string(forKey: quotaDisplayStyleKey) ?? "") ?? .card
        self.selectedItems = Self.loadSelectedItems(from: defaults, key: selectedItemsKey)

        // Load and clamp menuBarMaxItems, then persist the clamped value
        let loadedMax = defaults.integer(forKey: menuBarMaxItemsKey)
        let clampedMax = Self.clampedMenuBarMax(loadedMax)
        self.menuBarMaxItems = clampedMax
        if loadedMax != clampedMax {
            defaults.set(clampedMax, forKey: menuBarMaxItemsKey)
        }

        self.hideSensitiveInfo = defaults.bool(forKey: hideSensitiveInfoKey)
        self.totalUsageMode = TotalUsageMode(rawValue: defaults.string(forKey: totalUsageModeKey) ?? "") ?? .sessionOnly
        self.modelAggregationMode = ModelAggregationMode(rawValue: defaults.string(forKey: modelAggregationModeKey) ?? "") ?? .lowest
        self.hasUserModifiedMenuBar = defaults.bool(forKey: hasUserModifiedMenuBarKey)

        enforceMaxItems()
    }
    
    private func saveSelectedItems() {
        if let data = try? JSONEncoder().encode(selectedItems) {
            defaults.set(data, forKey: selectedItemsKey)
        }
    }
    
    private static func loadSelectedItems(from defaults: UserDefaults, key: String) -> [MenuBarQuotaItem] {
        guard let data = defaults.data(forKey: key),
              let items = try? JSONDecoder().decode([MenuBarQuotaItem].self, from: data) else {
            return []
        }
        return items
    }
    
    func addItem(_ item: MenuBarQuotaItem) {
        guard !selectedItems.contains(item) else { return }
        guard selectedItems.count < menuBarMaxItems else { return }
        if !showQuotaInMenuBar {
            showQuotaInMenuBar = true
        }
        if !showMenuBarIcon {
            showMenuBarIcon = true
        }
        selectedItems.append(item)
    }
    
    /// Remove an item (marks as user-modified to prevent auto-add)
    func removeItem(_ item: MenuBarQuotaItem) {
        selectedItems.removeAll { $0.id == item.id }
        hasUserModifiedMenuBar = true
    }

    /// Check if item is selected
    func isSelected(_ item: MenuBarQuotaItem) -> Bool {
        selectedItems.contains(item)
    }

    /// Toggle item selection (marks as user-modified to prevent auto-add)
    func toggleItem(_ item: MenuBarQuotaItem) {
        hasUserModifiedMenuBar = true
        if isSelected(item) {
            selectedItems.removeAll { $0.id == item.id }
        } else {
            addItem(item)
        }
    }
    
    /// Remove items that no longer exist in quota data
    func pruneInvalidItems(validItems: [MenuBarQuotaItem]) {
        let validIds = Set(validItems.map(\.id))
        selectedItems.removeAll { !validIds.contains($0.id) }
    }
    
    func autoSelectNewAccounts(availableItems: [MenuBarQuotaItem]) {
        // Don't auto-add if user has manually modified the menu bar selection
        guard !hasUserModifiedMenuBar else { return }

        enforceMaxItems()
        let existingIds = Set(selectedItems.map(\.id))
        let newItems = availableItems.filter { !existingIds.contains($0.id) }

        let remainingSlots = menuBarMaxItems - selectedItems.count
        if remainingSlots > 0 {
            let itemsToAdd = Array(newItems.prefix(remainingSlots))
            selectedItems.append(contentsOf: itemsToAdd)
        }
    }

    @discardableResult
    private func enforceMaxItems() -> Bool {
        guard selectedItems.count > menuBarMaxItems else { return false }
        selectedItems = Array(selectedItems.prefix(menuBarMaxItems))
        return true
    }

    private static func clampedMenuBarMax(_ value: Int) -> Int {
        min(max(value, minMenuBarItems), maxMenuBarItems)
    }
}

// MARK: - Menu Bar Display Item Builder

extension MenuBarSettingsManager {
    func makeQuotaDisplayItems(providerQuotas: [AIProvider: [String: ProviderQuotaData]]) -> [MenuBarQuotaDisplayItem] {
        guard showQuotaInMenuBar else { return [] }

        var orderedKeys: [String] = []
        var individualItems: [String: MenuBarQuotaDisplayItem] = [:]
        var aggregatedItems: [String: AggregatedMenuBarQuotaItem] = [:]

        for selectedItem in selectedItems {
            guard let provider = selectedItem.aiProvider else { continue }

            var displayPercent: Double = -1
            var isForbidden = false
            var planGroup: MenuBarQuotaPlanGroup?

            if let accountQuotas = providerQuotas[provider],
               let quotaData = resolveQuotaData(
                   for: selectedItem,
                   provider: provider,
                   accountQuotas: accountQuotas
               ) {
                isForbidden = quotaData.isForbidden
                planGroup = menuBarPlanGroup(for: provider, quotaData: quotaData)

                if !quotaData.models.isEmpty {
                    let models = quotaData.models.map { (name: $0.name, percentage: $0.percentage) }
                    displayPercent = totalUsagePercent(models: models)
                }
            }

            if let planGroup {
                let key = "group:\(provider.rawValue):\(planGroup.key)"
                if aggregatedItems[key] == nil {
                    aggregatedItems[key] = AggregatedMenuBarQuotaItem(
                        provider: provider,
                        planGroup: planGroup
                    )
                    orderedKeys.append(key)
                }
                aggregatedItems[key]?.add(percentage: displayPercent, isForbidden: isForbidden)
                continue
            }

            let key = "item:\(selectedItem.id)"
            individualItems[key] = MenuBarQuotaDisplayItem(
                id: selectedItem.id,
                providerSymbol: provider.menuBarSymbol,
                accountShort: selectedItem.accountKey,
                percentage: displayPercent,
                provider: provider,
                isForbidden: isForbidden
            )
            orderedKeys.append(key)
        }

        return orderedKeys.compactMap { key in
            if let item = individualItems[key] {
                return item
            }
            return aggregatedItems[key]?.displayItem
        }
    }

    private func menuBarPlanGroup(
        for provider: AIProvider,
        quotaData: ProviderQuotaData
    ) -> MenuBarQuotaPlanGroup? {
        guard provider == .codex else { return nil }
        guard let rawPlan = quotaData.planDisplayName ?? quotaData.planType,
              !rawPlan.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        let lowercased = rawPlan.lowercased()
        if lowercased.contains("team") {
            return MenuBarQuotaPlanGroup(key: "team", label: "Team")
        }
        if lowercased.contains("plus") {
            return MenuBarQuotaPlanGroup(key: "plus", label: "Plus")
        }
        if lowercased.contains("pro") {
            return MenuBarQuotaPlanGroup(key: "pro", label: "Pro")
        }
        if lowercased.contains("enterprise") {
            return MenuBarQuotaPlanGroup(key: "enterprise", label: "Enterprise")
        }

        let normalizedKey = lowercased
            .replacingOccurrences(of: "_", with: "-")
            .replacingOccurrences(of: " ", with: "-")
        let displayName = rawPlan
            .replacingOccurrences(of: "_", with: " ")
            .split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }
            .joined(separator: " ")

        return MenuBarQuotaPlanGroup(key: normalizedKey, label: displayName)
    }

    private func resolveQuotaData(
        for selectedItem: MenuBarQuotaItem,
        provider: AIProvider,
        accountQuotas: [String: ProviderQuotaData]
    ) -> ProviderQuotaData? {
        if let quotaData = accountQuotas[selectedItem.accountKey] {
            return quotaData
        }

        let cleanKey = selectedItem.accountKey.replacingOccurrences(of: ".json", with: "")
        if let quotaData = accountQuotas[cleanKey] {
            return quotaData
        }

        guard provider == .codex else { return nil }
        let normalizedSelected = normalizedCodexKey(cleanKey)
        return accountQuotas.first { normalizedCodexKey($0.key) == normalizedSelected }?.value
    }

    private func normalizedCodexKey(_ key: String) -> String {
        let cleanKey = key.replacingOccurrences(of: ".json", with: "")
        if let email = extractEmail(from: cleanKey) {
            return email.lowercased()
        }
        return cleanKey.lowercased()
    }

    private func extractEmail(from text: String) -> String? {
        let pattern = #"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#
        let options: String.CompareOptions = [.regularExpression, .caseInsensitive]
        guard let range = text.range(of: pattern, options: options) else { return nil }
        return String(text[range])
    }

    /// Resolve a stable (key, label) pair from a raw plan string using the same
    /// keyword matching as makeQuotaDisplayItems plan grouping.
    func resolveRemotePlanLabel(rawPlan: String) -> (key: String, label: String) {
        let lowercased = rawPlan.lowercased()
        if lowercased.contains("team") { return (key: "team", label: "Team") }
        if lowercased.contains("enterprise") { return (key: "enterprise", label: "Enterprise") }
        if lowercased.contains("business") { return (key: "business", label: "Business") }
        if lowercased.contains("plus") { return (key: "plus", label: "Plus") }
        if lowercased.contains("pro") { return (key: "pro", label: "Pro") }
        let key = lowercased
            .replacingOccurrences(of: "_", with: "-")
            .replacingOccurrences(of: " ", with: "-")
        let label = rawPlan
            .replacingOccurrences(of: "_", with: " ")
            .split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }
            .joined(separator: " ")
        return (key: key, label: label)
    }
}
