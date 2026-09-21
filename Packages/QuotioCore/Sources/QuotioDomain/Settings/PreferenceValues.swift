import Foundation

public enum OperatingMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case monitor = "monitor"
    case localProxy = "local"

    public var id: String { rawValue }

    public static func fromLegacy(appModeRaw: String?, connectionModeRaw: String?) -> OperatingMode {
        guard let appModeRaw else { return .monitor }

        switch appModeRaw {
        case "quotaOnly":
            return .monitor
        case "full":
            return connectionModeRaw == "remote" ? .monitor : .localProxy
        default:
            return .monitor
        }
    }
}

public struct OperatingModePreferences: Equatable, Sendable {
    public var mode: OperatingMode
    public var hasCompletedOnboarding: Bool

    public init(mode: OperatingMode = .monitor, hasCompletedOnboarding: Bool = false) {
        self.mode = mode
        self.hasCompletedOnboarding = hasCompletedOnboarding
    }
}

public struct MenuBarQuotaItem: Codable, Identifiable, Hashable, Sendable {
    public let provider: String
    public let accountKey: String
    /// nil = local account; non-nil = the `RemoteQuotaSourceConfig.id` this item's
    /// pooled quota was fetched from. Kept optional so pre-existing persisted items
    /// (and JSON written before this field existed) decode unchanged.
    public let sourceConfigId: String?

    private enum CodingKeys: String, CodingKey {
        case provider, accountKey, sourceConfigId
    }

    public init(provider: String, accountKey: String, sourceConfigId: String? = nil) {
        self.provider = provider
        self.accountKey = accountKey
        self.sourceConfigId = sourceConfigId
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        provider = try container.decode(String.self, forKey: .provider)
        accountKey = try container.decode(String.self, forKey: .accountKey)
        sourceConfigId = try container.decodeIfPresent(String.self, forKey: .sourceConfigId)
    }

    public var id: String {
        guard let sourceConfigId else { return "\(provider)_\(accountKey)" }
        return "remote:\(sourceConfigId):\(provider)_\(accountKey)"
    }

    public var isRemote: Bool { sourceConfigId != nil }
    public var isPool: Bool { accountKey == RemoteQuotaPoolIdentity.accountKey }
    /// Whether `accountKey` is a `RemoteQuotaAggregateIdentity` storage key — a pin
    /// targeting a derived same-source/provider/plan summary row, never a real account.
    public var isAggregate: Bool { RemoteQuotaAggregateIdentity.components(fromStorageKey: accountKey) != nil }
}

public enum MenuBarColorMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case colored = "colored"
    case monochrome = "monochrome"

    public var id: String { rawValue }
}

public enum QuotaDisplayMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case used = "used"
    case remaining = "remaining"

    public var id: String { rawValue }

    public func displayValue(from remainingPercent: Double) -> Double {
        guard remainingPercent >= 0 else { return -1 }
        let clamped = min(100, max(0, remainingPercent))
        return self == .used ? 100 - clamped : clamped
    }
}

public enum QuotaDisplayStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case card = "card"
    case lowestBar = "lowestBar"
    case ring = "ring"

    public var id: String { rawValue }
}

public enum TotalUsageMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case sessionOnly = "sessionOnly"
    case combined = "combined"

    public var id: String { rawValue }
}

public enum ModelAggregationMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case lowest = "lowest"
    case average = "average"

    public var id: String { rawValue }
}

public struct MenuBarPreferences: Equatable, Sendable {
    public var showMenuBarIcon: Bool
    public var showQuotaInMenuBar: Bool
    public var menuBarMaxItems: Int
    public var selectedItems: [MenuBarQuotaItem]
    public var selectedProvider: QuotaProvider?
    public var colorMode: MenuBarColorMode
    public var quotaDisplayMode: QuotaDisplayMode
    public var quotaDisplayStyle: QuotaDisplayStyle
    public var stackPairedQuotaMetrics: Bool
    public var hideSensitiveInfo: Bool
    public var totalUsageMode: TotalUsageMode
    public var modelAggregationMode: ModelAggregationMode
    public var hasUserModifiedMenuBar: Bool
    /// `MenuBarQuotaItem.id`s of individual remote accounts the user turned off while
    /// they were covered only by a legacy pool pin (`accountKey == "__pool__"`), which
    /// expands dynamically and therefore has no per-account entry to remove. Kept apart
    /// from `selectedItems` so it is never subject to `menuBarMaxItems` truncation — a
    /// deselection must survive regardless of how many items fit in the menu bar.
    public var deselectedPoolAccounts: Set<String>
    /// `MenuBarQuotaItem.id`-shaped keys the user turned off from the menu bar's
    /// per-provider dropdown account list. This is display-only: it never disables the
    /// account, never affects fetching, and never touches `selectedItems`/pins — a
    /// hidden account's own pin (if any) keeps working exactly as before. Applies to
    /// every real account, local and remote alike — local sources (proxy, monitor,
    /// direct) have a real disable mechanism of their own, but that only stops
    /// fetching/usage; it says nothing about whether the account should still clutter
    /// the dropdown, so this exists for them too. Keyed by `MenuBarQuotaItem.id` (which
    /// already namespaces by provider and, for remote accounts, by source id) rather
    /// than the raw account key, so a local and a remote account — or two local accounts
    /// on different providers — that happen to share a raw key/email can never collide
    /// in this set. Defaults to empty so pre-existing persisted state decodes unchanged.
    public var hiddenDropdownKeys: Set<String>
    /// User-customized display order for `RemoteQuotaSourceGroupIdentity` keys — one
    /// entry per configured remote source's accounts under one provider. Position in the
    /// array is the rank; a key absent from this list has no persisted rank and falls
    /// back to the pre-existing (alphabetical) sort. Drives the Accounts page's
    /// source/provider group order and, from the same persisted state, the menu bar
    /// dropdown's group order — never reordered automatically from live quota data.
    /// Defaults to empty so pre-existing installs keep today's alphabetical order until
    /// the user explicitly reorders something.
    public var sourceGroupOrder: [String]
    /// User-customized display order for individual accounts *inside* one group — the
    /// local group or one remote source's group under a provider — keyed by
    /// `MenuBarQuotaItem.id` (which already namespaces by provider and, for remote
    /// accounts, by source id, so two accounts sharing a raw key/email never collide).
    /// Position in the array is the rank; a key absent from this list has no persisted
    /// rank and falls back to the pre-existing (alphabetical/display) sort. One flat
    /// array holds every group's ranks: comparisons only ever happen between accounts of
    /// the same group, so keys from different groups being interleaved here is
    /// immaterial. Drives the menu bar dropdown's per-group account order and the
    /// Accounts page list, and is never reordered automatically from live quota data.
    /// Defaults to empty so pre-existing installs keep today's order until the user
    /// explicitly moves an account.
    public var accountOrder: [String]

    public init(
        showMenuBarIcon: Bool = true,
        showQuotaInMenuBar: Bool = true,
        menuBarMaxItems: Int = 3,
        selectedItems: [MenuBarQuotaItem] = [],
        selectedProvider: QuotaProvider? = nil,
        colorMode: MenuBarColorMode = .colored,
        quotaDisplayMode: QuotaDisplayMode = .used,
        quotaDisplayStyle: QuotaDisplayStyle = .card,
        stackPairedQuotaMetrics: Bool = true,
        hideSensitiveInfo: Bool = false,
        totalUsageMode: TotalUsageMode = .sessionOnly,
        modelAggregationMode: ModelAggregationMode = .lowest,
        hasUserModifiedMenuBar: Bool = false,
        deselectedPoolAccounts: Set<String> = [],
        hiddenDropdownKeys: Set<String> = [],
        sourceGroupOrder: [String] = [],
        accountOrder: [String] = []
    ) {
        self.showMenuBarIcon = showMenuBarIcon
        self.showQuotaInMenuBar = showQuotaInMenuBar
        self.menuBarMaxItems = menuBarMaxItems
        self.selectedItems = selectedItems
        self.selectedProvider = selectedProvider
        self.colorMode = colorMode
        self.quotaDisplayMode = quotaDisplayMode
        self.quotaDisplayStyle = quotaDisplayStyle
        self.stackPairedQuotaMetrics = stackPairedQuotaMetrics
        self.hideSensitiveInfo = hideSensitiveInfo
        self.totalUsageMode = totalUsageMode
        self.modelAggregationMode = modelAggregationMode
        self.hasUserModifiedMenuBar = hasUserModifiedMenuBar
        self.deselectedPoolAccounts = deselectedPoolAccounts
        self.hiddenDropdownKeys = hiddenDropdownKeys
        self.sourceGroupOrder = sourceGroupOrder
        self.accountOrder = accountOrder
    }
}

public enum RefreshCadence: String, Codable, CaseIterable, Identifiable, Sendable {
    case manual = "manual"
    case oneMinute = "1min"
    case twoMinutes = "2min"
    case fiveMinutes = "5min"
    case tenMinutes = "10min"
    case fifteenMinutes = "15min"

    public var id: String { rawValue }

    public var intervalSeconds: TimeInterval? {
        switch self {
        case .manual: nil
        case .oneMinute: 60
        case .twoMinutes: 120
        case .fiveMinutes: 300
        case .tenMinutes: 600
        case .fifteenMinutes: 900
        }
    }

    public var intervalNanoseconds: UInt64? {
        intervalSeconds.map { UInt64($0 * 1_000_000_000) }
    }
}

public struct RefreshPreferences: Equatable, Sendable {
    public var cadence: RefreshCadence

    public init(cadence: RefreshCadence = .tenMinutes) {
        self.cadence = cadence
    }
}

public enum WarmupCadence: String, Codable, CaseIterable, Identifiable, Sendable {
    case fifteenMinutes = "15min"
    case thirtyMinutes = "30min"
    case oneHour = "1h"
    case twoHours = "2h"
    case threeHours = "3h"
    case fourHours = "4h"

    public var id: String { rawValue }

    public var intervalSeconds: TimeInterval {
        switch self {
        case .fifteenMinutes: 900
        case .thirtyMinutes: 1_800
        case .oneHour: 3_600
        case .twoHours: 7_200
        case .threeHours: 10_800
        case .fourHours: 14_400
        }
    }

    public var intervalNanoseconds: UInt64 {
        UInt64(intervalSeconds * 1_000_000_000)
    }
}

public enum WarmupScheduleMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case interval
    case daily

    public var id: String { rawValue }
}

public struct WarmupPreferences: Equatable, Sendable {
    public var enabledAccountIds: Set<String>
    public var cadence: WarmupCadence
    public var scheduleMode: WarmupScheduleMode
    public var dailyMinutes: Int
    public var selectedModelsByAccount: [String: [String]]
    public var cadenceByAccount: [String: String]
    public var scheduleModeByAccount: [String: String]
    public var dailyMinutesByAccount: [String: Int]

    public init(
        enabledAccountIds: Set<String> = [],
        cadence: WarmupCadence = .oneHour,
        scheduleMode: WarmupScheduleMode = .interval,
        dailyMinutes: Int = 540,
        selectedModelsByAccount: [String: [String]] = [:],
        cadenceByAccount: [String: String] = [:],
        scheduleModeByAccount: [String: String] = [:],
        dailyMinutesByAccount: [String: Int] = [:]
    ) {
        self.enabledAccountIds = enabledAccountIds
        self.cadence = cadence
        self.scheduleMode = scheduleMode
        self.dailyMinutes = dailyMinutes
        self.selectedModelsByAccount = selectedModelsByAccount
        self.cadenceByAccount = cadenceByAccount
        self.scheduleModeByAccount = scheduleModeByAccount
        self.dailyMinutesByAccount = dailyMinutesByAccount
    }
}

public struct IDEScanOptions: Equatable, Sendable {
    public var scanCursor: Bool
    public var scanTrae: Bool
    public var scanCLITools: Bool

    public init(scanCursor: Bool = false, scanTrae: Bool = false, scanCLITools: Bool = true) {
        self.scanCursor = scanCursor
        self.scanTrae = scanTrae
        self.scanCLITools = scanCLITools
    }

    public var hasIDEScanEnabled: Bool { scanCursor || scanTrae }
    public var hasAnyScanEnabled: Bool { scanCursor || scanTrae || scanCLITools }

    public static let defaultOptions = IDEScanOptions()
    public static let allEnabled = IDEScanOptions(scanCursor: true, scanTrae: true, scanCLITools: true)
}

public struct IDEScanResult: Equatable, Sendable {
    public let cursorFound: Bool
    public let cursorEmail: String?
    public let traeFound: Bool
    public let traeEmail: String?
    public let cliToolsFound: [String]
    public let timestamp: Date

    public init(
        cursorFound: Bool,
        cursorEmail: String?,
        traeFound: Bool,
        traeEmail: String?,
        cliToolsFound: [String],
        timestamp: Date
    ) {
        self.cursorFound = cursorFound
        self.cursorEmail = cursorEmail
        self.traeFound = traeFound
        self.traeEmail = traeEmail
        self.cliToolsFound = cliToolsFound
        self.timestamp = timestamp
    }

    public static var empty: IDEScanResult {
        IDEScanResult(
            cursorFound: false,
            cursorEmail: nil,
            traeFound: false,
            traeEmail: nil,
            cliToolsFound: [],
            timestamp: Date()
        )
    }
}

public enum AppearanceMode: String, CaseIterable, Identifiable, Sendable {
    case system = "system"
    case light = "light"
    case dark = "dark"

    public var id: String { rawValue }
}

public struct AppearancePreferences: Equatable, Sendable {
    public var mode: AppearanceMode

    public init(mode: AppearanceMode = .system) {
        self.mode = mode
    }
}

public enum AppLanguage: String, Codable, CaseIterable, Identifiable, Sendable {
    case english = "en"
    case vietnamese = "vi"
    case chinese = "zh-Hans"
    case french = "fr"

    public var id: String { rawValue }
}

public struct LanguagePreferences: Equatable, Sendable {
    public var language: AppLanguage

    public init(language: AppLanguage = .english) {
        self.language = language
    }
}

public enum UpdateChannel: String, CaseIterable, Identifiable, Sendable {
    case stable
    case beta

    public var id: String { rawValue }
}

public struct UpdatePreferences: Equatable, Sendable {
    public var channel: UpdateChannel

    public init(channel: UpdateChannel = .stable) {
        self.channel = channel
    }
}

public struct TelemetryPreferences: Equatable, Sendable {
    public var shareAnonymousUsage: Bool
    public var anonymousInstallID: String?
    public var hasSentFirstOptInLaunch: Bool

    public init(
        shareAnonymousUsage: Bool = false,
        anonymousInstallID: String? = nil,
        hasSentFirstOptInLaunch: Bool = false
    ) {
        self.shareAnonymousUsage = shareAnonymousUsage
        self.anonymousInstallID = anonymousInstallID
        self.hasSentFirstOptInLaunch = hasSentFirstOptInLaunch
    }
}

public struct NotificationPreferences: Equatable, Sendable {
    public var notificationsEnabled: Bool
    public var quotaAlertThreshold: Double
    public var notifyOnQuotaLow: Bool
    public var notifyOnCooling: Bool
    public var notifyOnProxyCrash: Bool
    public var notifyOnUpgradeAvailable: Bool

    public init(
        notificationsEnabled: Bool = true,
        quotaAlertThreshold: Double = 20,
        notifyOnQuotaLow: Bool = true,
        notifyOnCooling: Bool = true,
        notifyOnProxyCrash: Bool = true,
        notifyOnUpgradeAvailable: Bool = true
    ) {
        self.notificationsEnabled = notificationsEnabled
        self.quotaAlertThreshold = quotaAlertThreshold
        self.notifyOnQuotaLow = notifyOnQuotaLow
        self.notifyOnCooling = notifyOnCooling
        self.notifyOnProxyCrash = notifyOnProxyCrash
        self.notifyOnUpgradeAvailable = notifyOnUpgradeAvailable
    }
}

public struct ProxyPreferences: Equatable, Sendable {
    public var autoStartProxy: Bool
    public var allowNetworkAccess: Bool
    public var loggingToFile: Bool
    public var proxyURL: String?

    public init(
        autoStartProxy: Bool = false,
        allowNetworkAccess: Bool = false,
        loggingToFile: Bool = true,
        proxyURL: String? = nil
    ) {
        self.autoStartProxy = autoStartProxy
        self.allowNetworkAccess = allowNetworkAccess
        self.loggingToFile = loggingToFile
        self.proxyURL = proxyURL
    }
}

public struct TunnelPreferences: Equatable, Sendable {
    public var autoStartTunnel: Bool
    public var autoRestartTunnel: Bool

    public init(autoStartTunnel: Bool = false, autoRestartTunnel: Bool = false) {
        self.autoStartTunnel = autoStartTunnel
        self.autoRestartTunnel = autoRestartTunnel
    }
}

public struct AppShellPreferences: Equatable, Sendable {
    public var autoCheckUpdates: Bool
    public var showInDock: Bool
    public var hideGettingStarted: Bool

    public init(
        autoCheckUpdates: Bool = true,
        showInDock: Bool = true,
        hideGettingStarted: Bool = false
    ) {
        self.autoCheckUpdates = autoCheckUpdates
        self.showInDock = showInDock
        self.hideGettingStarted = hideGettingStarted
    }
}
