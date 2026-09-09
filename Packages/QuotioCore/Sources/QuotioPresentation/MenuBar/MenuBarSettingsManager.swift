//
//  MenuBarSettings.swift
//  Quotio
//
//  Menu bar quota display settings with persistence
//

import Foundation
import QuotioApplication
import QuotioDomain
import SwiftUI

// MARK: - Privacy String Extension

public extension String {
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

// MARK: - Appearance Settings Manager

/// Manager for appearance settings with persistence
@MainActor
@Observable
public final class AppearanceManager {
    @ObservationIgnored private let repository: any AppearancePreferencesRepository
    @ObservationIgnored private let platform: any ApplicationPlatformControlling
    @ObservationIgnored private var didChangeHandler: (@MainActor (AppearanceMode) -> Void)?
    
    /// Current appearance mode
    public var appearanceMode: AppearanceMode {
        didSet {
            repository.save(AppearancePreferences(mode: appearanceMode))
            applyAppearance()
            didChangeHandler?(appearanceMode)
        }
    }
    
    public init(
        repository: any AppearancePreferencesRepository,
        platform: any ApplicationPlatformControlling
    ) {
        self.repository = repository
        self.platform = platform
        self.appearanceMode = repository.load().mode
    }
    
    /// Apply the current appearance mode to the app
    public func applyAppearance() {
        platform.applyAppearance(appearanceMode)
    }

    public func setDidChangeHandler(_ handler: (@MainActor (AppearanceMode) -> Void)?) {
        didChangeHandler = handler
    }
}

// MARK: - Usage Calculation Helpers

public extension MenuBarSettingsManager {
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
public final class RefreshSettingsManager {
    @ObservationIgnored private let repository: any RefreshPreferencesRepository
    @ObservationIgnored private var cadenceChangeHandlers: [(RefreshCadence) -> Void] = []
    
    /// Current refresh cadence
    public var refreshCadence: RefreshCadence {
        didSet {
            repository.save(RefreshPreferences(cadence: refreshCadence))
            cadenceChangeHandlers.forEach { $0(refreshCadence) }
        }
    }
    
    public init(repository: any RefreshPreferencesRepository) {
        self.repository = repository
        self.refreshCadence = repository.load().cadence
    }

    public func addCadenceChangeHandler(_ handler: @escaping (RefreshCadence) -> Void) {
        cadenceChangeHandlers.append(handler)
    }
}

// MARK: - Menu Bar Quota Display Item

/// A semantic quota metric rendered as one row of a compact menu bar pair.
public struct MenuBarQuotaMetric: Equatable, Sendable {
    public let labelKey: String
    public let remainingPercentage: Double

    public init(labelKey: String, remainingPercentage: Double) {
        self.labelKey = labelKey
        self.remainingPercentage = remainingPercentage
    }
}

/// Two related quota metrics rendered together in the compact menu bar layout.
public struct MenuBarQuotaPair: Equatable, Sendable {
    public let top: MenuBarQuotaMetric
    public let bottom: MenuBarQuotaMetric

    public init(top: MenuBarQuotaMetric, bottom: MenuBarQuotaMetric) {
        self.top = top
        self.bottom = bottom
    }

    public static func resolve(for provider: QuotaProvider, from models: [QuotaMetric]) -> MenuBarQuotaPair? {
        switch provider {
        case .claude:
            return makePair(
                from: models,
                topNames: ["five-hour-session"],
                topLabelKey: "quota.metric.fiveHour",
                bottomNames: ["seven-day-weekly", "seven-day-sonnet", "seven-day-opus"],
                bottomLabelKey: "quota.metric.weekly"
            )
        case .codex:
            let sessionNames: Set<String> = ["codex-session", "codex-spark"]
            guard let sessionPercentage = minimumPercentage(in: models, named: sessionNames),
                  sessionPercentage >= 0 else {
                return nil
            }
            return makePair(
                from: models,
                topNames: sessionNames,
                topLabelKey: "quota.metric.session",
                bottomNames: ["codex-weekly", "codex-spark-weekly"],
                bottomLabelKey: "quota.metric.weekly"
            )
        case .amp:
            return makePair(
                from: models,
                topNames: ["amp-agent-usage"],
                topLabelKey: "amp.quota.agent",
                bottomNames: ["amp-orb-usage"],
                bottomLabelKey: "amp.quota.orb",
                requiresBoth: true
            )
        case .antigravity:
            return makePair(
                from: models,
                topNames: ["antigravity-gemini-session", "antigravity-claude-gpt-session"],
                topLabelKey: "quota.metric.session",
                bottomNames: ["antigravity-gemini-weekly", "antigravity-claude-gpt-weekly"],
                bottomLabelKey: "quota.metric.weekly"
            )
        case .devin:
            return makePair(
                from: models,
                topNames: ["devin-daily"],
                topLabelKey: "quota.metric.daily",
                bottomNames: ["devin-weekly"],
                bottomLabelKey: "quota.metric.weekly",
                requiresBoth: true
            )
        case .cursor:
            guard models.contains(where: {
                $0.name == "on-demand"
                    && ($0.limit ?? 0) > 0
                    && $0.remaining != nil
                    && $0.percentage >= 0
            }) else {
                return nil
            }
            return makePair(
                from: models,
                topNames: ["plan-usage"],
                topLabelKey: "quota.metric.planUsage",
                bottomNames: ["on-demand"],
                bottomLabelKey: "quota.metric.onDemand",
                requiresBoth: true
            )
        default:
            return nil
        }
    }

    private static func makePair(
        from models: [QuotaMetric],
        topNames: Set<String>,
        topLabelKey: String,
        bottomNames: Set<String>,
        bottomLabelKey: String,
        requiresBoth: Bool = false
    ) -> MenuBarQuotaPair? {
        let topPercentage = minimumPercentage(in: models, named: topNames)
        let bottomPercentage = minimumPercentage(in: models, named: bottomNames)

        if requiresBoth {
            guard topPercentage != nil, bottomPercentage != nil else { return nil }
        } else {
            guard topPercentage != nil || bottomPercentage != nil else { return nil }
        }

        return MenuBarQuotaPair(
            top: MenuBarQuotaMetric(
                labelKey: topLabelKey,
                remainingPercentage: topPercentage ?? -1
            ),
            bottom: MenuBarQuotaMetric(
                labelKey: bottomLabelKey,
                remainingPercentage: bottomPercentage ?? -1
            )
        )
    }

    private static func minimumPercentage(in models: [QuotaMetric], named names: Set<String>) -> Double? {
        let matching = models.filter { names.contains($0.name) }
        guard !matching.isEmpty else { return nil }
        return matching.lazy.map(\.percentage).filter { $0 >= 0 }.min() ?? -1
    }
}

/// Data for displaying a single quota item in menu bar
public struct MenuBarQuotaDisplayItem: Identifiable, Equatable {
    public let id: String
    public let providerSymbol: String
    public let accountShort: String
    public let percentage: Double
    public let provider: QuotaProvider
    public var isForbidden: Bool
    public var quotaPair: MenuBarQuotaPair?
    /// Set when a single selected menu bar item (e.g. a remote pool with
    /// `accountKey == "__pool__"`) expands into several plan-group items — shown next
    /// to the provider icon so, for example, a source's Pro and Team pools are
    /// distinguishable. `nil` for ordinary single-plan/local items.
    public var groupLabel: String?

    public init(
        id: String,
        providerSymbol: String,
        accountShort: String,
        percentage: Double,
        provider: QuotaProvider,
        isForbidden: Bool = false,
        quotaPair: MenuBarQuotaPair? = nil,
        groupLabel: String? = nil
    ) {
        self.id = id
        self.providerSymbol = providerSymbol
        self.accountShort = accountShort
        self.percentage = percentage
        self.provider = provider
        self.isForbidden = isForbidden
        self.quotaPair = quotaPair
        self.groupLabel = groupLabel
    }
    
    public var statusColor: Color {
        statusColor(for: percentage)
    }

    public func statusColor(for percentage: Double) -> Color {
        if isForbidden { return .orange }
        if percentage > 50 { return .green }
        if percentage > 20 { return .orange }
        return .red
    }
}

// MARK: - Settings Manager

/// Manager for menu bar display settings with persistence
@MainActor
@Observable
public final class MenuBarSettingsManager {
    @ObservationIgnored private let repository: any MenuBarPreferencesRepository
    @ObservationIgnored private var didChangeHandler: (@MainActor (MenuBarPreferences) -> Void)?

    public static let minMenuBarItems = 1
    public static let maxMenuBarItems = 10
    public static let defaultMenuBarMaxItems = 3

    /// Whether to show menu bar icon at all
    public var showMenuBarIcon: Bool {
        didSet { persist() }
    }

    /// Whether to show quota in menu bar (only effective when showMenuBarIcon is true)
    public var showQuotaInMenuBar: Bool {
        didSet { persist() }
    }

    /// Maximum number of items to display in menu bar
    public var menuBarMaxItems: Int {
        didSet {
            persist()
            enforceMaxItems()
        }
    }
    
    /// Selected items to display
    public var selectedItems: [MenuBarQuotaItem] {
        didSet { persist() }
    }

    /// Provider used to filter account cards in the expanded menu.
    public private(set) var selectedProvider: QuotaProvider? {
        didSet { persist() }
    }
    
    /// Color mode (colored vs monochrome)
    public var colorMode: MenuBarColorMode {
        didSet { persist() }
    }
    
    /// Quota display mode (used vs remaining)
    public var quotaDisplayMode: QuotaDisplayMode {
        didSet { persist() }
    }
    
    /// Visual style for quota display
    public var quotaDisplayStyle: QuotaDisplayStyle {
        didSet { persist() }
    }

    /// Whether providers with a stable metric pair use the compact stacked layout.
    public var stackPairedQuotaMetrics: Bool {
        didSet { persist() }
    }
    
    /// Whether to hide sensitive information (emails, account names)
    public var hideSensitiveInfo: Bool {
        didSet { persist() }
    }
    
    /// Total usage calculation mode (session-only vs combined)
    public var totalUsageMode: TotalUsageMode {
        didSet { persist() }
    }
    
    /// Model aggregation mode (lowest vs average)
    public var modelAggregationMode: ModelAggregationMode {
        didSet { persist() }
    }

    /// Whether user has manually modified the menu bar selection
    /// When true, autoSelectNewAccounts will not add new items
    public private(set) var hasUserModifiedMenuBar: Bool {
        didSet { persist() }
    }

    /// Per-account `MenuBarQuotaItem.id`s the user turned off while the account was
    /// covered only by a legacy pool pin. A pool pin expands dynamically into whatever
    /// real accounts its source currently reports, so there is no per-account entry in
    /// `selectedItems` to remove — the deselection is recorded here instead, and the
    /// expansion skips it. Kept out of `selectedItems` so `menuBarMaxItems` truncation
    /// can never silently re-select an account the user turned off.
    public private(set) var deselectedPoolAccounts: Set<String> {
        didSet { persist() }
    }

    /// `MenuBarQuotaItem.id`-shaped keys hidden from the menu bar's per-provider dropdown
    /// account list — local and remote accounts alike. Purely a display filter — never
    /// touches `selectedItems`, never disables fetching. See
    /// `MenuBarPreferences.hiddenDropdownKeys` for the full rationale.
    public private(set) var hiddenDropdownKeys: Set<String> {
        didSet { persist() }
    }

    /// Every real remote account `RemoteQuotaSourceScreenModel` reported as visible in
    /// its most recent sync, refreshed by `syncKnownRemoteAccountItems` after every
    /// remote refresh. Used only to tell whether a legacy pool pin (`accountKey ==
    /// "__pool__"`) still covers at least one real account — never to prune or mutate
    /// `selectedItems`/`deselectedPoolAccounts`, so a transient remote fetch failure can
    /// never delete a user's pin or change what a pool dynamically covers once it
    /// recovers. `nil` means "no remote sync has happened yet in this process" and is
    /// deliberately distinct from an empty array: without that distinction, a cold
    /// launch (before the first remote refresh completes) would look identical to every
    /// pool genuinely having zero accounts, and would incorrectly free up capacity that
    /// isn't really available yet.
    @ObservationIgnored private var knownRemoteAccountItems: [MenuBarQuotaItem]?

    /// Feeds the latest known set of real remote accounts, keyed exactly as
    /// `AccountRowData.menuBarItem` builds them, so `effectiveSelectedItemCount` can
    /// tell a legacy pool pin apart from one that no longer covers anything real.
    public func syncKnownRemoteAccountItems(_ items: [MenuBarQuotaItem]) {
        knownRemoteAccountItems = items
    }

    /// Whether `item` (assumed to be a legacy pool pin) currently expands into at least
    /// one real, non-excluded account. A pool this manager has never received a remote
    /// sync for yet is assumed non-empty (see `knownRemoteAccountItems`).
    private func poolPinIsCurrentlyEmpty(_ item: MenuBarQuotaItem) -> Bool {
        guard let knownRemoteAccountItems else { return false }
        let coverage = knownRemoteAccountItems.filter {
            $0.sourceConfigId == item.sourceConfigId && $0.provider == item.provider
        }
        return !coverage.contains { poolExpansionIncludes($0) }
    }

    /// The number of `selectedItems` that actually occupy a `menuBarMaxItems` slot right
    /// now. Every ordinary pin (local, remote per-account, or aggregate) always counts
    /// as one. A legacy pool pin only counts while it still covers at least one real
    /// account — once every account it would have covered has been individually turned
    /// off, or its source now reports none at all, it stops reserving a slot exactly as
    /// if the user had unpinned it. Without this, several stale, fully-excluded pool
    /// pins could permanently occupy every slot and block all future selection even
    /// though the menu bar renders nothing for them.
    private var effectiveSelectedItemCount: Int {
        selectedItems.filter { !$0.isPool || !poolPinIsCurrentlyEmpty($0) }.count
    }

    /// Check if adding another item would exceed the warning threshold
    /// Warning shows when approaching the limit (at maxItems - 1)
    public var shouldWarnOnAdd: Bool {
        let threshold = max(menuBarMaxItems - 1, 1)
        let count = effectiveSelectedItemCount
        return count >= threshold && count < menuBarMaxItems
    }

    /// Check if selection has reached the maximum items
    public var isAtMaxItems: Bool {
        effectiveSelectedItemCount >= menuBarMaxItems
    }

    /// Whether toggling `item` on right now would occupy a menu bar slot that isn't
    /// already occupied — i.e. whether `isAtMaxItems`/`shouldWarnOnAdd` are relevant to
    /// this particular toggle. False when turning an item off (always allowed), and
    /// false when restoring a pool-covered account whose pool pin already occupies a
    /// slot (the pool's single slot doesn't grow with the number of accounts it
    /// covers). True for a brand new pin, and true for restoring a pool-covered account
    /// whose pool pin is currently empty — that restoration is what turns the pool from
    /// occupying zero slots to occupying one.
    public func toggleWouldOccupyNewSlot(_ item: MenuBarQuotaItem) -> Bool {
        if isSelected(item) { return false }
        guard isCoveredByPoolPin(item) else { return true }
        guard let poolItem = selectedItems.first(where: {
            $0.isPool && $0.sourceConfigId == item.sourceConfigId && $0.provider == item.provider
        }) else { return false }
        return poolPinIsCurrentlyEmpty(poolItem)
    }

    public var preferences: MenuBarPreferences {
        MenuBarPreferences(
            showMenuBarIcon: showMenuBarIcon,
            showQuotaInMenuBar: showQuotaInMenuBar,
            menuBarMaxItems: menuBarMaxItems,
            selectedItems: selectedItems,
            selectedProvider: selectedProvider,
            colorMode: colorMode,
            quotaDisplayMode: quotaDisplayMode,
            quotaDisplayStyle: quotaDisplayStyle,
            stackPairedQuotaMetrics: stackPairedQuotaMetrics,
            hideSensitiveInfo: hideSensitiveInfo,
            totalUsageMode: totalUsageMode,
            modelAggregationMode: modelAggregationMode,
            hasUserModifiedMenuBar: hasUserModifiedMenuBar,
            deselectedPoolAccounts: deselectedPoolAccounts,
            hiddenDropdownKeys: hiddenDropdownKeys
        )
    }

    public init(repository: any MenuBarPreferencesRepository) {
        self.repository = repository
        let preferences = repository.load()
        self.showMenuBarIcon = preferences.showMenuBarIcon
        self.showQuotaInMenuBar = preferences.showQuotaInMenuBar
        self.menuBarMaxItems = preferences.menuBarMaxItems
        self.selectedItems = preferences.selectedItems
        self.selectedProvider = preferences.selectedProvider
        self.colorMode = preferences.colorMode
        self.quotaDisplayMode = preferences.quotaDisplayMode
        self.quotaDisplayStyle = preferences.quotaDisplayStyle
        self.stackPairedQuotaMetrics = preferences.stackPairedQuotaMetrics
        self.hideSensitiveInfo = preferences.hideSensitiveInfo
        self.totalUsageMode = preferences.totalUsageMode
        self.modelAggregationMode = preferences.modelAggregationMode
        self.hasUserModifiedMenuBar = preferences.hasUserModifiedMenuBar
        self.deselectedPoolAccounts = preferences.deselectedPoolAccounts
        self.hiddenDropdownKeys = preferences.hiddenDropdownKeys
    }

    public func setDidChangeHandler(_ handler: (@MainActor (MenuBarPreferences) -> Void)?) {
        didChangeHandler = handler
    }

    public func selectProvider(_ provider: QuotaProvider?) {
        selectedProvider = provider
    }
    
    public func addItem(_ item: MenuBarQuotaItem) {
        // `isSelected` — not `contains` — so an account already covered by a legacy
        // pool pin is never added a second time, which would render it twice.
        guard !isSelected(item) else { return }
        guard effectiveSelectedItemCount < menuBarMaxItems else { return }
        if !showQuotaInMenuBar {
            showQuotaInMenuBar = true
        }
        if !showMenuBarIcon {
            showMenuBarIcon = true
        }
        selectedItems.append(item)
    }
    
    /// Remove an item (marks as user-modified to prevent auto-add)
    public func removeItem(_ item: MenuBarQuotaItem) {
        selectedItems.removeAll { $0.id == item.id }
        hasUserModifiedMenuBar = true
    }

    /// Check if item is selected — either pinned in its own right, or covered by a
    /// legacy pool pin for the same source and provider and not individually turned off.
    public func isSelected(_ item: MenuBarQuotaItem) -> Bool {
        if selectedItems.contains(item) { return true }
        guard isCoveredByPoolPin(item) else { return false }
        return !deselectedPoolAccounts.contains(item.id)
    }

    /// Whether this per-account remote item is one a currently-pinned legacy pool item
    /// expands into. Pool pins are scoped to one source + provider and cover whatever
    /// accounts that source reports, so coverage is decided by those two fields alone.
    /// A plan aggregate's own pin is deliberately excluded (`!item.isAggregate`) — the
    /// legacy pool-expansion mechanism only ever expands into real accounts, and an
    /// aggregate must never be mistaken for one of them just because both happen to be
    /// unpinned items under the same source and provider.
    public func isCoveredByPoolPin(_ item: MenuBarQuotaItem) -> Bool {
        guard !item.isPool, !item.isAggregate, let sourceId = item.sourceConfigId else { return false }
        return selectedItems.contains {
            $0.isPool && $0.sourceConfigId == sourceId && $0.provider == item.provider
        }
    }

    /// Whether `itemId` (an account row's own `menuBarItem.id`) is currently hidden from
    /// the menu bar's per-provider dropdown account list.
    public func isHiddenFromDropdown(_ itemId: String) -> Bool {
        hiddenDropdownKeys.contains(itemId)
    }

    /// Toggles whether `itemId` shows up in the menu bar's per-provider dropdown account
    /// list. Purely a display filter: it never touches `selectedItems`/pins and never
    /// affects fetching, so a hidden account keeps refreshing and keeps its pin (if any)
    /// working exactly as before.
    public func toggleDropdownVisibility(_ itemId: String) {
        if hiddenDropdownKeys.contains(itemId) {
            hiddenDropdownKeys.remove(itemId)
        } else {
            hiddenDropdownKeys.insert(itemId)
        }
    }

    /// Whether a legacy pool pin's dynamic expansion should include this account: it
    /// must not have been individually turned off, and must not already be pinned in
    /// its own right — otherwise the same account would render twice.
    public func poolExpansionIncludes(_ item: MenuBarQuotaItem) -> Bool {
        !deselectedPoolAccounts.contains(item.id) && !selectedItems.contains(item)
    }

    /// Toggle item selection (marks as user-modified to prevent auto-add)
    public func toggleItem(_ item: MenuBarQuotaItem) {
        hasUserModifiedMenuBar = true
        if selectedItems.contains(item) {
            selectedItems.removeAll { $0.id == item.id }
            // A legacy state can have both an explicit pin and a covering pool pin for
            // the same account at once. Removing only the explicit entry would leave the
            // pool pin's dynamic expansion covering it again on the very next read, so the
            // toggle would appear to do nothing. Record the exclusion too whenever the
            // pool would otherwise immediately re-select this account.
            if isCoveredByPoolPin(item) {
                deselectedPoolAccounts.insert(item.id)
            }
            return
        }
        // Covered by a legacy pool pin: there is no per-account entry to add or remove,
        // so the choice is recorded as a persistent exclusion instead. That keeps the
        // pool pin's "whatever this source currently has" coverage intact for every
        // other account, including ones that appear later.
        if isCoveredByPoolPin(item) {
            if deselectedPoolAccounts.contains(item.id) {
                // If the pool pin is currently empty, restoring this account is what
                // makes it start occupying a slot again — apply the same capacity guard
                // `addItem` uses so this can't push the effective count past the cap.
                if toggleWouldOccupyNewSlot(item), effectiveSelectedItemCount >= menuBarMaxItems {
                    return
                }
                deselectedPoolAccounts.remove(item.id)
            } else {
                deselectedPoolAccounts.insert(item.id)
            }
            return
        }
        addItem(item)
    }

    /// Remove items that no longer exist in quota data
    public func pruneInvalidItems(validItems: [MenuBarQuotaItem]) {
        let validIds = Set(validItems.map(\.id))
        selectedItems.removeAll { !validIds.contains($0.id) }
    }
    
    public func autoSelectNewAccounts(availableItems: [MenuBarQuotaItem]) {
        // Don't auto-add if user has manually modified the menu bar selection
        guard !hasUserModifiedMenuBar else { return }

        enforceMaxItems()
        let existingIds = Set(selectedItems.map(\.id))
        let newItems = availableItems.filter { !existingIds.contains($0.id) }

        let remainingSlots = menuBarMaxItems - effectiveSelectedItemCount
        if remainingSlots > 0 {
            let itemsToAdd = Array(newItems.prefix(remainingSlots))
            selectedItems.append(contentsOf: itemsToAdd)
        }
    }

    /// Trims `selectedItems` down to `menuBarMaxItems` by *effective* occupancy, not raw
    /// count: a legacy pool pin that currently covers no real account (see
    /// `poolPinIsCurrentlyEmpty`) never counts against the cap and is never dropped here,
    /// so it survives as a dead placeholder ready to reserve a slot again once its source
    /// reports a real account. Trimming raw entries beyond the cap would otherwise
    /// silently discard a newer pin (e.g. a freshly-added plan aggregate) whenever
    /// earlier, currently-empty pool pins pad out the raw array past `menuBarMaxItems`
    /// even though they occupy no slot.
    @discardableResult
    private func enforceMaxItems() -> Bool {
        guard effectiveSelectedItemCount > menuBarMaxItems else { return false }
        var kept: [MenuBarQuotaItem] = []
        var occupied = 0
        for item in selectedItems {
            let occupiesSlot = !item.isPool || !poolPinIsCurrentlyEmpty(item)
            if occupiesSlot {
                guard occupied < menuBarMaxItems else { continue }
                occupied += 1
            }
            kept.append(item)
        }
        guard kept.count != selectedItems.count else { return false }
        selectedItems = kept
        return true
    }

    private static func clampedMenuBarMax(_ value: Int) -> Int {
        min(max(value, minMenuBarItems), maxMenuBarItems)
    }

    private func persist() {
        let preferences = preferences
        repository.save(preferences)
        didChangeHandler?(preferences)
    }
}
