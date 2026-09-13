import Foundation

/// One recovery-time value as the Management API may report it: either an absolute
/// timestamp string (ISO-8601, matching every other date field on `ManagedAuthFile`) or
/// a bare number of seconds (matching the HTTP `Retry-After: <seconds>` convention some
/// `retry_after`-style fields use). Never assumes which — both are decoded and resolved
/// explicitly, never guessed from context.
public enum AuthFileRecoveryTimeValue: Codable, Equatable, Sendable {
    case absolute(String)
    case secondsFromNow(Double)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let seconds = try? container.decode(Double.self) {
            self = .secondsFromNow(seconds)
            return
        }
        self = .absolute(try container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .absolute(let value): try container.encode(value)
        case .secondsFromNow(let value): try container.encode(value)
        }
    }

    /// A bare number this large could never plausibly be a "seconds from now" retry
    /// delay (30 days) — at that magnitude it is far more likely a misclassified Unix
    /// epoch timestamp (which `AuthFileRecoveryTimeValue` never attempts to detect, since
    /// doing so would itself be a guess). Treating every bare number as a short duration
    /// regardless of size is exactly the heuristic this bound exists to avoid: past it,
    /// the field is unsupported/ambiguous data, so `resolvedDate` returns `nil` rather
    /// than resolving to a wildly wrong date.
    private static let maxPlausibleRetrySeconds: Double = 30 * 24 * 60 * 60

    /// Resolves this value to a concrete `Date`. `now` is only consulted for
    /// `.secondsFromNow`, where it anchors the duration to when the listing carrying
    /// this value was fetched. `nil` when an `.absolute` string fails to parse, a
    /// `.secondsFromNow` value is zero/negative, or it exceeds `maxPlausibleRetrySeconds`
    /// — never a fabricated date and never a guessed epoch/duration reinterpretation.
    /// Only meaningful for a field whose API contract is actually a relative duration
    /// (`retry_after`) — see `resolvedAbsoluteDate()` for fields that are timestamps.
    func resolvedDate(fetchedAt now: Date) -> Date? {
        switch self {
        case .absolute(let value):
            return QuotaDateFormatting.parseISO8601(value)
        case .secondsFromNow(let seconds):
            guard seconds > 0, seconds <= Self.maxPlausibleRetrySeconds else { return nil }
            return now.addingTimeInterval(seconds)
        }
    }

    /// Resolves this value only when it is an absolute timestamp. For fields whose
    /// documented contract is a point-in-time (`unfreeze_at`, `frozen_until`,
    /// `cooldown_until`, `recovery_at`, `next_retry_after`), a bare number is never a
    /// legitimate value for that field — there is no size threshold that reliably tells a
    /// relative-seconds value apart from a timestamp expressed as a number, so guessing
    /// via a magnitude cutoff would just trade one wrong interpretation for another.
    /// Unsupported/ambiguous data resolves to `nil` instead of a fabricated date.
    func resolvedAbsoluteDate() -> Date? {
        switch self {
        case .absolute(let value):
            return QuotaDateFormatting.parseISO8601(value)
        case .secondsFromNow:
            return nil
        }
    }
}

public struct ManagedAuthFile: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let provider: String
    public let label: String?
    public let status: String
    public let statusMessage: String?
    public let disabled: Bool
    public let unavailable: Bool
    public let runtimeOnly: Bool?
    public let source: String?
    public let path: String?
    public let email: String?
    public let accountType: String?
    public let account: String?
    public let authIndex: String?
    public let createdAt: String?
    public let updatedAt: String?
    public let lastRefresh: String?
    /// Real freeze/cooldown recovery signals the Management API may report for this
    /// specific account. None of these are guaranteed to exist on any given server
    /// build — `recoveryDate(fetchedAt:)` resolves whichever, if any, is actually
    /// present, and every one of them is optional so decoding an older/plainer response
    /// (none of these fields present) never fails.
    public let nextRetryAfter: AuthFileRecoveryTimeValue?
    public let retryAfter: AuthFileRecoveryTimeValue?
    public let unfreezeAt: AuthFileRecoveryTimeValue?
    public let frozenUntil: AuthFileRecoveryTimeValue?
    public let cooldownUntil: AuthFileRecoveryTimeValue?
    public let recoveryAt: AuthFileRecoveryTimeValue?

    public init(
        id: String,
        name: String,
        provider: String,
        label: String? = nil,
        status: String,
        statusMessage: String? = nil,
        disabled: Bool,
        unavailable: Bool,
        runtimeOnly: Bool? = nil,
        source: String? = nil,
        path: String? = nil,
        email: String? = nil,
        accountType: String? = nil,
        account: String? = nil,
        authIndex: String? = nil,
        createdAt: String? = nil,
        updatedAt: String? = nil,
        lastRefresh: String? = nil,
        nextRetryAfter: AuthFileRecoveryTimeValue? = nil,
        retryAfter: AuthFileRecoveryTimeValue? = nil,
        unfreezeAt: AuthFileRecoveryTimeValue? = nil,
        frozenUntil: AuthFileRecoveryTimeValue? = nil,
        cooldownUntil: AuthFileRecoveryTimeValue? = nil,
        recoveryAt: AuthFileRecoveryTimeValue? = nil
    ) {
        self.id = id
        self.name = name
        self.provider = provider
        self.label = label
        self.status = status
        self.statusMessage = statusMessage
        self.disabled = disabled
        self.unavailable = unavailable
        self.runtimeOnly = runtimeOnly
        self.source = source
        self.path = path
        self.email = email
        self.accountType = accountType
        self.account = account
        self.authIndex = authIndex
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastRefresh = lastRefresh
        self.nextRetryAfter = nextRetryAfter
        self.retryAfter = retryAfter
        self.unfreezeAt = unfreezeAt
        self.frozenUntil = frozenUntil
        self.cooldownUntil = cooldownUntil
        self.recoveryAt = recoveryAt
    }

    enum CodingKeys: String, CodingKey {
        case id, name, provider, label, status, disabled, unavailable, source, path, email, account
        case authIndex = "auth_index"
        case statusMessage = "status_message"
        case runtimeOnly = "runtime_only"
        case accountType = "account_type"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case lastRefresh = "last_refresh"
        case nextRetryAfter = "next_retry_after"
        case retryAfter = "retry_after"
        case unfreezeAt = "unfreeze_at"
        case frozenUntil = "frozen_until"
        case cooldownUntil = "cooldown_until"
        case recoveryAt = "recovery_at"
    }

    /// Real freeze/cooldown recovery time for this account, resolved from whichever
    /// explicit, structured signal the Management API actually provided — never a guess
    /// and never derived from any quota model's own reset time (a distinct, unrelated
    /// concept). Checked in this order: the explicit absolute/duration fields above,
    /// first one present wins. Deliberately never falls back to free-text inference from
    /// `statusMessage` (a server can freely change that copy, or state when the freeze
    /// *started* rather than when it ends) and never treats `updatedAt`/`lastRefresh` —
    /// which describe when the listing itself was last touched, not this account's
    /// unfreeze time — as a recovery signal. `nil` when none of these structured fields
    /// resolve to a concrete date, rather than a guessed one.
    ///
    /// `unfreezeAt`, `frozenUntil`, `cooldownUntil`, `recoveryAt`, and `nextRetryAfter`
    /// are all documented as absolute timestamps, so only an `.absolute` value resolves
    /// for them — a bare number under any of those keys is unsupported/ambiguous data,
    /// not a relative duration to guess at. `retryAfter` is the one field whose contract
    /// is a relative `Retry-After`-style duration, so it is the only one that accepts a
    /// `.secondsFromNow` value.
    public func recoveryDate(fetchedAt now: Date) -> Date? {
        let absoluteOnlyCandidates = [unfreezeAt, frozenUntil, cooldownUntil, recoveryAt, nextRetryAfter]
        for candidate in absoluteOnlyCandidates {
            if let date = candidate?.resolvedAbsoluteDate() {
                return date
            }
        }
        return retryAfter?.resolvedDate(fetchedAt: now)
    }

    public var providerID: QuotaProvider? {
        if provider == "copilot" { return .copilot }
        if provider == "xai" { return .grok }
        return QuotaProvider(rawValue: provider)
    }

    public var quotaLookupKey: String {
        if providerID == .codex {
            return name.removingProviderFilename(prefix: "codex-")
        }
        if providerID == .copilot {
            if let account = account?.nilIfBlank {
                return account
            }
            let filenameKey = name.removingProviderFilename(prefix: "github-copilot-")
            if !filenameKey.isEmpty {
                return filenameKey
            }
        }
        if let email = email?.nilIfBlank { return email }
        if let account = account?.nilIfBlank { return account }
        return name.removingProviderFilename(prefix: "github-copilot-")
    }

    public var menuBarAccountKey: String {
        let key = quotaLookupKey
        return key.isEmpty ? name : key
    }

    public var isReady: Bool {
        (status == "ready" || status == "active") && !disabled && !unavailable
    }

    /// Whether this auth file counts as an account that **exists** for quota tracking.
    /// Deliberately independent of `status`/`unavailable`: those describe a transient
    /// server-side condition (a cooldown after a rate limit, a failed token refresh),
    /// never whether the account is there — and conflating the two is what used to make
    /// a merely-frozen remote account vanish from the menu bar entirely instead of
    /// keeping its last-known-good reading. Only an explicitly disabled file is
    /// excluded: that one is a deliberate user action on the server, so it keeps its
    /// existing "not tracked at all" behavior.
    public var isQuotaTrackable: Bool { !disabled }

    /// Exists (see `isQuotaTrackable`) but the server currently reports it as not
    /// usable — cooling after a rate limit, an errored refresh, or flagged unavailable.
    /// Purely a display/bookkeeping state: an account in it is still listed, still
    /// keeps whatever quota reading it already had, and clears the state by itself as
    /// soon as the server reports it ready again.
    public var isTemporarilyUnavailable: Bool { isQuotaTrackable && !isReady }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(disabled)
        hasher.combine(status)
    }

    public static func == (lhs: ManagedAuthFile, rhs: ManagedAuthFile) -> Bool {
        lhs.id == rhs.id && lhs.disabled == rhs.disabled && lhs.status == rhs.status
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func removingProviderFilename(prefix: String) -> String {
        var key = self
        if key.hasPrefix(prefix) { key.removeFirst(prefix.count) }
        if key.hasSuffix(".json") { key.removeLast(".json".count) }
        return key
    }
}

public struct ManagedModelInfo: Codable, Equatable, Sendable {
    public let id: String
    public let ownedBy: String?
    public let type: String?

    public init(id: String, ownedBy: String? = nil, type: String? = nil) {
        self.id = id
        self.ownedBy = ownedBy
        self.type = type
    }

    enum CodingKeys: String, CodingKey {
        case id, type
        case ownedBy = "owned_by"
    }
}

public struct ProxyUsageStats: Codable, Equatable, Sendable {
    public let usage: ProxyUsageData?
    public let failedRequests: Int?

    enum CodingKeys: String, CodingKey {
        case usage
        case failedRequests = "failed_requests"
    }
}

public struct ProxyUsageData: Codable, Equatable, Sendable {
    public let totalRequests: Int?
    public let successCount: Int?
    public let failureCount: Int?
    public let totalTokens: Int?
    public let inputTokens: Int?
    public let outputTokens: Int?

    public var successRate: Double {
        guard let totalRequests, totalRequests > 0, let successCount else { return 0 }
        return Double(successCount) / Double(totalRequests) * 100
    }

    enum CodingKeys: String, CodingKey {
        case totalRequests = "total_requests"
        case successCount = "success_count"
        case failureCount = "failure_count"
        case totalTokens = "total_tokens"
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
    }
}

public struct ProxyManagementConfiguration: Codable, Equatable, Sendable {
    public let debug: Bool?
    public let proxyURL: String?
    public let routingStrategy: String?
    public let requestRetry: Int?
    public let maxRetryInterval: Int?
    public let loggingToFile: Bool?
    public let requestLog: Bool?
    public let quotaExceeded: ProxyQuotaExceededConfiguration?

    enum CodingKeys: String, CodingKey {
        case debug
        case proxyURL = "proxy-url"
        case routingStrategy = "routing-strategy"
        case requestRetry = "request-retry"
        case maxRetryInterval = "max-retry-interval"
        case loggingToFile = "logging-to-file"
        case requestLog = "request-log"
        case quotaExceeded = "quota-exceeded"
    }
}

public struct ProxyQuotaExceededConfiguration: Codable, Equatable, Sendable {
    public let switchProject: Bool?
    public let switchPreviewModel: Bool?

    enum CodingKeys: String, CodingKey {
        case switchProject = "switch-project"
        case switchPreviewModel = "switch-preview-model"
    }
}

public struct ProxyAPICall: Codable, Equatable, Sendable {
    public let authIndex: String?
    public let method: String
    public let url: String
    public let header: [String: String]?
    public let data: String?

    public init(authIndex: String?, method: String, url: String, header: [String: String]?, data: String?) {
        self.authIndex = authIndex
        self.method = method
        self.url = url
        self.header = header
        self.data = data
    }

    enum CodingKeys: String, CodingKey {
        case method, url, header, data
        case authIndex = "auth_index"
    }
}

public struct ProxyAPICallResult: Codable, Equatable, Sendable {
    public let statusCode: Int
    public let header: [String: [String]]?
    public let body: String?

    enum CodingKeys: String, CodingKey {
        case header, body
        case statusCode = "status_code"
    }
}

public struct ProxyOAuthStart: Codable, Equatable, Sendable {
    public let status: String
    public let url: String?
    public let state: String?
    public let error: String?
}

public struct ProxyOAuthStatus: Codable, Equatable, Sendable {
    public let status: String
    public let error: String?
}

public enum ProxyManagementOAuthProvider: String, Sendable {
    case claude
    case codex
    case qwen
    case iflow
    case antigravity
}

public struct ProxyLatestVersion: Codable, Equatable, Sendable {
    public let latestVersion: String

    enum CodingKeys: String, CodingKey {
        case latestVersion = "latest-version"
    }
}
