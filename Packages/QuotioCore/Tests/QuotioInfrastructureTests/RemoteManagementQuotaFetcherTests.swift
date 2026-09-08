import Foundation
import QuotioApplication
import QuotioDomain
import XCTest

@testable import QuotioInfrastructure

final class RemoteManagementQuotaFetcherTests: XCTestCase {
  func testFetchPoolMapsClaudeCodexAndGrokPassThroughResponses() async throws {
    let files = [
      ManagedAuthFile(
        id: "1", name: "claude-a.json", provider: "claude", status: "ready", disabled: false,
        unavailable: false, email: "a@example.com", authIndex: "claude-a"),
      ManagedAuthFile(
        id: "2", name: "codex-b.json", provider: "codex", status: "ready", disabled: false,
        unavailable: false, accountType: "plus", account: "acct-b", authIndex: "codex-b"),
      ManagedAuthFile(
        id: "3", name: "grok-c.json", provider: "grok", status: "ready", disabled: false,
        unavailable: false, email: "c@example.com", authIndex: "grok-c"),
      // Not ready — must be skipped entirely.
      ManagedAuthFile(
        id: "4", name: "claude-d.json", provider: "claude", status: "ready", disabled: true,
        unavailable: false, email: "d@example.com", authIndex: "claude-d"),
      // Unsupported provider — must be skipped.
      ManagedAuthFile(
        id: "5", name: "copilot-e.json", provider: "github-copilot", status: "ready",
        disabled: false, unavailable: false, authIndex: "copilot-e"),
    ]

    let claudeBody = #"{"five_hour":{"utilization":40,"resets_at":"2026-01-01T00:00:00Z"}}"#
    let codexBody = #"{"plan_type":"plus","rate_limit":{"primary_window":{"used_percent":25}}}"#
    let grokBody = """
      {"config":{"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","end":"2026-01-01T00:00:00Z"},"creditUsagePercent":10,"onDemandCap":{"val":0}}}
      """

    let api = StubProxyManagementAPI(
      authFiles: files,
      responses: [
        "claude-a": (200, claudeBody),
        "codex-b": (200, codexBody),
        "grok-c": (200, grokBody),
      ]
    )
    let fetcher = RemoteManagementQuotaFetcher(
      apiFactory: StubProxyManagementAPIFactory(api: api),
      now: { Date(timeIntervalSince1970: 1_800_000_000) }
    )
    let source = RemoteQuotaSourceConfig(id: "src-1", name: "Plus Pool", baseURL: "https://proxy.test:8317")

    let result = try await fetcher.fetchPool(source, managementKey: "admin-key")
    let pool = result.quotasByProviderAndPlan

    XCTAssertFalse(result.hasPartialFailure)
    XCTAssertEqual(pool[.claude]?["unknown"]?.models.first(where: { $0.name == "five-hour-session" })?.percentage, 60)
    XCTAssertEqual(pool[.codex]?["plus"]?.models.first(where: { $0.name == "codex-session" })?.percentage, 75)
    XCTAssertEqual(pool[.codex]?["plus"]?.planType, "plus")
    XCTAssertEqual(pool[.grok]?["unknown"]?.models.first(where: { $0.name == "grok-weekly" })?.percentage, 90)
    XCTAssertNil(pool[.copilot])

    // Every apiCall request must use the $TOKEN$ placeholder — the remote server
    // substitutes the real provider token; Quotio must never see it.
    for call in await api.recordedCalls {
      XCTAssertEqual(call.header?["Authorization"], "Bearer $TOKEN$")
    }
  }

  func testFetchPoolSelectsCurrentSchemaActiveXaiFileAsGrok() async throws {
    let files = [
      ManagedAuthFile(
        id: "1", name: "xai-a.json", provider: "xai", status: "active", disabled: false,
        unavailable: false, email: "a@example.com", authIndex: "xai-a"),
    ]
    let grokBody = """
      {"config":{"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","end":"2026-01-01T00:00:00Z"},"creditUsagePercent":10,"onDemandCap":{"val":0}}}
      """

    let api = StubProxyManagementAPI(
      authFiles: files,
      responses: ["xai-a": (200, grokBody)]
    )
    let fetcher = RemoteManagementQuotaFetcher(
      apiFactory: StubProxyManagementAPIFactory(api: api),
      now: { Date(timeIntervalSince1970: 1_800_000_000) }
    )
    let source = RemoteQuotaSourceConfig(id: "src-1", name: "Plus Pool", baseURL: "https://proxy.test:8317")

    let result = try await fetcher.fetchPool(source, managementKey: "admin-key")
    let pool = result.quotasByProviderAndPlan

    XCTAssertFalse(result.hasPartialFailure)
    XCTAssertEqual(pool[.grok]?["unknown"]?.models.first(where: { $0.name == "grok-weekly" })?.percentage, 90)
  }

  func testFetchPoolAggregatesMultipleAccountsToWorstCase() async throws {
    let files = [
      ManagedAuthFile(
        id: "1", name: "claude-a.json", provider: "claude", status: "ready", disabled: false,
        unavailable: false, authIndex: "claude-a"),
      ManagedAuthFile(
        id: "2", name: "claude-b.json", provider: "claude", status: "ready", disabled: false,
        unavailable: false, authIndex: "claude-b"),
    ]
    let api = StubProxyManagementAPI(
      authFiles: files,
      responses: [
        "claude-a": (200, #"{"five_hour":{"utilization":10}}"#),
        "claude-b": (200, #"{"five_hour":{"utilization":80}}"#),
      ]
    )
    let fetcher = RemoteManagementQuotaFetcher(apiFactory: StubProxyManagementAPIFactory(api: api))
    let source = RemoteQuotaSourceConfig(name: "Pool", baseURL: "https://proxy.test")

    let result = try await fetcher.fetchPool(source, managementKey: "k")

    // Worst-case (lowest remaining) percentage across the pool wins: 100-80=20.
    XCTAssertEqual(result.quotasByProviderAndPlan[.claude]?["unknown"]?.models.first?.percentage, 20)
  }

  func testFetchPoolThrowsWhenAuthFilesUnavailable() async {
    let api = StubProxyManagementAPI(authFiles: [], responses: [:], authFilesError: true)
    let fetcher = RemoteManagementQuotaFetcher(apiFactory: StubProxyManagementAPIFactory(api: api))
    let source = RemoteQuotaSourceConfig(name: "Pool", baseURL: "https://proxy.test")

    do {
      _ = try await fetcher.fetchPool(source, managementKey: "k")
      XCTFail("expected authFilesUnavailable")
    } catch let error as RemoteQuotaFetchError {
      XCTAssertEqual(error, .authFilesUnavailable)
    } catch {
      XCTFail("unexpected error: \(error)")
    }
  }

  func testFetchPoolClassifiesUnauthorizedResponse() async {
    let api = StubProxyManagementAPI(authFiles: [], responses: [:], authFilesFailure: ProxyManagementFailure.httpError(401))
    let fetcher = RemoteManagementQuotaFetcher(apiFactory: StubProxyManagementAPIFactory(api: api))
    let source = RemoteQuotaSourceConfig(name: "Pool", baseURL: "https://proxy.test")

    do {
      _ = try await fetcher.fetchPool(source, managementKey: "k")
      XCTFail("expected unauthorized")
    } catch let error as RemoteQuotaFetchError {
      XCTAssertEqual(error, .unauthorized)
    } catch {
      XCTFail("unexpected error: \(error)")
    }
  }

  func testFetchPoolClassifiesForbiddenResponseAsUnauthorized() async {
    let api = StubProxyManagementAPI(authFiles: [], responses: [:], authFilesFailure: ProxyManagementFailure.httpError(403))
    let fetcher = RemoteManagementQuotaFetcher(apiFactory: StubProxyManagementAPIFactory(api: api))
    let source = RemoteQuotaSourceConfig(name: "Pool", baseURL: "https://proxy.test")

    do {
      _ = try await fetcher.fetchPool(source, managementKey: "k")
      XCTFail("expected unauthorized")
    } catch let error as RemoteQuotaFetchError {
      XCTAssertEqual(error, .unauthorized)
    } catch {
      XCTFail("unexpected error: \(error)")
    }
  }

  func testFetchPoolClassifiesMissingManagementEndpointAsNotFound() async {
    let api = StubProxyManagementAPI(authFiles: [], responses: [:], authFilesFailure: ProxyManagementFailure.httpError(404))
    let fetcher = RemoteManagementQuotaFetcher(apiFactory: StubProxyManagementAPIFactory(api: api))
    let source = RemoteQuotaSourceConfig(name: "Pool", baseURL: "https://proxy.test")

    do {
      _ = try await fetcher.fetchPool(source, managementKey: "k")
      XCTFail("expected endpointNotFound")
    } catch let error as RemoteQuotaFetchError {
      XCTAssertEqual(error, .endpointNotFound)
    } catch {
      XCTFail("unexpected error: \(error)")
    }
  }

  func testFetchPoolClassifiesUnparsableResponseAsInvalidResponse() async {
    let decodingError = DecodingError.dataCorrupted(
      DecodingError.Context(codingPath: [], debugDescription: "bad payload"))
    let api = StubProxyManagementAPI(authFiles: [], responses: [:], authFilesFailure: decodingError)
    let fetcher = RemoteManagementQuotaFetcher(apiFactory: StubProxyManagementAPIFactory(api: api))
    let source = RemoteQuotaSourceConfig(name: "Pool", baseURL: "https://proxy.test")

    do {
      _ = try await fetcher.fetchPool(source, managementKey: "k")
      XCTFail("expected invalidResponse")
    } catch let error as RemoteQuotaFetchError {
      XCTAssertEqual(error, .invalidResponse)
    } catch {
      XCTFail("unexpected error: \(error)")
    }
  }

  func testFetchPoolClassifiesConnectionFailureAsConnectivityUnavailable() async {
    let api = StubProxyManagementAPI(
      authFiles: [], responses: [:],
      authFilesFailure: ProxyManagementFailure.connectionError("Could not connect to host"))
    let fetcher = RemoteManagementQuotaFetcher(apiFactory: StubProxyManagementAPIFactory(api: api))
    let source = RemoteQuotaSourceConfig(name: "Pool", baseURL: "https://proxy.test")

    do {
      _ = try await fetcher.fetchPool(source, managementKey: "k")
      XCTFail("expected connectivityUnavailable")
    } catch let error as RemoteQuotaFetchError {
      XCTAssertEqual(error, .connectivityUnavailable)
    } catch {
      XCTFail("unexpected error: \(error)")
    }
  }

  func testFetchPoolThrowsWhenNoSupportedReadyFiles() async {
    let files = [
      ManagedAuthFile(
        id: "1", name: "copilot-a.json", provider: "github-copilot", status: "ready",
        disabled: false, unavailable: false, authIndex: "copilot-a")
    ]
    let api = StubProxyManagementAPI(authFiles: files, responses: [:])
    let fetcher = RemoteManagementQuotaFetcher(apiFactory: StubProxyManagementAPIFactory(api: api))
    let source = RemoteQuotaSourceConfig(name: "Pool", baseURL: "https://proxy.test")

    do {
      _ = try await fetcher.fetchPool(source, managementKey: "k")
      XCTFail("expected noSupportedReadyFiles")
    } catch let error as RemoteQuotaFetchError {
      XCTAssertEqual(error, .noSupportedReadyFiles)
    } catch {
      XCTFail("unexpected error: \(error)")
    }
  }

  func testFetchPoolThrowsWhenEveryRequestFails() async {
    let files = [
      ManagedAuthFile(
        id: "1", name: "claude-a.json", provider: "claude", status: "ready", disabled: false,
        unavailable: false, authIndex: "claude-a")
    ]
    // No response registered for "claude-a" -> apiCall returns 404 -> mapUsage fails.
    let api = StubProxyManagementAPI(authFiles: files, responses: [:])
    let fetcher = RemoteManagementQuotaFetcher(apiFactory: StubProxyManagementAPIFactory(api: api))
    let source = RemoteQuotaSourceConfig(name: "Pool", baseURL: "https://proxy.test")

    do {
      _ = try await fetcher.fetchPool(source, managementKey: "k")
      XCTFail("expected allRequestsFailed")
    } catch let error as RemoteQuotaFetchError {
      XCTAssertEqual(error, .allRequestsFailed)
    } catch {
      XCTFail("unexpected error: \(error)")
    }
  }

  func testFetchPoolReportsPartialFailureWhenSomeAccountsFail() async throws {
    let files = [
      ManagedAuthFile(
        id: "1", name: "claude-a.json", provider: "claude", status: "ready", disabled: false,
        unavailable: false, authIndex: "claude-a"),
      ManagedAuthFile(
        id: "2", name: "claude-b.json", provider: "claude", status: "ready", disabled: false,
        unavailable: false, authIndex: "claude-b"),
    ]
    let api = StubProxyManagementAPI(
      authFiles: files,
      // Only "claude-a" gets a response; "claude-b" 404s and fails to map.
      responses: ["claude-a": (200, #"{"five_hour":{"utilization":10}}"#)]
    )
    let fetcher = RemoteManagementQuotaFetcher(apiFactory: StubProxyManagementAPIFactory(api: api))
    let source = RemoteQuotaSourceConfig(name: "Pool", baseURL: "https://proxy.test")

    let result = try await fetcher.fetchPool(source, managementKey: "k")

    XCTAssertTrue(result.hasPartialFailure)
    XCTAssertEqual(result.quotasByProviderAndPlan[.claude]?["unknown"]?.models.first?.percentage, 90)
  }

  func testFetchPoolGroupsSeparatePlansWithinTheSamePool() async throws {
    let files = [
      ManagedAuthFile(
        id: "1", name: "codex-a.json", provider: "codex", status: "ready", disabled: false,
        unavailable: false, accountType: "pro", authIndex: "codex-a"),
      ManagedAuthFile(
        id: "2", name: "codex-b.json", provider: "codex", status: "ready", disabled: false,
        unavailable: false, accountType: "team", authIndex: "codex-b"),
    ]
    let api = StubProxyManagementAPI(
      authFiles: files,
      responses: [
        "codex-a": (200, #"{"rate_limit":{"primary_window":{"used_percent":25}}}"#),
        "codex-b": (200, #"{"rate_limit":{"primary_window":{"used_percent":40}}}"#),
      ]
    )
    let fetcher = RemoteManagementQuotaFetcher(apiFactory: StubProxyManagementAPIFactory(api: api))
    let source = RemoteQuotaSourceConfig(name: "Pool", baseURL: "https://proxy.test")

    let result = try await fetcher.fetchPool(source, managementKey: "k")

    XCTAssertFalse(result.hasPartialFailure)
    XCTAssertEqual(result.quotasByProviderAndPlan[.codex]?["pro"]?.models.first?.percentage, 75)
    XCTAssertEqual(result.quotasByProviderAndPlan[.codex]?["team"]?.models.first?.percentage, 60)
  }

  func testIsRespondingDelegatesToManagementAPI() async {
    let api = StubProxyManagementAPI(authFiles: [], responses: [:], responding: true)
    let fetcher = RemoteManagementQuotaFetcher(apiFactory: StubProxyManagementAPIFactory(api: api))
    let source = RemoteQuotaSourceConfig(name: "Pool", baseURL: "https://proxy.test")

    let responding = await fetcher.isResponding(source, managementKey: "k")

    XCTAssertTrue(responding)
  }
}

// MARK: - Test doubles

private struct StubProxyManagementAPIFactory: ProxyManagementAPIFactory {
  let api: StubProxyManagementAPI

  func makeManagementAPI(connection: ProxyManagementConnection) -> any ProxyManagementAPI {
    api
  }
}

private actor StubProxyManagementAPI: ProxyManagementAPI {
  private let authFilesToReturn: [ManagedAuthFile]
  private let responses: [String: (statusCode: Int, body: String)]
  private let responding: Bool
  private let authFilesError: Bool
  private let authFilesFailure: Error?
  private(set) var recordedCalls: [ProxyAPICall] = []

  init(
    authFiles: [ManagedAuthFile],
    responses: [String: (statusCode: Int, body: String)],
    responding: Bool = true,
    authFilesError: Bool = false,
    authFilesFailure: Error? = nil
  ) {
    self.authFilesToReturn = authFiles
    self.responses = responses
    self.responding = responding
    self.authFilesError = authFilesError
    self.authFilesFailure = authFilesFailure
  }

  func invalidate() async {}

  func fetchAuthFiles() async throws -> [ManagedAuthFile] {
    if let authFilesFailure { throw authFilesFailure }
    if authFilesError { throw StubProxyManagementAPIError.simulated }
    return authFilesToReturn
  }

  func fetchAuthFileModels(name: String) async throws -> [ManagedModelInfo] { [] }

  func apiCall(_ request: ProxyAPICall) async throws -> ProxyAPICallResult {
    recordedCalls.append(request)
    guard let authIndex = request.authIndex, let response = responses[authIndex] else {
      return Self.makeResult(statusCode: 404, body: nil)
    }
    return Self.makeResult(statusCode: response.statusCode, body: response.body)
  }

  private static func makeResult(statusCode: Int, body: String?) -> ProxyAPICallResult {
    var payload: [String: Any] = ["status_code": statusCode]
    if let body { payload["body"] = body }
    let data = try! JSONSerialization.data(withJSONObject: payload)
    return try! JSONDecoder().decode(ProxyAPICallResult.self, from: data)
  }

  func deleteAuthFile(name: String) async throws {}
  func uploadAuthFile(name: String, content: Data) async throws {}
  func downloadAuthFile(name: String) async throws -> Data { Data() }
  func deleteAllAuthFiles() async throws {}
  func setAuthFileDisabled(name: String, disabled: Bool) async throws {}
  func fetchUsageStats() async throws -> ProxyUsageStats { Self.decode("{}") }
  func startOAuth(for provider: ProxyManagementOAuthProvider) async throws -> ProxyOAuthStart {
    Self.decode(#"{"status":"unsupported"}"#)
  }
  func pollOAuthStatus(state: String) async throws -> ProxyOAuthStatus {
    Self.decode(#"{"status":"unsupported"}"#)
  }
  func fetchConfig() async throws -> ProxyManagementConfiguration { Self.decode("{}") }
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
  func latestVersion() async throws -> ProxyLatestVersion { Self.decode(#"{"latest-version":"0.0.0"}"#) }
  func isResponding() async -> Bool { responding }

  private static func decode<T: Decodable>(_ json: String) -> T {
    // swiftlint:disable:next force_try
    try! JSONDecoder().decode(T.self, from: Data(json.utf8))
  }
}

private enum StubProxyManagementAPIError: Error {
  case simulated
}
