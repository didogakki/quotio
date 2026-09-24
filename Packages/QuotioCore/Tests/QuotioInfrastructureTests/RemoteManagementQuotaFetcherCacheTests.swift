import Foundation
import QuotioApplication
import QuotioDomain
import XCTest

@testable import QuotioInfrastructure

/// Covers the quota-cache opt-in path added to `RemoteManagementQuotaFetcher`:
/// `RemoteQuotaSourceConfig.quotaCacheBaseURL` defaults to `nil` (unchanged direct
/// behavior), and only usage/profile/credits requests ever go through the cache —
/// auth-file listing and account control always stay direct, so a cache failure can
/// never be mistaken for an account having been removed from the source.
final class RemoteManagementQuotaFetcherCacheTests: XCTestCase {
  func testDefaultConfigWithNoCacheBaseURLNeverCallsTheCacheClient() async throws {
    let files = [
      ManagedAuthFile(
        id: "1", name: "claude-a.json", provider: "claude", status: "ready", disabled: false,
        unavailable: false, authIndex: "claude-a")
    ]
    let api = CacheTestProxyManagementAPI(
      authFiles: files, urlResponses: [ClaudeQuotaFetcher.usageURL.absoluteString: (200, #"{"five_hour":{"utilization":10}}"#)])
    let cacheSession = CacheTestHTTPSession(statusCode: 200, body: Data())
    let fetcher = RemoteManagementQuotaFetcher(
      apiFactory: CacheTestProxyManagementAPIFactory(api: api),
      cacheClient: QuotaCacheClient(session: cacheSession)
    )
    let source = RemoteQuotaSourceConfig(name: "Pool", baseURL: "https://proxy.test")
    XCTAssertNil(source.quotaCacheBaseURL, "default must preserve the original direct-fetch behavior")

    let result = try await fetcher.fetchPool(source, managementKey: "k")

    XCTAssertEqual(result.quotasByProviderAndAccount[.claude]?["claude-a"]?.models.first?.percentage, 90)
    let cacheCalls = await cacheSession.requestCount
    XCTAssertEqual(cacheCalls, 0, "the cache client must never be reached when quotaCacheBaseURL is unset")
  }

  func testCacheEnabledSourceNeverFallsBackToDirectOnCacheFailure() async throws {
    let files = [
      ManagedAuthFile(
        id: "1", name: "claude-a.json", provider: "claude", status: "ready", disabled: false,
        unavailable: false, authIndex: "claude-a")
    ]
    // The direct API would happily answer, but must never be asked to.
    let api = CacheTestProxyManagementAPI(
      authFiles: files, urlResponses: [ClaudeQuotaFetcher.usageURL.absoluteString: (200, #"{"five_hour":{"utilization":10}}"#)])
    let cacheSession = CacheTestHTTPSession(statusCode: 503, body: Data())
    let fetcher = RemoteManagementQuotaFetcher(
      apiFactory: CacheTestProxyManagementAPIFactory(api: api),
      cacheClient: QuotaCacheClient(session: cacheSession)
    )
    let source = RemoteQuotaSourceConfig(
      name: "Pool", baseURL: "https://proxy.test", quotaCacheBaseURL: "https://proxy.test/quota-cache/v1/plus")

    let result = try await fetcher.fetchPool(source, managementKey: "k")

    XCTAssertNil(result.quotasByProviderAndAccount[.claude]?["claude-a"], "a failed cache read must not fall back to a direct upstream call")
    let directCalls = await api.recordedCalls
    XCTAssertTrue(directCalls.isEmpty, "no direct apiCall may be made once the source has opted into the cache")
    // The account is still known — a cache failure is never mistaken for the
    // account having been removed from the source.
    XCTAssertEqual(result.knownAccountKeys[.claude], ["claude-a"])
  }

  func testClassified401CreatesVisibleQuarantineWithoutFailingTheWholeSource() async throws {
    let files = [
      ManagedAuthFile(
        id: "1", name: "codex-a.json", provider: "codex", status: "ready", disabled: false,
        unavailable: false, email: "a@example.com", authIndex: "codex-a")
    ]
    let api = CacheTestProxyManagementAPI(authFiles: files, urlResponses: [:])
    let failure = Data(#"{"error":"upstream_unavailable","failure":{"kind":"auth_invalid","status_code":401}}"#.utf8)
    let fetcher = RemoteManagementQuotaFetcher(
      apiFactory: CacheTestProxyManagementAPIFactory(api: api),
      cacheClient: QuotaCacheClient(session: CacheTestHTTPSession(statusCode: 503, body: failure))
    )
    let source = RemoteQuotaSourceConfig(
      name: "Pool", baseURL: "https://proxy.test", quotaCacheBaseURL: "https://proxy.test/quota-cache/v1/plus")

    let result = try await fetcher.fetchPool(source, managementKey: "k")

    XCTAssertEqual(result.outcome, .complete, "a quarantined account is not a source-wide failure")
    XCTAssertEqual(result.accountIssues[.codex]?["codex-a"], .invalidOAuth)
    XCTAssertEqual(result.accountIssueObservedKeys[.codex], ["codex-a"])
    XCTAssertEqual(result.placeholderQuotas[.codex]?["codex-a"]?.remoteAccountIssue, .invalidOAuth)
    XCTAssertEqual(result.placeholderQuotas[.codex]?["codex-a"]?.accountDisplayName, "a@example.com")
    XCTAssertEqual(result.placeholderQuotas[.codex]?["codex-a"]?.models, [])
    let directCalls = await api.recordedCalls
    XCTAssertTrue(directCalls.isEmpty, "cache failures must never fall back to direct apiCall")
  }

  func testStaleSuccessfulEnvelopeKeepsQuotaAndAttachesAuthIssue() async throws {
    let files = [
      ManagedAuthFile(
        id: "1", name: "codex-a.json", provider: "codex", status: "ready", disabled: false,
        unavailable: false, authIndex: "codex-a")
    ]
    let api = CacheTestProxyManagementAPI(authFiles: files, urlResponses: [:])
    let envelope = #"{"result":{"status_code":200,"header":{},"body":"{\"plan_type\":\"plus\",\"rate_limit\":{\"primary_window\":{\"used_percent\":25,\"limit_window_seconds\":18000}}}"},"fetched_at":1700000000,"stale":true,"last_attempt":1700000500,"next_retry_at":1700000600,"failure":{"kind":"auth_invalid","status_code":401}}"#
    let fetcher = RemoteManagementQuotaFetcher(
      apiFactory: CacheTestProxyManagementAPIFactory(api: api),
      cacheClient: QuotaCacheClient(session: CacheTestHTTPSession(statusCode: 200, body: Data(envelope.utf8)))
    )
    let source = RemoteQuotaSourceConfig(
      name: "Pool", baseURL: "https://proxy.test", quotaCacheBaseURL: "https://proxy.test/quota-cache/v1/plus")

    let result = try await fetcher.fetchPool(source, managementKey: "k")

    XCTAssertEqual(result.outcome, .complete)
    XCTAssertEqual(result.quotasByProviderAndAccount[.codex]?["codex-a"]?.models.first?.percentage, 75)
    XCTAssertEqual(result.quotasByProviderAndAccount[.codex]?["codex-a"]?.remoteAccountIssue, .invalidOAuth)
    XCTAssertEqual(result.accountIssues[.codex]?["codex-a"], .invalidOAuth)
  }

  func testCacheEnabledSourceUsesTheCachesFetchedAtNotTheReadTime() async throws {
    let files = [
      ManagedAuthFile(
        id: "1", name: "claude-a.json", provider: "claude", status: "ready", disabled: false,
        unavailable: false, authIndex: "claude-a")
    ]
    let api = CacheTestProxyManagementAPI(authFiles: files, urlResponses: [:])
    let cachedAt = Date(timeIntervalSince1970: 1_700_000_000)
    let envelope = """
      {"result":{"status_code":200,"header":{},"body":"{\\"five_hour\\":{\\"utilization\\":10}}"},"fetched_at":1700000000,"stale":true,"last_attempt":1700000900,"next_retry_at":null}
      """
    let cacheSession = CacheTestHTTPSession(statusCode: 200, body: Data(envelope.utf8))
    let fetcher = RemoteManagementQuotaFetcher(
      apiFactory: CacheTestProxyManagementAPIFactory(api: api),
      // A very different "now" proves lastUpdated comes from the cache envelope,
      // never from the moment this round happened to run.
      now: { Date(timeIntervalSince1970: 1_900_000_000) },
      cacheClient: QuotaCacheClient(session: cacheSession)
    )
    let source = RemoteQuotaSourceConfig(
      name: "Pool", baseURL: "https://proxy.test", quotaCacheBaseURL: "https://proxy.test/quota-cache/v1/plus")

    let result = try await fetcher.fetchPool(source, managementKey: "k")

    XCTAssertEqual(result.quotasByProviderAndAccount[.claude]?["claude-a"]?.lastUpdated, cachedAt)
  }

  func testCacheEnabledSourceInterpretsRetryAfterRelativeToTheCachesFetchedAt() async throws {
    let files = [
      ManagedAuthFile(
        id: "1", name: "claude-a.json", provider: "claude", status: "error", disabled: false,
        unavailable: true, authIndex: "claude-a")
    ]
    let api = CacheTestProxyManagementAPI(authFiles: files, urlResponses: [:])
    let envelope = """
      {"result":{"status_code":429,"header":{"Retry-After":["120"]},"body":"rate limited"},"fetched_at":1700000000,"stale":false,"last_attempt":1700000000,"next_retry_at":1700000120}
      """
    let cacheSession = CacheTestHTTPSession(statusCode: 200, body: Data(envelope.utf8))
    let fetcher = RemoteManagementQuotaFetcher(
      apiFactory: CacheTestProxyManagementAPIFactory(api: api),
      // If the recovery date were (incorrectly) computed against the read time
      // instead of the cache's own fetched_at, this would produce a different date.
      now: { Date(timeIntervalSince1970: 1_800_000_000) },
      cacheClient: QuotaCacheClient(session: cacheSession)
    )
    let source = RemoteQuotaSourceConfig(
      name: "Pool", baseURL: "https://proxy.test", quotaCacheBaseURL: "https://proxy.test/quota-cache/v1/plus")

    let result = try await fetcher.fetchPool(source, managementKey: "k")

    XCTAssertEqual(
      result.placeholderQuotas[.claude]?["claude-a"]?.availabilityRecoveryDate,
      Date(timeIntervalSince1970: 1_700_000_000).addingTimeInterval(120))
  }

  func testCacheEnabledSourceKeepsUsageQuotaWhenOptionalProfileResourceFailsThroughCache() async throws {
    let files = [
      ManagedAuthFile(
        id: "1", name: "claude-a.json", provider: "claude", status: "ready", disabled: false,
        unavailable: false, accountType: "oauth", authIndex: "claude-a")
    ]
    let api = CacheTestProxyManagementAPI(authFiles: files, urlResponses: [:])
    let usageEnvelope = """
      {"result":{"status_code":200,"header":{},"body":"{\\"five_hour\\":{\\"utilization\\":10}}"},"fetched_at":1700000000,"stale":false,"last_attempt":1700000000,"next_retry_at":null}
      """
    // Every resource maps to the same base URL/path shape; the profile resource
    // (an optional supplement) fails while the usage resource already succeeded.
    let cacheSession = CacheTestHTTPSession(
      responsesByPath: [
        "/quota-cache/v1/plus/claude-usage": (200, Data(usageEnvelope.utf8)),
        "/quota-cache/v1/plus/claude-profile": (503, Data()),
      ])
    let fetcher = RemoteManagementQuotaFetcher(
      apiFactory: CacheTestProxyManagementAPIFactory(api: api),
      cacheClient: QuotaCacheClient(session: cacheSession)
    )
    let source = RemoteQuotaSourceConfig(
      name: "Pool", baseURL: "https://proxy.test", quotaCacheBaseURL: "https://proxy.test/quota-cache/v1/plus")

    let result = try await fetcher.fetchPool(source, managementKey: "k")

    XCTAssertEqual(result.quotasByProviderAndAccount[.claude]?["claude-a"]?.models.first?.percentage, 90)
    XCTAssertNil(result.quotasByProviderAndAccount[.claude]?["claude-a"]?.planType)
  }

  /// `routing_weights` on a cache-enabled Codex `codex-usage` envelope attaches to the
  /// resulting `ProviderQuota.routingWeight` — the same round-trip that already fetches
  /// usage, never a separate request/timer.
  func testCacheEnabledCodexSourceAttachesOptionalRoutingWeightFromTheSameEnvelope() async throws {
    let files = [
      ManagedAuthFile(
        id: "1", name: "codex-a.json", provider: "codex", status: "ready", disabled: false,
        unavailable: false, authIndex: "codex-a")
    ]
    let api = CacheTestProxyManagementAPI(authFiles: files, urlResponses: [:])
    let envelope = #"{"result":{"status_code":200,"header":{},"body":"{\"plan_type\":\"plus\",\"rate_limit\":{\"primary_window\":{\"used_percent\":25,\"limit_window_seconds\":18000}}}"},"fetched_at":1700000000,"stale":false,"last_attempt":1700000000,"next_retry_at":null,"routing_weights":{"account":33,"channel":75,"updated_at":1700000500}}"#
    let fetcher = RemoteManagementQuotaFetcher(
      apiFactory: CacheTestProxyManagementAPIFactory(api: api),
      cacheClient: QuotaCacheClient(session: CacheTestHTTPSession(statusCode: 200, body: Data(envelope.utf8)))
    )
    let source = RemoteQuotaSourceConfig(
      name: "Pool", baseURL: "https://proxy.test", quotaCacheBaseURL: "https://proxy.test/quota-cache/v1/plus")

    let result = try await fetcher.fetchPool(source, managementKey: "k")

    let routingWeight = result.quotasByProviderAndAccount[.codex]?["codex-a"]?.routingWeight
    XCTAssertEqual(routingWeight?.accountWeight, 33)
    XCTAssertEqual(routingWeight?.channelWeight, 75)
    XCTAssertEqual(routingWeight?.updatedAt, Date(timeIntervalSince1970: 1_700_000_500))
  }

  /// A cache build that doesn't compute weights at all (no `routing_weights` key)
  /// must never break the usage reading — the field is purely additive.
  func testCacheEnabledCodexSourceLeavesRoutingWeightNilWhenAbsentFromTheEnvelope() async throws {
    let files = [
      ManagedAuthFile(
        id: "1", name: "codex-a.json", provider: "codex", status: "ready", disabled: false,
        unavailable: false, authIndex: "codex-a")
    ]
    let api = CacheTestProxyManagementAPI(authFiles: files, urlResponses: [:])
    let envelope = #"{"result":{"status_code":200,"header":{},"body":"{\"plan_type\":\"plus\",\"rate_limit\":{\"primary_window\":{\"used_percent\":25,\"limit_window_seconds\":18000}}}"},"fetched_at":1700000000,"stale":false,"last_attempt":1700000000,"next_retry_at":null}"#
    let fetcher = RemoteManagementQuotaFetcher(
      apiFactory: CacheTestProxyManagementAPIFactory(api: api),
      cacheClient: QuotaCacheClient(session: CacheTestHTTPSession(statusCode: 200, body: Data(envelope.utf8)))
    )
    let source = RemoteQuotaSourceConfig(
      name: "Pool", baseURL: "https://proxy.test", quotaCacheBaseURL: "https://proxy.test/quota-cache/v1/plus")

    let result = try await fetcher.fetchPool(source, managementKey: "k")

    XCTAssertEqual(result.quotasByProviderAndAccount[.codex]?["codex-a"]?.models.first?.percentage, 75)
    XCTAssertNil(result.quotasByProviderAndAccount[.codex]?["codex-a"]?.routingWeight)
  }

  func testCrossOriginHTTPSCacheBaseURLIsNeverCalledAndNeverLeaksTheManagementKey() async throws {
    let files = [
      ManagedAuthFile(
        id: "1", name: "claude-a.json", provider: "claude", status: "ready", disabled: false,
        unavailable: false, authIndex: "claude-a")
    ]
    // The cache would happily answer, but the management key must never reach a
    // host that isn't this source's own management origin.
    let api = CacheTestProxyManagementAPI(authFiles: files, urlResponses: [:])
    let usageEnvelope = """
      {"result":{"status_code":200,"header":{},"body":"{\\"five_hour\\":{\\"utilization\\":10}}"},"fetched_at":1700000000,"stale":false,"last_attempt":1700000000,"next_retry_at":null}
      """
    let cacheSession = CacheTestHTTPSession(statusCode: 200, body: Data(usageEnvelope.utf8))
    let fetcher = RemoteManagementQuotaFetcher(
      apiFactory: CacheTestProxyManagementAPIFactory(api: api),
      cacheClient: QuotaCacheClient(session: cacheSession)
    )
    let source = RemoteQuotaSourceConfig(
      name: "Pool", baseURL: "https://proxy.test",
      quotaCacheBaseURL: "https://cache.example.com/quota-cache/v1/plus")

    let result = try await fetcher.fetchPool(source, managementKey: "k")

    XCTAssertNil(result.quotasByProviderAndAccount[.claude]?["claude-a"])
    let cacheCalls = await cacheSession.requestCount
    XCTAssertEqual(cacheCalls, 0, "a quota-cache base URL on a different origin must never be reached")
  }

  func testLoopbackHTTPCacheBaseURLIsTrustedRegardlessOfTheSourcesOwnOrigin() async throws {
    let files = [
      ManagedAuthFile(
        id: "1", name: "claude-a.json", provider: "claude", status: "ready", disabled: false,
        unavailable: false, authIndex: "claude-a")
    ]
    let api = CacheTestProxyManagementAPI(authFiles: files, urlResponses: [:])
    let usageEnvelope = """
      {"result":{"status_code":200,"header":{},"body":"{\\"five_hour\\":{\\"utilization\\":10}}"},"fetched_at":1700000000,"stale":false,"last_attempt":1700000000,"next_retry_at":null}
      """
    let cacheSession = CacheTestHTTPSession(statusCode: 200, body: Data(usageEnvelope.utf8))
    let fetcher = RemoteManagementQuotaFetcher(
      apiFactory: CacheTestProxyManagementAPIFactory(api: api),
      cacheClient: QuotaCacheClient(session: cacheSession)
    )
    // Same-host deployment: the cache runs on a different local port than the
    // remote management API, so it can never share the same origin, and never
    // needs to — loopback is trusted unconditionally.
    let source = RemoteQuotaSourceConfig(
      name: "Pool", baseURL: "https://proxy.test",
      quotaCacheBaseURL: "http://127.0.0.1:8328/quota-cache/v1/plus")

    let result = try await fetcher.fetchPool(source, managementKey: "k")

    XCTAssertEqual(result.quotasByProviderAndAccount[.claude]?["claude-a"]?.models.first?.percentage, 90)
  }
}

// MARK: - Test doubles

private struct CacheTestProxyManagementAPIFactory: ProxyManagementAPIFactory {
  let api: CacheTestProxyManagementAPI
  func makeManagementAPI(connection: ProxyManagementConnection) -> any ProxyManagementAPI { api }
}

private actor CacheTestProxyManagementAPI: ProxyManagementAPI {
  private let authFiles: [ManagedAuthFile]
  private let urlResponses: [String: (statusCode: Int, body: String)]
  private(set) var recordedCalls: [ProxyAPICall] = []

  init(authFiles: [ManagedAuthFile], urlResponses: [String: (statusCode: Int, body: String)]) {
    self.authFiles = authFiles
    self.urlResponses = urlResponses
  }

  func invalidate() async {}
  func fetchAuthFiles() async throws -> [ManagedAuthFile] { authFiles }
  func fetchAuthFileModels(name: String) async throws -> [ManagedModelInfo] { [] }

  func apiCall(_ request: ProxyAPICall) async throws -> ProxyAPICallResult {
    recordedCalls.append(request)
    guard let response = urlResponses[request.url] else {
      return try Self.makeResult(statusCode: 404, body: nil)
    }
    return try Self.makeResult(statusCode: response.statusCode, body: response.body)
  }

  private static func makeResult(statusCode: Int, body: String?) throws -> ProxyAPICallResult {
    var payload: [String: Any] = ["status_code": statusCode]
    if let body { payload["body"] = body }
    let data = try JSONSerialization.data(withJSONObject: payload)
    return try JSONDecoder().decode(ProxyAPICallResult.self, from: data)
  }

  func deleteAuthFile(name: String) async throws {}
  func uploadAuthFile(name: String, content: Data) async throws {}
  func downloadAuthFile(name: String) async throws -> Data { Data() }
  func deleteAllAuthFiles() async throws {}
  func setAuthFileDisabled(name: String, disabled: Bool) async throws {}
  func fetchUsageStats() async throws -> ProxyUsageStats { try Self.decode("{}") }
  func startOAuth(for provider: ProxyManagementOAuthProvider) async throws -> ProxyOAuthStart {
    try Self.decode(#"{"status":"unsupported"}"#)
  }
  func pollOAuthStatus(state: String) async throws -> ProxyOAuthStatus {
    try Self.decode(#"{"status":"unsupported"}"#)
  }
  func fetchConfig() async throws -> ProxyManagementConfiguration { try Self.decode("{}") }
  func setDebug(_ enabled: Bool) async throws {}
  func routingStrategy() async throws -> String { "" }
  func setRoutingStrategy(_ strategy: String) async throws {}
  func setQuotaExceededSwitchProject(_ enabled: Bool) async throws {}
  func setQuotaExceededSwitchPreviewModel(_ enabled: Bool) async throws {}
  func setRequestRetry(_ count: Int) async throws {}
  func setMaxRetryInterval(_ seconds: Int) async throws {}
  func setProxyURL(_ url: String) async throws {}
  func deleteProxyURL() async throws {}
  func setLoggingToFile(_ enabled: Bool) async throws {}
  func setRequestLog(_ enabled: Bool) async throws {}
  func uploadVertexServiceAccount(data: Data) async throws {}
  func fetchAPIKeys() async throws -> [String] { [] }
  func addAPIKey(_ key: String) async throws {}
  func replaceAPIKeys(_ keys: [String]) async throws {}
  func updateAPIKey(old: String, new: String) async throws {}
  func deleteAPIKey(value: String) async throws {}
  func deleteAPIKey(at index: Int) async throws {}
  func latestVersion() async throws -> ProxyLatestVersion { try Self.decode(#"{"latest-version":"0.0.0"}"#) }
  func isResponding() async -> Bool { true }

  private static func decode<T: Decodable>(_ json: String) throws -> T {
    try JSONDecoder().decode(T.self, from: Data(json.utf8))
  }
}

/// Fake `QuotaHTTPSession` for the cache client. Either answers every request with
/// one fixed status/body pair, or dispatches by request path when a resource needs
/// to answer differently (e.g. usage succeeds while profile fails).
private actor CacheTestHTTPSession: QuotaHTTPSession {
  private let fixed: (statusCode: Int, body: Data)?
  private let byPath: [String: (statusCode: Int, body: Data)]
  private(set) var requestCount = 0

  init(statusCode: Int, body: Data) {
    self.fixed = (statusCode, body)
    self.byPath = [:]
  }

  init(responsesByPath: [String: (statusCode: Int, body: Data)]) {
    self.fixed = nil
    self.byPath = responsesByPath
  }

  func data(for request: URLRequest) async throws -> (Data, URLResponse) {
    requestCount += 1
    let (statusCode, body) = byPath[request.url?.path ?? ""] ?? fixed ?? (404, Data())
    let response = HTTPURLResponse(url: request.url!, statusCode: statusCode, httpVersion: "HTTP/1.1", headerFields: nil)!
    return (body, response)
  }
}
