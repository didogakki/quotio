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

    public init(
        apiFactory: any ProxyManagementAPIFactory = LiveProxyManagementAPIFactory(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.apiFactory = apiFactory
        self.now = now
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

        let candidates = files.filter { file in
            file.isReady && file.providerID.map(Self.supportedProviders.contains) == true
        }

        // The listing succeeded, so it is authoritative for **every** provider this
        // fetcher supports — seeding each with an empty set (rather than only recording
        // providers that happen to have a candidate) is what tells the coordinator that
        // a provider whose last account was deleted now genuinely has none, instead of
        // leaving its stale reading behind forever.
        var knownAccountKeys = Dictionary(
            uniqueKeysWithValues: Self.supportedProviders.map { ($0, Set<String>()) }
        )
        guard !candidates.isEmpty else {
            // An empty listing is a real, authoritative answer — never a fetch error —
            // so it must still be allowed to prune. `outcome` keeps the round marked
            // as a failure so it can't be mistaken for a healthy refresh.
            return RemoteQuotaPoolFetchResult(
                outcome: .noAccountsListed,
                knownAccountKeys: knownAccountKeys
            )
        }

        // Each ready, supported auth file is one real remote account — its quota is
        // kept under its own raw key (never merged/aggregated with any other account's
        // reading), so the same identity survives from fetch through display.
        var byProviderAndAccount: [QuotaProvider: [String: ProviderQuota]] = [:]
        var succeededCount = 0
        for file in candidates {
            guard let provider = file.providerID else { continue }
            let accountKey = file.authIndex ?? file.name
            knownAccountKeys[provider, default: []].insert(accountKey)
            guard var quota = try? await fetchQuota(provider: provider, file: file, source: source, api: api) else {
                continue
            }
            succeededCount += 1
            if quota.accountDisplayName == nil {
                quota.accountDisplayName = file.email?.nilIfBlank ?? file.name
            }
            byProviderAndAccount[provider, default: [:]][accountKey] = quota
        }

        // Even when no quota request survived, the listing above still reported exactly
        // which accounts exist — that list stays authoritative and is returned rather
        // than thrown away, so a round where every request fails can still prune
        // accounts that disappeared from the remote server.
        let outcome: RemoteQuotaPoolFetchResult.QuotaOutcome
        if succeededCount == 0 {
            outcome = .allFailed
        } else if succeededCount < candidates.count {
            outcome = .partial
        } else {
            outcome = .complete
        }

        return RemoteQuotaPoolFetchResult(
            quotasByProviderAndAccount: byProviderAndAccount,
            outcome: outcome,
            knownAccountKeys: knownAccountKeys
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
    private func fetchGrokSettingsPlan(authIndex: String, api: any ProxyManagementAPI) async -> String? {
        guard let result = try? await api.apiCall(ProxyAPICall(
            authIndex: authIndex,
            method: "GET",
            url: "https://cli-chat-proxy.grok.com/v1/settings",
            header: Self.grokAPIHeaders,
            data: nil
        )), let data = bodyData(result),
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
    private func fetchClaudeProfilePlan(authIndex: String, api: any ProxyManagementAPI) async -> String? {
        guard let result = try? await api.apiCall(ProxyAPICall(
            authIndex: authIndex,
            method: "GET",
            url: ClaudeQuotaFetcher.profileURL.absoluteString,
            header: Self.claudeAPIHeaders,
            data: nil
        )), let data = bodyData(result) else { return nil }
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
        authIndex: String,
        accountId: String?,
        api: any ProxyManagementAPI
    ) async -> (analytics: QuotaAnalytics, summary: CodexResetCreditSummary)? {
        guard let result = try? await api.apiCall(ProxyAPICall(
            authIndex: authIndex,
            method: "GET",
            url: CodexResetCreditInventoryFetcher.inventoryURL.absoluteString,
            header: CodexResetCreditInventoryFetcher.headers(accessToken: "$TOKEN$", accountID: accountId),
            data: nil
        )), let data = bodyData(result) else { return nil }
        return try? CodexResetCreditInventoryFetcher.parse(data, now: now())
    }

    private func makeAPI(
        _ source: RemoteQuotaSourceConfig,
        managementKey: String
    ) -> any ProxyManagementAPI {
        apiFactory.makeManagementAPI(
            connection: ProxyManagementConnection(baseURL: source.managementBaseURL, authKey: managementKey)
        )
    }

    private func fetchQuota(
        provider: QuotaProvider,
        file: ManagedAuthFile,
        source: RemoteQuotaSourceConfig,
        api: any ProxyManagementAPI
    ) async throws -> ProviderQuota? {
        let authIndex = file.authIndex ?? file.name
        switch provider {
        case .claude:
            let result = try await api.apiCall(ProxyAPICall(
                authIndex: authIndex,
                method: "GET",
                url: ClaudeQuotaFetcher.usageURL.absoluteString,
                header: Self.claudeAPIHeaders,
                data: nil
            ))
            guard let data = bodyData(result) else { return nil }
            var quota = ClaudeQuotaFetcher.mapUsage(data, planFallback: trustedPlanFallback(file), now: now())
            // Claude only ever authenticates via OAuth, so the auth-file listing never
            // carries a trustworthy plan for it (see `trustedPlanFallback`) — the OAuth
            // profile endpoint is the only source that does. Only consulted when usage
            // came back with no trusted plan already, and a failure here (network error,
            // non-2xx, unparsable body) must never discard the usage quota that already
            // succeeded — it just leaves the plan unset, same as before this existed.
            if quota?.planType == nil {
                quota?.planType = await fetchClaudeProfilePlan(authIndex: authIndex, api: api)
            }
            return quota

        case .codex:
            var header = [
                "Authorization": "Bearer $TOKEN$",
                "Accept": "application/json",
            ]
            if let account = file.account, !account.isEmpty {
                header["ChatGPT-Account-Id"] = account
            }
            let result = try await api.apiCall(ProxyAPICall(
                authIndex: authIndex,
                method: "GET",
                url: CodexQuotaFetcher.usageURL.absoluteString,
                header: header,
                data: nil
            ))
            guard let data = bodyData(result) else { return nil }
            guard var quota = try? CodexQuotaFetcher.mapUsage(data, planFallback: trustedPlanFallback(file), now: now()) else {
                return nil
            }
            if let resetCredits = await fetchCodexResetCredits(authIndex: authIndex, accountId: file.account, api: api) {
                quota.analytics = CodexResetCreditInventoryFetcher.merge(resetCredits.analytics, into: quota.analytics)
                quota.codexResetCreditSummary = resetCredits.summary
            }
            return quota

        case .grok:
            let result = try await api.apiCall(ProxyAPICall(
                authIndex: authIndex,
                method: "GET",
                url: "https://cli-chat-proxy.grok.com/v1/billing?format=credits",
                header: Self.grokAPIHeaders,
                data: nil
            ))
            guard let data = bodyData(result) else { return nil }
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
            let plan = await fetchGrokSettingsPlan(authIndex: authIndex, api: api) ?? trustedPlanFallback(file)
            return GrokQuotaFetcher.mapBilling(data, plan: plan, displayName: displayName, now: now())

        default:
            return nil
        }
    }

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
