import Foundation
import QuotioApplication
import QuotioDomain

/// Fetches pooled quota data from a remote CLIProxyAPI's Management API. This talks
/// directly to the remote server's `/v0/management` endpoints (never through
/// ProxyBridge, which is local-only) — the same `ProxyManagementAPI` abstraction the
/// app already uses for the local proxy, just pointed at a different base URL.
///
/// The remote CLIProxyAPI holds the real provider tokens; requests use the
/// `$TOKEN$` placeholder documented by its `/api-call` pass-through, so provider
/// credentials never leave that server.
public struct RemoteManagementQuotaFetcher: RemoteQuotaSourceFetching {
    public static let supportedProviders: Set<QuotaProvider> = [.claude, .codex, .grok]

    private let apiFactory: any ProxyManagementAPIFactory
    private let now: @Sendable () -> Date
    private let cacheClient: QuotaCacheClient

    public init(
        apiFactory: any ProxyManagementAPIFactory = LiveProxyManagementAPIFactory(),
        now: @escaping @Sendable () -> Date = Date.init,
        cacheClient: QuotaCacheClient = QuotaCacheClient()
    ) {
        self.apiFactory = apiFactory
        self.now = now
        self.cacheClient = cacheClient
    }

    public func isResponding(_ source: RemoteQuotaSourceConfig, managementKey: String) async -> Bool {
        let api = makeAPI(source, managementKey: managementKey)
        defer { Task { await api.invalidate() } }
        return await api.isResponding()
    }

    public func fetchPool(
        _ source: RemoteQuotaSourceConfig,
        managementKey: String
    ) async throws -> RemoteQuotaPoolFetchResult {
        let api = makeAPI(source, managementKey: managementKey)
        defer { Task { await api.invalidate() } }

        let files: [ManagedAuthFile]
        do {
            files = try await api.fetchAuthFiles()
        } catch ProxyManagementFailure.httpError(401) {
            throw RemoteQuotaFetchError.unauthorized
        } catch ProxyManagementFailure.httpError(403) {
            throw RemoteQuotaFetchError.unauthorized
        } catch ProxyManagementFailure.httpError(404) {
            throw RemoteQuotaFetchError.endpointNotFound
        } catch is DecodingError {
            throw RemoteQuotaFetchError.invalidResponse
        } catch ProxyManagementFailure.invalidResponse {
            throw RemoteQuotaFetchError.invalidResponse
        } catch ProxyManagementFailure.invalidURL {
            throw RemoteQuotaFetchError.connectivityUnavailable
        } catch ProxyManagementFailure.connectionError(_) {
            throw RemoteQuotaFetchError.connectivityUnavailable
        } catch {
            throw RemoteQuotaFetchError.authFilesUnavailable
        }

        // An account carrying the server's aggregated `unavailable` flag is still an
        // account: `isQuotaTrackable` keeps it here so it stays in `knownAccountKeys` and
        // survives the coordinator's prune, instead of being mistaken for one that was
        // deleted from the server. A status-only model error remains usable here; only an
        // explicitly disabled file is left out.
        let candidates = files.filter { file in
            file.isQuotaTrackable && file.providerID.map(Self.supportedProviders.contains) == true
        }

        // The listing succeeded, so it is authoritative for **every** provider this
        // fetcher supports — seeding each with an empty set (rather than only recording
        // providers that happen to have a candidate) is what tells the coordinator that
        // a provider whose last account was deleted now genuinely has none, instead of
        // leaving its stale reading behind forever. The frozen-account listing is seeded
        // the same way, for the same reason in reverse: an empty set is what clears the
        // state off every account of a provider that recovered.
        var knownAccountKeys = Dictionary(
            uniqueKeysWithValues: Self.supportedProviders.map { ($0, Set<String>()) }
        )
        var temporarilyUnavailableAccountKeys = knownAccountKeys
        guard !candidates.isEmpty else {
            // An empty listing is a real, authoritative answer — never a fetch error —
            // so it must still be allowed to prune. `outcome` keeps the round marked
            // as a failure so it can't be mistaken for a healthy refresh.
            return RemoteQuotaPoolFetchResult(
                outcome: .noAccountsListed,
                knownAccountKeys: knownAccountKeys,
                temporarilyUnavailableAccountKeys: temporarilyUnavailableAccountKeys
            )
        }

        // Each trackable, supported auth file is one real remote account — its quota is
        // kept under its own raw key (never merged/aggregated with any other account's
        // reading), so the same identity survives from fetch through display.
        var byProviderAndAccount: [QuotaProvider: [String: ProviderQuota]] = [:]
        var placeholderQuotas: [QuotaProvider: [String: ProviderQuota]] = [:]
        var availabilityRecoveryDates: [QuotaProvider: [String: Date]] = [:]
        var accountIssues: [QuotaProvider: [String: RemoteQuotaAccountIssue]] = [:]
        var accountIssueObservedKeys: [QuotaProvider: Set<String>] = [:]
        // Counted over the accounts this round could reasonably expect a reading from,
        // which excludes the frozen ones: a request that fails because the server already
        // said the account is cooling is not evidence that the *source* is unhealthy, and
        // counting it as one would drive the coordinator's consecutive-failure threshold
        // and hide the whole source — the same disappearance, one level up.
        var expectedCount = 0
        var succeededCount = 0
        for file in candidates {
            guard let provider = file.providerID else { continue }
            let accountKey = file.authIndex ?? file.name
            knownAccountKeys[provider, default: []].insert(accountKey)
            let isFrozen = file.isTemporarilyUnavailable
            if isFrozen {
                temporarilyUnavailableAccountKeys[provider, default: []].insert(accountKey)
            }
            // Still attempted for a frozen account: the management API may well answer
            // (a cooldown is the remote server's own routing state, not a hard block), and
            // a real reading is always better than a placeholder.
            let attempt = await fetchQuota(
                provider: provider, file: file, source: source, managementKey: managementKey, api: api
            )
            let issue = attempt.remoteAccountIssue
            let isAuthInvalid = issue == .invalidOAuth
            if attempt.accountIssueWasObserved {
                accountIssueObservedKeys[provider, default: []].insert(accountKey)
                if let issue {
                    accountIssues[provider, default: [:]][accountKey] = issue
                }
            }
            // A confirmed invalid credential is an account-level quarantine, not evidence
            // that the whole source failed. It therefore releases its balancing weight
            // without driving the source-wide consecutive-failure hide threshold.
            if !isFrozen && !isAuthInvalid {
                expectedCount += 1
            }
            // The auth-file listing's own explicit fields are authoritative when present;
            // the quota request's own (429-only, estimated) `Retry-After` header is only a
            // fallback for a server build that exposes no such field on the listing at
            // all. Only resolved for a frozen account — a ready one has nothing to recover
            // from.
            let recoveryDate = isFrozen
                ? (file.recoveryDate(fetchedAt: now()) ?? attempt.headerRecoveryDate)
                : nil
            // Recorded for every frozen account this round, whether or not one resolved —
            // an absent entry is this round's authoritative "unknown", which is what lets
            // the coordinator clear a stale recovery time from an earlier round instead of
            // only ever being able to set one.
            if isFrozen {
                availabilityRecoveryDates[provider, default: [:]][accountKey] = recoveryDate
            }
            guard var quota = attempt.quota else {
                if isFrozen || isAuthInvalid {
                    // Identity only — no models, so nothing here can read as a real
                    // measurement. The coordinator drops it in favour of any reading it
                    // already holds.
                    placeholderQuotas[provider, default: [:]][accountKey] = ProviderQuota(
                        lastUpdated: now(),
                        accountDisplayName: file.email?.nilIfBlank ?? file.name,
                        remoteAccountIssue: issue,
                        isTemporarilyUnavailable: isFrozen ? true : nil,
                        availabilityRecoveryDate: recoveryDate
                    )
                }
                continue
            }
            if !isFrozen && !isAuthInvalid { succeededCount += 1 }
            quota.remoteAccountIssue = issue
            if quota.accountDisplayName == nil {
                quota.accountDisplayName = file.email?.nilIfBlank ?? file.name
            }
            if isFrozen {
                quota.availabilityRecoveryDate = recoveryDate
            }
            byProviderAndAccount[provider, default: [:]][accountKey] = quota
        }

        // Even when no quota request survived, the listing above still reported exactly
        // which accounts exist — that list stays authoritative and is returned rather
        // than thrown away, so a round where every request fails can still prune
        // accounts that disappeared from the remote server.
        let outcome: RemoteQuotaPoolFetchResult.QuotaOutcome
        if expectedCount == 0 {
            // Every listed account is frozen, so nothing was expected to report and
            // nothing failed. The listing itself succeeded and the accounts are all
            // still there — a healthy round, not a failing one.
            outcome = .complete
        } else if succeededCount == 0 {
            outcome = .allFailed
        } else if succeededCount < expectedCount {
            outcome = .partial
        } else {
            outcome = .complete
        }

        return RemoteQuotaPoolFetchResult(
            quotasByProviderAndAccount: byProviderAndAccount,
            outcome: outcome,
            knownAccountKeys: knownAccountKeys,
            temporarilyUnavailableAccountKeys: temporarilyUnavailableAccountKeys,
            placeholderQuotas: placeholderQuotas,
            availabilityRecoveryDates: availabilityRecoveryDates,
            accountIssues: accountIssues,
            accountIssueObservedKeys: accountIssueObservedKeys
        )
    }

    private static let grokAPIHeaders = [
        "Authorization": "Bearer $TOKEN$",
        "X-XAI-Token-Auth": "xai-grok-cli",
        "Accept": "application/json",
        "User-Agent": "Quotio",
    ]

    /// Fetches `GET /v1/settings` through the same `$TOKEN$` pass-through as billing
    /// and reads `subscription_tier_display` — mirroring `GrokQuotaFetcher`'s local
    /// path. Best-effort supplement: swallows every failure into `nil`, exactly like
    /// `fetchClaudeProfilePlan`, so a failed/unparsable settings response never blocks
    /// the billing quota that already succeeded.
    private func fetchGrokSettingsPlan(
        source: RemoteQuotaSourceConfig, managementKey: String, authIndex: String, api: any ProxyManagementAPI
    ) async -> String? {
        guard let call = await performQuotaCall(
            source: source, managementKey: managementKey, resource: "grok-settings", authIndex: authIndex,
            method: "GET", url: "https://cli-chat-proxy.grok.com/v1/settings", header: Self.grokAPIHeaders, api: api
        ), let result = call.result, let data = bodyData(result),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let value = (json["subscription_tier_display"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (value?.isEmpty ?? true) ? nil : value
    }

    private static let claudeAPIHeaders = [
        "Authorization": "Bearer $TOKEN$",
        "Accept": "application/json",
        "Content-Type": "application/json",
        "anthropic-beta": "oauth-2025-04-20",
        "User-Agent": "claude-code/2.1.69",
    ]

    /// Fetches `GET /api/oauth/profile` through the same `$TOKEN$` pass-through as the
    /// usage call and maps it via `ClaudeQuotaFetcher.mapProfilePlan`. Swallows every
    /// failure into `nil` — this is a best-effort supplement to a usage fetch that
    /// already succeeded, never a requirement for it.
    private func fetchClaudeProfilePlan(
        source: RemoteQuotaSourceConfig, managementKey: String, authIndex: String, api: any ProxyManagementAPI
    ) async -> String? {
        guard let call = await performQuotaCall(
            source: source, managementKey: managementKey, resource: "claude-profile", authIndex: authIndex,
            method: "GET", url: ClaudeQuotaFetcher.profileURL.absoluteString, header: Self.claudeAPIHeaders, api: api
        ), let result = call.result, let data = bodyData(result) else { return nil }
        return ClaudeQuotaFetcher.mapProfilePlan(data)
    }

    /// Fetches `GET wham/rate-limit-reset-credits` through the same `$TOKEN$`
    /// pass-through as the usage call — the remote CLIProxyAPI server substitutes the
    /// real access token server-side, so it never reaches Quotio, matching every other
    /// remote quota request. Best-effort supplement to a usage fetch that already
    /// succeeded: swallows every failure into `nil`, exactly like
    /// `fetchClaudeProfilePlan`, so a reset-credit fetch failure never discards the
    /// quota usage reading that already succeeded. This function has no memory of a
    /// previous round by itself, so a failure here means the `ProviderQuota` returned
    /// this round simply has no reset-credit data of its own — it is
    /// `RemoteQuotaSourceCoordinator.refresh` (via `QuotaPolicy.mergingCodexResetCredits`)
    /// that re-attaches the previous round's `codexResetCreditSummary`/analytics rows
    /// when merging, so the account doesn't visibly lose them for one failed round.
    private func fetchCodexResetCredits(
        source: RemoteQuotaSourceConfig,
        managementKey: String,
        authIndex: String,
        accountId: String?,
        api: any ProxyManagementAPI
    ) async -> (analytics: QuotaAnalytics, summary: CodexResetCreditSummary)? {
        guard let call = await performQuotaCall(
            source: source, managementKey: managementKey, resource: "codex-reset-credits", authIndex: authIndex,
            method: "GET", url: CodexResetCreditInventoryFetcher.inventoryURL.absoluteString,
            header: CodexResetCreditInventoryFetcher.headers(accessToken: "$TOKEN$", accountID: accountId), api: api
        ), let result = call.result, let fetchedAt = call.fetchedAt,
           let data = bodyData(result) else { return nil }
        return try? CodexResetCreditInventoryFetcher.parse(data, now: fetchedAt)
    }

    private func makeAPI(
        _ source: RemoteQuotaSourceConfig,
        managementKey: String
    ) -> any ProxyManagementAPI {
        apiFactory.makeManagementAPI(
            connection: ProxyManagementConnection(baseURL: source.managementBaseURL, authKey: managementKey)
        )
    }

    /// One provider-specific quota fetch attempt's outcome: the parsed quota when the
    /// upstream request produced one, plus any real cooldown/recovery time recovered
    /// from that same HTTP response's own `Retry-After`/`X-RateLimit-Reset` headers —
    /// carried separately so a failed request (e.g. the upstream returning 429) can
    /// still report a real recovery time even though it produced no quota.
    private struct QuotaFetchAttempt {
        var quota: ProviderQuota?
        var headerRecoveryDate: Date?
        var remoteAccountIssue: RemoteQuotaAccountIssue?
        var accountIssueWasObserved: Bool

        init(
            quota: ProviderQuota?,
            headerRecoveryDate: Date?,
            remoteAccountIssue: RemoteQuotaAccountIssue? = nil,
            accountIssueWasObserved: Bool = false
        ) {
            self.quota = quota
            self.headerRecoveryDate = headerRecoveryDate
            self.remoteAccountIssue = remoteAccountIssue
            self.accountIssueWasObserved = accountIssueWasObserved
        }
    }

    private struct QuotaCallResult {
        var result: ProxyAPICallResult?
        var fetchedAt: Date?
        var remoteAccountIssue: RemoteQuotaAccountIssue?
        var canClearAccountIssue: Bool
    }

    private func fetchQuota(
        provider: QuotaProvider,
        file: ManagedAuthFile,
        source: RemoteQuotaSourceConfig,
        managementKey: String,
        api: any ProxyManagementAPI
    ) async -> QuotaFetchAttempt {
        let authIndex = file.authIndex ?? file.name
        switch provider {
        case .claude:
            guard let call = await performQuotaCall(
                source: source, managementKey: managementKey, resource: "claude-usage", authIndex: authIndex,
                method: "GET", url: ClaudeQuotaFetcher.usageURL.absoluteString, header: Self.claudeAPIHeaders, api: api
            ) else {
                return QuotaFetchAttempt(quota: nil, headerRecoveryDate: nil)
            }
            guard let result = call.result, let fetchedAt = call.fetchedAt else {
                return QuotaFetchAttempt(
                    quota: nil, headerRecoveryDate: nil, remoteAccountIssue: call.remoteAccountIssue,
                    accountIssueWasObserved: call.remoteAccountIssue != nil
                )
            }
            let headerRecoveryDate = Self.recoveryDate(
                statusCode: result.statusCode, headers: result.header, fetchedAt: fetchedAt
            )
            guard let data = bodyData(result) else {
                return QuotaFetchAttempt(
                    quota: nil, headerRecoveryDate: headerRecoveryDate, remoteAccountIssue: call.remoteAccountIssue,
                    accountIssueWasObserved: call.remoteAccountIssue != nil
                )
            }
            var quota = ClaudeQuotaFetcher.mapUsage(data, planFallback: trustedPlanFallback(file), now: fetchedAt)
            // Claude only ever authenticates via OAuth, so the auth-file listing never
            // carries a trustworthy plan for it (see `trustedPlanFallback`) — the OAuth
            // profile endpoint is the only source that does. Only consulted when usage
            // came back with no trusted plan already, and a failure here (network error,
            // non-2xx, unparsable body) must never discard the usage quota that already
            // succeeded — it just leaves the plan unset, same as before this existed.
            if quota?.planType == nil {
                quota?.planType = await fetchClaudeProfilePlan(source: source, managementKey: managementKey, authIndex: authIndex, api: api)
            }
            return QuotaFetchAttempt(
                quota: quota, headerRecoveryDate: headerRecoveryDate, remoteAccountIssue: call.remoteAccountIssue,
                accountIssueWasObserved: call.remoteAccountIssue != nil || (quota != nil && call.canClearAccountIssue)
            )

        case .codex:
            var header = [
                "Authorization": "Bearer $TOKEN$",
                "Accept": "application/json",
            ]
            if let account = file.account, !account.isEmpty {
                header["ChatGPT-Account-Id"] = account
            }
            guard let call = await performQuotaCall(
                source: source, managementKey: managementKey, resource: "codex-usage", authIndex: authIndex,
                method: "GET", url: CodexQuotaFetcher.usageURL.absoluteString, header: header, api: api
            ) else {
                return QuotaFetchAttempt(quota: nil, headerRecoveryDate: nil)
            }
            guard let result = call.result, let fetchedAt = call.fetchedAt else {
                return QuotaFetchAttempt(
                    quota: nil, headerRecoveryDate: nil, remoteAccountIssue: call.remoteAccountIssue,
                    accountIssueWasObserved: call.remoteAccountIssue != nil
                )
            }
            let headerRecoveryDate = Self.recoveryDate(
                statusCode: result.statusCode, headers: result.header, fetchedAt: fetchedAt
            )
            guard let data = bodyData(result) else {
                return QuotaFetchAttempt(
                    quota: nil, headerRecoveryDate: headerRecoveryDate, remoteAccountIssue: call.remoteAccountIssue,
                    accountIssueWasObserved: call.remoteAccountIssue != nil
                )
            }
            guard var quota = try? CodexQuotaFetcher.mapUsage(
                data, planFallback: trustedPlanFallback(file), now: fetchedAt
            ) else {
                return QuotaFetchAttempt(
                    quota: nil, headerRecoveryDate: headerRecoveryDate, remoteAccountIssue: call.remoteAccountIssue,
                    accountIssueWasObserved: call.remoteAccountIssue != nil
                )
            }
            if let resetCredits = await fetchCodexResetCredits(
                source: source, managementKey: managementKey, authIndex: authIndex, accountId: file.account, api: api
            ) {
                quota.analytics = CodexResetCreditInventoryFetcher.merge(resetCredits.analytics, into: quota.analytics)
                quota.codexResetCreditSummary = resetCredits.summary
            }
            return QuotaFetchAttempt(
                quota: quota, headerRecoveryDate: headerRecoveryDate, remoteAccountIssue: call.remoteAccountIssue,
                accountIssueWasObserved: call.remoteAccountIssue != nil || call.canClearAccountIssue
            )

        case .grok:
            guard let call = await performQuotaCall(
                source: source, managementKey: managementKey, resource: "grok-usage", authIndex: authIndex,
                method: "GET", url: "https://cli-chat-proxy.grok.com/v1/billing?format=credits",
                header: Self.grokAPIHeaders, api: api
            ) else {
                return QuotaFetchAttempt(quota: nil, headerRecoveryDate: nil)
            }
            guard let result = call.result, let fetchedAt = call.fetchedAt else {
                return QuotaFetchAttempt(
                    quota: nil, headerRecoveryDate: nil, remoteAccountIssue: call.remoteAccountIssue,
                    accountIssueWasObserved: call.remoteAccountIssue != nil
                )
            }
            let headerRecoveryDate = Self.recoveryDate(
                statusCode: result.statusCode, headers: result.header, fetchedAt: fetchedAt
            )
            guard let data = bodyData(result) else {
                return QuotaFetchAttempt(
                    quota: nil, headerRecoveryDate: headerRecoveryDate, remoteAccountIssue: call.remoteAccountIssue,
                    accountIssueWasObserved: call.remoteAccountIssue != nil
                )
            }
            let displayName = file.email?.nilIfBlank ?? file.name
            // Prefer real metadata: the auth-file listing carries no per-account Grok
            // plan field, so `/v1/settings` (the same endpoint the local Grok fetcher
            // uses) is the only trustworthy signal, tried through the same `$TOKEN$`
            // pass-through as billing. This fetcher deliberately never guesses beyond
            // that — the narrowly source-scoped "Premium" legacy default (see
            // `QuotaPolicy.legacyGrokPlanDefault`) is applied downstream by
            // `RemoteQuotaSourceCoordinator`, which is the layer that actually owns a
            // source's stable `id` across renames; a fetch round here has no memory of
            // that identity beyond the single `RemoteQuotaSourceConfig` it was called
            // with.
            let plan = await fetchGrokSettingsPlan(source: source, managementKey: managementKey, authIndex: authIndex, api: api)
                ?? trustedPlanFallback(file)
            let quota = GrokQuotaFetcher.mapBilling(data, plan: plan, displayName: displayName, now: fetchedAt)
            return QuotaFetchAttempt(
                quota: quota, headerRecoveryDate: headerRecoveryDate, remoteAccountIssue: call.remoteAccountIssue,
                accountIssueWasObserved: call.remoteAccountIssue != nil || (quota != nil && call.canClearAccountIssue)
            )

        default:
            return QuotaFetchAttempt(quota: nil, headerRecoveryDate: nil)
        }
    }

    /// Executes one upstream-bound quota/profile/credits request, either directly
    /// through the remote CLIProxyAPI's `/api-call` pass-through (this fetcher's
    /// original behavior, and still the only path when `source.quotaCacheBaseURL` is
    /// unset) or, when a cache base URL is configured, through the local read-only
    /// quota-cache service instead — reusing the same management key already used for
    /// every other call on this source, so enabling the cache adds no new secret
    /// surface. A cache-enabled source never falls back to a direct request when the
    /// cache call fails — that failure is reported exactly like any other failed quota
    /// attempt (see call sites), never silently retried against the real upstream.
    /// `fetchedAt` on the result is the real time the value was last actually obtained
    /// from upstream: the cache's own `fetched_at` when read from cache, or the moment
    /// of this direct call otherwise — never the moment this function returns.
    private func performQuotaCall(
        source: RemoteQuotaSourceConfig,
        managementKey: String,
        resource: String,
        authIndex: String,
        method: String,
        url: String,
        header: [String: String],
        api: any ProxyManagementAPI
    ) async -> QuotaCallResult? {
        if let cacheBaseURL = source.quotaCacheBaseURL?.trimmingCharacters(in: .whitespacesAndNewlines),
            !cacheBaseURL.isEmpty {
            guard Self.cacheOriginIsTrusted(cacheBaseURL: cacheBaseURL, managementBaseURL: source.managementBaseURL)
            else { return nil }
            do {
                let response = try await cacheClient.fetch(
                    baseURL: cacheBaseURL, resource: resource, authIndex: authIndex, managementKey: managementKey
                )
                return QuotaCallResult(
                    result: response.result,
                    fetchedAt: Date(timeIntervalSince1970: response.fetchedAt),
                    remoteAccountIssue: response.failure?.remoteAccountIssue,
                    canClearAccountIssue: !response.stale && 200...299 ~= response.result.statusCode
                )
            } catch QuotaCacheError.authInvalid(_) {
                return QuotaCallResult(
                    result: nil, fetchedAt: nil, remoteAccountIssue: .invalidOAuth,
                    canClearAccountIssue: false
                )
            } catch {
                return nil
            }
        }
        guard let result = try? await api.apiCall(ProxyAPICall(
            authIndex: authIndex, method: method, url: url, header: header, data: nil
        )) else { return nil }
        return QuotaCallResult(
            result: result,
            fetchedAt: now(),
            remoteAccountIssue: Self.classifiedAccountIssue(statusCode: result.statusCode, body: result.body),
            canClearAccountIssue: 200...299 ~= result.statusCode
        )
    }

    private static func classifiedAccountIssue(statusCode: Int, body: String?) -> RemoteQuotaAccountIssue? {
        if statusCode == 401 { return .invalidOAuth }
        guard statusCode == 403 else { return nil }
        let lowered = body?.lowercased() ?? ""
        return lowered.contains("invalidated oauth token")
            || lowered.contains("invalid oauth token")
            || lowered.contains("oauth token has been invalidated")
            ? .invalidOAuth
            : nil
    }

    /// Binds the configured quota-cache base URL to this source's own management
    /// origin before the management key is ever sent to it, so a misconfigured (or
    /// malicious) `quotaCacheBaseURL` can never siphon that secret to an unrelated
    /// domain. A loopback `http://127.0.0.1:...` cache is trusted unconditionally —
    /// the documented same-host deployment (scripts/quota-cache/README.md) where the
    /// cache runs on a different local port than the remote management API, so it
    /// never leaves the machine regardless of port. Any other cache must be `https`
    /// on the exact same host and port as `managementBaseURL` — the documented
    /// reverse-proxy-on-the-existing-domain deployment; a cache on a different host,
    /// even over `https`, is never trusted.
    private static func cacheOriginIsTrusted(cacheBaseURL: String, managementBaseURL: String) -> Bool {
        guard let cacheComponents = URLComponents(string: cacheBaseURL),
            let cacheScheme = cacheComponents.scheme?.lowercased(),
            let cacheHost = cacheComponents.host, !cacheHost.isEmpty
        else { return false }
        if cacheScheme == "http" {
            return QuotaCacheClient.isLoopbackHost(cacheHost)
        }
        guard cacheScheme == "https",
            let sourceComponents = URLComponents(string: managementBaseURL),
            sourceComponents.scheme?.lowercased() == "https",
            let sourceHost = sourceComponents.host, !sourceHost.isEmpty
        else { return false }
        let cachePort = cacheComponents.port ?? 443
        let sourcePort = sourceComponents.port ?? 443
        return cacheHost.lowercased() == sourceHost.lowercased() && cachePort == sourcePort
    }

    /// Extracts an **estimated** retry time from an explicit 429 (rate-limited) quota
    /// HTTP response's own `Retry-After` header (RFC 7231: either delta-seconds or an
    /// HTTP-date, relative to when this response was received) — the header CLIProxyAPI's
    /// `/api-call` passes straight through from the upstream provider in
    /// `ProxyAPICallResult.header`. Header name lookup is case-insensitive, since HTTP
    /// header casing is not guaranteed to survive the pass-through.
    ///
    /// Deliberately gated on `statusCode == 429`: `Retry-After` on any other response
    /// (including a normal 2xx success) says nothing about a freeze/cooldown. Likewise
    /// deliberately never falls back to `X-RateLimit-Reset` — on a successful response
    /// that header names the *next quota window*, not a freeze/cooldown recovery (the
    /// same distinction `ProviderQuota.availabilityRecoveryDate`'s own doc comment
    /// draws against `QuotaMetric.resetTime`), and even on a 429 it is not a documented
    /// unfreeze signal the way `Retry-After` is. This is only ever a best-effort
    /// **estimate**: the upstream provider's own `Retry-After` is not a guarantee that
    /// the account is actually usable again once it elapses — the auth-file listing's own
    /// structured fields (see `ManagedAuthFile.recoveryDate(fetchedAt:)`), tried first by
    /// the caller, are the more authoritative signal when present. `nil` when the
    /// response isn't a 429, or the header is absent/unparseable — never a fabricated
    /// fallback.
    private static func recoveryDate(statusCode: Int, headers: [String: [String]]?, fetchedAt now: Date) -> Date? {
        guard statusCode == 429, let headers else { return nil }
        func firstValue(_ name: String) -> String? {
            for (key, values) in headers where key.caseInsensitiveCompare(name) == .orderedSame {
                let value = values.first?.trimmingCharacters(in: .whitespaces)
                return (value?.isEmpty ?? true) ? nil : value
            }
            return nil
        }
        guard let retryAfter = firstValue("Retry-After") else { return nil }
        if let seconds = Double(retryAfter), seconds > 0 {
            return now.addingTimeInterval(seconds)
        }
        if let httpDate = httpDateFormatter.date(from: retryAfter) {
            return httpDate
        }
        return nil
    }

    /// RFC 7231 `HTTP-date` format (e.g. `Wed, 21 Oct 2026 07:28:00 GMT`) — the
    /// alternate, non-numeric form `Retry-After` may use.
    private static let httpDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter
    }()

    /// Auth-mechanism labels the Management API's `account_type` field can carry (e.g.
    /// Claude only ever authenticates via OAuth, so its `account_type` is always
    /// `"oauth"`) — never a subscription/plan name. The auth-file listing this fetcher
    /// reads from has no separate plan/tier field at all, so `account_type` was
    /// previously passed straight through as the quota's plan fallback, which showed a
    /// literal "oauth" tier badge instead of the account's real plan (or none at all).
    /// Filtering out the known auth-mechanism values here — rather than substituting a
    /// guessed plan name — means an account with no real plan data shows no tier badge
    /// instead of a misleading one.
    private static let authMechanismValues: Set<String> = ["oauth", "api_key", "apikey", "api-key"]

    private func trustedPlanFallback(_ file: ManagedAuthFile) -> String? {
        guard let accountType = file.accountType?.nilIfBlank,
              !Self.authMechanismValues.contains(accountType.lowercased()) else {
            return nil
        }
        return accountType
    }

    private func bodyData(_ result: ProxyAPICallResult) -> Data? {
        guard 200...299 ~= result.statusCode, let body = result.body else { return nil }
        return body.data(using: .utf8)
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
