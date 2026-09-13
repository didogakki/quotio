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
      // Explicitly disabled on the server — must be skipped entirely.
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
    let pool = result.quotasByProviderAndAccount

    XCTAssertEqual(result.outcome, .complete)
    // Each ready, supported auth file surfaces as its own account under its own
    // `authIndex` key — never merged with any other account's reading.
    XCTAssertEqual(pool[.claude]?["claude-a"]?.models.first(where: { $0.name == "five-hour-session" })?.percentage, 60)
    XCTAssertEqual(pool[.claude]?["claude-a"]?.accountDisplayName, "a@example.com")
    XCTAssertEqual(pool[.codex]?["codex-b"]?.models.first(where: { $0.name == "codex-session" })?.percentage, 75)
    XCTAssertEqual(pool[.codex]?["codex-b"]?.planType, "plus")
    XCTAssertEqual(pool[.grok]?["grok-c"]?.models.first(where: { $0.name == "grok-weekly" })?.percentage, 90)
    XCTAssertNil(pool[.copilot])

    // Every apiCall request must use the $TOKEN$ placeholder — the remote server
    // substitutes the real provider token; Quotio must never see it.
    for call in await api.recordedCalls {
      XCTAssertEqual(call.header?["Authorization"], "Bearer $TOKEN$")
    }
  }

  /// A frozen account — cooling after a rate limit, or flagged unavailable — is still a
  /// real account on the server. It must stay in `knownAccountKeys`, which is exactly
  /// what the coordinator prunes against, instead of being mistaken for one that was
  /// deleted; only an explicitly disabled file is left out.
  func testFrozenAccountsStayListedAndAreReportedSeparately() async throws {
    let files = [
      ManagedAuthFile(
        id: "1", name: "claude-a.json", provider: "claude", status: "ready", disabled: false,
        unavailable: false, email: "a@example.com", authIndex: "claude-a"),
      // Cooling and silent — the case that used to make the account vanish.
      ManagedAuthFile(
        id: "2", name: "claude-b.json", provider: "claude", status: "cooling", disabled: false,
        unavailable: false, email: "b@example.com", authIndex: "claude-b"),
      // Flagged unavailable but still answering: frozen accounts are always attempted,
      // and a real reading always beats a stand-in.
      ManagedAuthFile(
        id: "3", name: "claude-c.json", provider: "claude", status: "ready", disabled: false,
        unavailable: true, email: "c@example.com", authIndex: "claude-c"),
      // Explicitly disabled on the server — a deliberate user action, still excluded.
      ManagedAuthFile(
        id: "4", name: "claude-d.json", provider: "claude", status: "ready", disabled: true,
        unavailable: false, email: "d@example.com", authIndex: "claude-d"),
    ]
    let claudeBody = #"{"five_hour":{"utilization":40,"resets_at":"2026-01-01T00:00:00Z"}}"#
    let api = StubProxyManagementAPI(
      authFiles: files,
      responses: ["claude-a": (200, claudeBody), "claude-c": (200, claudeBody)]
    )
    let fetcher = RemoteManagementQuotaFetcher(
      apiFactory: StubProxyManagementAPIFactory(api: api),
      now: { Date(timeIntervalSince1970: 1_800_000_000) }
    )
    let source = RemoteQuotaSourceConfig(id: "src-1", name: "Pool", baseURL: "https://proxy.test:8317")

    let result = try await fetcher.fetchPool(source, managementKey: "admin-key")

    XCTAssertEqual(result.knownAccountKeys[.claude], ["claude-a", "claude-b", "claude-c"])
    XCTAssertEqual(result.temporarilyUnavailableAccountKeys[.claude], ["claude-b", "claude-c"])
    // Only the one unfrozen account was expected to report, and it did — a frozen
    // account staying silent is not evidence that the source is unhealthy.
    XCTAssertEqual(result.outcome, .complete)
    XCTAssertEqual(
      result.quotasByProviderAndAccount[.claude]?["claude-c"]?.models.first?.percentage, 60,
      "a frozen account that still answers keeps its real reading")
    XCTAssertNil(
      result.quotasByProviderAndAccount[.claude]?["claude-c"]?.isTemporarilyUnavailable,
      "the frozen state is the coordinator's to stamp, from this round's listing")
    XCTAssertNil(result.placeholderQuotas[.claude]?["claude-c"])
    // The silent one gets an identity-only stand-in — never fabricated metrics.
    XCTAssertNil(result.quotasByProviderAndAccount[.claude]?["claude-b"])
    XCTAssertEqual(result.placeholderQuotas[.claude]?["claude-b"]?.accountDisplayName, "b@example.com")
    XCTAssertEqual(result.placeholderQuotas[.claude]?["claude-b"]?.isTemporarilyUnavailable, true)
    XCTAssertEqual(result.placeholderQuotas[.claude]?["claude-b"]?.models, [])
    XCTAssertNil(result.placeholderQuotas[.claude]?["claude-d"])
  }

  /// Every account frozen at once must not read as a failing round: three of those in a
  /// row would trip the coordinator's hide threshold and take the whole source out of
  /// the menu bar — the same disappearance the frozen-account handling exists to prevent.
  func testSourceWithOnlyFrozenAccountsIsNotReportedAsFailing() async throws {
    let files = [
      ManagedAuthFile(
        id: "1", name: "claude-a.json", provider: "claude", status: "cooling", disabled: false,
        unavailable: false, email: "a@example.com", authIndex: "claude-a"),
      ManagedAuthFile(
        id: "2", name: "codex-b.json", provider: "codex", status: "ready", disabled: false,
        unavailable: true, email: "b@example.com", authIndex: "codex-b"),
    ]
    let api = StubProxyManagementAPI(authFiles: files, responses: [:])
    let fetcher = RemoteManagementQuotaFetcher(
      apiFactory: StubProxyManagementAPIFactory(api: api),
      now: { Date(timeIntervalSince1970: 1_800_000_000) }
    )
    let source = RemoteQuotaSourceConfig(id: "src-1", name: "Pool", baseURL: "https://proxy.test:8317")

    let result = try await fetcher.fetchPool(source, managementKey: "admin-key")

    XCTAssertEqual(result.outcome, .complete)
    XCTAssertFalse(result.isFailure)
    XCTAssertEqual(result.knownAccountKeys[.claude], ["claude-a"])
    XCTAssertEqual(result.knownAccountKeys[.codex], ["codex-b"])
    XCTAssertEqual(result.placeholderQuotas[.claude]?.keys.sorted(), ["claude-a"])
    XCTAssertEqual(result.placeholderQuotas[.codex]?.keys.sorted(), ["codex-b"])
  }

  /// The auth-file listing's own explicit recovery field is the real, authoritative
  /// unfreeze time — carried through to the placeholder the coordinator stores, never
  /// derived from any quota model's `resetTime`.
  func testFrozenAccountPlaceholderCarriesTheAuthFileListingsOwnRecoveryTime() async throws {
    let files = [
      ManagedAuthFile(
        id: "1", name: "claude-a.json", provider: "claude", status: "cooling", disabled: false,
        unavailable: false, email: "a@example.com", authIndex: "claude-a",
        unfreezeAt: .absolute("2027-01-15T06:00:00Z")),
    ]
    let api = StubProxyManagementAPI(authFiles: files, responses: [:])
    let fetcher = RemoteManagementQuotaFetcher(
      apiFactory: StubProxyManagementAPIFactory(api: api),
      now: { Date(timeIntervalSince1970: 1_800_000_000) }
    )
    let source = RemoteQuotaSourceConfig(id: "src-1", name: "Pool", baseURL: "https://proxy.test:8317")

    let result = try await fetcher.fetchPool(source, managementKey: "admin-key")

    XCTAssertEqual(
      result.placeholderQuotas[.claude]?["claude-a"]?.availabilityRecoveryDate,
      ISO8601DateFormatter().date(from: "2027-01-15T06:00:00Z")
    )
  }

  /// When the listing itself carries no recovery field, the quota request's own
  /// `Retry-After` response header (passed straight through from the upstream provider)
  /// is used as a fallback real signal — never a fabricated one.
  func testFrozenAccountFallsBackToRetryAfterHeaderWhenListingHasNoRecoveryField() async throws {
    let files = [
      ManagedAuthFile(
        id: "1", name: "claude-a.json", provider: "claude", status: "cooling", disabled: false,
        unavailable: false, email: "a@example.com", authIndex: "claude-a"),
    ]
    let api = StubProxyManagementAPI(
      authFiles: files,
      responses: ["claude-a": (429, "rate limited")],
      headerResponses: ["claude-a": ["Retry-After": ["120"]]]
    )
    let fetchedAt = Date(timeIntervalSince1970: 1_800_000_000)
    let fetcher = RemoteManagementQuotaFetcher(
      apiFactory: StubProxyManagementAPIFactory(api: api),
      now: { fetchedAt }
    )
    let source = RemoteQuotaSourceConfig(id: "src-1", name: "Pool", baseURL: "https://proxy.test:8317")

    let result = try await fetcher.fetchPool(source, managementKey: "admin-key")

    XCTAssertEqual(
      result.placeholderQuotas[.claude]?["claude-a"]?.availabilityRecoveryDate,
      fetchedAt.addingTimeInterval(120)
    )
  }

  /// Neither the listing nor the quota response's headers carry any real recovery
  /// signal — the placeholder must report no recovery time at all, never one guessed
  /// from the quota model data it doesn't even have.
  func testFrozenAccountPlaceholderHasNoRecoveryDateWhenNoRealSignalExists() async throws {
    let files = [
      ManagedAuthFile(
        id: "1", name: "claude-a.json", provider: "claude", status: "cooling", disabled: false,
        unavailable: false, email: "a@example.com", authIndex: "claude-a"),
    ]
    let api = StubProxyManagementAPI(authFiles: files, responses: [:])
    let fetcher = RemoteManagementQuotaFetcher(
      apiFactory: StubProxyManagementAPIFactory(api: api),
      now: { Date(timeIntervalSince1970: 1_800_000_000) }
    )
    let source = RemoteQuotaSourceConfig(id: "src-1", name: "Pool", baseURL: "https://proxy.test:8317")

    let result = try await fetcher.fetchPool(source, managementKey: "admin-key")

    XCTAssertNil(result.placeholderQuotas[.claude]?["claude-a"]?.availabilityRecoveryDate)
  }

  /// `X-RateLimit-Reset` on a normal, successful response names the *next quota
  /// window*, never a freeze/cooldown recovery — it must never be read as one, even
  /// when present and even though the account is frozen per the listing.
  func testFrozenAccountNeverFallsBackToXRateLimitResetHeader() async throws {
    let files = [
      ManagedAuthFile(
        id: "1", name: "claude-a.json", provider: "claude", status: "cooling", disabled: false,
        unavailable: false, email: "a@example.com", authIndex: "claude-a"),
    ]
    let claudeBody = #"{"five_hour":{"utilization":40,"resets_at":"2026-01-01T00:00:00Z"}}"#
    let api = StubProxyManagementAPI(
      authFiles: files,
      responses: ["claude-a": (200, claudeBody)],
      headerResponses: ["claude-a": ["X-RateLimit-Reset": ["2027-01-15T06:00:00Z"]]]
    )
    let fetcher = RemoteManagementQuotaFetcher(
      apiFactory: StubProxyManagementAPIFactory(api: api),
      now: { Date(timeIntervalSince1970: 1_800_000_000) }
    )
    let source = RemoteQuotaSourceConfig(id: "src-1", name: "Pool", baseURL: "https://proxy.test:8317")

    let result = try await fetcher.fetchPool(source, managementKey: "admin-key")

    XCTAssertNil(result.quotasByProviderAndAccount[.claude]?["claude-a"]?.availabilityRecoveryDate)
  }

  /// `Retry-After` only ever describes an explicit 429 rate-limit response — on any
  /// other status (including a normal 2xx success) it must never be read as a
  /// freeze/cooldown recovery signal.
  func testRetryAfterHeaderIsIgnoredOnANonRateLimitedResponse() async throws {
    let files = [
      ManagedAuthFile(
        id: "1", name: "claude-a.json", provider: "claude", status: "cooling", disabled: false,
        unavailable: false, email: "a@example.com", authIndex: "claude-a"),
    ]
    let claudeBody = #"{"five_hour":{"utilization":40,"resets_at":"2026-01-01T00:00:00Z"}}"#
    let api = StubProxyManagementAPI(
      authFiles: files,
      responses: ["claude-a": (200, claudeBody)],
      headerResponses: ["claude-a": ["Retry-After": ["120"]]]
    )
    let fetcher = RemoteManagementQuotaFetcher(
      apiFactory: StubProxyManagementAPIFactory(api: api),
      now: { Date(timeIntervalSince1970: 1_800_000_000) }
    )
    let source = RemoteQuotaSourceConfig(id: "src-1", name: "Pool", baseURL: "https://proxy.test:8317")

    let result = try await fetcher.fetchPool(source, managementKey: "admin-key")

    XCTAssertNil(result.quotasByProviderAndAccount[.claude]?["claude-a"]?.availabilityRecoveryDate)
  }

  /// `availabilityRecoveryDates` is this round's own authoritative per-account map —
  /// separate from `placeholderQuotas`, which only ever covers an account with no
  /// existing reading — so the coordinator can refresh/clear a recovery time on an
  /// account it already has metrics for.
  func testAvailabilityRecoveryDatesReportsEveryFrozenAccountIncludingThoseWithARealReading() async throws {
    let files = [
      ManagedAuthFile(
        id: "1", name: "claude-a.json", provider: "claude", status: "cooling", disabled: false,
        unavailable: false, email: "a@example.com", authIndex: "claude-a",
        unfreezeAt: .absolute("2027-01-15T06:00:00Z")),
    ]
    let claudeBody = #"{"five_hour":{"utilization":40,"resets_at":"2026-01-01T00:00:00Z"}}"#
    let api = StubProxyManagementAPI(authFiles: files, responses: ["claude-a": (200, claudeBody)])
    let fetcher = RemoteManagementQuotaFetcher(
      apiFactory: StubProxyManagementAPIFactory(api: api),
      now: { Date(timeIntervalSince1970: 1_800_000_000) }
    )
    let source = RemoteQuotaSourceConfig(id: "src-1", name: "Pool", baseURL: "https://proxy.test:8317")

    let result = try await fetcher.fetchPool(source, managementKey: "admin-key")

    // The account produced a real reading (frozen but still answering), so it's not in
    // `placeholderQuotas` — but its recovery time must still be reported authoritatively.
    XCTAssertNil(result.placeholderQuotas[.claude]?["claude-a"])
    XCTAssertEqual(
      result.availabilityRecoveryDates[.claude]?["claude-a"],
      ISO8601DateFormatter().date(from: "2027-01-15T06:00:00Z")
    )
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
    let pool = result.quotasByProviderAndAccount

    XCTAssertEqual(result.outcome, .complete)
    XCTAssertEqual(pool[.grok]?["xai-a"]?.models.first(where: { $0.name == "grok-weekly" })?.percentage, 90)
  }

  /// Regression: two distinct accounts under one source must never be merged/aggregated
  /// into a single worst-case reading — each keeps its own independent quota, keyed by
  /// its own `authIndex`, so neither account's real data is lost or overwritten.
  func testFetchPoolNeverAggregatesMultipleAccountsTogether() async throws {
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

    let pool = result.quotasByProviderAndAccount[.claude]
    XCTAssertEqual(pool?.count, 2, "each account must surface as its own independent entry")
    XCTAssertEqual(pool?["claude-a"]?.models.first?.percentage, 90)
    XCTAssertEqual(pool?["claude-b"]?.models.first?.percentage, 20)
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

  /// "Nothing supported and ready" is a real answer from a listing that succeeded, so
  /// it must be reported as an authoritative empty list rather than thrown — otherwise
  /// the coordinator can never learn that the source's accounts are all gone.
  func testFetchPoolReportsEmptyAuthoritativeListingInsteadOfThrowing() async throws {
    let files = [
      ManagedAuthFile(
        id: "1", name: "copilot-a.json", provider: "github-copilot", status: "ready",
        disabled: false, unavailable: false, authIndex: "copilot-a")
    ]
    let api = StubProxyManagementAPI(authFiles: files, responses: [:])
    let fetcher = RemoteManagementQuotaFetcher(apiFactory: StubProxyManagementAPIFactory(api: api))
    let source = RemoteQuotaSourceConfig(name: "Pool", baseURL: "https://proxy.test")

    let result = try await fetcher.fetchPool(source, managementKey: "k")

    XCTAssertEqual(result.outcome, .noAccountsListed)
    XCTAssertTrue(result.isFailure, "an empty listing must still count as a failed round")
    XCTAssertEqual(
      result.failureLocalizationKey, RemoteQuotaFetchError.noSupportedReadyFiles.localizationKey)
    XCTAssertEqual(
      Set(result.knownAccountKeys.keys), RemoteManagementQuotaFetcher.supportedProviders,
      "every supported provider must be reported, so each can be pruned to nothing")
    XCTAssertTrue(result.knownAccountKeys.values.allSatisfy(\.isEmpty))
  }

  /// Every quota request failing says nothing about which accounts exist. The listing
  /// still succeeded, so it must come back intact — marked as a failed round, but with
  /// an authoritative account list the coordinator can prune against.
  func testFetchPoolKeepsListingAuthoritativeWhenEveryRequestFails() async throws {
    let files = [
      ManagedAuthFile(
        id: "1", name: "claude-a.json", provider: "claude", status: "ready", disabled: false,
        unavailable: false, authIndex: "claude-a")
    ]
    // No response registered for "claude-a" -> apiCall returns 404 -> mapUsage fails.
    let api = StubProxyManagementAPI(authFiles: files, responses: [:])
    let fetcher = RemoteManagementQuotaFetcher(apiFactory: StubProxyManagementAPIFactory(api: api))
    let source = RemoteQuotaSourceConfig(name: "Pool", baseURL: "https://proxy.test")

    let result = try await fetcher.fetchPool(source, managementKey: "k")

    XCTAssertEqual(result.outcome, .allFailed)
    XCTAssertTrue(result.isFailure)
    XCTAssertEqual(
      result.failureLocalizationKey, RemoteQuotaFetchError.allRequestsFailed.localizationKey)
    XCTAssertTrue(result.quotasByProviderAndAccount.isEmpty)
    XCTAssertEqual(result.knownAccountKeys[.claude], ["claude-a"])
  }

  /// A provider whose accounts were all removed remotely must come back as an empty
  /// set, not be omitted — omission means "the listing said nothing", which the
  /// coordinator deliberately treats as "leave the previous accounts alone".
  func testFetchPoolReportsEmptySetForSupportedProvidersWithNoAccounts() async throws {
    let files = [
      ManagedAuthFile(
        id: "1", name: "claude-a.json", provider: "claude", status: "ready", disabled: false,
        unavailable: false, authIndex: "claude-a")
    ]
    let api = StubProxyManagementAPI(
      authFiles: files,
      responses: ["claude-a": (200, #"{"five_hour":{"utilization":10}}"#)]
    )
    let fetcher = RemoteManagementQuotaFetcher(apiFactory: StubProxyManagementAPIFactory(api: api))
    let source = RemoteQuotaSourceConfig(name: "Pool", baseURL: "https://proxy.test")

    let result = try await fetcher.fetchPool(source, managementKey: "k")

    XCTAssertEqual(result.knownAccountKeys[.claude], ["claude-a"])
    XCTAssertEqual(result.knownAccountKeys[.codex], [])
    XCTAssertEqual(result.knownAccountKeys[.grok], [])
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

    XCTAssertEqual(result.outcome, .partial)
    XCTAssertEqual(result.quotasByProviderAndAccount[.claude]?["claude-a"]?.models.first?.percentage, 90)
    // "claude-b" is still a ready, supported auth file — its own quota request merely
    // failed — so it must still be reported as known, letting the coordinator keep its
    // last-known-good reading instead of treating it as removed from the source.
    XCTAssertEqual(result.knownAccountKeys[.claude], ["claude-a", "claude-b"])
  }

  /// An auth file that's no longer ready (e.g. deleted or disabled on the remote
  /// server) must never appear in `knownAccountKeys` — that's what lets the
  /// coordinator distinguish "still exists but its quota fetch failed" from "no
  /// longer exists at all" and prune only the latter.
  func testFetchPoolExcludesNonReadyFilesFromKnownAccountKeys() async throws {
    let files = [
      ManagedAuthFile(
        id: "1", name: "claude-a.json", provider: "claude", status: "ready", disabled: false,
        unavailable: false, authIndex: "claude-a"),
      ManagedAuthFile(
        id: "2", name: "claude-b.json", provider: "claude", status: "disabled", disabled: true,
        unavailable: false, authIndex: "claude-b"),
    ]
    let api = StubProxyManagementAPI(
      authFiles: files,
      responses: ["claude-a": (200, #"{"five_hour":{"utilization":10}}"#)]
    )
    let fetcher = RemoteManagementQuotaFetcher(apiFactory: StubProxyManagementAPIFactory(api: api))
    let source = RemoteQuotaSourceConfig(name: "Pool", baseURL: "https://proxy.test")

    let result = try await fetcher.fetchPool(source, managementKey: "k")

    XCTAssertEqual(result.knownAccountKeys[.claude], ["claude-a"])
  }

  /// Two accounts on different plans under the same source must each keep their own
  /// plan and quota, keyed by their own `authIndex` — never merged into a plan bucket.
  func testFetchPoolKeepsDifferentPlanAccountsAsSeparateEntries() async throws {
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

    XCTAssertEqual(result.outcome, .complete)
    XCTAssertEqual(result.quotasByProviderAndAccount[.codex]?["codex-a"]?.models.first?.percentage, 75)
    XCTAssertEqual(result.quotasByProviderAndAccount[.codex]?["codex-a"]?.planType, "pro")
    XCTAssertEqual(result.quotasByProviderAndAccount[.codex]?["codex-b"]?.models.first?.percentage, 60)
    XCTAssertEqual(result.quotasByProviderAndAccount[.codex]?["codex-b"]?.planType, "team")
  }

  /// Fix for the menu bar showing "Claude Unknown": the remote branch used to have no
  /// `file.accountType` fallback for Claude at all, so a remote Claude account's plan
  /// was always nil even when the management API reported one via `account_type`.
  func testFetchPoolUsesAccountTypeAsClaudePlanFallback() async throws {
    let files = [
      ManagedAuthFile(
        id: "1", name: "claude-a.json", provider: "claude", status: "ready", disabled: false,
        unavailable: false, accountType: "max", authIndex: "claude-a"),
    ]
    let api = StubProxyManagementAPI(
      authFiles: files,
      responses: ["claude-a": (200, #"{"five_hour":{"utilization":10}}"#)]
    )
    let fetcher = RemoteManagementQuotaFetcher(apiFactory: StubProxyManagementAPIFactory(api: api))
    let source = RemoteQuotaSourceConfig(name: "Pool", baseURL: "https://proxy.test")

    let result = try await fetcher.fetchPool(source, managementKey: "k")

    XCTAssertEqual(result.quotasByProviderAndAccount[.claude]?["claude-a"]?.planType, "max")
  }

  /// Regression: Claude only ever authenticates via OAuth, so a real remote server can
  /// report `account_type: "oauth"` for a genuinely paid account — that value describes
  /// *how* the account authenticates, never *what plan* it is on. Passing it straight
  /// through as the plan fallback made the tier badge read the literal word "oauth"
  /// instead of the account's real plan (or nothing). It must be filtered out, not
  /// displayed, and never replaced with a guessed plan like "Pro".
  func testFetchPoolFiltersOAuthAccountTypeFromClaudePlanFallback() async throws {
    let files = [
      ManagedAuthFile(
        id: "1", name: "claude-a.json", provider: "claude", status: "ready", disabled: false,
        unavailable: false, accountType: "oauth", authIndex: "claude-a"),
    ]
    let api = StubProxyManagementAPI(
      authFiles: files,
      responses: ["claude-a": (200, #"{"five_hour":{"utilization":10}}"#)]
    )
    let fetcher = RemoteManagementQuotaFetcher(apiFactory: StubProxyManagementAPIFactory(api: api))
    let source = RemoteQuotaSourceConfig(name: "Pool", baseURL: "https://proxy.test")

    let result = try await fetcher.fetchPool(source, managementKey: "k")

    XCTAssertNil(result.quotasByProviderAndAccount[.claude]?["claude-a"]?.planType)
  }

  /// The `api_key` auth-mechanism label must be filtered the same way `oauth` is,
  /// regardless of casing/hyphenation, since it is never a plan name either.
  func testFetchPoolFiltersApiKeyAccountTypeFromClaudePlanFallback() async throws {
    let files = [
      ManagedAuthFile(
        id: "1", name: "claude-a.json", provider: "claude", status: "ready", disabled: false,
        unavailable: false, accountType: "API_KEY", authIndex: "claude-a"),
    ]
    let api = StubProxyManagementAPI(
      authFiles: files,
      responses: ["claude-a": (200, #"{"five_hour":{"utilization":10}}"#)]
    )
    let fetcher = RemoteManagementQuotaFetcher(apiFactory: StubProxyManagementAPIFactory(api: api))
    let source = RemoteQuotaSourceConfig(name: "Pool", baseURL: "https://proxy.test")

    let result = try await fetcher.fetchPool(source, managementKey: "k")

    XCTAssertNil(result.quotasByProviderAndAccount[.claude]?["claude-a"]?.planType)
  }

  /// When the management API reports no `account_type` at all, the plan must stay nil
  /// (no guessed "Pro"/plan) rather than defaulting to some non-nil placeholder.
  func testFetchPoolLeavesClaudePlanNilWhenAccountTypeIsMissing() async throws {
    let files = [
      ManagedAuthFile(
        id: "1", name: "claude-a.json", provider: "claude", status: "ready", disabled: false,
        unavailable: false, authIndex: "claude-a"),
    ]
    let api = StubProxyManagementAPI(
      authFiles: files,
      responses: ["claude-a": (200, #"{"five_hour":{"utilization":10}}"#)]
    )
    let fetcher = RemoteManagementQuotaFetcher(apiFactory: StubProxyManagementAPIFactory(api: api))
    let source = RemoteQuotaSourceConfig(name: "Pool", baseURL: "https://proxy.test")

    let result = try await fetcher.fetchPool(source, managementKey: "k")

    XCTAssertNil(result.quotasByProviderAndAccount[.claude]?["claude-a"]?.planType)
  }

  // MARK: - Claude OAuth profile plan supplement

  /// Claude only ever authenticates via OAuth, so a real remote server's `account_type`
  /// never carries the real plan (see `testFetchPoolFiltersOAuthAccountTypeFromClaudePlanFallback`).
  /// The OAuth profile endpoint is the only trusted source in that case — fetched via the
  /// same `apiCall`/`$TOKEN$` pass-through as usage, keyed by a distinct URL so the stub
  /// can answer the two requests differently.
  func testFetchPoolSupplementsClaudePlanFromOAuthProfileWhenAccountTypeIsUntrusted() async throws {
    let files = [
      ManagedAuthFile(
        id: "1", name: "claude-a.json", provider: "claude", status: "ready", disabled: false,
        unavailable: false, accountType: "oauth", authIndex: "claude-a"),
    ]
    let profileBody =
      #"{"account":{"has_claude_pro":true,"has_claude_max":false},"organization":{"organization_type":"claude_pro"}}"#
    let api = StubProxyManagementAPI(
      authFiles: files,
      responses: [:],
      urlResponses: [
        ClaudeQuotaFetcher.usageURL.absoluteString: (200, #"{"five_hour":{"utilization":10}}"#),
        ClaudeQuotaFetcher.profileURL.absoluteString: (200, profileBody),
      ]
    )
    let fetcher = RemoteManagementQuotaFetcher(apiFactory: StubProxyManagementAPIFactory(api: api))
    let source = RemoteQuotaSourceConfig(name: "Pool", baseURL: "https://proxy.test")

    let result = try await fetcher.fetchPool(source, managementKey: "k")

    XCTAssertEqual(result.quotasByProviderAndAccount[.claude]?["claude-a"]?.planType, "Pro")
    XCTAssertEqual(result.quotasByProviderAndAccount[.claude]?["claude-a"]?.models.first?.percentage, 90)
  }

  /// An account mid-transition can report both entitlement flags at once; Max must win.
  func testFetchPoolPrefersMaxOverProWhenBothProfileFlagsAreSet() async throws {
    let files = [
      ManagedAuthFile(
        id: "1", name: "claude-a.json", provider: "claude", status: "ready", disabled: false,
        unavailable: false, authIndex: "claude-a"),
    ]
    let profileBody = #"{"account":{"has_claude_pro":true,"has_claude_max":true}}"#
    let api = StubProxyManagementAPI(
      authFiles: files,
      responses: [:],
      urlResponses: [
        ClaudeQuotaFetcher.usageURL.absoluteString: (200, #"{"five_hour":{"utilization":10}}"#),
        ClaudeQuotaFetcher.profileURL.absoluteString: (200, profileBody),
      ]
    )
    let fetcher = RemoteManagementQuotaFetcher(apiFactory: StubProxyManagementAPIFactory(api: api))
    let source = RemoteQuotaSourceConfig(name: "Pool", baseURL: "https://proxy.test")

    let result = try await fetcher.fetchPool(source, managementKey: "k")

    XCTAssertEqual(result.quotasByProviderAndAccount[.claude]?["claude-a"]?.planType, "Max")
  }

  /// A failed/unparsable profile response must never discard a usage fetch that already
  /// succeeded — it only leaves the plan unset, exactly as if the profile call had never
  /// been made.
  func testFetchPoolKeepsUsageQuotaWhenProfileRequestFails() async throws {
    let files = [
      ManagedAuthFile(
        id: "1", name: "claude-a.json", provider: "claude", status: "ready", disabled: false,
        unavailable: false, authIndex: "claude-a"),
    ]
    let api = StubProxyManagementAPI(
      authFiles: files,
      responses: [:],
      urlResponses: [
        ClaudeQuotaFetcher.usageURL.absoluteString: (200, #"{"five_hour":{"utilization":10}}"#),
        ClaudeQuotaFetcher.profileURL.absoluteString: (500, "internal error"),
      ]
    )
    let fetcher = RemoteManagementQuotaFetcher(apiFactory: StubProxyManagementAPIFactory(api: api))
    let source = RemoteQuotaSourceConfig(name: "Pool", baseURL: "https://proxy.test")

    let result = try await fetcher.fetchPool(source, managementKey: "k")

    XCTAssertEqual(result.quotasByProviderAndAccount[.claude]?["claude-a"]?.models.first?.percentage, 90)
    XCTAssertNil(result.quotasByProviderAndAccount[.claude]?["claude-a"]?.planType)
  }

  /// A canceled renewal must never downgrade an account that still reports
  /// `has_claude_pro` — losing a future renewal is not the same as losing the plan the
  /// account currently has. Uses the exact field-verified real-endpoint response shape.
  func testFetchPoolKeepsProPlanEvenWhenSubscriptionStatusIsCanceled() async throws {
    let files = [
      ManagedAuthFile(
        id: "1", name: "claude-a.json", provider: "claude", status: "ready", disabled: false,
        unavailable: false, authIndex: "claude-a"),
    ]
    let profileBody =
      #"{"account":{"has_claude_pro":true,"has_claude_max":false},"organization":{"organization_type":"claude_pro","subscription_status":"canceled","rate_limit_tier":"default_claude_ai","seat_tier":null}}"#
    let api = StubProxyManagementAPI(
      authFiles: files,
      responses: [:],
      urlResponses: [
        ClaudeQuotaFetcher.usageURL.absoluteString: (200, #"{"five_hour":{"utilization":10}}"#),
        ClaudeQuotaFetcher.profileURL.absoluteString: (200, profileBody),
      ]
    )
    let fetcher = RemoteManagementQuotaFetcher(apiFactory: StubProxyManagementAPIFactory(api: api))
    let source = RemoteQuotaSourceConfig(name: "Pool", baseURL: "https://proxy.test")

    let result = try await fetcher.fetchPool(source, managementKey: "k")

    XCTAssertEqual(result.quotasByProviderAndAccount[.claude]?["claude-a"]?.planType, "Pro")
  }

  /// Once the auth-file listing already has a trusted plan, the profile endpoint must
  /// not be requested at all — supplementing only applies when usage/metadata provided
  /// no trustworthy plan.
  func testFetchPoolSkipsProfileRequestWhenAccountTypeIsAlreadyTrusted() async throws {
    let files = [
      ManagedAuthFile(
        id: "1", name: "claude-a.json", provider: "claude", status: "ready", disabled: false,
        unavailable: false, accountType: "max", authIndex: "claude-a"),
    ]
    let api = StubProxyManagementAPI(
      authFiles: files,
      responses: [:],
      urlResponses: [
        ClaudeQuotaFetcher.usageURL.absoluteString: (200, #"{"five_hour":{"utilization":10}}"#),
      ]
    )
    let fetcher = RemoteManagementQuotaFetcher(apiFactory: StubProxyManagementAPIFactory(api: api))
    let source = RemoteQuotaSourceConfig(name: "Pool", baseURL: "https://proxy.test")

    let result = try await fetcher.fetchPool(source, managementKey: "k")

    XCTAssertEqual(result.quotasByProviderAndAccount[.claude]?["claude-a"]?.planType, "max")
    let profileCalls = await api.recordedCalls.filter { $0.url == ClaudeQuotaFetcher.profileURL.absoluteString }
    XCTAssertTrue(profileCalls.isEmpty, "profile must not be requested once a trusted plan is already known")
  }

  // MARK: - Codex reset-credit supplement (remote CPA accounts)

  /// Every CPA Codex account must get its reset-credit summary the same way local
  /// Codex accounts do — via the `$TOKEN$` pass-through, never a direct token.
  func testFetchPoolSupplementsCodexResetCreditSummaryForRemoteAccounts() async throws {
    let files = [
      ManagedAuthFile(
        id: "1", name: "codex-a.json", provider: "codex", status: "ready", disabled: false,
        unavailable: false, account: "acct-a", authIndex: "codex-a"),
    ]
    let resetCreditsBody =
      #"{"available_count":1,"credits":[{"id":"c1","status":"available","expires_at":"2026-09-21T07:22:00Z"}]}"#
    let api = StubProxyManagementAPI(
      authFiles: files,
      responses: [:],
      urlResponses: [
        CodexQuotaFetcher.usageURL.absoluteString: (200, #"{"rate_limit":{"primary_window":{"used_percent":25}}}"#),
        CodexResetCreditInventoryFetcher.inventoryURL.absoluteString: (200, resetCreditsBody),
      ]
    )
    let fetcher = RemoteManagementQuotaFetcher(
      apiFactory: StubProxyManagementAPIFactory(api: api),
      now: { Date(timeIntervalSince1970: 1_700_000_000) }
    )
    let source = RemoteQuotaSourceConfig(name: "Pool", baseURL: "https://proxy.test")

    let result = try await fetcher.fetchPool(source, managementKey: "k")

    let summary = result.quotasByProviderAndAccount[.codex]?["codex-a"]?.codexResetCreditSummary
    XCTAssertEqual(summary?.availableCount, 1)
    XCTAssertEqual(summary?.nearestExpiryAt, ISO8601DateFormatter().date(from: "2026-09-21T07:22:00Z"))

    let resetCreditsCall = await api.recordedCalls.first {
      $0.url == CodexResetCreditInventoryFetcher.inventoryURL.absoluteString
    }
    XCTAssertEqual(resetCreditsCall?.header?["Authorization"], "Bearer $TOKEN$")
    XCTAssertEqual(resetCreditsCall?.header?["ChatGPT-Account-Id"], "acct-a")
  }

  /// A failed/unparsable reset-credit response must never discard a usage fetch that
  /// already succeeded — mirroring `testFetchPoolKeepsUsageQuotaWhenProfileRequestFails`
  /// for Claude's profile supplement.
  func testFetchPoolKeepsCodexUsageQuotaWhenResetCreditRequestFails() async throws {
    let files = [
      ManagedAuthFile(
        id: "1", name: "codex-a.json", provider: "codex", status: "ready", disabled: false,
        unavailable: false, authIndex: "codex-a"),
    ]
    let api = StubProxyManagementAPI(
      authFiles: files,
      responses: [:],
      urlResponses: [
        CodexQuotaFetcher.usageURL.absoluteString: (200, #"{"rate_limit":{"primary_window":{"used_percent":25}}}"#),
        CodexResetCreditInventoryFetcher.inventoryURL.absoluteString: (500, "internal error"),
      ]
    )
    let fetcher = RemoteManagementQuotaFetcher(apiFactory: StubProxyManagementAPIFactory(api: api))
    let source = RemoteQuotaSourceConfig(name: "Pool", baseURL: "https://proxy.test")

    let result = try await fetcher.fetchPool(source, managementKey: "k")

    XCTAssertEqual(result.quotasByProviderAndAccount[.codex]?["codex-a"]?.models.first?.percentage, 75)
    XCTAssertNil(result.quotasByProviderAndAccount[.codex]?["codex-a"]?.codexResetCreditSummary)
  }

  // MARK: - Grok plan resolution (remote CPA accounts)

  /// Real `/v1/settings` metadata (mirroring the local Grok fetcher) must be preferred
  /// over the narrowly source-scoped legacy default.
  func testFetchPoolPrefersGrokSettingsPlanOverLegacyDefault() async throws {
    let files = [
      ManagedAuthFile(
        id: "1", name: "grok-a.json", provider: "grok", status: "ready", disabled: false,
        unavailable: false, authIndex: "grok-a"),
    ]
    let billingBody = """
      {"config":{"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","end":"2026-01-01T00:00:00Z"},"creditUsagePercent":10,"onDemandCap":{"val":0}}}
      """
    let api = StubProxyManagementAPI(
      authFiles: files,
      responses: [:],
      urlResponses: [
        "https://cli-chat-proxy.grok.com/v1/billing?format=credits": (200, billingBody),
        "https://cli-chat-proxy.grok.com/v1/settings": (200, #"{"subscription_tier_display":"Basic"}"#),
      ]
    )
    let fetcher = RemoteManagementQuotaFetcher(apiFactory: StubProxyManagementAPIFactory(api: api))
    // Named exactly like the source the legacy default targets — real metadata must
    // still win over it.
    let source = RemoteQuotaSourceConfig(name: "CLIProxyAPI Plus", baseURL: "https://proxy.test")

    let result = try await fetcher.fetchPool(source, managementKey: "k")

    XCTAssertEqual(result.quotasByProviderAndAccount[.grok]?["grok-a"]?.planType, "Basic")
  }

  /// The narrowly source-scoped "Premium" legacy default (see
  /// `QuotaPolicy.legacyGrokPlanDefault`) is applied downstream by
  /// `RemoteQuotaSourceCoordinator`, not this fetcher — a fetch round has no memory of
  /// a source's identity across refreshes, so without real metadata the plan must stay
  /// nil here, regardless of the source's display name.
  func testFetchPoolNeverGuessesAPlanWithoutRealMetadata() async throws {
    let files = [
      ManagedAuthFile(
        id: "1", name: "grok-a.json", provider: "grok", status: "ready", disabled: false,
        unavailable: false, authIndex: "grok-a"),
    ]
    let billingBody = """
      {"config":{"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","end":"2026-01-01T00:00:00Z"},"creditUsagePercent":10,"onDemandCap":{"val":0}}}
      """
    let api = StubProxyManagementAPI(
      authFiles: files,
      responses: [:],
      urlResponses: [
        "https://cli-chat-proxy.grok.com/v1/billing?format=credits": (200, billingBody),
        // No settings entry -> settings fetch 404s -> no real metadata available.
      ]
    )
    let fetcher = RemoteManagementQuotaFetcher(apiFactory: StubProxyManagementAPIFactory(api: api))

    let source = RemoteQuotaSourceConfig(name: "CLIProxyAPI Plus", baseURL: "https://proxy.test")
    let result = try await fetcher.fetchPool(source, managementKey: "k")

    XCTAssertNil(result.quotasByProviderAndAccount[.grok]?["grok-a"]?.planType)
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
  /// Keyed by the exact request URL (not `authIndex`) — needed once a single account
  /// makes more than one distinct API call (e.g. Claude's usage + profile requests share
  /// one `authIndex` but hit different URLs), since `responses` alone can't distinguish
  /// them. Checked first; falls back to `responses` when a URL has no explicit entry.
  private let urlResponses: [String: (statusCode: Int, body: String)]
  /// Response headers keyed by `authIndex` — kept separate from `responses`/`urlResponses`
  /// so existing call sites (which only supply status/body tuples) don't need updating.
  private let headerResponses: [String: [String: [String]]]
  private let responding: Bool
  private let authFilesError: Bool
  private let authFilesFailure: Error?
  private(set) var recordedCalls: [ProxyAPICall] = []

  init(
    authFiles: [ManagedAuthFile],
    responses: [String: (statusCode: Int, body: String)],
    urlResponses: [String: (statusCode: Int, body: String)] = [:],
    headerResponses: [String: [String: [String]]] = [:],
    responding: Bool = true,
    authFilesError: Bool = false,
    authFilesFailure: Error? = nil
  ) {
    self.authFilesToReturn = authFiles
    self.responses = responses
    self.urlResponses = urlResponses
    self.headerResponses = headerResponses
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
    let headers = request.authIndex.flatMap { headerResponses[$0] }
    if let response = urlResponses[request.url] {
      return Self.makeResult(statusCode: response.statusCode, body: response.body, headers: headers)
    }
    guard let authIndex = request.authIndex, let response = responses[authIndex] else {
      return Self.makeResult(statusCode: 404, body: nil, headers: headers)
    }
    return Self.makeResult(statusCode: response.statusCode, body: response.body, headers: headers)
  }

  private static func makeResult(statusCode: Int, body: String?, headers: [String: [String]]? = nil) -> ProxyAPICallResult {
    var payload: [String: Any] = ["status_code": statusCode]
    if let body { payload["body"] = body }
    if let headers { payload["header"] = headers }
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
