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
        guard !candidates.isEmpty else {
            throw RemoteQuotaFetchError.noSupportedReadyFiles
        }

        var quotasByProvider: [QuotaProvider: [ProviderQuota]] = [:]
        var succeededCount = 0
        for file in candidates {
            guard let provider = file.providerID else { continue }
            guard let quota = try? await fetchQuota(provider: provider, file: file, api: api) else {
                continue
            }
            succeededCount += 1
            quotasByProvider[provider, default: []].append(quota)
        }

        guard succeededCount > 0 else {
            throw RemoteQuotaFetchError.allRequestsFailed
        }

        var byProviderAndPlan: [QuotaProvider: [String: ProviderQuota]] = [:]
        for (provider, quotas) in quotasByProvider {
            let grouped = Dictionary(grouping: quotas) { QuotaPolicy.normalizedPlanKey($0.planType) }
            for (planKey, planQuotas) in grouped {
                guard let aggregated = QuotaPolicy.aggregatePool(planQuotas) else { continue }
                byProviderAndPlan[provider, default: [:]][planKey] = aggregated
            }
        }

        return RemoteQuotaPoolFetchResult(
            quotasByProviderAndPlan: byProviderAndPlan,
            hasPartialFailure: succeededCount < candidates.count
        )
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
        api: any ProxyManagementAPI
    ) async throws -> ProviderQuota? {
        let authIndex = file.authIndex ?? file.name
        switch provider {
        case .claude:
            let result = try await api.apiCall(ProxyAPICall(
                authIndex: authIndex,
                method: "GET",
                url: ClaudeQuotaFetcher.usageURL.absoluteString,
                header: [
                    "Authorization": "Bearer $TOKEN$",
                    "Accept": "application/json",
                    "Content-Type": "application/json",
                    "anthropic-beta": "oauth-2025-04-20",
                    "User-Agent": "claude-code/2.1.69",
                ],
                data: nil
            ))
            guard let data = bodyData(result) else { return nil }
            return ClaudeQuotaFetcher.mapUsage(data, now: now())

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
            return try? CodexQuotaFetcher.mapUsage(data, planFallback: file.accountType, now: now())

        case .grok:
            let result = try await api.apiCall(ProxyAPICall(
                authIndex: authIndex,
                method: "GET",
                url: "https://cli-chat-proxy.grok.com/v1/billing?format=credits",
                header: [
                    "Authorization": "Bearer $TOKEN$",
                    "X-XAI-Token-Auth": "xai-grok-cli",
                    "Accept": "application/json",
                    "User-Agent": "Quotio",
                ],
                data: nil
            ))
            guard let data = bodyData(result) else { return nil }
            let displayName = file.email?.nilIfBlank ?? file.name
            return GrokQuotaFetcher.mapBilling(data, plan: file.accountType, displayName: displayName, now: now())

        default:
            return nil
        }
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
