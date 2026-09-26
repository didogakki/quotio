import Foundation

public enum QuotaProvider: String, CaseIterable, Codable, Identifiable, Sendable {
    case claude
    case codex
    case qwen
    case iflow
    case antigravity
    case vertex
    case kiro
    case copilot = "github-copilot"
    case cursor
    case factoryDroid = "factory-droid"
    case devin
    case grok
    case openRouter = "openrouter"
    case amp
    case trae
    case glm
    case warp
    case clinePass = "clinepass"

    public var id: String { rawValue }

    public var supportsQuotaOnlyMode: Bool {
        switch self {
        case .qwen, .iflow, .vertex:
            false
        default:
            true
        }
    }

    public var usesBrowserAuth: Bool {
        self == .cursor || self == .trae
    }

    public var usesCLIQuota: Bool {
        self == .claude || self == .codex
    }

    public var supportsManualAuth: Bool {
        switch self {
        case .cursor, .trae, .devin, .grok, .glm, .clinePass:
            false
        default:
            true
        }
    }

    public var isImportedFromLocalIDE: Bool {
        usesBrowserAuth && !supportsManualAuth
    }

    public var usesAPIKeyAuth: Bool {
        switch self {
        case .glm, .warp, .clinePass, .factoryDroid, .openRouter, .amp:
            true
        default:
            false
        }
    }

    public var isQuotaTrackingOnly: Bool {
        switch self {
        case .cursor, .trae, .factoryDroid, .devin, .grok, .openRouter, .amp, .warp:
            true
        default:
            false
        }
    }

    public var supportsLocalProxySetup: Bool {
        supportsManualAuth && !isQuotaTrackingOnly
    }

    public var cliAgent: CLIAgent? {
        switch self {
        case .claude: .claudeCode
        case .codex: .codexCLI
        default: nil
        }
    }
}

public struct QuotaAccountID: Hashable, Sendable {
    public let provider: QuotaProvider
    public let accountKey: String

    public init(provider: QuotaProvider, accountKey: String) {
        self.provider = provider
        self.accountKey = accountKey
    }
}

public enum QuotaMetricUnit: String, Codable, Equatable, Sendable {
    case usd
    case credits
    case requests
    case searches
}

public enum QuotaAmountSemantics: String, Codable, Equatable, Sendable {
    case balance
    case spent
}

public enum QuotaMetricPresentation: Codable, Equatable, Sendable {
    case progress(used: Double, limit: Double, unit: QuotaMetricUnit)
    case amount(value: Double, unit: QuotaMetricUnit, semantics: QuotaAmountSemantics)
    case status(text: String)
}

public struct QuotaMetric: Codable, Equatable, Identifiable, Sendable {
    public let name: String
    public let percentage: Double
    public let resetTime: String
    public var presentation: QuotaMetricPresentation?
    public var used: Int?
    public var limit: Int?
    public var remaining: Int?
    public var tooltip: String?

    public var id: String { name }
    public var usedPercentage: Double { 100 - percentage }

    public init(
        name: String,
        percentage: Double,
        resetTime: String,
        presentation: QuotaMetricPresentation? = nil,
        used: Int? = nil,
        limit: Int? = nil,
        remaining: Int? = nil,
        tooltip: String? = nil
    ) {
        self.name = name
        self.percentage = percentage
        self.resetTime = resetTime
        self.presentation = presentation
        self.used = used
        self.limit = limit
        self.remaining = remaining
        self.tooltip = tooltip
    }
}

public struct QuotaAnalytics: Codable, Equatable, Sendable {
    public var trend: [QuotaAnalyticsPoint]
    public var rows: [QuotaAnalyticsRow]
    public var note: String?

    public var isEmpty: Bool {
        trend.isEmpty && rows.isEmpty && (note?.isEmpty ?? true)
    }

    public init(
        trend: [QuotaAnalyticsPoint] = [],
        rows: [QuotaAnalyticsRow] = [],
        note: String? = nil
    ) {
        self.trend = trend
        self.rows = rows
        self.note = note
    }

    public func merging(_ other: QuotaAnalytics?) -> QuotaAnalytics {
        guard let other, !other.isEmpty else { return self }
        var mergedRows = rows
        var seen = Set(rows.map(\.id))
        for row in other.rows where seen.insert(row.id).inserted {
            mergedRows.append(row)
        }
        return QuotaAnalytics(
            trend: other.trend.isEmpty ? trend : other.trend,
            rows: mergedRows,
            note: other.note ?? note
        )
    }
}

public struct QuotaAnalyticsPoint: Codable, Equatable, Identifiable, Sendable {
    public var id: String { date }
    public var date: String
    public var value: Double
    public var label: String
    public var valueLabel: String

    public init(date: String, value: Double, label: String, valueLabel: String) {
        self.date = date
        self.value = value
        self.label = label
        self.valueLabel = valueLabel
    }
}

public struct QuotaAnalyticsRow: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var value: String
    public var isAvailable: Bool

    public init(id: String, title: String, value: String, isAvailable: Bool = true) {
        self.id = id
        self.title = title
        self.value = value
        self.isAvailable = isAvailable
    }
}

/// One Codex account's currently-available rate-limit reset credits, as last reported
/// by the `wham/rate-limit-reset-credits` endpoint (see `CodexResetCreditInventoryFetcher`)
/// — never from the local Codex CLI/app's own data. `availableCount` and
/// `nearestExpiryAt` are computed from the same available-and-unexpired-at-fetch-time
/// filter, so they always describe the same set of credits. `nil` on `ProviderQuota`
/// means "no successful fetch yet" — never a synthetic zero.
public struct CodexResetCreditSummary: Codable, Equatable, Sendable {
    public let availableCount: Int
    /// `nil` when `availableCount` is 0, or when every available credit happens to
    /// carry no expiry at all — never a fabricated date.
    public let nearestExpiryAt: Date?

    public init(availableCount: Int, nearestExpiryAt: Date?) {
        self.availableCount = availableCount
        self.nearestExpiryAt = nearestExpiryAt
    }
}

/// Non-sensitive account-level problem explicitly observed by a remote quota source.
/// Optional so snapshots written before this field existed continue to decode normally.
public enum RemoteQuotaAccountIssue: String, Codable, Equatable, Sendable {
    case invalidOAuth
}

/// One CPA pool's account/channel routing-weight reading, as optionally reported
/// alongside a Codex account's own quota-cache response (`routing_weights` on the
/// existing per-account `codex-usage` fetch — never a separate endpoint/request).
/// `accountWeight` is the account's own raw weight within its pool, never normalized
/// to a percentage; `channelWeight` is the weight of the New API channel currently
/// serving that pool at `updatedAt`. Absent entirely (never a synthetic zero) when the
/// cache has no weights configured, the pool layer errored, or the source isn't cache-
/// enabled.
public struct AccountRoutingWeight: Codable, Equatable, Sendable {
    public let accountWeight: Int
    public let channelWeight: Int
    public let updatedAt: Date

    public init(accountWeight: Int, channelWeight: Int, updatedAt: Date) {
        self.accountWeight = accountWeight
        self.channelWeight = channelWeight
        self.updatedAt = updatedAt
    }
}

public struct ProviderQuota: Codable, Equatable, Sendable {
    public var models: [QuotaMetric]
    public var lastUpdated: Date
    public var isForbidden: Bool
    public var planType: String?
    public var tokenExpiresAt: Date?
    public var analytics: QuotaAnalytics?
    public var accountDisplayName: String?
    public var codexResetCreditSummary: CodexResetCreditSummary?
    /// A safe, typed account problem reported by the quota-cache. The cache never sends
    /// the upstream error body, so persisting this on the last-known-good reading cannot
    /// leak OAuth tokens or provider response text. Cleared only after a successful quota
    /// reading for the same account identity; generic network failures leave it untouched.
    public var remoteAccountIssue: RemoteQuotaAccountIssue?
    /// Set only for a remote (CLIProxyAPI) account the source currently reports as
    /// frozen — cooling after a rate limit, or otherwise flagged unavailable. Distinct
    /// from `isForbidden`, which means the account's own credential was rejected: this
    /// one is transient and clears itself the moment the source lists the account as
    /// ready again. `nil` (not `false`) means "no such state", which is also how every
    /// reading written by an older build decodes — hence Optional: a non-Optional Bool
    /// would make the synthesized decoder reject every cached reading that predates
    /// this field, silently wiping the last-known-good snapshot it is meant to protect.
    public var isTemporarilyUnavailable: Bool?
    /// Real freeze/cooldown recovery time for this account, taken directly from the
    /// remote source's own structured signals (see
    /// `ManagedAuthFile.recoveryDate(fetchedAt:)`), or — only for an explicit 429
    /// response — an *estimate* from that response's own `Retry-After` header (see
    /// `RemoteManagementQuotaFetcher`'s header fallback); never derived from any
    /// `QuotaMetric.resetTime`. That field is a distinct, unrelated concept (the
    /// provider's own usage-window reset, e.g. Claude's 5-hour session window); using it
    /// here would misrepresent an account's freeze/cooldown recovery as its next quota
    /// reset. `nil` means "no real recovery time is known", never a fabricated fallback —
    /// this is re-resolved fresh every refresh round (see
    /// `RemoteQuotaSourceCoordinator.refresh`), so a round with no fresh signal clears a
    /// stale value rather than leaving it in place.
    public var availabilityRecoveryDate: Date?
    /// This Codex account's CPA pool routing-weight reading, carried alongside the
    /// same quota-cache response the account's usage reading already came from —
    /// `nil` (never a synthetic zero) when the cache has no weights configured, the
    /// pool layer reported an error, or the source isn't cache-enabled at all.
    public var routingWeight: AccountRoutingWeight?
    /// This Codex account's own `rate_limit.limit_reached` flag, taken directly from
    /// its most recent *successful* Codex quota response (`CodexQuotaFetcher.mapUsage`,
    /// shared by both the local and remote/CPA Codex fetch paths). Distinct from
    /// `isForbidden`, which already folds this same flag into a provider-agnostic
    /// "credential rejected" signal used by aggregate math and every other surface —
    /// this field exists only so the menu dropdown can tell "Codex reported the limit
    /// reached" apart from "this account's credential was rejected for some other
    /// reason". `nil` means "no successful Codex response has reported this yet",
    /// including every reading written by a build predating this field; never set from
    /// a failed fetch, a cache/error path, or a non-Codex provider.
    public var codexLimitReached: Bool?

    public init(
        models: [QuotaMetric] = [],
        lastUpdated: Date = Date(),
        isForbidden: Bool = false,
        planType: String? = nil,
        tokenExpiresAt: Date? = nil,
        analytics: QuotaAnalytics? = nil,
        accountDisplayName: String? = nil,
        codexResetCreditSummary: CodexResetCreditSummary? = nil,
        remoteAccountIssue: RemoteQuotaAccountIssue? = nil,
        isTemporarilyUnavailable: Bool? = nil,
        availabilityRecoveryDate: Date? = nil,
        routingWeight: AccountRoutingWeight? = nil,
        codexLimitReached: Bool? = nil
    ) {
        self.models = models
        self.lastUpdated = lastUpdated
        self.isForbidden = isForbidden
        self.planType = planType
        self.tokenExpiresAt = tokenExpiresAt
        self.analytics = analytics
        self.accountDisplayName = accountDisplayName
        self.codexResetCreditSummary = codexResetCreditSummary
        self.remoteAccountIssue = remoteAccountIssue
        self.isTemporarilyUnavailable = isTemporarilyUnavailable
        self.availabilityRecoveryDate = availabilityRecoveryDate
        self.routingWeight = routingWeight
        self.codexLimitReached = codexLimitReached
    }
}

public struct QuotaSubscriptionTier: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let description: String
    public let privacyNotice: QuotaPrivacyNotice?
    public let isDefault: Bool?
    public let upgradeSubscriptionUri: String?
    public let upgradeSubscriptionText: String?
    public let upgradeSubscriptionType: String?
    public let userDefinedCloudaicompanionProject: Bool?

    public init(
        id: String,
        name: String,
        description: String,
        privacyNotice: QuotaPrivacyNotice?,
        isDefault: Bool?,
        upgradeSubscriptionUri: String?,
        upgradeSubscriptionText: String?,
        upgradeSubscriptionType: String?,
        userDefinedCloudaicompanionProject: Bool?
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.privacyNotice = privacyNotice
        self.isDefault = isDefault
        self.upgradeSubscriptionUri = upgradeSubscriptionUri
        self.upgradeSubscriptionText = upgradeSubscriptionText
        self.upgradeSubscriptionType = upgradeSubscriptionType
        self.userDefinedCloudaicompanionProject = userDefinedCloudaicompanionProject
    }
}

public struct QuotaPrivacyNotice: Codable, Equatable, Sendable {
    public let showNotice: Bool?
    public let noticeText: String?

    public init(showNotice: Bool?, noticeText: String?) {
        self.showNotice = showNotice
        self.noticeText = noticeText
    }
}

public struct QuotaSubscriptionInfo: Codable, Equatable, Sendable {
    public let currentTier: QuotaSubscriptionTier?
    public let allowedTiers: [QuotaSubscriptionTier]?
    public let cloudaicompanionProject: String?
    public let gcpManaged: Bool?
    public let upgradeSubscriptionUri: String?
    public let paidTier: QuotaSubscriptionTier?

    public var effectiveTier: QuotaSubscriptionTier? { paidTier ?? currentTier }
    public var tierId: String { effectiveTier?.id ?? "unknown" }
    public var isPaidTier: Bool {
        guard let id = effectiveTier?.id else { return false }
        return id.contains("pro") || id.contains("ultra")
    }
    public var canUpgrade: Bool { effectiveTier?.upgradeSubscriptionUri != nil }
    public var upgradeURL: URL? {
        effectiveTier?.upgradeSubscriptionUri.flatMap(URL.init(string:))
    }

    public init(
        currentTier: QuotaSubscriptionTier?,
        allowedTiers: [QuotaSubscriptionTier]?,
        cloudaicompanionProject: String?,
        gcpManaged: Bool?,
        upgradeSubscriptionUri: String?,
        paidTier: QuotaSubscriptionTier?
    ) {
        self.currentTier = currentTier
        self.allowedTiers = allowedTiers
        self.cloudaicompanionProject = cloudaicompanionProject
        self.gcpManaged = gcpManaged
        self.upgradeSubscriptionUri = upgradeSubscriptionUri
        self.paidTier = paidTier
    }
}

public enum QuotaPolicy {
    public static func mergeImportedIDEQuotas(
        fetched: [String: ProviderQuota],
        into existing: [String: ProviderQuota]
    ) -> [String: ProviderQuota] {
        guard !existing.isEmpty else { return existing }
        var merged = existing
        for (accountKey, quota) in fetched where existing[accountKey] != nil {
            merged[accountKey] = quota
        }
        return merged
    }

    public static func canonicalizedAccounts(
        _ quotas: [String: ProviderQuota],
        aliases: [String: String]
    ) -> [String: ProviderQuota] {
        var result = quotas
        for (alias, canonical) in aliases where alias != canonical {
            guard let aliasQuota = result.removeValue(forKey: alias) else { continue }
            if result[canonical].map({ $0.lastUpdated <= aliasQuota.lastUpdated }) ?? true {
                result[canonical] = aliasQuota
            }
        }
        return result
    }

    public static func lastUpdated(
        for account: QuotaAccountID,
        in quotas: [QuotaProvider: [String: ProviderQuota]]
    ) -> Date? {
        quotas[account.provider]?[account.accountKey]?.lastUpdated
    }

    public static func lowestAvailablePercentage(in quota: ProviderQuota) -> Double {
        quota.models.lazy.map(\.percentage).filter { $0 >= 0 }.min()
            ?? quota.models.first?.percentage
            ?? -1
    }

    /// Buckets a raw `planType` string into a small, stable set of keys so accounts on
    /// equivalent plans (e.g. "Pro", "Pro 5x", "Pro 20x") group together instead of
    /// each raw label producing its own pool. Unrecognized labels fall back to a
    /// slugified version of themselves so they still group consistently.
    public static func normalizedPlanKey(_ planType: String?) -> String {
        guard let trimmed = planType?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return "unknown" }
        let lower = trimmed.lowercased()
        // Matched on a punctuation/whitespace-stripped form so "Pro 5x", "pro-lite",
        // "pro_lite", and "prolite" all normalize the same way, without the looser
        // substring check on `lower` swallowing them into plain "pro".
        let compact = lower.filter { $0.isLetter || $0.isNumber }
        if lower.contains("enterprise") { return "enterprise" }
        if lower.contains("business") { return "business" }
        if lower.contains("team") { return "team" }
        if compact.contains("prolite") || compact.contains("pro5x") { return "pro_lite" }
        if lower.contains("pro") { return "pro" }
        if lower.contains("plus") { return "plus" }
        if lower.contains("free") || lower.contains("standard") { return "free" }
        return slugify(lower)
    }

    /// Reduces an unrecognized plan label to a key made only of ASCII letters, digits,
    /// and underscores, so it can never break `RemoteQuotaPoolIdentity`'s `::`-delimited
    /// composite storage keys (a raw label containing `::` or `/` would corrupt parsing).
    private static func slugify(_ lower: String) -> String {
        var result = String(lower.map { $0.isLetter || $0.isNumber ? $0 : "_" })
        while result.contains("__") { result = result.replacingOccurrences(of: "__", with: "_") }
        result = result.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return result.isEmpty ? "unknown" : result
    }

    /// One-time default for a specific, already-existing remote source — confirmed by
    /// the user (2026-09-09) to have its Grok/xAI account on the "Premium" plan — whose
    /// CLIProxyAPI management API reports no plan metadata for that account at all.
    /// Unlike Claude/Codex, the remote Grok fetch path has no per-account plan field on
    /// the auth-file listing; `/v1/settings`'s `subscription_tier_display` (tried first,
    /// mirroring the local Grok fetcher) is the only real metadata signal, and this
    /// default is only ever consulted when that comes back empty too.
    ///
    /// Scoped by `sourceId` — `RemoteQuotaSourceConfig.id`, never its user-editable
    /// `name` — so it survives that one source being renamed, and a different,
    /// unrelated source that merely shares a display name with it never qualifies.
    /// `knownLegacySourceId` is the caller's already-resolved stable identity for that
    /// one confirmed source (see `RemoteQuotaSourceCoordinator`, which captures it once
    /// by name and remembers it by id from then on) — never a blanket "every unknown
    /// Grok account, or every unknown provider, is Premium" default. Real metadata, once
    /// available (now or in the future), always wins over this default; blank/whitespace
    /// metadata is normalized to "missing" rather than displayed verbatim.
    public static func legacyGrokPlanDefault(
        sourceId: String,
        knownLegacySourceId: String?,
        rawPlanType: String?
    ) -> String? {
        let isBlank = rawPlanType?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
        guard isBlank else { return rawPlanType }
        guard sourceId == knownLegacySourceId else { return nil }
        return "Premium"
    }

    /// Well-known ids of the Codex reset-credit analytics rows produced by
    /// `CodexResetCreditInventoryFetcher` — the summary row plus one row per available
    /// credit. Exposed here (rather than only as private literals in Infrastructure/
    /// Presentation) so `mergingCodexResetCredits` can identify them without owning the
    /// full row-building logic itself.
    private static let codexResetCreditSummaryRowID = "codex-rate-limit-resets"
    private static let codexResetCreditRowIDPrefix = "codex-rate-limit-reset-"

    /// Merges one refresh round's freshly-fetched reading (`new`) on top of the last
    /// successful reading for the *same* account (`old`) — intended for a
    /// `Dictionary.merge(_:uniquingKeysWith:)` combine closure, which only ever runs on
    /// key collisions, so this can never mix data across different accounts or sources.
    ///
    /// Codex's reset-credit inventory is fetched by a separate, best-effort request
    /// that can fail even when the round's main usage fetch succeeds (see
    /// `RemoteManagementQuotaFetcher`'s Codex path); when that happens, `new` carries no
    /// reset-credit data of its own (`codexResetCreditSummary == nil`). Without this,
    /// the account would visibly lose its reset-credit summary and analytics rows for
    /// one failed round even though nothing about the account actually changed. A `new`
    /// summary that is non-nil — including a genuine zero reading — always wins, since
    /// that is a real fresh result, never a failure.
    public static func mergingCodexResetCredits(old: ProviderQuota?, new: ProviderQuota) -> ProviderQuota {
        guard new.codexResetCreditSummary == nil,
              let old, let oldSummary = old.codexResetCreditSummary else {
            return new
        }

        var merged = new
        merged.codexResetCreditSummary = oldSummary

        let staleResetRows = old.analytics?.rows.filter {
            $0.id == codexResetCreditSummaryRowID || $0.id.hasPrefix(codexResetCreditRowIDPrefix)
        } ?? []
        guard !staleResetRows.isEmpty else { return merged }

        var rows = merged.analytics?.rows ?? []
        let existingIDs = Set(rows.map(\.id))
        rows.append(contentsOf: staleResetRows.filter { !existingIDs.contains($0.id) })
        merged.analytics = QuotaAnalytics(
            trend: merged.analytics?.trend ?? [],
            rows: rows,
            note: merged.analytics?.note
        )
        return merged
    }

    /// User-facing label for a normalized plan key. Claude's "Plus" plan has always
    /// displayed as "Pro" in this app's UI, so that one mapping is provider-specific.
    public static func planGroupDisplayLabel(
        provider: QuotaProvider,
        planKey: String,
        rawPlanType: String?
    ) -> String {
        // Claude has no "Pro 5x"/"Pro 20x" tiering — that naming is Codex-specific. Its
        // own "Pro" plan (and the older "Plus" label some cached data still carries)
        // must never fall through to the generic `pro`/`plus` cases below, which are
        // written for Codex's tiered plan names.
        if provider == .claude, planKey == "plus" || planKey == "pro" { return "Pro" }
        switch planKey {
        case "plus": return "Plus"
        case "business": return "Business"
        case "pro": return "Pro 20x"
        case "pro_lite": return "Pro 5x"
        case "team": return "Team"
        case "enterprise": return "Enterprise"
        case "free": return "Free"
        case "unknown": return "Unknown"
        default: return rawPlanType?.capitalized ?? planKey.capitalized
        }
    }

    /// Derives a single read-only summary `ProviderQuota` from several real accounts'
    /// readings — a **pure, on-the-fly** view, never persisted and never a replacement
    /// for any of the underlying accounts. Callers are expected to have already grouped
    /// `accounts` by source + provider + `normalizedPlanKey`; this function does not
    /// re-check that they share a plan.
    ///
    /// Forbidden accounts never contribute fabricated "healthy" numbers: they are
    /// excluded from the metric math entirely, and the result is itself forbidden (with
    /// no models) only when every input account is forbidden. `lastUpdated` is the
    /// earliest timestamp among the contributing accounts, so the summary never claims
    /// to be fresher than its stalest input — mirroring the app's existing "keep the
    /// last-known-good reading, never overstate it" refresh policy.
    public static func aggregate(_ accounts: [ProviderQuota], mode: ModelAggregationMode) -> ProviderQuota {
        let contributing = accounts.filter { !$0.isForbidden }
        guard !contributing.isEmpty else {
            return ProviderQuota(
                models: [],
                lastUpdated: accounts.map(\.lastUpdated).max() ?? Date(),
                isForbidden: true,
                planType: accounts.first(where: { $0.planType != nil })?.planType
            )
        }

        var orderedNames: [String] = []
        var percentagesByName: [String: [Double]] = [:]
        var resetTimeByName: [String: String] = [:]
        for account in contributing {
            for metric in account.models {
                if percentagesByName[metric.name] == nil {
                    orderedNames.append(metric.name)
                    resetTimeByName[metric.name] = metric.resetTime
                }
                percentagesByName[metric.name, default: []].append(metric.percentage)
            }
        }

        let models = orderedNames.map { name in
            QuotaMetric(
                name: name,
                percentage: aggregatePercentages(percentagesByName[name] ?? [], mode: mode),
                resetTime: resetTimeByName[name] ?? ""
            )
        }

        return ProviderQuota(
            models: models,
            lastUpdated: contributing.map(\.lastUpdated).min() ?? Date(),
            isForbidden: false,
            planType: contributing.first(where: { $0.planType != nil })?.planType
        )
    }

    /// Reconciles possibly-differing channel-weight readings from the several
    /// accounts of one remote pool (each account's own quota-cache response can carry
    /// its own `AccountRoutingWeight.channelWeight` reading, taken at its own request
    /// time) into the single value shown on that pool's subheader. The reading with
    /// the latest `updatedAt` wins; when the latest `updatedAt` is shared by readings
    /// that disagree on the value, the conflict is unresolvable and this hides the
    /// channel weight entirely rather than guessing which one is current.
    public static func reconciledChannelWeight(from weights: [AccountRoutingWeight]) -> Int? {
        guard let latest = weights.map(\.updatedAt).max() else { return nil }
        let atLatest = weights.filter { $0.updatedAt == latest }
        let values = Set(atLatest.map(\.channelWeight))
        return values.count == 1 ? values.first : nil
    }

    private static func aggregatePercentages(_ percentages: [Double], mode: ModelAggregationMode) -> Double {
        let valid = percentages.filter { $0 >= 0 }
        guard !valid.isEmpty else { return -1 }
        switch mode {
        case .lowest: return valid.min() ?? -1
        case .average: return valid.reduce(0, +) / Double(valid.count)
        }
    }
}
